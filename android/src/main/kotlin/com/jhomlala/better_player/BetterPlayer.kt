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
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
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
import com.google.android.exoplayer2.ForwardingPlayer
import com.google.android.exoplayer2.LoadControl
import com.google.android.exoplayer2.MediaItem
import com.google.android.exoplayer2.PlaybackException
import com.google.android.exoplayer2.PlaybackParameters
import com.google.android.exoplayer2.Player
import com.google.android.exoplayer2.SeekParameters
import com.google.android.exoplayer2.Timeline
import com.google.android.exoplayer2.analytics.AnalyticsListener
import com.google.android.exoplayer2.audio.AudioAttributes
import com.google.android.exoplayer2.drm.*
import com.google.android.exoplayer2.ext.mediasession.MediaSessionConnector
import com.google.android.exoplayer2.ext.okhttp.OkHttpDataSource
import com.google.android.exoplayer2.extractor.DefaultExtractorsFactory
import com.google.android.exoplayer2.source.ClippingMediaSource
import com.google.android.exoplayer2.source.MediaSource
import com.google.android.exoplayer2.source.ProgressiveMediaSource
import com.google.android.exoplayer2.source.dash.DashMediaSource
import com.google.android.exoplayer2.source.dash.DefaultDashChunkSource
import com.google.android.exoplayer2.source.hls.HlsMediaSource
import com.google.android.exoplayer2.source.smoothstreaming.DefaultSsChunkSource
import com.google.android.exoplayer2.source.smoothstreaming.SsMediaSource
import com.google.android.exoplayer2.trackselection.AdaptiveTrackSelection
import com.google.android.exoplayer2.trackselection.DefaultTrackSelector
import com.google.android.exoplayer2.trackselection.TrackSelectionOverrides
import com.google.android.exoplayer2.ui.PlayerNotificationManager
import com.google.android.exoplayer2.ui.PlayerNotificationManager.BitmapCallback
import com.google.android.exoplayer2.ui.PlayerNotificationManager.MediaDescriptionAdapter
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.DefaultBandwidthMeter
import com.google.android.exoplayer2.upstream.DefaultDataSource
import com.google.android.exoplayer2.upstream.DefaultHttpDataSource
import com.google.android.exoplayer2.upstream.HttpDataSource
import com.google.android.exoplayer2.upstream.TransferListener
import com.google.android.exoplayer2.upstream.cache.Cache
import com.google.android.exoplayer2.upstream.cache.CacheKeyFactory
import com.google.android.exoplayer2.upstream.cache.ContentMetadata
import com.google.android.exoplayer2.util.UriUtil
import com.google.android.exoplayer2.util.Util
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.EventChannel.EventSink
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry.SurfaceTextureEntry
import okhttp3.ConnectionPool
import okhttp3.OkHttpClient
import java.io.File
import java.io.IOException
import java.lang.Exception
import java.lang.IllegalStateException
import java.util.UUID
import kotlin.math.max
import kotlin.math.min

