package com.jhomlala.better_player

import com.google.android.exoplayer2.C
import com.google.android.exoplayer2.source.TrackGroup
import com.google.android.exoplayer2.source.chunk.MediaChunk
import com.google.android.exoplayer2.trackselection.AdaptiveTrackSelection
import com.google.android.exoplayer2.trackselection.TrackSelection
import com.google.android.exoplayer2.upstream.BandwidthMeter

/**
 * An AdaptiveTrackSelection that *never discards* already-buffered chunks when the
 * selected quality changes. It keeps the entire queue, so switches only take effect
 * after the buffered queue is consumed. This avoids visual stalls on bandwidth dips.
 */
internal class KeepBufferAdaptiveTrackSelection(
    group: TrackGroup,
    tracks: IntArray,
    @C.TrackType private val type: Int,
    bandwidthMeter: BandwidthMeter,
    minDurationForQualityIncreaseMs: Long,
    maxDurationForQualityDecreaseMs: Long,
    minDurationToRetainAfterDiscardMs: Long,
    bandwidthFraction: Float,
    bufferedFractionToLiveEdgeForQualityIncrease: Float
) : AdaptiveTrackSelection(
    group,
    tracks,
    type,
    bandwidthMeter,
    /* minDurationForQualityIncreaseMs = */ minDurationForQualityIncreaseMs,
    /* maxDurationForQualityDecreaseMs = */ maxDurationForQualityDecreaseMs,
    /* minDurationToRetainAfterDiscardMs = */ minDurationToRetainAfterDiscardMs,
    /* bandwidthFraction = */ bandwidthFraction,
    /* bufferedFractionToLiveEdgeForQualityIncrease = */ bufferedFractionToLiveEdgeForQualityIncrease
) {

    /**
     * Critical override: keep the entire queue to avoid discarding already-buffered
     * media for track switches. This means the new quality takes effect only after
     * existing buffered chunks have been played.
     */
    override fun evaluateQueueSize(playbackPositionUs: Long, queue: MutableList<out MediaChunk>): Int {
        return queue.size // keep everything we have already buffered
    }

    /**
     * Factory that creates KeepBufferAdaptiveTrackSelection for VIDEO, delegating the
     * rest to a standard Adaptive factory.
     */
    class Factory(
        private val minDurationForQualityIncreaseMs: Long = 10_000L,
        private val maxDurationForQualityDecreaseMs: Long = 3_000L,
        private val minDurationToRetainAfterDiscardMs: Long = 60_000L, // large => no discard
        private val bandwidthFraction: Float = 0.75f,
        private val bufferedFractionToLiveEdgeForQualityIncrease: Float = 0.75f
    ) : TrackSelection.Factory {

        private val delegate = AdaptiveTrackSelection.Factory(
            minDurationForQualityIncreaseMs,
            maxDurationForQualityDecreaseMs,
            minDurationToRetainAfterDiscardMs,
            bandwidthFraction
        )

        override fun createTrackSelections(
            definitions: Array<out TrackSelection.Definition>?,
            bandwidthMeter: BandwidthMeter
        ): Array<TrackSelection?> {
            if (definitions == null || definitions.isEmpty()) {
                return arrayOf()
            }
            // First let the standard factory create all selections.
            val base = delegate.createTrackSelections(definitions, bandwidthMeter)
            // Replace VIDEO selections with our "keep-buffer" variant.
            for (i in definitions.indices) {
                val def = definitions[i] ?: continue
                if (def.type == C.TRACK_TYPE_VIDEO && def.tracks.isNotEmpty()) {
                    base[i] = KeepBufferAdaptiveTrackSelection(
                        def.group,
                        def.tracks,
                        def.type,
                        bandwidthMeter,
                        minDurationForQualityIncreaseMs,
                        maxDurationForQualityDecreaseMs,
                        minDurationToRetainAfterDiscardMs,
                        bandwidthFraction,
                        bufferedFractionToLiveEdgeForQualityIncrease
                    )
                }
            }
            return base
        }
    }
}
