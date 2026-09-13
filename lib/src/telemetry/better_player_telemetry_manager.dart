import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:better_player/src/configuration/better_player_event.dart';
import 'package:better_player/src/configuration/better_player_event_type.dart';
import 'package:better_player/src/configuration/better_player_network_log.dart';
import 'package:better_player/src/core/better_player_controller.dart';
import 'package:better_player/src/core/better_player_utils.dart';

import 'better_player_telemetry_models.dart';
import 'better_player_telemetry_utils.dart';

/// Manages telemetry collection, buffering, and batch uploading according to
/// the Playback Telemetry Client Guide.
class BetterPlayerTelemetryManager {
  final BetterPlayerController controller;

  /// The unique session ID for the currently active viewing session.
  /// A fresh UUID v4 is generated on each startSession() call.
  String _sessionId;

  BetterPlayerTelemetryConfiguration? _configuration;
  BetterPlayerTelemetryData? _telemetryData;
  String? _sessionStartedAt;

  final HttpClient _httpClient;

  // Timers
  Timer? _bufferSampleTimer;
  Timer? _batchSendTimer;
  Timer? _sessionStartRetryTimer;
  Duration _sessionStartRetryDelay = const Duration(seconds: 2);

  // Session state
  bool _isDisposed = false;
  bool _sessionStartInitiated = false;
  bool _sessionStartCompleted = false;
  bool _isSendingBatch = false;
  bool _hasPlaybackStarted = false;
  int _chunkSeqCounter = 0;
  String? _lastCdnHost;

  // Active watched range tracking
  BetterPlayerWatchedRangeMetric? _activeWatchedRange;
  double? _lastWatchedPositionS;
  int? _currentQualityLevel;

  // Queues for pending observations
  final List<BetterPlayerChunkLoadMetric> _pendingChunkLoads = [];
  final List<BetterPlayerBufferSampleMetric> _pendingBufferSamples = [];
  final List<BetterPlayerWatchedRangeMetric> _pendingWatchedRanges = [];
  final List<BetterPlayerPlaybackEventMetric> _pendingPlaybackEvents = [];

  // Temporary retry batch (holds exact payload and batchId if sending failed)
  BetterPlayerTelemetryBatch? _retryBatch;

  BetterPlayerTelemetryManager(this.controller, {HttpClient? httpClient})
      : _sessionId = BetterPlayerTelemetryUtils.generateUuidV4(),
        _httpClient = httpClient ??
            (HttpClient()..connectionTimeout = const Duration(seconds: 5));

  /// Gets the unique session ID for the currently active viewing session.
  String get sessionId => _sessionId;

  /// Gets the current telemetry configuration.
  BetterPlayerTelemetryConfiguration? get configuration => _configuration;

  /// Gets the current session telemetry data.
  BetterPlayerTelemetryData? get telemetryData => _telemetryData;

  /// Whether the session start request has succeeded on the server.
  bool get isSessionStartCompleted => _sessionStartCompleted;

