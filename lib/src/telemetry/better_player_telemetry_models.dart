import 'dart:io';
import 'package:flutter/foundation.dart';
import 'better_player_telemetry_utils.dart';

/// Configuration for the playback telemetry client.
@immutable
class BetterPlayerTelemetryConfiguration {
  /// Base URL of the telemetry backend API (e.g. "https://telemetry.example.com").
  final String? baseUrl;

  /// Path for the session start endpoint.
  final String startSessionPath;

  /// Path for the batch events upload endpoint.
  final String batchEventsPath;

  /// Optional HTTP headers sent only with session start requests (e.g. auth tokens).
  final Map<String, dynamic>? headers;

  /// Interval between taking buffer samples. Defaults to 5 seconds.
  final Duration bufferSampleInterval;

  /// Interval between sending batches of pending observations. Defaults to 15 seconds.
  final Duration batchSendInterval;

  /// Maximum chunk load items per batch. Defaults to 200.
  final int maxChunkLoadsPerBatch;

  /// Maximum buffer samples per batch. Defaults to 20.
  final int maxBufferSamplesPerBatch;

  /// Maximum watched ranges per batch. Defaults to 100.
  final int maxWatchedRangesPerBatch;

  /// Maximum playback events per batch. Defaults to 100.
  final int maxPlaybackEventsPerBatch;

  /// Maximum allowed size in bytes for event details. Defaults to 8192 (8 KB).
  final int maxEventDetailsBytes;

  /// Whether telemetry reporting is enabled. Defaults to true.
  final bool enabled;

  /// Optional custom HttpClient to use for telemetry requests.
  final HttpClient? httpClient;

  /// A repeated error with the same code is reported at most once per this
  /// interval; the suppressed repeats are added to the next event's `count`.
  /// Defaults to 30 seconds.
  final Duration errorRepeatInterval;

  /// A batch that could not be delivered is dropped once it is older than
  /// this. Defaults to 24 hours.
  final Duration maxBatchAge;

  const BetterPlayerTelemetryConfiguration({
    this.baseUrl,
    this.startSessionPath = 'v1/statistics/sessions/start',
    this.batchEventsPath = 'v1/statistics/events/batch',
    this.headers,
    this.bufferSampleInterval = const Duration(seconds: 5),
    this.batchSendInterval = const Duration(seconds: 15),
    this.maxChunkLoadsPerBatch = 200,
    this.maxBufferSamplesPerBatch = 20,
    this.maxWatchedRangesPerBatch = 100,
    this.maxPlaybackEventsPerBatch = 100,
    this.maxEventDetailsBytes = 8192,
    this.enabled = true,
    this.httpClient,
    this.errorRepeatInterval = const Duration(seconds: 30),
    this.maxBatchAge = const Duration(hours: 24),
  });

  /// Whether this configuration has a valid baseUrl and is enabled.
  bool get hasValue => baseUrl != null && baseUrl!.trim().isNotEmpty && enabled;

  /// Full URL for the start session endpoint, or null if baseUrl is not configured.
  Uri? get startSessionUri {
    final base = baseUrl?.trim();
    if (base == null || base.isEmpty) return null;
    final cleanBase =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final cleanPath = startSessionPath.startsWith('/')
        ? startSessionPath
        : '/$startSessionPath';
    return Uri.parse('$cleanBase$cleanPath');
  }

  /// Full URL for the batch events endpoint, or null if baseUrl is not configured.
  Uri? get batchEventsUri {
    final base = baseUrl?.trim();
    if (base == null || base.isEmpty) return null;
    final cleanBase =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    final cleanPath =
        batchEventsPath.startsWith('/') ? batchEventsPath : '/$batchEventsPath';
    return Uri.parse('$cleanBase$cleanPath');
  }
}

/// Metadata provided for the viewing session.
@immutable
class BetterPlayerTelemetryData {
  /// Playable episode ID (integer >= 1).
  final dynamic episodeId;

  /// Live TV channel ID (integer >= 1). A session with a channel ID and no
  /// episode ID is a live channel session.
  final dynamic channelId;

  /// Live event ID (integer >= 1), only when the channel was opened from a
  /// live event's screen. Sent only together with [channelId].
  final dynamic eventId;

  /// Platform name (e.g. 'ANDROID', 'IOS', 'WEB').
  final String? platform;

  /// Device type (e.g. 'MOBILE', 'TABLET', 'DESKTOP').
  final String? deviceType;

  /// Operating system name.
  final String? os;

  /// Client user IP address. Kept for API compatibility only: it is never
  /// sent, the gateway adds the IP itself.
  final String? ip;

  /// "<manufacturer> <model>" of the device (max 100 characters). Filled in
  /// automatically on Android when not provided.
  final String? deviceModel;

  /// Streaming file URL (scheme + host + path, stripped of query tokens).
  final String? fileUrl;

  /// Additional custom metadata.
  final Map<String, dynamic>? extra;

