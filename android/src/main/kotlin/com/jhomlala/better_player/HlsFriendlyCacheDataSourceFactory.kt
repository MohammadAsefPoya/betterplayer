package com.jhomlala.better_player

import android.content.Context
import android.net.Uri
import android.util.Log
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.TransferListener
import com.google.android.exoplayer2.upstream.cache.CacheDataSink
import com.google.android.exoplayer2.upstream.cache.CacheDataSource
import com.google.android.exoplayer2.upstream.cache.Cache
import java.io.IOException

/**
 * Cache factory that **bypasses cache for any .m3u8** (master/variant) requests
 * and uses cache for everything else (segments, progressive media, etc).
 *
 * This prevents serving stale HLS playlists whose 'w...' ids expire and cause 404s.
 */
class HlsFriendlyCacheDataSourceFactory(
    context: Context,
    private val maxCacheSize: Long,
    private val maxCacheFileSize: Long,
    private val upstreamFactory: DataSource.Factory
) : DataSource.Factory {

    private val appContext = context.applicationContext
    private val TAG = "HlsCacheFactory"

    // Lazily build the cached + upstream chain we will delegate to.
    private val cache: Cache? by lazy { BetterPlayerCache.createCache(appContext, maxCacheSize) }

    // Exo's CacheDataSource is created lazily because it needs the cache instance.
    private val cachedFactory: CacheDataSource.Factory? by lazy {
        cache?.let { c ->
            CacheDataSource.Factory()
                .setCache(c)
                .setUpstreamDataSourceFactory(upstreamFactory)
                .setCacheWriteDataSinkFactory(
                    CacheDataSink.Factory()
                        .setCache(c)
                        .setFragmentSize(maxCacheFileSize)
                )
                // If cache ever misbehaves, don't poison playback:
                .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        }
    }

    override fun createDataSource(): DataSource {
        val upstreamOnly = upstreamFactory.createDataSource()
        val cached = cachedFactory?.createDataSource()

        return object : DataSource {
            private var chosen: DataSource? = null

            override fun addTransferListener(transferListener: TransferListener) {
                upstreamOnly.addTransferListener(transferListener)
                cached?.addTransferListener(transferListener)
            }

            @Throws(IOException::class)
            override fun open(dataSpec: DataSpec): Long {
                val uri: Uri = dataSpec.uri
                val path = (uri.path ?: "").lowercase()

                // --- CRITICAL RULE: never cache HLS playlist files (.m3u8) ---
                // This avoids stale 'w...' chunklist ids that 404 later.
                val isM3u8 = path.contains(".m3u8")

                chosen = if (isM3u8 || cached == null) {
                    upstreamOnly
                } else {
                    cached
                }

                if (isM3u8) {
                    // Optional: useful during debugging
                    Log.d(TAG, "Bypass cache for playlist: $uri")
                }

                return chosen!!.open(dataSpec)
            }

            @Throws(IOException::class)
            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                val c = chosen ?: upstreamOnly
                return c.read(buffer, offset, length)
            }

            override fun getUri(): Uri? {
                val c = chosen ?: upstreamOnly
                return c.uri
            }

            override fun getResponseHeaders(): Map<String, List<String>> {
                val c = chosen ?: upstreamOnly
                return c.responseHeaders
            }

            @Throws(IOException::class)
            override fun close() {
                try { upstreamOnly.close() } catch (_: Exception) {}
                try { cached?.close() } catch (_: Exception) {}
                chosen = null
            }
        }
    }
}
