import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:better_player/src/configuration/better_player_event.dart';
import 'package:better_player/src/configuration/better_player_event_type.dart';
import 'package:better_player/src/configuration/better_player_network_log.dart';
import 'package:better_player/src/configuration/better_player_playback_origin.dart';
import 'package:better_player/src/core/better_player_controller.dart';
import 'package:better_player/src/core/better_player_utils.dart';
import 'package:better_player/src/subtitles/better_player_subtitles_source_type.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:flutter/foundation.dart';

import 'better_player_telemetry_models.dart';
import 'better_player_telemetry_utils.dart';

/// Manages telemetry collection, buffering, and batch uploading according to
/// the Playback Telemetry Client Guide and the backend contract
/// ("Mobile & STB app: telemetry changes", Oct 2026).
///
/// Lifecycle: a data source with a telemetry configuration only *arms* a
/// session ([prepareSession]). The session *begins* (new UUID, `startedAt`,
/// `sessions/start`) on the first play request ([notifyPlayRequested]) or on
/// a fatal error before play, so a failed start is still reported. Setting up
/// the same episode again (fallback URL, quality change) keeps the session and
/// reports a `CDN_SWITCH` when the host changes. A different episode, the end
/// of the media, or disposing the player ends the session with a final batch.
class BetterPlayerTelemetryManager {
  static const double _seekDiscontinuityThresholdS = 15.0;
  static const Duration _playbackEventDedupWindow = Duration(milliseconds: 500);
  static const Duration _cdnSwitchErrorWindow = Duration(seconds: 60);
  static const Duration _flushWaitTimeout = Duration(seconds: 2);
  static const Duration _inFlightWaitTimeout = Duration(seconds: 20);
  static const Duration _requestTimeout = Duration(seconds: 15);
  static const Duration _undeliveredRetryInterval = Duration(seconds: 30);
  static const int _maxUndeliveredSessions = 50;

