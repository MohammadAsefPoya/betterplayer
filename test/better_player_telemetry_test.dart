import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:better_player/better_player.dart';
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

    test('getOperatingSystem returns non-empty string and clamps to 100 chars',
        () {
      final os = BetterPlayerTelemetryUtils.getOperatingSystem();
      expect(os.isNotEmpty, isTrue);
      expect(os.length, lessThanOrEqualTo(100));
    });

    test('normalizePlatform validates and normalizes platforms', () {
      expect(BetterPlayerTelemetryUtils.normalizePlatform('android'),
          equals('ANDROID'));
      expect(
          BetterPlayerTelemetryUtils.normalizePlatform('ios'), equals('IOS'));
      expect(
          BetterPlayerTelemetryUtils.normalizePlatform('web'), equals('WEB'));
      expect(BetterPlayerTelemetryUtils.normalizePlatform('android_tv'),
          equals('ANDROID_TV'));
      expect(BetterPlayerTelemetryUtils.normalizePlatform('old_web_tv'),
          equals('OLD_WEB_TV'));

      // Invalid/empty fallback
      final defaultPlatform =
          BetterPlayerTelemetryUtils.resolveDefaultPlatform();
      expect(BetterPlayerTelemetryUtils.normalizePlatform(null),
          equals(defaultPlatform));
      expect(BetterPlayerTelemetryUtils.normalizePlatform(''),
          equals(defaultPlatform));
      expect(BetterPlayerTelemetryUtils.normalizePlatform('invalid_platform'),
          equals(defaultPlatform));
    });

    test('normalizeDeviceType validates and normalizes device types', () {
      expect(BetterPlayerTelemetryUtils.normalizeDeviceType('mobile'),
          equals('MOBILE'));
      expect(BetterPlayerTelemetryUtils.normalizeDeviceType('tablet'),
          equals('TABLET'));
      expect(BetterPlayerTelemetryUtils.normalizeDeviceType('desktop'),
          equals('DESKTOP'));
      expect(
          BetterPlayerTelemetryUtils.normalizeDeviceType('tv'), equals('TV'));
      expect(BetterPlayerTelemetryUtils.normalizeDeviceType('unknown'),
          equals('UNKNOWN'));

      // Invalid/empty fallback
      final defaultDeviceType =
          BetterPlayerTelemetryUtils.resolveDefaultDeviceType();
      expect(BetterPlayerTelemetryUtils.normalizeDeviceType(null),
          equals(defaultDeviceType));
      expect(BetterPlayerTelemetryUtils.normalizeDeviceType(''),
          equals(defaultDeviceType));
      expect(BetterPlayerTelemetryUtils.normalizeDeviceType('watch'),
          equals(defaultDeviceType));
    });

    test('normalizeEpisodeId parses valid positive integers', () {
      expect(BetterPlayerTelemetryUtils.normalizeEpisodeId(123), equals(123));
      expect(BetterPlayerTelemetryUtils.normalizeEpisodeId('456'), equals(456));
      expect(BetterPlayerTelemetryUtils.normalizeEpisodeId(789.0), equals(789));
      expect(BetterPlayerTelemetryUtils.normalizeEpisodeId(-5),
          equals(1)); // at least 1
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
        'mediaUrl':
            'https://cdn.example.com/segment.ts?token=xyz&signature=123',
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
      expect(
          sanitized['mediaUrl'], equals('https://cdn.example.com/segment.ts'));
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
        equals(
            'https://telemetry.example.com/api/v1/statistics/sessions/start'),
      );
      expect(
        config.batchEventsUri.toString(),
        equals('https://telemetry.example.com/api/v1/statistics/events/batch'),
      );
    });

    test(
        'BetterPlayerTelemetryConfiguration defaults batch send interval to 15 seconds',
        () {
      const config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'https://telemetry.example.com',
      );
      expect(config.batchSendInterval, equals(const Duration(seconds: 15)));
    });

    test(
        'BetterPlayerTelemetryConfiguration with null or empty baseUrl has hasValue = false and null URIs',
        () {
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

    test(
        'BetterPlayerTelemetryData serializes to map correctly with normalized fields',
        () {
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

    test('BetterPlayerTelemetryData strips userId and profileId from JSON body',
        () {
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

    test(
        'BetterPlayerTelemetryData omits episodeId if null, and auto-defaults required platform/deviceType and os',
        () {
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
      expect(map.containsKey('os'), isTrue);
      expect(
          map['os'], equals(BetterPlayerTelemetryUtils.getOperatingSystem()));
      expect(map['platform'], isNotNull);
      expect(
          BetterPlayerTelemetryUtils.allowedPlatforms.contains(map['platform']),
          isTrue);
      expect(map['deviceType'], isNotNull);
      expect(
          BetterPlayerTelemetryUtils.allowedDeviceTypes
              .contains(map['deviceType']),
          isTrue);
      expect(map['sessionId'], equals('test-session-id'));
      expect(map['startedAt'], equals('2026-09-10T08:00:00.000Z'));
    });

    test('BetterPlayerTelemetryData preserves custom os when provided', () {
      const data = BetterPlayerTelemetryData(
        os: 'Android 14',
      );
      final map = data.toMap(
        sessionId: 'test-session-id',
        startedAt: '2026-09-10T08:00:00.000Z',
      );
      expect(map['os'], equals('Android 14'));
    });

    test(
        'BetterPlayerChunkLoadMetric serializes with required non-null integer level',
        () {
      const chunk = BetterPlayerChunkLoadMetric(
        chunkSeq: 0,
        level: 1,
        startS: 0.0,
        endS: 6.0,
        bytes: 480000,
        loadMs: 240,
        source: 'segment-001.ts',
        loadedAt: '2026-09-10T08:00:01.800Z',
      );
      final map = chunk.toMap();
      expect(map['chunkSeq'], equals(0));
      expect(map['level'], equals(1));
      expect(map['startS'], equals(0.0));
      expect(map['endS'], equals(6.0));
      expect(map['bytes'], equals(480000));
      expect(map['loadMs'], equals(240));
      expect(map['source'], equals('segment-001.ts'));
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
            source: 'segment-001.ts',
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
    test(
        'sessionId generates a valid UUID v4 and updates on each new viewing session',
        () async {
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
      final ds =
          BetterPlayerDataSource.network('https://example.com/video.mp4');
      expect(ds.telemetryConfiguration, isNull);
    });
  });

  group('BetterPlayerTelemetryManager Live Mock HTTP Server Tests', () {
    late HttpServer server;
    final List<Map<String, dynamic>> receivedStartRequests = [];
    final List<Map<String, dynamic>> receivedBatchRequests = [];
    final List<HttpHeaders> receivedStartHeaders = [];
    final List<HttpHeaders> receivedBatchHeaders = [];
    final List<int> batchResponseStatusCodes = [];

    setUp(() async {
      receivedStartRequests.clear();
      receivedBatchRequests.clear();
      receivedStartHeaders.clear();
      receivedBatchHeaders.clear();
      batchResponseStatusCodes.clear();

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final body = await utf8.decodeStream(request);
        final json = jsonDecode(body) as Map<String, dynamic>;

        if (request.uri.path == '/api/v1/statistics/sessions/start') {
          receivedStartRequests.add(json);
          receivedStartHeaders.add(request.headers);
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'success': true, 'alreadyExists': false}))
            ..close();
        } else if (request.uri.path == '/api/v1/statistics/events/batch') {
          receivedBatchRequests.add(json);
          receivedBatchHeaders.add(request.headers);
          final statusCode = batchResponseStatusCodes.isEmpty
              ? HttpStatus.ok
              : batchResponseStatusCodes.removeAt(0);
          request.response
            ..statusCode = statusCode
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

    List<Map<String, dynamic>> allPlaybackEvents() {
      return receivedBatchRequests
          .expand((batch) => batch['playbackEvents'] as List)
          .cast<Map<String, dynamic>>()
          .toList();
    }

    List<Map<String, dynamic>> allWatchedRanges() {
      return receivedBatchRequests
          .expand((batch) => batch['watchedRanges'] as List)
          .cast<Map<String, dynamic>>()
          .toList();
    }

    List<Map<String, dynamic>> allChunkLoads() {
      return receivedBatchRequests
          .expand((batch) => batch['chunkLoads'] as List)
          .cast<Map<String, dynamic>>()
          .toList();
    }

    BetterPlayerNetworkLog completedMediaChunkLog({
      required String id,
      required int bitrate,
      required int width,
      required int height,
      required int mediaStartTimeMs,
      required int mediaEndTimeMs,
    }) {
      return BetterPlayerNetworkLog(
        id: id,
        url: 'https://cdn.example.com/$id.ts',
        phase: BetterPlayerNetworkLogPhase.completed,
        dataType: BetterPlayerNetworkDataType.mediaSegment,
        bytesLoaded: 500000,
        durationMs: 300,
        timestamp: DateTime.now(),
        bitrate: bitrate,
        width: width,
        height: height,
        mediaStartTimeMs: mediaStartTimeMs,
        mediaEndTimeMs: mediaEndTimeMs,
      );
    }

    Future<void> progressAtDuration(
      BetterPlayerMockController controller,
      MockVideoPlayerController mockVideo,
      Duration position,
    ) async {
      await mockVideo.seekTo(position);
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.progress),
      );
    }

    Future<void> progressAt(
      BetterPlayerMockController controller,
      MockVideoPlayerController mockVideo,
      int seconds,
    ) async {
      await progressAtDuration(
        controller,
        mockVideo,
        Duration(seconds: seconds),
      );
    }

    test(
        'Dispatches session start and batch events with correct Content-Type and Accept headers',
        () async {
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
      expect(chunkLoads.first['source'], equals('media_1.ts'));

      await controller.telemetryManager.dispose(isFinal: true);
      controller.dispose(forceDispose: true);
    });

    test('Periodic telemetry sends at most one batch per timer tick', () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(milliseconds: 200),
        maxPlaybackEventsPerBatch: 1,
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      controller.telemetryManager.recordPlaybackEvent(
        type: 'PLAYBACK_STARTED',
        positionS: 0.0,
      );
      controller.telemetryManager.recordPlaybackEvent(
        type: 'PAUSE',
        positionS: 1.0,
      );
      controller.telemetryManager.recordPlaybackEvent(
        type: 'RESUME',
        positionS: 2.0,
      );

      await Future.delayed(const Duration(milliseconds: 150));

      expect(receivedBatchRequests.length, equals(1));
      expect(
        receivedBatchRequests.first['playbackEvents'],
        hasLength(1),
      );

      await Future.delayed(const Duration(milliseconds: 220));

      expect(receivedBatchRequests.length, equals(2));
      expect(
        receivedBatchRequests.last['playbackEvents'],
        hasLength(1),
      );

      await controller.telemetryManager.dispose(isFinal: false);
      controller.dispose(forceDispose: true);
    });

    test('Successful retry does not send another new batch in the same tick',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      batchResponseStatusCodes.add(HttpStatus.internalServerError);

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(milliseconds: 200),
        maxPlaybackEventsPerBatch: 1,
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      controller.telemetryManager.recordPlaybackEvent(
        type: 'PLAYBACK_STARTED',
        positionS: 0.0,
      );
      controller.telemetryManager.recordPlaybackEvent(
        type: 'PAUSE',
        positionS: 1.0,
      );

      await Future.delayed(const Duration(milliseconds: 150));

      expect(receivedBatchRequests.length, equals(1));
      final failedBatchId = receivedBatchRequests.single['batchId'];

      await Future.delayed(const Duration(milliseconds: 220));

      expect(receivedBatchRequests.length, equals(2));
      expect(receivedBatchRequests.last['batchId'], equals(failedBatchId));

      await Future.delayed(const Duration(milliseconds: 180));

      expect(receivedBatchRequests.length, equals(3));
      expect(
          receivedBatchRequests.last['batchId'], isNot(equals(failedBatchId)));

      await controller.telemetryManager.dispose(isFinal: false);
      controller.dispose(forceDispose: true);
    });

    test('Final telemetry sends a single final batch containing queued events',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        maxPlaybackEventsPerBatch: 1,
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      controller.telemetryManager.recordPlaybackEvent(
        type: 'PLAYBACK_STARTED',
        positionS: 0.0,
      );
      controller.telemetryManager.recordPlaybackEvent(
        type: 'PAUSE',
        positionS: 1.0,
      );
      controller.telemetryManager.recordPlaybackEvent(
        type: 'RESUME',
        positionS: 2.0,
      );

      await controller.telemetryManager.dispose(isFinal: true);

      expect(receivedBatchRequests.length, equals(1));
      expect(receivedBatchRequests.first['isFinal'], isTrue);
      expect(
        receivedBatchRequests.first['playbackEvents'],
        hasLength(3),
      );

      controller.dispose(forceDispose: true);
    });

    test(
        'Dynamic setupDataSource state transitions: Null -> Valid -> Null -> Valid',
        () async {
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
      final ds1 =
          BetterPlayerDataSource.network('https://example.com/video1.mp4');
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
      expect(receivedStartRequests.first['os'],
          equals(BetterPlayerTelemetryUtils.getOperatingSystem()));

      // 3. THIRD SETUP: Telemetry is null -> Flushes prior session, stops telemetry
      final ds3 =
          BetterPlayerDataSource.network('https://example.com/video3.mp4');
      await controller.setupDataSource(ds3);

      await Future.delayed(const Duration(milliseconds: 150));
      // Prior session had an isFinal batch sent
      expect(
          receivedBatchRequests
              .any((b) => b['sessionId'] == session2Id && b['isFinal'] == true),
          isTrue);

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
      expect(
          receivedStartRequests.length, equals(startRequestsCountBefore + 1));
      expect(receivedStartRequests.last['sessionId'], equals(session4Id));
      expect(receivedStartRequests.last['episodeId'], equals(401));

      await controller.telemetryManager.dispose(isFinal: true);
      controller.dispose(forceDispose: true);
    });

    test(
        'Chunk telemetry sends segment filename source and excludes non completed media segments',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      controller.telemetryManager.handleNetworkLog(
        BetterPlayerNetworkLog(
          id: 'valid-segment',
          url:
              'https://cdn.example.com/video/quality/segment-001.m4s?token=abc',
          phase: BetterPlayerNetworkLogPhase.completed,
          dataType: BetterPlayerNetworkDataType.mediaSegment,
          bytesLoaded: 250000,
          durationMs: 120,
          timestamp: DateTime.now(),
          mediaStartTimeMs: 0,
          mediaEndTimeMs: 4000,
        ),
      );
      controller.telemetryManager.handleNetworkLog(
        BetterPlayerNetworkLog(
          id: 'valid-client-segment',
          url:
              'https://cdn.example.com/client?segment=https://media.example.com/video/segment-002.ts&token=abc',
          phase: BetterPlayerNetworkLogPhase.completed,
          dataType: BetterPlayerNetworkDataType.mediaSegment,
          bytesLoaded: 260000,
          durationMs: 130,
          timestamp: DateTime.now(),
          mediaStartTimeMs: 4000,
          mediaEndTimeMs: 8000,
        ),
      );
      controller.telemetryManager.handleNetworkLog(
        BetterPlayerNetworkLog(
          id: 'generic-client',
          url: 'https://cdn.example.com/CLIENT',
          phase: BetterPlayerNetworkLogPhase.completed,
          dataType: BetterPlayerNetworkDataType.mediaSegment,
          bytesLoaded: 270000,
          durationMs: 140,
          timestamp: DateTime.now(),
          mediaStartTimeMs: 8000,
          mediaEndTimeMs: 12000,
        ),
      );
      controller.telemetryManager.handleNetworkLog(
        BetterPlayerNetworkLog(
          id: 'manifest',
          url: 'https://cdn.example.com/video/master.m3u8',
          phase: BetterPlayerNetworkLogPhase.completed,
          dataType: BetterPlayerNetworkDataType.manifest,
          bytesLoaded: 1000,
          durationMs: 40,
          timestamp: DateTime.now(),
          mediaStartTimeMs: 0,
          mediaEndTimeMs: 4000,
        ),
      );
      controller.telemetryManager.handleNetworkLog(
        BetterPlayerNetworkLog(
          id: 'init',
          url: 'https://cdn.example.com/video/init.m4s',
          phase: BetterPlayerNetworkLogPhase.completed,
          dataType: BetterPlayerNetworkDataType.initialization,
          bytesLoaded: 5000,
          durationMs: 30,
          timestamp: DateTime.now(),
          mediaStartTimeMs: 0,
          mediaEndTimeMs: 4000,
        ),
      );
      controller.telemetryManager.handleNetworkLog(
        BetterPlayerNetworkLog(
          id: 'canceled',
          url: 'https://cdn.example.com/video/segment-002.m4s',
          phase: BetterPlayerNetworkLogPhase.canceled,
          dataType: BetterPlayerNetworkDataType.mediaSegment,
          bytesLoaded: 100000,
          durationMs: 80,
          timestamp: DateTime.now(),
          mediaStartTimeMs: 4000,
          mediaEndTimeMs: 8000,
        ),
      );
      controller.telemetryManager.handleNetworkLog(
        BetterPlayerNetworkLog(
          id: 'error',
          url: 'https://cdn.example.com/video/segment-003.m4s',
          phase: BetterPlayerNetworkLogPhase.error,
          dataType: BetterPlayerNetworkDataType.mediaSegment,
          bytesLoaded: 0,
          durationMs: 70,
          timestamp: DateTime.now(),
          mediaStartTimeMs: 8000,
          mediaEndTimeMs: 12000,
        ),
      );
      controller.telemetryManager.handleNetworkLog(
        BetterPlayerNetworkLog(
          id: 'untimed',
          url: 'https://cdn.example.com/video/segment-004.m4s',
          phase: BetterPlayerNetworkLogPhase.completed,
          dataType: BetterPlayerNetworkDataType.mediaSegment,
          bytesLoaded: 250000,
          durationMs: 100,
          timestamp: DateTime.now(),
        ),
      );

      await controller.telemetryManager.dispose(isFinal: true);

      final chunkLoads = allChunkLoads();
      expect(chunkLoads.length, equals(2));
      expect(chunkLoads.first['source'], equals('segment-001.m4s'));
      expect(chunkLoads.first['bytes'], equals(250000));
      expect(chunkLoads.first['startS'], equals(0.0));
      expect(chunkLoads.first['endS'], equals(4.0));
      expect(chunkLoads.last['source'], equals('segment-002.ts'));
      expect(chunkLoads.last['bytes'], equals(260000));
      expect(chunkLoads.last['startS'], equals(4.0));
      expect(chunkLoads.last['endS'], equals(8.0));

      controller.dispose(forceDispose: true);
    });

    test('Chunk telemetry deduplicates near-identical segment intervals',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      controller.telemetryManager.handleNetworkLog(
        BetterPlayerNetworkLog(
          id: 'segment-audio',
          url: 'https://cdn.example.com/video/segment-001-audio.ts',
          phase: BetterPlayerNetworkLogPhase.completed,
          dataType: BetterPlayerNetworkDataType.mediaSegment,
          trackType: 'audio',
          bytesLoaded: 135172,
          durationMs: 136,
          timestamp: DateTime.now(),
          mediaStartTimeMs: 6016,
          mediaEndTimeMs: 12010,
        ),
      );
      controller.telemetryManager.handleNetworkLog(
        BetterPlayerNetworkLog(
          id: 'segment-video-small',
          url: 'https://cdn.example.com/video/segment-001-small.ts',
          phase: BetterPlayerNetworkLogPhase.completed,
          dataType: BetterPlayerNetworkDataType.mediaSegment,
          bytesLoaded: 879652,
          durationMs: 385,
          timestamp: DateTime.now(),
          mediaStartTimeMs: 6006,
          mediaEndTimeMs: 12012,
        ),
      );
      controller.telemetryManager.handleNetworkLog(
        BetterPlayerNetworkLog(
          id: 'segment-video-large',
          url: 'https://cdn.example.com/video/segment-001.ts',
          phase: BetterPlayerNetworkLogPhase.completed,
          dataType: BetterPlayerNetworkDataType.mediaSegment,
          bytesLoaded: 1754980,
          durationMs: 360,
          timestamp: DateTime.now(),
          mediaStartTimeMs: 6018,
          mediaEndTimeMs: 12018,
        ),
      );

      await controller.telemetryManager.dispose(isFinal: true);

      final chunkLoads = allChunkLoads();
      expect(chunkLoads.length, equals(1));
      expect(chunkLoads.first['source'], equals('segment-001.ts'));
      expect(chunkLoads.first['bytes'], equals(1754980));
      expect(chunkLoads.first['chunkSeq'], equals(0));

      controller.dispose(forceDispose: true);
    });

    test(
        'Watched range retains same rangeId during continuous playback and splits on seek',
        () async {
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

    test('Progress jumps up to 15 seconds keep one watched range', () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      mockVideo.setDuration(const Duration(minutes: 5));
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      await mockVideo.play();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );

      for (final position in <Duration>[
        Duration.zero,
        const Duration(milliseconds: 10714),
        const Duration(milliseconds: 20387),
        const Duration(milliseconds: 26508),
        const Duration(milliseconds: 36508),
        const Duration(milliseconds: 40312),
      ]) {
        await progressAtDuration(controller, mockVideo, position);
      }

      await controller.telemetryManager.dispose(isFinal: true);

      final seekEvents = allPlaybackEvents()
          .where((event) => event['type'] == 'SEEK')
          .toList();
      expect(seekEvents, isEmpty);

      final watchedRanges = allWatchedRanges();
      expect(watchedRanges.length, equals(1));
      expect(watchedRanges.single['fromS'], equals(0.0));
      expect(watchedRanges.single['toS'], equals(40.312));

      controller.dispose(forceDispose: true);
    });

    test('Progress jump exactly 15 seconds keeps one watched range', () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      mockVideo.setDuration(const Duration(minutes: 5));
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      await mockVideo.play();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );

      for (final seconds in <int>[0, 1, 16, 20]) {
        await progressAt(controller, mockVideo, seconds);
      }

      await controller.telemetryManager.dispose(isFinal: true);

      final watchedRanges = allWatchedRanges();
      expect(watchedRanges.length, equals(1));
      expect(watchedRanges.single['fromS'], equals(0.0));
      expect(watchedRanges.single['toS'], equals(20.0));

      controller.dispose(forceDispose: true);
    });

    test('Progress jump greater than 15 seconds splits watched ranges',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      mockVideo.setDuration(const Duration(minutes: 5));
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      await mockVideo.play();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );

      for (final position in <Duration>[
        Duration.zero,
        const Duration(seconds: 1),
        const Duration(milliseconds: 16001),
        const Duration(seconds: 20),
      ]) {
        await progressAtDuration(controller, mockVideo, position);
      }

      await controller.telemetryManager.dispose(isFinal: true);

      final watchedRanges = allWatchedRanges();
      expect(watchedRanges.length, equals(2));
      expect(watchedRanges.first['fromS'], equals(0.0));
      expect(watchedRanges.first['toS'], equals(1.0));
      expect(watchedRanges.last['fromS'], equals(16.001));
      expect(watchedRanges.last['toS'], equals(20.0));

      controller.dispose(forceDispose: true);
    });

    test('Buffering side effect pause and play events are not user events',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      mockVideo.setDuration(const Duration(minutes: 5));
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      await mockVideo.play();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );

      for (final position in <Duration>[
        Duration.zero,
        const Duration(milliseconds: 10714),
      ]) {
        await progressAtDuration(controller, mockVideo, position);
      }

      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.bufferingStart),
      );
      await mockVideo.pause();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.pause),
      );

      await mockVideo.seekTo(const Duration(milliseconds: 20387));
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.bufferingEnd),
      );
      await mockVideo.play();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );

      await progressAtDuration(
        controller,
        mockVideo,
        const Duration(milliseconds: 26508),
      );

      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.bufferingStart),
      );
      await mockVideo.pause();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.pause),
      );

      await mockVideo.seekTo(const Duration(milliseconds: 36508));
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.bufferingEnd),
      );
      await mockVideo.play();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );

      await progressAtDuration(
        controller,
        mockVideo,
        const Duration(milliseconds: 40312),
      );

      await controller.telemetryManager.dispose(isFinal: true);

      final playbackEvents = allPlaybackEvents();
      expect(
        playbackEvents.where((event) => event['type'] == 'STALL_START').length,
        equals(2),
      );
      expect(
        playbackEvents.where((event) => event['type'] == 'STALL_END').length,
        equals(2),
      );
      expect(
          playbackEvents.where((event) => event['type'] == 'PAUSE'), isEmpty);
      expect(
        playbackEvents.where((event) => event['type'] == 'RESUME'),
        isEmpty,
      );
      expect(playbackEvents.where((event) => event['type'] == 'SEEK'), isEmpty);

      final watchedRanges = allWatchedRanges();
      expect(watchedRanges.length, equals(1));
      expect(watchedRanges.single['fromS'], equals(0.0));
      expect(watchedRanges.single['toS'], equals(40.312));

      controller.dispose(forceDispose: true);
    });

    test('Pause and resume within 15 seconds keep one watched range', () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      mockVideo.setDuration(const Duration(minutes: 5));
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      await mockVideo.play();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.progress),
      );

      for (final seconds in <int>[2, 4, 6, 8, 10]) {
        await progressAt(controller, mockVideo, seconds);
      }

      await mockVideo.pause();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.pause),
      );

      await mockVideo.seekTo(const Duration(seconds: 20));
      await mockVideo.play();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );
      await progressAt(controller, mockVideo, 20);

      await controller.telemetryManager.dispose(isFinal: true);

      final seekEvents = allPlaybackEvents()
          .where((event) => event['type'] == 'SEEK')
          .toList();
      expect(seekEvents, isEmpty);

      final watchedRanges = allWatchedRanges();
      expect(watchedRanges.length, equals(1));
      expect(watchedRanges.single['fromS'], equals(0.0));
      expect(watchedRanges.single['toS'], equals(20.0));

      controller.dispose(forceDispose: true);
    });

    test('Duplicate playback action events are only sent once per batch',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      controller.telemetryManager.recordPlaybackEvent(
        type: 'PAUSE',
        positionS: 12.0,
      );
      controller.telemetryManager.recordPlaybackEvent(
        type: 'PAUSE',
        positionS: 12.0,
      );

      await controller.telemetryManager.dispose(isFinal: true);

      final pauseEvents = allPlaybackEvents()
          .where((event) => event['type'] == 'PAUSE')
          .toList();
      expect(pauseEvents.length, equals(1));

      controller.dispose(forceDispose: true);
    });

    test('Duplicate pause and resume events are suppressed across other events',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      mockVideo.setDuration(const Duration(minutes: 5));
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      await mockVideo.play();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.progress),
      );

      await mockVideo.pause();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.pause),
      );
      controller.telemetryManager.recordPlaybackEvent(
        type: 'ERROR',
        positionS: 0.0,
      );
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.pause),
      );

      await mockVideo.play();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );
      controller.telemetryManager.recordPlaybackEvent(
        type: 'ERROR',
        positionS: 0.0,
      );
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );

      await controller.telemetryManager.dispose(isFinal: true);

      final playbackEvents = allPlaybackEvents();
      expect(
        playbackEvents.where((event) => event['type'] == 'PAUSE').length,
        equals(1),
      );
      expect(
        playbackEvents.where((event) => event['type'] == 'RESUME').length,
        equals(1),
      );

      controller.dispose(forceDispose: true);
    });

    test('Pause and resume are sent once for each real transition', () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      mockVideo.setDuration(const Duration(minutes: 5));
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      await mockVideo.play();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.progress),
      );

      for (int i = 0; i < 2; i++) {
        await mockVideo.pause();
        controller.telemetryManager.handlePlayerEvent(
          BetterPlayerEvent(BetterPlayerEventType.pause),
        );
        await mockVideo.play();
        controller.telemetryManager.handlePlayerEvent(
          BetterPlayerEvent(BetterPlayerEventType.play),
        );
      }

      await controller.telemetryManager.dispose(isFinal: true);

      final playbackEvents = allPlaybackEvents();
      expect(
        playbackEvents.where((event) => event['type'] == 'PAUSE').length,
        equals(2),
      );
      expect(
        playbackEvents.where((event) => event['type'] == 'RESUME').length,
        equals(2),
      );

      controller.dispose(forceDispose: true);
    });

    test('Auto quality reports actual loaded level and skips duplicates',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      mockVideo.setDuration(const Duration(minutes: 5));
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );
      controller.betterPlayerAsmsTracks.addAll(<BetterPlayerAsmsTrack>[
        BetterPlayerAsmsTrack.defaultTrack(),
        BetterPlayerAsmsTrack('240p', 426, 240, 400000, 0, '', 'video/mp4'),
        BetterPlayerAsmsTrack('720p', 1280, 720, 2500000, 0, '', 'video/mp4'),
      ]);

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      controller.telemetryManager.handleNetworkLog(
        completedMediaChunkLog(
          id: 'chunk-720-a',
          bitrate: 2500000,
          width: 1280,
          height: 720,
          mediaStartTimeMs: 0,
          mediaEndTimeMs: 6000,
        ),
      );
      controller.telemetryManager.handleNetworkLog(
        completedMediaChunkLog(
          id: 'chunk-720-b',
          bitrate: 2500000,
          width: 1280,
          height: 720,
          mediaStartTimeMs: 6000,
          mediaEndTimeMs: 12000,
        ),
      );

      await controller.telemetryManager.dispose(isFinal: true);

      final qualityEvents = allPlaybackEvents()
          .where((event) => event['type'] == 'QUALITY_SWITCH')
          .toList();
      expect(qualityEvents.length, equals(1));
      expect(qualityEvents.single['details']['fromLevel'], equals(0));
      expect(qualityEvents.single['details']['toLevel'], equals(2));
      expect(qualityEvents.single['details']['bitrate'], equals(2500000));
      expect(qualityEvents.single['details']['width'], equals(1280));
      expect(qualityEvents.single['details']['height'], equals(720));

      final chunkLoads = allChunkLoads();
      expect(chunkLoads.map((chunk) => chunk['level']).toList(),
          equals(<int>[2, 2]));

      controller.dispose(forceDispose: true);
    });

    test('Auto quality sends a switch only when actual loaded level changes',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      mockVideo.setDuration(const Duration(minutes: 5));
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );
      controller.betterPlayerAsmsTracks.addAll(<BetterPlayerAsmsTrack>[
        BetterPlayerAsmsTrack.defaultTrack(),
        BetterPlayerAsmsTrack('240p', 426, 240, 400000, 0, '', 'video/mp4'),
        BetterPlayerAsmsTrack('720p', 1280, 720, 2500000, 0, '', 'video/mp4'),
      ]);

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      controller.telemetryManager.handleNetworkLog(
        completedMediaChunkLog(
          id: 'chunk-240',
          bitrate: 400000,
          width: 426,
          height: 240,
          mediaStartTimeMs: 0,
          mediaEndTimeMs: 6000,
        ),
      );
      controller.telemetryManager.handleNetworkLog(
        completedMediaChunkLog(
          id: 'chunk-720',
          bitrate: 2500000,
          width: 1280,
          height: 720,
          mediaStartTimeMs: 6000,
          mediaEndTimeMs: 12000,
        ),
      );

      await controller.telemetryManager.dispose(isFinal: true);

      final qualityEvents = allPlaybackEvents()
          .where((event) => event['type'] == 'QUALITY_SWITCH')
          .toList();
      expect(qualityEvents.length, equals(2));
      expect(qualityEvents.first['details']['fromLevel'], equals(0));
      expect(qualityEvents.first['details']['toLevel'], equals(1));
      expect(qualityEvents.last['details']['fromLevel'], equals(1));
      expect(qualityEvents.last['details']['toLevel'], equals(2));
      expect(
        qualityEvents.any(
          (event) =>
              event['details']['fromLevel'] == event['details']['toLevel'],
        ),
        isFalse,
      );

      controller.dispose(forceDispose: true);
    });

    test('Manual same-level quality events are ignored', () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      mockVideo.setDuration(const Duration(minutes: 5));
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );
      final track720 =
          BetterPlayerAsmsTrack('720p', 1280, 720, 2500000, 0, '', 'video/mp4');
      controller.betterPlayerAsmsTracks.addAll(<BetterPlayerAsmsTrack>[
        BetterPlayerAsmsTrack.defaultTrack(),
        track720,
      ]);

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      controller.telemetryManager.handleNetworkLog(
        completedMediaChunkLog(
          id: 'chunk-720',
          bitrate: 2500000,
          width: 1280,
          height: 720,
          mediaStartTimeMs: 0,
          mediaEndTimeMs: 6000,
        ),
      );
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(
          BetterPlayerEventType.changedTrack,
          parameters: <String, dynamic>{
            'bitrate': track720.bitrate,
            'width': track720.width,
            'height': track720.height,
          },
        ),
      );
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(
          BetterPlayerEventType.changedResolution,
          parameters: <String, dynamic>{
            'width': track720.width,
            'height': track720.height,
          },
        ),
      );

      await controller.telemetryManager.dispose(isFinal: true);

      final qualityEvents = allPlaybackEvents()
          .where((event) => event['type'] == 'QUALITY_SWITCH')
          .toList();
      expect(qualityEvents.length, equals(1));
      expect(qualityEvents.single['details']['fromLevel'], equals(0));
      expect(qualityEvents.single['details']['toLevel'], equals(1));

      controller.dispose(forceDispose: true);
    });

    test('Resume more than 15 seconds from pause position counts as seek',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      mockVideo.setDuration(const Duration(minutes: 5));
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      await mockVideo.play();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.progress),
      );

      for (final seconds in <int>[2, 4, 6, 8, 10]) {
        await progressAt(controller, mockVideo, seconds);
      }

      await mockVideo.pause();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.pause),
      );

      await mockVideo.seekTo(const Duration(seconds: 30));
      await mockVideo.play();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );

      for (final seconds in <int>[32, 34, 35]) {
        await progressAt(controller, mockVideo, seconds);
      }

      await controller.telemetryManager.dispose(isFinal: true);

      final seekEvents = allPlaybackEvents()
          .where((event) => event['type'] == 'SEEK')
          .toList();
      expect(seekEvents.length, equals(1));
      expect(seekEvents.single['positionS'], equals(10.0));
      expect(seekEvents.single['details']['fromS'], equals(10.0));
      expect(seekEvents.single['details']['toS'], equals(30.0));

      final watchedRanges = allWatchedRanges();
      expect(watchedRanges.length, equals(2));
      expect(watchedRanges.first['fromS'], equals(0.0));
      expect(watchedRanges.first['toS'], equals(10.0));
      expect(watchedRanges.last['fromS'], equals(30.0));
      expect(watchedRanges.last['toS'], equals(35.0));

      controller.dispose(forceDispose: true);
    });

    test(
        'Seek uses real from and to positions and ignores jumps within 15 seconds',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      mockVideo.setDuration(const Duration(minutes: 5));
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      await mockVideo.play();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.progress),
      );

      for (final seconds in <int>[2, 4, 6, 8, 10]) {
        await progressAt(controller, mockVideo, seconds);
      }

      await controller.seekTo(const Duration(seconds: 24));
      await controller.seekTo(const Duration(seconds: 45));

      for (final seconds in <int>[47, 49, 50]) {
        await progressAt(controller, mockVideo, seconds);
      }

      await controller.telemetryManager.dispose(isFinal: true);

      final seekEvents = allPlaybackEvents()
          .where((event) => event['type'] == 'SEEK')
          .toList();
      expect(seekEvents.length, equals(1));
      expect(seekEvents.single['positionS'], equals(24.0));
      expect(seekEvents.single['details']['fromS'], equals(24.0));
      expect(seekEvents.single['details']['toS'], equals(45.0));

      final watchedRanges = allWatchedRanges();
      expect(watchedRanges.length, equals(2));
      expect(watchedRanges.first['fromS'], equals(0.0));
      expect(watchedRanges.first['toS'], equals(24.0));
      expect(watchedRanges.last['fromS'], equals(45.0));
      expect(watchedRanges.last['toS'], equals(50.0));

      controller.dispose(forceDispose: true);
    });

    test(
        'Seek fallback uses last watched position and only records jumps greater than 15 seconds',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      mockVideo.setDuration(const Duration(minutes: 5));
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(hours: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      await mockVideo.play();
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(BetterPlayerEventType.play),
      );
      for (final seconds in <int>[0, 2, 4, 6, 8, 10]) {
        await progressAt(controller, mockVideo, seconds);
      }

      await mockVideo.seekTo(Duration.zero);
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(
          BetterPlayerEventType.seekTo,
          parameters: {'duration': Duration.zero},
        ),
      );

      await mockVideo.seekTo(const Duration(seconds: 10));
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(
          BetterPlayerEventType.seekTo,
          parameters: {'duration': const Duration(seconds: 10)},
        ),
      );

      await mockVideo.seekTo(const Duration(seconds: 20));
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(
          BetterPlayerEventType.seekTo,
          parameters: {'duration': const Duration(seconds: 20)},
        ),
      );

      await mockVideo.seekTo(const Duration(seconds: 35));
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(
          BetterPlayerEventType.seekTo,
          parameters: {'duration': const Duration(seconds: 35)},
        ),
      );

      await mockVideo.seekTo(const Duration(seconds: 51));
      controller.telemetryManager.handlePlayerEvent(
        BetterPlayerEvent(
          BetterPlayerEventType.seekTo,
          parameters: {'duration': const Duration(seconds: 51)},
        ),
      );

      await controller.telemetryManager.dispose(isFinal: true);

      final seekEvents = allPlaybackEvents()
          .where((event) => event['type'] == 'SEEK')
          .toList();
      expect(seekEvents.length, equals(1));
      expect(seekEvents.single['positionS'], equals(35.0));
      expect(seekEvents.single['details']['fromS'], equals(35.0));
      expect(seekEvents.single['details']['toS'], equals(51.0));

      controller.dispose(forceDispose: true);
    });

    test('Does not send queued events immediately after session start succeeds',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        batchSendInterval: const Duration(seconds: 1),
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 101),
      );
      controller.telemetryManager.recordPlaybackEvent(
        type: 'PAUSE',
        positionS: 5.0,
      );

      await Future.delayed(const Duration(milliseconds: 200));

      expect(receivedStartRequests.length, equals(1));
      expect(receivedBatchRequests.length, equals(0));

      await Future.delayed(const Duration(milliseconds: 950));

      expect(receivedBatchRequests.length, equals(1));
      expect(
        (receivedBatchRequests.single['playbackEvents'] as List).single['type'],
        equals('PAUSE'),
      );

      await controller.telemetryManager.dispose(isFinal: true);
      controller.dispose(forceDispose: true);
    });

    test(
        'Logs error response body and cancels retries when server returns HTTP 400 Bad Request',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final errorServer =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      errorServer.listen((HttpRequest request) async {
        await utf8.decodeStream(request);
        request.response
          ..statusCode = HttpStatus.badRequest
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'message': ['episodeId must not be less than 1']
          }))
          ..close();
      });

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${errorServer.address.host}:${errorServer.port}',
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(),
      );

      await Future.delayed(const Duration(milliseconds: 100));

      expect(controller.telemetryManager.isSessionStartCompleted, isFalse);

      await controller.telemetryManager.dispose(isFinal: false);
      controller.dispose(forceDispose: true);
      await errorServer.close(force: true);
    });

    test(
        'Accepts Map<String, dynamic> in BetterPlayerTelemetryConfiguration headers and dispatches them',
        () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final dynamicHeaders = <String, dynamic>{
        'x-is-guest': true,
        'Authorization': 'Bearer test_token',
        'X-Profile-Id': '12345678-1234-4234-8234-123456789abc',
        'X-Numeric-Header': 42,
        'X-Null-Header': null,
      };

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        headers: dynamicHeaders,
        httpClient: client,
      );

      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(episodeId: 1),
      );

      await Future.delayed(const Duration(milliseconds: 150));

      expect(receivedStartRequests.length, equals(1));
      final startHeader = receivedStartHeaders.first;
      expect(startHeader.value('x-is-guest'), equals('true'));
      expect(startHeader.value('authorization'), equals('Bearer test_token'));
      expect(startHeader.value('x-profile-id'),
          equals('12345678-1234-4234-8234-123456789abc'));
      expect(startHeader.value('x-numeric-header'), equals('42'));
      expect(startHeader.value('x-null-header'), isNull);

      await controller.telemetryManager.dispose(isFinal: false);
      controller.dispose(forceDispose: true);
    });
  });
}
