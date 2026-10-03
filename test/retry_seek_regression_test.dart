import 'dart:async';

import 'package:better_player/better_player.dart';
import 'package:better_player/src/video_player/video_player.dart';
import 'package:better_player/src/video_player/video_player_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

class RecoveryTestPlatform extends VideoPlayerPlatform {
  final events = StreamController<VideoEvent>.broadcast();
  final calls = <String>[];
  Duration currentPosition = Duration.zero;
  Completer<void>? seekGate;
  Completer<void>? transitionGate;
  bool failNextSeek = false;
  bool failNextSource = false;
  bool positionStuckAtZero = false;

  @override
  Future<void> init() async {}

  @override
  Future<int?> create(
          {BetterPlayerBufferingConfiguration? bufferingConfiguration}) async =>
      1;

  @override
  Stream<VideoEvent> videoEventsFor(int? textureId) => events.stream;

  @override
  Future<void> setDataSource(int? textureId, DataSource dataSource) async {
    calls.add('source');
    if (failNextSource) {
      failNextSource = false;
      throw StateError('source failed');
    }
    currentPosition = Duration.zero;
    scheduleMicrotask(() => events.add(VideoEvent(
          eventType: VideoEventType.initialized,
          key: dataSource.key,
          duration: const Duration(seconds: 100),
        )));
  }

  @override
  Future<void> seekTo(int? textureId, Duration? position) async {
    calls.add('seek:${position!.inSeconds}');
    if (failNextSeek) {
      failNextSeek = false;
      events.addError(StateError('seek failed'));
      throw StateError('seek failed');
    }
    await seekGate?.future;
    currentPosition = position;
  }

  @override
  Future<void> play(int? textureId) async {
    calls.add('play');
    await transitionGate?.future;
  }

  @override
  Future<void> pause(int? textureId) async {
    calls.add('pause');
    await transitionGate?.future;
  }

  @override
  Future<void> setLooping(int? textureId, bool looping) async {}

  @override
  Future<void> setVolume(int? textureId, double volume) async {}

  @override
  Future<void> setTrackParameters(
      int? textureId, int? width, int? height, int? bitrate) async {}

  @override
  Future<Duration> getPosition(int? textureId) async =>
      positionStuckAtZero ? Duration.zero : currentPosition;

  @override
  Future<DateTime?> getAbsolutePosition(int? textureId) async => null;

  @override
  Future<void> dispose(int? textureId) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late RecoveryTestPlatform platform;

  setUpAll(() {
    platform = RecoveryTestPlatform();
    VideoPlayerPlatform.instance = platform;
  });

  setUp(() {
    platform.calls.clear();
    platform.currentPosition = Duration.zero;
    platform.failNextSeek = false;
    platform.failNextSource = false;
    platform.positionStuckAtZero = false;
    platform.seekGate = null;
    platform.transitionGate = null;
  });

  test('retry restores a failed seek and play intent without early autoplay',
      () async {
    final controller =
        BetterPlayerController(const BetterPlayerConfiguration(autoPlay: true));
    var initialized = 0;
    controller.addEventsListener((event) {
      if (event.betterPlayerEventType == BetterPlayerEventType.initialized) {
        initialized++;
      }
    });
    await controller.setupDataSource(
        BetterPlayerDataSource.network('https://example.com/video.mp4'));
    platform.failNextSeek = true;
    await expectLater(
        controller.seekTo(const Duration(seconds: 35)), throwsStateError);

    platform.calls.clear();
    await controller.retryDataSource();

    expect(controller.videoPlayerController!.value.position,
        const Duration(seconds: 35));
    expect(controller.isPlaying(), isTrue);
    expect(initialized, 2);
    expect(platform.calls.where((call) => call == 'play').length, 1);
    expect(platform.calls.indexOf('play'),
        greaterThan(platform.calls.indexOf('seek:35')));
    controller.dispose(forceDispose: true);
  });

