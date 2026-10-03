///Representation of HLS / DASH audio track
class BetterPlayerAsmsAudioTrack {
  ///Audio ordinal in the manifest, or in the current native track list.
  ///It is not an ExoPlayer track-group index.
  final int? id;

  ///segmentAlignment
  final bool? segmentAlignment;

  ///Description of the audio
  final String? label;

  ///Language code
  final String? language;

  ///Url of audio track
  final String? url;

  ///mimeType of the audio track
  final String? mimeType;

  ///Native track identity for the current media source, when available.
  final String? nativeTrackId;

  ///Manifest format ID (for example HLS GROUP-ID:NAME).
  final String? formatId;

  ///Whether this track is currently selected by the native player.
  final bool isSelected;

  BetterPlayerAsmsAudioTrack(
      {this.id,
      this.segmentAlignment,
      this.label,
      this.language,
      this.url,
      this.mimeType,
      this.nativeTrackId,
      this.formatId,
      this.isSelected = false});
}
