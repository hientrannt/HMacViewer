package io.github.hientrannt.hmacviewer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.os.SystemClock
import android.text.InputType
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.ViewConfiguration
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
import kotlin.math.abs
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/** What the view asks the session to send; coordinates are remote screen pixels. */
interface RemoteInputSink {
    fun pointer(x: Int, y: Int)
    fun button(button: Int, pressed: Boolean, x: Int, y: Int)
    fun scroll(steps: Float)
    fun text(text: String)
    fun key(key: RemoteKey)
}

/**
 * Shows the remote screen and turns touches into mouse input.
 *
 * Touchpad mode (default) works like a laptop trackpad: sliding a finger
 * moves the cursor, tap clicks where the cursor is, two-finger tap
 * right-clicks, press-and-hold then slide drags. Direct mode clicks where the
 * finger touches. In both, two fingers scroll, pinch zooms around the cursor,
 * and a zoomed view follows the cursor.
 */
class RemoteScreenView(context: Context, private val sink: RemoteInputSink) : View(context) {
    var bitmap: Bitmap? = null
        set(value) {
            val resized = value?.width != field?.width || value?.height != field?.height
            field = value
            if (resized && value != null) { cursorX = value.width / 2f; cursorY = value.height / 2f; panX = 0f; panY = 0f }
            invalidate()
        }

    var touchpadMode = true
    /** Zoom over the fitted size, 1 to 6. */
    var zoom = 1f
        set(value) { field = value.coerceIn(1f, MAX_ZOOM); followCursor(); invalidate() }

