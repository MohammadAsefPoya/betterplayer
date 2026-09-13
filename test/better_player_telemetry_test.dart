import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:better_player/better_player.dart';
import 'package:flutter_test/flutter_test.dart';

import 'better_player_mock_controller.dart';
import 'better_player_test_utils.dart';
import 'mock_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final MockMethodChannel mockMethodChannel = MockMethodChannel();

  setUpAll(() {
    HttpOverrides.global = null;
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance!.defaultBinaryMessenger
        .setMockMethodCallHandler(
            mockMethodChannel.channel, mockMethodChannel.handle);
  });

  group('BetterPlayerTelemetryUtils Tests', () {
    test('generateUuidV4 returns valid RFC 4122 v4 UUID', () {
      final uuidRegex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );

      for (int i = 0; i < 100; i++) {
        final uuid = BetterPlayerTelemetryUtils.generateUuidV4();
        expect(uuidRegex.hasMatch(uuid), isTrue,
            reason: 'UUID $uuid should match RFC 4122 v4 format');
      }
    });

    test('generateUuidV4 generates unique values', () {
      final set = <String>{};
      for (int i = 0; i < 1000; i++) {
        final uuid = BetterPlayerTelemetryUtils.generateUuidV4();
        expect(set.contains(uuid), isFalse);
        set.add(uuid);
      }
      expect(set.length, equals(1000));
    });

    test('getOperatingSystem returns non-empty string and clamps to 100 chars', () {
      final os = BetterPlayerTelemetryUtils.getOperatingSystem();
      expect(os.isNotEmpty, isTrue);
      expect(os.length, lessThanOrEqualTo(100));
    });

    test('normalizePlatform validates and normalizes platforms', () {
      expect(BetterPlayerTelemetryUtils.normalizePlatform('android'), equals('ANDROID'));
      expect(BetterPlayerTelemetryUtils.normalizePlatform('ios'), equals('IOS'));
      expect(BetterPlayerTelemetryUtils.normalizePlatform('web'), equals('WEB'));
      expect(BetterPlayerTelemetryUtils.normalizePlatform('android_tv'), equals('ANDROID_TV'));
      expect(BetterPlayerTelemetryUtils.normalizePlatform('old_web_tv'), equals('OLD_WEB_TV'));

      // Invalid/empty fallback
      final defaultPlatform = BetterPlayerTelemetryUtils.resolveDefaultPlatform();
      expect(BetterPlayerTelemetryUtils.normalizePlatform(null), equals(defaultPlatform));
      expect(BetterPlayerTelemetryUtils.normalizePlatform(''), equals(defaultPlatform));
      expect(BetterPlayerTelemetryUtils.normalizePlatform('invalid_platform'), equals(defaultPlatform));
    });

    test('normalizeDeviceType validates and normalizes device types', () {
      expect(BetterPlayerTelemetryUtils.normalizeDeviceType('mobile'), equals('MOBILE'));
      expect(BetterPlayerTelemetryUtils.normalizeDeviceType('tablet'), equals('TABLET'));
      expect(BetterPlayerTelemetryUtils.normalizeDeviceType('desktop'), equals('DESKTOP'));
      expect(BetterPlayerTelemetryUtils.normalizeDeviceType('tv'), equals('TV'));
      expect(BetterPlayerTelemetryUtils.normalizeDeviceType('unknown'), equals('UNKNOWN'));

      // Invalid/empty fallback
      final defaultDeviceType = BetterPlayerTelemetryUtils.resolveDefaultDeviceType();
      expect(BetterPlayerTelemetryUtils.normalizeDeviceType(null), equals(defaultDeviceType));
      expect(BetterPlayerTelemetryUtils.normalizeDeviceType(''), equals(defaultDeviceType));
      expect(BetterPlayerTelemetryUtils.normalizeDeviceType('watch'), equals(defaultDeviceType));
    });

    test('normalizeEpisodeId parses valid positive integers', () {
      expect(BetterPlayerTelemetryUtils.normalizeEpisodeId(123), equals(123));
      expect(BetterPlayerTelemetryUtils.normalizeEpisodeId('456'), equals(456));
      expect(BetterPlayerTelemetryUtils.normalizeEpisodeId(789.0), equals(789));
      expect(BetterPlayerTelemetryUtils.normalizeEpisodeId(-5), equals(1)); // at least 1
      expect(BetterPlayerTelemetryUtils.normalizeEpisodeId('0'), equals(1));
      expect(BetterPlayerTelemetryUtils.normalizeEpisodeId('invalid'), isNull);
      expect(BetterPlayerTelemetryUtils.normalizeEpisodeId(null), isNull);
    });

    test('formatIsoTimestamp returns UTC ISO8601 string', () {
      final now = DateTime.utc(2026, 9, 10, 8, 0, 0);
      final formatted = BetterPlayerTelemetryUtils.formatIsoTimestamp(now);
      expect(formatted, equals('2026-09-10T08:00:00.000Z'));
    });

    test('sanitizeEventDetails removes tokens and limits size', () {
      final rawDetails = <String, dynamic>{
        'normalKey': 'normalValue',
        'authToken': 'secret123',
        'bearer_token': 'secret456',
        'password': 'pass',
        'userSignature': 'sig',
        'mediaUrl': 'https://cdn.example.com/segment.ts?token=xyz&signature=123',
      };

      final sanitized =
          BetterPlayerTelemetryUtils.sanitizeEventDetails(rawDetails);

      expect(sanitized.containsKey('normalKey'), isTrue);
      expect(sanitized['normalKey'], equals('normalValue'));
      expect(sanitized.containsKey('authToken'), isFalse);
      expect(sanitized.containsKey('bearer_token'), isFalse);
      expect(sanitized.containsKey('password'), isFalse);
      expect(sanitized.containsKey('userSignature'), isFalse);
      // Stripped query parameters from URL
      expect(sanitized['mediaUrl'], equals('https://cdn.example.com/segment.ts'));
    });

    test('sanitizeEventDetails enforces max size limit', () {
      final hugeDetails = <String, dynamic>{
        'huge': 'A' * 9000,
      };

      final sanitized = BetterPlayerTelemetryUtils.sanitizeEventDetails(
        hugeDetails,
        maxBytes: 1000,
      );
      expect(sanitized.containsKey('warning'), isTrue);
    });
  });

  group('BetterPlayerTelemetry Models Tests', () {
    test('BetterPlayerTelemetryConfiguration correctly builds URIs', () {
      const config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'https://telemetry.example.com',
      );
      expect(
        config.startSessionUri.toString(),
        equals('https://telemetry.example.com/api/v1/client/statistics/sessions/start'),
      );
      expect(
        config.batchEventsUri.toString(),
        equals('https://telemetry.example.com/api/v1/client/statistics/events/batch'),
      );
    });

    test('BetterPlayerTelemetryConfiguration with null or empty baseUrl has hasValue = false and null URIs', () {
      const configEmpty = BetterPlayerTelemetryConfiguration();
      expect(configEmpty.baseUrl, isNull);
      expect(configEmpty.hasValue, isFalse);
      expect(configEmpty.startSessionUri, isNull);
      expect(configEmpty.batchEventsUri, isNull);

      const configBlank = BetterPlayerTelemetryConfiguration(baseUrl: '   ');
      expect(configBlank.hasValue, isFalse);
      expect(configBlank.startSessionUri, isNull);
      expect(configBlank.batchEventsUri, isNull);

      const configDisabled = BetterPlayerTelemetryConfiguration(
        baseUrl: 'https://telemetry.example.com',
        enabled: false,
      );
      expect(configDisabled.hasValue, isFalse);
    });

    test('BetterPlayerTelemetryData serializes to map correctly with normalized fields', () {
      const data = BetterPlayerTelemetryData(
        episodeId: '123',
        platform: 'android',
        deviceType: 'mobile',
        os: 'Android 14',
      );
      final map = data.toMap(
        sessionId: 'test-session-id',
        startedAt: '2026-09-10T08:00:00.000Z',
      );

      expect(map['sessionId'], equals('test-session-id'));
      expect(map['episodeId'], equals(123)); // parsed to integer
      expect(map['platform'], equals('ANDROID')); // uppercase enum
      expect(map['deviceType'], equals('MOBILE')); // uppercase enum
      expect(map['os'], equals('Android 14'));
      expect(map['startedAt'], equals('2026-09-10T08:00:00.000Z'));
    });

    test('BetterPlayerTelemetryData strips userId and profileId from JSON body', () {
      const data = BetterPlayerTelemetryData(
        episodeId: 100,
        extra: {
          'userId': 'user_123',
          'profileId': 'profile_456',
          'user_id': 789,
          'allowedExtra': 'safeValue',
        },
      );
      final map = data.toMap(
        sessionId: 'test-session-id',
        startedAt: '2026-09-10T08:00:00.000Z',
      );

      expect(map.containsKey('userId'), isFalse);
      expect(map.containsKey('profileId'), isFalse);
      expect(map.containsKey('user_id'), isFalse);
      expect(map['allowedExtra'], equals('safeValue'));
    });

    test('BetterPlayerTelemetryData omits optional os and episodeId if null, and auto-defaults required platform/deviceType', () {
      const data = BetterPlayerTelemetryData(
        platform: '   ',
        os: null,
      );
      expect(data.hasValue, isFalse);

      final map = data.toMap(
        sessionId: 'test-session-id',
        startedAt: '2026-09-10T08:00:00.000Z',
      );

      expect(map.containsKey('episodeId'), isFalse);
      expect(map.containsKey('os'), isFalse);
      expect(map['platform'], isNotNull);
      expect(BetterPlayerTelemetryUtils.allowedPlatforms.contains(map['platform']), isTrue);
      expect(map['deviceType'], isNotNull);
      expect(BetterPlayerTelemetryUtils.allowedDeviceTypes.contains(map['deviceType']), isTrue);
      expect(map['sessionId'], equals('test-session-id'));
      expect(map['startedAt'], equals('2026-09-10T08:00:00.000Z'));
    });

    test('BetterPlayerChunkLoadMetric serializes with required non-null integer level', () {
      const chunk = BetterPlayerChunkLoadMetric(
        chunkSeq: 0,
        level: 1,
        startS: 0.0,
        endS: 6.0,
        bytes: 480000,
        loadMs: 240,
        loadedAt: '2026-09-10T08:00:01.800Z',
      );
      final map = chunk.toMap();
      expect(map['chunkSeq'], equals(0));
      expect(map['level'], equals(1));
      expect(map['startS'], equals(0.0));
      expect(map['endS'], equals(6.0));
      expect(map['bytes'], equals(480000));
      expect(map['loadMs'], equals(240));
      expect(map['loadedAt'], equals('2026-09-10T08:00:01.800Z'));
    });

    test('BetterPlayerTelemetryBatch serializes to map correctly', () {
      final batch = BetterPlayerTelemetryBatch(
        sessionId: 'session-1',
        batchId: 'batch-1',
        sentAt: '2026-09-10T08:00:00.000Z',
        isFinal: false,
        chunkLoads: const [
          BetterPlayerChunkLoadMetric(
            chunkSeq: 0,
            level: 0,
            startS: 0.0,
            endS: 5.0,
            bytes: 100000,
            loadMs: 150,
            loadedAt: '2026-09-10T08:00:01.000Z',
          )
        ],
        bufferSamples: const [
          BetterPlayerBufferSampleMetric(
            ts: '2026-09-10T08:00:02.000Z',
            positionS: 1.0,
            bufferedAheadS: 10.0,
          )
        ],
        watchedRanges: const [
          BetterPlayerWatchedRangeMetric(
            rangeId: 'range-1',
            fromS: 0.0,
            toS: 5.0,
            level: 0,
          )
        ],
        playbackEvents: const [
          BetterPlayerPlaybackEventMetric(
            ts: '2026-09-10T08:00:00.500Z',
            type: 'PLAYBACK_STARTED',
            positionS: 0.0,
          )
        ],
      );

      final map = batch.toMap();
      expect(map['sessionId'], equals('session-1'));
      expect(map['batchId'], equals('batch-1'));
      expect(map['isFinal'], isFalse);
      expect((map['chunkLoads'] as List).length, equals(1));
      expect((map['bufferSamples'] as List).length, equals(1));
      expect((map['watchedRanges'] as List).length, equals(1));
      expect((map['playbackEvents'] as List).length, equals(1));
    });
  });

  group('BetterPlayerController Telemetry Dynamic Switching Tests', () {
    test('sessionId generates a valid UUID v4 and updates on each new viewing session', () async {
      final mockVideoController =
          BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideoController,
      );

      final initialSessionId = controller.sessionId;
      expect(initialSessionId.isNotEmpty, isTrue);

      final uuidRegex = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(uuidRegex.hasMatch(initialSessionId), isTrue);

      // Starting a fresh session updates sessionId
      controller.telemetryManager.startSession(
        configuration: const BetterPlayerTelemetryConfiguration(
          baseUrl: 'https://telemetry.example.com',
        ),
      );
      final newSessionId = controller.sessionId;
      expect(uuidRegex.hasMatch(newSessionId), isTrue);
      expect(newSessionId, isNot(equals(initialSessionId)));

      controller.dispose(forceDispose: true);
    });

    test('BetterPlayerDataSource has null telemetry by default', () {
      final ds = BetterPlayerDataSource.network('https://example.com/video.mp4');
      expect(ds.telemetryConfiguration, isNull);
    });
  });

  group('BetterPlayerTelemetryManager Live Mock HTTP Server Tests', () {
    late HttpServer server;
    final List<Map<String, dynamic>> receivedStartRequests = [];
    final List<Map<String, dynamic>> receivedBatchRequests = [];
    final List<HttpHeaders> receivedStartHeaders = [];
    final List<HttpHeaders> receivedBatchHeaders = [];

    setUp(() async {
      receivedStartRequests.clear();
      receivedBatchRequests.clear();
      receivedStartHeaders.clear();
      receivedBatchHeaders.clear();

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final body = await utf8.decodeStream(request);
        final json = jsonDecode(body) as Map<String, dynamic>;

        if (request.uri.path == '/api/v1/client/statistics/sessions/start') {
          receivedStartRequests.add(json);
          receivedStartHeaders.add(request.headers);
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'success': true, 'alreadyExists': false}))
            ..close();
        } else if (request.uri.path == '/api/v1/client/statistics/events/batch') {
          receivedBatchRequests.add(json);
          receivedBatchHeaders.add(request.headers);
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'success': true, 'duplicate': false}))
            ..close();
        } else {
          request.response
            ..statusCode = HttpStatus.notFound
            ..close();
        }
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('Dispatches session start and batch events with correct Content-Type and Accept headers', () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        bufferSampleInterval: const Duration(milliseconds: 50),
        batchSendInterval: const Duration(milliseconds: 100),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(
          episodeId: 999,
          platform: 'WEB',
          deviceType: 'DESKTOP',
          os: 'Linux',
        ),
      );

      // Allow async session start request to complete
      await Future.delayed(const Duration(milliseconds: 150));

      expect(receivedStartRequests.length, equals(1));
      final startReq = receivedStartRequests.first;
      expect(startReq['sessionId'], equals(controller.sessionId));
      expect(startReq['episodeId'], equals(999));
      expect(startReq['platform'], equals('WEB'));
      expect(startReq['deviceType'], equals('DESKTOP'));
      expect(startReq['os'], equals('Linux'));
      expect(startReq['startedAt'], isNotNull);

      // Verify headers on start request
      final startHeader = receivedStartHeaders.first;
      expect(startHeader.value('accept'), equals('application/json'));
      expect(startHeader.contentType?.mimeType, equals('application/json'));

      // Record playback events
      controller.telemetryManager.recordPlaybackEvent(
        type: 'PLAYBACK_STARTED',
        positionS: 0.0,
      );
      controller.telemetryManager.recordPlaybackEvent(
        type: 'PAUSE',
        positionS: 12.5,
      );

      // Ingest chunk load
      controller.telemetryManager.handleNetworkLog(
        BetterPlayerNetworkLog(
          id: 'chunk-1',
          url: 'https://cdn.example.com/media_1.ts',
          phase: BetterPlayerNetworkLogPhase.completed,
          dataType: BetterPlayerNetworkDataType.mediaSegment,
          bytesLoaded: 500000,
          durationMs: 300,
          timestamp: DateTime.now(),
          mediaStartTimeMs: 0,
          mediaEndTimeMs: 6000,
          bitrate: 2500000,
        ),
      );

      // Wait for periodic batch dispatch
      await Future.delayed(const Duration(milliseconds: 250));

      expect(receivedBatchRequests.isNotEmpty, isTrue);
      final batchReq = receivedBatchRequests.first;
      expect(batchReq['sessionId'], equals(controller.sessionId));
      expect(batchReq['batchId'], isNotNull);
      expect(batchReq['batchId'], isNot(equals(controller.sessionId)));
      expect(batchReq['isFinal'], isFalse);

      // Verify headers on batch request
      final batchHeader = receivedBatchHeaders.first;
      expect(batchHeader.value('accept'), equals('application/json'));
      expect(batchHeader.contentType?.mimeType, equals('application/json'));

      final playbackEvents = batchReq['playbackEvents'] as List;
      expect(playbackEvents.length, greaterThanOrEqualTo(2));

      final chunkLoads = batchReq['chunkLoads'] as List;
      expect(chunkLoads.length, equals(1));
      expect(chunkLoads.first['chunkSeq'], equals(0));
      expect(chunkLoads.first['level'], isA<int>());
      expect(chunkLoads.first['startS'], equals(0.0));
      expect(chunkLoads.first['endS'], equals(6.0));
      expect(chunkLoads.first['bytes'], equals(500000));

      await controller.telemetryManager.dispose(isFinal: true);
      controller.dispose(forceDispose: true);
    });

    test('Dynamic setupDataSource state transitions: Null -> Valid -> Null -> Valid', () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );
      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        bufferSampleInterval: const Duration(milliseconds: 50),
        batchSendInterval: const Duration(milliseconds: 100),
        httpClient: client,
      );

      // 1. FIRST SETUP: Telemetry is null -> No requests sent
      final ds1 = BetterPlayerDataSource.network('https://example.com/video1.mp4');
      await controller.setupDataSource(ds1);

      controller.telemetryManager.recordPlaybackEvent(
        type: 'PLAYBACK_STARTED',
        positionS: 0.0,
      );

      await Future.delayed(const Duration(milliseconds: 150));
      expect(receivedStartRequests.length, equals(0));
      expect(receivedBatchRequests.length, equals(0));

      // 2. SECOND SETUP: Telemetry is valid -> Session starts, fresh UUID
      final ds2 = BetterPlayerDataSource.network(
        'https://example.com/video2.mp4',
        episodeId: 201,
        telemetryConfiguration: config,
      );
      await controller.setupDataSource(ds2);
      final session2Id = controller.sessionId;

      await Future.delayed(const Duration(milliseconds: 150));
      expect(receivedStartRequests.length, equals(1));
      expect(receivedStartRequests.first['sessionId'], equals(session2Id));
      expect(receivedStartRequests.first['episodeId'], equals(201));

      // 3. THIRD SETUP: Telemetry is null -> Flushes prior session, stops telemetry
      final ds3 = BetterPlayerDataSource.network('https://example.com/video3.mp4');
      await controller.setupDataSource(ds3);

      await Future.delayed(const Duration(milliseconds: 150));
      // Prior session had an isFinal batch sent
      expect(receivedBatchRequests.any((b) => b['sessionId'] == session2Id && b['isFinal'] == true), isTrue);

      final startRequestsCountBefore = receivedStartRequests.length;
      controller.telemetryManager.recordPlaybackEvent(
        type: 'PAUSE',
        positionS: 5.0,
      );
      await Future.delayed(const Duration(milliseconds: 150));
      expect(receivedStartRequests.length, equals(startRequestsCountBefore));

      // 4. FOURTH SETUP: Telemetry is valid again -> New session with distinct UUID
      final ds4 = BetterPlayerDataSource.network(
        'https://example.com/video4.mp4',
        episodeId: 401,
        telemetryConfiguration: config,
      );
      await controller.setupDataSource(ds4);
      final session4Id = controller.sessionId;

      await Future.delayed(const Duration(milliseconds: 150));
      expect(session4Id, isNot(equals(session2Id)));
      expect(receivedStartRequests.length, equals(startRequestsCountBefore + 1));
      expect(receivedStartRequests.last['sessionId'], equals(session4Id));
      expect(receivedStartRequests.last['episodeId'], equals(401));

      await controller.telemetryManager.dispose(isFinal: true);
      controller.dispose(forceDispose: true);
    });

    test('Watched range retains same rangeId during continuous playback and splits on seek', () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(milliseconds: 100),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      // Simulate first frame progress (0.0s -> 5.0s)
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.progress),
      );

      // Wait for first batch containing active range snapshot
      await Future.delayed(const Duration(milliseconds: 250));

      // Trigger a seek event (discontinuity)
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(
          BetterPlayerEventType.seekTo,
          parameters: {'duration': const Duration(seconds: 50)},
        ),
      );

      await Future.delayed(const Duration(milliseconds: 250));

      expect(receivedBatchRequests.isNotEmpty, isTrue);

      await controller.telemetryManager.dispose(isFinal: true);
      controller.dispose(forceDispose: true);
    });
  });
}
