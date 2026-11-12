// Tests for live TV channel telemetry ("Mobile & STB app: live TV telemetry
// you must add", Oct 28 2026): channelId sessions, one session per channel,
// period positions, liveLatencyS, no language events, errors that never end
// the session, and live telemetry being off on iOS.
import 'dart:convert';
import 'dart:io';

import 'package:better_player/better_player.dart';
import 'package:better_player/src/video_player/video_player_platform_interface.dart';
import 'package:flutter/foundation.dart';
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
  // Order of the requests: "start:<sessionId>" and "batch:<sessionId>:<final>".
  final requestLog = <String>[];

  setUp(() async {
    starts.clear();
    batches.clear();
    requestLog.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final body =
          jsonDecode(await utf8.decodeStream(request)) as Map<String, dynamic>;
      if (request.uri.path.endsWith('sessions/start')) {
        starts.add(body);
        requestLog.add('start:${body['sessionId']}');
      } else {
        batches.add(body);
        requestLog.add('batch:${body['sessionId']}:${body['isFinal']}');
      }
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.json
        ..write('{}')
        ..close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  BetterPlayerTelemetryConfiguration config({
    Duration bufferSampleInterval = const Duration(seconds: 5),
  }) =>
      BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        bufferSampleInterval: bufferSampleInterval,
        httpClient: HttpClient(),
      );

  BetterPlayerDataSource channel(
    int channelId, {
    String url =
        'https://kbl-stream.movie.af/live/smil:tolo.smil/playlist.m3u8',
    int? eventId,
    BetterPlayerTelemetryConfiguration? telemetry,
  }) =>
      BetterPlayerDataSource.network(
        url,
        liveStream: true,
        channelId: channelId,
        eventId: eventId,
        platform: 'STB',
        deviceType: 'TV',
        os: 'Android 11 (API 30)',
        telemetryConfiguration: telemetry,
      );

  List<Map<String, dynamic>> events([String? sessionId]) => batches
      .where((b) => sessionId == null || b['sessionId'] == sessionId)
      .expand((b) => b['playbackEvents'] as List)
      .cast<Map<String, dynamic>>()
      .toList();

  List<String> types([String? sessionId]) =>
      events(sessionId).map((e) => e['type'] as String).toList();

  List<Map<String, dynamic>> ranges([String? sessionId]) => batches
      .where((b) => sessionId == null || b['sessionId'] == sessionId)
      .expand((b) => b['watchedRanges'] as List)
      .cast<Map<String, dynamic>>()
      .toList();

  List<Map<String, dynamic>> samples() => batches
      .expand((b) => b['bufferSamples'] as List)
      .cast<Map<String, dynamic>>()
      .toList();

  Future<void> settle([int ms = 150]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  // The stream started long ago: period positions are large.
  const periodOffsetMs = 27000000;

  // Moves the live player: [windowMs] is the player (live window) position,
  // [periodMs] the position in the period.
  Future<void> liveAt(
    BetterPlayerController controller,
    MockVideoPlayerController video, {
    required int windowMs,
    required int periodMs,
    int? liveOffsetMs = 15300,
    bool progress = true,
  }) async {
    await video.seekTo(Duration(milliseconds: windowMs));
    video.livePlaybackInfo = <String, dynamic>{
      'isLive': true,
      'positionMs': windowMs,
      'periodPositionMs': periodMs,
      'liveOffsetMs': liveOffsetMs,
      'bufferedAheadMs': 9200,
    };
    await controller.telemetryManager.refreshLivePlaybackInfo();
    if (progress) {
      controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.progress));
    }
  }

  void nativeEvent(MockVideoPlayerController video, VideoEvent event) =>
      video.videoEventStreamController.add(event);

  // Plays [channelId]: setup, play, first frame at period 27000 s.
  Future<(BetterPlayerMockController, MockVideoPlayerController)>
      playingChannel(
    BetterPlayerTelemetryConfiguration telemetry, {
    int channelId = 12,
    int? eventId,
  }) async {
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);
    await controller.setupDataSource(
        channel(channelId, eventId: eventId, telemetry: telemetry));
    await controller.play();
    await liveAt(controller, video,
        windowMs: 30000, periodMs: periodOffsetMs, progress: false);
    nativeEvent(
        video, VideoEvent(eventType: VideoEventType.firstFrame, key: null));
    await settle();
    return (controller, video);
  }

  test('Session start sends channelId, no episodeId, and eventId only if set',
      () async {
    final (controller, _) = await playingChannel(config());
    await controller.telemetryManager.dispose();

    final start = starts.single;
    expect(start['channelId'], 12);
    expect(start.containsKey('episodeId'), isFalse);
    expect(start.containsKey('eventId'), isFalse);
    expect(start['platform'], 'STB');
    expect(start['deviceType'], 'TV');
    expect(start['os'], 'Android 11 (API 30)');
    expect(start['fileUrl'],
        'https://kbl-stream.movie.af/live/smil:tolo.smil/playlist.m3u8');

    starts.clear();
    final (fromEvent, _) = await playingChannel(config(), eventId: 341);
    await fromEvent.telemetryManager.dispose();
    expect(starts.single['channelId'], 12);
    expect(starts.single['eventId'], 341);
    expect(starts.single.containsKey('episodeId'), isFalse);
  });

  test('Session data never pairs channelId with episodeId', () {
    const vod = BetterPlayerTelemetryData(episodeId: 7, channelId: 12);
    final vodMap = vod.toMap(sessionId: 's', startedAt: 't');
    expect(vod.isLiveChannel, isFalse);
    expect(vodMap['episodeId'], 7);
    expect(vodMap.containsKey('channelId'), isFalse);

    const eventOnly = BetterPlayerTelemetryData(eventId: 341);
    final eventOnlyMap = eventOnly.toMap(sessionId: 's', startedAt: 't');
    expect(eventOnlyMap.containsKey('eventId'), isFalse);
    expect(eventOnlyMap.containsKey('channelId'), isFalse);

    const live = BetterPlayerTelemetryData(channelId: '15', eventId: 341);
    final liveMap = live.toMap(sessionId: 's', startedAt: 't');
    expect(live.isLiveChannel, isTrue);
    expect(liveMap['channelId'], 15);
    expect(liveMap['eventId'], 341);
    expect(liveMap.containsKey('episodeId'), isFalse);
  });

  test(
      'First frame sends PLAYBACK_STARTED at the period position, no languages',
      () async {
    final (controller, video) = await playingChannel(config());

    // Track changes on a channel are never reported.
    controller.postEvent(BetterPlayerEvent(
        BetterPlayerEventType.changedAudioTrack,
        parameters: <String, dynamic>{'from': 'fa', 'to': 'en'}));
    controller.postEvent(BetterPlayerEvent(
        BetterPlayerEventType.changedSubtitles,
        parameters: <String, dynamic>{'from': null, 'to': 'fa'}));
    await liveAt(controller, video, windowMs: 32000, periodMs: 27002000);
    await controller.telemetryManager.dispose();

    expect(types(), contains('PLAYBACK_STARTED'));
    expect(types(), isNot(contains('AUDIO_LANGUAGE_CHANGED')));
    expect(types(), isNot(contains('SUBTITLE_CHANGED')));
    final started = events().firstWhere((e) => e['type'] == 'PLAYBACK_STARTED');
    expect(started['positionS'], 27000.0);
    expect(started['details']['startupMs'], isA<int>());
    expect(types().where((t) => t == 'PLAYBACK_STARTED'), hasLength(1));
  });

  test('Startup is measured from the stream request (setup)', () async {
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);
    await controller.setupDataSource(channel(12, telemetry: config()));
    await settle(300);
    await controller.play();
    await liveAt(controller, video,
        windowMs: 30000, periodMs: periodOffsetMs, progress: false);
    nativeEvent(
        video, VideoEvent(eventType: VideoEventType.firstFrame, key: null));
    await settle();
    await controller.telemetryManager.dispose();

    final startupMs =
        events().firstWhere((e) => e['type'] == 'PLAYBACK_STARTED')['details']
            ['startupMs'] as int;
    expect(startupMs, greaterThanOrEqualTo(300));
  });

  test('A stream loaded under a pre-roll ad does not count the ad as startup',
      () async {
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);
    await controller.setupDataSource(channel(12, telemetry: config()));
    // The first frame renders while paused; the ad then plays elsewhere.
    nativeEvent(
        video, VideoEvent(eventType: VideoEventType.firstFrame, key: null));
    await settle(600);
    expect(controller.telemetryManager.isSessionArmed, isTrue);

    await controller.play();
    await liveAt(controller, video,
        windowMs: 30000, periodMs: periodOffsetMs, progress: false);
    controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.progress));
    await liveAt(controller, video,
        windowMs: 31000, periodMs: periodOffsetMs + 1000);
    await settle();
    await controller.telemetryManager.dispose();

    final started = events().firstWhere((e) => e['type'] == 'PLAYBACK_STARTED');
    expect(started['details']['startupMs'] as int, lessThan(400));
    expect(started['positionS'], 27000.0);
  });

  test('Watched ranges use period positions while the live window slides',
      () async {
    final (controller, video) = await playingChannel(config());

    // 20 s of playback. The window slides by 6 s every 6 s, so the player
    // position keeps dropping back; the period position keeps growing.
    for (var second = 1; second <= 20; second++) {
      final windowMs = 30000 + (second % 6) * 1000;
      await liveAt(controller, video,
          windowMs: windowMs, periodMs: periodOffsetMs + second * 1000);
    }
    controller.dispose(forceDispose: true);
    await controller.telemetryManager.waitForPendingFlushes();

    final watched = ranges();
    final totalS = watched.fold<double>(
        0, (sum, r) => sum + (r['toS'] as num) - (r['fromS'] as num));
    expect(totalS, closeTo(20, 1));
    expect(watched, hasLength(1));
    expect(watched.single['fromS'], greaterThanOrEqualTo(27000));
    expect(batches.last['isFinal'], isTrue);
    expect(types(), isNot(contains('PAUSE')));
    expect(types(), isNot(contains('SEEK')));
  });

  test('Buffer samples carry liveLatencyS, left out when unknown', () async {
    final (controller, video) = await playingChannel(
        config(bufferSampleInterval: const Duration(milliseconds: 100)));
    await liveAt(controller, video,
        windowMs: 31000, periodMs: periodOffsetMs + 1000, liveOffsetMs: 15349);
    await settle(250);
    await liveAt(controller, video,
        windowMs: 32000, periodMs: periodOffsetMs + 2000, liveOffsetMs: null);
    await settle(250);
    await liveAt(controller, video,
        windowMs: 33000, periodMs: periodOffsetMs + 3000, liveOffsetMs: -400);
    await settle(250);
    await controller.telemetryManager.dispose();

    final all = samples();
    expect(all, isNotEmpty);
    for (final sample in all) {
      expect(sample['positionS'], greaterThanOrEqualTo(27000));
      expect(sample['bufferedAheadS'], 9.2);
    }
    final latencies = all.map((s) => s['liveLatencyS']).toList();
    expect(latencies, contains(15.3));
    expect(latencies, contains(0.0));
    expect(all.any((s) => !s.containsKey('liveLatencyS')), isTrue);
    expect(latencies.whereType<num>().every((l) => l >= 0), isTrue);
  });

  test('Changing channel ends the old session before the new one starts',
      () async {
    final (controller, video) = await playingChannel(config());
    final firstSessionId = controller.sessionId;
    await liveAt(controller, video, windowMs: 35000, periodMs: 27005000);

    // Channel up: 12 -> 15 on the same player.
    await controller.setupDataSource(channel(15, telemetry: config()));
    await controller.play();
    await liveAt(controller, video,
        windowMs: 30000, periodMs: 54000000, progress: false);
    nativeEvent(
        video, VideoEvent(eventType: VideoEventType.firstFrame, key: null));
    await settle(400);
    final secondSessionId = controller.sessionId;
    await controller.telemetryManager.dispose();

    expect(secondSessionId, isNot(firstSessionId));
    expect(starts.map((s) => s['channelId']), [12, 15]);
    final finalOld = requestLog.indexOf('batch:$firstSessionId:true');
    final startNew = requestLog.indexOf('start:$secondSessionId');
    expect(finalOld, greaterThanOrEqualTo(0));
    expect(startNew, greaterThan(finalOld));
    expect(types(firstSessionId), isNot(contains('PAUSE')));
    expect(ranges(firstSessionId), isNotEmpty);
  });

  test('A fallback URL or retry of the same channel keeps the session',
      () async {
    final (controller, video) = await playingChannel(config());
    final sessionId = controller.sessionId;
    await liveAt(controller, video, windowMs: 33000, periodMs: 27003000);

    await controller.setupDataSource(channel(12,
        url: 'https://mzr-stream.movie.af/live/smil:tolo.smil/playlist.m3u8',
        telemetry: config()));
    await controller.play();
    await settle();
    expect(controller.sessionId, sessionId);
    await controller.telemetryManager.dispose();

    expect(starts, hasLength(1));
    final cdn = events().firstWhere((e) => e['type'] == 'CDN_SWITCH');
    expect(cdn['details']['previousHost'], 'kbl-stream.movie.af');
    expect(cdn['details']['newHost'], 'mzr-stream.movie.af');
  });

  test('A fatal error is reported but never ends the session', () async {
    final (controller, video) = await playingChannel(config());
    final sessionId = controller.sessionId;
    await liveAt(controller, video, windowMs: 34000, periodMs: 27004000);

    controller.postEvent(BetterPlayerEvent(
      BetterPlayerEventType.exception,
      parameters: <String, dynamic>{
        'exception': 'Video player had error',
        'errorDetails': <String, dynamic>{
          'kind': 'playback',
          'code': 'ERROR_CODE_IO_BAD_HTTP_STATUS',
          'errorCode': 2004,
          'fatal': true,
          'httpStatus': 404,
          'host': 'kbl-stream.movie.af',
          'message': 'Response code: 404',
        },
        'isRepeat': false,
      },
    ));
    await settle();

    expect(controller.telemetryManager.isSessionActive, isTrue);
    expect(controller.sessionId, sessionId);
    expect(batches.where((b) => b['isFinal'] == true), isEmpty);
    final error = events().firstWhere((e) => e['type'] == 'ERROR');
    expect(error['details']['code'], 'ERROR_CODE_IO_BAD_HTTP_STATUS');
    expect(error['details']['fatal'], isTrue);
    expect(error['details']['message'], 'Response code: 404');
    expect(error['positionS'], 27004.0);
    // The fatal error closed the watched range.
    expect(ranges().last['toS'], 27004.0);

    await controller.telemetryManager.dispose();
    expect(batches.where((b) => b['isFinal'] == true), hasLength(1));
    expect(starts, hasLength(1));
  });

  test('A failed channel start reports the error and no PLAYBACK_STARTED',
      () async {
    final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: video);
    await controller.setupDataSource(channel(12, telemetry: config()));
    await controller.play();
    controller.postEvent(BetterPlayerEvent(
      BetterPlayerEventType.exception,
      parameters: <String, dynamic>{
        'exception': 'Video player had error',
        'errorDetails': <String, dynamic>{
          'code': 'ERROR_CODE_IO_BAD_HTTP_STATUS',
          'errorCode': 2004,
          'fatal': true,
          'httpStatus': 404,
          'message': 'Response code: 404',
        },
      },
    ));
    await settle();
    controller.dispose(forceDispose: true);
    await controller.telemetryManager.waitForPendingFlushes();

    expect(starts, hasLength(1));
    expect(types(), ['ERROR']);
    expect(events().single['positionS'], 0.0);
    expect(batches.last['isFinal'], isTrue);
  });

  test('Behind-live-window recovery is a non-fatal ERROR, not an error state',
      () async {
    final (controller, video) = await playingChannel(config());
    await liveAt(controller, video, windowMs: 33000, periodMs: 27003000);
    final appEvents = <BetterPlayerEventType>[];
    controller.addEventsListener((e) => appEvents.add(e.betterPlayerEventType));

    nativeEvent(
        video,
        VideoEvent(
          eventType: VideoEventType.recoveredError,
          key: null,
          errorDetails: <String, dynamic>{
            'kind': 'playback',
            'code': 'ERROR_CODE_BEHIND_LIVE_WINDOW',
            'errorCode': 1002,
            'fatal': false,
            'message': 'Behind live window',
          },
        ));
    await settle();
    await controller.telemetryManager.dispose();

    final error = events().firstWhere((e) => e['type'] == 'ERROR');
    expect(error['details']['code'], 'ERROR_CODE_BEHIND_LIVE_WINDOW');
    expect(error['details']['fatal'], isFalse);
    expect(video.value.hasError, isFalse);
    expect(appEvents, isNot(contains(BetterPlayerEventType.exception)));
  });

  test('The end of a live stream sends ENDED but keeps the session', () async {
    final (controller, video) = await playingChannel(config());
    await liveAt(controller, video, windowMs: 33000, periodMs: 27003000);

    controller.postEvent(BetterPlayerEvent(BetterPlayerEventType.finished));
    await settle();
    expect(controller.telemetryManager.isSessionActive, isTrue);
    expect(batches.where((b) => b['isFinal'] == true), isEmpty);

    await controller.telemetryManager.dispose();
    expect(types(), contains('ENDED'));
    expect(batches.where((b) => b['isFinal'] == true), hasLength(1));
  });

  test('A pause closes the range; only a user pause is a PAUSE event',
      () async {
    final (controller, video) = await playingChannel(config());
    await liveAt(controller, video, windowMs: 33000, periodMs: 27003000);

    // Mid-roll ad: system pause, no PAUSE event, the range closes.
    await controller.pause(origin: BetterPlayerPlaybackOrigin.system);
    await controller.play(origin: BetterPlayerPlaybackOrigin.system);
    await liveAt(controller, video, windowMs: 34000, periodMs: 27004000);
    await liveAt(controller, video, windowMs: 36000, periodMs: 27006000);

    // The viewer pauses.
    await controller.pause();
    await controller.play();
    await liveAt(controller, video, windowMs: 37000, periodMs: 27007000);
    await liveAt(controller, video, windowMs: 39000, periodMs: 27009000);
    await controller.telemetryManager.dispose();

    expect(types().where((t) => t == 'PAUSE'), hasLength(1));
    expect(types().where((t) => t == 'RESUME'), hasLength(1));
    expect(types(), isNot(contains('SEEK')));
    final watched = ranges();
    expect(watched, hasLength(3));
    expect(watched.map((r) => r['rangeId']).toSet(), hasLength(3));
    expect(watched[0]['toS'], 27003.0);
    expect(watched[1]['fromS'], 27003.0);
    expect(watched[1]['toS'], 27006.0);
    expect(watched[2]['toS'], 27009.0);
  });

  test('Timestamps have millisecond precision', () async {
    final (controller, video) = await playingChannel(config());
    await liveAt(controller, video, windowMs: 33000, periodMs: 27003000);
    await controller.telemetryManager.dispose();

    final iso = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$');
    expect(starts.single['startedAt'], matches(iso));
    for (final batch in batches) {
      expect(batch['sentAt'], matches(iso));
    }
    for (final event in events()) {
      expect(event['ts'], matches(iso));
    }
  });

  test('Live channel telemetry is off on iOS; VOD still reports', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final video = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
          controller: video);
      await controller.setupDataSource(channel(12, telemetry: config()));
      expect(controller.telemetryManager.isSessionArmed, isFalse);
      await controller.play();
      await settle();
      await controller.telemetryManager.dispose();
      expect(starts, isEmpty);
      expect(batches, isEmpty);

      final vodVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final vod = BetterPlayerTestUtils.setupBetterPlayerMockController(
          controller: vodVideo);
      await vod.setupDataSource(BetterPlayerDataSource.network(
        'https://kbl-cdn.movie.af/videos/1/hls/master.m3u8',
        episodeId: 7,
        telemetryConfiguration: config(),
      ));
      await vod.play();
      await settle();
      await vod.telemetryManager.dispose();
      expect(starts.single['episodeId'], 7);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
