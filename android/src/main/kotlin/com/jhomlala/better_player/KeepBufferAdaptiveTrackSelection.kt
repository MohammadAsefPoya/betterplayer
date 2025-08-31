package com.jhomlala.better_player

import com.google.android.exoplayer2.source.TrackGroup
import com.google.android.exoplayer2.source.chunk.MediaChunk
import com.google.android.exoplayer2.trackselection.AdaptiveTrackSelection
import com.google.android.exoplayer2.trackselection.ExoTrackSelection
import com.google.android.exoplayer2.upstream.BandwidthMeter

/**
 * Adaptive selection that NEVER discards already-buffered chunks when quality changes.
 * The new quality takes effect only after the buffered queue is consumed.
 */
internal class KeepBufferAdaptiveTrackSelection(
    group: TrackGroup,
    tracks: IntArray,
    bandwidthMeter: BandwidthMeter
) : AdaptiveTrackSelection(group, tracks, bandwidthMeter) {

    /** Keep everything we have already buffered. */
    override fun evaluateQueueSize(
        playbackPositionUs: Long,
        queue: MutableList<out MediaChunk>
    ): Int = queue.size

    /**
     * Factory that produces KeepBuffer selections for video tracks and delegates
     * everything else to a standard AdaptiveTrackSelection.Factory (2.17.x API).
     */
    class Factory(
        private val minDurationForQualityIncreaseMs: Int = 10_000,
        private val maxDurationForQualityDecreaseMs: Int = 3_000,
        private val minDurationToRetainAfterDiscardMs: Int = 60_000, // large => don't discard
        private val bandwidthFraction: Float = 0.75f
    ) : ExoTrackSelection.Factory {

        private val delegate = AdaptiveTrackSelection.Factory(
            minDurationForQualityIncreaseMs,
            maxDurationForQualityDecreaseMs,
            minDurationToRetainAfterDiscardMs,
            bandwidthFraction
        )

        override fun createTrackSelections(
            definitions: Array<ExoTrackSelection.Definition?>,
            bandwidthMeter: BandwidthMeter
        ): Array<ExoTrackSelection?> {
            if (definitions.isEmpty()) return arrayOf()

            // Let the default factory create selections first.
            val base: Array<ExoTrackSelection?> =
                delegate.createTrackSelections(definitions, bandwidthMeter)

            // Replace VIDEO selections with our keep-buffer variant.
            for (i in definitions.indices) {
                val def = definitions[i] ?: continue
                val tracks = def.tracks
                if (tracks.isEmpty()) continue
                val fmt = def.group.getFormat(tracks[0])
                val mime = fmt.sampleMimeType ?: ""
                if (mime.startsWith("video")) {
                    base[i] = KeepBufferAdaptiveTrackSelection(def.group, tracks, bandwidthMeter)
                }
            }
            return base
        }
    }
}
