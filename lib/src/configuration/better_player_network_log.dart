import 'package:flutter/foundation.dart';

/// The lifecycle phase of a network request / video chunk load.
enum BetterPlayerNetworkLogPhase {
  /// The request has started.
  start,

  /// The request completed successfully.
  completed,

  /// The request was canceled before completion.
  canceled,

  /// The request encountered an error or failed.
  error,
}

/// The type of data being loaded over the network.
enum BetterPlayerNetworkDataType {
  /// Master or Media playlist/manifest (e.g. .m3u8, .mpd).
  manifest,

  /// Media chunk segment (video/audio chunk, e.g. .ts, .m4s, fmp4).
  mediaSegment,

  /// Initialization segment (e.g. init.mp4, init.m4s).
  initialization,

  /// DRM license or encryption key request (e.g. .key, Widevine/FairPlay license).
  drmKey,

  /// External or embedded subtitle segment (e.g. .vtt, .srt).
  subtitles,

  /// Unknown or generic network request.
  unknown,
}

/// Model representing a video chunk or network request log entry.
/// Similar to browser Network tab entries.
@immutable
class BetterPlayerNetworkLog {
  /// Unique identifier or task ID for the network request.
  final String id;

  /// The full requested URL (chunk, playlist, manifest, key, etc.).
  final String url;

  /// HTTP Method (GET, POST, HEAD, etc.).
  final String httpMethod;

  /// Current phase of the request.
  final BetterPlayerNetworkLogPhase phase;

  /// Classification of the data type loaded.
  final BetterPlayerNetworkDataType dataType;

  /// Track type if available ('video', 'audio', 'text', 'unknown').
  final String? trackType;

  /// HTTP response status code (e.g. 200, 206, 404), if available.
  final int? statusCode;

  /// Total number of bytes loaded/transferred.
  final int bytesLoaded;

  /// Duration taken to complete the load in milliseconds.
  final int durationMs;

  /// Timestamp of the log event.
  final DateTime timestamp;

  /// Remote server IP or hostname if provided by the platform.
  final String? serverAddress;

  /// Bitrate of the media track in bits per second, if applicable.
  final int? bitrate;

  /// Track video width in pixels, if applicable.
  final int? width;

  /// Track video height in pixels, if applicable.
  final int? height;

  /// Media segment start time in milliseconds, if applicable.
  final int? mediaStartTimeMs;

  /// Media segment end time in milliseconds, if applicable.
  final int? mediaEndTimeMs;

  /// Error message or failure description, if the request failed.
  final String? errorMessage;

  /// Additional raw metadata sent from native player.
  final Map<String, dynamic>? extra;

  const BetterPlayerNetworkLog({
    required this.id,
    required this.url,
    this.httpMethod = 'GET',
    required this.phase,
    this.dataType = BetterPlayerNetworkDataType.unknown,
    this.trackType,
    this.statusCode,
    this.bytesLoaded = 0,
    this.durationMs = 0,
    required this.timestamp,
    this.serverAddress,
    this.bitrate,
    this.width,
    this.height,
    this.mediaStartTimeMs,
    this.mediaEndTimeMs,
    this.errorMessage,
    this.extra,
  });

