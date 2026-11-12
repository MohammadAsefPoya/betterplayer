import 'dart:async';
import 'dart:io';

import 'package:better_player/src/core/better_player_utils.dart';
import 'package:flutter/foundation.dart';

/// The result of pinging one CDN server, as sent to
/// `POST v1/statistics/cdn-probes` ("Mobile & STB app: CDN ping you must
/// add", Nov 11 2026).
@immutable
class BetterPlayerCdnProbeResult {
  /// `TIMEOUT`: no reply within the ping timeout.
  static const String errorTimeout = 'TIMEOUT';

  /// `NETWORK`: DNS, connection or TLS failure.
  static const String errorNetwork = 'NETWORK';

  /// Host of the pinged URL (`Uri.authority`).
  final String host;

  /// Time until the reply headers arrived, null when there was no reply.
  final int? ms;

  /// HTTP status of the reply, 0 when there was none.
  final int status;

  /// [errorTimeout] or [errorNetwork] when there was no reply, else null.
  final String? error;

  const BetterPlayerCdnProbeResult({
    required this.host,
    required this.ms,
    required this.status,
    this.error,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'host': host,
        'ms': ms,
        'status': status,
        if (error != null) 'error': error,
      };

  @override
  String toString() => toJson().toString();
}

/// Pings CDN servers one after another, with a client of its own that is
/// never the player's.
class BetterPlayerCdnProber {
  /// The backend accepts 1 to 20 results per round.
  static const int maxResults = 20;

  // The backend accepts `ms` from 0 to 60000.
  static const int _maxMs = 60000;

  BetterPlayerCdnProber._();

  /// The URLs to ping, in the order given: http(s) URLs with a host, each
  /// host once (the backend rejects a host twice), at most [maxResults].
  static List<Uri> targetsOf(List<String> urls) {
    final targets = <Uri>[];
    final hosts = <String>{};
    for (final raw in urls) {
      if (targets.length >= maxResults) break;
      final uri = Uri.tryParse(raw.trim());
      if (uri == null ||
          (uri.scheme != 'http' && uri.scheme != 'https') ||
          uri.host.isEmpty) {
        BetterPlayerUtils.log('Telemetry CDN ping skips invalid URL: $raw');
        continue;
      }
      if (!hosts.add(uri.authority)) {
        BetterPlayerUtils.log('Telemetry CDN ping skips repeated host: $raw');
        continue;
      }
      targets.add(uri);
    }
    return targets;
  }

  /// Pings every target in order, never two at the same time. Returns null
  /// as soon as [isCancelled] is true, so a cancelled round sends nothing.
  static Future<List<BetterPlayerCdnProbeResult>?> run(
    List<Uri> targets, {
    required Duration timeout,
    required bool Function() isCancelled,
  }) async {
    final results = <BetterPlayerCdnProbeResult>[];
    for (final target in targets) {
      if (isCancelled()) return null;
      final result = await ping(target, timeout: timeout);
      if (isCancelled()) return null;
      BetterPlayerUtils.log('Telemetry CDN ping $target: $result');
      results.add(result);
    }
    return results;
  }

  /// One GET to [target], timed from just before it is sent until the reply
  /// headers arrive. Any reply counts, whatever its status. The body is never
  /// read.
  static Future<BetterPlayerCdnProbeResult> ping(
    Uri target, {
    required Duration timeout,
  }) async {
    // A client per ping: closing it with force also aborts a request that
    // timed out, so it never competes with the next ping.
    final client = HttpClient()..autoUncompress = false;
    final stopwatch = Stopwatch();
    try {
      final response = await () async {
        stopwatch.start();
        final request = await client.getUrl(target);
        request.followRedirects = false;
        request.headers
          ..set(HttpHeaders.cacheControlHeader, 'no-cache')
          ..set(HttpHeaders.pragmaHeader, 'no-cache');
        return request.close();
      }()
          .timeout(timeout);
      stopwatch.stop();
      unawaited(response.listen(null).cancel().catchError((_) {}));
      return BetterPlayerCdnProbeResult(
        host: target.authority,
        ms: stopwatch.elapsedMilliseconds.clamp(0, _maxMs),
        status: response.statusCode.clamp(0, 599),
      );
    } on TimeoutException {
      return BetterPlayerCdnProbeResult(
        host: target.authority,
        ms: null,
        status: 0,
        error: BetterPlayerCdnProbeResult.errorTimeout,
      );
    } catch (e) {
      // SocketException, HandshakeException, HttpException and anything
      // else that kept the server from answering.
      BetterPlayerUtils.log('Telemetry CDN ping $target failed: $e');
      return BetterPlayerCdnProbeResult(
        host: target.authority,
        ms: null,
        status: 0,
        error: BetterPlayerCdnProbeResult.errorNetwork,
      );
    } finally {
      client.close(force: true);
    }
  }
}
