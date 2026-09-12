import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Utility methods for Playback Telemetry
class BetterPlayerTelemetryUtils {
  static final Random _secureRandom = Random.secure();

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

  /// Safely resolves operating system name.
  static String getOperatingSystem() {
    try {
      return Platform.operatingSystem;
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