  /// Stops and clears the current telemetry session.
  /// If [flushPrevious] is true and a session was active, attempts a final upload.
  Future<void> stopSession({bool flushPrevious = true}) async {
    _bufferSampleTimer?.cancel();
    _bufferSampleTimer = null;
    _batchSendTimer?.cancel();
    _batchSendTimer = null;
    _sessionStartRetryTimer?.cancel();
    _sessionStartRetryTimer = null;

    if (flushPrevious &&
        _configuration?.hasValue == true &&
        (_sessionStartCompleted || _hasPendingData)) {
      try {
        _finalizeWatchedRange(_getCurrentPositionSeconds());
        await _sendPendingBatches(isFinal: true)
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    }

    _configuration = null;
    _telemetryData = null;
    _sessionStartInitiated = false;
    _sessionStartCompleted = false;
    _hasPlaybackStarted = false;
    _chunkSeqCounter = 0;
    _lastCdnHost = null;
    _activeWatchedRange = null;
    _lastWatchedPositionS = null;
    _currentQualityLevel = null;
    _retryBatch = null;
    _pendingChunkLoads.clear();
    _pendingBufferSamples.clear();
    _pendingWatchedRanges.clear();
    _pendingPlaybackEvents.clear();
  }

  /// Initializes or updates the viewing session telemetry with configuration and data.
  void startSession({
    BetterPlayerTelemetryConfiguration? configuration,
    BetterPlayerTelemetryData? telemetryData,
  }) {
    // If a session is already in progress, stop and flush it first
    if (_configuration?.hasValue == true &&
        (_sessionStartCompleted || _hasPendingData)) {
      stopSession(flushPrevious: true);
    } else {
      stopSession(flushPrevious: false);
    }

    if (configuration == null || !configuration.hasValue) {
      return;
    }

    _configuration = configuration;
    _telemetryData = telemetryData;
    _sessionId = BetterPlayerTelemetryUtils.generateUuidV4();
    _sessionStartedAt =
        BetterPlayerTelemetryUtils.formatIsoTimestamp(DateTime.now());
    _sessionStartRetryDelay = const Duration(seconds: 2);

    _startTimers();
    _dispatchSessionStart();
  }

  void _startTimers() {
    _bufferSampleTimer?.cancel();
    _batchSendTimer?.cancel();

    final config = _configuration;
    if (config == null || !config.hasValue) return;

    _bufferSampleTimer = Timer.periodic(
      config.bufferSampleInterval,
      (_) => _takeBufferSample(),
    );

    _batchSendTimer = Timer.periodic(
      config.batchSendInterval,
      (_) => _sendPendingBatches(isFinal: false),
    );
  }

  /// Dispatches POST /api/v1/client/statistics/sessions/start
  Future<void> _dispatchSessionStart() async {
    final config = _configuration;
    final data = _telemetryData;
    if (config == null ||
        !config.hasValue ||
        _isDisposed ||
        _sessionStartCompleted) {
      return;
    }

    final targetUri = config.startSessionUri;
    if (targetUri == null) {
      return;
    }

    _sessionStartInitiated = true;
    final startedAt = _sessionStartedAt ??
        BetterPlayerTelemetryUtils.formatIsoTimestamp(DateTime.now());
    _sessionStartedAt = startedAt;

    final payload = (data ?? const BetterPlayerTelemetryData()).toMap(
      sessionId: sessionId,
      startedAt: startedAt,
    );

    try {
      final client = config.httpClient ?? _httpClient;
      final request = await client.postUrl(targetUri);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      config.headers?.forEach((key, value) {
        request.headers.set(key, value);
      });

      final jsonBytes = utf8.encode(jsonEncode(payload));
      request.contentLength = jsonBytes.length;
      request.add(jsonBytes);

      final response = await request.close();
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _sessionStartCompleted = true;
        _sessionStartRetryTimer?.cancel();
        _sessionStartRetryDelay = const Duration(seconds: 2);
        // Trigger immediate send of any observations queued during session start
        _sendPendingBatches(isFinal: false);
      } else if (response.statusCode == 400 || response.statusCode == 409) {
        BetterPlayerUtils.log(
          'Telemetry session start rejected with status ${response.statusCode}. Halting retries.',
        );
        _sessionStartRetryTimer?.cancel();
      } else {
        _scheduleSessionStartRetry();
      }
      await response.drain<void>();
    } catch (e) {
      BetterPlayerUtils.log('Telemetry session start failed: $e');
      _scheduleSessionStartRetry();
    }
  }

  void _scheduleSessionStartRetry() {
    if (_isDisposed ||
        _sessionStartCompleted ||
        _configuration?.hasValue != true) return;
    _sessionStartRetryTimer?.cancel();
    _sessionStartRetryTimer = Timer(_sessionStartRetryDelay, () {
      _sessionStartRetryDelay = Duration(
        seconds: min(30, _sessionStartRetryDelay.inSeconds * 2),
      );
      _dispatchSessionStart();
    });
  }

  /// Handles incoming player events from [BetterPlayerController].
  void handlePlayerEvent(BetterPlayerEvent event) {
    if (_configuration?.hasValue != true || _isDisposed) return;

    final currentPositionS = _getCurrentPositionSeconds();

    switch (event.betterPlayerEventType) {
      case BetterPlayerEventType.play:
        _handlePlay(currentPositionS);
        break;

      case BetterPlayerEventType.pause:
        _handlePause(currentPositionS);
        break;

      case BetterPlayerEventType.seekTo:
        final toDuration = event.parameters?['duration'] as Duration?;
        _handleSeek(currentPositionS, toDuration);
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

      case BetterPlayerEventType.exception:
        _handleError(currentPositionS, event.parameters?['exception']);
        break;

      case BetterPlayerEventType.progress:
        _handleProgress(currentPositionS);
        break;

      default:
        break;
    }
  }

