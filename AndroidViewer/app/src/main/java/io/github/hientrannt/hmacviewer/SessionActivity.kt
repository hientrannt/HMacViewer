package io.github.hientrannt.hmacviewer

import android.app.Activity
import android.app.AlertDialog
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Toast
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/** One remote session: full screen, landscape, with a small floating toolbar. */
class SessionActivity : Activity(), RemoteInputSink {
    private var handle = 0L
    // Input is written to the socket in order, off the UI thread.
    private val sender: ExecutorService = Executors.newSingleThreadExecutor()
    private lateinit var screen: RemoteScreenView
    private lateinit var status: TextView
    private lateinit var toolbar: LinearLayout
    private var frameBitmap: Bitmap? = null
    private var ended = false
    private var zoomedOnce = false
    private var sharpImage = false
    private var directSession = false
    // Only the newest pointer position waits to be sent; older moves are dropped.
    private val pendingPointer = AtomicReference<Pair<Int, Int>?>(null)

    private val tick = object : Runnable {
        override fun run() {
            if (handle == 0L) return
            pollEvents()
            val bitmap = frameBitmap
            if (handle != 0L && bitmap != null && NativeSession.nativeDrawFrame(handle, bitmap)) {
                status.visibility = View.GONE
                screen.invalidate()
            }
            screen.postOnAnimation(this)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val dp = resources.displayMetrics.density
        screen = RemoteScreenView(this, this)
        status = TextView(this).apply {
            setTextColor(Color.WHITE); textSize = 16f; gravity = Gravity.CENTER
            text = getString(R.string.connecting)
        }
        toolbar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            setBackgroundColor(0xB0202030.toInt())
            setPadding((4 * dp).toInt(), 0, (4 * dp).toInt(), 0)
        }
        fun tool(label: String, action: () -> Unit) = Button(this, null, android.R.attr.borderlessButtonStyle).apply {
            text = label; setTextColor(Color.WHITE); isAllCaps = false; minWidth = 0; minimumWidth = 0
            setPadding((10 * dp).toInt(), 0, (10 * dp).toInt(), 0)
            setOnClickListener { action() }
            toolbar.addView(this)
        }
        tool("⌨ " + getString(R.string.keyboard)) { toggleKeyboard() }
        lateinit var modeButton: Button
        modeButton = tool(getString(R.string.mode_touchpad)) {
            screen.touchpadMode = !screen.touchpadMode
            modeButton.text = getString(if (screen.touchpadMode) R.string.mode_touchpad else R.string.mode_direct)
        }
        tool("🔍 " + getString(R.string.zoom)) { screen.zoom = if (screen.zoom > 1.05f) 1f else 2.5f }
        lateinit var qualityButton: Button
        qualityButton = tool(getString(R.string.quality_fast)) {
            sharpImage = !sharpImage
            qualityButton.text = getString(if (sharpImage) R.string.quality_sharp else R.string.quality_fast)
            onSender { NativeSession.nativeSetQuality(it, if (sharpImage) 70 else 30) }
        }
        // VNC and RDP pick their own image quality.
        if (intent.getIntExtra(EXTRA_PROTOCOL, Protocol.ULTRAVIEWER.code) != Protocol.ULTRAVIEWER.code) {
            qualityButton.visibility = View.GONE
        }
        tool("Esc") { key(RemoteKey.ESCAPE) }
        tool("Tab") { key(RemoteKey.TAB) }
        tool("⊞ Win") { key(RemoteKey.WINDOWS) }
        tool("←") { key(RemoteKey.LEFT) }
        tool("→") { key(RemoteKey.RIGHT) }
        tool("↑") { key(RemoteKey.UP) }
        tool("↓") { key(RemoteKey.DOWN) }
        tool("✕ " + getString(R.string.disconnect)) { confirmDisconnect() }
        val handleButton = Button(this, null, android.R.attr.borderlessButtonStyle).apply {
            text = "⋯"; setTextColor(Color.WHITE); textSize = 20f; setBackgroundColor(0x80202030.toInt())
            setOnClickListener { toolbar.visibility = if (toolbar.visibility == View.VISIBLE) View.GONE else View.VISIBLE }
        }
        setContentView(FrameLayout(this).apply {
            addView(screen)
            addView(status, FrameLayout.LayoutParams(-1, -1))
            addView(toolbar, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.CENTER_HORIZONTAL))
            addView(handleButton, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.END))
        })
        enterImmersive()
        Toast.makeText(this, R.string.help, Toast.LENGTH_LONG).show()

        val id = intent.getStringExtra(EXTRA_ID).orEmpty()
        val password = intent.getStringExtra(EXTRA_PASSWORD).orEmpty()
        val protocol = intent.getIntExtra(EXTRA_PROTOCOL, Protocol.ULTRAVIEWER.code)
        directSession = protocol != Protocol.ULTRAVIEWER.code
        val metrics = resources.displayMetrics
        val (w, h) = max(metrics.widthPixels, metrics.heightPixels) to min(metrics.widthPixels, metrics.heightPixels)
        handle = if (!directSession) {
            NativeSession.nativeConnect(id, password, w, h)
        } else {
            // "host:port" or just "host" (the protocol's default port).
            val (host, port) = splitHostPort(id)
            NativeSession.nativeConnectDirect(protocol, host, port, intent.getStringExtra(EXTRA_USER).orEmpty(), password, w, h)
        }
        if (handle == 0L) {
            showEnded(NativeSession.nativeLastError())
        } else {
            screen.postOnAnimation(tick)
        }
    }

    private fun max(a: Int, b: Int) = if (a > b) a else b
    private fun min(a: Int, b: Int) = if (a < b) a else b

    private fun pollEvents() {
        while (handle != 0L) {
            val event = NativeSession.nativePoll(handle) ?: return
            val body = event.substring(2)
            when (event[0]) {
                'S' -> status.text = body
                'C' -> {
                    val (w, h) = body.split(':').map { it.toInt() }
                    if (frameBitmap?.width != w || frameBitmap?.height != h) {
                        frameBitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                        screen.bitmap = frameBitmap
                    }
                    // On a phone a whole desktop is tiny: start zoomed in around the cursor.
                    if (!zoomedOnce && resources.configuration.smallestScreenWidthDp < 600) {
                        zoomedOnce = true
                        screen.zoom = 2f
                    }
                }
                'V' -> if (body == "1") Toast.makeText(this, R.string.view_only, Toast.LENGTH_LONG).show()
                'X' -> { closeSession(); showEnded(body); return }
            }
        }
    }

    private fun enterImmersive() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.insetsController?.let {
                it.hide(WindowInsets.Type.systemBars())
                it.systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (View.SYSTEM_UI_FLAG_FULLSCREEN or View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY or View.SYSTEM_UI_FLAG_LAYOUT_STABLE)
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterImmersive()
    }

    private fun toggleKeyboard() {
        val ime = getSystemService(INPUT_METHOD_SERVICE) as InputMethodManager
        screen.requestFocus()
        @Suppress("DEPRECATION")
        ime.toggleSoftInput(InputMethodManager.SHOW_FORCED, 0)
    }

    private fun confirmDisconnect() {
        AlertDialog.Builder(this)
            .setMessage(R.string.disconnect_question)
            .setPositiveButton(R.string.disconnect) { _, _ -> closeSession(); finish() }
            .setNegativeButton(R.string.cancel, null)
            .show()
    }

    @Deprecated("Back confirms disconnecting")
    override fun onBackPressed() = confirmDisconnect()

    private fun showEnded(reason: String) {
        if (ended || isFinishing) return
        ended = true
        AlertDialog.Builder(this)
            .setTitle(R.string.session_ended)
            .setMessage(reason)
            .setCancelable(false)
            .setPositiveButton(R.string.ok) { _, _ -> finish() }
            .show()
    }

    private fun closeSession() {
        val h = handle
        if (h == 0L) return
        handle = 0L
        sender.execute { NativeSession.nativeClose(h) }
    }

    override fun onDestroy() {
        closeSession()
        sender.shutdown()
        super.onDestroy()
    }

    private fun onSender(block: (Long) -> Unit) {
        val h = handle
        if (h != 0L) sender.execute { block(h) }
    }

    override fun pointer(x: Int, y: Int) {
        if (pendingPointer.getAndSet(x to y) == null) {
            onSender { h -> pendingPointer.getAndSet(null)?.let { (px, py) -> NativeSession.nativePointer(h, px, py) } }
        }
    }
    override fun button(button: Int, pressed: Boolean, x: Int, y: Int) =
        onSender { NativeSession.nativeButton(it, button, pressed, x, y) }
    override fun scroll(steps: Float) = onSender { NativeSession.nativeScroll(it, steps) }
    override fun text(text: String) = onSender { NativeSession.nativeText(it, text) }
    override fun key(key: RemoteKey) = onSender {
        NativeSession.nativeKey(it, key.vk, key.scan, key.ch, true)
        NativeSession.nativeKey(it, key.vk, key.scan, key.ch, false)
    }

    companion object {
        const val EXTRA_ID = "id"
        const val EXTRA_PASSWORD = "password"
        const val EXTRA_PROTOCOL = "protocol"
        const val EXTRA_USER = "user"

        /** Splits "host:port" (or "[v6]:port"); 0 means the protocol's default port. */
        fun splitHostPort(text: String): Pair<String, Int> {
            val t = text.trim()
            if (t.startsWith("[")) {
                val end = t.indexOf(']')
                if (end > 0) return t.substring(1, end) to (t.substring(end + 1).removePrefix(":").toIntOrNull() ?: 0)
            }
            val colon = t.lastIndexOf(':')
            if (colon > 0 && t.indexOf(':') == colon) return t.substring(0, colon) to (t.substring(colon + 1).toIntOrNull() ?: 0)
            return t to 0
        }
    }
}