internal class BetterPlayer(
    context: Context,
    private val eventChannel: EventChannel,
    private val textureEntry: SurfaceTextureEntry,
    customDefaultLoadControl: CustomDefaultLoadControl?,
    result: MethodChannel.Result
) {
    // Core
    private var exoPlayer: ExoPlayer? = null
    private val eventSink = QueuingEventSink()
    private var trackSelector: DefaultTrackSelector
    private val loadControl: LoadControl
    private var isInitialized = false
    private var surface: Surface? = null
    private var key: String? = null

    // Cache & UI state
    private var useCacheEnabledForThisSource = false
    private var lastSendBufferedPosition = 0L

    // Notifications / MediaSession
    private var playerNotificationManager: PlayerNotificationManager? = null
    private var refreshHandler: Handler? = null
    private var refreshRunnable: Runnable? = null
    private var exoPlayerEventListener: Player.Listener? = null
    private var bitmap: Bitmap? = null
    private var mediaSession: MediaSessionCompat? = null

    // DRM
    private var drmSessionManager: DrmSessionManager? = null

    // WorkManager for image loading
    private val workManager: WorkManager
    private val workerObserverMap: HashMap<UUID, Observer<WorkInfo?>>

    // Buffer config (from Flutter)
    private val customDefaultLoadControl: CustomDefaultLoadControl =
        customDefaultLoadControl ?: CustomDefaultLoadControl()

    // ABR & caps
    private var lastBandwidthEstimateBps: Long = -1
    private var recentLoadErrors: Int = 0
    private var errorWindowStartMs: Long = 0
    private val errorWindowMs = 8_000L
    private val errorThreshold = 2
    private val floorCapWhenErrorsBps = 600_000
    private var capLiftHandler: Handler? = null

    // Contexts
    private val appContext: Context = context.applicationContext

    // Bandwidth meter
    private val bandwidthMeter: DefaultBandwidthMeter by lazy {
        DefaultBandwidthMeter.Builder(appContext)
            .setInitialBitrateEstimate(600_000L)
            .setResetOnNetworkTypeChange(true)
            .build()
    }

    // Periodic playable-offline ticker
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

    // ---------------------------------------------------------------------------------------------
    // Init
    // ---------------------------------------------------------------------------------------------
    init {
        // LoadControl (time-based, no byte cap)
        val loadBuilder = DefaultLoadControl.Builder()
            .setBufferDurationsMs(
                this.customDefaultLoadControl.minBufferMs,
                this.customDefaultLoadControl.maxBufferMs,
                this.customDefaultLoadControl.bufferForPlaybackMs,
                this.customDefaultLoadControl.bufferForPlaybackAfterRebufferMs
            )
            .setTargetBufferBytes(C.LENGTH_UNSET)
            .setPrioritizeTimeOverSizeThresholds(true)

        loadControl = loadBuilder.build()

        // TrackSelector w/ ABR
        trackSelector = DefaultTrackSelector(
            context,
            AdaptiveTrackSelection.Factory(
                10_000, // minDurationForQualityIncreaseMs
                3_000,  // maxDurationForQualityDecreaseMs
                25_000, // minDurationToRetainAfterDiscardMs
                0.75f   // bandwidthFraction
            )
        )

        // Player
        exoPlayer = ExoPlayer.Builder(context)
            .setTrackSelector(trackSelector)
            .setLoadControl(loadControl)
            .setBandwidthMeter(bandwidthMeter)
            .build()

        exoPlayer?.setSeekParameters(SeekParameters.CLOSEST_SYNC)

        // WorkManager for artwork loading
        workManager = WorkManager.getInstance(context)
        workerObserverMap = HashMap()

        // Texture + EventChannel
        setupVideoPlayer(eventChannel, textureEntry, result)

        // Analytics
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
                if (bitrateEstimate > 0 && bitrateEstimate < 1_200_000) {
                    val safeCap = (bitrateEstimate * 7 / 10).toInt().coerceAtLeast(300_000)
                    applyBitrateCap(safeCap)
                    scheduleCapLift()
                }
            }

            override fun onLoadError(
                eventTime: AnalyticsListener.EventTime,
                loadEventInfo: com.google.android.exoplayer2.source.LoadEventInfo,
                mediaLoadData: com.google.android.exoplayer2.source.MediaLoadData,
                error: IOException,
                wasCanceled: Boolean
            ) {
                val uriStr = try { loadEventInfo.dataSpec.uri.toString() } catch (_: Exception) { "?" }
                val httpCode = (error as? HttpDataSource.InvalidResponseCodeException)?.responseCode
                Log.e(TAG, "onLoadError: $uriStr, httpCode=$httpCode, cause=${error.javaClass.simpleName}")

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

    // ---------------------------------------------------------------------------------------------
    // Data source
    // ---------------------------------------------------------------------------------------------
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

        val inferredTypeFromHint = when (formatHint) {
            FORMAT_HLS -> C.TYPE_HLS
            FORMAT_DASH -> C.TYPE_DASH
            FORMAT_SS -> C.TYPE_SS
            FORMAT_OTHER -> C.TYPE_OTHER
            else -> C.TYPE_OTHER
        }
        val inferredTypeFromUri = Util.inferContentType(uri)
        val isHlsType = (inferredTypeFromHint == C.TYPE_HLS) || (inferredTypeFromUri == C.TYPE_HLS)

        // --- OkHttp client (shared) ---
        val okClient = OkHttpClient.Builder()
            .connectionPool(ConnectionPool(8, 60, java.util.concurrent.TimeUnit.SECONDS))
            .retryOnConnectionFailure(true)
            .followRedirects(true)
            .followSslRedirects(true)
            .connectTimeout(8, java.util.concurrent.TimeUnit.SECONDS)
            .readTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
            .writeTimeout(15, java.util.concurrent.TimeUnit.SECONDS)
            .build()

        // ---------------- DRM (Widevine/ClearKey) ----------------
        if (!licenseUrl.isNullOrEmpty()) {
            val drmFactory = OkHttpDataSource.Factory(okClient).setUserAgent(userAgent)
            val httpMediaDrmCallback = HttpMediaDrmCallback(licenseUrl, drmFactory)
            drmHeaders?.forEach { (k, v) -> httpMediaDrmCallback.setKeyRequestProperty(k, v) }

            if (Util.SDK_INT < 18) {
                Log.e(TAG, "Protected content not supported on API levels below 18")
                drmSessionManager = null
            } else {
                val drmSchemeUuid = Util.getDrmUuid("widevine")
                if (drmSchemeUuid != null) {
                    drmSessionManager = DefaultDrmSessionManager.Builder()
                        .setUuidAndExoMediaDrmProvider(drmSchemeUuid) { uuid: UUID? ->
                            try {
                                val mediaDrm = FrameworkMediaDrm.newInstance(uuid!!)
                                mediaDrm.setPropertyString("securityLevel", "L3")
                                mediaDrm
                            } catch (e: UnsupportedDrmException) {
                                DummyExoMediaDrm()
                            }
                        }
                        .setMultiSession(false)
                        .build(httpMediaDrmCallback)
                }
            }
        } else if (!clearKey.isNullOrEmpty()) {
            drmSessionManager = if (Util.SDK_INT < 18) {
                Log.e(TAG, "Protected content not supported on API levels below 18")
                null
            } else {
                DefaultDrmSessionManager.Builder()
                    .setUuidAndExoMediaDrmProvider(
                        C.CLEARKEY_UUID,
                        FrameworkMediaDrm.DEFAULT_PROVIDER
                    ).build(LocalMediaDrmCallback(clearKey.toByteArray()))
            }
        } else {
            drmSessionManager = null
        }

        // ---------------- HTTP stacks ----------------
        var defaultHttp = DefaultHttpDataSource.Factory()
            .setUserAgent(userAgent)
            .setAllowCrossProtocolRedirects(true)
            .setConnectTimeoutMs(8_000)
            .setReadTimeoutMs(15_000)

        var okHttp = OkHttpDataSource.Factory(okClient).setUserAgent(userAgent)

        headers?.let {
            defaultHttp = defaultHttp.setDefaultRequestProperties(it)
            okHttp = okHttp.setDefaultRequestProperties(it)
        }

        // Upstream DS (with fallback for HLS)
        val upstreamHttp: DataSource.Factory =
            if (isHlsType) {
                FallbackHttpDataSourceFactory(primary = defaultHttp, secondary = okHttp)
            } else {
                okHttp
            }

        // Wrap with cache (but bypass for .m3u8 internally)
        val mediaDataSourceFactory: DataSource.Factory =
            if (DataSourceUtils.isHTTP(uri) && useCache && maxCacheSize > 0 && maxCacheFileSize > 0) {
                HlsFriendlyCacheDataSourceFactory(
                    context = context,
                    maxCacheSize = maxCacheSize,
                    maxCacheFileSize = maxCacheFileSize,
                    upstreamFactory = upstreamHttp
                )
            } else if (DataSourceUtils.isHTTP(uri)) {
                upstreamHttp
            } else {
                DefaultDataSource.Factory(context)
            }

        val mediaSource = buildMediaSource(uri, mediaDataSourceFactory, formatHint, cacheKey, context)
        if (overriddenDuration != 0L) {
            val clippingMediaSource = ClippingMediaSource(mediaSource, 0, overriddenDuration * 1000)
            exoPlayer?.setMediaSource(clippingMediaSource)
        } else {
            exoPlayer?.setMediaSource(mediaSource)
        }

        exoPlayer?.prepare()
        applyBitrateCap(1_200_000)
        scheduleCapLift()
        startOfflineTicker()

        result.success(null)
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
            ).setDrmSessionManagerProvider(drmSessionManagerProvider)
                .createMediaSource(mediaItem)

            C.TYPE_DASH -> DashMediaSource.Factory(
                DefaultDashChunkSource.Factory(mediaDataSourceFactory),
                DefaultDataSource.Factory(context, mediaDataSourceFactory)
            ).setDrmSessionManagerProvider(drmSessionManagerProvider)
                .createMediaSource(mediaItem)

            C.TYPE_HLS -> HlsMediaSource.Factory(mediaDataSourceFactory)
                // IMPORTANT for wide compatibility on live HLS:
                .setAllowChunklessPreparation(false)
                .setDrmSessionManagerProvider(drmSessionManagerProvider)
                .createMediaSource(mediaItem)

            C.TYPE_OTHER -> ProgressiveMediaSource.Factory(
                mediaDataSourceFactory,
                DefaultExtractorsFactory()
            ).setDrmSessionManagerProvider(drmSessionManagerProvider)
                .createMediaSource(mediaItem)

            else -> {
                throw IllegalStateException("Unsupported type: $type")
            }
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Playable (RAM + disk) computation
    // ---------------------------------------------------------------------------------------------
    private fun playerCache(): Cache? {
        if (!useCacheEnabledForThisSource) return null
        return BetterPlayerCache.createCache(appContext, 1L)
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
            C.TYPE_HLS -> diskAheadHlsMs(cache, p)
            else -> 0L
        }
        return ramAheadMs + kotlin.math.max(0L, diskAheadMs)
    }

    // Progressive: contiguous cached bytes ahead mapped to time.
    private fun diskAheadProgressiveMs(cache: Cache, item: MediaItem, p: ExoPlayer): Long {
        val durationMs = p.duration.takeIf { it > 0 } ?: return 0L
        val mc = item.localConfiguration ?: return 0L
        val dataSpec = DataSpec(mc.uri)
        val key = mc.customCacheKey ?: CacheKeyFactory.DEFAULT.buildCacheKey(dataSpec)

        val meta = cache.getContentMetadata(key)
        val contentLength = ContentMetadata.getContentLength(meta)
        val currentMs = p.currentPosition

        if (contentLength > 0L) {
            val startByte = ((contentLength * currentMs) / durationMs)
                .coerceAtLeast(0L).coerceAtMost(contentLength - 1)
            var pos = startByte
            var aheadBytes = 0L
            while (true) {
                val len = cache.getCachedLength(key, pos, Long.MAX_VALUE)
                if (len <= 0) break
                aheadBytes += len
                pos += len
            }
            return (aheadBytes * durationMs / contentLength)
        } else {
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
            return ((aheadBytes * 8_000L) / bitrateBps)
        }
    }

    // HLS: sum durations of fully cached segments strictly AFTER the current one (reflection).
    private fun diskAheadHlsMs(cache: Cache, p: ExoPlayer): Long {
        val any = p.currentManifest ?: return 0L
        try {
            // any is com.google.android.exoplayer2.source.hls.playlist.HlsManifest
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

    // ---------------------------------------------------------------------------------------------
    // Player & events
    // ---------------------------------------------------------------------------------------------
    private fun setupVideoPlayer(
        eventChannel: EventChannel,
        textureEntry: SurfaceTextureEntry,
        result: MethodChannel.Result
    ) {
        eventChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(o: Any?, sink: EventSink) {
                    eventSink.setDelegate(sink)
                }
                override fun onCancel(o: Any?) {
                    eventSink.setDelegate(null)
                }
            }
        )

        surface = Surface(textureEntry.surfaceTexture())
        exoPlayer?.setVideoSurface(surface)
        setAudioAttributes(exoPlayer, true)

        // This listener is the ONLY place that emits playback events to Dart.
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

    fun play() { exoPlayer?.playWhenReady = true }
    fun pause() { exoPlayer?.playWhenReady = false }

    fun setLooping(value: Boolean) {
        exoPlayer?.repeatMode = if (value) Player.REPEAT_MODE_ALL else Player.REPEAT_MODE_OFF
    }

    fun setVolume(value: Double) {
        val bracketedValue = max(0.0, min(1.0, value)).toFloat()
        exoPlayer?.volume = bracketedValue
    }

    fun setSpeed(value: Double) {
        val playbackParameters = PlaybackParameters(value.toFloat())
        exoPlayer?.playbackParameters = playbackParameters
    }

    fun setTrackParameters(width: Int, height: Int, bitrate: Int) {
        val parametersBuilder = trackSelector.buildUponParameters()
        if (width != 0 && height != 0) {
            parametersBuilder.setMaxVideoSize(width, height)
        }
        if (bitrate != 0) {
            parametersBuilder.setMaxVideoBitrate(bitrate)
        }
        if (width == 0 && height == 0 && bitrate == 0) {
            parametersBuilder.clearVideoSizeConstraints()
            parametersBuilder.setMaxVideoBitrate(Int.MAX_VALUE)
        }
        trackSelector.setParameters(parametersBuilder)
    }

    fun seekTo(location: Int) {
        // small temporary cap during seeks helps avoid rebuffer at the switch
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
                    val windowStartTimeMs =
                        timeline.getWindow(0, Timeline.Window()).windowStartTimeMs
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
            if (exoPlayer?.videoFormat != null) {
                val videoFormat = exoPlayer!!.videoFormat
                var width = videoFormat?.width
                var height = videoFormat?.height
                val rotationDegrees = videoFormat?.rotationDegrees
                if (rotationDegrees == 90 || rotationDegrees == 270) {
                    width = exoPlayer!!.videoFormat?.height
                    height = exoPlayer!!.videoFormat?.width
                }
                event["width"] = width
                event["height"] = height
            }
            eventSink.success(event)
        }
    }

    private fun getDuration(): Long = exoPlayer?.duration ?: 0L

    // ---------------------------------------------------------------------------------------------
    // Media session & notifications
    // ---------------------------------------------------------------------------------------------
    @SuppressLint("InlinedApi")
    fun setupMediaSession(context: Context?): MediaSessionCompat? {
        mediaSession?.release()
        context?.let {
            val mediaButtonIntent = Intent(Intent.ACTION_MEDIA_BUTTON)
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                0, mediaButtonIntent,
                PendingIntent.FLAG_IMMUTABLE
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
        return null
    }

    fun disposeMediaSession() {
        mediaSession?.release()
        mediaSession = null
    }

    fun onPictureInPictureStatusChanged(inPip: Boolean) {
        val event: MutableMap<String, Any> = HashMap()
        event["event"] = if (inPip) "pipStart" else "pipStop"
        eventSink.success(event)
    }

    private fun sendSeekToEvent(positionMs: Long) {
        exoPlayer?.seekTo(positionMs)
        val event: MutableMap<String, Any> = HashMap()
        event["event"] = "seek"
        event["position"] = positionMs
        eventSink.success(event)
    }

    // Called from plugin – keep signature
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

            override fun getCurrentLargeIcon(
                player: Player,
                callback: BitmapCallback
            ): Bitmap? {
                if (imageUrl == null) return null
                if (bitmap != null) return bitmap

                val imageWorkRequest = OneTimeWorkRequest.Builder(ImageWorker::class.java)
                    .addTag(imageUrl)
                    .setInputData(
                        Data.Builder()
                            .putString(BetterPlayerPlugin.URL_PARAMETER, imageUrl)
                            .build()
                    )
                    .build()

                workManager.enqueue(imageWorkRequest)

                val workInfoObserver = Observer { workInfo: WorkInfo? ->
                    try {
                        if (workInfo != null) {
                            val state = workInfo.state
                            if (state == WorkInfo.State.SUCCEEDED) {
                                val outputData = workInfo.outputData
                                val filePath =
                                    outputData.getString(BetterPlayerPlugin.FILE_PATH_PARAMETER)
                                bitmap = BitmapFactory.decodeFile(filePath)
                                bitmap?.let { bmp -> callback.onBitmap(bmp) }
                            }
                            if (state == WorkInfo.State.SUCCEEDED ||
                                state == WorkInfo.State.CANCELLED ||
                                state == WorkInfo.State.FAILED
                            ) {
                                val uuid = imageWorkRequest.id
                                workerObserverMap.remove(uuid)?.let { observer ->
                                    workManager.getWorkInfoByIdLiveData(uuid)
                                        .removeObserver(observer)
                                }
                            }
                        }
                    } catch (exception: Exception) {
                        Log.e(TAG, "Image select error: $exception")
                    }
                }

                val workerUuid = imageWorkRequest.id
                workManager.getWorkInfoByIdLiveData(workerUuid)
                    .observeForever(workInfoObserver)
                workerObserverMap[workerUuid] = workInfoObserver

                return null
            }
        }

        var channelName = notificationChannelName
        if (channelName == null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val importance = NotificationManager.IMPORTANCE_LOW
                val channel = NotificationChannel(
                    DEFAULT_NOTIFICATION_CHANNEL,
                    DEFAULT_NOTIFICATION_CHANNEL,
                    importance
                ).apply { description = DEFAULT_NOTIFICATION_CHANNEL }

                val notificationManager =
                    context.getSystemService(NotificationManager::class.java)
                notificationManager.createNotificationChannel(channel)
                channelName = DEFAULT_NOTIFICATION_CHANNEL
            }
        }

        playerNotificationManager = PlayerNotificationManager.Builder(
            context,
            NOTIFICATION_ID,
            channelName!!
        ).setMediaDescriptionAdapter(mediaDescriptionAdapter).build()

        playerNotificationManager?.apply {
            exoPlayer?.let { exo ->
                setPlayer(ForwardingPlayer(exo))
                setUseNextAction(false)
                setUsePreviousAction(false)
                setUseStopAction(false)
            }
            this@BetterPlayer.setupMediaSession(context)?.let {
                setMediaSessionToken(it.sessionToken)
            }
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

        // Keep the listener here, but DO NOT emit events to Dart from this one.
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
                        else
                            900_000
                        applyBitrateCap(fastCap)
                    }
                    Player.STATE_READY -> {
                        scheduleCapLift()
                    }
                    else -> { /* no-op */ }
                }
            }
        }
        exoPlayerEventListener?.let { exoPlayer?.addListener(it) }

        exoPlayer?.seekTo(0)
    }

    fun disposeRemoteNotifications() {
        exoPlayerEventListener?.let { exoPlayer?.removeListener(it) }
        if (refreshHandler != null) {
            refreshHandler?.removeCallbacksAndMessages(null)
            refreshHandler = null
            refreshRunnable = null
        }
        playerNotificationManager?.setPlayer(null)
        bitmap = null
    }

    // ---------------------------------------------------------------------------------------------
    // ABR helpers
    // ---------------------------------------------------------------------------------------------
    private fun resetErrorWindowIfNeeded(now: Long) {
        if (now - errorWindowStartMs > errorWindowMs) {
            errorWindowStartMs = now
            recentLoadErrors = 0
        }
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

    // ---------------------------------------------------------------------------------------------
    // Audio track selection (unchanged)
    // ---------------------------------------------------------------------------------------------
    fun setAudioTrack(name: String, index: Int) {
        try {
            val mappedTrackInfo = trackSelector.currentMappedTrackInfo
            if (mappedTrackInfo != null) {
                for (rendererIndex in 0 until mappedTrackInfo.rendererCount) {
                    if (mappedTrackInfo.getRendererType(rendererIndex) != C.TRACK_TYPE_AUDIO) {
                        continue
                    }
                    val trackGroupArray = mappedTrackInfo.getTrackGroups(rendererIndex)
                    var hasElementWithoutLabel = false
                    var hasStrangeAudioTrack = false
                    for (groupIndex in 0 until trackGroupArray.length) {
                        val group = trackGroupArray[groupIndex]
                        for (groupElementIndex in 0 until group.length) {
                            val format = group.getFormat(groupElementIndex)
                            if (format.label == null) {
                                hasElementWithoutLabel = true
                            }
                            if (format.id != null && format.id == "1/15") {
                                hasStrangeAudioTrack = true
                            }
                        }
                    }
                    for (groupIndex in 0 until trackGroupArray.length) {
                        val group = trackGroupArray[groupIndex]
                        for (groupElementIndex in 0 until group.length) {
                            val label = group.getFormat(groupElementIndex).label
                            if (name == label && index == groupIndex) {
                                setAudioTrack(rendererIndex, groupIndex, groupElementIndex)
                                return
                            }
                            if (!hasStrangeAudioTrack && hasElementWithoutLabel && index == groupIndex) {
                                setAudioTrack(rendererIndex, groupIndex, groupElementIndex)
                                return
                            }
                            if (hasStrangeAudioTrack && name == label) {
                                setAudioTrack(rendererIndex, groupIndex, groupElementIndex)
                                return
                            }
                        }
                    }
                }
            }
        } catch (exception: Exception) {
            Log.e(TAG, "setAudioTrack failed$exception")
        }
    }

    private fun setAudioTrack(rendererIndex: Int, groupIndex: Int, groupElementIndex: Int) {
        val mappedTrackInfo = trackSelector.currentMappedTrackInfo
        if (mappedTrackInfo != null) {
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
    }

    fun setMixWithOthers(mixWithOthers: Boolean) {
        setAudioAttributes(exoPlayer, mixWithOthers)
    }

    // ---------------------------------------------------------------------------------------------
    // Dispose
    // ---------------------------------------------------------------------------------------------
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
        exoPlayer = null

        drmSessionManager?.release()
        drmSessionManager = null
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
        result = 31 * result + if (surface != null) surface.hashCode() else 0
        return result
    }

    companion object {
        internal const val TAG = "BetterPlayer"
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
            } catch (exception: Exception) {
                Log.e(TAG, exception.toString())
                result.error("", "", "")
            }
        }

        private fun deleteDirectory(file: File) {
            if (file.isDirectory) {
                val entries = file.listFiles()
                if (entries != null) {
                    for (entry in entries) {
                        deleteDirectory(entry)
                    }
                }
            }
            if (!file.delete()) {
                Log.e(TAG, "Failed to delete cache dir.")
            }
        }

        //Start pre cache of video. Invoke work manager job and start caching in background.
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

        //Stop pre cache of video with given url. If there's no work manager job for given url, then
        //it will be ignored.
        fun stopPreCache(context: Context?, url: String?, result: MethodChannel.Result) {
            if (url != null && context != null) {
                WorkManager.getInstance(context).cancelAllWorkByTag(url)
            }
            result.success(null)
        }
    }
}