  const BetterPlayerTelemetryData({
    this.episodeId,
    this.channelId,
    this.eventId,
    this.platform,
    this.deviceType,
    this.os,
    this.ip,
    this.fileUrl,
    this.deviceModel,
    this.extra,
  });

  BetterPlayerTelemetryData copyWith({
    String? os,
    String? deviceModel,
    String? fileUrl,
  }) {
    return BetterPlayerTelemetryData(
      episodeId: episodeId,
      channelId: channelId,
      eventId: eventId,
      platform: platform,
      deviceType: deviceType,
      os: os ?? this.os,
      ip: ip,
      fileUrl: fileUrl ?? this.fileUrl,
      deviceModel: deviceModel ?? this.deviceModel,
      extra: extra,
    );
  }

  /// Whether this is a live channel session: a valid channel ID and no
  /// valid episode ID.
  bool get isLiveChannel =>
      BetterPlayerTelemetryUtils.normalizeEpisodeId(episodeId) == null &&
      BetterPlayerTelemetryUtils.normalizeEpisodeId(channelId) != null;

  /// Whether any metadata property is populated with a value.
  bool get hasValue =>
      episodeId != null ||
      channelId != null ||
      eventId != null ||
      (platform != null && platform!.trim().isNotEmpty) ||
      (deviceType != null && deviceType!.trim().isNotEmpty) ||
      (os != null && os!.trim().isNotEmpty) ||
      (ip != null && ip!.trim().isNotEmpty) ||
      (fileUrl != null && fileUrl!.trim().isNotEmpty) ||
      (deviceModel != null && deviceModel!.trim().isNotEmpty) ||
      (extra != null && extra!.isNotEmpty);

  Map<String, dynamic> toMap({
    required String sessionId,
    required String startedAt,
  }) {
    final effectiveEpisodeId =
        BetterPlayerTelemetryUtils.normalizeEpisodeId(episodeId);
    // The gateway rejects episodeId together with channelId, and eventId
    // without channelId: a live channel sends channelId (+ eventId) only.
    final effectiveChannelId = effectiveEpisodeId == null
        ? BetterPlayerTelemetryUtils.normalizeEpisodeId(channelId)
        : null;
    final effectiveEventId = effectiveChannelId != null
        ? BetterPlayerTelemetryUtils.normalizeEpisodeId(eventId)
        : null;
    final effectivePlatform =
        BetterPlayerTelemetryUtils.normalizePlatform(platform);
    final effectiveDeviceType =
        BetterPlayerTelemetryUtils.normalizeDeviceType(deviceType);
    final normalizedOs = BetterPlayerTelemetryUtils.normalizeOs(os);
    final effectiveOs = normalizedOs.isNotEmpty
        ? BetterPlayerTelemetryUtils.clamp(normalizedOs, 100)
        : BetterPlayerTelemetryUtils.getOperatingSystem();
    final effectiveFileUrl = BetterPlayerTelemetryUtils.cleanFileUrl(fileUrl);
    final effectiveDeviceModel = deviceModel?.trim();

    final map = <String, dynamic>{
      'sessionId': sessionId,
      if (effectiveEpisodeId != null) 'episodeId': effectiveEpisodeId,
      if (effectiveChannelId != null) 'channelId': effectiveChannelId,
      if (effectiveEventId != null) 'eventId': effectiveEventId,
      'platform': effectivePlatform,
      'deviceType': effectiveDeviceType,
      if (effectiveOs.isNotEmpty) 'os': effectiveOs,
      'startedAt': startedAt,
      if (effectiveFileUrl != null && effectiveFileUrl.isNotEmpty)
        'fileUrl': effectiveFileUrl,
      if (effectiveDeviceModel != null && effectiveDeviceModel.isNotEmpty)
        'deviceModel':
            BetterPlayerTelemetryUtils.clamp(effectiveDeviceModel, 100),
    };

    if (extra != null && extra!.isNotEmpty) {
      for (final entry in extra!.entries) {
        final keyLower = entry.key.toLowerCase();
        // Do not send userId, profileId, accountId or ip in the JSON body:
        // the gateway adds them.
        if (keyLower == 'userid' ||
            keyLower == 'episodeid' ||
            keyLower == 'channelid' ||
            keyLower == 'eventid' ||
            keyLower == 'profileid' ||
            keyLower == 'user_id' ||
            keyLower == 'profile_id' ||
            keyLower == 'accountid' ||
            keyLower == 'account_id' ||
            keyLower == 'ip') {
          continue;
        }
        map[entry.key] = entry.value;
      }
    }

    return map;
  }
}

/// A completed video-segment chunk download measurement.
@immutable
class BetterPlayerChunkLoadMetric {
  /// Segment sequence number.
  final int chunkSeq;

  /// Quality index/level (required non-negative integer quality index).
  final int level;

  /// Video interval start in seconds.
  final double startS;

  /// Video interval end in seconds.
  final double endS;

  /// Downloaded bytes.
  final int bytes;

  /// Download duration in milliseconds.
  final int loadMs;

  /// Segment filename/source, without path or query parameters.
  final String source;

