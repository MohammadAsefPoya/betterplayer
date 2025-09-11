import 'dart:async';
import 'package:better_player/better_player.dart';
import 'package:better_player/src/subtitles/better_player_subtitle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

class BetterPlayerSubtitlesDrawer extends StatefulWidget {
  final List<BetterPlayerSubtitle> subtitles;
  final BetterPlayerController betterPlayerController;
  final BetterPlayerSubtitlesConfiguration? betterPlayerSubtitlesConfiguration;
  final Stream<bool> playerVisibilityStream;

  const BetterPlayerSubtitlesDrawer({
    Key? key,
    required this.subtitles,
    required this.betterPlayerController,
    this.betterPlayerSubtitlesConfiguration,
    required this.playerVisibilityStream,
  }) : super(key: key);

  @override
  _BetterPlayerSubtitlesDrawerState createState() =>
      _BetterPlayerSubtitlesDrawerState();
}

class _BetterPlayerSubtitlesDrawerState
    extends State<BetterPlayerSubtitlesDrawer> {
  // (kept from your file; not used here but harmless)
  final RegExp htmlRegExp = RegExp(r"<[^>]*>", multiLine: true);

  late TextStyle _innerTextStyle;
  late TextStyle _outerTextStyle;

  VideoPlayerValue? _latestValue;
  late BetterPlayerSubtitlesConfiguration _configuration;
  bool _playerVisible = false;

  /// Stream used to detect if play controls are visible or not
  late StreamSubscription<bool> _visibilityStreamSubscription;

  // Ensure the incoming stream is broadcast so multiple listeners during rebuilds don't throw.
  Stream<bool> _ensureBroadcast(Stream<bool> s) =>
      s.isBroadcast ? s : s.asBroadcastStream();

  void _recomputeStyles() {
    _outerTextStyle = TextStyle(
      fontSize: _configuration.fontSize,
      fontFamily: _configuration.fontFamily,
      foreground: Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _configuration.outlineSize
        ..color = _configuration.outlineColor,
    );

    _innerTextStyle = TextStyle(
      fontFamily: _configuration.fontFamily,
      color: _configuration.fontColor,
      fontSize: _configuration.fontSize,
    );
  }

  @override
  void initState() {
    super.initState();

    _configuration = widget.betterPlayerSubtitlesConfiguration ??
        const BetterPlayerSubtitlesConfiguration();
    _recomputeStyles();

    _visibilityStreamSubscription =
        _ensureBroadcast(widget.playerVisibilityStream).listen((state) {
      if (!mounted) return;
      setState(() => _playerVisible = state);
    });

    widget.betterPlayerController.videoPlayerController!
        .addListener(_updateState);
  }

  @override
  void didUpdateWidget(covariant BetterPlayerSubtitlesDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);

    // If the visibility stream instance changed, resubscribe safely.
    if (oldWidget.playerVisibilityStream != widget.playerVisibilityStream) {
      _visibilityStreamSubscription.cancel();
      _visibilityStreamSubscription =
          _ensureBroadcast(widget.playerVisibilityStream).listen((state) {
        if (!mounted) return;
        setState(() => _playerVisible = state);
      });
    }

    // Always apply latest configuration (enables live styling)
    _configuration = widget.betterPlayerSubtitlesConfiguration ??
        const BetterPlayerSubtitlesConfiguration();
    _recomputeStyles();
    setState(() {}); // redraw with new styles
  }

  @override
  void dispose() {
    widget.betterPlayerController.videoPlayerController!
        .removeListener(_updateState);
    _visibilityStreamSubscription.cancel();
    super.dispose();
  }

  /// Called when player state has changed, i.e. new player position, etc.
  void _updateState() {
    if (!mounted) return;
    setState(() {
      _latestValue = widget.betterPlayerController.videoPlayerController!.value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final BetterPlayerSubtitle? subtitle = _getSubtitleAtCurrentPosition();
    widget.betterPlayerController.renderedSubtitle = subtitle;
    final List<String> texts = subtitle?.texts ?? [];
    final List<Widget> textWidgets =
        texts.map((text) => _buildSubtitleTextWidget(text)).toList();

    return SizedBox.expand(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: _playerVisible
              ? _configuration.bottomPadding + 30
              : _configuration.bottomPadding,
          left: _configuration.leftPadding,
          right: _configuration.rightPadding,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.end,
          children: textWidgets,
        ),
      ),
    );
  }

  BetterPlayerSubtitle? _getSubtitleAtCurrentPosition() {
    if (_latestValue == null) return null;

    final Duration position = _latestValue!.position;
    for (final BetterPlayerSubtitle subtitle
        in widget.betterPlayerController.subtitlesLines) {
      if (subtitle.start! <= position && subtitle.end! >= position) {
        return subtitle;
      }
    }
    return null;
  }

  Widget _buildSubtitleTextWidget(String subtitleText) {
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: _configuration.alignment,
            child: _getTextWithStroke(subtitleText),
          ),
        ),
      ],
    );
  }

  Widget _getTextWithStroke(String subtitleText) {
    return Container(
      color: _configuration.backgroundColor,
      child: Stack(
        children: [
          if (_configuration.outlineEnabled)
            _buildHtmlWidget(subtitleText, _outerTextStyle)
          else
            const SizedBox.shrink(),
          _buildHtmlWidget(subtitleText, _innerTextStyle),
        ],
      ),
    );
  }

  Widget _buildHtmlWidget(String text, TextStyle textStyle) {
    return HtmlWidget(text, textStyle: textStyle);
  }
}