  // Shared by all players; never closed, so ended sessions can still be
  // delivered after their player is disposed.
  static final HttpClient _sharedHttpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);

  // Ended sessions that could not be delivered yet (offline, server down).
  // They are retried while the app runs and dropped after maxBatchAge.
  static final List<_UndeliveredSession> _undelivered = <_UndeliveredSession>[];
  static Timer? _undeliveredTimer;
  static bool _isRetryingUndelivered = false;
  static const int _maxErrorMessageLength = 500;

  final BetterPlayerController controller;

  /// The unique session ID of the current (or last) viewing session.
  String _sessionId;

  final HttpClient _httpClient;

  // Prepared (armed) data source.
  _PreparedSession? _prepared;

  // Last prepared data source, kept to start a new session on replay.
  _PreparedSession? _lastPrepared;

  // The session that has begun, null while idle or armed.
  _SessionCore? _session;

  // Flushes of ended sessions that are still running.
  final Set<Future<void>> _pendingFlushes = <Future<void>>{};

  // Timers
  Timer? _bufferSampleTimer;
  Timer? _batchSendTimer;

  // Session state
  bool _isDisposed = false;
  bool _hasPlaybackStarted = false;
  _TelemetryPlaybackState _playbackState = _TelemetryPlaybackState.unknown;
  int _chunkSeqCounter = 0;
  // Host serving the current video segments, and host of the current source.
  String? _lastCdnHost;
  String? _sourceHost;
  // A re-setup of the same session (retry, quality change, fallback URL)
  // restores the position with a seek that is not a viewer seek.
  bool _isRestoringPosition = false;
  double? _lastProgressPositionS;

  // Startup measurement
  Stopwatch? _startupStopwatch;
  double? _firstFrameReferenceS;

  // Stall / pause pairing
  Stopwatch? _stallStopwatch;
  bool _isPauseEventOpen = false;

  // Errors
  final Map<String, _ErrorWindow> _errorWindows = <String, _ErrorWindow>{};
  String? _lastErrorCode;
  DateTime? _lastErrorAt;

  // Active watched range tracking
  BetterPlayerWatchedRangeMetric? _activeWatchedRange;
  double? _lastWatchedPositionS;
  double? _pausedPositionS;
  int? _currentQualityLevel;
  int? _currentQualityBitrate;
  int? _currentQualityWidth;
  int? _currentQualityHeight;
  bool _initialQualitySent = false;
  String? _lastPlaybackEventType;
  double? _lastPlaybackEventPositionS;
  Map<String, dynamic>? _lastPlaybackEventDetails;
  DateTime? _lastPlaybackEventAt;
  double? _suppressNextPausePositionS;
  double? _suppressNextPlayPositionS;

  // Languages: the current selection, and the last value that was reported.
  String? _currentAudioLanguage;
  String? _currentSubtitleLanguage;
  String? _reportedAudioLanguage;
  String? _reportedSubtitleLanguage;

  // Queues for pending observations of the current session
  final List<BetterPlayerChunkLoadMetric> _pendingChunkLoads = [];
  final List<BetterPlayerBufferSampleMetric> _pendingBufferSamples = [];
  final List<BetterPlayerWatchedRangeMetric> _pendingWatchedRanges = [];
  final List<BetterPlayerPlaybackEventMetric> _pendingPlaybackEvents = [];

  BetterPlayerTelemetryManager(this.controller, {HttpClient? httpClient})
      : _sessionId = BetterPlayerTelemetryUtils.generateUuidV4(),
        _httpClient = httpClient ?? _sharedHttpClient;

  /// Gets the unique session ID of the current (or last) viewing session.
  String get sessionId => _sessionId;

  /// Gets the current telemetry configuration.
  BetterPlayerTelemetryConfiguration? get configuration =>
      _session?.config ?? _prepared?.config;

  /// Gets the current session telemetry data.
  BetterPlayerTelemetryData? get telemetryData =>
      _session?.data ?? _prepared?.data;

  /// Whether the session start request has succeeded on the server.
  bool get isSessionStartCompleted => _session?.startCompleted == true;

  /// Whether a session is armed and waits for the first play request.
  bool get isSessionArmed => _session == null && _prepared != null;

  /// Whether a session has begun and is reporting.
  bool get isSessionActive => _session != null;

  /// Pending playback events queued for transmission.
  @visibleForTesting
  List<BetterPlayerPlaybackEventMetric> get pendingPlaybackEvents =>
      List.unmodifiable(_pendingPlaybackEvents);

  /// Runs a telemetry entry point. Telemetry must never break playback, so
  /// an unexpected failure is logged and ignored.
  void _guard(String name, void Function() body) {
    try {
      body();
    } catch (e, st) {
      BetterPlayerUtils.log('Telemetry $name failed: $e\n$st');
    }
  }

  /// Completes when every final flush of ended sessions has finished.
  @visibleForTesting
  Future<void> waitForPendingFlushes() async {
    while (_pendingFlushes.isNotEmpty) {
      await Future.wait(_pendingFlushes.toList());
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Arms a session for a data source. Nothing is sent until the first play
  /// request. Setting up the same episode (or the same URL when there is no
  /// episode) while a session is armed or active keeps that session; a host
  /// change is then reported as `CDN_SWITCH`. Anything else ends the current
  /// session first.
  void prepareSession({
    BetterPlayerTelemetryConfiguration? configuration,
    BetterPlayerTelemetryData? telemetryData,
    bool forceNew = false,
  }) =>
      _guard(
          'prepareSession',
          () => _prepareSession(
                configuration: configuration,
                telemetryData: telemetryData,
                forceNew: forceNew,
              ));

  void _prepareSession({
    BetterPlayerTelemetryConfiguration? configuration,
    BetterPlayerTelemetryData? telemetryData,
    bool forceNew = false,
  }) {
    if (_isDisposed) return;
    if (configuration == null || !configuration.hasValue) {
      endSession();
      _prepared = null;
      _lastPrepared = null;
      return;
    }

    final data = telemetryData ?? const BetterPlayerTelemetryData();
    final prepared = _PreparedSession(
      config: configuration,
      data: data,
      identity: _identityOf(data),
    );
    // Resolve native device info early so session start does not wait for it.
    unawaited(BetterPlayerTelemetryUtils.deviceInfo());

    final current = _prepared;
    if (!forceNew && current != null && current.identity == prepared.identity) {
      final session = _session;
      if (session != null) {
        _reportSourceChange(
          BetterPlayerTelemetryUtils.hostOf(prepared.data.fileUrl),
        );
        // The session already started with the first URL; keep its start
        // payload and only remember the new source for a later replay.
      }
      _prepared = prepared;
      _lastPrepared = prepared;
      return;
    }

    endSession();
    _prepared = prepared;
    _lastPrepared = prepared;
  }

  /// Called for every play request (any origin). Begins an armed session,
  /// starts a new session for a replay after the previous one ended, and
  /// starts the startup clock of a session that a fatal error opened early.
  void notifyPlayRequested({
    BetterPlayerPlaybackOrigin origin = BetterPlayerPlaybackOrigin.user,
  }) =>
      _guard('notifyPlayRequested', () => _notifyPlayRequested(origin));

  void _notifyPlayRequested(BetterPlayerPlaybackOrigin origin) {
    if (_isDisposed) return;
    if (_session == null) {
      if (_prepared == null && _lastPrepared != null) {
        _prepared = _lastPrepared;
      }
      if (_prepared == null) return;
      _beginSession(startStopwatch: true);
    } else if (!_hasPlaybackStarted && _startupStopwatch == null) {
      _startupStopwatch = Stopwatch()..start();
      _firstFrameReferenceS = _getCurrentPositionSeconds();
    }
    _handlePlay(_getCurrentPositionSeconds(), origin);
  }

  /// Called for every pause request, before the player is paused, so the
  /// origin of the pause is known before the native pause event arrives.
  void notifyPauseRequested({
    BetterPlayerPlaybackOrigin origin = BetterPlayerPlaybackOrigin.user,
  }) =>
      _guard('notifyPauseRequested', () {
        if (_isDisposed || _session == null) return;
        _handlePause(_getCurrentPositionSeconds(), origin);
      });

  /// Ends the current session. An armed session is dropped without any
  /// request; an active one is sent with a final batch (`isFinal: true`).
  void endSession({bool isFinal = true}) =>
      _guard('endSession', () => _endSession(isFinal: isFinal));

  void _endSession({required bool isFinal}) {
    final session = _session;
    if (session == null) {
      _prepared = null;
      return;
    }
    _finalizeWatchedRange(_getCurrentPositionSeconds());
    _stopTimers();

    final chunks = List<BetterPlayerChunkLoadMetric>.from(_pendingChunkLoads);
    final samples =
        List<BetterPlayerBufferSampleMetric>.from(_pendingBufferSamples);
    final ranges =
        List<BetterPlayerWatchedRangeMetric>.from(_pendingWatchedRanges);
    final events =
        List<BetterPlayerPlaybackEventMetric>.from(_pendingPlaybackEvents);

    session.ended = true;
    session.startRetryTimer?.cancel();
    _session = null;
    _prepared = null;
    _resetSessionState();

    final flush = _flushEndedSession(
      session,
      chunks: chunks,
      samples: samples,
      ranges: ranges,
      events: events,
      isFinal: isFinal,
    ).catchError((Object e) {
      BetterPlayerUtils.log('Telemetry final flush failed: $e');
    });
    _pendingFlushes.add(flush);
    flush.whenComplete(() => _pendingFlushes.remove(flush));
  }

  /// Sends what is pending now without ending the session (app goes to the
  /// background).
  void flush() => _guard('flush', () {
        if (_isDisposed || _session == null) return;
        _sendPendingBatches(isFinal: false);
      });

  /// Legacy API: arms a new session and begins it immediately.
  void startSession({
    BetterPlayerTelemetryConfiguration? configuration,
    BetterPlayerTelemetryData? telemetryData,
  }) {
    prepareSession(
      configuration: configuration,
      telemetryData: telemetryData,
      forceNew: true,
    );
    if (_prepared != null) {
      _beginSession(startStopwatch: true);
    }
  }

  /// Legacy API: ends the current session.
  /// If [flushPrevious] is false, queued data of the session is discarded
  /// and no final batch is sent.
  Future<void> stopSession({bool flushPrevious = true}) async {
    if (!flushPrevious) {
      _session?.ended = true;
      _session?.startRetryTimer?.cancel();
      _session = null;
      _prepared = null;
      _stopTimers();
      _resetSessionState();
      return;
    }
    endSession();
    await waitForPendingFlushes()
        .timeout(const Duration(seconds: 6), onTimeout: () {});
  }

  /// Flushes pending data and terminates the telemetry manager.
  Future<void> dispose({bool isFinal = true}) async {
    if (_isDisposed) return;
    endSession(isFinal: isFinal);
    _prepared = null;
    _lastPrepared = null;
    _isDisposed = true;
    try {
      await waitForPendingFlushes().timeout(const Duration(seconds: 6));
    } catch (_) {}
  }

  /// Number of ended sessions waiting to be delivered.
  @visibleForTesting
  static int get undeliveredSessionCount => _undelivered.length;

  /// Retries delivery of ended sessions now.
  @visibleForTesting
  static Future<void> retryUndeliveredSessions() => _retryUndelivered();

  String _identityOf(BetterPlayerTelemetryData data) {
    final episodeId =
        BetterPlayerTelemetryUtils.normalizeEpisodeId(data.episodeId);
    if (episodeId != null) return 'episode:$episodeId';
    return 'url:${BetterPlayerTelemetryUtils.cleanFileUrl(data.fileUrl) ?? ''}';
  }

  void _beginSession({required bool startStopwatch}) {
    final prepared = _prepared;
    if (prepared == null || _isDisposed) return;

    _resetSessionState();
    final session = _SessionCore(
      config: prepared.config,
      data: prepared.data,
      sessionId: BetterPlayerTelemetryUtils.generateUuidV4(),
      startedAt: BetterPlayerTelemetryUtils.formatIsoTimestamp(DateTime.now()),
    );
    _session = session;
    _sessionId = session.sessionId;
    _sourceHost = BetterPlayerTelemetryUtils.hostOf(prepared.data.fileUrl);
    _firstFrameReferenceS = _getCurrentPositionSeconds();
    if (startStopwatch) {
      _startupStopwatch = Stopwatch()..start();
    }
    // Languages selected before play (default tracks, app preferences).
    _currentAudioLanguage = prepared.audioLanguage;
    _currentSubtitleLanguage = prepared.subtitleLanguage;

    _startTimers(session.config);
    session.startFuture = _dispatchSessionStart(session);
  }

  void _resetSessionState() {
    _hasPlaybackStarted = false;
    _playbackState = _TelemetryPlaybackState.unknown;
    _chunkSeqCounter = 0;
    _lastCdnHost = null;
    _sourceHost = null;
    _isRestoringPosition = false;
    _lastProgressPositionS = null;
    _startupStopwatch = null;
    _firstFrameReferenceS = null;
    _stallStopwatch = null;
    _isPauseEventOpen = false;
    _errorWindows.clear();
    _lastErrorCode = null;
    _lastErrorAt = null;
    _activeWatchedRange = null;
    _lastWatchedPositionS = null;
    _pausedPositionS = null;
    _currentQualityLevel = null;
    _currentQualityBitrate = null;
    _currentQualityWidth = null;
    _currentQualityHeight = null;
    _initialQualitySent = false;
    _lastPlaybackEventType = null;
    _lastPlaybackEventPositionS = null;
    _lastPlaybackEventDetails = null;
    _lastPlaybackEventAt = null;
    _suppressNextPausePositionS = null;
    _suppressNextPlayPositionS = null;
    _currentAudioLanguage = null;
    _currentSubtitleLanguage = null;
    _reportedAudioLanguage = null;
    _reportedSubtitleLanguage = null;
    _pendingChunkLoads.clear();
    _pendingBufferSamples.clear();
    _pendingWatchedRanges.clear();
    _pendingPlaybackEvents.clear();
  }

  void _startTimers(BetterPlayerTelemetryConfiguration config) {
    _stopTimers();
    _bufferSampleTimer = Timer.periodic(
      config.bufferSampleInterval,
      (_) => _takeBufferSample(),
    );
    _batchSendTimer = Timer.periodic(
      config.batchSendInterval,
      (_) => _sendPendingBatches(isFinal: false),
    );
  }

  void _stopTimers() {
    _bufferSampleTimer?.cancel();
    _bufferSampleTimer = null;
    _batchSendTimer?.cancel();
    _batchSendTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Session start
  // ---------------------------------------------------------------------------

  Future<Map<String, dynamic>> _buildStartPayload(_SessionCore session) async {
    final existing = session.startPayload;
    if (existing != null) return existing;

    Map<String, dynamic>? info;
    try {
      info = await BetterPlayerTelemetryUtils.deviceInfo()
          .timeout(const Duration(seconds: 1));
    } catch (_) {}
    final nativeOs = BetterPlayerTelemetryUtils.osFromDeviceInfo(info);
    final nativeModel =
        BetterPlayerTelemetryUtils.deviceModelFromDeviceInfo(info);
    final data = session.data.copyWith(
      os: nativeOs,
      deviceModel: (session.data.deviceModel?.trim().isNotEmpty ?? false)
          ? session.data.deviceModel
          : nativeModel,
    );
    final payload = data.toMap(
      sessionId: session.sessionId,
      startedAt: session.startedAt,
    );
    session.startPayload = payload;
    return payload;
  }

  /// Dispatches POST v1/statistics/sessions/start for [session].
  Future<bool> _dispatchSessionStart(_SessionCore session) async {
    if (session.startCompleted) return true;
    if (session.startRejected) return false;
    final ok = await _postSessionStart(session);
    if (!ok && !session.startRejected && !session.ended && !_isDisposed) {
      _scheduleSessionStartRetry(session);
    }
    return ok;
  }

  Future<bool> _postSessionStart(_SessionCore session) async {
    final targetUri = session.config.startSessionUri;
    if (targetUri == null) return false;

    try {
      final payload = await _buildStartPayload(session);
      final jsonBody = jsonEncode(payload);
      BetterPlayerUtils.log(
        'Telemetry session start POST $targetUri '
        'query parameters: ${jsonEncode(targetUri.queryParametersAll)} '
        'body: $jsonBody',
      );
      final client = session.config.httpClient ?? _httpClient;
      final request = await client.postUrl(targetUri).timeout(_requestTimeout);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      session.config.headers?.forEach((key, value) {
        if (value != null) {
          request.headers.set(key, value);
        }
      });

      final jsonBytes = utf8.encode(jsonBody);
      request.contentLength = jsonBytes.length;
      request.add(jsonBytes);

      final response = await request.close().timeout(_requestTimeout);
      final responseBody = await response
          .transform(const Utf8Decoder())
          .join()
          .timeout(_requestTimeout);
      BetterPlayerUtils.log(
        'Telemetry session start response POST $targetUri '
        'status: ${response.statusCode} body: $responseBody',
      );
      if (response.statusCode >= 200 && response.statusCode < 300) {
        session.startCompleted = true;
        session.startRetryDelay = const Duration(seconds: 2);
        return true;
      }
      BetterPlayerUtils.log(
        'Telemetry session start rejected with status ${response.statusCode}: $responseBody',
      );
      if (response.statusCode == 400 || response.statusCode == 409) {
        session.startRejected = true;
      }
      return false;
    } catch (e) {
      BetterPlayerUtils.log('Telemetry session start failed: $e');
      return false;
    }
  }

  void _scheduleSessionStartRetry(_SessionCore session) {
    session.startRetryTimer?.cancel();
    session.startRetryTimer = Timer(session.startRetryDelay, () {
      if (session.ended || _isDisposed || session.startCompleted) return;
      session.startRetryDelay = Duration(
        seconds: min(30, session.startRetryDelay.inSeconds * 2),
      );
      session.startFuture = _dispatchSessionStart(session);
    });
  }

  // ---------------------------------------------------------------------------
  // Player events
  // ---------------------------------------------------------------------------

  /// Handles incoming player events from [BetterPlayerController].
  void handlePlayerEvent(BetterPlayerEvent event) =>
      _guard('handlePlayerEvent', () => _handlePlayerEvent(event));

  void _handlePlayerEvent(BetterPlayerEvent event) {
    if (_isDisposed) return;
    final type = event.betterPlayerEventType;

    // Errors may open a session (failed start); language selections made
    // before play are remembered for the first batch.
    if (type == BetterPlayerEventType.exception) {
      _handleError(_getCurrentPositionSeconds(), event.parameters);
      return;
    }
    if (_session == null) {
      _rememberArmedSelection(event);
      return;
    }

    final currentPositionS = _getCurrentPositionSeconds();
    final origin = _originOf(event);

    switch (type) {
      case BetterPlayerEventType.play:
        _handlePlay(currentPositionS, origin);
        break;

      case BetterPlayerEventType.pause:
        _handlePause(currentPositionS, origin);
        break;

      case BetterPlayerEventType.seekTo:
        final toDuration = event.parameters?['duration'] as Duration?;
        final fromDuration = event.parameters?['fromDuration'] as Duration?;
        _handleSeek(currentPositionS, toDuration, fromDuration);
        break;

      case BetterPlayerEventType.bufferingStart:
        _handleStallStart(currentPositionS);
        break;

      case BetterPlayerEventType.bufferingEnd:
        _handleStallEnd(currentPositionS);
        break;

      case BetterPlayerEventType.changedTrack:
      case BetterPlayerEventType.changedResolution:
        _handleQualitySwitch(currentPositionS, event);
        break;

      case BetterPlayerEventType.finished:
        _handleEnded(currentPositionS);
        break;

      case BetterPlayerEventType.setupDataSource:
        _handleSourceReset();
        break;

      case BetterPlayerEventType.progress:
        _handleProgress(currentPositionS);
        break;

      case BetterPlayerEventType.changedAudioTrack:
        handleAudioLanguageChanged(
          from: event.parameters?['from'] as String?,
          to: event.parameters?['to'] as String?,
          positionS: currentPositionS,
        );
        break;

      case BetterPlayerEventType.changedSubtitles:
        if (event.parameters?.containsKey('from') == true ||
            event.parameters?.containsKey('to') == true) {
          handleSubtitleChanged(
            from: event.parameters?['from'] as String?,
            to: event.parameters?['to'] as String?,
            isFromNone: event.parameters?['isFromNone'] == true,
            isToNone: event.parameters?['isToNone'] == true,
            positionS: currentPositionS,
          );
        }
        break;

      default:
        break;
    }
  }

  /// Checks for the first rendered frame. Called on every player value
  /// change so startup time is measured with the player's position updates.
  void handlePositionTick() {
    if (_isDisposed || _session == null || _hasPlaybackStarted) return;
    _guard('handlePositionTick',
        () => _checkFirstFrame(_getCurrentPositionSeconds()));
  }

  BetterPlayerPlaybackOrigin _originOf(BetterPlayerEvent event) {
    final origin = event.parameters?['origin'];
    return origin is BetterPlayerPlaybackOrigin
        ? origin
        : BetterPlayerPlaybackOrigin.user;
  }

  void _rememberArmedSelection(BetterPlayerEvent event) {
    final prepared = _prepared;
    if (prepared == null) return;
    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.changedAudioTrack:
        final to = event.parameters?['to'] as String?;
        if (to != null) {
          prepared.audioLanguage =
              BetterPlayerTelemetryUtils.normalizeAudioLanguageCode(to);
        }
        break;
      case BetterPlayerEventType.changedSubtitles:
        if (event.parameters?.containsKey('to') == true) {
          prepared.subtitleLanguage =
              BetterPlayerTelemetryUtils.normalizeSubtitleLanguageCode(
            event.parameters?['to'] as String?,
            isNone: event.parameters?['isToNone'] == true,
          );
        }
        break;
      default:
        break;
    }
  }

  /// Ingests network logs and captures video chunk loads.
  void handleNetworkLog(BetterPlayerNetworkLog log) =>
      _guard('handleNetworkLog', () => _handleNetworkLog(log));

  void _handleNetworkLog(BetterPlayerNetworkLog log) {
    if (_isDisposed || _session == null) return;

    // Playback moved to another host: a video segment completed there.
    // Manifests (redirects, master and media playlists on different hosts),
    // audio and subtitle loads are not compared.
    final logTrackType = log.trackType?.toLowerCase();
    if (log.isMediaChunk &&
        log.phase == BetterPlayerNetworkLogPhase.completed &&
        log.dataType != BetterPlayerNetworkDataType.manifest &&
        log.dataType != BetterPlayerNetworkDataType.subtitles &&
        logTrackType != 'text' &&
        logTrackType != 'audio') {
      final host = BetterPlayerTelemetryUtils.hostOf(log.url);
      if (host != null) {
        if (_lastCdnHost == null) {
          // The first segment of a source sets the serving host.
          _lastCdnHost = host;
        } else {
          _reportHostChange(host);
        }
      }
    }

    // Ingest completed media chunk segment
    // Rule: Report real measurements. Do not send invented or incomplete segment loads.
    if (log.dataType == BetterPlayerNetworkDataType.mediaSegment &&
        log.phase == BetterPlayerNetworkLogPhase.completed &&
        log.mediaStartTimeMs != null &&
        log.mediaEndTimeMs != null) {
      final trackType = log.trackType?.toLowerCase();
      if (trackType == 'audio' || trackType == 'text') return;

      final source = log.segmentFileName;
      if (source == null) return;

      final startS = max(0.0, log.mediaStartTimeMs! / 1000.0);
      final endS = max(startS, log.mediaEndTimeMs! / 1000.0);
      final qualitySnapshot = _resolveQualitySnapshot(
        bitrate: log.bitrate,
        width: log.width,
        height: log.height,
      );
      final level = qualitySnapshot?.level ?? _currentQualityLevel ?? 0;

      if (qualitySnapshot != null) {
        _updateQualityLevel(
          qualitySnapshot,
          positionS: _getCurrentPositionSeconds(),
        );
      }

      final chunkMetric = BetterPlayerChunkLoadMetric(
        chunkSeq: _chunkSeqCounter++,
        level: level,
        startS: startS,
        endS: endS,
        bytes: max(0, log.bytesLoaded),
        loadMs: max(0, log.durationMs),
        source: source,
        loadedAt: BetterPlayerTelemetryUtils.formatIsoTimestamp(log.timestamp),
      );

      _addOrReplaceChunkLoad(chunkMetric);
    }
  }

  /// The same session continues on a new source URL (fallback).
  void _reportSourceChange(String? newSourceHost) {
    final previousHost = _lastCdnHost ?? _sourceHost;
    _sourceHost = newSourceHost;
    // Segments of the new source set the serving host again.
    _lastCdnHost = null;
    _recordCdnSwitch(previousHost, newSourceHost);
  }

  void _reportHostChange(String newHost) {
    final previousHost = _lastCdnHost;
    _lastCdnHost = newHost;
    _recordCdnSwitch(previousHost, newHost);
  }

  void _recordCdnSwitch(String? previousHost, String? newHost) {
    if (_session == null ||
        previousHost == null ||
        newHost == null ||
        previousHost == newHost) {
      return;
    }
    recordPlaybackEvent(
      type: 'CDN_SWITCH',
      positionS: _getCurrentPositionSeconds(),
      details: <String, dynamic>{
        'previousHost': previousHost,
        'newHost': newHost,
        'errorCode': _recentErrorCode(),
      },
    );
  }

  String? _recentErrorCode() {
    final at = _lastErrorAt;
    if (at == null || DateTime.now().difference(at) > _cdnSwitchErrorWindow) {
      return null;
    }
    return _lastErrorCode;
  }

  void _addOrReplaceChunkLoad(BetterPlayerChunkLoadMetric chunkMetric) {
    final duplicateIndex = _pendingChunkLoads.indexWhere((existing) {
      return existing.level == chunkMetric.level &&
          (existing.startS - chunkMetric.startS).abs() <= 0.05 &&
          (existing.endS - chunkMetric.endS).abs() <= 0.05;
    });

    if (duplicateIndex == -1) {
      _pendingChunkLoads.add(chunkMetric);
      return;
    }

    _chunkSeqCounter--;
    final existing = _pendingChunkLoads[duplicateIndex];
    if (chunkMetric.bytes <= existing.bytes) return;

    _pendingChunkLoads[duplicateIndex] = BetterPlayerChunkLoadMetric(
      chunkSeq: existing.chunkSeq,
      level: chunkMetric.level,
      startS: chunkMetric.startS,
      endS: chunkMetric.endS,
      bytes: chunkMetric.bytes,
      loadMs: chunkMetric.loadMs,
      source: chunkMetric.source,
      loadedAt: chunkMetric.loadedAt,
    );
  }

  _QualitySnapshot? _resolveQualitySnapshot({
    int? bitrate,
    int? width,
    int? height,
  }) {
    final tracks = controller.betterPlayerAsmsTracks;
    if (tracks.isNotEmpty) {
      for (int i = 0; i < tracks.length; i++) {
        final track = tracks[i];
        if (_isAutoTrack(
          bitrate: track.bitrate,
          width: track.width,
          height: track.height,
        )) {
          continue;
        }
        if (bitrate != null && bitrate > 0 && track.bitrate == bitrate) {
          return _QualitySnapshot(
            level: i,
            bitrate: track.bitrate ?? bitrate,
            width: track.width ?? width,
            height: track.height ?? height,
          );
        }
      }

      for (int i = 0; i < tracks.length; i++) {
        final track = tracks[i];
        if (_isAutoTrack(
          bitrate: track.bitrate,
          width: track.width,
          height: track.height,
        )) {
          continue;
        }
        if (height != null && height > 0 && track.height == height) {
          return _QualitySnapshot(
            level: i,
            bitrate: track.bitrate ?? bitrate,
            width: track.width ?? width,
            height: track.height ?? height,
          );
        }
      }
    }

    if (_hasConcreteQuality(bitrate: bitrate, width: width, height: height) &&
        _currentQualityLevel != null) {
      return _QualitySnapshot(
        level: _currentQualityLevel!,
        bitrate: bitrate ?? _currentQualityBitrate,
        width: width ?? _currentQualityWidth,
        height: height ?? _currentQualityHeight,
      );
    }

    return null;
  }

  bool _hasConcreteQuality({int? bitrate, int? width, int? height}) {
    return (bitrate ?? 0) > 0 || (width ?? 0) > 0 || (height ?? 0) > 0;
  }

  bool _isAutoTrack({int? bitrate, int? width, int? height}) {
    return (bitrate ?? 0) == 0 && (width ?? 0) == 0 && (height ?? 0) == 0;
  }

  bool get _isControllerPlaying {
    try {
      if (controller.videoPlayerController == null) return false;
      return controller.isPlaying() == true;
    } catch (_) {
      return false;
    }
  }

  void _handlePlay(double positionS, BetterPlayerPlaybackOrigin origin) {
    if (_consumeSuppressedPlay(positionS)) {
      _playbackState = _TelemetryPlaybackState.playing;
      _pausedPositionS = null;
      _startOrExtendWatchedRange(positionS);
      return;
    }

    final pausedPositionS = _pausedPositionS;
    // Any play closes a reported user pause, so every PAUSE gets a RESUME.
    if (_isPauseEventOpen) {
      _isPauseEventOpen = false;
      _handleResumePosition(positionS);
      recordPlaybackEvent(
        type: 'RESUME',
        positionS: positionS,
      );
    }
    _playbackState = _TelemetryPlaybackState.playing;
    _pausedPositionS = null;
    if (pausedPositionS != null &&
        (positionS - pausedPositionS).abs() <= _seekDiscontinuityThresholdS) {
      _continueWatchedRangeThroughPosition(positionS);
    } else {
      _startOrExtendWatchedRange(positionS);
    }
  }

  void _handlePause(double positionS, BetterPlayerPlaybackOrigin origin) {
    if (_consumeSuppressedPause(positionS)) {
      if (_activeWatchedRange != null) {
        _activeWatchedRange = _activeWatchedRange!.copyWith(toS: positionS);
        _lastWatchedPositionS = positionS;
      }
      return;
    }

    _pausedPositionS = positionS;
    if (_activeWatchedRange != null) {
      _activeWatchedRange = _activeWatchedRange!.copyWith(toS: positionS);
      _lastWatchedPositionS = positionS;
    }
    if (_playbackState == _TelemetryPlaybackState.paused) {
      return;
    }
    _playbackState = _TelemetryPlaybackState.paused;
    // Only a viewer's pause is a PAUSE event. Closing, backgrounding, ads,
    // dialogs, buffering, errors and the end of media are not.
    if (origin != BetterPlayerPlaybackOrigin.user || !_hasPlaybackStarted) {
      return;
    }
    _isPauseEventOpen = true;
    recordPlaybackEvent(
      type: 'PAUSE',
      positionS: positionS,
    );
  }

  void _handleSeekWithPositions(double fromPositionS, double toPositionS) {
    // Before the first frame a seek only moves the start position.
    if (!_hasPlaybackStarted) {
      _firstFrameReferenceS = toPositionS;
      return;
    }

    // The position restore after a retry / quality change / fallback.
    if (_isRestoringPosition) {
      _isRestoringPosition = false;
      _finalizeWatchedRange(_activeWatchedRange?.toS ?? fromPositionS);
      if (_isControllerPlaying) {
        _startOrExtendWatchedRange(toPositionS);
      }
      return;
    }

    final seekDistanceS = (toPositionS - fromPositionS).abs();
    if (seekDistanceS <= _seekDiscontinuityThresholdS) {
      _continueWatchedRangeThroughPosition(toPositionS);
      return;
    }

    _finalizeWatchedRange(fromPositionS);

    recordPlaybackEvent(
      type: 'SEEK',
      positionS: toPositionS,
      details: <String, dynamic>{
        'fromS': fromPositionS,
        'toS': toPositionS,
      },
    );

    if (_isControllerPlaying) {
      _startOrExtendWatchedRange(toPositionS);
    }
  }

  void _handleSeek(
    double currentPositionS,
    Duration? toDuration,
    Duration? fromDuration,
  ) {
    if (toDuration == null) return;

    final toPositionS = toDuration.inMilliseconds / 1000.0;
    final fromPositionS = fromDuration != null
        ? fromDuration.inMilliseconds / 1000.0
        : _resolveSeekStartPositionFallback(currentPositionS);
    _handleSeekWithPositions(fromPositionS, toPositionS);
  }

  double _resolveSeekStartPositionFallback(double currentPositionS) {
    return _pausedPositionS ??
        _lastWatchedPositionS ??
        _activeWatchedRange?.toS ??
        currentPositionS;
  }

  void _handleResumePosition(double positionS) {
    final pausedPositionS = _pausedPositionS;
    if (pausedPositionS == null) return;

    final resumeDistanceS = (positionS - pausedPositionS).abs();
    if (resumeDistanceS <= _seekDiscontinuityThresholdS) return;

    _finalizeWatchedRange(pausedPositionS);

    recordPlaybackEvent(
      type: 'SEEK',
      positionS: positionS,
      details: <String, dynamic>{
        'fromS': pausedPositionS,
        'toS': positionS,
      },
    );
  }

  void _handleStallStart(double positionS) {
    // A stall exists only after the first frame, while playing, and once.
    if (!_hasPlaybackStarted ||
        _stallStopwatch != null ||
        _playbackState == _TelemetryPlaybackState.paused ||
        !_isControllerPlaying) {
      return;
    }
    if (_activeWatchedRange != null) {
      _activeWatchedRange = _activeWatchedRange!.copyWith(toS: positionS);
      _lastWatchedPositionS = positionS;
    }
    _suppressNextPausePositionS = positionS;
    _stallStopwatch = Stopwatch()..start();
    recordPlaybackEvent(
      type: 'STALL_START',
      positionS: positionS,
    );
  }

  void _handleStallEnd(double positionS) {
    final stopwatch = _stallStopwatch;
    // No STALL_END without an open STALL_START.
    if (stopwatch == null) return;
    _stallStopwatch = null;
    _suppressNextPlayPositionS = positionS;
    recordPlaybackEvent(
      type: 'STALL_END',
      positionS: positionS,
      details: <String, dynamic>{
        'durationMs': stopwatch.elapsedMilliseconds,
      },
    );

    if (_isControllerPlaying) {
      _startOrExtendWatchedRange(positionS);
    }
  }

  bool _consumeSuppressedPause(double positionS) {
    return _consumeSuppressedPlaybackTransition(
      positionS,
      pause: true,
    );
  }

  bool _consumeSuppressedPlay(double positionS) {
    return _consumeSuppressedPlaybackTransition(
      positionS,
      pause: false,
    );
  }

  bool _consumeSuppressedPlaybackTransition(
    double positionS, {
    required bool pause,
  }) {
    final suppressedPositionS =
        pause ? _suppressNextPausePositionS : _suppressNextPlayPositionS;
    if (suppressedPositionS == null) return false;

    if (pause) {
      _suppressNextPausePositionS = null;
    } else {
      _suppressNextPlayPositionS = null;
    }
    return (positionS - suppressedPositionS).abs() <= 0.25;
  }

  void _handleQualitySwitch(double positionS, BetterPlayerEvent event) {
    final snapshot = _resolveQualitySnapshot(
      bitrate: (event.parameters?['bitrate'] as num?)?.toInt(),
      width: (event.parameters?['width'] as num?)?.toInt(),
      height: (event.parameters?['height'] as num?)?.toInt(),
    );
    if (snapshot == null) return;

    _updateQualityLevel(
      snapshot,
      positionS: positionS,
    );
  }

  void _updateQualityLevel(
    _QualitySnapshot snapshot, {
    required double positionS,
  }) {
    final previousLevel = _currentQualityLevel;
    _currentQualityLevel = snapshot.level;
    _currentQualityBitrate = snapshot.bitrate;
    _currentQualityWidth = snapshot.width;
    _currentQualityHeight = snapshot.height;

    if (previousLevel != snapshot.level) {
      if (_activeWatchedRange != null) {
        _activeWatchedRange = _activeWatchedRange!.copyWith(
          level: snapshot.level,
        );
      } else if (_isControllerPlaying) {
        _startOrExtendWatchedRange(positionS);
      }
    }

    // Before the first frame only the current rendition is remembered; the
    // initial QUALITY_SWITCH is sent with the first frame.
    if (!_hasPlaybackStarted) return;
    if (!_initialQualitySent) {
      _recordInitialQualitySwitch(positionS);
      return;
    }
    if (previousLevel == snapshot.level) return;

    _recordQualitySwitch(fromLevel: previousLevel, positionS: positionS);
  }

  void _recordInitialQualitySwitch(double positionS) {
    if (_initialQualitySent || _currentQualityLevel == null) return;
    _initialQualitySent = true;
    _recordQualitySwitch(fromLevel: null, positionS: positionS);
  }

  void _recordQualitySwitch({
    required int? fromLevel,
    required double positionS,
  }) {
    recordPlaybackEvent(
      type: 'QUALITY_SWITCH',
      positionS: positionS,
      details: <String, dynamic>{
        'fromLevel': fromLevel,
        'toLevel': _currentQualityLevel,
        if (_currentQualityBitrate != null) 'bitrate': _currentQualityBitrate,
        if (_currentQualityWidth != null) 'width': _currentQualityWidth,
        if (_currentQualityHeight != null) 'height': _currentQualityHeight,
      },
    );
  }

  void _handleEnded(double positionS) {
    if (_session == null) return;
    // A "completed" far from the end is a player glitch the app recovers
    // from (seek back and play); it is not the end of the viewing.
    final duration = controller.videoPlayerController?.value.duration;
    final lastPositionS = _lastProgressPositionS;
    if (duration != null &&
        duration > Duration.zero &&
        lastPositionS != null &&
        duration.inMilliseconds / 1000.0 - lastPositionS >
            _seekDiscontinuityThresholdS) {
      BetterPlayerUtils.log(
        'Telemetry ignored an early finished event at ${lastPositionS}s',
      );
      return;
    }
    _finalizeWatchedRange(_activeWatchedRange?.toS ?? positionS);
    recordPlaybackEvent(
      type: 'ENDED',
      positionS: positionS,
    );
    // The session ends here; playing again starts a new session.
    endSession();
  }

  /// The same session sets up its source again (retry, quality change,
  /// fallback URL). The player position reads 0 until the restore seek.
  void _handleSourceReset() {
    final range = _activeWatchedRange;
    if (range != null) {
      _finalizeWatchedRange(range.toS);
    }
    _pausedPositionS = null;
    _isRestoringPosition = _hasPlaybackStarted;
  }

  void _handleError(double positionS, Map<String, dynamic>? parameters) {
    if (_prepared == null && _session == null) return;
    // The same error state reported again by the player listener.
    if (parameters?['isRepeat'] == true) return;

    final message = parameters?['exception']?.toString();
    final rawDetails = parameters?['errorDetails'];
    final nativeDetails = rawDetails is Map
        ? Map<String, dynamic>.from(rawDetails)
        : const <String, dynamic>{};

    // A stall is reported as STALL_START / STALL_END, never as an error.
    if (nativeDetails['kind'] == 'stall' ||
        (message?.contains('stalled while buffering') ?? false)) {
      return;
    }

    final code = (nativeDetails['code'] as String?)?.trim().isNotEmpty == true
        ? nativeDetails['code'] as String
        : 'PLAYBACK_ERROR';
    final fatalValue = nativeDetails['fatal'];
    final fatal = fatalValue is bool
        ? fatalValue
        : controller.videoPlayerController?.value.hasError == true;

    // A play attempt that fails before play still becomes a session.
    if (_session == null) {
      _beginSession(startStopwatch: false);
      if (_session == null) return;
    }

    final now = DateTime.now();
    _lastErrorCode = code;
    _lastErrorAt = now;

    final interval = _session!.config.errorRepeatInterval;
    final window = _errorWindows[code];
    if (window != null && now.difference(window.lastSentAt) < interval) {
      window.suppressed++;
      return;
    }
    final count = 1 + (window?.suppressed ?? 0);
    _errorWindows[code] = _ErrorWindow(now);

    final errorMessage = (nativeDetails['message'] as String?) ?? message;
    recordPlaybackEvent(
      type: 'ERROR',
      positionS: positionS,
      details: <String, dynamic>{
        'code': code,
        'errorCode': nativeDetails['errorCode'],
        'fatal': fatal,
        'httpStatus': nativeDetails['httpStatus'],
        'host': nativeDetails['host'],
        'message': BetterPlayerTelemetryUtils.clamp(
          errorMessage ?? 'Playback error',
          _maxErrorMessageLength,
        ),
        'count': count,
      },
    );

    if (fatal) {
      // Playback stopped: an open stall ends here, so it stays paired.
      _handleStallEnd(positionS);
      _suppressNextPlayPositionS = null;
      _finalizeWatchedRange(_activeWatchedRange?.toS ?? positionS);
      _sendPendingBatches(isFinal: false);
    }
  }

  void _handleProgress(double currentPositionS) {
    if (!_isControllerPlaying) return;
    _lastProgressPositionS = currentPositionS;
    _checkFirstFrame(currentPositionS);
    _startOrExtendWatchedRange(currentPositionS);
  }

  /// PLAYBACK_STARTED is sent once, when the position first advances after
  /// the play request (the first rendered frame).
  void _checkFirstFrame(double positionS) {
    if (_hasPlaybackStarted || _session == null || !_isControllerPlaying) {
      return;
    }
    final reference = _firstFrameReferenceS;
    // While buffering the position only jumps (seek to a start position);
    // frames render once the player is ready.
    final isBuffering =
        controller.videoPlayerController?.value.isBuffering == true;
    if (reference == null || positionS < reference || isBuffering) {
      _firstFrameReferenceS = positionS;
      return;
    }
    if (positionS <= reference + 0.001) return;

    _hasPlaybackStarted = true;
    _playbackState = _TelemetryPlaybackState.playing;
    final stopwatch = _startupStopwatch;
    _startupStopwatch = null;
    recordPlaybackEvent(
      type: 'PLAYBACK_STARTED',
      positionS: positionS,
      details: <String, dynamic>{
        'startupMs': stopwatch?.elapsedMilliseconds ?? _millisSinceStart(),
      },
    );
    _recordInitialQualitySwitch(positionS);
    _recordInitialLanguages(positionS);
  }

  int _millisSinceStart() {
    final startedAt = DateTime.tryParse(_session?.startedAt ?? '');
    if (startedAt == null) return 0;
    return max(0, DateTime.now().difference(startedAt).inMilliseconds);
  }

  void _recordInitialLanguages(double positionS) {
    final audio = _resolveCurrentAudioLanguage();
    _currentAudioLanguage = audio;
    _reportedAudioLanguage = audio;
    recordPlaybackEvent(
      type: 'AUDIO_LANGUAGE_CHANGED',
      positionS: positionS,
      details: <String, dynamic>{'from': 'none', 'to': audio},
    );

    final subtitle = _resolveCurrentSubtitleLanguage();
    _currentSubtitleLanguage = subtitle;
    _reportedSubtitleLanguage = subtitle;
    recordPlaybackEvent(
      type: 'SUBTITLE_CHANGED',
      positionS: positionS,
      details: <String, dynamic>{'from': 'none', 'to': subtitle},
    );
  }

  String _resolveCurrentAudioLanguage() {
    String? language;
    try {
      language = controller.betterPlayerAsmsAudioTrack?.language;
      language ??= _currentAudioLanguage;
      final tracks = controller.betterPlayerAsmsAudioTracks;
      language ??=
          tracks?.firstWhereOrNull((track) => track.isSelected)?.language;
      if (language == null && tracks != null && tracks.length == 1) {
        language = tracks.first.language;
      }
    } catch (_) {}
    return BetterPlayerTelemetryUtils.normalizeAudioLanguageCode(language);
  }

  String _resolveCurrentSubtitleLanguage() {
    try {
      final source = controller.betterPlayerSubtitlesSource;
      if (source != null) {
        return BetterPlayerTelemetryUtils.normalizeSubtitleLanguageCode(
          source.language,
          isNone: source.type == BetterPlayerSubtitlesSourceType.none,
        );
      }
    } catch (_) {}
    return _currentSubtitleLanguage ?? 'none';
  }

  void _startOrExtendWatchedRange(double positionS) {
    if (_activeWatchedRange == null) {
      _activeWatchedRange = BetterPlayerWatchedRangeMetric(
        rangeId: BetterPlayerTelemetryUtils.generateUuidV4(),
        fromS: positionS,
        toS: positionS,
        level: _currentQualityLevel,
      );
      _lastWatchedPositionS = positionS;
      return;
    }

    final lastPos = _lastWatchedPositionS ?? _activeWatchedRange!.fromS;
    final delta = positionS - lastPos;

    // Forward playback progression or a small tolerated seek/jump.
    if (delta >= 0.0 && delta <= _seekDiscontinuityThresholdS) {
      _activeWatchedRange = _activeWatchedRange!.copyWith(toS: positionS);
      _lastWatchedPositionS = positionS;
    } else {
      // Seek jump or discontinuity detected: finalize existing and split
      _finalizeWatchedRange(lastPos);
      _activeWatchedRange = BetterPlayerWatchedRangeMetric(
        rangeId: BetterPlayerTelemetryUtils.generateUuidV4(),
        fromS: positionS,
        toS: positionS,
        level: _currentQualityLevel,
      );
      _lastWatchedPositionS = positionS;
    }
  }

  void _continueWatchedRangeThroughPosition(double positionS) {
    if (_activeWatchedRange == null) {
      _startOrExtendWatchedRange(positionS);
      return;
    }

    _activeWatchedRange = _activeWatchedRange!.copyWith(
      toS: max(_activeWatchedRange!.toS, positionS),
    );
    _lastWatchedPositionS = positionS;
  }

  void _finalizeWatchedRange(double positionS) {
    if (_activeWatchedRange != null) {
      // Never end a range before it started (position reset to 0).
      final range = _activeWatchedRange!.copyWith(
        toS: positionS >= _activeWatchedRange!.fromS
            ? positionS
            : _activeWatchedRange!.toS,
      );
      // Keep range if user actually watched more than 50 milliseconds
      if ((range.toS - range.fromS).abs() > 0.05) {
        _pendingWatchedRanges.add(range);
      }
      _activeWatchedRange = null;
      _lastWatchedPositionS = null;
      _pausedPositionS = null;
    }
  }

  /// Records an AUDIO_LANGUAGE_CHANGED event when the audio language really
  /// changes after the first frame. Before that only the current value is
  /// remembered; it is sent as `none → <code>` with the first frame.
  void handleAudioLanguageChanged({
    String? from,
    required String? to,
    double? positionS,
  }) {
    if (_isDisposed || _session == null) return;

    final effectiveTo = to != null
        ? BetterPlayerTelemetryUtils.normalizeAudioLanguageCode(to)
        : _resolveCurrentAudioLanguage();
    _currentAudioLanguage = effectiveTo;
    if (!_hasPlaybackStarted) return;

    final reported = _reportedAudioLanguage ?? 'none';
    if (reported == effectiveTo) return;
    _reportedAudioLanguage = effectiveTo;

    recordPlaybackEvent(
      type: 'AUDIO_LANGUAGE_CHANGED',
      positionS: positionS ?? _getCurrentPositionSeconds(),
      details: <String, dynamic>{
        'from': reported,
        'to': effectiveTo,
      },
    );
  }

  /// Records a SUBTITLE_CHANGED event when the subtitle really changes after
  /// the first frame. Before that only the current value is remembered.
  void handleSubtitleChanged({
    String? from,
    required String? to,
    bool isFromNone = false,
    bool isToNone = false,
    double? positionS,
  }) {
    if (_isDisposed || _session == null) return;

    final effectiveTo =
        BetterPlayerTelemetryUtils.normalizeSubtitleLanguageCode(
      to,
      isNone: isToNone,
    );
    _currentSubtitleLanguage = effectiveTo;
    if (!_hasPlaybackStarted) return;

    final reported = _reportedSubtitleLanguage ?? 'none';
    if (reported == effectiveTo) return;
    _reportedSubtitleLanguage = effectiveTo;

    recordPlaybackEvent(
      type: 'SUBTITLE_CHANGED',
      positionS: positionS ?? _getCurrentPositionSeconds(),
      details: <String, dynamic>{
        'from': reported,
        'to': effectiveTo,
      },
    );
  }

  /// Records a playback state change event into the pending queue.
  void recordPlaybackEvent({
    required String type,
    required double positionS,
    Map<String, dynamic>? details,
  }) {
    final session = _session;
    if (_isDisposed || session == null) return;

    final sanitizedDetails = BetterPlayerTelemetryUtils.sanitizeEventDetails(
      details,
      maxBytes: session.config.maxEventDetailsBytes,
    );

    final event = BetterPlayerPlaybackEventMetric(
      ts: BetterPlayerTelemetryUtils.formatIsoTimestamp(DateTime.now()),
      type: type,
      positionS: positionS,
      details: sanitizedDetails,
    );

    if (_isDuplicatePlaybackEvent(event)) return;

    _pendingPlaybackEvents.add(event);
  }

  bool _isDuplicatePlaybackEvent(BetterPlayerPlaybackEventMetric event) {
    final now = DateTime.now();
    final lastAt = _lastPlaybackEventAt;
    final isDuplicate = _lastPlaybackEventType == event.type &&
        _lastPlaybackEventPositionS != null &&
        (event.positionS - _lastPlaybackEventPositionS!).abs() <= 0.25 &&
        lastAt != null &&
        now.difference(lastAt) <= _playbackEventDedupWindow &&
        _mapEquals(_lastPlaybackEventDetails, event.details);

    if (isDuplicate) {
      _lastPlaybackEventAt = now;
      return true;
    }

    _lastPlaybackEventType = event.type;
    _lastPlaybackEventPositionS = event.positionS;
    _lastPlaybackEventDetails = Map<String, dynamic>.from(event.details);
    _lastPlaybackEventAt = now;
    return false;
  }

  bool _mapEquals(Map<String, dynamic>? left, Map<String, dynamic>? right) {
    if (identical(left, right)) return true;
    if (left == null || right == null) return false;
    if (left.length != right.length) return false;
    for (final key in left.keys) {
      if (!right.containsKey(key) || right[key] != left[key]) return false;
    }
    return true;
  }

  /// Takes a periodic buffer sample.
  void _takeBufferSample() {
    if (_session == null || !_isControllerPlaying || _isDisposed) return;

    final videoValue = controller.videoPlayerController?.value;
    if (videoValue == null || !videoValue.initialized) return;

    final positionMs = videoValue.position.inMilliseconds;
    final positionS = max(0.0, positionMs / 1000.0);

    // Count only continuous playable media ahead of current position
    double bufferedAheadS = 0.0;
    for (final range in videoValue.buffered) {
      final startMs = range.start.inMilliseconds;
      final endMs = range.end.inMilliseconds;
      if (positionMs >= startMs - 250 && positionMs <= endMs) {
        bufferedAheadS = max(0.0, (endMs - positionMs) / 1000.0);
        break;
      }
    }

    final sample = BetterPlayerBufferSampleMetric(
      ts: BetterPlayerTelemetryUtils.formatIsoTimestamp(DateTime.now()),
      positionS: positionS,
      bufferedAheadS: bufferedAheadS,
    );

    _pendingBufferSamples.add(sample);
  }

  double _getCurrentPositionSeconds() {
    final pos = controller.videoPlayerController?.value.position;
    return max(0.0, (pos?.inMilliseconds ?? 0) / 1000.0);
  }

  // ---------------------------------------------------------------------------
  // Batches
  // ---------------------------------------------------------------------------

  /// Sends at most one batch of the current session. Never runs while another
  /// upload of the session is in flight or before session start succeeded.
  Future<void> _sendPendingBatches({required bool isFinal}) async {
    final session = _session;
    if (session == null || session.inFlightUpload != null) return;

    if (!session.startCompleted) {
      if (session.startFuture == null && !session.startRejected) {
        session.startFuture = _dispatchSessionStart(session);
      }
      return;
    }

    final completer = Completer<void>();
    session.inFlightUpload = completer.future;
    try {
      // 1. Resend a failed batch first, with the SAME batchId and payload.
      final retry = session.retryBatch;
      if (retry != null) {
        if (_isTooOld(retry, session.config)) {
          session.retryBatch = null;
        } else {
          final success = await _uploadBatch(session, retry.batch);
          if (success) session.retryBatch = null;
          return;
        }
      }

      // 2. Snapshot the active watched range, retaining the same rangeId.
      if (_activeWatchedRange != null && identical(_session, session)) {
        final curPos = _getCurrentPositionSeconds();
        if (curPos - _activeWatchedRange!.fromS > 0.05) {
          _pendingWatchedRanges.add(_activeWatchedRange!.copyWith(toS: curPos));
        }
      }

      // 3. Build at most one batch per send call, respecting batch limits.
      final config = session.config;
      final batch = BetterPlayerTelemetryBatch(
        sessionId: session.sessionId,
        batchId: BetterPlayerTelemetryUtils.generateUuidV4(),
        sentAt: BetterPlayerTelemetryUtils.formatIsoTimestamp(DateTime.now()),
        isFinal: isFinal,
        chunkLoads:
            _takeSublist(_pendingChunkLoads, config.maxChunkLoadsPerBatch),
        bufferSamples: _takeSublist(
            _pendingBufferSamples, config.maxBufferSamplesPerBatch),
        watchedRanges: _takeSublist(
            _pendingWatchedRanges, config.maxWatchedRangesPerBatch),
        playbackEvents: _takeSublist(
            _pendingPlaybackEvents, config.maxPlaybackEventsPerBatch),
      );

      if (batch.isEmpty && !isFinal) return;

      final success = await _uploadBatch(session, batch);
      if (!success) {
        session.retryBatch = _PendingBatch(batch);
      }
    } finally {
      session.inFlightUpload = null;
      completer.complete();
    }
  }

  /// Sends everything an ended session still has, split by the batch limits;
  /// only the last batch carries [isFinal]. What cannot be delivered now is
  /// kept and retried later.
  Future<void> _flushEndedSession(
    _SessionCore session, {
    required List<BetterPlayerChunkLoadMetric> chunks,
    required List<BetterPlayerBufferSampleMetric> samples,
    required List<BetterPlayerWatchedRangeMetric> ranges,
    required List<BetterPlayerPlaybackEventMetric> events,
    required bool isFinal,
  }) async {
    // Let a running upload finish first, so no older batch arrives after the
    // final one and a failed one is resent below.
    final inFlight = session.inFlightUpload;
    if (inFlight != null) {
      await inFlight.timeout(_inFlightWaitTimeout, onTimeout: () {});
    }
    final pendingStart = session.startFuture;
    if (!session.startCompleted && pendingStart != null) {
      await pendingStart.timeout(_flushWaitTimeout, onTimeout: () => false);
    }

    final config = session.config;
    final batches = <BetterPlayerTelemetryBatch>[];
    final retry = session.retryBatch;
    session.retryBatch = null;
    if (retry != null && !_isTooOld(retry, config)) {
      batches.add(retry.batch);
    }

    final hasAnyData = chunks.isNotEmpty ||
        samples.isNotEmpty ||
        ranges.isNotEmpty ||
        events.isNotEmpty;
    if (hasAnyData || isFinal) {
      var isFirst = true;
      while (isFirst ||
          chunks.isNotEmpty ||
          samples.isNotEmpty ||
          ranges.isNotEmpty ||
          events.isNotEmpty) {
        isFirst = false;
        final chunkBatch = _takeSublist(chunks, config.maxChunkLoadsPerBatch);
        final sampleBatch =
            _takeSublist(samples, config.maxBufferSamplesPerBatch);
        final rangeBatch =
            _takeSublist(ranges, config.maxWatchedRangesPerBatch);
        final eventBatch =
            _takeSublist(events, config.maxPlaybackEventsPerBatch);
        final isLast = chunks.isEmpty &&
            samples.isEmpty &&
            ranges.isEmpty &&
            events.isEmpty;
        batches.add(BetterPlayerTelemetryBatch(
          sessionId: session.sessionId,
          batchId: BetterPlayerTelemetryUtils.generateUuidV4(),
          sentAt: BetterPlayerTelemetryUtils.formatIsoTimestamp(DateTime.now()),
          isFinal: isFinal && isLast,
          chunkLoads: chunkBatch,
          bufferSamples: sampleBatch,
          watchedRanges: rangeBatch,
          playbackEvents: eventBatch,
        ));
      }
    }
    if (batches.isEmpty) return;

    final delivery = _UndeliveredSession(this, session, batches);
    if (!await _deliver(delivery)) {
      _enqueueUndelivered(delivery);
    }
  }

  /// Delivers [delivery] in order: session start, then each batch with its
  /// own batchId. Returns true when nothing is left to send.
  Future<bool> _deliver(_UndeliveredSession delivery) async {
    final session = delivery.session;
    if (session.startRejected) return true;
    if (!session.startCompleted) {
      await _postSessionStart(session);
      if (session.startRejected) return true;
      if (!session.startCompleted) return false;
    }
    while (delivery.batches.isNotEmpty) {
      final batch = delivery.batches.first;
      var success = await _uploadBatch(session, batch);
      if (!success && session.startCompleted) {
        // One immediate retry with the same batchId.
        success = await _uploadBatch(session, batch);
      }
      if (!success) return false;
      delivery.batches.removeAt(0);
    }
    return true;
  }

  static void _enqueueUndelivered(_UndeliveredSession delivery) {
    _undelivered.add(delivery);
    while (_undelivered.length > _maxUndeliveredSessions) {
      _undelivered.removeAt(0);
    }
    _undeliveredTimer ??= Timer.periodic(
      _undeliveredRetryInterval,
      (_) => _retryUndelivered(),
    );
  }

  static Future<void> _retryUndelivered() async {
    if (_isRetryingUndelivered) return;
    _isRetryingUndelivered = true;
    try {
      for (final delivery in List<_UndeliveredSession>.from(_undelivered)) {
        if (DateTime.now().difference(delivery.createdAt) >
            delivery.session.config.maxBatchAge) {
          _undelivered.remove(delivery);
          continue;
        }
        if (await delivery.owner._deliver(delivery)) {
          _undelivered.remove(delivery);
        } else {
          // Still offline: try the rest on the next round.
          break;
        }
      }
    } catch (e) {
      BetterPlayerUtils.log('Telemetry retry of ended sessions failed: $e');
    } finally {
      _isRetryingUndelivered = false;
      if (_undelivered.isEmpty) {
        _undeliveredTimer?.cancel();
        _undeliveredTimer = null;
      }
    }
  }

  bool _isTooOld(_PendingBatch pending, BetterPlayerTelemetryConfiguration c) {
    return DateTime.now().difference(pending.createdAt) > c.maxBatchAge;
  }

  List<T> _takeSublist<T>(List<T> list, int maxCount) {
    if (list.isEmpty) return <T>[];
    final count = min(list.length, maxCount);
    final sub = list.sublist(0, count);
    list.removeRange(0, count);
    return sub;
  }

  Future<bool> _uploadBatch(
    _SessionCore session,
    BetterPlayerTelemetryBatch batch,
  ) async {
    final config = session.config;
    final targetUri = config.batchEventsUri;
    if (targetUri == null) return false;

    try {
      final jsonBody = jsonEncode(batch.toMap());
      BetterPlayerUtils.log(
        'Telemetry batch POST $targetUri '
        'query parameters: ${jsonEncode(targetUri.queryParametersAll)} '
        'body: $jsonBody',
      );
      final client = config.httpClient ?? _httpClient;
      final request = await client.postUrl(targetUri).timeout(_requestTimeout);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');

      final jsonBytes = utf8.encode(jsonBody);
      request.contentLength = jsonBytes.length;
      request.add(jsonBytes);

      final response = await request.close().timeout(_requestTimeout);
      final statusCode = response.statusCode;
      final responseBody = await response
          .transform(const Utf8Decoder())
          .join()
          .timeout(_requestTimeout);
      BetterPlayerUtils.log(
        'Telemetry batch response POST $targetUri '
        'status: $statusCode body: $responseBody',
      );

      if (statusCode >= 200 && statusCode < 300) {
        return true;
      }

      if (statusCode == 404) {
        // Session not found on backend: register it again, then retry.
        BetterPlayerUtils.log(
          'Telemetry batch 404: Session not found ($responseBody), re-registering session',
        );
        session.startCompleted = false;
        if (session.ended) {
          await _postSessionStart(session);
        } else {
          session.startFuture = _dispatchSessionStart(session);
        }
        return false;
      } else if (statusCode == 400) {
        // Bad request - check fields, don't endlessly retry same invalid batch
        BetterPlayerUtils.log(
          'Telemetry batch rejected with HTTP 400: $responseBody (payload: $batch)',
        );
        return true; // Discard invalid batch
      } else {
        BetterPlayerUtils.log(
          'Telemetry batch upload failed with status $statusCode: $responseBody',
        );
        return false;
      }
    } catch (e) {
      BetterPlayerUtils.log('Telemetry batch upload failed: $e');
      return false;
    }
  }
}

/// A data source that has a telemetry configuration but has not begun.
class _PreparedSession {
  final BetterPlayerTelemetryConfiguration config;
  final BetterPlayerTelemetryData data;
  final String identity;
  String? audioLanguage;
  String? subtitleLanguage;

  _PreparedSession({
    required this.config,
    required this.data,
    required this.identity,
  });
}

/// Network state of one session. Continuations of a session only touch its
/// own core, so a new session can never be changed by an old one.
class _SessionCore {
  final BetterPlayerTelemetryConfiguration config;
  final BetterPlayerTelemetryData data;
  final String sessionId;
  final String startedAt;
  Map<String, dynamic>? startPayload;
  bool startCompleted = false;
  bool startRejected = false;
  bool ended = false;
  Future<bool>? startFuture;
  Timer? startRetryTimer;
  Duration startRetryDelay = const Duration(seconds: 2);
  Future<void>? inFlightUpload;
  _PendingBatch? retryBatch;

  _SessionCore({
    required this.config,
    required this.data,
    required this.sessionId,
    required this.startedAt,
  });
}

/// An ended session whose batches are not delivered yet.
class _UndeliveredSession {
  final BetterPlayerTelemetryManager owner;
  final _SessionCore session;
  final List<BetterPlayerTelemetryBatch> batches;
  final DateTime createdAt = DateTime.now();

  _UndeliveredSession(this.owner, this.session, this.batches);
}

class _PendingBatch {
  final BetterPlayerTelemetryBatch batch;
  final DateTime createdAt = DateTime.now();

  _PendingBatch(this.batch);
}

class _ErrorWindow {
  final DateTime lastSentAt;
  int suppressed = 0;

  _ErrorWindow(this.lastSentAt);
}

class _QualitySnapshot {
  final int level;
  final int? bitrate;
  final int? width;
  final int? height;

  const _QualitySnapshot({
    required this.level,
    this.bitrate,
    this.width,
    this.height,
  });
}

enum _TelemetryPlaybackState {
  unknown,
  playing,
  paused,
}