  /// Ingests network logs and captures video chunk loads.
  void handleNetworkLog(BetterPlayerNetworkLog log) {
    if (_configuration?.hasValue != true || _isDisposed) return;

    // Detect CDN switch on media streams / manifests
    if (log.isHls || log.isMediaChunk) {
      try {
        final uri = Uri.parse(log.url);
        if (uri.host.isNotEmpty) {
          if (_lastCdnHost != null && _lastCdnHost != uri.host) {
            recordPlaybackEvent(
              type: 'CDN_SWITCH',
              positionS: _getCurrentPositionSeconds(),
              details: <String, dynamic>{
                'previousHost': _lastCdnHost,
                'newHost': uri.host,
              },
            );
          }
          _lastCdnHost = uri.host;
        }
      } catch (_) {}
    }

    // Ingest completed media chunk segment
    // Rule: Report real measurements. Do not send invented or incomplete segment loads.
    if (log.isMediaChunk &&
        log.phase == BetterPlayerNetworkLogPhase.completed &&
        log.mediaStartTimeMs != null &&
        log.mediaEndTimeMs != null) {
      final startS = max(0.0, log.mediaStartTimeMs! / 1000.0);
      final endS = max(startS, log.mediaEndTimeMs! / 1000.0);
      final chunkSeq = _chunkSeqCounter++;

      final chunkMetric = BetterPlayerChunkLoadMetric(
        chunkSeq: chunkSeq,
        level: _resolveQualityLevelIndex(log.bitrate, log.height),
        startS: startS,
        endS: endS,
        bytes: max(0, log.bytesLoaded),
        loadMs: max(0, log.durationMs),
        loadedAt: BetterPlayerTelemetryUtils.formatIsoTimestamp(log.timestamp),
      );

      _pendingChunkLoads.add(chunkMetric);
    }
  }

  int _resolveQualityLevelIndex(int? bitrate, int? height) {
    final tracks = controller.betterPlayerAsmsTracks;
    if (tracks.isNotEmpty) {
      for (int i = 0; i < tracks.length; i++) {
        final track = tracks[i];
        if (bitrate != null && track.bitrate == bitrate) {
          return i;
        }
        if (height != null && track.height == height) {
          return i;
        }
      }
    }
    return _currentQualityLevel ?? 0;
  }

  bool get _isControllerPlaying {
    try {
      if (controller.videoPlayerController == null) return false;
      return controller.isPlaying() == true;
    } catch (_) {
      return false;
    }
  }

  void _handlePlay(double positionS) {
    if (_hasPlaybackStarted) {
      recordPlaybackEvent(
        type: 'RESUME',
        positionS: positionS,
      );
    }
    _startOrExtendWatchedRange(positionS);
  }

  void _handlePause(double positionS) {
    _finalizeWatchedRange(positionS);
    recordPlaybackEvent(
      type: 'PAUSE',
      positionS: positionS,
    );
  }

  void _handleSeek(double currentPositionS, Duration? toDuration) {
    _finalizeWatchedRange(currentPositionS);
    final toPositionS = (toDuration?.inMilliseconds ?? 0) / 1000.0;

    recordPlaybackEvent(
      type: 'SEEK',
      positionS: currentPositionS,
      details: <String, dynamic>{
        'fromS': currentPositionS,
        'toS': toPositionS,
      },
    );

    if (_isControllerPlaying) {
      _startOrExtendWatchedRange(toPositionS);
    }
  }

  void _handleStallStart(double positionS) {
    // Only record stall if video playback genuinely started and was playing
    if (_hasPlaybackStarted && _isControllerPlaying) {
      _finalizeWatchedRange(positionS);
      recordPlaybackEvent(
        type: 'STALL_START',
        positionS: positionS,
      );
    }
  }

  void _handleStallEnd(double positionS) {
    if (_hasPlaybackStarted) {
      recordPlaybackEvent(
        type: 'STALL_END',
        positionS: positionS,
      );

      if (_isControllerPlaying) {
        _startOrExtendWatchedRange(positionS);
      }
    }
  }