    private val density = resources.displayMetrics.density
    private val slop = ViewConfiguration.get(context).scaledTouchSlop.toFloat()
    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val cursorFill = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
    private val cursorEdge = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK; style = Paint.Style.STROKE; strokeWidth = 1.5f * density; strokeJoin = Paint.Join.ROUND
    }
    private var panX = 0f
    private var panY = 0f
    private var cursorX = 0f
    private var cursorY = 0f

    // Gesture state.
    private var downX = 0f
    private var downY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var downTime = 0L
    private var moved = false
    private var holding = false
    private var multiTouch = false
    private var multiMoved = false
    private var multiStart = 0L
    private var lastFocusY = 0f
    private var scaled = false
    private var composing = ""

    private val holdStart = Runnable {
        if (moved || multiTouch) return@Runnable
        if (!touchpadMode) placeCursor(downX, downY)
        holding = true
        performHapticFeedback(HAPTIC_FEEDBACK_ENABLED)
        if (touchpadMode) {
            sink.button(0, true, cursorX.toInt(), cursorY.toInt())
        } else {
            // Direct mode: holding without moving is a right click.
            sink.button(1, true, cursorX.toInt(), cursorY.toInt())
            sink.button(1, false, cursorX.toInt(), cursorY.toInt())
        }
    }

    init {
        isFocusable = true
        isFocusableInTouchMode = true
    }

    private fun scale(b: Bitmap) = min(width / b.width.toFloat(), height / b.height.toFloat()) * zoom
    private fun originX(b: Bitmap) = (width - b.width * scale(b)) / 2 + panX
    private fun originY(b: Bitmap) = (height - b.height * scale(b)) / 2 + panY

    private fun clampPan() {
        val b = bitmap ?: return
        val s = scale(b)
        val spareX = max(0f, (b.width * s - width) / 2)
        val spareY = max(0f, (b.height * s - height) / 2)
        panX = panX.coerceIn(-spareX, spareX)
        panY = panY.coerceIn(-spareY, spareY)
    }

    /** Pans a zoomed view so the cursor stays inside a margin of the screen. */
    private fun followCursor() {
        val b = bitmap ?: return
        val s = scale(b)
        val margin = min(width, height) * 0.2f
        val x = originX(b) + cursorX * s
        val y = originY(b) + cursorY * s
        if (x < margin) panX += margin - x else if (x > width - margin) panX -= x - (width - margin)
        if (y < margin) panY += margin - y else if (y > height - margin) panY -= y - (height - margin)
        clampPan()
    }

    private fun placeCursor(viewX: Float, viewY: Float) {
        val b = bitmap ?: return
        val s = scale(b)
        cursorX = ((viewX - originX(b)) / s).coerceIn(0f, b.width - 1f)
        cursorY = ((viewY - originY(b)) / s).coerceIn(0f, b.height - 1f)
    }

    private fun moveCursorBy(dx: Float, dy: Float) {
        val b = bitmap ?: return
        // Faster finger movement travels further, like a trackpad.
        val speed = hypot(dx, dy) / density
        val gain = (1f + min(speed / 12f, 1.5f)) / scale(b)
        cursorX = (cursorX + dx * gain).coerceIn(0f, b.width - 1f)
        cursorY = (cursorY + dy * gain).coerceIn(0f, b.height - 1f)
    }

    private fun sendCursor() {
        sink.pointer(cursorX.toInt(), cursorY.toInt())
        followCursor()
        invalidate()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        clampPan()
    }

    override fun onDraw(canvas: Canvas) {
        canvas.drawColor(Color.BLACK)
        val b = bitmap ?: return
        val s = scale(b)
        canvas.save()
        canvas.translate(originX(b), originY(b))
        canvas.scale(s, s)
        canvas.drawBitmap(b, 0f, 0f, paint)
        canvas.restore()
        val x = originX(b) + cursorX * s
        val y = originY(b) + cursorY * s
        val d = density
        val arrow = Path().apply {
            moveTo(x, y); lineTo(x, y + 22 * d); lineTo(x + 5.5f * d, y + 17 * d)
            lineTo(x + 9.5f * d, y + 25.5f * d); lineTo(x + 13f * d, y + 24 * d)
            lineTo(x + 9f * d, y + 15.5f * d); lineTo(x + 16 * d, y + 15.5f * d); close()
        }
        canvas.drawPath(arrow, cursorFill)
        canvas.drawPath(arrow, cursorEdge)
    }

    private val scaler = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            val b = bitmap ?: return false
            scaled = true
            // Zoom around the cursor so the point being worked on stays put.
            val before = scale(b)
            val cx = originX(b) + cursorX * before
            val cy = originY(b) + cursorY * before
            zoom = (zoom * detector.scaleFactor).coerceIn(1f, MAX_ZOOM)
            val after = scale(b)
            panX += cx - (originX(b) + cursorX * after)
            panY += cy - (originY(b) + cursorY * after)
            clampPan()
            invalidate()
            return true
        }
    })

    override fun onTouchEvent(event: MotionEvent): Boolean {
        scaler.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x; downY = event.y; lastX = event.x; lastY = event.y
                downTime = SystemClock.uptimeMillis()
                moved = false; holding = false; multiTouch = false; scaled = false
                postDelayed(holdStart, HOLD_MS)
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                removeCallbacks(holdStart)
                if (!multiTouch) {
                    multiTouch = true; multiMoved = false; multiStart = SystemClock.uptimeMillis()
                }
                if (holding && touchpadMode) {
                    holding = false
                    sink.button(0, false, cursorX.toInt(), cursorY.toInt())
                }
                lastFocusY = focusY(event)
            }
            MotionEvent.ACTION_MOVE -> if (multiTouch) {
                if (event.pointerCount >= 2 && !scaler.isInProgress) {
                    val fy = focusY(event)
                    val dy = fy - lastFocusY
                    if (abs(dy) > 0.5f) multiMoved = true
                    // About one wheel step per 30 dp; fingers up scroll the content down.
                    if (!scaled) sink.scroll(dy / (30 * density))
                    lastFocusY = fy
                } else if (scaler.isInProgress) multiMoved = true
            } else {
                if (!moved && hypot(event.x - downX, event.y - downY) > slop) {
                    moved = true
                    removeCallbacks(holdStart)
                    if (!touchpadMode && !holding) {
                        // Direct mode: a drag presses where the finger went down.
                        placeCursor(downX, downY)
                        holding = true
                        sink.button(0, true, cursorX.toInt(), cursorY.toInt())
                    }
                }
                if (moved) {
                    if (touchpadMode) moveCursorBy(event.x - lastX, event.y - lastY) else placeCursor(event.x, event.y)
                    sendCursor()
                }
                lastX = event.x; lastY = event.y
            }
            MotionEvent.ACTION_POINTER_UP -> lastFocusY = focusY(event, excluding = event.actionIndex)
            MotionEvent.ACTION_UP -> {
                removeCallbacks(holdStart)
                val quick = SystemClock.uptimeMillis() - (if (multiTouch) multiStart else downTime) < TAP_MS
                when {
                    multiTouch -> if (!multiMoved && !scaled && quick) click(1)
                    holding -> if (touchpadMode || moved) sink.button(0, false, cursorX.toInt(), cursorY.toInt())
                    !moved && quick -> {
                        if (!touchpadMode) placeCursor(event.x, event.y)
                        click(0)
                    }
                }
                holding = false
            }
            MotionEvent.ACTION_CANCEL -> {
                removeCallbacks(holdStart)
                if (holding) sink.button(0, false, cursorX.toInt(), cursorY.toInt())
                holding = false
            }
        }
        return true
    }

    private fun click(button: Int) {
        val (x, y) = cursorX.toInt() to cursorY.toInt()
        sink.button(button, true, x, y)
        sink.button(button, false, x, y)
        followCursor()
        invalidate()
    }

    private fun focusY(e: MotionEvent, excluding: Int = -1): Float {
        var y = 0f
        var n = 0
        for (i in 0 until e.pointerCount) if (i != excluding) { y += e.getY(i); n++ }
        return if (n == 0) lastFocusY else y / n
    }

    // Soft keyboard: committed and composing text is typed on the remote
    // computer as it changes, so IME edits (Telex, autocorrect) are mirrored.
    override fun onCheckIsTextEditor() = true

    override fun onCreateInputConnection(outAttrs: EditorInfo): InputConnection {
        outAttrs.inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_NO_SUGGESTIONS
        outAttrs.imeOptions = EditorInfo.IME_FLAG_NO_EXTRACT_UI or EditorInfo.IME_FLAG_NO_FULLSCREEN
        composing = ""
        return object : BaseInputConnection(this, false) {
            override fun commitText(text: CharSequence, newCursorPosition: Int): Boolean {
                replaceComposing(text.toString()); composing = ""; return true
            }
            override fun setComposingText(text: CharSequence, newCursorPosition: Int): Boolean {
                replaceComposing(text.toString()); composing = text.toString(); return true
            }
            override fun finishComposingText(): Boolean { composing = ""; return true }
            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                repeat(beforeLength) { sink.key(RemoteKey.BACKSPACE) }
                repeat(afterLength) { sink.key(RemoteKey.DELETE) }
                return true
            }
            override fun sendKeyEvent(event: KeyEvent): Boolean {
                if (event.action == KeyEvent.ACTION_DOWN) typeKey(event)
                return true
            }
        }
    }

    private fun replaceComposing(next: String) {
        val common = composing.commonPrefixWith(next).length
        repeat(composing.length - common) { sink.key(RemoteKey.BACKSPACE) }
        val added = next.substring(common)
        when {
            added == "\n" -> sink.key(RemoteKey.ENTER)
            added.isNotEmpty() -> sink.text(added)
        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent): Boolean {
        if (keyCode == KeyEvent.KEYCODE_BACK) return super.onKeyDown(keyCode, event)
        return typeKey(event) || super.onKeyDown(keyCode, event)
    }

    private fun typeKey(event: KeyEvent): Boolean {
        val key = when (event.keyCode) {
            KeyEvent.KEYCODE_DEL -> RemoteKey.BACKSPACE
            KeyEvent.KEYCODE_FORWARD_DEL -> RemoteKey.DELETE
            KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_NUMPAD_ENTER -> RemoteKey.ENTER
            KeyEvent.KEYCODE_TAB -> RemoteKey.TAB
            KeyEvent.KEYCODE_ESCAPE -> RemoteKey.ESCAPE
            KeyEvent.KEYCODE_DPAD_LEFT -> RemoteKey.LEFT
            KeyEvent.KEYCODE_DPAD_RIGHT -> RemoteKey.RIGHT
            KeyEvent.KEYCODE_DPAD_UP -> RemoteKey.UP
            KeyEvent.KEYCODE_DPAD_DOWN -> RemoteKey.DOWN
            KeyEvent.KEYCODE_MOVE_HOME -> RemoteKey.HOME
            KeyEvent.KEYCODE_MOVE_END -> RemoteKey.END
            KeyEvent.KEYCODE_PAGE_UP -> RemoteKey.PAGE_UP
            KeyEvent.KEYCODE_PAGE_DOWN -> RemoteKey.PAGE_DOWN
            else -> null
        }
        if (key != null) { sink.key(key); return true }
        val ch = event.unicodeChar
        if (ch > 0) { sink.text(String(Character.toChars(ch))); return true }
        return false
    }

    private companion object {
        const val MAX_ZOOM = 6f
        const val HOLD_MS = 450L
        const val TAP_MS = 300L
    }
}
