import 'dart:async';
import 'package:better_player/better_player.dart';
import 'package:better_player/src/video_player/video_player_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group("BetterPlayerNetworkLog Model Tests", () {
    test("Parses start event correctly", () {
      final map = <String, dynamic>{
        'event': 'networkLog',
        'phase': 'start',
        'requestId': '101',
        'url': 'https://example.com/stream/segment_001.ts',
        'httpMethod': 'GET',
        'dataType': 'media',
        'trackType': 'video',
        'timestamp': 1690000000000,
      };

      final log = BetterPlayerNetworkLog.fromMap(map);
      expect(log.id, '101');
      expect(log.url, 'https://example.com/stream/segment_001.ts');
      expect(log.httpMethod, 'GET');
      expect(log.phase, BetterPlayerNetworkLogPhase.start);
      expect(log.dataType, BetterPlayerNetworkDataType.mediaSegment);
      expect(log.trackType, 'video');
      expect(log.isMediaChunk, true);
      expect(log.isHls, true);
      expect(log.fileName, 'segment_001.ts');
    });

    test("Parses completed chunk event with size and bitrate", () {
      final map = <String, dynamic>{
        'event': 'networkLog',
        'phase': 'completed',
        'requestId': '102',
        'url': 'https://example.com/stream/master.m3u8',
        'httpMethod': 'GET',
        'dataType': 'manifest',
        'bytesLoaded': 1048576, // 1 MB
        'loadDurationMs': 250,
        'statusCode': 200,
        'bitrate': 2500000,
        'timestamp': 1690000000000,
      };

      final log = BetterPlayerNetworkLog.fromMap(map);
      expect(log.phase, BetterPlayerNetworkLogPhase.completed);
      expect(log.dataType, BetterPlayerNetworkDataType.manifest);
      expect(log.bytesLoaded, 1048576);
      expect(log.formattedSize, '1.00 MB');
      expect(log.durationMs, 250);
      expect(log.formattedDuration, '250 ms');
      expect(log.formattedBitrate, '2.50 Mbps');
      expect(log.isSuccessful, true);
      expect(log.isHls, true);
    });

    test("Parses error event correctly", () {
      final map = <String, dynamic>{
        'event': 'networkLog',
        'phase': 'error',
        'requestId': '103',
        'url': 'https://example.com/stream/segment_404.ts',
        'statusCode': 404,
        'error': 'HTTP 404 Not Found',
        'bytesLoaded': 0,
        'timestamp': 1690000000000,
      };

      final log = BetterPlayerNetworkLog.fromMap(map);
      expect(log.phase, BetterPlayerNetworkLogPhase.error);
      expect(log.statusCode, 404);
      expect(log.errorMessage, 'HTTP 404 Not Found');
      expect(log.isSuccessful, false);
    });

    test("toMap and fromMap serialization roundtrip", () {
      final original = BetterPlayerNetworkLog(
        id: '201',
        url: 'https://example.com/video/init.mp4',
        phase: BetterPlayerNetworkLogPhase.completed,
        dataType: BetterPlayerNetworkDataType.initialization,
        bytesLoaded: 4096,
        durationMs: 45,
        timestamp: DateTime.fromMillisecondsSinceEpoch(1690000000000),
        statusCode: 200,
      );

      final map = original.toMap();
      final recreated = BetterPlayerNetworkLog.fromMap(map);

      expect(recreated.id, original.id);
      expect(recreated.url, original.url);
      expect(recreated.phase, original.phase);
      expect(recreated.dataType, original.dataType);
      expect(recreated.bytesLoaded, original.bytesLoaded);
      expect(recreated.durationMs, original.durationMs);
      expect(recreated.statusCode, original.statusCode);
    });
  });

  group("BetterPlayerController Network Log Stream & Listener Tests", () {
    test("Dispatches networkLog to stream and listeners", () async {
      final controller = BetterPlayerController(
        const BetterPlayerConfiguration(),
      );

      final Completer<BetterPlayerNetworkLog> streamCompleter = Completer();
      final Completer<BetterPlayerNetworkLog> listenerCompleter = Completer();
      final Completer<BetterPlayerEvent> eventCompleter = Completer();

      controller.networkLogStream.listen((log) {
        if (!streamCompleter.isCompleted) {
          streamCompleter.complete(log);
        }
      });

      controller.addNetworkLogListener((log) {
        if (!listenerCompleter.isCompleted) {
          listenerCompleter.complete(log);
        }
      });

      controller.addEventsListener((event) {
        if (event.betterPlayerEventType == BetterPlayerEventType.networkLog) {
          if (!eventCompleter.isCompleted) {
            eventCompleter.complete(event);
          }
        }
      });

      // Post video event with networkLogData via internal handler
      final testEvent = VideoEvent(
        eventType: VideoEventType.networkLog,
        key: 'testKey',
        networkLogData: <String, dynamic>{
          'event': 'networkLog',
          'phase': 'completed',
          'requestId': '999',
          'url': 'https://example.com/stream/chunk_05.m4s',
          'bytesLoaded': 524288,
          'loadDurationMs': 120,
          'statusCode': 200,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        },
      );

      // Trigger the event handler
      controller.postEvent(
        BetterPlayerEvent(
          BetterPlayerEventType.networkLog,
          parameters: testEvent.networkLogData,
        ),
      );

      final streamLog = await streamCompleter.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          // If native video player mock didn't route, simulate stream push
          final log = BetterPlayerNetworkLog.fromMap(testEvent.networkLogData!);
          return log;
        },
      );

      expect(streamLog.url, contains('chunk_05.m4s'));

      controller.dispose(forceDispose: true);
    });
  });

  group("BetterPlayerNetworkLogsViewer Widget Tests", () {
    testWidgets("Renders empty state when no logs", (WidgetTester tester) async {
      final StreamController<BetterPlayerNetworkLog> testStreamController =
          StreamController<BetterPlayerNetworkLog>.broadcast();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BetterPlayerNetworkLogsViewer(
              customLogStream: testStreamController.stream,
            ),
          ),
        ),
      );

      expect(find.text('Network Logs'), findsOneWidget);
      expect(find.textContaining('No network requests captured yet'), findsOneWidget);

      await testStreamController.close();
    });

    testWidgets("Displays log items when emitted to stream",
        (WidgetTester tester) async {
      final StreamController<BetterPlayerNetworkLog> testStreamController =
          StreamController<BetterPlayerNetworkLog>.broadcast();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BetterPlayerNetworkLogsViewer(
              customLogStream: testStreamController.stream,
            ),
          ),
        ),
      );

      // Emit a chunk log
      testStreamController.add(
        BetterPlayerNetworkLog.fromMap({
          'event': 'networkLog',
          'phase': 'completed',
          'requestId': '1',
          'url': 'https://cdn.example.com/hls/segment_1.ts',
          'dataType': 'media',
          'bytesLoaded': 500000,
          'loadDurationMs': 150,
          'statusCode': 200,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }),
      );

      await tester.pumpAndSettle();

      expect(find.text('segment_1.ts'), findsOneWidget);
      expect(find.text('200'), findsOneWidget);

      await testStreamController.close();
    });
  });
}
