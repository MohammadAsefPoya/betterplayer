package com.jhomlala.better_player

import android.content.Context
import android.util.Log
import com.google.android.exoplayer2.C
import com.google.android.exoplayer2.database.ExoDatabaseProvider
import com.google.android.exoplayer2.upstream.cache.Cache
import com.google.android.exoplayer2.upstream.cache.CacheSpan
import com.google.android.exoplayer2.upstream.cache.LeastRecentlyUsedCacheEvictor
import com.google.android.exoplayer2.upstream.cache.SimpleCache
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.lang.Exception
import java.util.concurrent.ConcurrentHashMap

object BetterPlayerCache {
    @Volatile
    private var instance: SimpleCache? = null

    // Keep listeners per cache key so we can remove/replace them cleanly
    private val listeners = ConcurrentHashMap<String, Cache.Listener>()

    fun createCache(context: Context, cacheFileSize: Long): SimpleCache? {
        if (instance == null) {
            synchronized(BetterPlayerCache::class.java) {
                if (instance == null) {
                    instance = SimpleCache(
                        File(context.cacheDir, "betterPlayerCache"),
                        LeastRecentlyUsedCacheEvictor(cacheFileSize),
                        ExoDatabaseProvider(context)
                    )
                }
            }
        }
        return instance
    }

    @JvmStatic
    fun releaseCache() {
        try {
            removeAllCacheListeners()
            if (instance != null) {
                instance!!.release()
                instance = null
            }
        } catch (exception: Exception) {
            Log.e("BetterPlayerCache", exception.toString())
        }
    }

    /**
     * Attach a cache listener for a single cache key (best for progressive content where the key is a single file).
     * Emits {"event":"cacheUpdate","cachedBytes":X,"totalBytes":Y,"percentCached":Z}
     */
    fun addCacheListener(cacheKey: String, eventSink: EventChannel.EventSink) {
        val cache = instance ?: return
        // If a listener for this key already exists, remove it
        listeners[cacheKey]?.let { cache.removeListener(cacheKey, it) }

        val listener = object : Cache.Listener {
            override fun onSpanAdded(cache: Cache, span: CacheSpan) {
                sendCacheUpdate(cacheKey, eventSink)
            }

            override fun onSpanRemoved(cache: Cache, span: CacheSpan) {
                sendCacheUpdate(cacheKey, eventSink)
            }

            override fun onSpanTouched(cache: Cache, oldSpan: CacheSpan, newSpan: CacheSpan) {
                sendCacheUpdate(cacheKey, eventSink)
            }
        }
        listeners[cacheKey] = listener
        cache.addListener(cacheKey, listener)

        // Push an initial snapshot immediately
        sendCacheUpdate(cacheKey, eventSink)
    }

    fun removeCacheListener(cacheKey: String) {
        val cache = instance ?: return
        listeners.remove(cacheKey)?.let { listener ->
            cache.removeListener(cacheKey, listener)
        }
    }

    fun removeAllCacheListeners() {
        val cache = instance ?: return
        for ((key, listener) in listeners.entries) {
            cache.removeListener(key, listener)
        }
        listeners.clear()
    }

    /**
     * Get total cached bytes for all entries whose cache key starts with the given prefix.
     * Useful for HLS/DASH where each segment is cached under its own absolute segment URL.
     */
    fun getCachedBytesForPrefix(prefix: String): Long {
        val cache = instance ?: return 0L
        var sum = 0L
        try {
            // Cache.getKeys() returns all keys currently present.
            for (key in cache.keys) {
                if (key.startsWith(prefix)) {
                    sum += cache.getCachedBytes(key, 0, C.LENGTH_UNSET)
                }
            }
        } catch (e: Exception) {
            Log.e("BetterPlayerCache", "Error aggregating cached bytes: ${e.message}")
        }
        return sum
    }

    private fun sendCacheUpdate(cacheKey: String, eventSink: EventChannel.EventSink) {
        val cache = instance ?: return
        try {
            val cachedBytes = cache.getCachedBytes(cacheKey, 0, C.LENGTH_UNSET)
            val totalBytes = cache.getContentLength(cacheKey) // -1 if unknown
            val percent = if (totalBytes > 0) (cachedBytes * 100 / totalBytes) else -1

            val event: MutableMap<String, Any> = HashMap()
            event["event"] = "cacheUpdate"
            event["cachedBytes"] = cachedBytes
            event["totalBytes"] = totalBytes
            event["percentCached"] = percent
            event["source"] = "cacheKeyListener"
            eventSink.success(event)
        } catch (e: Exception) {
            Log.e("BetterPlayerCache", "Cache listener error: ${e.message}")
        }
    }
}
