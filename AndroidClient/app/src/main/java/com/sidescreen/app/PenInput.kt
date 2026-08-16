package com.sidescreen.app

import android.view.MotionEvent
import android.view.View

/**
 * Converts stylus [MotionEvent]s into [PenSample]s.
 *
 * Only active once the host has acknowledged pen support (wire type 13) — see
 * docs/pen-support-design.md §5. Until then [enabled] stays false and stylus
 * input falls through to the ordinary touch path unchanged.
 */
class PenInput(private val send: (PenSample) -> Unit) {

    /** Set from the host's `penEnabled` ack. */
    @Volatile
    var enabled: Boolean = false

    /** True once a DOWN has been sent and its UP has not. */
    private var strokeActive = false

    fun reset() {
        strokeActive = false
    }

    /** Whether this event carries a stylus that we should handle. */
    fun isStylus(event: MotionEvent): Boolean =
        enabled && stylusPointerIndex(event) != null

    /**
     * Handles a touch-phase event (tip in contact).
     * Returns true if the event was consumed as pen input.
     */
    fun handleTouch(
        view: View,
        event: MotionEvent,
        flipHorizontal: Boolean,
        flipVertical: Boolean,
    ): Boolean {
        val index = stylusPointerIndex(event) ?: return false
        if (!enabled) return false

        val phase =
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> PenPhase.DOWN
                MotionEvent.ACTION_MOVE -> PenPhase.MOVE
                MotionEvent.ACTION_UP -> PenPhase.UP
                MotionEvent.ACTION_CANCEL -> PenPhase.CANCEL
                else -> return false
            }

        // A MOVE arriving with no stroke open means we missed the DOWN (the
        // host toggled pen input on mid-gesture, say). Promote it rather than
        // emitting a drag the host will treat as a hover.
        val effective =
            if (phase == PenPhase.MOVE && !strokeActive) PenPhase.DOWN else phase

        when (effective) {
            PenPhase.DOWN -> strokeActive = true
            PenPhase.UP, PenPhase.CANCEL -> strokeActive = false
            else -> {}
        }

        emitWithHistory(view, event, index, effective, flipHorizontal, flipVertical)
        return true
    }

    /**
     * Handles a hover-phase event. Hover is delivered to
     * `onGenericMotionEvent`, never to `onTouchEvent`, so it needs its own
     * entry point.
     */
    fun handleHover(
        view: View,
        event: MotionEvent,
        flipHorizontal: Boolean,
        flipVertical: Boolean,
    ): Boolean {
        val index = stylusPointerIndex(event) ?: return false
        if (!enabled) return false

        val phase =
            when (event.actionMasked) {
                MotionEvent.ACTION_HOVER_ENTER -> PenPhase.HOVER_ENTER
                MotionEvent.ACTION_HOVER_MOVE -> PenPhase.HOVER_MOVE
                MotionEvent.ACTION_HOVER_EXIT -> PenPhase.HOVER_EXIT
                else -> return false
            }

        emitWithHistory(view, event, index, phase, flipHorizontal, flipVertical)
        return true
    }

    // MARK: - Sample emission

    /**
     * Emits every batched sample, oldest first, then the current one.
     *
     * MotionEvent coalesces stylus samples to the vsync tick, so the pen's
     * ~240 Hz stream arrives 60–120 times a second with the rest in the
     * history buffer. Reading only the current position throws most of the
     * resolution away and produces visibly polygonal strokes.
     */
    private fun emitWithHistory(
        view: View,
        event: MotionEvent,
        pointerIndex: Int,
        phase: PenPhase,
        flipHorizontal: Boolean,
        flipVertical: Boolean,
    ) {
        val width = view.width.toFloat()
        val height = view.height.toFloat()
        if (width <= 0f || height <= 0f) return

        val buttons = buttonsOf(event, pointerIndex)
        val contact = phase == PenPhase.DOWN || phase == PenPhase.MOVE

        // Historical samples are always intermediate motion, never the
        // transition itself, so they carry MOVE/HOVER_MOVE.
        val historyPhase = if (contact) PenPhase.MOVE else PenPhase.HOVER_MOVE
        if (phase == PenPhase.MOVE || phase == PenPhase.HOVER_MOVE) {
            for (h in 0 until event.historySize) {
                send(
                    PenSample(
                        phase = historyPhase,
                        buttons = buttons,
                        x = normalize(event.getHistoricalX(pointerIndex, h), width, flipHorizontal),
                        y = normalize(event.getHistoricalY(pointerIndex, h), height, flipVertical),
                        pressure = if (contact) event.getHistoricalPressure(pointerIndex, h) else 0f,
                        tiltX = 0f,
                        tiltY = 0f,
                    ).withTilt(
                        event.getHistoricalAxisValue(MotionEvent.AXIS_TILT, pointerIndex, h),
                        event.getHistoricalOrientation(pointerIndex, h),
                    )
                )
            }
        }

        send(
            PenSample(
                phase = phase,
                buttons = buttons,
                x = normalize(event.getX(pointerIndex), width, flipHorizontal),
                y = normalize(event.getY(pointerIndex), height, flipVertical),
                pressure = if (contact) event.getPressure(pointerIndex) else 0f,
                tiltX = 0f,
                tiltY = 0f,
            ).withTilt(
                event.getAxisValue(MotionEvent.AXIS_TILT, pointerIndex),
                event.getOrientation(pointerIndex),
            )
        )
    }

    private fun PenSample.withTilt(tiltRadians: Float, orientationRadians: Float): PenSample {
        val (tx, ty) = PenTilt.toCartesian(tiltRadians, orientationRadians)
        return copy(tiltX = tx, tiltY = ty)
    }

    private fun normalize(value: Float, extent: Float, flip: Boolean): Float {
        val n = value / extent
        return if (flip) 1f - n else n
    }

    private fun buttonsOf(event: MotionEvent, pointerIndex: Int): Int {
        var buttons = 0
        val state = event.buttonState
        if (state and MotionEvent.BUTTON_STYLUS_PRIMARY != 0) buttons = buttons or PenCodec.BUTTON_BARREL1
        if (state and MotionEvent.BUTTON_STYLUS_SECONDARY != 0) buttons = buttons or PenCodec.BUTTON_BARREL2
        if (event.getToolType(pointerIndex) == MotionEvent.TOOL_TYPE_ERASER) {
            buttons = buttons or PenCodec.BUTTON_ERASER
        }
        return buttons
    }

    /** Index of the first stylus/eraser pointer, or null if this isn't a pen event. */
    private fun stylusPointerIndex(event: MotionEvent): Int? {
        for (i in 0 until event.pointerCount) {
            when (event.getToolType(i)) {
                MotionEvent.TOOL_TYPE_STYLUS, MotionEvent.TOOL_TYPE_ERASER -> return i
            }
        }
        return null
    }
}
