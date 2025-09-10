package com.jhomlala.better_player

import com.google.android.exoplayer2.drm.ExoMediaDrm
import com.google.android.exoplayer2.drm.MediaDrmCallback
import java.util.UUID

/**
 * Minimal local ClearKey callback for ExoPlayer versions that don't ship
 * com.google.android.exoplayer2.drm.LocalMediaDrmCallback.
 *
 * Pass the ClearKey JSON (as bytes) to the constructor. ExoPlayer will call
 * executeKeyRequest() and receive those bytes as the "license" response.
 *
 * Example ClearKey JSON shape ExoPlayer expects:
 * {
 *   "keys":[{"kty":"oct","k":"<base64Key>","kid":"<base64KeyId>"}],
 *   "type":"temporary"
 * }
 */
internal class LocalMediaDrmCallback(
    private val responseBytes: ByteArray
) : MediaDrmCallback {

    override fun executeProvisionRequest(
        uuid: UUID,
        request: ExoMediaDrm.ProvisionRequest
    ): ByteArray {
        // ClearKey normally doesn't require provisioning; return empty body.
        return ByteArray(0)
    }

    override fun executeKeyRequest(
        uuid: UUID,
        request: ExoMediaDrm.KeyRequest
    ): ByteArray {
        // Just return the ClearKey JSON bytes provided by the app.
        return responseBytes
    }
}