  /// Completion timestamp (UTC ISO string).
  final String loadedAt;

  const BetterPlayerChunkLoadMetric({
    required this.chunkSeq,
    this.level = 0,
    required this.startS,
    required this.endS,
    required this.bytes,
    required this.loadMs,
    required this.source,
    required this.loadedAt,
  });

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'chunkSeq': chunkSeq,
      'level': level,
      'startS': startS,
      'endS': endS,
      'bytes': bytes,
      'loadMs': loadMs,
      'source': source,
      'loadedAt': loadedAt,
    };
  }
}

/// A buffer measurement taken periodically during playback.
@immutable
class BetterPlayerBufferSampleMetric {
  /// Timestamp of the sample (UTC ISO string).
  final String ts;

  /// Current video playback position in seconds.
  final double positionS;

  /// Playable seconds already downloaded ahead in continuous range.
  final double bufferedAheadS;

  /// Live channels only: seconds behind the live edge, rounded to 0.1 s.
  /// Left out when unknown.
  final double? liveLatencyS;

  const BetterPlayerBufferSampleMetric({
    required this.ts,
    required this.positionS,
    required this.bufferedAheadS,
    this.liveLatencyS,
  });

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'ts': ts,
      'positionS': positionS,
      'bufferedAheadS': bufferedAheadS,
      if (liveLatencyS != null) 'liveLatencyS': liveLatencyS,
    };
  }
}

/// An interval that was genuinely watched by the user.
@immutable
class BetterPlayerWatchedRangeMetric {
  /// Unique identifier for this continuous watching interval (UUID v4).
  final String rangeId;

  /// Starting position in seconds.
  final double fromS;

  /// Ending position in seconds.
  final double toS;

  /// Optional quality level.
  final int? level;

  const BetterPlayerWatchedRangeMetric({
    required this.rangeId,
    required this.fromS,
    required this.toS,
    this.level,
  });

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'rangeId': rangeId,
      'fromS': fromS,
      'toS': toS,
      if (level != null) 'level': level,
    };
  }

  BetterPlayerWatchedRangeMetric copyWith({
    double? toS,
    int? level,
  }) {
    return BetterPlayerWatchedRangeMetric(
      rangeId: rangeId,
      fromS: fromS,
      toS: toS ?? this.toS,
      level: level ?? this.level,
    );
  }
}

/// Standard player state change event.
@immutable
class BetterPlayerPlaybackEventMetric {
  /// Timestamp when event occurred (UTC ISO string).
  final String ts;

  /// Type of the event.
  /// Standard types: PLAYBACK_STARTED, PAUSE, RESUME, SEEK, STALL_START,
  /// STALL_END, QUALITY_SWITCH, ERROR, CDN_SWITCH, ENDED,
  /// AUDIO_LANGUAGE_CHANGED, SUBTITLE_CHANGED.
  final String type;

  /// Video position in seconds when the event happened.
  final double positionS;

  /// Context details object (max 8 KB, no tokens or secret URLs).
  final Map<String, dynamic> details;

  const BetterPlayerPlaybackEventMetric({
    required this.ts,
    required this.type,
    required this.positionS,
    this.details = const <String, dynamic>{},
  });

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'ts': ts,
      'type': type,
      'positionS': positionS,
      'details': details,
    };
  }
}

/// A batch of telemetry observations.
@immutable
class BetterPlayerTelemetryBatch {
  /// The ID for this viewing session (UUID v4).
  final String sessionId;

  /// A new UUID v4 for each new batch.
  final String batchId;

  /// UTC timestamp when the batch was prepared.
  final String sentAt;

  /// false normally; true when this session ends.
  final bool isFinal;

  /// Completed video-segment downloads.
  final List<BetterPlayerChunkLoadMetric> chunkLoads;

  /// Buffer measurements.
  final List<BetterPlayerBufferSampleMetric> bufferSamples;

  /// Intervals that actually played.
  final List<BetterPlayerWatchedRangeMetric> watchedRanges;

  /// Player events and their context.
  final List<BetterPlayerPlaybackEventMetric> playbackEvents;

  const BetterPlayerTelemetryBatch({
    required this.sessionId,
    required this.batchId,
    required this.sentAt,
    required this.isFinal,
    this.chunkLoads = const [],
    this.bufferSamples = const [],
    this.watchedRanges = const [],
    this.playbackEvents = const [],
  });

  bool get isEmpty =>
      chunkLoads.isEmpty &&
      bufferSamples.isEmpty &&
      watchedRanges.isEmpty &&
      playbackEvents.isEmpty;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'sessionId': sessionId,
      'batchId': batchId,
      'sentAt': sentAt,
      'isFinal': isFinal,
      'chunkLoads': chunkLoads.map((c) => c.toMap()).toList(),
      'bufferSamples': bufferSamples.map((b) => b.toMap()).toList(),
      'watchedRanges': watchedRanges.map((w) => w.toMap()).toList(),
      'playbackEvents': playbackEvents.map((e) => e.toMap()).toList(),
    };
  }
}