  void _handleQualitySwitch(double positionS, BetterPlayerEvent event) {
    _finalizeWatchedRange(positionS);

    final track = controller.betterPlayerAsmsTrack;
    final tracks = controller.betterPlayerAsmsTracks;
    int? newLevelIndex;
    if (track != null && tracks.isNotEmpty) {
      final idx = tracks.indexOf(track);
      if (idx != -1) newLevelIndex = idx;
    }
    newLevelIndex ??= (tracks.isNotEmpty ? 0 : 0);

    final oldLevelIndex = _currentQualityLevel ?? 0;
    _currentQualityLevel = newLevelIndex;

    recordPlaybackEvent(
      type: 'QUALITY_SWITCH',
      positionS: positionS,
      details: <String, dynamic>{
        'fromLevel': oldLevelIndex,
        'toLevel': newLevelIndex,
        if (track?.bitrate != null) 'bitrate': track!.bitrate,
        if (track?.width != null) 'width': track!.width,
        if (track?.height != null) 'height': track!.height,
      },
    );

    if (_isControllerPlaying) {
      _startOrExtendWatchedRange(positionS);
    }
  }

  void _handleEnded(double positionS) {
    _finalizeWatchedRange(positionS);
    recordPlaybackEvent(
      type: 'ENDED',
      positionS: positionS,
    );
    // Send final observations
    _sendPendingBatches(isFinal: true);
  }

  void _handleError(double positionS, dynamic error) {
    recordPlaybackEvent(
      type: 'ERROR',
      positionS: positionS,
      details: <String, dynamic>{
        'code': 'PLAYBACK_ERROR',
        'message': error?.toString() ?? 'Playback error',
        'fatal': false,
      },
    );
  }

