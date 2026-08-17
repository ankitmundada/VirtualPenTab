package com.sidescreen.app

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.sin

/**
 * Stylus stroke phase.
 *
 * Wire values MUST stay in lockstep with `PenPhase` in `MacHost/PenCore` —
 * PenCodecTest pins them so a rename on one side breaks the build, not a
 * running session.
 */
enum class PenPhase(val wire: Byte) {
    HOVER_ENTER(0),
    HOVER_MOVE(1),
    DOWN(2),
    MOVE(3),
    UP(4),
    HOVER_EXIT(5),
    CANCEL(6),
}

/** One stylus sample. Coordinates are normalized 0..1 against the video surface. */
data class PenSample(
    val phase: PenPhase,
    val buttons: Int,
    val x: Float,
    val y: Float,
    val pressure: Float,
    val tiltX: Float,
    val tiltY: Float,
)

/**
 * Encoder for the `penEvent` wire message (type 14). See
 * docs/pen-support-design.md §5.2 for the layout.
 */
object PenCodec {
    const val MESSAGE_PEN_EVENT = 14
    const val MESSAGE_CLIENT_SUPPORTS_PEN = 12
    const val MESSAGE_PEN_ENABLED = 13
    const val FRAME_SIZE = 23

    const val BUTTON_BARREL1 = 1
    const val BUTTON_BARREL2 = 2
    const val BUTTON_ERASER = 4

    fun encode(s: PenSample): ByteArray = ByteArray(FRAME_SIZE).also { encodeInto(s, it, 0) }

    /**
     * Writes one frame into an existing buffer at [offset].
     *
     * Allocation-free so a stroke can be encoded into a reused batch buffer:
     * at 240 Hz a fresh ByteArray per sample is pure GC pressure, and a GC
     * pause during a stroke is visible as a hitch in the drawn line.
     */
    fun encodeInto(s: PenSample, dest: ByteArray, offset: Int) {
        dest[offset] = MESSAGE_PEN_EVENT.toByte()
        dest[offset + 1] = s.phase.wire
        dest[offset + 2] = (s.buttons and 0b111).toByte()
        putFloatLE(dest, offset + 3, clamp(s.x, 0f, 1f))
        putFloatLE(dest, offset + 7, clamp(s.y, 0f, 1f))
        putFloatLE(dest, offset + 11, clamp(s.pressure, 0f, 1f))
        putFloatLE(dest, offset + 15, clamp(s.tiltX, -1f, 1f))
        putFloatLE(dest, offset + 19, clamp(s.tiltY, -1f, 1f))
    }

    private fun putFloatLE(dest: ByteArray, at: Int, value: Float) {
        val bits = java.lang.Float.floatToIntBits(value)
        dest[at] = (bits and 0xFF).toByte()
        dest[at + 1] = ((bits ushr 8) and 0xFF).toByte()
        dest[at + 2] = ((bits ushr 16) and 0xFF).toByte()
        dest[at + 3] = ((bits ushr 24) and 0xFF).toByte()
    }

    /**
     * Clamps into range, mapping non-finite input to zero.
     *
     * The host rejects any frame containing NaN or infinity outright, so a
     * single glitched sample from the digitizer would otherwise drop a whole
     * pen event rather than just a bad axis.
     */
    private fun clamp(v: Float, lo: Float, hi: Float): Float {
        if (!v.isFinite()) return 0f
        return v.coerceIn(lo, hi)
    }
}

/**
 * Converts Android's polar stylus tilt into the Cartesian pair macOS expects.
 *
 * Android reports `AXIS_TILT` (angle away from perpendicular) plus
 * `orientation` (azimuth, 0 = pointing away from the user, positive
 * clockwise). macOS `tabletEventTiltX/tiltY` are two independent signed axes.
 *
 * Collapsing these to a single value — as upstream PR #33 does — discards the
 * pen's direction entirely, and the Xiaomi Pad 5 digitizer genuinely reports
 * both (`ABS_TILT_X` and `ABS_TILT_Y`, each -60..60 degrees).
 */
object PenTilt {
    private const val HALF_PI = (PI / 2).toFloat()

    /**
     * Components below this are treated as exactly zero.
     *
     * A fully flat pen (tilt = 90°) is a genuine singularity: the vertical
     * component is zero, so `atan2` amplifies float noise to full scale.
     * `cos(PI/2)` in Float is -4.4e-8 rather than 0, which without snapping
     * turns `atan2(0, -4.4e-8)` into PI — reporting maximum tilt on an axis
     * that should read zero.
     */
    private const val EPSILON = 1e-6f

    fun toCartesian(tiltRadians: Float, orientationRadians: Float): Pair<Float, Float> {
        if (!tiltRadians.isFinite() || !orientationRadians.isFinite()) return 0f to 0f

        // Tilt is defined over 0..90°, so the vertical component is never
        // negative; clamping absorbs both bad input and float error at the end.
        val tilt = tiltRadians.coerceIn(0f, HALF_PI)
        val sinTilt = sin(tilt)
        val vertical = max(cos(tilt), 0f)

        val horizontal = snap(sinTilt * sin(orientationRadians))
        val depth = snap(sinTilt * cos(orientationRadians))

        val tiltX = atan2(horizontal, vertical)
        val tiltY = atan2(depth, vertical)

        return (tiltX / HALF_PI).coerceIn(-1f, 1f) to (tiltY / HALF_PI).coerceIn(-1f, 1f)
    }

    private fun snap(v: Float): Float = if (abs(v) < EPSILON) 0f else v
}
