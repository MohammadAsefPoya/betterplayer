import 'dart:async';
import 'dart:io';

import 'package:better_player/better_player.dart';
import 'package:better_player/src/hls/better_player_hls_utils.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mock_video_player_controller.dart';

class DelayedAudioController extends MockVideoPlayerController {
  Completer<void>? selection;

  @override
  Future<void> setAudioTrack(String? name, int? index,
      {String? nativeTrackId, String? formatId, String? language}) async {
    await selection?.future;
  }
}

const _oldCue = 'WEBVTT\n\n00:00:10.000 --> 00:00:20.000\nOld';
const _newCue = 'WEBVTT\n\n00:00:10.000 --> 00:00:20.000\nNew';

BetterPlayerSubtitlesSource _segmentSource(String url) =>
    BetterPlayerSubtitlesSource(
      type: BetterPlayerSubtitlesSourceType.network,
      asmsIsSegmented: true,
      asmsSegmentsTime: 10000,
      asmsSegments: [
        BetterPlayerAsmsSubtitleSegment(
            const Duration(seconds: 10), const Duration(seconds: 20), url),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => HttpOverrides.global = null);

  test('audio selection changes only after the native future succeeds',
      () async {
    final controller =
        BetterPlayerController(const BetterPlayerConfiguration());
    final video = DelayedAudioController();
    controller.videoPlayerController = video;
    final track =
        BetterPlayerAsmsAudioTrack(id: 1, label: 'French', language: 'fr');
    final gate = Completer<void>();
    video.selection = gate;

    final selection = controller.setAudioTrack(track);
    expect(controller.betterPlayerAsmsAudioTrack, isNull);
    gate.complete();
    await selection;
    expect(controller.betterPlayerAsmsAudioTrack, same(track));

    final failedGate = Completer<void>();
    video.selection = failedGate;
    final other = BetterPlayerAsmsAudioTrack(id: 2, label: 'English');
    final failedSelection = controller.setAudioTrack(other);
    failedGate.completeError(StateError('not found'));
    await expectLater(failedSelection, throwsStateError);
    expect(controller.betterPlayerAsmsAudioTrack, same(track));
  });

  test('segmented subtitles load the segment covering a paused position',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      request.response
        ..headers.contentType = ContentType('text', 'vtt')
        ..write(_newCue)
        ..close();
    });
    addTearDown(() => server.close(force: true));
    final controller =
        BetterPlayerController(const BetterPlayerConfiguration());
    final video = MockVideoPlayerController()
      ..setDuration(const Duration(seconds: 100));
    controller.videoPlayerController = video;
    await video.seekTo(const Duration(seconds: 15));
    var redraws = 0;
    video.addListener(() => redraws++);

    await controller.setupSubtitleSource(
        _segmentSource('http://127.0.0.1:${server.port}/segment.vtt'));

    expect(controller.subtitlesLines.single.texts, ['New']);
    expect(video.value.position, const Duration(seconds: 15));
    expect(video.value.isPlaying, isFalse);
    expect(redraws, greaterThan(0));
  });

  test('segment-relative cues align with the media position', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response
          .write('WEBVTT\n\n00:00:05.000 --> 00:00:06.000\nAt fifteen');
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final controller =
        BetterPlayerController(const BetterPlayerConfiguration());
    final video = MockVideoPlayerController()
      ..setDuration(const Duration(seconds: 100));
    controller.videoPlayerController = video;
    await video.seekTo(const Duration(seconds: 15));

    await controller.setupSubtitleSource(
        _segmentSource('http://127.0.0.1:${server.port}/relative.vtt'));
    expect(controller.subtitlesLines.single.start, const Duration(seconds: 15));
    expect(controller.subtitlesLines.single.end, const Duration(seconds: 16));
  });

  test('HLS subtitle segment intervals start at the preceding end', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.write('''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXTINF:10,
first.vtt
#EXTINF:10,
second.vtt
#EXT-X-ENDLIST
''');
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    const master = '''#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",LANGUAGE="en",URI="subs.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1000000,SUBTITLES="subs"
video.m3u8
''';

    final subtitles = await BetterPlayerHlsUtils.parseSubtitles(
        master, 'http://127.0.0.1:${server.port}/master.m3u8');
    expect(subtitles.single.segments!.first.startTime, Duration.zero);
    expect(
        subtitles.single.segments!.first.endTime, const Duration(seconds: 10));
    expect(
        subtitles.single.segments![1].startTime, const Duration(seconds: 10));
    expect(subtitles.single.segments![1].endTime, const Duration(seconds: 20));
  });

  test('late segment from an old selection cannot replace new cues', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final slowRequest = Completer<HttpRequest>();
    final releaseOld = Completer<void>();
    server.listen((request) async {
      if (request.uri.path == '/old') {
        slowRequest.complete(request);
        await releaseOld.future;
        request.response.write(_oldCue);
      } else {
        request.response.write(_newCue);
      }
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final controller =
        BetterPlayerController(const BetterPlayerConfiguration());
    final video = MockVideoPlayerController()
      ..setDuration(const Duration(seconds: 100));
    controller.videoPlayerController = video;
    await video.seekTo(const Duration(seconds: 15));

    final oldSelection = controller.setupSubtitleSource(
        _segmentSource('http://127.0.0.1:${server.port}/old'));
    await slowRequest.future;
    await controller.setupSubtitleSource(
        _segmentSource('http://127.0.0.1:${server.port}/new'));
    releaseOld.complete();
    await oldSelection;

    expect(controller.subtitlesLines.single.texts, ['New']);
  });

  test('failed segment request retries and does not remain marked loading',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      if (requests == 1) {
        request.response.statusCode = HttpStatus.internalServerError;
      } else {
        request.response.write(_newCue);
      }
      await request.response.close();
    });
    addTearDown(() => server.close(force: true));
    final controller =
        BetterPlayerController(const BetterPlayerConfiguration());
    final video = MockVideoPlayerController()
      ..setDuration(const Duration(seconds: 100));
    controller.videoPlayerController = video;
    await video.seekTo(const Duration(seconds: 15));

    await controller.setupSubtitleSource(
        _segmentSource('http://127.0.0.1:${server.port}/retry'));
    expect(controller.subtitlesLines, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(requests, 2);
    expect(controller.subtitlesLines.single.texts, ['New']);
  });

  test('none clears a non-segmented subtitle immediately', () async {
    final controller =
        BetterPlayerController(const BetterPlayerConfiguration());
    controller.videoPlayerController = MockVideoPlayerController();
    await controller.setupSubtitleSource(BetterPlayerSubtitlesSource(
        type: BetterPlayerSubtitlesSourceType.memory, content: _oldCue));
    expect(controller.subtitlesLines, isNotEmpty);
    controller.renderedSubtitle = controller.subtitlesLines.first;

    await controller.setupSubtitleSource(BetterPlayerSubtitlesSource(
        type: BetterPlayerSubtitlesSourceType.none));
    expect(controller.subtitlesLines, isEmpty);
    expect(controller.renderedSubtitle, isNull);
  });
}
