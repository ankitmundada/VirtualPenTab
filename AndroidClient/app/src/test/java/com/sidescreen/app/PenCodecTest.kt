package com.sidescreen.app

import org.junit.Assert.assertEquals
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI

class PenCodecTest {

    private fun sample(
        phase: PenPhase = PenPhase.MOVE,
        buttons: Int = 0,
        x: Float = 0.25f,
        y: Float = 0.75f,
        pressure: Float = 0.5f,
        tiltX: Float = -0.25f,
        tiltY: Float = 0.5f,
    ) = PenSample(phase, buttons, x, y, pressure, tiltX, tiltY)

    @Test
    fun frameIsTwentyThreeBytes() {
        assertEquals(23, PenCodec.FRAME_SIZE)
        assertEquals(23, PenCodec.encode(sample()).size)
    }

    @Test
    fun encodesHeaderAndFieldsLittleEndian() {
        val bytes = PenCodec.encode(
            sample(phase = PenPhase.DOWN, buttons = 0b011, x = 0.25f, y = 0.75f,
                pressure = 0.5f, tiltX = -0.25f, tiltY = 0.5f)
        )
        assertEquals(14, bytes[0].toInt())
        assertEquals(2, bytes[1].toInt())      // DOWN
        assertEquals(0b011, bytes[2].toInt())

        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        buf.position(3)
        assertEquals(0.25f, buf.float, 1e-6f)
        assertEquals(0.75f, buf.float, 1e-6f)
        assertEquals(0.5f, buf.float, 1e-6f)
        assertEquals(-0.25f, buf.float, 1e-6f)
        assertEquals(0.5f, buf.float, 1e-6f)
    }

    @Test
    fun everyPhaseHasDistinctWireValueMatchingHost() {
        // These must stay in lockstep with PenPhase in MacHost/PenCore.
        assertEquals(0, PenPhase.HOVER_ENTER.wire.toInt())
        assertEquals(1, PenPhase.HOVER_MOVE.wire.toInt())
        assertEquals(2, PenPhase.DOWN.wire.toInt())
        assertEquals(3, PenPhase.MOVE.wire.toInt())
        assertEquals(4, PenPhase.UP.wire.toInt())
        assertEquals(5, PenPhase.HOVER_EXIT.wire.toInt())
        assertEquals(6, PenPhase.CANCEL.wire.toInt())
    }

    @Test
    fun clampsOutOfRangeValues() {
        val bytes = PenCodec.encode(
            sample(x = -0.5f, y = 1.5f, pressure = 2f, tiltX = -9f, tiltY = 9f)
        )
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        buf.position(3)
        assertEquals(0f, buf.float, 1e-6f)
        assertEquals(1f, buf.float, 1e-6f)
        assertEquals(1f, buf.float, 1e-6f)
        assertEquals(-1f, buf.float, 1e-6f)
        assertEquals(1f, buf.float, 1e-6f)
    }

    @Test
    fun replacesNonFiniteWithZero() {
        // A digitizer glitch reporting NaN must not reach the host, which
        // rejects the whole frame on non-finite input.
        val bytes = PenCodec.encode(sample(pressure = Float.NaN, tiltX = Float.POSITIVE_INFINITY))
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        buf.position(11)
        assertEquals(0f, buf.float, 1e-6f)
        assertEquals(0f, buf.float, 1e-6f)
    }
}

class PenTiltTest {

    private fun tilt(tiltRad: Float, orientationRad: Float) =
        PenTilt.toCartesian(tiltRad, orientationRad)

    @Test
    fun perpendicularPenHasNoTilt() {
        val (x, y) = tilt(0f, 0f)
        assertEquals(0f, x, 1e-5f)
        assertEquals(0f, y, 1e-5f)
    }

    @Test
    fun perpendicularPenIgnoresOrientation() {
        // With zero tilt the azimuth is meaningless and must not leak through.
        for (o in listOf(0f, 1f, -2f, PI.toFloat())) {
            val (x, y) = tilt(0f, o)
            assertEquals("tiltX at orientation $o", 0f, x, 1e-5f)
            assertEquals("tiltY at orientation $o", 0f, y, 1e-5f)
        }
    }

    @Test
    fun fullyFlatPenPointingUpIsPositiveY() {
        val (x, y) = tilt((PI / 2).toFloat(), 0f)
        assertEquals(0f, x, 1e-5f)
        assertEquals(1f, y, 1e-5f)
    }

    @Test
    fun fullyFlatPenPointingRightIsPositiveX() {
        val (x, y) = tilt((PI / 2).toFloat(), (PI / 2).toFloat())
        assertEquals(1f, x, 1e-5f)
        assertEquals(0f, y, 1e-5f)
    }

    @Test
    fun fullyFlatPenPointingLeftIsNegativeX() {
        val (x, y) = tilt((PI / 2).toFloat(), (-PI / 2).toFloat())
        assertEquals(-1f, x, 1e-5f)
        assertEquals(0f, y, 1e-5f)
    }

    @Test
    fun fullyFlatPenPointingDownIsNegativeY() {
        val (x, y) = tilt((PI / 2).toFloat(), PI.toFloat())
        assertEquals(0f, x, 1e-5f)
        assertEquals(-1f, y, 1e-5f)
    }

    @Test
    fun fortyFiveDegreeTiltIsHalfScale() {
        // atan2(sin45*sin90, cos45) = 45deg = half of the 90deg full range.
        val (x, y) = tilt((PI / 4).toFloat(), (PI / 2).toFloat())
        assertEquals(0.5f, x, 1e-5f)
        assertEquals(0f, y, 1e-5f)
    }

    @Test
    fun outputStaysWithinUnitRange() {
        var t = 0f
        while (t <= (PI / 2).toFloat()) {
            var o = -PI.toFloat()
            while (o <= PI.toFloat()) {
                val (x, y) = tilt(t, o)
                assert(x in -1f..1f) { "tiltX $x out of range at t=$t o=$o" }
                assert(y in -1f..1f) { "tiltY $y out of range at t=$t o=$o" }
                o += 0.2f
            }
            t += 0.1f
        }
    }

    @Test
    fun nonFiniteInputCollapsesToZero() {
        val (x, y) = tilt(Float.NaN, Float.NaN)
        assertEquals(0f, x, 1e-6f)
        assertEquals(0f, y, 1e-6f)
    }
}
