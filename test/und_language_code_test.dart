import 'package:better_player/better_player.dart';
import 'package:better_player/src/dash/better_player_dash_utils.dart';
import 'package:better_player/src/hls/better_player_hls_utils.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';
import 'better_player_mock_controller.dart';
import 'better_player_test_utils.dart';
import 'mock_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final MockMethodChannel mockMethodChannel = MockMethodChannel();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            mockMethodChannel.channel, mockMethodChannel.handle);
  });

  group('HLS "und" language handling', () {
    test('parseLanguages defaults null, empty, or whitespace language to "und"',
        () async {
      const hlsManifest = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="No Lang",AUTOSELECT=YES,DEFAULT=YES,URI="audio1.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Whitespace Lang",LANGUAGE="   ",URI="audio2.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",LANGUAGE="en",URI="audio3.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1280000,AUDIO="audio"
video.m3u8
''';

      final audioTracks = await BetterPlayerHlsUtils.parseLanguages(
        hlsManifest,
        'https://example.com/master.m3u8',
      );

      expect(audioTracks.length, 3);
      expect(audioTracks[0].label, 'No Lang');
      expect(audioTracks[0].language, 'und');

      expect(audioTracks[1].label, 'Whitespace Lang');
      expect(audioTracks[1].language, 'und');

      expect(audioTracks[2].label, 'English');
      expect(audioTracks[2].language, 'en');
    });
  });

  group('DASH "und" language handling', () {
    test('parseAudio defaults null, empty, or whitespace language to "und"', () {
      final xmlNoLang = XmlDocument.parse(
              '<AdaptationSet contentType="audio" label="Audio 1" mimeType="audio/mp4" />')
          .rootElement;
      final trackNoLang = BetterPlayerDashUtils.parseAudio(xmlNoLang, 0);
      expect(trackNoLang.language, 'und');

      final xmlEmptyLang = XmlDocument.parse(
              '<AdaptationSet contentType="audio" lang="" label="Audio 2" mimeType="audio/mp4" />')
          .rootElement;
      final trackEmptyLang = BetterPlayerDashUtils.parseAudio(xmlEmptyLang, 1);
      expect(trackEmptyLang.language, 'und');

      final xmlWhitespaceLang = XmlDocument.parse(
              '<AdaptationSet contentType="audio" lang="   " label="Audio 3" mimeType="audio/mp4" />')
          .rootElement;
      final trackWhitespaceLang =
          BetterPlayerDashUtils.parseAudio(xmlWhitespaceLang, 2);
      expect(trackWhitespaceLang.language, 'und');

      final xmlValidLang = XmlDocument.parse(
              '<AdaptationSet contentType="audio" lang="es" label="Spanish" mimeType="audio/mp4" />')
          .rootElement;
      final trackValidLang = BetterPlayerDashUtils.parseAudio(xmlValidLang, 3);
      expect(trackValidLang.language, 'es');
    });

    test('parseSubtitle defaults null, empty, or whitespace language to "und"',
        () {
      final xmlNoLang = XmlDocument.parse(
              '<AdaptationSet contentType="text" label="Sub 1" mimeType="text/vtt"><Representation><BaseURL>sub1.vtt</BaseURL></Representation></AdaptationSet>')
          .rootElement;
      final subNoLang = BetterPlayerDashUtils.parseSubtitle(
          'https://example.com/manifest.mpd', xmlNoLang);
      expect(subNoLang.language, 'und');

      final xmlEmptyLang = XmlDocument.parse(
              '<AdaptationSet contentType="text" lang="" label="Sub 2" mimeType="text/vtt"><Representation><BaseURL>sub2.vtt</BaseURL></Representation></AdaptationSet>')
          .rootElement;
      final subEmptyLang = BetterPlayerDashUtils.parseSubtitle(
          'https://example.com/manifest.mpd', xmlEmptyLang);
      expect(subEmptyLang.language, 'und');

      final xmlWhitespaceLang = XmlDocument.parse(
              '<AdaptationSet contentType="text" lang="  " label="Sub 3" mimeType="text/vtt"><Representation><BaseURL>sub3.vtt</BaseURL></Representation></AdaptationSet>')
          .rootElement;
      final subWhitespaceLang = BetterPlayerDashUtils.parseSubtitle(
          'https://example.com/manifest.mpd', xmlWhitespaceLang);
      expect(subWhitespaceLang.language, 'und');

      final xmlValidLang = XmlDocument.parse(
              '<AdaptationSet contentType="text" lang="fr" label="French" mimeType="text/vtt"><Representation><BaseURL>sub4.vtt</BaseURL></Representation></AdaptationSet>')
          .rootElement;
      final subValidLang = BetterPlayerDashUtils.parseSubtitle(
          'https://example.com/manifest.mpd', xmlValidLang);
      expect(subValidLang.language, 'fr');
    });
  });

  group('BetterPlayerController subtitle source handling', () {
    test('preserves dummy "Off" subtitle source with type none', () async {
      final BetterPlayerMockController controller =
          BetterPlayerMockController(const BetterPlayerConfiguration());
      await controller.setupDataSource(
          BetterPlayerDataSource.network(BetterPlayerTestUtils.forBiggerBlazesUrl));

      final noneSource = controller.betterPlayerSubtitlesSourceList
          .firstWhere((s) => s.type == BetterPlayerSubtitlesSourceType.none);
      expect(noneSource, isNotNull);
      expect(noneSource.name, 'Default subtitles');
      expect(noneSource.language, isNull);
    });
  });

  group('BetterPlayerTelemetryUtils language normalization', () {
    test('normalizeAudioLanguageCode handles null, empty, none, and valid codes', () {
      expect(BetterPlayerTelemetryUtils.normalizeAudioLanguageCode(null), 'und');
      expect(BetterPlayerTelemetryUtils.normalizeAudioLanguageCode(''), 'und');
      expect(BetterPlayerTelemetryUtils.normalizeAudioLanguageCode('   '), 'und');
      expect(BetterPlayerTelemetryUtils.normalizeAudioLanguageCode('none'), 'und');
      expect(BetterPlayerTelemetryUtils.normalizeAudioLanguageCode('null'), 'und');
      expect(BetterPlayerTelemetryUtils.normalizeAudioLanguageCode('fas'), 'fas');
      expect(BetterPlayerTelemetryUtils.normalizeAudioLanguageCode('HIN'), 'hin');
      expect(BetterPlayerTelemetryUtils.normalizeAudioLanguageCode(' und '), 'und');
    });

    test('normalizeSubtitleLanguageCode handles isNone, none, null, und, and valid codes', () {
      expect(BetterPlayerTelemetryUtils.normalizeSubtitleLanguageCode(null, isNone: true), 'none');
      expect(BetterPlayerTelemetryUtils.normalizeSubtitleLanguageCode('fas', isNone: true), 'none');
      expect(BetterPlayerTelemetryUtils.normalizeSubtitleLanguageCode('none'), 'none');
      expect(BetterPlayerTelemetryUtils.normalizeSubtitleLanguageCode('NONE'), 'none');
      expect(BetterPlayerTelemetryUtils.normalizeSubtitleLanguageCode(null), 'und');
      expect(BetterPlayerTelemetryUtils.normalizeSubtitleLanguageCode(''), 'und');
      expect(BetterPlayerTelemetryUtils.normalizeSubtitleLanguageCode('   '), 'und');
      expect(BetterPlayerTelemetryUtils.normalizeSubtitleLanguageCode('null'), 'und');
      expect(BetterPlayerTelemetryUtils.normalizeSubtitleLanguageCode('fas'), 'fas');
      expect(BetterPlayerTelemetryUtils.normalizeSubtitleLanguageCode('ENG'), 'eng');
    });
  });

  group('Telemetry playback events for audio and subtitle changes', () {
    // Starts a session and plays past the first frame.
    Future<BetterPlayerMockController> startedController() async {
      final controller =
          BetterPlayerMockController(const BetterPlayerConfiguration());
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      controller.videoPlayerController = mockVideo;
      controller.telemetryManager.startSession(
        configuration: const BetterPlayerTelemetryConfiguration(
          baseUrl: 'https://telemetry.example.com',
        ),
      );
      await mockVideo.play();
      controller.telemetryManager
          .handlePlayerEvent(BetterPlayerEvent(BetterPlayerEventType.progress));
      await mockVideo.seekTo(const Duration(seconds: 1));
      controller.telemetryManager
          .handlePlayerEvent(BetterPlayerEvent(BetterPlayerEventType.progress));
      return controller;
    }

    List<String> changes(BetterPlayerController controller, String type) =>
        controller.telemetryManager.pendingPlaybackEvents
            .where((e) => e.type == type)
            .map((e) => '${e.details['from']}>${e.details['to']}')
            .toList();

    test('AUDIO_LANGUAGE_CHANGED starts from none and drops no-op changes',
        () async {
      final controller = await startedController();
      final manager = controller.telemetryManager;

      manager.handleAudioLanguageChanged(from: null, to: 'fa', positionS: 10);
      manager.handleAudioLanguageChanged(from: 'fa', to: 'fas', positionS: 11);
      manager.handleAudioLanguageChanged(to: '', positionS: 25.5);

      expect(changes(controller, 'AUDIO_LANGUAGE_CHANGED'),
          equals(<String>['none>und', 'und>fas', 'fas>und']));
      final last = manager.pendingPlaybackEvents
          .lastWhere((e) => e.type == 'AUDIO_LANGUAGE_CHANGED');
      expect(last.positionS, 25.5);
    });

    test('SUBTITLE_CHANGED sends none for none type and und for null language',
        () async {
      final controller = await startedController();
      final manager = controller.telemetryManager;

      manager.handleSubtitleChanged(
          from: 'none', to: 'fa', isFromNone: true, positionS: 5.0);
      manager.handleSubtitleChanged(from: 'fas', to: 'en', positionS: 15.0);
      manager.handleSubtitleChanged(from: 'eng', to: null, positionS: 30.0);
      manager.handleSubtitleChanged(
          from: null, to: 'none', isToNone: true, positionS: 45.0);

      expect(
          changes(controller, 'SUBTITLE_CHANGED'),
          equals(<String>[
            'none>none',
            'none>fas',
            'fas>eng',
            'eng>und',
            'und>none',
          ]));
    });

    test('Selections before the first frame are only reported from none',
        () async {
      final controller =
          BetterPlayerMockController(const BetterPlayerConfiguration());
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      controller.videoPlayerController = mockVideo;
      final manager = controller.telemetryManager;
      manager.startSession(
        configuration: const BetterPlayerTelemetryConfiguration(
          baseUrl: 'https://telemetry.example.com',
        ),
      );

      manager.handleAudioLanguageChanged(to: 'und');
      manager.handleAudioLanguageChanged(to: 'fa');
      manager.handleSubtitleChanged(to: 'per');
      expect(manager.pendingPlaybackEvents, isEmpty);

      await mockVideo.play();
      manager
          .handlePlayerEvent(BetterPlayerEvent(BetterPlayerEventType.progress));
      await mockVideo.seekTo(const Duration(milliseconds: 400));
      manager
          .handlePlayerEvent(BetterPlayerEvent(BetterPlayerEventType.progress));

      expect(changes(controller, 'AUDIO_LANGUAGE_CHANGED'),
          equals(<String>['none>fas']));
      expect(changes(controller, 'SUBTITLE_CHANGED'),
          equals(<String>['none>fas']));
    });

    test('Controller setAudioTrack and setupSubtitleSource emit telemetry events',
        () async {
      final controller = await startedController();

      final trackFas =
          BetterPlayerAsmsAudioTrack(id: 1, label: 'Persian', language: 'fas');
      final trackHin =
          BetterPlayerAsmsAudioTrack(id: 2, label: 'Hindi', language: 'hin');
      final trackHinAgain =
          BetterPlayerAsmsAudioTrack(id: 2, label: 'Hindi', language: 'hi');

      await controller.setAudioTrack(trackFas);
      await controller.setAudioTrack(trackHin);
      // Re-selecting the same language (even as another object) is a no-op.
      await controller.setAudioTrack(trackHinAgain);

      final subNone = BetterPlayerSubtitlesSource(
          type: BetterPlayerSubtitlesSourceType.none);
      final subSpa = BetterPlayerSubtitlesSource(
        type: BetterPlayerSubtitlesSourceType.network,
        language: 'spa',
        urls: ['https://example.com/spa.vtt'],
      );

      await controller.setupSubtitleSource(subNone, sourceInitialize: true);
      await controller.setupSubtitleSource(subSpa);
      await controller.setupSubtitleSource(subNone);

      expect(changes(controller, 'AUDIO_LANGUAGE_CHANGED'),
          equals(<String>['none>und', 'und>fas', 'fas>hin']));
      expect(changes(controller, 'SUBTITLE_CHANGED'),
          equals(<String>['none>none', 'none>spa', 'spa>none']));
    });
  });

  group('ISO 639-2/T conversion', () {
    test('2-letter, B-form and regional tags become 3-letter T codes', () {
      const expected = <String, String>{
        'fa': 'fas', 'ps': 'pus', 'en': 'eng', 'hi': 'hin', 'ur': 'urd',
        'tr': 'tur', 'ar': 'ara', 'pa': 'pan', 'ta': 'tam', 'ko': 'kor',
        'de': 'deu', 'per': 'fas', 'ger': 'deu', 'fa-IR': 'fas',
        'EN_us': 'eng', 'fas': 'fas', 'prs': 'prs', 'und': 'und',
      };
      expected.forEach((input, output) {
        expect(BetterPlayerTelemetryUtils.toIso6392T(input), output,
            reason: input);
      });
    });
  });
}
