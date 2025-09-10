package com.jhomlala.better_player

import android.net.Uri
import android.util.Log
import com.google.android.exoplayer2.C
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.TransferListener
import java.io.IOException

/**
 * For HLS, we bypass caching the playlist (.m3u8) requests. For media chunks (TS/MP4) and
 * progressive content, we use the normal CacheDataSourceFactory.
 *
 * This wrapper uses your existing [CacheDataSourceFactory] class from the repo.
 */
internal class HlsFriendlyCacheDataSourceFactory(
    private val context: android.content.Context,
    private val maxCacheSize: Long,
    private val maxCacheFileSize: Long,
    private val upstreamFactory: DataSource.Factory
) : DataSource.Factory {

    override fun createDataSource(): DataSource {
        return object : DataSource {
            private var ds: DataSource? = null
            private var listener: TransferListener? = null

            override fun addTransferListener(transferListener: TransferListener) {
                listener = transferListener
            }

            @Throws(IOException::class)
            override fun open(dataSpec: DataSpec): Long {
                val uriString = dataSpec.uri.toString().lowercase()
                ds = if (uriString.contains(".m3u8")) {
                    // Playlist -> never cached to avoid CDN 404s on variant switches
                    upstreamFactory.createDataSource()
                } else {
                    // Chunks / progressive -> cached
                    CacheDataSourceFactory(
                        context,
                        maxCacheSize,
                        maxCacheFileSize,
                        upstreamFactory
                    ).createDataSource()
                }
                listener?.let { ds?.addTransferListener(it) }
                return ds!!.open(dataSpec)
            }

            override fun read(buffer: ByteArray, offset: Int, readLength: Int): Int {
                return ds?.read(buffer, offset, readLength) ?: C.RESULT_END_OF_INPUT
            }

            override fun getUri(): Uri? = ds?.uri

            override fun close() {
                try { ds?.close() } catch (_: Exception) {}
                ds = null
            }
        }
    }
}
