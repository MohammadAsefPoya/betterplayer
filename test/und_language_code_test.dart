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
    test('AUDIO_LANGUAGE_CHANGED event is recorded with correct details and und fallback', () {
      final controller = BetterPlayerMockController(const BetterPlayerConfiguration());
      final manager = controller.telemetryManager;
      manager.startSession(
        configuration: const BetterPlayerTelemetryConfiguration(
          baseUrl: 'https://telemetry.example.com',
        ),
      );

      manager.handleAudioLanguageChanged(
        from: null,
        to: 'fas',
        positionS: 10.0,
      );

      final events = manager.pendingPlaybackEvents
          .where((e) => e.type == 'AUDIO_LANGUAGE_CHANGED')
          .toList();
      expect(events.length, 1);
      expect(events.first.positionS, 10.0);
      expect(events.first.details['from'], 'und');
      expect(events.first.details['to'], 'fas');

      // Next change uses previous language if from is omitted, and falls back to und if to is null/empty
      manager.handleAudioLanguageChanged(
        to: '',
        positionS: 25.5,
      );

      final events2 = manager.pendingPlaybackEvents
          .where((e) => e.type == 'AUDIO_LANGUAGE_CHANGED')
          .toList();
      expect(events2.length, 2);
      expect(events2.last.positionS, 25.5);
      expect(events2.last.details['from'], 'fas');
      expect(events2.last.details['to'], 'und');
    });

    test('SUBTITLE_CHANGED event sends none for none type and und for null language', () {
      final controller = BetterPlayerMockController(const BetterPlayerConfiguration());
      final manager = controller.telemetryManager;
      manager.startSession(
        configuration: const BetterPlayerTelemetryConfiguration(
          baseUrl: 'https://telemetry.example.com',
        ),
      );

      // From none (off) to Persian
      manager.handleSubtitleChanged(
        from: 'none',
        to: 'fas',
        isFromNone: true,
        positionS: 5.0,
      );

      // From Persian to English
      manager.handleSubtitleChanged(
        from: 'fas',
        to: 'eng',
        positionS: 15.0,
      );

      // From English to subtitle with missing language (null) -> sends 'und'
      manager.handleSubtitleChanged(
        from: 'eng',
        to: null,
        positionS: 30.0,
      );

      // From missing language (null) to none (off) -> sends 'none'
      manager.handleSubtitleChanged(
        from: null,
        to: 'none',
        isToNone: true,
        positionS: 45.0,
      );

      final events = manager.pendingPlaybackEvents
          .where((e) => e.type == 'SUBTITLE_CHANGED')
          .toList();
      expect(events.length, 4);

      expect(events[0].details['from'], 'none');
      expect(events[0].details['to'], 'fas');
      expect(events[0].positionS, 5.0);

      expect(events[1].details['from'], 'fas');
      expect(events[1].details['to'], 'eng');
      expect(events[1].positionS, 15.0);

      expect(events[2].details['from'], 'eng');
      expect(events[2].details['to'], 'und');
      expect(events[2].positionS, 30.0);

      expect(events[3].details['from'], 'und');
      expect(events[3].details['to'], 'none');
      expect(events[3].positionS, 45.0);
    });

    test('Controller setAudioTrack and setupSubtitleSource emit telemetry events', () async {
      final controller = BetterPlayerMockController(const BetterPlayerConfiguration());
      final mockVideo = BetterPlayerTestUtils.setupMockVideoPlayerControler();
      controller.videoPlayerController = mockVideo;

      controller.telemetryManager.startSession(
        configuration: const BetterPlayerTelemetryConfiguration(
          baseUrl: 'https://telemetry.example.com',
        ),
      );

      final trackFas = BetterPlayerAsmsAudioTrack(id: 1, label: 'Persian', language: 'fas');
      final trackHin = BetterPlayerAsmsAudioTrack(id: 2, label: 'Hindi', language: 'hin');

      await controller.setAudioTrack(trackFas);
      await controller.setAudioTrack(trackHin);

      // Selecting the same track again does not emit a duplicate event
      await controller.setAudioTrack(trackHin);

      final subNone = BetterPlayerSubtitlesSource(type: BetterPlayerSubtitlesSourceType.none);
      final subSpa = BetterPlayerSubtitlesSource(
        type: BetterPlayerSubtitlesSourceType.network,
        language: 'spa',
        urls: ['https://example.com/spa.vtt'],
      );

      // Setup initial subtitle does not emit event when sourceInitialize is true
      await controller.setupSubtitleSource(subNone, sourceInitialize: true);

      // Switch to Spanish
      await controller.setupSubtitleSource(subSpa);

      // Switch back to none (off)
      await controller.setupSubtitleSource(subNone);

      final audioEvents = controller.telemetryManager.pendingPlaybackEvents
          .where((e) => e.type == 'AUDIO_LANGUAGE_CHANGED')
          .toList();
      expect(audioEvents.length, 2);
      expect(audioEvents[0].details['from'], 'und');
      expect(audioEvents[0].details['to'], 'fas');
      expect(audioEvents[1].details['from'], 'fas');
      expect(audioEvents[1].details['to'], 'hin');

      final subEvents = controller.telemetryManager.pendingPlaybackEvents
          .where((e) => e.type == 'SUBTITLE_CHANGED')
          .toList();
      expect(subEvents.length, 2);
      expect(subEvents[0].details['from'], 'none');
      expect(subEvents[0].details['to'], 'spa');
      expect(subEvents[1].details['from'], 'spa');
      expect(subEvents[1].details['to'], 'none');
    });
  });
}
