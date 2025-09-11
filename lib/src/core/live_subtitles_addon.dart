// lib/src/core/live_subtitles_addon.dart
//
// Adds live subtitle styling to Better Player via an extension on
// BetterPlayerController and an internal registry of ValueNotifiers.
// No changes to BetterPlayerController are required.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Alignment, Color, Colors;
import '../subtitles/better_player_subtitles_configuration.dart';
import 'better_player_controller.dart';

class _LiveSubtitlesRegistry {
  static final Map<BetterPlayerController,
      ValueNotifier<BetterPlayerSubtitlesConfiguration>> _notifiers = {};

  static ValueNotifier<BetterPlayerSubtitlesConfiguration> of(
      BetterPlayerController controller) {
    return _notifiers.putIfAbsent(
      controller,
      () => ValueNotifier<BetterPlayerSubtitlesConfiguration>(
        controller.betterPlayerConfiguration.subtitlesConfiguration,
      ),
    );
  }

  static void dispose(BetterPlayerController controller) {
    _notifiers.remove(controller)?.dispose();
  }
}

/// Public extension: instant subtitle updates with no re-init.
extension BetterPlayerLiveSubtitles on BetterPlayerController {
  /// Listen to this in the subtitles layer; push new configs to update live.
  ValueNotifier<BetterPlayerSubtitlesConfiguration>
      get subtitlesConfigNotifier => _LiveSubtitlesRegistry.of(this);

  /// Update the subtitle style *live*.
  void updateSubtitlesConfiguration(
      BetterPlayerSubtitlesConfiguration configuration) {
    subtitlesConfigNotifier.value = configuration;
  }

  /// Optional: call this alongside controller.dispose() if you want eager cleanup.
  void disposeLiveSubtitles() => _LiveSubtitlesRegistry.dispose(this);
}
