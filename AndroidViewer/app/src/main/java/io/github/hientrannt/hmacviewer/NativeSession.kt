package io.github.hientrannt.hmacviewer

/** The Rust protocol core (AndroidViewer/native). Handles are owned by [SessionActivity]. */
object NativeSession {
    init {
        System.loadLibrary("hmacviewer")
    }

    @JvmStatic external fun nativeInit(filesDir: String, deviceName: String)

    /** Starts a session in the background; 0 on failure (see [nativeLastError]). */
    @JvmStatic external fun nativeConnect(id: String, password: String, width: Int, height: Int): Long
    /** VNC (1) or RDP (2) session to [host]:[port] (0: default port); 0 if the protocol is unknown. */
    @JvmStatic external fun nativeConnectDirect(protocol: Int, host: String, port: Int, username: String,
                                                password: String, width: Int, height: Int): Long
    @JvmStatic external fun nativeLastError(): String

    /** Next event or null: `S:status`, `C:width:height`, `V:0|1`, `X:reason`. */
    @JvmStatic external fun nativePoll(handle: Long): String?

    /** Copies a new frame as ARGB into [out] (width × height); false when nothing changed. */
    @JvmStatic external fun nativeCopyFrame(handle: Long, out: IntArray): Boolean

    /** Draws a new frame into [bitmap] (ARGB_8888, screen size); false when nothing changed. */
    @JvmStatic external fun nativeDrawFrame(handle: Long, bitmap: android.graphics.Bitmap): Boolean

    /** Display quality 1-100 asked of the host (30 fast, 70 sharp). */
    @JvmStatic external fun nativeSetQuality(handle: Long, quality: Int)

    @JvmStatic external fun nativePointer(handle: Long, x: Int, y: Int)
    @JvmStatic external fun nativeButton(handle: Long, button: Int, pressed: Boolean, x: Int, y: Int)
    @JvmStatic external fun nativeScroll(handle: Long, steps: Float)
    @JvmStatic external fun nativeText(handle: Long, text: String)
    @JvmStatic external fun nativeKey(handle: Long, vk: Int, scan: Int, ch: Int, pressed: Boolean)
    @JvmStatic external fun nativeClose(handle: Long)
}

/** Windows virtual keys with their set-1 scan codes and reported characters. */
enum class RemoteKey(val vk: Int, val scan: Int, val ch: Int = 0) {
    BACKSPACE(0x08, 0x0e, 8), TAB(0x09, 0x0f, 9), ENTER(0x0d, 0x1c, 13), ESCAPE(0x1b, 0x01, 27),
    DELETE(0x2e, 0xe053), HOME(0x24, 0xe047), END(0x23, 0xe04f), PAGE_UP(0x21, 0xe049), PAGE_DOWN(0x22, 0xe051),
    LEFT(0x25, 0xe04b), UP(0x26, 0xe048), RIGHT(0x27, 0xe04d), DOWN(0x28, 0xe050),
    WINDOWS(0x5b, 0xe05b),
}
