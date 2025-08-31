package com.jhomlala.better_player

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.Surface
import androidx.lifecycle.Observer
import androidx.work.Data
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.google.android.exoplayer2.C
import com.google.android.exoplayer2.DefaultLoadControl
import com.google.android.exoplayer2.ExoPlayer
import com.google.android.exoplayer2.LoadControl
import com.google.android.exoplayer2.MediaItem
import com.google.android.exoplayer2.PlaybackException
import com.google.android.exoplayer2.PlaybackParameters
import com.google.android.exoplayer2.Player
import com.google.android.exoplayer2.SeekParameters
import com.google.android.exoplayer2.Timeline
import com.google.android.exoplayer2.analytics.AnalyticsListener
import com.google.android.exoplayer2.audio.AudioAttributes
import com.google.android.exoplayer2.drm.DefaultDrmSessionManager
import com.google.android.exoplayer2.drm.DrmSessionManager
import com.google.android.exoplayer2.drm.DrmSessionManagerProvider
import com.google.android.exoplayer2.drm.DummyExoMediaDrm
import com.google.android.exoplayer2.drm.FrameworkMediaDrm
import com.google.android.exoplayer2.drm.HttpMediaDrmCallback
import com.google.android.exoplayer2.drm.LocalMediaDrmCallback
import com.google.android.exoplayer2.drm.UnsupportedDrmException
import com.google.android.exoplayer2.ext.mediasession.MediaSessionConnector
import com.google.android.exoplayer2.ext.okhttp.OkHttpDataSource
import com.google.android.exoplayer2.extractor.DefaultExtractorsFactory
import com.google.android.exoplayer2.source.ClippingMediaSource
import com.google.android.exoplayer2.source.LoadEventInfo
import com.google.android.exoplayer2.source.MediaLoadData
import com.google.android.exoplayer2.source.MediaSource
import com.google.android.exoplayer2.source.ProgressiveMediaSource
import com.google.android.exoplayer2.source.dash.DashMediaSource
import com.google.android.exoplayer2.source.dash.DefaultDashChunkSource
import com.google.android.exoplayer2.source.hls.HlsMediaSource
import com.google.android.exoplayer2.source.smoothstreaming.DefaultSsChunkSource
import com.google.android.exoplayer2.source.smoothstreaming.SsMediaSource
import com.google.android.exoplayer2.trackselection.DefaultTrackSelector
import com.google.android.exoplayer2.trackselection.ExoTrackSelection
import com.google.android.exoplayer2.trackselection.TrackSelectionOverrides
import com.google.android.exoplayer2.ui.PlayerNotificationManager
import com.google.android.exoplayer2.ui.PlayerNotificationManager.BitmapCallback
import com.google.android.exoplayer2.ui.PlayerNotificationManager.MediaDescriptionAdapter
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.DefaultDataSource
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource
import com.google.android.exoplayer2.upstream.cache.Cache
import com.google.android.exoplayer2.upstream.cache.CacheDataSink
import com.google.android.exoplayer2.upstream.cache.CacheKeyFactory
import com.google.android.exoplayer2.upstream.cache.ContentMetadata
import com.google.android.exoplayer2.upstream.cache.SimpleCache
import com.google.android.exoplayer2.util.UriUtil
import com.google.android.exoplayer2.util.Util
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry.SurfaceTextureEntry
import okhttp3.ConnectionPool
import okhttp3.OkHttpClient
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import java.io.File
import java.io.IOException
import java.lang.Exception
import java.lang.IllegalStateException
import java.util.UUID
import java.util.concurrent.TimeUnit
import kotlin.math.max
import kotlin.math.min

