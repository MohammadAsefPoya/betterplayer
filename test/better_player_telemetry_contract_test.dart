// Tests for the telemetry contract agreed with the backend team
// ("Mobile & STB app: telemetry changes", Oct 2026): session lifecycle,
// user vs system pauses, stalls, errors, languages and final batches.
import 'dart:convert';
import 'dart:io';

import 'package:better_player/better_player.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
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

  late HttpServer server;
  final starts = <Map<String, dynamic>>[];
  final batches = <Map<String, dynamic>>[];
  var startDelay = Duration.zero;
  var batchDelay = Duration.zero;
  var batchStatus = HttpStatus.ok;

  setUp(() async {
    starts.clear();
    batches.clear();
    startDelay = Duration.zero;
    batchDelay = Duration.zero;
    batchStatus = HttpStatus.ok;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final body =
          jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
      var status = HttpStatus.ok;
      if (request.uri.path.endsWith('sessions/start')) {
        await Future<void>.delayed(startDelay);
        starts.add(body);
      } else {
        await Future<void>.delayed(batchDelay);
        status = batchStatus;
        if (status == HttpStatus.ok) batches.add(body);
      }
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write('{}')
        ..close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  BetterPlayerTelemetryConfiguration config({
    Duration batchSendInterval = const Duration(hours: 1),
  }) =>
      BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: batchSendInterval,
        httpClient: HttpClient(),
      );

  BetterPlayerDataSource episode(
    int episodeId, {
    String url = 'https://kbl-cdn.movie.af/videos/1/hls/master.m3u8',
    BetterPlayerTelemetryConfiguration? telemetry,
    String? os,
  }) =>
      BetterPlayerDataSource.network(
        url,
        episodeId: episodeId,
        platform: 'STB',
        deviceType: 'TV',
        os: os,
        ip: '10.0.0.1',
        telemetryConfiguration: telemetry,
      );

  List<Map<String, dynamic>> events([String? sessionId]) => batches
      .where((b) => sessionId == null || b['sessionId'] == sessionId)
      .expand((b) => b['playbackEvents'] as List)
      .cast<Map<String, dynamic>>()
      .toList();

  List<String> types([String? sessionId]) =>
      events(sessionId).map((e) => e['type'] as String).toList();

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

  Future<(BetterPlayerMockController, MockVideoPlayerController)>
      playingEpisode(
    BetterPlayerTelemetryConfiguration telemetry, {
    int episodeId = 7,
  }) async {
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    video.setDuration(const Duration(minutes: 30));
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);
    await controller.setupDataSource(episode(episodeId, telemetry: telemetry));
    await controller.play();
    await advanceTo(controller, video, Duration.zero);
    await advanceTo(controller, video, const Duration(milliseconds: 300));
    await settle();
    return (controller, video);
  }

  BetterPlayerEvent nativeError({
    String code = 'ERROR_CODE_IO_BAD_HTTP_STATUS',
    int errorCode = 2004,
    int? httpStatus = 404,
    String? host = 'kbl-cdn.movie.af',
    bool isRepeat = false,
  }) =>
      BetterPlayerEvent(
        BetterPlayerEventType.exception,
        parameters: <String, dynamic>{
          'exception': 'Video player had error z5.r: Source error',
          'errorDetails': <String, dynamic>{
            'kind': 'playback',
            'code': code,
            'errorCode': errorCode,
            'fatal': true,
            'httpStatus': httpStatus,
            'host': host,
            'message': 'Source error: Response code: $httpStatus',
          },
          'isRepeat': isRepeat,
        },
      );

  test('Preparing a source without play sends no request', () async {
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);

    await controller.setupDataSource(episode(7, telemetry: config()));
    await settle();
    await controller.telemetryManager.dispose();

    expect(starts, isEmpty);
    expect(batches, isEmpty);
  });

  test('Play, watch, close: start, first-batch events, one final batch',
      () async {
    final (controller, video) = await playingEpisode(config());
    expect(starts, hasLength(1));
    final start = starts.single;
    expect(start['platform'], 'STB');
    expect(start['deviceType'], 'TV');
    expect(start.containsKey('ip'), isFalse);
    expect(
        start['fileUrl'], 'https://kbl-cdn.movie.af/videos/1/hls/master.m3u8');

    await advanceTo(controller, video, const Duration(seconds: 60));
    // Closing the screen: visibility and dispose pauses are not PAUSE.
    controller.onPlayerVisibilityChanged(0);
    controller.dispose(forceDispose: true);
    await controller.telemetryManager.waitForPendingFlushes();

    expect(
        types(),
        containsAllInOrder(<String>[
          'PLAYBACK_STARTED',
          'AUDIO_LANGUAGE_CHANGED',
          'SUBTITLE_CHANGED',
        ]));
    expect(types(), isNot(contains('PAUSE')));
    final startedEvent =
        events().firstWhere((e) => e['type'] == 'PLAYBACK_STARTED');
    expect(startedEvent['details']['startupMs'], isA<int>());
    final audio =
        events().firstWhere((e) => e['type'] == 'AUDIO_LANGUAGE_CHANGED');
    expect(audio['details'], {'from': 'none', 'to': 'und'});
    final subtitle =
        events().firstWhere((e) => e['type'] == 'SUBTITLE_CHANGED');
    expect(subtitle['details'], {'from': 'none', 'to': 'none'});
    expect(batches.last['isFinal'], isTrue);
    expect(batches.where((b) => b['isFinal'] == true), hasLength(1));
  });

  test('Startup is measured from the play request, not from preparing',
      () async {
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    video.setDuration(const Duration(minutes: 30));
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);
    await controller.setupDataSource(episode(7, telemetry: config()));
    // An ad or a "continue watching" dialog keeps the content waiting.
    await settle(600);
    await controller.play(origin: BetterPlayerPlaybackOrigin.system);
    await advanceTo(controller, video, Duration.zero);
    await settle(200);
    await advanceTo(controller, video, const Duration(milliseconds: 300));
    await controller.telemetryManager.dispose();

    final startupMs =
        events().firstWhere((e) => e['type'] == 'PLAYBACK_STARTED')['details']
            ['startupMs'] as int;
    expect(startupMs, greaterThanOrEqualTo(150));
    expect(startupMs, lessThan(550));
  });

  test('User pause/resume are reported once; system and native ones are not',
      () async {
    final (controller, video) = await playingEpisode(config());

    await controller.pause();
    await controller.play();

    await controller.pause(origin: BetterPlayerPlaybackOrigin.system); // ad
    await controller.play(origin: BetterPlayerPlaybackOrigin.system);

    // Native pause (error / end of media / buffering side effect).
    controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.pause,
        parameters: <String, dynamic>{
          'origin': BetterPlayerPlaybackOrigin.native,
        }));
    controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.play,
        parameters: <String, dynamic>{
          'origin': BetterPlayerPlaybackOrigin.native,
        }));

    // Going to the background is a system pause plus a normal flush.
    controller.setAppLifecycleState(AppLifecycleState.paused);
    await settle();
    expect(batches.last['isFinal'], isFalse);
    controller.setAppLifecycleState(AppLifecycleState.resumed);

    await controller.telemetryManager.dispose();
    expect(types().where((t) => t == 'PAUSE'), hasLength(1));
    expect(types().where((t) => t == 'RESUME'), hasLength(1));
  });

  test('Stalls are paired, carry durationMs and only exist after first frame',
      () async {
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    video.setDuration(const Duration(minutes: 30));
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);
    await controller.setupDataSource(episode(7, telemetry: config()));
    await controller.play();
    // Waiting before the first frame is startup time, not a stall.
    controller
        .postEvent(BetterPlayerEvent(BetterPlayerEventType.bufferingStart));
    controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.bufferingEnd));
    await advanceTo(controller, video, Duration.zero);
    await advanceTo(controller, video, const Duration(seconds: 1));

    controller
        .postEvent(BetterPlayerEvent(BetterPlayerEventType.bufferingStart));
    controller
        .postEvent(BetterPlayerEvent(BetterPlayerEventType.bufferingStart));
    await settle(50);
    controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.bufferingEnd));
    controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.bufferingEnd));

    // Buffering after a seek while paused is not a stall.
    await controller.pause();
    controller
        .postEvent(BetterPlayerEvent(BetterPlayerEventType.bufferingStart));
    controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.bufferingEnd));

    // The watchdog's "stalled" error is not an ERROR.
    controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.exception,
        parameters: <String, dynamic>{
          'exception':
              'Video player stalled while buffering. Possible network connection loss.',
          'errorDetails': <String, dynamic>{'kind': 'stall'},
        }));

    await controller.telemetryManager.dispose();
    expect(types().where((t) => t == 'STALL_START'), hasLength(1));
    expect(types().where((t) => t == 'STALL_END'), hasLength(1));
    expect(types(), isNot(contains('ERROR')));
    final end = events().firstWhere((e) => e['type'] == 'STALL_END');
    expect(end['details']['durationMs'], greaterThanOrEqualTo(40));
  });

  test('A start that fails before play is reported with a fatal ERROR',
      () async {
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);
    await controller.setupDataSource(episode(7, telemetry: config()));

    controller.postEvent(nativeError());
    controller.postEvent(nativeError(isRepeat: true));
    await settle();
    expect(starts, hasLength(1));

    controller.dispose(forceDispose: true);
    await controller.telemetryManager.waitForPendingFlushes();

    expect(types(), isNot(contains('PLAYBACK_STARTED')));
    final errors = events().where((e) => e['type'] == 'ERROR').toList();
    expect(errors, hasLength(1));
    expect(errors.single['details'], {
      'code': 'ERROR_CODE_IO_BAD_HTTP_STATUS',
      'errorCode': 2004,
      'fatal': true,
      'httpStatus': 404,
      'host': 'kbl-cdn.movie.af',
      'message': 'Source error: Response code: 404',
      'count': 1,
    });
    expect(batches.last['isFinal'], isTrue);
  });

  test('Repeated errors with the same code are throttled with a count',
      () async {
    final telemetry = BetterPlayerTelemetryConfiguration(
      baseUrl: 'http://${server.address.host}:${server.port}',
      batchSendInterval: const Duration(hours: 1),
      errorRepeatInterval: const Duration(milliseconds: 200),
      httpClient: HttpClient(),
    );
    final (controller, _) = await playingEpisode(telemetry);

    controller.postEvent(nativeError());
    controller.postEvent(nativeError());
    controller.postEvent(nativeError());
    await settle(250);
    controller.postEvent(nativeError());
    await controller.telemetryManager.dispose();

    final errors = events().where((e) => e['type'] == 'ERROR').toList();
    expect(errors.map((e) => e['details']['count']), equals(<int>[1, 3]));
  });

  test('Fallback URL of the same episode keeps the session with CDN_SWITCH',
      () async {
    final telemetry = config();
    final (controller, _) = await playingEpisode(telemetry);
    final sessionId = controller.sessionId;

    controller.postEvent(nativeError(host: 'kbl-cdn.movie.af'));
    await controller.setupDataSource(episode(7,
        url: 'https://mzr-stream.movie.af/videos/1/playlist.m3u8',
        telemetry: telemetry));
    await controller.play(origin: BetterPlayerPlaybackOrigin.system);
    await controller.telemetryManager.dispose();

    expect(starts, hasLength(1));
    expect(controller.sessionId, sessionId);
    final cdnSwitch = events().firstWhere((e) => e['type'] == 'CDN_SWITCH');
    expect(cdnSwitch['details'], {
      'previousHost': 'kbl-cdn.movie.af',
      'newHost': 'mzr-stream.movie.af',
      'errorCode': 'ERROR_CODE_IO_BAD_HTTP_STATUS',
    });
  });

  test('Next episode on the same controller is a complete new session',
      () async {
    final telemetry =
        config(batchSendInterval: const Duration(milliseconds: 100));
    final (controller, video) = await playingEpisode(telemetry, episodeId: 1);
    final first = controller.sessionId;

    await controller.setupDataSource(episode(2, telemetry: telemetry));
    await controller.play(origin: BetterPlayerPlaybackOrigin.system);
    final second = controller.sessionId;
    await advanceTo(controller, video, const Duration(seconds: 1));
    await advanceTo(controller, video, const Duration(seconds: 2));
    await settle(400);

    expect(second, isNot(first));
    expect(starts.map((s) => s['episodeId']), equals(<int>[1, 2]));
    expect(starts.last['sessionId'], second);
    expect(
        batches.where((b) => b['sessionId'] == first && b['isFinal'] == true),
        hasLength(1));
    expect(types(second), contains('PLAYBACK_STARTED'));
    await controller.telemetryManager.dispose();
  });

  test('ENDED closes the session; playing again starts a new one', () async {
    final (controller, video) = await playingEpisode(config());
    final first = controller.sessionId;
    await advanceTo(
        controller, video, const Duration(minutes: 29, seconds: 58));

    controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.finished));
    await controller.telemetryManager.waitForPendingFlushes();
    expect(batches.last['isFinal'], isTrue);
    expect(types(first).last, 'ENDED');

    await video.seekTo(Duration.zero);
    await controller.play();
    await settle();
    expect(controller.sessionId, isNot(first));
    expect(starts, hasLength(2));
    await controller.telemetryManager.dispose();
  });

  test('Final batch is not lost while a periodic batch is in flight', () async {
    batchDelay = const Duration(milliseconds: 500);
    final (controller, video) = await playingEpisode(
        config(batchSendInterval: const Duration(milliseconds: 100)));
    await settle(150); // a periodic upload is now in flight
    await controller.pause();

    await controller.telemetryManager.dispose();

    expect(batches.last['isFinal'], isTrue);
    expect(types(), contains('PAUSE'));
  });

  test('Closing before sessions/start answers still delivers the session',
      () async {
    startDelay = const Duration(milliseconds: 400);
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);
    await controller.setupDataSource(episode(7, telemetry: config()));
    controller.postEvent(nativeError());

    await controller.telemetryManager.dispose();

    expect(starts, hasLength(1));
    expect(types(), contains('ERROR'));
    expect(batches.last['isFinal'], isTrue);
  });

  test('Seeks before the first frame only move the start position', () async {
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    video.setDuration(const Duration(minutes: 30));
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);
    await controller.setupDataSource(episode(7, telemetry: config()));
    await controller.play();
    await controller.seekTo(const Duration(minutes: 10)); // continue watching
    await advanceTo(controller, video, const Duration(minutes: 10));
    await advanceTo(
        controller, video, const Duration(minutes: 10, milliseconds: 300));
    await controller.seekTo(const Duration(minutes: 15));
    await controller.telemetryManager.dispose();

    final seeks = events().where((e) => e['type'] == 'SEEK').toList();
    expect(seeks, hasLength(1));
    expect(seeks.single['details']['fromS'], closeTo(600.3, 0.01));
    expect(seeks.single['details']['toS'], 900.0);
    expect(seeks.single['positionS'], 900.0);
    final started = events().firstWhere((e) => e['type'] == 'PLAYBACK_STARTED');
    expect(started['positionS'], closeTo(600.3, 0.01));
  });

  test('Session start uses the contract OS format', () async {
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);
    await controller.setupDataSource(
        episode(7, telemetry: config(), os: 'ANDROID 11 (API Level 30)'));
    await controller.play();
    await settle();
    await controller.telemetryManager.dispose();

    expect(starts.single['os'], 'Android 11 (API 30)');
    expect(BetterPlayerTelemetryUtils.normalizeOs('ANDROID 14 (API level 34)'),
        'Android 14 (API 34)');
    expect(
        BetterPlayerTelemetryUtils.normalizeOs('ANDROID 16.0 (API Level 29)'),
        'Android 16.0 (API 29)');
    expect(BetterPlayerTelemetryUtils.normalizeOs('IOS 17.5'), 'IOS 17.5');
  });

  test('Session start includes deviceModel when provided', () async {
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);
    controller.telemetryManager.startSession(
      configuration: config(),
      telemetryData: const BetterPlayerTelemetryData(
        episodeId: 7,
        deviceModel: 'Amlogic X96Max_Plus2',
      ),
    );
    await settle();
    await controller.telemetryManager.dispose();

    expect(starts.single['deviceModel'], 'Amlogic X96Max_Plus2');
    expect(
      BetterPlayerTelemetryUtils.deviceModelFromDeviceInfo(
          <String, dynamic>{'manufacturer': 'samsung', 'model': 'SM-A145F'}),
      'samsung SM-A145F',
    );
  });

  BetterPlayerEvent connectivityError() => BetterPlayerEvent(
        BetterPlayerEventType.exception,
        parameters: <String, dynamic>{
          'exception': 'Video player had error z5.r: Source error',
          'errorDetails': <String, dynamic>{
            'kind': 'playback',
            'code': 'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED',
            'errorCode': 2001,
            'fatal': false,
            'httpStatus': null,
            'host': 'kbl-cdn.movie.af',
            'message': 'Source error',
          },
        },
      );

  test('A self-recovering network error keeps the stall open and paired',
      () async {
    final (controller, video) = await playingEpisode(config());
    await advanceTo(controller, video, const Duration(seconds: 5));

    controller
        .postEvent(BetterPlayerEvent(BetterPlayerEventType.bufferingStart));
    controller.postEvent(connectivityError());
    await settle(50);
    controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.bufferingEnd));
    await controller.telemetryManager.dispose();

    expect(types().where((t) => t.startsWith('STALL')).toList(),
        equals(<String>['STALL_START', 'STALL_END']));
    final error = events().firstWhere((e) => e['type'] == 'ERROR');
    expect(error['details']['fatal'], isFalse);
  });

  test('A fatal error during a stall closes the stall', () async {
    final (controller, video) = await playingEpisode(config());
    await advanceTo(controller, video, const Duration(seconds: 5));

    controller
        .postEvent(BetterPlayerEvent(BetterPlayerEventType.bufferingStart));
    controller.postEvent(nativeError());
    controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.bufferingEnd));
    await controller.telemetryManager.dispose();

    expect(types().where((t) => t.startsWith('STALL')).toList(),
        equals(<String>['STALL_START', 'STALL_END']));
  });

  test('Retry and quality re-setup restore the position without a SEEK',
      () async {
    final (controller, video) = await playingEpisode(config());
    for (final s in <int>[2, 4, 6, 8, 10]) {
      await advanceTo(controller, video, Duration(seconds: s));
    }

    // retryDataSource: the source is set up again, the position reads 0,
    // then the old position is restored by a seek.
    await controller.retryDataSource(
        resumePosition: const Duration(seconds: 10), playOnSuccess: true);
    for (final s in <int>[11, 12, 13]) {
      await advanceTo(controller, video, Duration(seconds: s));
    }
    await controller.telemetryManager.dispose();

    expect(types(), isNot(contains('SEEK')));
    final ranges = batches
        .expand((b) => b['watchedRanges'] as List)
        .cast<Map<String, dynamic>>();
    for (final range in ranges) {
      expect(range['toS'] as num, greaterThanOrEqualTo(range['fromS'] as num));
    }
    expect(starts, hasLength(1));
  });

  test('An early finished event does not end the session', () async {
    final (controller, video) = await playingEpisode(config());
    final sessionId = controller.sessionId;
    await advanceTo(controller, video, const Duration(minutes: 3));

    controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.finished));
    await controller.play();
    expect(controller.sessionId, sessionId);
    expect(controller.telemetryManager.isSessionActive, isTrue);

    await advanceTo(
        controller, video, const Duration(minutes: 29, seconds: 55));
    controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.finished));
    await controller.telemetryManager.waitForPendingFlushes();
    expect(controller.telemetryManager.isSessionActive, isFalse);
    expect(types().where((t) => t == 'ENDED'), hasLength(1));
    expect(starts, hasLength(1));
  });

  test('No first frame while the player buffers after a start seek', () async {
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    video.setDuration(const Duration(minutes: 30));
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);
    await controller.setupDataSource(episode(7, telemetry: config()));
    await controller.play();
    video.setBuffering(true);
    await advanceTo(controller, video, const Duration(minutes: 5)); // startAt
    expect(controller.telemetryManager.pendingPlaybackEvents, isEmpty);
    video.setBuffering(false);
    await advanceTo(
        controller, video, const Duration(minutes: 5, milliseconds: 300));
    await controller.telemetryManager.dispose();

    final started = events().firstWhere((e) => e['type'] == 'PLAYBACK_STARTED');
    expect(started['positionS'], closeTo(300.3, 0.01));
  });

  BetterPlayerNetworkLog segmentLog(String url, {String? trackType}) =>
      BetterPlayerNetworkLog(
        id: url,
        url: url,
        phase: BetterPlayerNetworkLogPhase.completed,
        dataType: BetterPlayerNetworkDataType.mediaSegment,
        trackType: trackType,
        bytesLoaded: 1000,
        durationMs: 10,
        timestamp: DateTime.now(),
        mediaStartTimeMs: 0,
        mediaEndTimeMs: 4000,
      );

  test('CDN_SWITCH only when video segments move to another host', () async {
    final (controller, _) = await playingEpisode(config());
    final manager = controller.telemetryManager;

    // Redirected source: segments come from another host than fileUrl.
    manager.handleNetworkLog(BetterPlayerNetworkLog(
      id: 'master',
      url: 'https://cdn.movie.af/videos/1/hls/720p.m3u8',
      phase: BetterPlayerNetworkLogPhase.completed,
      dataType: BetterPlayerNetworkDataType.manifest,
      timestamp: DateTime.now(),
    ));
    manager.handleNetworkLog(segmentLog('https://hrt-cdn.movie.af/s1.ts'));
    manager.handleNetworkLog(
        segmentLog('https://subs.movie.af/s1.vtt', trackType: 'text'));
    manager.handleNetworkLog(
        segmentLog('https://audio.movie.af/a1.ts', trackType: 'audio'));
    manager.handleNetworkLog(segmentLog('https://hrt-cdn.movie.af/s2.ts'));
    expect(manager.pendingPlaybackEvents.where((e) => e.type == 'CDN_SWITCH'),
        isEmpty);

    manager.handleNetworkLog(segmentLog('https://mzr-cdn.movie.af/s3.ts'));
    await manager.dispose();
    final cdn = events().where((e) => e['type'] == 'CDN_SWITCH').toList();
    expect(cdn, hasLength(1));
    expect(cdn.single['details']['previousHost'], 'hrt-cdn.movie.af');
    expect(cdn.single['details']['newHost'], 'mzr-cdn.movie.af');
  });

  test('Sessions closed while the server is unreachable are delivered later',
      () async {
    final (controller, _) = await playingEpisode(config());
    batchStatus = HttpStatus.serviceUnavailable;

    await controller.telemetryManager.dispose();
    expect(batches, isEmpty);
    expect(BetterPlayerTelemetryManager.undeliveredSessionCount, 1);

    batchStatus = HttpStatus.ok;
    await BetterPlayerTelemetryManager.retryUndeliveredSessions();
    expect(BetterPlayerTelemetryManager.undeliveredSessionCount, 0);
    expect(batches.last['isFinal'], isTrue);
    expect(types(), contains('PLAYBACK_STARTED'));
  });

  test('Repeated native error reports are counted', () async {
    final telemetry = BetterPlayerTelemetryConfiguration(
      baseUrl: 'http://${server.address.host}:${server.port}',
      batchSendInterval: const Duration(hours: 1),
      errorRepeatInterval: const Duration(milliseconds: 200),
      httpClient: HttpClient(),
    );
    final (controller, _) = await playingEpisode(telemetry);
    for (var i = 0; i < 4; i++) {
      controller.postEvent(connectivityError());
    }
    await settle(250);
    controller.postEvent(connectivityError());
    await controller.telemetryManager.dispose();

    final errors = events().where((e) => e['type'] == 'ERROR').toList();
    expect(errors.map((e) => e['details']['count']), equals(<int>[1, 4]));
  });
}
