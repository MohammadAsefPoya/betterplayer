// lib/src/core/live_subtitles_addon.dart
//
// Live subtitle styling helpers for Better Player.
//
// - Per-controller ValueNotifier stored via Expando (no leaks)
// - Getters for current, initial, and package-default configs
// - Reset helpers (to initial or package defaults)
// - Full-update and partial-update APIs (uses copyWith)

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Alignment, Color;

import '../subtitles/better_player_subtitles_configuration.dart';
import 'better_player_controller.dart';

class _LiveSubtitlesRegistry {
  // One notifier per controller (weakly referenced).
  static final Expando<ValueNotifier<BetterPlayerSubtitlesConfiguration>>
      _notifier = Expando('bp_live_subs_notifier');

  // Remember the initial config (what the controller was constructed with).
  static final Expando<BetterPlayerSubtitlesConfiguration> _initial =
      Expando('bp_live_subs_initial');

  static ValueNotifier<BetterPlayerSubtitlesConfiguration> of(
      BetterPlayerController controller) {
    final existing = _notifier[controller];
    if (existing != null) return existing;

    final initial = controller.betterPlayerConfiguration.subtitlesConfiguration;
    _initial[controller] = initial;

    final created = ValueNotifier<BetterPlayerSubtitlesConfiguration>(initial);
    _notifier[controller] = created;
    return created;
  }

  static BetterPlayerSubtitlesConfiguration initialOf(
          BetterPlayerController controller) =>
      _initial[controller] ??
      controller.betterPlayerConfiguration.subtitlesConfiguration;

  static void dispose(BetterPlayerController controller) {
    _notifier[controller]?.dispose();
    _notifier[controller] = null;
    _initial[controller] = null;
  }
}

/// Public extension: instant subtitle updates and accessors.
extension BetterPlayerLiveSubtitles on BetterPlayerController {
  /// Reactive config you can listen to (used by the subtitles drawer).
  ValueNotifier<BetterPlayerSubtitlesConfiguration>
      get subtitlesConfigNotifier => _LiveSubtitlesRegistry.of(this);

  /// The currently active subtitles configuration.
  BetterPlayerSubtitlesConfiguration get currentSubtitlesConfiguration =>
      subtitlesConfigNotifier.value;

  /// The configuration captured when this controller was created.
  BetterPlayerSubtitlesConfiguration get initialSubtitlesConfiguration =>
      _LiveSubtitlesRegistry.initialOf(this);

  /// The package-wide default configuration (independent of this controller).
  BetterPlayerSubtitlesConfiguration get packageDefaultSubtitlesConfiguration =>
      BetterPlayerSubtitlesConfiguration.defaults;

  /// Replace the entire configuration (live).
  void updateSubtitlesConfiguration(
      BetterPlayerSubtitlesConfiguration configuration) {
    subtitlesConfigNotifier.value = configuration;
  }

  /// Reset to the configuration the controller started with.
  void resetSubtitlesToInitial() {
    subtitlesConfigNotifier.value = initialSubtitlesConfiguration;
  }

  /// Reset to package defaults (constructor defaults).
  void resetSubtitlesToPackageDefaults() {
    subtitlesConfigNotifier.value = BetterPlayerSubtitlesConfiguration.defaults;
  }

  /// Partial update using `copyWith` (keeps other fields intact).
  void updateSubtitleStyle({
    double? fontSize,
    Color? fontColor,
    Color? backgroundColor,
    Alignment? alignment,
    bool? outlineEnabled,
    Color? outlineColor,
    double? outlineSize,
    String? fontFamily,
    double? leftPadding,
    double? rightPadding,
    double? bottomPadding,
  }) {
    final next = subtitlesConfigNotifier.value.copyWith(
      fontSize: fontSize,
      fontColor: fontColor,
      backgroundColor: backgroundColor,
      alignment: alignment,
      outlineEnabled: outlineEnabled,
      outlineColor: outlineColor,
      outlineSize: outlineSize,
      fontFamily: fontFamily,
      leftPadding: leftPadding,
      rightPadding: rightPadding,
      bottomPadding: bottomPadding,
    );
    subtitlesConfigNotifier.value = next;
  }

  /// Convenience one-liners
  void setSubtitleFontSize(double size) => updateSubtitleStyle(fontSize: size);

  void setSubtitleTextColor(Color color) =>
      updateSubtitleStyle(fontColor: color);

  void setSubtitleBackgroundColor(Color color) =>
      updateSubtitleStyle(backgroundColor: color);

  void setSubtitleAlignment(Alignment align) =>
      updateSubtitleStyle(alignment: align);

  void setSubtitleOutline({
    bool? enabled,
    double? size,
    Color? color,
  }) =>
      updateSubtitleStyle(
        outlineEnabled: enabled,
        outlineSize: size,
        outlineColor: color,
      );

  /// Optional: eager cleanup alongside `controller.dispose()`.
  void disposeLiveSubtitles() => _LiveSubtitlesRegistry.dispose(this);
}

/// Sugar for nullable controllers (optional to use).
extension BetterPlayerLiveSubtitlesNullable on BetterPlayerController? {
  BetterPlayerSubtitlesConfiguration? get currentSubtitlesConfigurationOrNull =>
      this == null ? null : _LiveSubtitlesRegistry.of(this!).value;

  BetterPlayerSubtitlesConfiguration? get initialSubtitlesConfigurationOrNull =>
      this == null ? null : _LiveSubtitlesRegistry.initialOf(this!);

  void updateSubtitleStyleIfNotNull({
    double? fontSize,
    Color? fontColor,
    Color? backgroundColor,
    Alignment? alignment,
    bool? outlineEnabled,
    Color? outlineColor,
    double? outlineSize,
    String? fontFamily,
    double? leftPadding,
    double? rightPadding,
    double? bottomPadding,
  }) {
    final c = this;
    if (c == null) return;
    _LiveSubtitlesRegistry.of(c).value =
        _LiveSubtitlesRegistry.of(c).value.copyWith(
              fontSize: fontSize,
              fontColor: fontColor,
              backgroundColor: backgroundColor,
              alignment: alignment,
              outlineEnabled: outlineEnabled,
              outlineColor: outlineColor,
              outlineSize: outlineSize,
              fontFamily: fontFamily,
              leftPadding: leftPadding,
              rightPadding: rightPadding,
              bottomPadding: bottomPadding,
            );
  }
}
