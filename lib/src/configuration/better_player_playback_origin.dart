///Describes who triggered a play or pause transition. It is carried in the
///`origin` parameter of [BetterPlayerEventType.play] and
///[BetterPlayerEventType.pause] events and decides whether telemetry reports
///a PAUSE / RESUME event.
enum BetterPlayerPlaybackOrigin {
  ///The viewer pressed play or pause (controls, remote, keyboard).
  user,

  ///The app or the player changed playback on its own: ads, dialogs, episode
  ///change, app lifecycle, visibility, quality change, retry, scrubbing.
  system,

  ///Reported by the native player (buffering, errors, end of media,
  ///notification or PiP controls).
  native,
}