  /// Factory constructor to parse native map sent via EventChannel.
  factory BetterPlayerNetworkLog.fromMap(Map<String, dynamic> map) {
    final String phaseStr =
        (map['phase'] as String?)?.toLowerCase() ?? 'completed';
    final BetterPlayerNetworkLogPhase phase;
    switch (phaseStr) {
      case 'start':
      case 'started':
        phase = BetterPlayerNetworkLogPhase.start;
        break;
      case 'canceled':
      case 'cancelled':
        phase = BetterPlayerNetworkLogPhase.canceled;
        break;
      case 'error':
      case 'failed':
        phase = BetterPlayerNetworkLogPhase.error;
        break;
      case 'completed':
      default:
        phase = BetterPlayerNetworkLogPhase.completed;
        break;
    }

    final String url = (map['url'] as String?) ?? '';
    final String dataTypeStr =
        (map['dataType'] as String?)?.toLowerCase() ?? '';
    final BetterPlayerNetworkDataType dataType =
        _inferDataType(dataTypeStr, url);

    final rawTimestamp = map['timestamp'];
    final DateTime timestamp;
    if (rawTimestamp is int) {
      timestamp = DateTime.fromMillisecondsSinceEpoch(rawTimestamp);
    } else if (rawTimestamp is String) {
      timestamp = DateTime.tryParse(rawTimestamp) ?? DateTime.now();
    } else {
      timestamp = DateTime.now();
    }

    return BetterPlayerNetworkLog(
      id: map['requestId']?.toString() ??
          map['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      url: url,
      httpMethod: (map['httpMethod'] as String?) ?? 'GET',
      phase: phase,
      dataType: dataType,
      trackType: map['trackType'] as String?,
      statusCode: (map['statusCode'] as num?)?.toInt(),
      bytesLoaded: (map['bytesLoaded'] as num?)?.toInt() ?? 0,
      durationMs: (map['loadDurationMs'] as num?)?.toInt() ??
          (map['durationMs'] as num?)?.toInt() ??
          0,
      timestamp: timestamp,
      serverAddress: map['serverAddress'] as String?,
      bitrate: (map['bitrate'] as num?)?.toInt() ??
          (map['indicatedBitrate'] as num?)?.toInt() ??
          (map['observedBitrate'] as num?)?.toInt(),
      width: (map['width'] as num?)?.toInt(),
      height: (map['height'] as num?)?.toInt(),
      mediaStartTimeMs: (map['mediaStartTimeMs'] as num?)?.toInt(),
      mediaEndTimeMs: (map['mediaEndTimeMs'] as num?)?.toInt(),
      errorMessage: map['error'] as String? ?? map['errorMessage'] as String?,
      extra: map,
    );
  }

  static BetterPlayerNetworkDataType _inferDataType(
      String dataTypeStr, String url) {
    if (dataTypeStr.contains('manifest') || dataTypeStr.contains('playlist')) {
      return BetterPlayerNetworkDataType.manifest;
    }
    if (dataTypeStr.contains('init')) {
      return BetterPlayerNetworkDataType.initialization;
    }
    if (dataTypeStr.contains('drm') || dataTypeStr.contains('key')) {
      return BetterPlayerNetworkDataType.drmKey;
    }
    if (dataTypeStr.contains('sub') ||
        dataTypeStr.contains('text') ||
        dataTypeStr.contains('vtt')) {
      return BetterPlayerNetworkDataType.subtitles;
    }
    if (dataTypeStr.contains('media')) {
      return BetterPlayerNetworkDataType.mediaSegment;
    }

    final lowerUrl = url.toLowerCase();
    if (lowerUrl.contains('.m3u8') || lowerUrl.contains('.mpd')) {
      return BetterPlayerNetworkDataType.manifest;
    }
    if (lowerUrl.contains('.ts') ||
        lowerUrl.contains('.m4s') ||
        lowerUrl.contains('.mp4') ||
        lowerUrl.contains('.aac') ||
        lowerUrl.contains('.m4a') ||
        lowerUrl.contains('segment') ||
        lowerUrl.contains('chunk')) {
      return BetterPlayerNetworkDataType.mediaSegment;
    }
    if (lowerUrl.contains('init') || lowerUrl.contains('.mp4?init')) {
      return BetterPlayerNetworkDataType.initialization;
    }
    if (lowerUrl.contains('.key') || lowerUrl.contains('license')) {
      return BetterPlayerNetworkDataType.drmKey;
    }
    if (lowerUrl.contains('.vtt') || lowerUrl.contains('.srt')) {
      return BetterPlayerNetworkDataType.subtitles;
    }

    return BetterPlayerNetworkDataType.unknown;
  }

  /// Converts this log entry to a serializable Map.
  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'url': url,
      'httpMethod': httpMethod,
      'phase': phase.name,
      'dataType': dataType.name,
      'trackType': trackType,
      'statusCode': statusCode,
      'bytesLoaded': bytesLoaded,
      'durationMs': durationMs,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'serverAddress': serverAddress,
      'bitrate': bitrate,
      'width': width,
      'height': height,
      'mediaStartTimeMs': mediaStartTimeMs,
      'mediaEndTimeMs': mediaEndTimeMs,
      'errorMessage': errorMessage,
      if (extra != null) 'extra': extra,
    };
  }

  /// Returns true if this request represents an HLS segment (.ts, .m4s) or manifest (.m3u8).
  bool get isHls =>
      url.contains('.m3u8') ||
      url.contains('.ts') ||
      url.contains('.m4s') ||
      dataType == BetterPlayerNetworkDataType.manifest ||
      dataType == BetterPlayerNetworkDataType.mediaSegment;

  /// Returns true if this request represents an HLS/DASH media chunk/segment.
  bool get isMediaChunk =>
      dataType == BetterPlayerNetworkDataType.mediaSegment ||
      url.contains('.ts') ||
      url.contains('.m4s');

  /// Returns true if the request completed without errors.
  bool get isSuccessful =>
      phase != BetterPlayerNetworkLogPhase.error &&
      (statusCode == null || (statusCode! >= 200 && statusCode! < 400));

  /// Returns the file/segment name portion of the URL.
  String get fileName {
    return segmentFileName ?? 'Unknown';
  }

  /// Returns a real media segment filename, without path or query parameters.
  String? get segmentFileName {
    if (url.isEmpty) return null;
    try {
      final uri = Uri.parse(url);
      final pathSegmentName = _findSegmentName(uri.pathSegments);
      if (pathSegmentName != null) {
        return pathSegmentName;
      }

      final querySegmentName =
          _findSegmentName(uri.queryParametersAll.values.expand((v) => v));
      if (querySegmentName != null) {
        return querySegmentName;
      }

      final extraSegmentName = _findSegmentName(
        extra?.values.map((value) => value?.toString()) ?? const <String>[],
      );
      if (extraSegmentName != null) {
        return extraSegmentName;
      }

      return null;
    } catch (_) {
      return _segmentNameFromValue(url);
    }
  }

  static String? _findSegmentName(Iterable<String?> values) {
    for (final value in values) {
      final segmentName = _segmentNameFromValue(value);
      if (segmentName != null) return segmentName;
    }
    return null;
  }

  static String? _segmentNameFromValue(String? value) {
    if (value == null || value.trim().isEmpty) return null;

    final candidates = <String>[value.trim()];
    try {
      final decoded = Uri.decodeFull(value.trim());
      if (decoded != value.trim()) {
        candidates.add(decoded);
      }
    } catch (_) {}

    for (final candidate in candidates) {
      final uri = Uri.tryParse(candidate);
      final pathSegments = uri?.pathSegments ?? const <String>[];
      for (final segment in pathSegments.reversed) {
        final cleanSegment = segment.split(';').first;
        if (_isSegmentFileName(cleanSegment)) return cleanSegment;
      }

      final sanitized = candidate.split('?').first.split('#').first.split(';').first;
      final parts = sanitized.split('/');
      for (final part in parts.reversed) {
        if (_isSegmentFileName(part)) return part;
      }
    }

    return null;
  }

  static bool _isSegmentFileName(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return false;

    final lower = trimmed.toLowerCase();

    // Explicitly reject known non-segment endpoints
    if (_isGenericEndpointName(lower)) {
      return false;
    }

    final hasMediaExtension = lower.endsWith('.ts') ||
        lower.endsWith('.m4s') ||
        lower.endsWith('.m4a') ||
        lower.endsWith('.aac') ||
        lower.endsWith('.mp4') ||
        lower.endsWith('.fmp4') ||
        lower.endsWith('.cmfv') ||
        lower.endsWith('.cmfa') ||
        lower.endsWith('.m4v') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.mp3');
    if (hasMediaExtension) return true;

    // Segment identifiers like segment-100 or chunk_02 without file extension
    if (lower.contains('segment') || lower.contains('chunk')) {
      return true;
    }

    return false;
  }

  static bool _isGenericEndpointName(String value) {
    const genericEndpoints = <String>{
      'client',
      'manifest',
      'playlist',
      'master',
      'index',
      'history',
      'profile',
      'reaction',
      'preference',
      'unknown',
      'api',
      'stream',
      'events',
      'v1',
      'v2',
    };
    return genericEndpoints.contains(value);
  }

  /// Formatted bytes string (e.g. "1.2 MB" or "450 KB" or "12 B").
  String get formattedSize {
    if (bytesLoaded <= 0) return '0 B';
    if (bytesLoaded < 1024) return '$bytesLoaded B';
    if (bytesLoaded < 1024 * 1024) {
      return '${(bytesLoaded / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytesLoaded / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  /// Formatted duration string (e.g. "145 ms" or "1.2 s").
  String get formattedDuration {
    if (durationMs < 1000) return '$durationMs ms';
    return '${(durationMs / 1000).toStringAsFixed(2)} s';
  }

  /// Formatted bitrate string (e.g. "2.4 Mbps" or "850 kbps").
  String? get formattedBitrate {
    if (bitrate == null || bitrate! <= 0) return null;
    if (bitrate! >= 1000000) {
      return '${(bitrate! / 1000000).toStringAsFixed(2)} Mbps';
    }
    return '${(bitrate! / 1000).toStringAsFixed(0)} kbps';
  }

  @override
  String toString() {
    return 'BetterPlayerNetworkLog(id: $id, phase: ${phase.name}, url: $url, bytes: $bytesLoaded, duration: ${durationMs}ms, status: $statusCode)';
  }
}
