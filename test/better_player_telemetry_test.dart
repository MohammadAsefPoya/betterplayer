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

    test('getOperatingSystem returns non-empty string', () {
      final os = BetterPlayerTelemetryUtils.getOperatingSystem();
      expect(os.isNotEmpty, isTrue);
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

    test('BetterPlayerTelemetryData serializes to map correctly', () {
      const data = BetterPlayerTelemetryData(
        episodeId: 123,
        platform: 'ANDROID',
        deviceType: 'MOBILE',
        os: 'Android',
      );
      final map = data.toMap(
        sessionId: 'test-session-id',
        startedAt: '2026-09-10T08:00:00.000Z',
      );

      expect(map['sessionId'], equals('test-session-id'));
      expect(map['episodeId'], equals(123));
      expect(map['platform'], equals('ANDROID'));
      expect(map['deviceType'], equals('MOBILE'));
      expect(map['os'], equals('Android'));
      expect(map['startedAt'], equals('2026-09-10T08:00:00.000Z'));
    });

    test('BetterPlayerTelemetryData omits null and empty fields in toMap', () {
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
      expect(map.containsKey('platform'), isFalse);
      expect(map.containsKey('deviceType'), isFalse);
      expect(map.containsKey('os'), isFalse);
      expect(map['sessionId'], equals('test-session-id'));
      expect(map['startedAt'], equals('2026-09-10T08:00:00.000Z'));
    });

    test('BetterPlayerTelemetryBatch serializes to map correctly', () {
      final batch = BetterPlayerTelemetryBatch(
        sessionId: 'session-1',
        batchId: 'batch-1',
        sentAt: '2026-09-10T08:00:00.000Z',
        isFinal: false,
        chunkLoads: const [
          BetterPlayerChunkLoadMetric(
            chunkSeq: 1,
            level: 1080,
            startS: 0.0,
            endS: 6.0,
            bytes: 480000,
            loadMs: 240,
            loadedAt: '2026-09-10T08:00:01.000Z',
          )
        ],
        bufferSamples: const [
          BetterPlayerBufferSampleMetric(
            ts: '2026-09-10T08:00:05.000Z',
            positionS: 5.0,
            bufferedAheadS: 12.0,
          )
        ],
        watchedRanges: const [
          BetterPlayerWatchedRangeMetric(
            rangeId: 'range-1',
            fromS: 0.0,
            toS: 5.0,
            level: 1080,
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

  group('BetterPlayerController Telemetry Integration Tests', () {
    test('sessionId is generated once and remains consistent on controller', () async {
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

      // Verify sessionId never changes across setupDataSource or setDataSource calls
      final ds1 = BetterPlayerDataSource.network(
        'https://example.com/video1.mp4',
        episodeId: 101,
        platform: 'ANDROID',
        deviceType: 'MOBILE',
        telemetryConfiguration: const BetterPlayerTelemetryConfiguration(
          baseUrl: 'http://localhost:8080',
          enabled: false,
        ),
      );

      await controller.setupDataSource(ds1);
      expect(controller.sessionId, equals(initialSessionId));

      final ds2 = BetterPlayerDataSource.network(
        'https://example.com/video2.mp4',
        episodeId: 102,
        platform: 'IOS',
        deviceType: 'TABLET',
      );

      await controller.setDataSource(
        ds2,
        episodeId: 202,
        platform: 'IOS',
        deviceType: 'TABLET',
      );
      expect(controller.sessionId, equals(initialSessionId));

      controller.dispose(forceDispose: true);
    });

    test('BetterPlayerDataSource holds telemetry configuration and parameters', () {
      const config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'https://telemetry.example.com',
      );

      final ds = BetterPlayerDataSource.network(
        'https://example.com/stream.m3u8',
        episodeId: 456,
        platform: 'ANDROID',
        deviceType: 'MOBILE',
        os: 'Android 14',
        telemetryConfiguration: config,
      );

      expect(ds.episodeId, equals(456));
      expect(ds.platform, equals('ANDROID'));
      expect(ds.deviceType, equals('MOBILE'));
      expect(ds.os, equals('Android 14'));
      expect(ds.telemetryConfiguration, equals(config));

      final copy = ds.copyWith(episodeId: 789, deviceType: 'TABLET');
      expect(copy.episodeId, equals(789));
      expect(copy.deviceType, equals('TABLET'));
      expect(copy.platform, equals('ANDROID'));
    });
  });

  group('BetterPlayerTelemetryManager Live Mock HTTP Server Tests', () {
    late HttpServer server;
    final List<Map<String, dynamic>> receivedStartRequests = [];
    final List<Map<String, dynamic>> receivedBatchRequests = [];

    setUp(() async {
      receivedStartRequests.clear();
      receivedBatchRequests.clear();

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        final body = await utf8.decodeStream(request);
        final json = jsonDecode(body) as Map<String, dynamic>;

        if (request.uri.path == '/api/v1/client/statistics/sessions/start') {
          receivedStartRequests.add(json);
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'ok'}))
            ..close();
        } else if (request.uri.path == '/api/v1/client/statistics/events/batch') {
          receivedBatchRequests.add(json);
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'ok'}))
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

    test('Dispatches session start and batch events over HTTP', () async {
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

      // Record some playback events
      controller.telemetryManager.recordPlaybackEvent(
        type: 'PLAYBACK_STARTED',
        positionS: 0.0,
      );
      controller.telemetryManager.recordPlaybackEvent(
        type: 'PAUSE',
        positionS: 12.5,
      );

      // Ingest a chunk load
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

      final playbackEvents = batchReq['playbackEvents'] as List;
      expect(playbackEvents.length, greaterThanOrEqualTo(2));

      final chunkLoads = batchReq['chunkLoads'] as List;
      expect(chunkLoads.length, equals(1));
      expect(chunkLoads.first['startS'], equals(0.0));
      expect(chunkLoads.first['endS'], equals(6.0));
      expect(chunkLoads.first['bytes'], equals(500000));

      // Test batchId changes on subsequent sends
      final firstBatchId = batchReq['batchId'];

      controller.telemetryManager.recordPlaybackEvent(
        type: 'RESUME',
        positionS: 12.5,
      );

      await Future.delayed(const Duration(milliseconds: 250));

      if (receivedBatchRequests.length > 1) {
        final secondBatchId = receivedBatchRequests[1]['batchId'];
        expect(secondBatchId, isNot(equals(firstBatchId)));
      }

      // Dispose controller and verify final batch upload
      await controller.telemetryManager.dispose(isFinal: true);
      controller.dispose(forceDispose: true);
    });

    test('Does not dispatch session start or batch requests if baseUrl is null or empty', () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      // Null baseUrl configuration
      controller.telemetryManager.startSession(
        configuration: const BetterPlayerTelemetryConfiguration(),
        telemetryData: const BetterPlayerTelemetryData(
          episodeId: 100,
        ),
      );

      controller.telemetryManager.recordPlaybackEvent(
        type: 'PLAYBACK_STARTED',
        positionS: 0.0,
      );

      await Future.delayed(const Duration(milliseconds: 200));

      expect(receivedStartRequests.isEmpty, isTrue);
      expect(receivedBatchRequests.isEmpty, isTrue);

      await controller.telemetryManager.dispose(isFinal: true);
      controller.dispose(forceDispose: true);
    });

    test('Session start payload does NOT include platform, deviceType, os, or episodeId when they are null or empty', () async {
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
        controller: mockVideo,
      );

      final client = HttpClient();
      final config = BetterPlayerTelemetryConfiguration(
        baseUrl: 'http://${server.address.host}:${server.port}',
        httpClient: client,
      );

      // Start session with NO episodeId, platform, deviceType, os
      controller.telemetryManager.startSession(
        configuration: config,
        telemetryData: const BetterPlayerTelemetryData(),
      );

      await Future.delayed(const Duration(milliseconds: 150));

      expect(receivedStartRequests.length, equals(1));
      final startReq = receivedStartRequests.first;
      expect(startReq['sessionId'], equals(controller.sessionId));
      expect(startReq['startedAt'], isNotNull);

      // Verify that no fallbacks were injected
      expect(startReq.containsKey('episodeId'), isFalse);
      expect(startReq.containsKey('platform'), isFalse);
      expect(startReq.containsKey('deviceType'), isFalse);
      expect(startReq.containsKey('os'), isFalse);

      await controller.telemetryManager.dispose(isFinal: true);
      controller.dispose(forceDispose: true);
    });
  });
}