internal class BetterPlayer(
    context: Context,
    private val eventChannel: EventChannel,
    private val textureEntry: SurfaceTextureEntry,
    customDefaultLoadControl: CustomDefaultLoadControl?,
    result: MethodChannel.Result
) {
    // --- player core ---
    private var exoPlayer: ExoPlayer? = null
    private val eventSink = QueuingEventSink()
    private var trackSelector: DefaultTrackSelector
    private val loadControl: LoadControl

    // --- state & plumbing ---
    private var isInitialized = false
    private var surface: Surface? = null
    private var key: String? = null
    private var useCacheEnabledForThisSource = false
    private var playerNotificationManager: PlayerNotificationManager? = null
    private var refreshHandler: Handler? = null
    private var refreshRunnable: Runnable? = null
    private var exoPlayerEventListener: Player.Listener? = null
    private var bitmap: Bitmap? = null
    private var mediaSession: MediaSessionCompat? = null
    private var drmSessionManager: DrmSessionManager? = null
    private val workManager: WorkManager
    private val workerObserverMap: HashMap<UUID, Observer<WorkInfo?>>
    private val customDefaultLoadControl: CustomDefaultLoadControl =
        customDefaultLoadControl ?: CustomDefaultLoadControl()
    private var lastSendBufferedPosition = 0L

    // ABR helpers
    private var lastBandwidthEstimateBps: Long = -1
    private var recentLoadErrors: Int = 0
    private var errorWindowStartMs: Long = 0
    private val errorWindowMs = 8_000L
    private val errorThreshold = 2
    private val floorCapWhenErrorsBps = 600_000

    // cap lift
    private var capLiftHandler: Handler? = null

    // app context & cache
    private val appContext: Context = context.applicationContext

    // periodic cache ticker
    private var offlineTicker: Handler? = null
    private val offlineRunnable = object : Runnable {
        override fun run() {
            val p = exoPlayer ?: return
            val current = p.currentPosition
            val buffered = p.bufferedPosition
            val ramAheadMs = kotlin.math.max(0L, buffered - current)
            val playableMs = computePlayableOfflineMs()
            val diskAheadMs = kotlin.math.max(0L, playableMs - ramAheadMs)

            Log.d(TAG, "cacheUpdate(playable) playable=$playableMs ram=$ramAheadMs disk=$diskAheadMs")

            val event = HashMap<String, Any>()
            event["event"] = "cacheUpdate"
            event["playableOfflineMs"] = playableMs
            event["ramAheadMs"] = ramAheadMs
            event["diskAheadMs"] = diskAheadMs
            event["currentPositionMs"] = current
            event["bufferedPositionMs"] = buffered
            eventSink.success(event)

            offlineTicker?.postDelayed(this, 1000L)
        }
    }

    private fun resetErrorWindowIfNeeded(now: Long) {
        if (now - errorWindowStartMs > errorWindowMs) {
            errorWindowStartMs = now
            recentLoadErrors = 0
        }
    }

    init {
        // --- LoadControl: prefer time thresholds; no target byte cap.
        val loadBuilder = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                this.customDefaultLoadControl.minBufferMs,
                this.customDefaultLoadControl.maxBufferMs,
                this.customDefaultLoadControl.bufferForPlaybackMs,
                this.customDefaultLoadControl.bufferForPlaybackAfterRebufferMs
            )
            .setTargetBufferBytes(C.LENGTH_UNSET)      // no hard byte cap
            .setPrioritizeTimeOverSizeThresholds(true) // time-based buffering behavior
        loadControl = loadBuilder.build()

        // --- TrackSelector with KEEP-BUFFER ABR policy for VIDEO (Exo 2.17 API)
        val keepBufferFactory: ExoTrackSelection.Factory =
            KeepBufferAdaptiveTrackSelection.Factory(
                /* minDurationForQualityIncreaseMs = */ 10_000,
                /* maxDurationForQualityDecreaseMs = */ 3_000,
                /* minDurationToRetainAfterDiscardMs = */ 60_000,
                /* bandwidthFraction = */ 0.75f
            )

        trackSelector = DefaultTrackSelector(context, keepBufferFactory)

        // --- ExoPlayer
        exoPlayer = ExoPlayer.Builder(context)
            .setTrackSelector(trackSelector)
            .setLoadControl(loadControl)
            .build()

        exoPlayer?.setSeekParameters(SeekParameters.CLOSEST_SYNC)

        // --- WorkManager
        workManager = WorkManager.getInstance(context)
        workerObserverMap = HashMap()

        // --- Flutter plumbing
        setupVideoPlayer(eventChannel, textureEntry, result)

        // --- Analytics
        exoPlayer?.addAnalyticsListener(object : AnalyticsListener {
            override fun onVideoSizeChanged(
                eventTime: AnalyticsListener.EventTime,
                videoSize: com.google.android.exoplayer2.video.VideoSize
            ) {
                val event: MutableMap<String, Any> = HashMap()
                event["event"] = "videoSizeChanged"
                event["width"] = videoSize.width
                event["height"] = videoSize.height
                eventSink.success(event)
            }

            override fun onBandwidthEstimate(
                eventTime: AnalyticsListener.EventTime,
                totalLoadTimeMs: Int,
                totalBytesLoaded: Long,
                bitrateEstimate: Long
            ) {
                lastBandwidthEstimateBps = bitrateEstimate
                // Apply a temporary cap to stabilize; KEEP-BUFFER ensures no discards.
                if (bitrateEstimate > 0 && bitrateEstimate < 1_200_000) {
                    val safeCap = (bitrateEstimate * 7 / 10).toInt().coerceAtLeast(300_000)
                    applyBitrateCap(safeCap)
                    scheduleCapLift() // lift shortly after recovery
                }
            }

            override fun onLoadError(
                eventTime: AnalyticsListener.EventTime,
                loadEventInfo: LoadEventInfo,
                mediaLoadData: MediaLoadData,
                error: IOException,
                wasCanceled: Boolean
            ) {
                val now = SystemClock.elapsedRealtime()
                resetErrorWindowIfNeeded(now)
                recentLoadErrors++
                if (recentLoadErrors >= errorThreshold) {
                    applyBitrateCap(floorCapWhenErrorsBps)
                    capLiftHandler?.removeCallbacksAndMessages(null)
                    capLiftHandler = Handler(Looper.getMainLooper())
                    capLiftHandler?.postDelayed({ liftBitrateCap() }, 5_000L)
                }
            }
        })
    }

    // ---------------- Cache helpers (RAM + Disk “playable without network”) ----------------

    private fun playerCache(): Cache? {
        if (!useCacheEnabledForThisSource) return null
        // Return as Cache? (SimpleCache implements Cache)
        return BetterPlayerCache.createCache(appContext, 1L) as Cache?
    }

    private fun computePlayableOfflineMs(): Long {
        val p = exoPlayer ?: return 0L
        val ramAheadMs = kotlin.math.max(0L, (p.bufferedPosition - p.currentPosition))

        val cache = playerCache() ?: return ramAheadMs
        val item = p.currentMediaItem ?: return ramAheadMs
        val uri = item.localConfiguration?.uri ?: return ramAheadMs
        val type = Util.inferContentType(uri)

        val diskAheadMs = when (type) {
            C.TYPE_OTHER -> diskAheadProgressiveMs(cache, item, p)
            C.TYPE_HLS   -> diskAheadHlsMs(cache, p)
            else         -> 0L
        }
        return ramAheadMs + kotlin.math.max(0L, diskAheadMs)
    }

    private fun applyBitrateCap(capBps: Int) {
        val cap = capBps.coerceAtLeast(128_000)
        val newParams = trackSelector.parameters.buildUpon()
            .setForceHighestSupportedBitrate(false)
            .setMaxVideoBitrate(cap)
            .build()
        trackSelector.parameters = newParams
        Log.d(TAG, "ABR cap applied: $cap Bps")
    }

    private fun liftBitrateCap() {
        val newParams = trackSelector.parameters.buildUpon()
            .setMaxVideoBitrate(Int.MAX_VALUE)
            .build()
        trackSelector.parameters = newParams
        Log.d(TAG, "ABR cap lifted")
    }

    private fun scheduleCapLift(delayMs: Long = 2_500L) {
        capLiftHandler?.removeCallbacksAndMessages(null)
        capLiftHandler = Handler(Looper.getMainLooper())
        capLiftHandler?.postDelayed({ liftBitrateCap() }, delayMs)
    }

    // Progressive: map cached bytes ahead to time.
    private fun diskAheadProgressiveMs(cache: Cache, item: MediaItem, p: ExoPlayer): Long {
        val durationMs = p.duration.takeIf { it > 0 } ?: return 0L
        val mc = item.localConfiguration ?: return 0L
        val dataSpec = DataSpec(mc.uri)
        val key = mc.customCacheKey ?: CacheKeyFactory.DEFAULT.buildCacheKey(dataSpec)

        val meta = cache.getContentMetadata(key)
        val contentLength = ContentMetadata.getContentLength(meta) // C.LENGTH_UNSET if unknown
        val currentMs = p.currentPosition

        if (contentLength > 0L) {
            val startByte = ((contentLength * currentMs) / durationMs)
                .coerceAtLeast(0L).coerceAtMost(contentLength - 1)
            var pos = startByte
            var aheadBytes = 0L
            while (true) {
                val len = cache.getCachedLength(key, pos, Long.MAX_VALUE)
                if (len <= 0) break // hole
                aheadBytes += len
                pos += len
            }
            return (aheadBytes * durationMs / contentLength)
        } else {
            // Fallback via bitrate if content length unknown
            val bitrateBps = (p.videoFormat?.bitrate ?: 0).toLong()
            if (bitrateBps <= 0) return 0L
            val startByte = (((bitrateBps / 8.0) * (currentMs / 1000.0))).toLong().coerceAtLeast(0L)
            var pos = startByte
            var aheadBytes = 0L
            while (true) {
                val len = cache.getCachedLength(key, pos, Long.MAX_VALUE)
                if (len <= 0) break
                aheadBytes += len
                pos += len
            }
            return ((aheadBytes * 8_000L) / bitrateBps) // ms
        }
    }

    // HLS: sum durations of fully cached segments strictly AFTER current one (reflection).
    private fun diskAheadHlsMs(cache: Cache, p: ExoPlayer): Long {
        val any = p.currentManifest ?: return 0L
        try {
            val playlistObj = any.javaClass.getField("mediaPlaylist").get(any) ?: return 0L
            val baseUri = playlistObj.javaClass.getField("baseUri").get(playlistObj) as? String ?: return 0L
            val startTimeUs = playlistObj.javaClass.getField("startTimeUs").getLong(playlistObj)
            @Suppress("UNCHECKED_CAST")
            val segments = playlistObj.javaClass.getField("segments").get(playlistObj) as? List<Any?> ?: return 0L

            val nowUs = p.currentPosition * 1000L
            val relUs = nowUs - startTimeUs

            var idx = -1
            for (i in segments.indices) {
                val seg = segments[i] ?: continue
                val segStartUs = seg.javaClass.getField("relativeStartTimeUs").getLong(seg)
                val segDurUs = seg.javaClass.getField("durationUs").getLong(seg)
                val segEndUs = segStartUs + segDurUs
                if (relUs >= segStartUs && relUs < segEndUs) { idx = i; break }
            }
            if (idx < 0) return 0L

            var accUs = 0L
            for (j in (idx + 1) until segments.size) {
                val seg = segments[j] ?: continue
                val url = seg.javaClass.getField("url").get(seg) as? String ?: continue
                val resolved = UriUtil.resolveToUri(baseUri, url)
                val key = CacheKeyFactory.DEFAULT.buildCacheKey(DataSpec(resolved))
                val fullyCached = cache.isCached(key, 0L, Long.MAX_VALUE)
                if (!fullyCached) break
                val durUs = seg.javaClass.getField("durationUs").getLong(seg)
                accUs += durUs
            }
            return accUs / 1000L
        } catch (e: Exception) {
            Log.w(TAG, "diskAheadHlsMs reflection failed: $e")
            return 0L
        }
    }

    private fun startOfflineTicker() {
        stopOfflineTicker()
        offlineTicker = Handler(Looper.getMainLooper())
        offlineTicker?.post(offlineRunnable)
    }

    private fun stopOfflineTicker() {
        offlineTicker?.removeCallbacksAndMessages(null)
        offlineTicker = null
    }

    fun setDataSource(
        context: Context,
        key: String?,
        dataSource: String?,
        formatHint: String?,
        result: MethodChannel.Result,
        headers: Map<String, String>?,
        useCache: Boolean,
        maxCacheSize: Long,
        maxCacheFileSize: Long,
        overriddenDuration: Long,
        licenseUrl: String?,
        drmHeaders: Map<String, String>?,
        cacheKey: String?,
        clearKey: String?
    ) {
        this.key = key
        isInitialized = false
        useCacheEnabledForThisSource = useCache
        val uri = Uri.parse(dataSource)
        val userAgent = DataSourceUtils.getUserAgent(headers)

        // --- shared OkHttp client
        val okClient = OkHttpClient.Builder()
            .connectionPool(ConnectionPool(8, 60, TimeUnit.SECONDS))
            .retryOnConnectionFailure(true)
            .followRedirects(true)
            .followSslRedirects(true)
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .writeTimeout(15, TimeUnit.SECONDS)
            .build()

        // --- DRM
        drmSessionManager = null
        if (!licenseUrl.isNullOrEmpty()) {
            val drmFactory = OkHttpDataSource.Factory(okClient).setUserAgent(userAgent)
            val drmCallback = HttpMediaDrmCallback(licenseUrl, drmFactory)
            drmHeaders?.forEach { (k, v) -> drmCallback.setKeyRequestProperty(k, v) }
            if (Util.SDK_INT >= 18) {
                val drmUuid = Util.getDrmUuid("widevine")
                if (drmUuid != null) {
                    drmSessionManager = DefaultDrmSessionManager.Builder()
                        .setUuidAndExoMediaDrmProvider(drmUuid) { uuid ->
                            try {
                                val md = FrameworkMediaDrm.newInstance(uuid!!)
                                md.setPropertyString("securityLevel", "L3")
                                md
                            } catch (_: UnsupportedDrmException) {
                                DummyExoMediaDrm()
                            }
                        }
                        .setMultiSession(false)
                        .build(drmCallback)
                }
            } else {
                Log.e(TAG, "Protected content not supported on API < 18")
            }
        } else if (!clearKey.isNullOrEmpty()) {
            drmSessionManager =
                if (Util.SDK_INT < 18) {
                    Log.e(TAG, "Protected content not supported on API < 18")
                    null
                } else {
                    DefaultDrmSessionManager.Builder()
                        .setUuidAndExoMediaDrmProvider(C.CLEARKEY_UUID, FrameworkMediaDrm.DEFAULT_PROVIDER)
                        .build(LocalMediaDrmCallback(clearKey.toByteArray()))
                }
        }

        // --- DataSource with caching (stable keys)
        val mediaDataSourceFactory: DataSource.Factory = if (DataSourceUtils.isHTTP(uri)) {
            var upstream: DataSource.Factory =
                OkHttpDataSource.Factory(okClient).setUserAgent(userAgent).let { f ->
                    if (!headers.isNullOrEmpty()) f.setDefaultRequestProperties(headers) else f
                }

            if (useCache && maxCacheSize > 0 && maxCacheFileSize > 0) {
                val cache: SimpleCache? = BetterPlayerCache.createCache(appContext, maxCacheSize)

                // Drop volatile query params so refreshed tokens still hit cache.
                val stableKeyFactory = CacheKeyFactory { ds ->
                    val base = ds.key ?: ds.uri.toString()
                    try {
                        val u = Uri.parse(base)
                        u.buildUpon().clearQuery().build().toString()
                    } catch (_: Exception) {
                        base
                    }
                }

                val cacheFactory = com.google.android.exoplayer2.upstream.cache.CacheDataSource.Factory()
                    .setCache(cache)
                    .setUpstreamDataSourceFactory(upstream)
                    .setCacheWriteDataSinkFactory(
                        CacheDataSink.Factory()
                            .setCache(cache)
                            .setFragmentSize(maxCacheFileSize)
                    )
                    .setCacheKeyFactory(stableKeyFactory)
                    .setFlags(com.google.android.exoplayer2.upstream.cache.CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)

                upstream = cacheFactory
            }
            upstream
        } else {
            DefaultDataSource.Factory(context)
        }

        // --- MediaSource
        val mediaSource = buildMediaSource(uri, mediaDataSourceFactory, formatHint, cacheKey, context)
        if (overriddenDuration != 0L) {
            exoPlayer?.setMediaSource(ClippingMediaSource(mediaSource, 0, overriddenDuration * 1000))
        } else {
            exoPlayer?.setMediaSource(mediaSource)
        }
        exoPlayer?.prepare()

        // Small initial cap to reduce startup stalls; KEEP-BUFFER selection avoids discards
        applyBitrateCap(1_200_000)
        scheduleCapLift()

        startOfflineTicker()
        result.success(null)
    }

    fun setupPlayerNotification(
        context: Context,
        title: String,
        author: String?,
        imageUrl: String?,
        notificationChannelName: String?,
        activityName: String
    ) {
        val mediaDescriptionAdapter: MediaDescriptionAdapter = object : MediaDescriptionAdapter {
            override fun getCurrentContentTitle(player: Player): String = title

            @SuppressLint("UnspecifiedImmutableFlag")
            override fun createCurrentContentIntent(player: Player): PendingIntent? {
                val packageName = context.applicationContext.packageName
                val notificationIntent = Intent().apply {
                    setClassName(packageName, "$packageName.$activityName")
                    flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
                }
                return PendingIntent.getActivity(
                    context, 0, notificationIntent, PendingIntent.FLAG_IMMUTABLE
                )
            }

            override fun getCurrentContentText(player: Player): String? = author

            override fun getCurrentLargeIcon(player: Player, callback: BitmapCallback): Bitmap? {
                if (imageUrl == null) return null
                if (bitmap != null) return bitmap

                val imageWorkRequest = OneTimeWorkRequest.Builder(ImageWorker::class.java)
                    .addTag(imageUrl)
                    .setInputData(Data.Builder().putString(BetterPlayerPlugin.URL_PARAMETER, imageUrl).build())
                    .build()

                workManager.enqueue(imageWorkRequest)

                val workInfoObserver = Observer { workInfo: WorkInfo? ->
                    try {
                        if (workInfo != null) {
                            val state = workInfo.state
                            if (state == WorkInfo.State.SUCCEEDED) {
                                val outputData = workInfo.outputData
                                val filePath = outputData.getString(BetterPlayerPlugin.FILE_PATH_PARAMETER)
                                bitmap = BitmapFactory.decodeFile(filePath)
                                bitmap?.let { bmp -> callback.onBitmap(bmp) }
                            }
                            if (state == WorkInfo.State.SUCCEEDED ||
                                state == WorkInfo.State.CANCELLED ||
                                state == WorkInfo.State.FAILED
                            ) {
                                val uuid = imageWorkRequest.id
                                workerObserverMap.remove(uuid)?.let { observer ->
                                    workManager.getWorkInfoByIdLiveData(uuid).removeObserver(observer)
                                }
                            }
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Image select error: $e")
                    }
                }

                val workerUuid = imageWorkRequest.id
                workManager.getWorkInfoByIdLiveData(workerUuid).observeForever(workInfoObserver)
                workerObserverMap[workerUuid] = workInfoObserver
                return null
            }
        }

        var playerNotificationChannelName = notificationChannelName
        if (playerNotificationChannelName == null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val importance = NotificationManager.IMPORTANCE_LOW
            val channel = NotificationChannel(
                DEFAULT_NOTIFICATION_CHANNEL,
                DEFAULT_NOTIFICATION_CHANNEL,
                importance
            ).apply { description = DEFAULT_NOTIFICATION_CHANNEL }

            val notificationManager = context.getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
            playerNotificationChannelName = DEFAULT_NOTIFICATION_CHANNEL
        }

        playerNotificationManager = PlayerNotificationManager.Builder(
            context,
            NOTIFICATION_ID,
            playerNotificationChannelName!!
        ).setMediaDescriptionAdapter(mediaDescriptionAdapter).build()

        playerNotificationManager?.apply {
            exoPlayer?.let { exo ->
                setPlayer(com.google.android.exoplayer2.ForwardingPlayer(exo))
                setUseNextAction(false)
                setUsePreviousAction(false)
                setUseStopAction(false)
            }
            setupMediaSession(context)?.let { setMediaSessionToken(it.sessionToken) }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            refreshHandler = Handler(Looper.getMainLooper())
            refreshRunnable = Runnable {
                val playbackState: PlaybackStateCompat =
                    if (exoPlayer?.isPlaying == true) {
                        PlaybackStateCompat.Builder()
                            .setActions(PlaybackStateCompat.ACTION_SEEK_TO)
                            .setState(PlaybackStateCompat.STATE_PLAYING, position, 1.0f)
                            .build()
                    } else {
                        PlaybackStateCompat.Builder()
                            .setActions(PlaybackStateCompat.ACTION_SEEK_TO)
                            .setState(PlaybackStateCompat.STATE_PAUSED, position, 1.0f)
                            .build()
                    }
                mediaSession?.setPlaybackState(playbackState)
                refreshHandler?.postDelayed(refreshRunnable!!, 1000)
            }
            refreshHandler?.postDelayed(refreshRunnable!!, 0)
        }

        // ABR stabilization only (no Dart events here)
        exoPlayerEventListener = object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                mediaSession?.setMetadata(
                    MediaMetadataCompat.Builder()
                        .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, getDuration())
                        .build()
                )
                when (playbackState) {
                    Player.STATE_BUFFERING -> {
                        val fastCap = if (lastBandwidthEstimateBps > 0)
                            max(300_000, (lastBandwidthEstimateBps * 7 / 10).toInt())
                        else 900_000
                        applyBitrateCap(fastCap)
                    }
                    Player.STATE_READY -> {
                        scheduleCapLift()
                    }
                }
            }
        }
        exoPlayerEventListener?.let { exoPlayer?.addListener(it) }
        exoPlayer?.seekTo(0)
    }

    fun disposeRemoteNotifications() {
        exoPlayerEventListener?.let { exoPlayer?.removeListener(it) }
        refreshHandler?.removeCallbacksAndMessages(null)
        refreshHandler = null
        refreshRunnable = null
        playerNotificationManager?.setPlayer(null)
        bitmap = null
    }

    private fun buildMediaSource(
        uri: Uri,
        mediaDataSourceFactory: DataSource.Factory,
        formatHint: String?,
        cacheKey: String?,
        context: Context
    ): MediaSource {
        val type: Int = if (formatHint == null) {
            val lastPathSegment = uri.lastPathSegment ?: ""
            Util.inferContentType(lastPathSegment)
        } else {
            when (formatHint) {
                FORMAT_SS -> C.TYPE_SS
                FORMAT_DASH -> C.TYPE_DASH
                FORMAT_HLS -> C.TYPE_HLS
                FORMAT_OTHER -> C.TYPE_OTHER
                else -> -1
            }
        }

        val mediaItemBuilder = MediaItem.Builder().setUri(uri)
        if (!cacheKey.isNullOrEmpty()) {
            mediaItemBuilder.setCustomCacheKey(cacheKey)
        }
        val mediaItem = mediaItemBuilder.build()

        var drmSessionManagerProvider: DrmSessionManagerProvider? = null
        drmSessionManager?.let { dsm ->
            drmSessionManagerProvider = DrmSessionManagerProvider { dsm }
        }

        return when (type) {
            C.TYPE_SS -> SsMediaSource.Factory(
                DefaultSsChunkSource.Factory(mediaDataSourceFactory),
                DefaultDataSource.Factory(context, mediaDataSourceFactory)
            )
                .setDrmSessionManagerProvider(drmSessionManagerProvider)
                .createMediaSource(mediaItem)

            C.TYPE_DASH -> DashMediaSource.Factory(
                DefaultDashChunkSource.Factory(mediaDataSourceFactory),
                DefaultDataSource.Factory(context, mediaDataSourceFactory)
            )
                .setDrmSessionManagerProvider(drmSessionManagerProvider)
                .createMediaSource(mediaItem)

            C.TYPE_HLS -> HlsMediaSource.Factory(mediaDataSourceFactory)
                .setAllowChunklessPreparation(true)
                .setDrmSessionManagerProvider(drmSessionManagerProvider)
                .createMediaSource(mediaItem)

            C.TYPE_OTHER -> ProgressiveMediaSource.Factory(
                mediaDataSourceFactory,
                DefaultExtractorsFactory()
            )
                .setDrmSessionManagerProvider(drmSessionManagerProvider)
                .createMediaSource(mediaItem)

            else -> throw IllegalStateException("Unsupported type: $type")
        }
    }

    private fun setupVideoPlayer(
        eventChannel: EventChannel,
        textureEntry: SurfaceTextureEntry,
        result: MethodChannel.Result
    ) {
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(o: Any?, sink: EventSink) {
                eventSink.setDelegate(sink)
            }

            override fun onCancel(o: Any?) {
                eventSink.setDelegate(null)
            }
        })

        surface = Surface(textureEntry.surfaceTexture())
        exoPlayer?.setVideoSurface(surface)
        setAudioAttributes(exoPlayer, true)

        // Emit playback events to Dart
        exoPlayer?.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_BUFFERING -> {
                        sendBufferingUpdate(true)
                        val event: MutableMap<String, Any> = HashMap()
                        event["event"] = "bufferingStart"
                        eventSink.success(event)
                    }
                    Player.STATE_READY -> {
                        if (!isInitialized) {
                            isInitialized = true
                            sendInitialized()
                        }
                        val event: MutableMap<String, Any> = HashMap()
                        event["event"] = "bufferingEnd"
                        eventSink.success(event)
                    }
                    Player.STATE_ENDED -> {
                        val event: MutableMap<String, Any?> = HashMap()
                        event["event"] = "completed"
                        event["key"] = key
                        eventSink.success(event)
                    }
                    Player.STATE_IDLE -> { /* no-op */ }
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                eventSink.error("VideoError", "Video player had error $error", "")
            }
        })

        val reply: MutableMap<String, Any> = HashMap()
        reply["textureId"] = textureEntry.id()
        result.success(reply)
    }

    fun sendBufferingUpdate(isFromBufferingStart: Boolean) {
        val bufferedPosition = exoPlayer?.bufferedPosition ?: 0L
        if (isFromBufferingStart || bufferedPosition != lastSendBufferedPosition) {
            val event: MutableMap<String, Any> = HashMap()
            event["event"] = "bufferingUpdate"
            val range: List<Number?> = listOf(0, bufferedPosition)
            event["values"] = listOf(range)
            eventSink.success(event)
            lastSendBufferedPosition = bufferedPosition
        }
    }

    @Suppress("DEPRECATION")
    private fun setAudioAttributes(exoPlayer: ExoPlayer?, mixWithOthers: Boolean) {
        val audioComponent = exoPlayer?.audioComponent ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            audioComponent.setAudioAttributes(
                AudioAttributes.Builder().setContentType(C.CONTENT_TYPE_MOVIE).build(),
                !mixWithOthers
            )
        } else {
            audioComponent.setAudioAttributes(
                AudioAttributes.Builder().setContentType(C.CONTENT_TYPE_MUSIC).build(),
                !mixWithOthers
            )
        }
    }

    fun play() {
        exoPlayer?.playWhenReady = true
    }

    fun pause() {
        exoPlayer?.playWhenReady = false
    }

    fun setLooping(value: Boolean) {
        exoPlayer?.repeatMode = if (value) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
    }

    fun setVolume(value: Double) {
        val v = max(0.0, min(1.0, value)).toFloat()
        exoPlayer?.volume = v
    }

    fun setSpeed(value: Double) {
        val playbackParameters = PlaybackParameters(value.toFloat())
        exoPlayer?.playbackParameters = playbackParameters
    }

    fun setTrackParameters(width: Int, height: Int, bitrate: Int) {
        val b = trackSelector.buildUponParameters()
        if (width != 0 && height != 0) {
            b.setMaxVideoSize(width, height)
        }
        if (bitrate != 0) {
            b.setMaxVideoBitrate(bitrate)
        }
        if (width == 0 && height == 0 && bitrate == 0) {
            b.clearVideoSizeConstraints()
            b.setMaxVideoBitrate(Int.MAX_VALUE)
        }
        trackSelector.setParameters(b)
    }

    fun seekTo(location: Int) {
        applyBitrateCap(1_000_000)
        scheduleCapLift()
        exoPlayer?.seekTo(location.toLong())
    }

    val position: Long
        get() = exoPlayer?.currentPosition ?: 0L

    val absolutePosition: Long
        get() {
            val timeline = exoPlayer?.currentTimeline
            timeline?.let {
                if (!timeline.isEmpty) {
                    val windowStartTimeMs = timeline.getWindow(0, Timeline.Window()).windowStartTimeMs
                    val pos = exoPlayer?.currentPosition ?: 0L
                    return windowStartTimeMs + pos
                }
            }
            return exoPlayer?.currentPosition ?: 0L
        }

    private fun sendInitialized() {
        if (isInitialized) {
            val event: MutableMap<String, Any?> = HashMap()
            event["event"] = "initialized"
            event["key"] = key
            event["duration"] = getDuration()
            exoPlayer?.videoFormat?.let { vf ->
                var width = vf.width
                var height = vf.height
                val rotation = vf.rotationDegrees
                if (rotation == 90 || rotation == 270) {
                    width = vf.height
                    height = vf.width
                }
                event["width"] = width
                event["height"] = height
            }
            eventSink.success(event)
        }
    }

    private fun getDuration(): Long = exoPlayer?.duration ?: 0L

    @SuppressLint("InlinedApi")
    fun setupMediaSession(context: Context?): MediaSessionCompat? {
        mediaSession?.release()
        context ?: return null

        val mediaButtonIntent = Intent(Intent.ACTION_MEDIA_BUTTON)
        val pendingIntent = PendingIntent.getBroadcast(
            context, 0, mediaButtonIntent, PendingIntent.FLAG_IMMUTABLE
        )
        val mediaSession = MediaSessionCompat(context, TAG, null, pendingIntent)
        mediaSession.setCallback(object : MediaSessionCompat.Callback() {
            override fun onSeekTo(pos: Long) {
                sendSeekToEvent(pos)
                super.onSeekTo(pos)
            }
        })
        mediaSession.isActive = true
        val mediaSessionConnector = MediaSessionConnector(mediaSession)
        mediaSessionConnector.setPlayer(exoPlayer)
        this.mediaSession = mediaSession
        return mediaSession
    }

    fun onPictureInPictureStatusChanged(inPip: Boolean) {
        val event: MutableMap<String, Any> = HashMap()
        event["event"] = if (inPip) "pipStart" else "pipStop"
        eventSink.success(event)
    }

    fun disposeMediaSession() {
        mediaSession?.release()
        mediaSession = null
    }

    fun setAudioTrack(name: String, index: Int) {
        try {
            val mappedTrackInfo = trackSelector.currentMappedTrackInfo ?: return
            for (rendererIndex in 0 until mappedTrackInfo.rendererCount) {
                if (mappedTrackInfo.getRendererType(rendererIndex) != C.TRACK_TYPE_AUDIO) continue
                val trackGroupArray = mappedTrackInfo.getTrackGroups(rendererIndex)
                var hasElementWithoutLabel = false
                var hasStrangeAudioTrack = false
                for (groupIndex in 0 until trackGroupArray.length) {
                    val group = trackGroupArray[groupIndex]
                    for (groupElementIndex in 0 until group.length) {
                        val format = group.getFormat(groupElementIndex)
                        if (format.label == null) hasElementWithoutLabel = true
                        if (format.id != null && format.id == "1/15") hasStrangeAudioTrack = true
                    }
                }
                for (groupIndex in 0 until trackGroupArray.length) {
                    val group = trackGroupArray[groupIndex]
                    for (groupElementIndex in 0 until group.length) {
                        val label = group.getFormat(groupElementIndex).label
                        if (name == label && index == groupIndex) {
                            setAudioTrack(rendererIndex, groupIndex, groupElementIndex); return
                        }
                        if (!hasStrangeAudioTrack && hasElementWithoutLabel && index == groupIndex) {
                            setAudioTrack(rendererIndex, groupIndex, groupElementIndex); return
                        }
                        if (hasStrangeAudioTrack && name == label) {
                            setAudioTrack(rendererIndex, groupIndex, groupElementIndex); return
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "setAudioTrack failed $e")
        }
    }

    private fun setAudioTrack(rendererIndex: Int, groupIndex: Int, groupElementIndex: Int) {
        val mappedTrackInfo = trackSelector.currentMappedTrackInfo ?: return
        val builder = trackSelector.parameters.buildUpon()
            .setRendererDisabled(rendererIndex, false)
            .setTrackSelectionOverrides(
                TrackSelectionOverrides.Builder().addOverride(
                    TrackSelectionOverrides.TrackSelectionOverride(
                        mappedTrackInfo.getTrackGroups(rendererIndex).get(groupIndex)
                    )
                ).build()
            )
        trackSelector.setParameters(builder)
    }

    private fun sendSeekToEvent(positionMs: Long) {
        exoPlayer?.seekTo(positionMs)
        val event: MutableMap<String, Any> = HashMap()
        event["event"] = "seek"
        event["position"] = positionMs
        eventSink.success(event)
    }

    fun setMixWithOthers(mixWithOthers: Boolean) {
        setAudioAttributes(exoPlayer, mixWithOthers)
    }

    fun dispose() {
        capLiftHandler?.removeCallbacksAndMessages(null)
        capLiftHandler = null
        disposeMediaSession()
        disposeRemoteNotifications()
        stopOfflineTicker()
        if (isInitialized) {
            exoPlayer?.stop()
        }
        textureEntry.release()
        eventChannel.setStreamHandler(null)
        surface?.release()
        exoPlayer?.release()
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other == null || javaClass != other.javaClass) return false
        val that = other as BetterPlayer
        if (if (exoPlayer != null) exoPlayer != that.exoPlayer else that.exoPlayer != null) return false
        return if (surface != null) surface == that.surface else that.surface == null
    }

    override fun hashCode(): Int {
        var result = exoPlayer?.hashCode() ?: 0
        result = 31 * result + (surface?.hashCode() ?: 0)
        return result
    }

    companion object {
        private const val TAG = "BetterPlayer"
        private const val FORMAT_SS = "ss"
        private const val FORMAT_DASH = "dash"
        private const val FORMAT_HLS = "hls"
        private const val FORMAT_OTHER = "other"
        private const val DEFAULT_NOTIFICATION_CHANNEL = "BETTER_PLAYER_NOTIFICATION"
        private const val NOTIFICATION_ID = 20772077

        //Clear cache without accessing BetterPlayerCache.
        fun clearCache(context: Context?, result: MethodChannel.Result) {
            try {
                context?.let { ctx ->
                    val file = File(ctx.cacheDir, "betterPlayerCache")
                    deleteDirectory(file)
                }
                result.success(null)
            } catch (e: Exception) {
                Log.e(TAG, e.toString())
                result.error("", "", "")
            }
        }

        private fun deleteDirectory(file: File) {
            if (file.isDirectory) {
                file.listFiles()?.forEach { deleteDirectory(it) }
            }
            if (!file.delete()) {
                Log.e(TAG, "Failed to delete cache dir.")
            }
        }

        fun preCache(
            context: Context?, dataSource: String?, preCacheSize: Long,
            maxCacheSize: Long, maxCacheFileSize: Long, headers: Map<String, String?>,
            cacheKey: String?, result: MethodChannel.Result
        ) {
            val dataBuilder = Data.Builder()
                .putString(BetterPlayerPlugin.URL_PARAMETER, dataSource)
                .putLong(BetterPlayerPlugin.PRE_CACHE_SIZE_PARAMETER, preCacheSize)
                .putLong(BetterPlayerPlugin.MAX_CACHE_SIZE_PARAMETER, maxCacheSize)
                .putLong(BetterPlayerPlugin.MAX_CACHE_FILE_SIZE_PARAMETER, maxCacheFileSize)
            if (cacheKey != null) {
                dataBuilder.putString(BetterPlayerPlugin.CACHE_KEY_PARAMETER, cacheKey)
            }
            for (headerKey in headers.keys) {
                dataBuilder.putString(
                    BetterPlayerPlugin.HEADER_PARAMETER + headerKey,
                    headers[headerKey]
                )
            }
            if (dataSource != null && context != null) {
                val cacheWorkRequest = OneTimeWorkRequest.Builder(CacheWorker::class.java)
                    .addTag(dataSource)
                    .setInputData(dataBuilder.build()).build()
                WorkManager.getInstance(context).enqueue(cacheWorkRequest)
            }
            result.success(null)
        }

        fun stopPreCache(context: Context?, url: String?, result: MethodChannel.Result) {
            if (url != null && context != null) {
                WorkManager.getInstance(context).cancelAllWorkByTag(url)
            }
            result.success(null)
        }
    }
}
