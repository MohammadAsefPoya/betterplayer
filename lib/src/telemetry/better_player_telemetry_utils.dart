import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Utility methods for Playback Telemetry
class BetterPlayerTelemetryUtils {
  static final Random _secureRandom = Random.secure();

  /// Valid platforms allowed by the backend telemetry specification.
  static const Set<String> allowedPlatforms = {
    'WEB',
    'ANDROID',
    'IOS',
    'ANDROID_TV',
    'STB',
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
    if (kIsWeb) return 'web';
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

  /// Normalizes an audio language code.
  /// If [language] is null, empty, whitespace, or 'none', returns 'und'.
  static String normalizeAudioLanguageCode(String? language) {
    if (language == null) return 'und';
    final trimmed = language.trim().toLowerCase();
    if (trimmed.isEmpty || trimmed == 'null' || trimmed == 'none') {
      return 'und';
    }
    return toIso6392T(trimmed);
  }

  /// Normalizes a subtitle language code.
  /// If [isNone] is true or [language] is 'none', returns 'none' (subtitle off).
  /// If [language] is null, empty, or whitespace, returns 'und'.
  /// Otherwise returns trimmed lowercase language code.
  static String normalizeSubtitleLanguageCode(String? language,
      {bool isNone = false}) {
    if (isNone) return 'none';
    if (language == null) return 'und';
    final trimmed = language.trim().toLowerCase();
    if (trimmed == 'none') return 'none';
    if (trimmed.isEmpty || trimmed == 'null') return 'und';
    return toIso6392T(trimmed);
  }

  /// ISO 639-1 (2-letter) codes mapped to ISO 639-2/T.
  static const Map<String, String> _iso6391To6392T = {
    'aa': 'aar', 'af': 'afr', 'am': 'amh', 'ar': 'ara', 'as': 'asm',
    'az': 'aze', 'ba': 'bak', 'be': 'bel', 'bg': 'bul', 'bn': 'ben',
    'bo': 'bod', 'bs': 'bos', 'ca': 'cat', 'cs': 'ces', 'cy': 'cym',
    'da': 'dan', 'de': 'deu', 'dv': 'div', 'el': 'ell', 'en': 'eng',
    'eo': 'epo', 'es': 'spa', 'et': 'est', 'eu': 'eus', 'fa': 'fas',
    'fi': 'fin', 'fr': 'fra', 'ga': 'gle', 'gl': 'glg', 'gu': 'guj',
    'ha': 'hau', 'he': 'heb', 'hi': 'hin', 'hr': 'hrv', 'hu': 'hun',
    'hy': 'hye', 'id': 'ind', 'is': 'isl', 'it': 'ita', 'ja': 'jpn',
    'jv': 'jav', 'ka': 'kat', 'kk': 'kaz', 'km': 'khm', 'kn': 'kan',
    'ko': 'kor', 'ku': 'kur', 'ky': 'kir', 'la': 'lat', 'lo': 'lao',
    'lt': 'lit', 'lv': 'lav', 'mk': 'mkd', 'ml': 'mal', 'mn': 'mon',
    'mr': 'mar', 'ms': 'msa', 'my': 'mya', 'ne': 'nep', 'nl': 'nld',
    'no': 'nor', 'nb': 'nob', 'nn': 'nno', 'or': 'ori', 'pa': 'pan',
    'pl': 'pol', 'ps': 'pus', 'pt': 'por', 'ro': 'ron', 'ru': 'rus',
    'sd': 'snd', 'si': 'sin', 'sk': 'slk', 'sl': 'slv', 'so': 'som',
    'sq': 'sqi', 'sr': 'srp', 'sv': 'swe', 'sw': 'swa', 'ta': 'tam',
    'te': 'tel', 'tg': 'tgk', 'th': 'tha', 'tk': 'tuk', 'tl': 'tgl',
    'tr': 'tur', 'tt': 'tat', 'ug': 'uig', 'uk': 'ukr', 'ur': 'urd',
    'uz': 'uzb', 'vi': 'vie', 'yi': 'yid', 'zh': 'zho', 'zu': 'zul',
  };

  /// ISO 639-2/B (bibliographic) codes mapped to their /T form.
  static const Map<String, String> _iso6392BTo6392T = {
    'alb': 'sqi', 'arm': 'hye', 'baq': 'eus', 'bur': 'mya', 'chi': 'zho',
    'cze': 'ces', 'dut': 'nld', 'fre': 'fra', 'geo': 'kat', 'ger': 'deu',
    'gre': 'ell', 'ice': 'isl', 'mac': 'mkd', 'mao': 'mri', 'may': 'msa',
    'per': 'fas', 'rum': 'ron', 'slo': 'slk', 'tib': 'bod', 'wel': 'cym',
  };

  /// Converts a language tag (ISO 639-1, 639-2/B, 639-2/T or a BCP 47 tag
  /// such as `fa-IR`) to a lowercase ISO 639-2/T code. Unknown values are
  /// returned lowercased; `und` and `none` are kept as they are.
  static String toIso6392T(String language) {
    var code = language.trim().toLowerCase();
    if (code.isEmpty) return 'und';
    if (code == 'und' || code == 'none') return code;
    final separator = code.indexOf(RegExp('[-_]'));
    if (separator > 0) {
      code = code.substring(0, separator);
    }
    if (code.length == 2) {
      return _iso6391To6392T[code] ?? code;
    }
    return _iso6392BTo6392T[code] ?? code;
  }

  /// Truncates [value] to at most [maxLength] characters.
  static String clamp(String value, int maxLength) =>
      value.length > maxLength ? value.substring(0, maxLength) : value;

  static final RegExp _androidOsPattern = RegExp(
    r'^android\s+([^\s(]+)\s*\(\s*api(?:\s*level)?\s*(\d+)\s*\)',
    caseSensitive: false,
  );

  /// Builds the contract OS string `Android <release> (API <sdk>)`.
  static String formatAndroidOs(String release, int sdkInt) =>
      'Android ${release.trim()} (API $sdkInt)';

  /// Rewrites Android OS strings such as `ANDROID 11 (API Level 30)` or
  /// `ANDROID 14 (API level 34)` to `Android 11 (API 30)`. Other values are
  /// returned trimmed.
  static String normalizeOs(String? os) {
    final trimmed = os?.trim() ?? '';
    final match = _androidOsPattern.firstMatch(trimmed);
    if (match == null) return trimmed;
    return formatAndroidOs(match.group(1)!, int.parse(match.group(2)!));
  }

  /// Host of [url], or null when it has none (local files, invalid URLs).
  static String? hostOf(String? url) {
    if (url == null || url.trim().isEmpty) return null;
    try {
      final host = Uri.parse(url.trim()).host;
      return host.isEmpty ? null : host.toLowerCase();
    } catch (_) {
      return null;
    }
  }

  static const MethodChannel _deviceInfoChannel =
      MethodChannel('better_player_channel');
  static Future<Map<String, dynamic>?>? _deviceInfoFuture;

  /// Native device information (Android only): `release`, `sdkInt`,
  /// `manufacturer` and `model`. Resolved once per process; null when it is
  /// unavailable.
  static Future<Map<String, dynamic>?> deviceInfo() {
    return _deviceInfoFuture ??= _loadDeviceInfo();
  }

  static Future<Map<String, dynamic>?> _loadDeviceInfo() async {
    try {
      if (kIsWeb || !Platform.isAndroid) return null;
      final info = await _deviceInfoChannel
          .invokeMapMethod<String, dynamic>('getDeviceInfo')
          .timeout(const Duration(seconds: 2));
      return info;
    } catch (_) {
      return null;
    }
  }

  /// Contract OS string from native [info], or null.
  static String? osFromDeviceInfo(Map<String, dynamic>? info) {
    final release = info?['release'];
    final sdkInt = info?['sdkInt'];
    if (release is! String || release.trim().isEmpty || sdkInt is! int) {
      return null;
    }
    return formatAndroidOs(release, sdkInt);
  }

  /// `<manufacturer> <model>` from native [info], or null.
  static String? deviceModelFromDeviceInfo(Map<String, dynamic>? info) {
    final manufacturer = (info?['manufacturer'] as String?)?.trim() ?? '';
    final model = (info?['model'] as String?)?.trim() ?? '';
    final value = [manufacturer, model].where((e) => e.isNotEmpty).join(' ');
    return value.isEmpty ? null : clamp(value, 100);
  }

  /// Cleans a streaming file URL by retaining scheme, host, port (if present), and path,
  /// stripping query parameters, tokens, and fragment.
  /// Returns null if [url] is null or empty.
  static String? cleanFileUrl(String? url) {
    final cleaned = _cleanFileUrl(url);
    return cleaned == null ? null : clamp(cleaned, 2048);
  }

  static String? _cleanFileUrl(String? url) {
    if (url == null) return null;
    final trimmed = url.trim().replaceAll(r'\', '/');
    if (trimmed.isEmpty) return null;

    try {
      final uri = Uri.parse(trimmed);
      if (uri.hasScheme && uri.host.isNotEmpty) {
        final origin =
            '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
        final path = uri.path;
        return '$origin$path';
      }
    } catch (_) {}

    // Fallback: strip query string and fragment manually
    final questionMarkIdx = trimmed.indexOf('?');
    var withoutQuery =
        questionMarkIdx != -1 ? trimmed.substring(0, questionMarkIdx) : trimmed;
    final hashIdx = withoutQuery.indexOf('#');
    if (hashIdx != -1) {
      withoutQuery = withoutQuery.substring(0, hashIdx);
    }
    return withoutQuery.isNotEmpty ? withoutQuery : null;
  }
}
