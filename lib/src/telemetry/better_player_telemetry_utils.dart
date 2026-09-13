import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';

/// Utility methods for Playback Telemetry
class BetterPlayerTelemetryUtils {
  static final Random _secureRandom = Random.secure();

  /// Valid platforms allowed by the backend telemetry specification.
  static const Set<String> allowedPlatforms = {
    'WEB',
    'ANDROID',
    'IOS',
    'ANDROID_TV',
    'OLD_WEB_TV',
  };

  /// Valid device types allowed by the backend telemetry specification.
  static const Set<String> allowedDeviceTypes = {
    'DESKTOP',
    'MOBILE',
    'TABLET',
    'TV',
    'UNKNOWN',
  };

  /// Generates a compliant RFC 4122 version 4 UUID string.
  /// Example: 762a3221-482d-483a-b661-bb6c64a753fa
  static String generateUuidV4() {
    final List<int> bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));

    // Set version to 4 (0100xxxx)
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Set variant to RFC 4122 (10xxxxxx)
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < 16; i++) {
      if (i == 4 || i == 6 || i == 8 || i == 10) {
        buffer.write('-');
      }
      buffer.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  /// Safely resolves default platform name conforming to backend enum.
  static String resolveDefaultPlatform() {
    if (kIsWeb) return 'WEB';
    try {
      if (Platform.isAndroid) return 'ANDROID';
      if (Platform.isIOS) return 'IOS';
    } catch (_) {}
    return 'WEB';
  }

  /// Normalizes and validates the platform string against allowed values.
  static String normalizePlatform(String? platform) {
    if (platform == null || platform.trim().isEmpty) {
      return resolveDefaultPlatform();
    }
    final normalized = platform.trim().toUpperCase();
    if (allowedPlatforms.contains(normalized)) {
      return normalized;
    }
    return resolveDefaultPlatform();
  }

  /// Safely resolves default device type conforming to backend enum.
  static String resolveDefaultDeviceType() {
    if (kIsWeb) return 'DESKTOP';
    try {
      if (Platform.isAndroid || Platform.isIOS) return 'MOBILE';
      if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
        return 'DESKTOP';
      }
    } catch (_) {}
    return 'UNKNOWN';
  }

  /// Normalizes and validates the device type string against allowed values.
  static String normalizeDeviceType(String? deviceType) {
    if (deviceType == null || deviceType.trim().isEmpty) {
      return resolveDefaultDeviceType();
    }
    final normalized = deviceType.trim().toUpperCase();
    if (allowedDeviceTypes.contains(normalized)) {
      return normalized;
    }
    return resolveDefaultDeviceType();
  }

  /// Normalizes episodeId to integer >= 1 as required by backend specification.
  static int? normalizeEpisodeId(dynamic episodeId) {
    if (episodeId == null) return null;
    if (episodeId is int) return episodeId >= 1 ? episodeId : 1;
    if (episodeId is num) {
      final val = episodeId.toInt();
      return val >= 1 ? val : 1;
    }
    if (episodeId is String) {
      final parsed = int.tryParse(episodeId.trim());
      if (parsed != null) {
        return parsed >= 1 ? parsed : 1;
      }
    }
    return null;
  }

  /// Safely resolves operating system name, clamped to max 100 characters.
  static String getOperatingSystem() {
    try {
      final os = Platform.operatingSystem;
      return os.length > 100 ? os.substring(0, 100) : os;
    } catch (_) {
      return 'unknown';
    }
  }

  /// Formats [DateTime] as UTC ISO-8601 with millisecond precision and 'Z'.
  /// Example: 2026-09-10T08:00:00.000Z
  static String formatIsoTimestamp(DateTime dateTime) {
    return dateTime.toUtc().toIso8601String();
  }

  /// Sanitizes event details map to ensure:
  /// 1. It is a valid JSON map, not a JSON string.
  /// 2. It does not contain tokens or signed media URLs.
  /// 3. It is bounded to a maximum of [maxBytes] (default 8 KB).
  static Map<String, dynamic> sanitizeEventDetails(
    Map<String, dynamic>? details, {
    int maxBytes = 8192,
  }) {
    if (details == null || details.isEmpty) {
      return <String, dynamic>{};
    }

    final sanitized = <String, dynamic>{};
    for (final entry in details.entries) {
      final keyLower = entry.key.toLowerCase();
      // Exclude tokens, secrets, signatures, credentials
      if (keyLower.contains('token') ||
          keyLower.contains('signature') ||
          keyLower.contains('auth') ||
          keyLower.contains('password') ||
          keyLower.contains('secret')) {
        continue;
      }

      var value = entry.value;
      if (value is String) {
        // Strip sensitive query params from URLs if any
        if (value.startsWith('http://') || value.startsWith('https://')) {
          try {
            final uri = Uri.parse(value);
            if (uri.hasQuery) {
              value = '${uri.origin}${uri.path}';
            }
          } catch (_) {}
        }
      }
      sanitized[entry.key] = value;
    }

    // Ensure payload size <= maxBytes
    try {
      final jsonStr = jsonEncode(sanitized);
      if (utf8.encode(jsonStr).length > maxBytes) {
        return <String, dynamic>{'warning': 'details_exceeded_size_limit'};
      }
    } catch (_) {
      return <String, dynamic>{};
    }

    return sanitized;
  }
}