  test('retry retains pause intent and accepts an explicit recovery position',
      () async {
    final controller =
        BetterPlayerController(const BetterPlayerConfiguration(autoPlay: true));
    await controller.setupDataSource(
        BetterPlayerDataSource.network('https://example.com/video.mp4'));
    await controller.pause();
    platform.failNextSeek = true;
    await expectLater(
        controller.seekTo(const Duration(seconds: 18)), throwsStateError);

    platform.calls.clear();
    await controller.retryDataSource(
        resumePosition: const Duration(seconds: 42), playOnSuccess: false);

    expect(controller.videoPlayerController!.value.position,
        const Duration(seconds: 42));
    expect(controller.isPlaying(), isFalse);
    expect(platform.calls, isNot(contains('play')));
    controller.dispose(forceDispose: true);
  });

  test('retry propagates source and seek failures', () async {
    final controller =
        BetterPlayerController(const BetterPlayerConfiguration());
    await controller.setupDataSource(
        BetterPlayerDataSource.network('https://example.com/video.mp4'));
    await controller.seekTo(const Duration(seconds: 12));

    platform.failNextSource = true;
    await expectLater(controller.retryDataSource(), throwsStateError);
    await controller.retryDataSource();
    expect(controller.videoPlayerController!.value.position,
        const Duration(seconds: 12));
    platform.failNextSeek = true;
    await expectLater(
        controller.retryDataSource(resumePosition: const Duration(seconds: 20)),
        throwsStateError);
    await controller.retryDataSource();
    expect(controller.videoPlayerController!.value.position,
        const Duration(seconds: 20));
    controller.dispose(forceDispose: true);
  });

  test('retry does not succeed while the native position remains at zero',
      () async {
    final controller = BetterPlayerController(const BetterPlayerConfiguration());
    await controller.setupDataSource(
        BetterPlayerDataSource.network('https://example.com/video.mp4'));
    platform.positionStuckAtZero = true;
    await expectLater(
        controller.retryDataSource(resumePosition: const Duration(seconds: 20)),
        throwsStateError);
    controller.dispose(forceDispose: true);
  });

  test('seek clamps both ends and waits for the pause transition', () async {
    final controller = VideoPlayerController();
    await controller.setNetworkDataSource('https://example.com/video.mp4');

    final gate = Completer<void>();
    platform.transitionGate = gate;
    var completed = false;
    final seek = controller.seekTo(const Duration(seconds: 150)).then((_) {
      completed = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(platform.calls, contains('seek:100'));
    gate.complete();
    await seek;
    expect(controller.value.position, const Duration(seconds: 100));
    expect(controller.value.isPlaying, isFalse);

    platform.transitionGate = null;
    await controller.seekTo(const Duration(seconds: -5));
    expect(platform.calls.lastIndexOf('seek:0'), greaterThan(-1));
    expect(controller.value.position, Duration.zero);
    await controller.dispose();
  });

  test('rapid seeks finish in request order and the last position wins',
      () async {
    final controller = VideoPlayerController();
    await controller.setNetworkDataSource('https://example.com/video.mp4');
    final gate = Completer<void>();
    platform.seekGate = gate;

    final first = controller.seekTo(const Duration(seconds: 10));
    final second = controller.seekTo(const Duration(seconds: 20));
    await Future<void>.delayed(Duration.zero);
    expect(
        platform.calls.where((call) => call.startsWith('seek:')), ['seek:10']);
    gate.complete();
    await Future.wait([first, second]);
    expect(controller.value.position, const Duration(seconds: 20));
    expect(platform.calls.where((call) => call.startsWith('seek:')),
        ['seek:10', 'seek:20']);
    await controller.dispose();
  });

  test('seek waits for the play transition', () async {
    final controller = VideoPlayerController();
    await controller.setNetworkDataSource('https://example.com/video.mp4');
    await controller.play();
    final gate = Completer<void>();
    platform.transitionGate = gate;
    var completed = false;
    final seek = controller.seekTo(const Duration(seconds: 12)).then((_) {
      completed = true;
    });
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(platform.calls.last, 'play');
    gate.complete();
    await seek;
    expect(controller.value.position, const Duration(seconds: 12));
    expect(controller.value.isPlaying, isTrue);
    await controller.dispose();
  });
}
