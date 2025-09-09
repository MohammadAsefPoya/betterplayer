package com.jhomlala.better_player

import android.net.Uri
import android.util.Log
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.TransferListener
import java.io.IOException

/**
 * A DataSource that tries [primary] first and, if opening fails with an IOException,
 * retries the same request with [secondary]. This is useful for HLS/CDNs that behave
 * differently depending on the HTTP stack (DefaultHttp vs OkHttp).
 */
class FallbackHttpDataSourceFactory(
    private val primary: DataSource.Factory,
    private val secondary: DataSource.Factory
) : DataSource.Factory {
    override fun createDataSource(): DataSource {
        return FallbackHttpDataSource(
            primary = primary.createDataSource(),
            secondary = secondary.createDataSource()
        )
    }
}

private const val FB_TAG = "BetterPlayer-FallbackDS"

private class FallbackHttpDataSource(
    private val primary: DataSource,
    private val secondary: DataSource
) : DataSource {

    private var chosen: DataSource? = null

    override fun addTransferListener(transferListener: TransferListener) {
        // Register on both; only the chosen will be actively used after open().
        primary.addTransferListener(transferListener)
        secondary.addTransferListener(transferListener)
    }

    @Throws(IOException::class)
    override fun open(dataSpec: DataSpec): Long {
        // Try primary
        try {
            val length = primary.open(dataSpec)
            chosen = primary
            return length
        } catch (e: IOException) {
            Log.w(FB_TAG, "Primary DS failed (${e.javaClass.simpleName}); switching to secondary")
            // best-effort close in case it partially opened
            try { primary.close() } catch (_: Exception) {}
        }
        // Try secondary
        val length = secondary.open(dataSpec)
        chosen = secondary
        return length
    }

    @Throws(IOException::class)
    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        val c = chosen ?: primary
        return c.read(buffer, offset, length)
    }

    override fun getUri(): Uri? {
        val c = chosen ?: primary
        return c.uri
    }

    override fun getResponseHeaders(): Map<String, List<String>> {
        val c = chosen ?: primary
        return c.responseHeaders
    }

    @Throws(IOException::class)
    override fun close() {
        try { primary.close() } catch (_: Exception) {}
        try { secondary.close() } catch (_: Exception) {}
        chosen = null
    }
}
