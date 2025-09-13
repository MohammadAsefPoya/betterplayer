// lib/src/subtitles/better_player_subtitles_configuration.dart
import 'package:flutter/material.dart';

/// Styling for subtitles drawn by Better Player.
class BetterPlayerSubtitlesConfiguration {
  /// Font size of the subtitle text.
  final double fontSize;

  /// Text color of the subtitle.
  final Color fontColor;

  /// Whether an outline (stroke) behind the text is shown.
  final bool outlineEnabled;

  /// Color of the outline.
  final Color outlineColor;

  /// Size (blur/stroke) of the outline.
  final double outlineSize;

  /// Font family used to render the subtitle.
  final String fontFamily;

  /// Left padding from the left screen edge.
  final double leftPadding;

  /// Right padding from the right screen edge.
  final double rightPadding;

  /// Bottom padding from the bottom screen edge.
  final double bottomPadding;

  /// Alignment of the subtitle block (usually [Alignment.center]).
  final Alignment alignment;

  /// Background color behind the text (use with transparency for readability).
  final Color backgroundColor;

  const BetterPlayerSubtitlesConfiguration({
    this.fontSize = 14.0,
    this.fontColor = Colors.white,
    this.outlineEnabled = true,
    this.outlineColor = Colors.black,
    this.outlineSize = 2.0,
    this.fontFamily = 'Roboto',
    this.leftPadding = 8.0,
    this.rightPadding = 8.0,
    this.bottomPadding = 20.0,
    this.alignment = Alignment.center,
    this.backgroundColor = Colors.transparent,
  });

  /// Handy canonical default instance.
  static const BetterPlayerSubtitlesConfiguration defaults =
      BetterPlayerSubtitlesConfiguration();

  /// Create a new configuration overriding only selected fields.
  BetterPlayerSubtitlesConfiguration copyWith({
    double? fontSize,
    Color? fontColor,
    bool? outlineEnabled,
    Color? outlineColor,
    double? outlineSize,
    String? fontFamily,
    double? leftPadding,
    double? rightPadding,
    double? bottomPadding,
    Alignment? alignment,
    Color? backgroundColor,
  }) {
    return BetterPlayerSubtitlesConfiguration(
      fontSize: fontSize ?? this.fontSize,
      fontColor: fontColor ?? this.fontColor,
      outlineEnabled: outlineEnabled ?? this.outlineEnabled,
      outlineColor: outlineColor ?? this.outlineColor,
      outlineSize: outlineSize ?? this.outlineSize,
      fontFamily: fontFamily ?? this.fontFamily,
      leftPadding: leftPadding ?? this.leftPadding,
      rightPadding: rightPadding ?? this.rightPadding,
      bottomPadding: bottomPadding ?? this.bottomPadding,
      alignment: alignment ?? this.alignment,
      backgroundColor: backgroundColor ?? this.backgroundColor,
    );
  }

  @override
  String toString() {
    return 'BetterPlayerSubtitlesConfiguration('
        'fontSize: $fontSize, fontColor: $fontColor, '
        'outlineEnabled: $outlineEnabled, outlineColor: $outlineColor, outlineSize: $outlineSize, '
        'fontFamily: $fontFamily, leftPadding: $leftPadding, rightPadding: $rightPadding, '
        'bottomPadding: $bottomPadding, alignment: $alignment, backgroundColor: $backgroundColor)';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BetterPlayerSubtitlesConfiguration &&
          runtimeType == other.runtimeType &&
          fontSize == other.fontSize &&
          fontColor == other.fontColor &&
          outlineEnabled == other.outlineEnabled &&
          outlineColor == other.outlineColor &&
          outlineSize == other.outlineSize &&
          fontFamily == other.fontFamily &&
          leftPadding == other.leftPadding &&
          rightPadding == other.rightPadding &&
          bottomPadding == other.bottomPadding &&
          alignment == other.alignment &&
          backgroundColor == other.backgroundColor;

  @override
  int get hashCode => Object.hash(
        fontSize,
        fontColor,
        outlineEnabled,
        outlineColor,
        outlineSize,
        fontFamily,
        leftPadding,
        rightPadding,
        bottomPadding,
        alignment,
        backgroundColor,
      );
}
