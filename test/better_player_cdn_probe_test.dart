// Tests for the CDN ping ("Mobile & STB app: CDN ping you must add", Nov 11
// 2026): one round per session after PLAYBACK_STARTED, servers pinged one
// after another, any reply counts, TIMEOUT / NETWORK results, one results
// POST with a single retry after a network error, and nothing sent for a
// session that ends first.
import 'dart:convert';
import 'dart:io';

import 'package:better_player/better_player.dart';
import 'package:better_player/src/video_player/video_player_platform_interface.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'better_player_mock_controller.dart';
import 'better_player_test_utils.dart';
import 'mock_method_channel.dart';
import 'mock_video_player_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final MockMethodChannel mockMethodChannel = MockMethodChannel();

  setUpAll(() {
    HttpOverrides.global = null;
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            mockMethodChannel.channel, mockMethodChannel.handle);
  });

  // Telemetry backend.
  late HttpServer server;
  final starts = <Map<String, dynamic>>[];
  final probes = <Map<String, dynamic>>[];
  // "start", "probes" and "ping:<i>:in" / "ping:<i>:out", in order.
  final log = <String>[];
  var probeAttempts = 0;
  // Answers of the cdn-probes POSTs in turn; null drops the connection.
  var probeAnswers = <int?>[];
  // Answers of sessions/start in turn, then 200.
  var startAnswers = <int>[];

  // CDN servers.
  final cdnServers = <HttpServer>[];

  setUp(() async {
    starts.clear();
    probes.clear();
    log.clear();
    probeAttempts = 0;
    probeAnswers = <int?>[];
    startAnswers = <int>[];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final body =
          jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
      var status = HttpStatus.ok;
      final path = request.uri.path;
      if (path.endsWith('sessions/start')) {
        if (startAnswers.isNotEmpty) status = startAnswers.removeAt(0);
        if (status == HttpStatus.ok) {
          starts.add(body);
          log.add('start');
        }
      } else if (path.endsWith('statistics/cdn-probes')) {
        probeAttempts++;
        final answer =
            probeAnswers.isEmpty ? HttpStatus.ok : probeAnswers.removeAt(0);
        if (answer == null) {
          final socket = await request.response.detachSocket();
          socket.destroy();
          return;
        }
        status = answer;
        if (status == HttpStatus.ok) {
          probes.add(body);
          log.add('probes');
        }
      }
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(status == HttpStatus.ok && path.endsWith('cdn-probes')
            ? '{"success":true,"alreadyExists":false}'
            : '{}')
        ..close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    for (final cdn in cdnServers) {
      await cdn.close(force: true);
    }
    cdnServers.clear();
  });

  /// A CDN server that answers [status] after [delay]; [hang] never answers.
  Future<String> cdn(
    int index, {
    int status = HttpStatus.ok,
    Duration delay = Duration.zero,
    bool hang = false,
    List<Map<String, String?>>? seenHeaders,
  }) async {
    final cdnServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    cdnServers.add(cdnServer);
    cdnServer.listen((HttpRequest request) async {
      log.add('ping:$index:in');
      seenHeaders?.add(<String, String?>{
        'method': request.method,
        'cache-control': request.headers.value('cache-control'),
        'pragma': request.headers.value('pragma'),
      });
      if (hang) return;
      await Future<void>.delayed(delay);
      log.add('ping:$index:out');
      request.response
        ..statusCode = status
        ..write('x' * 1000)
        ..close();
    });
    return 'http://${cdnServer.address.host}:${cdnServer.port}/';
  }

  /// A URL whose server refuses connections.
  Future<String> refused() async {
    final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final url = 'http://${closed.address.host}:${closed.port}/';
    await closed.close(force: true);
    return url;
  }

  String hostOf(String url) => Uri.parse(url).authority;

  BetterPlayerTelemetryConfiguration config(
    List<String> pingUrls, {
    Duration delay = const Duration(milliseconds: 400),
    Duration timeout = const Duration(milliseconds: 300),
    Duration retryDelay = const Duration(milliseconds: 300),
  }) =>
      BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: HttpClient(),
        cdnProbeUrls: pingUrls,
        cdnProbeDelay: delay,
        cdnProbeTimeout: timeout,
        cdnProbeRetryDelay: retryDelay,
      );

  BetterPlayerDataSource episode(
    int episodeId, {
    String url = 'https://kbl-cdn.movie.af/videos/1/hls/master.m3u8',
    BetterPlayerTelemetryConfiguration? telemetry,
  }) =>
      BetterPlayerDataSource.network(
        url,
        episodeId: episodeId,
        platform: 'STB',
        deviceType: 'TV',
        telemetryConfiguration: telemetry,
      );

  Future<void> settle([int ms = 150]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> advanceTo(
    BetterPlayerController controller,
    MockVideoPlayerController video,
    Duration position,
  ) async {
    await video.seekTo(position);
    controller.telemetryManager.handlePositionTick();
    controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.progress));
  }

  // Plays an episode until PLAYBACK_STARTED.
  Future<(BetterPlayerMockController, MockVideoPlayerController)>
      playingEpisode(BetterPlayerTelemetryConfiguration telemetry,
          {int episodeId = 7}) async {
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    video.setDuration(const Duration(minutes: 30));
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);
    await controller.setupDataSource(episode(episodeId, telemetry: telemetry));
    await controller.play();
    await advanceTo(controller, video, Duration.zero);
    await advanceTo(controller, video, const Duration(milliseconds: 300));
    return (controller, video);
  }

  List<String> pings() => log.where((e) => e.endsWith(':in')).toList();

  test('One round after the delay: every server in order, one at a time',
      () async {
    final headers = <Map<String, String?>>[];
    final urls = <String>[
      await cdn(0,
          status: 403,
          delay: const Duration(milliseconds: 60),
          seenHeaders: headers),
      await cdn(1, delay: const Duration(milliseconds: 60)),
      await cdn(2, status: 404, delay: const Duration(milliseconds: 60)),
    ];
    final (controller, video) = await playingEpisode(config(urls));
    await settle(200);
    // Not before the delay after PLAYBACK_STARTED.
    expect(pings(), isEmpty);
    await settle(800);
    await advanceTo(controller, video, const Duration(seconds: 20));
    await settle(400);

    expect(pings(), ['ping:0:in', 'ping:1:in', 'ping:2:in']);
    // Never in parallel: each ping starts after the previous reply.
    expect(log.where((e) => e.startsWith('ping:')).toList(), <String>[
      'ping:0:in',
      'ping:0:out',
      'ping:1:in',
      'ping:1:out',
      'ping:2:in',
      'ping:2:out',
    ]);
    expect(headers.single['method'], 'GET');
    expect(headers.single['cache-control'], 'no-cache');
    expect(headers.single['pragma'], 'no-cache');

    expect(probes, hasLength(1));
    final body = probes.single;
    expect(body.keys.toSet(), {'sessionId', 'results'});
    expect(body['sessionId'], starts.single['sessionId']);
    final results = (body['results'] as List).cast<Map<String, dynamic>>();
    expect(results.map((r) => r['host']), urls.map(hostOf));
    expect(results.map((r) => r['status']), [403, 200, 404]);
    for (final r in results) {
      expect(r.containsKey('error'), isFalse);
      expect(r['ms'], isA<int>());
      expect(r['ms'] as int, inInclusiveRange(40, 60000));
    }
    expect(log.indexOf('start'), lessThan(log.indexOf('probes')));

    // The round never repeats in the same session.
    await settle(800);
    expect(probeAttempts, 1);
    await controller.telemetryManager.dispose();
    expect(probeAttempts, 1);
  });

  test('No reply: TIMEOUT after the timeout, NETWORK when refused', () async {
    final urls = <String>[
      await cdn(0, hang: true),
      await refused(),
      await cdn(2),
    ];
    final (controller, _) = await playingEpisode(config(urls));
    await settle(1600);
    await controller.telemetryManager.dispose();

    final results =
        (probes.single['results'] as List).cast<Map<String, dynamic>>();
    expect(results[0], {
      'host': hostOf(urls[0]),
      'ms': null,
      'status': 0,
      'error': 'TIMEOUT',
    });
    expect(results[1], {
      'host': hostOf(urls[1]),
      'ms': null,
      'status': 0,
      'error': 'NETWORK',
    });
    expect(results[2]['status'], 200);
    expect(results[2].containsKey('error'), isFalse);
  });

  test('No ping URLs: no ping and no results', () async {
    for (final urls in <List<String>>[
      const <String>[],
      const <String>['not a url', 'ftp://cdn.movie.af/'],
    ]) {
      final (controller, _) = await playingEpisode(config(urls));
      await settle(800);
      await controller.telemetryManager.dispose();
    }
    expect(starts, hasLength(2));
    expect(log.where((e) => e.startsWith('ping')), isEmpty);
    expect(probeAttempts, 0);
  });

  test('A session that ends before the delay is not pinged', () async {
    final urls = <String>[await cdn(0), await cdn(1)];
    final (controller, _) = await playingEpisode(config(urls));
    await settle(100);
    controller.dispose(forceDispose: true);
    await controller.telemetryManager.waitForPendingFlushes();
    await settle(800);
    expect(pings(), isEmpty);
    expect(probeAttempts, 0);
  });

  test('A session that never started playback is not pinged', () async {
    final urls = <String>[await cdn(0)];
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);
    await controller.setupDataSource(episode(7, telemetry: config(urls)));
    await controller.play();
    await settle(800);
    await controller.telemetryManager.dispose();
    expect(starts, hasLength(1));
    expect(pings(), isEmpty);
    expect(probeAttempts, 0);
  });

  test('A session that ends while pinging sends nothing', () async {
    final urls = <String>[
      await cdn(0, delay: const Duration(milliseconds: 250)),
      await cdn(1),
    ];
    final (controller, _) = await playingEpisode(config(urls));
    await settle(500);
    expect(pings(), ['ping:0:in']);
    // Another episode: the old session ends during the first ping.
    await controller.setupDataSource(episode(8, telemetry: config(urls)));
    await settle(600);
    expect(pings(), ['ping:0:in']);
    expect(probeAttempts, 0);
    await controller.telemetryManager.dispose();
  });

  test('Each session gets its own round; a fallback URL keeps the session',
      () async {
    final urls = <String>[await cdn(0)];
    final (controller, video) = await playingEpisode(config(urls));
    await settle(700);
    expect(probes, hasLength(1));

    // Fallback URL of the same episode: same session, no second round.
    await controller.setupDataSource(episode(7,
        url: 'https://mzr-cdn.movie.af/videos/1/hls/master.m3u8',
        telemetry: config(urls)));
    await controller.play();
    await advanceTo(controller, video, const Duration(seconds: 2));
    await advanceTo(controller, video, const Duration(seconds: 3));
    await settle(700);
    expect(probes, hasLength(1));

    // Another episode: a new session with its own round.
    await controller.setupDataSource(episode(8, telemetry: config(urls)));
    await controller.play();
    await advanceTo(controller, video, Duration.zero);
    await advanceTo(controller, video, const Duration(milliseconds: 300));
    await settle(700);
    await controller.telemetryManager.dispose();

    expect(starts, hasLength(2));
    expect(probes, hasLength(2));
    expect(
        probes.map((p) => p['sessionId']), starts.map((s) => s['sessionId']));
  });

  test('Live channels ping too, one round per channel session', () async {
    final urls = <String>[await cdn(0)];
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);

    Future<void> watchChannel(int channelId) async {
      await controller.setupDataSource(BetterPlayerDataSource.network(
        'https://kbl-stream.movie.af/live/$channelId/playlist.m3u8',
        liveStream: true,
        channelId: channelId,
        platform: 'STB',
        deviceType: 'TV',
        telemetryConfiguration: config(urls),
      ));
      await controller.play();
      await video.seekTo(const Duration(seconds: 30));
      video.livePlaybackInfo = <String, dynamic>{
        'isLive': true,
        'positionMs': 30000,
        'periodPositionMs': 27000000,
        'liveOffsetMs': 15000,
        'bufferedAheadMs': 9000,
      };
      await controller.telemetryManager.refreshLivePlaybackInfo();
      video.videoEventStreamController
          .add(VideoEvent(eventType: VideoEventType.firstFrame, key: null));
    }

    await watchChannel(12);
    await settle(800);
    // Zapping: channel 13 for less than the delay, then channel 14.
    await watchChannel(13);
    await settle(150);
    await watchChannel(14);
    await settle(800);
    await controller.telemetryManager.dispose();

    expect(starts.map((s) => s['channelId']), [12, 13, 14]);
    expect(probes.map((p) => p['sessionId']),
        [starts[0]['sessionId'], starts[2]['sessionId']]);
  });

  test('Results wait for the session start to succeed', () async {
    // The first start fails; its retry comes 2 s later.
    startAnswers = <int>[HttpStatus.serviceUnavailable];
    final urls = <String>[await cdn(0)];
    final (controller, _) = await playingEpisode(config(urls));
    await settle(900);
    expect(pings(), ['ping:0:in']);
    expect(probeAttempts, 0);
    await settle(2000);
    await controller.telemetryManager.dispose();
    expect(
        log.where((e) => e == 'start' || e == 'probes'), ['start', 'probes']);
    expect(probes.single['sessionId'], starts.single['sessionId']);
  });

  test('A network error is retried once, then dropped', () async {
    probeAnswers = <int?>[null, null];
    final urls = <String>[await cdn(0)];
    final (controller, _) = await playingEpisode(config(urls));
    await settle(700);
    expect(probeAttempts, 1);
    await settle(500);
    expect(probeAttempts, 2);
    await settle(800);
    expect(probeAttempts, 2);
    await controller.telemetryManager.dispose();
  });

  test('A retry after a network error can deliver the results', () async {
    probeAnswers = <int?>[null];
    final urls = <String>[await cdn(0)];
    final (controller, _) = await playingEpisode(config(urls));
    await settle(1400);
    await controller.telemetryManager.dispose();
    expect(probeAttempts, 2);
    expect(probes, hasLength(1));
  });

  test('A 4xx answer is never retried', () async {
    for (final status in <int>[HttpStatus.notFound, HttpStatus.badRequest]) {
      probeAttempts = 0;
      probeAnswers = <int?>[status];
      final urls = <String>[await cdn(0)];
      final (controller, _) = await playingEpisode(config(urls));
      await settle(1400);
      await controller.telemetryManager.dispose();
      expect(probeAttempts, 1, reason: '$status');
    }
    expect(probes, isEmpty);
  });

  test('Background before the round: none until the app is back', () async {
    final urls = <String>[await cdn(0)];
    final (controller, _) = await playingEpisode(config(urls));
    await settle(100);
    controller.setAppLifecycleState(AppLifecycleState.paused);
    await settle(800);
    expect(pings(), isEmpty);

    controller.setAppLifecycleState(AppLifecycleState.resumed);
    await settle(200);
    expect(pings(), isEmpty);
    await settle(600);
    await controller.telemetryManager.dispose();
    expect(pings(), ['ping:0:in']);
    expect(probes, hasLength(1));
  });

  test('Ping targets: http(s) only, each host once, at most 20', () {
    final targets = BetterPlayerCdnProber.targetsOf(<String>[
      'https://cdn.movie.af/',
      'https://cdn.movie.af/other',
      'ftp://x.movie.af/',
      '',
      'https://hrt-stream.movie.af:8443/',
      for (var i = 0; i < 30; i++) 'https://h$i.movie.af/',
    ]);
    expect(targets, hasLength(20));
    expect(targets[0].authority, 'cdn.movie.af');
    expect(targets[1].authority, 'hrt-stream.movie.af:8443');
    expect(targets.map((t) => t.authority).toSet(), hasLength(20));
  });

  test('Result JSON leaves error out when a reply came', () {
    expect(
        const BetterPlayerCdnProbeResult(
                host: 'cdn.movie.af', ms: 61, status: 403)
            .toJson(),
        {'host': 'cdn.movie.af', 'ms': 61, 'status': 403});
    expect(
        const BetterPlayerCdnProbeResult(
                host: 'cdn.movie.af', ms: null, status: 0, error: 'TIMEOUT')
            .toJson(),
        {'host': 'cdn.movie.af', 'ms': null, 'status': 0, 'error': 'TIMEOUT'});
    expect(
        const BetterPlayerTelemetryConfiguration(
                baseUrl: 'https://api.movie.af/api/')
            .cdnProbesUri
            .toString(),
        'https://api.movie.af/api/v1/statistics/cdn-probes');
  });
}
