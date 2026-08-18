package com.sidescreen.app

import android.content.Context
import android.util.DisplayMetrics
import android.view.WindowManager
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * The client's real panel geometry, reported to the host so it can size the
 * virtual display sensibly.
 *
 * The host cannot infer any of this. Its virtual display descriptor carries a
 * *fabricated* physical size — the PPI there is a lever to push macOS past its
 * Retina-detection threshold, not a description of this tablet — so without
 * this message the Mac genuinely believes it is driving an 18 inch panel.
 */
data class PanelInfo(
    val widthPx: Int,
    val heightPx: Int,
    val widthMm: Int,
    val heightMm: Int,
    val refreshHz: Int,
) {
    val diagonalInches: Double
        get() = sqrt((widthMm.toDouble() * widthMm) + (heightMm.toDouble() * heightMm)) / 25.4

    val ppi: Double
        get() = if (diagonalInches > 0) {
            sqrt((widthPx.toDouble() * widthPx) + (heightPx.toDouble() * heightPx)) / diagonalInches
        } else {
            0.0
        }

    companion object {
        /**
         * Reads the real panel from the platform.
         *
         * Uses the *physical* display metrics rather than the app window's, so
         * system bars and multi-window mode do not shrink the reported panel.
         */
        @Suppress("DEPRECATION")
        fun fromContext(context: Context): PanelInfo? {
            val wm = context.getSystemService(Context.WINDOW_SERVICE) as? WindowManager ?: return null
            val display = wm.defaultDisplay ?: return null

            val metrics = DisplayMetrics()
            display.getRealMetrics(metrics)

            val widthPx = metrics.widthPixels
            val heightPx = metrics.heightPixels
            if (widthPx <= 0 || heightPx <= 0) return null

            // xdpi/ydpi are the panel's true physical density. Some devices
            // report nonsense here, so sanity-check before trusting them.
            val xdpi = metrics.xdpi
            val ydpi = metrics.ydpi
            if (!xdpi.isFinite() || !ydpi.isFinite() || xdpi < 50f || ydpi < 50f) return null

            val widthMm = (widthPx / xdpi * 25.4f).roundToInt()
            val heightMm = (heightPx / ydpi * 25.4f).roundToInt()
            if (widthMm < 20 || heightMm < 20) return null

            val refresh = display.refreshRate.takeIf { it.isFinite() && it >= 15f } ?: 60f

            return PanelInfo(
                widthPx = widthPx,
                heightPx = heightPx,
                widthMm = widthMm,
                heightMm = heightMm,
                refreshHz = refresh.roundToInt(),
            )
        }
    }
}

/**
 * Codec for the `clientPanelInfo` wire message (type 15).
 *
 * Seven data bits per byte with the high bit always set, matching
 * `clientDecoderLimits`: a host that does not know this type consumes unknown
 * messages one byte at a time, so no payload byte may collide with a real
 * message-type value. That makes it safe to send unsolicited.
 */
object PanelInfoCodec {
    const val MESSAGE_CLIENT_PANEL_INFO = 15
    const val FRAME_SIZE = 11
    private const val MAX_FIELD = 16383 // 14 bits

    fun encode(info: PanelInfo): ByteArray {
        val out = ByteArray(FRAME_SIZE)
        out[0] = MESSAGE_CLIENT_PANEL_INFO.toByte()
        val fields = intArrayOf(
            info.widthPx, info.heightPx,
            info.widthMm, info.heightMm,
            info.refreshHz,
        )
        for ((i, raw) in fields.withIndex()) {
            val v = raw.coerceIn(0, MAX_FIELD)
            out[1 + i * 2] = (0x80 or ((v shr 7) and 0x7F)).toByte()
            out[2 + i * 2] = (0x80 or (v and 0x7F)).toByte()
        }
        return out
    }
}
