package com.jhomlala.better_player

import android.net.Uri
import android.util.Log
import com.google.android.exoplayer2.C
import com.google.android.exoplayer2.upstream.DataSource
import com.google.android.exoplayer2.upstream.DataSpec
import com.google.android.exoplayer2.upstream.HttpDataSource
import com.google.android.exoplayer2.upstream.TransferListener
import java.io.IOException

/**
 * Try a primary HTTP DataSource first (DefaultHttpDataSource), and if it fails during open()
 * with a networking error or 4xx/5xx, fall back to a secondary (OkHttpDataSource).
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

    private var active: DataSource? = null
    private var listener: TransferListener? = null

    override fun addTransferListener(transferListener: TransferListener) {
        listener = transferListener
        primary.addTransferListener(transferListener)
        secondary.addTransferListener(transferListener)
    }

    @Throws(IOException::class)
    override fun open(dataSpec: DataSpec): Long {
        return try {
            active = primary
            primary.open(dataSpec)
        } catch (e: IOException) {
            Log.w("BetterPlayer-FallbackDS", "Primary DS failed (${e.javaClass.simpleName}); switching to secondary")
            active = secondary
            secondary.open(dataSpec)
        }
    }

    override fun read(buffer: ByteArray, offset: Int, readLength: Int): Int {
        return active?.read(buffer, offset, readLength) ?: C.RESULT_END_OF_INPUT
    }

    override fun getUri(): Uri? = active?.uri

    override fun close() {
        try {
            active?.close()
        } catch (_: Exception) {
        } finally {
            active = null
        }
    }
}