  void _handleProgress(double currentPositionS) {
    if (!_isControllerPlaying) return;

    // First frame played — record PLAYBACK_STARTED once per session
    if (!_hasPlaybackStarted && currentPositionS >= 0.0) {
      _hasPlaybackStarted = true;
      recordPlaybackEvent(
        type: 'PLAYBACK_STARTED',
        positionS: currentPositionS,
      );
    }

    _startOrExtendWatchedRange(currentPositionS);
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

    // Normal forward playback progression (e.g. 0.0s to 2.5s)
    if (delta >= 0.0 && delta <= 2.5) {
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

  void _finalizeWatchedRange(double positionS) {
    if (_activeWatchedRange != null) {
      final range = _activeWatchedRange!.copyWith(toS: positionS);
      // Keep range if user actually watched more than 50 milliseconds
      if ((range.toS - range.fromS).abs() > 0.05) {
        _pendingWatchedRanges.add(range);
      }
      _activeWatchedRange = null;
      _lastWatchedPositionS = null;
    }
  }

  /// Records a playback state change event into the pending queue.
  void recordPlaybackEvent({
    required String type,
    required double positionS,
    Map<String, dynamic>? details,
  }) {
    if (_configuration?.hasValue != true || _isDisposed) return;

    final maxBytes = _configuration?.maxEventDetailsBytes ?? 8192;
    final sanitizedDetails = BetterPlayerTelemetryUtils.sanitizeEventDetails(
      details,
      maxBytes: maxBytes,
    );

    final event = BetterPlayerPlaybackEventMetric(
      ts: BetterPlayerTelemetryUtils.formatIsoTimestamp(DateTime.now()),
      type: type,
      positionS: positionS,
      details: sanitizedDetails,
    );

    _pendingPlaybackEvents.add(event);
  }

  /// Takes a periodic buffer sample.
  void _takeBufferSample() {
    if (_configuration?.hasValue != true ||
        !_isControllerPlaying ||
        _isDisposed) return;

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

  /// Prepares and sends batches of observations.
  Future<void> _sendPendingBatches({required bool isFinal}) async {
    final config = _configuration;
    if (config == null || !config.hasValue || _isSendingBatch) return;

    // Wait until session start has succeeded
    if (!_sessionStartCompleted) {
      if (!_sessionStartInitiated) {
        _dispatchSessionStart();
      }
      return;
    }

    _isSendingBatch = true;
    try {
      // 1. If we have a previous failed batch, retry it with the SAME batchId and payload
      if (_retryBatch != null) {
        final success = await _uploadBatchPayload(_retryBatch!);
        if (success) {
          _retryBatch = null;
        } else {
          // Keep retryBatch and do not send newer batches yet
          _isSendingBatch = false;
          return;
        }
      }

      // 2. Handle active watched range
      if (isFinal) {
        _finalizeWatchedRange(_getCurrentPositionSeconds());
      } else if (_activeWatchedRange != null) {
        final curPos = _getCurrentPositionSeconds();
        if ((curPos - _activeWatchedRange!.fromS).abs() > 0.05) {
          // Snapshot active watched range into this batch, retaining same rangeId
          _pendingWatchedRanges.add(_activeWatchedRange!.copyWith(toS: curPos));
        }
      }

      // 3. Partition queues respecting batch limits
      while (_hasPendingData || (isFinal && _pendingPlaybackEvents.isEmpty)) {
        final chunkBatch =
            _takeSublist(_pendingChunkLoads, config.maxChunkLoadsPerBatch);
        final bufferBatch =
            _takeSublist(_pendingBufferSamples, config.maxBufferSamplesPerBatch);
        final watchedBatch = _takeSublist(
            _pendingWatchedRanges, config.maxWatchedRangesPerBatch);
        final eventsBatch = _takeSublist(
            _pendingPlaybackEvents, config.maxPlaybackEventsPerBatch);

        final bool thisBatchIsFinal = isFinal && !_hasPendingData;

        final batch = BetterPlayerTelemetryBatch(
          sessionId: sessionId,
          batchId: BetterPlayerTelemetryUtils.generateUuidV4(),
          sentAt:
              BetterPlayerTelemetryUtils.formatIsoTimestamp(DateTime.now()),
          isFinal: thisBatchIsFinal,
          chunkLoads: chunkBatch,
          bufferSamples: bufferBatch,
          watchedRanges: watchedBatch,
          playbackEvents: eventsBatch,
        );

        if (batch.isEmpty && !thisBatchIsFinal) {
          break;
        }

        final success = await _uploadBatchPayload(batch);
        if (!success) {
          // Save batch for safe retry with identical batchId & payload
          _retryBatch = batch;
          break;
        }

        if (thisBatchIsFinal) {
          break;
        }
      }
    } finally {
      _isSendingBatch = false;
    }
  }

  bool get _hasPendingData =>
      _pendingChunkLoads.isNotEmpty ||
      _pendingBufferSamples.isNotEmpty ||
      _pendingWatchedRanges.isNotEmpty ||
      _pendingPlaybackEvents.isNotEmpty;

  List<T> _takeSublist<T>(List<T> list, int maxCount) {
    if (list.isEmpty) return <T>[];
    final count = min(list.length, maxCount);
    final sub = list.sublist(0, count);
    list.removeRange(0, count);
    return sub;
  }

  Future<bool> _uploadBatchPayload(BetterPlayerTelemetryBatch batch) async {
    final config = _configuration;
    if (config == null || !config.hasValue) return false;

    final targetUri = config.batchEventsUri;
    if (targetUri == null) return false;

    try {
      final client = config.httpClient ?? _httpClient;
      final request = await client.postUrl(targetUri);
      request.headers.contentType = ContentType.json;
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      config.headers?.forEach((key, value) {
        request.headers.set(key, value);
      });

      final jsonBytes = utf8.encode(jsonEncode(batch.toMap()));
      request.contentLength = jsonBytes.length;
      request.add(jsonBytes);

      final response = await request.close();
      final statusCode = response.statusCode;
      await response.drain<void>();

      if (statusCode >= 200 && statusCode < 300) {
        return true;
      } else if (statusCode == 404) {
        // Session not found on backend! Re-dispatch session start then retry
        BetterPlayerUtils.log(
          'Telemetry batch 404: Session not found, re-registering session',
        );
        _sessionStartCompleted = false;
        _dispatchSessionStart();
        return false;
      } else if (statusCode == 400) {
        // Bad request - check fields, don't endlessly retry same invalid batch
        BetterPlayerUtils.log('Telemetry batch rejected with HTTP 400: $batch');
        return true; // Discard invalid batch
      } else {
        return false;
      }
    } catch (e) {
      BetterPlayerUtils.log('Telemetry batch upload failed: $e');
      return false;
    }
  }

  /// Flushes pending data and terminates the telemetry manager.
  Future<void> dispose({bool isFinal = true}) async {
    if (_isDisposed) return;
    _isDisposed = true;

    _bufferSampleTimer?.cancel();
    _batchSendTimer?.cancel();
    _sessionStartRetryTimer?.cancel();

    _finalizeWatchedRange(_getCurrentPositionSeconds());

    if (_configuration?.hasValue == true &&
        (_sessionStartCompleted || _hasPendingData)) {
      // Best effort final upload
      try {
        await _sendPendingBatches(isFinal: isFinal)
            .timeout(const Duration(seconds: 3));
      } catch (_) {}
    }

    _httpClient.close(force: true);
  }
}