// =================================================================================================
// Helper DS factories (kept in the same file so you don't miss them)
// =================================================================================================

/**
 * Try a primary HTTP DataSource first (DefaultHttpDataSource), and if it fails during open()
 * with a recoverable networking error/404, fall back to a secondary (OkHttpDataSource).
 */
internal class FallbackHttpDataSourceFactory(
    private val primary: HttpDataSource.Factory,
    private val secondary: HttpDataSource.Factory
) : DataSource.Factory {

    override fun createDataSource(): DataSource {
        val primaryDs = primary.createDataSource()
        val secondaryDs = secondary.createDataSource()
        return FallbackHttpDataSource(primaryDs, secondaryDs)
    }
}

internal class FallbackHttpDataSource(
    private val primary: DataSource,
    private val secondary: DataSource
) : DataSource {

    private var current: DataSource? = null
    private var listener: TransferListener? = null

    override fun addTransferListener(transferListener: TransferListener) {
        listener = transferListener
        primary.addTransferListener(transferListener)
        secondary.addTransferListener(transferListener)
    }

    @Throws(IOException::class)
    override fun open(dataSpec: DataSpec): Long {
        return try {
            current = primary
            primary.open(dataSpec)
        } catch (e: IOException) {
            // Log and switch
            Log.w("BetterPlayer-FallbackDS", "Primary DS failed (${e.javaClass.simpleName}); switching to secondary")
            current = secondary
            secondary.open(dataSpec)
        }
    }

    override fun read(buffer: ByteArray, offset: Int, readLength: Int): Int {
        return current?.read(buffer, offset, readLength) ?: C.RESULT_END_OF_INPUT
    }

    override fun getUri(): Uri? = current?.uri

    override fun close() {
        try {
            current?.close()
        } catch (_: Exception) {
        } finally {
            current = null
        }
    }
}

/**
 * For HLS, we *bypass* caching the playlist (.m3u8) requests (these frequently 404 with variant
 * switching on some CDNs). For media chunks and progressive, we use your existing cache factory.
 *
 * NOTE: This wrapper uses your existing [CacheDataSourceFactory] class from the repo.
 */
internal class HlsFriendlyCacheDataSourceFactory(
    private val context: Context,
    private val maxCacheSize: Long,
    private val maxCacheFileSize: Long,
    private val upstreamFactory: DataSource.Factory
) : DataSource.Factory {

    override fun createDataSource(): DataSource {
        // We cannot inspect DataSpec here, so we return a small delegating DS that decides at open().
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
                    // playlist -> never cached
                    upstreamFactory.createDataSource()
                } else {
                    // chunks / progressive -> cached
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
