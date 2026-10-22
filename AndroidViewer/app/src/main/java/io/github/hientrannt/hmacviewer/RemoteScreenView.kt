package io.github.hientrannt.hmacviewer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.text.InputType
import android.view.GestureDetector
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.ScaleGestureDetector
import android.view.View
import android.view.inputmethod.BaseInputConnection
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection
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
 * Shows the remote screen fitted to the view (pinch to zoom, two fingers to
 * pan when zoomed or scroll otherwise) and turns touches into mouse input:
 * tap clicks, long press right-clicks, one-finger drag drags.
 */
class RemoteScreenView(context: Context, private val sink: RemoteInputSink) : View(context) {
    var bitmap: Bitmap? = null
        set(value) { field = value; zoom = 1f; panX = 0f; panY = 0f; invalidate() }

    private val paint = Paint(Paint.FILTER_BITMAP_FLAG)
    private val pointerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Color.WHITE }
    private val pointerOutline = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Color.BLACK; style = Paint.Style.STROKE; strokeWidth = 2f
    }
    private var zoom = 1f
    private var panX = 0f
    private var panY = 0f
    private var pointer: Pair<Int, Int>? = null
    private var dragging = false
    private var multiTouch = false
    private var lastFocus: Pair<Float, Float>? = null
    private var composing = ""

    init {
        isFocusable = true
        isFocusableInTouchMode = true
    }

    // Fit scale and the top-left of the drawn image, in view pixels.
    private fun scale(b: Bitmap) = min(width / b.width.toFloat(), height / b.height.toFloat()) * zoom
    private fun originX(b: Bitmap) = (width - b.width * scale(b)) / 2 + panX
    private fun originY(b: Bitmap) = (height - b.height * scale(b)) / 2 + panY

    private fun toRemote(x: Float, y: Float): Pair<Int, Int>? {
        val b = bitmap ?: return null
        val s = scale(b)
        val rx = ((x - originX(b)) / s).toInt().coerceIn(0, b.width - 1)
        val ry = ((y - originY(b)) / s).toInt().coerceIn(0, b.height - 1)
        return rx to ry
    }

    private fun clampPan() {
        val b = bitmap ?: return
        val s = scale(b)
        val spareX = max(0f, (b.width * s - width) / 2)
        val spareY = max(0f, (b.height * s - height) / 2)
        panX = panX.coerceIn(-spareX, spareX)
        panY = panY.coerceIn(-spareY, spareY)
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
        pointer?.let { (rx, ry) ->
            val x = originX(b) + rx * s
            val y = originY(b) + ry * s
            val d = resources.displayMetrics.density
            val arrow = Path().apply {
                moveTo(x, y); lineTo(x, y + 18 * d); lineTo(x + 5 * d, y + 13 * d)
                lineTo(x + 12 * d, y + 13 * d); close()
            }
            canvas.drawPath(arrow, pointerPaint)
            canvas.drawPath(arrow, pointerOutline)
        }
    }

    private val gestures = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onDown(e: MotionEvent) = true

        override fun onSingleTapUp(e: MotionEvent): Boolean {
            val p = toRemote(e.x, e.y) ?: return false
            pointer = p
            sink.button(0, true, p.first, p.second)
            sink.button(0, false, p.first, p.second)
            invalidate()
            return true
        }

        override fun onLongPress(e: MotionEvent) {
            if (multiTouch || dragging) return
            val p = toRemote(e.x, e.y) ?: return
            pointer = p
            performHapticFeedback(HAPTIC_FEEDBACK_ENABLED)
            sink.button(1, true, p.first, p.second)
            sink.button(1, false, p.first, p.second)
            invalidate()
        }

        override fun onScroll(e1: MotionEvent?, e2: MotionEvent, dx: Float, dy: Float): Boolean {
            if (multiTouch || e2.pointerCount > 1) return false
            val p = toRemote(e2.x, e2.y) ?: return false
            if (!dragging) {
                val start = e1?.let { toRemote(it.x, it.y) } ?: p
                dragging = true
                sink.button(0, true, start.first, start.second)
            }
            pointer = p
            sink.pointer(p.first, p.second)
            invalidate()
            return true
        }
    }).apply { setIsLongpressEnabled(true) }

    private val scaler = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            val b = bitmap ?: return false
            val before = scale(b)
            zoom = (zoom * detector.scaleFactor).coerceIn(1f, 6f)
            val ratio = scale(b) / before
            // Keep the content under the fingers in place.
            val cx = width / 2f
            val cy = height / 2f
            panX = (panX + cx - detector.focusX) * ratio - cx + detector.focusX
            panY = (panY + cy - detector.focusY) * ratio - cy + detector.focusY
            clampPan()
            invalidate()
            return true
        }
    })

    override fun onTouchEvent(event: MotionEvent): Boolean {
        scaler.onTouchEvent(event)
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> { multiTouch = false; lastFocus = null }
            MotionEvent.ACTION_POINTER_DOWN -> {
                multiTouch = true
                endDrag(event)
                lastFocus = focus(event)
            }
            MotionEvent.ACTION_MOVE -> if (multiTouch && event.pointerCount >= 2) {
                val (fx, fy) = focus(event)
                lastFocus?.let { (lx, ly) ->
                    if (zoom > 1.01f) {
                        panX += fx - lx; panY += fy - ly; clampPan(); invalidate()
                    } else {
                        // About one wheel step per 40 dp, finger up scrolls content down.
                        sink.scroll((fy - ly) / (40 * resources.displayMetrics.density))
                    }
                }
                lastFocus = fx to fy
            }
            MotionEvent.ACTION_POINTER_UP -> lastFocus = null
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> endDrag(event)
        }
        if (!multiTouch) gestures.onTouchEvent(event)
        return true
    }

    private fun focus(e: MotionEvent): Pair<Float, Float> {
        var x = 0f
        var y = 0f
        for (i in 0 until e.pointerCount) { x += e.getX(i); y += e.getY(i) }
        return x / e.pointerCount to y / e.pointerCount
    }

    private fun endDrag(e: MotionEvent) {
        if (!dragging) return
        dragging = false
        val p = pointer ?: toRemote(e.x, e.y) ?: return
        sink.button(0, false, p.first, p.second)
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
}
