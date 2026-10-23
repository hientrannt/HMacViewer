//! C interface for the Apple apps (see include/remotecore.h). Every call is
//! non-blocking; a handle stays valid until `rc_close`, which frees it.

use std::ffi::{c_char, CStr};

use crate::{ConnectParams, Event, Key, Protocol, Session};

pub struct RcSession(Session);

unsafe fn text(s: *const c_char) -> String {
    if s.is_null() { String::new() } else { CStr::from_ptr(s).to_string_lossy().into_owned() }
}

/// protocol: 1 VNC, 2 RDP. port 0 uses the protocol's default. Never null for a known protocol.
#[no_mangle]
pub unsafe extern "C" fn rc_connect(protocol: i32, host: *const c_char, port: u16, username: *const c_char,
                                    password: *const c_char, width: u32, height: u32) -> *mut RcSession {
    let protocol = match protocol { 1 => Protocol::Vnc, 2 => Protocol::Rdp, _ => return std::ptr::null_mut() };
    let session = Session::connect(ConnectParams {
        protocol, host: text(host).trim().to_string(),
        port: if port == 0 { protocol.default_port() } else { port },
        username: text(username), password: text(password), width: width.max(1), height: height.max(1),
    });
    Box::into_raw(Box::new(RcSession(session)))
}

/// Next event: 0 none, 1 status, 2 connected (width/height set), 3 closed.
/// Status and close text is written NUL-terminated into `buffer`, truncated to `capacity`.
#[no_mangle]
pub unsafe extern "C" fn rc_poll_event(session: *const RcSession, buffer: *mut c_char, capacity: usize,
                                       width: *mut u32, height: *mut u32) -> i32 {
    let Some(s) = session.as_ref() else { return 0 };
    let (kind, message) = match s.0.poll_event() {
        None => return 0,
        Some(Event::Status(t)) => (1, t),
        Some(Event::Connected { width: w, height: h }) => {
            if !width.is_null() { *width = w }
            if !height.is_null() { *height = h }
            (2, String::new())
        }
        Some(Event::Closed(t)) => (3, t),
    };
    if !buffer.is_null() && capacity > 0 {
        let mut bytes = message.into_bytes();
        bytes.truncate(capacity - 1);
        while std::str::from_utf8(&bytes).is_err() { bytes.pop(); }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer as *mut u8, bytes.len());
        *buffer.add(bytes.len()) = 0;
    }
    kind
}

/// If the screen changed, copies it into `pixels` (32-bit little-endian
/// xRGB, rows of `width`) when `capacity` (in pixels) is enough, and returns 1.
/// Always reports the current size; returns 0 when nothing new was copied.
#[no_mangle]
pub unsafe extern "C" fn rc_copy_frame(session: *const RcSession, pixels: *mut u32, capacity: usize,
                                       width: *mut u32, height: *mut u32) -> i32 {
    let Some(s) = session.as_ref() else { return 0 };
    let copied = s.0.with_new_frame(|f| {
        if !width.is_null() { *width = f.width }
        if !height.is_null() { *height = f.height }
        if pixels.is_null() || capacity < f.pixels.len() { return false }
        std::ptr::copy_nonoverlapping(f.pixels.as_ptr(), pixels, f.pixels.len());
        true
    });
    match copied {
        Some(true) => 1,
        Some(false) => { s.0.redraw_later(); 0 }
        None => 0,
    }
}

/// buttons: bit 0 left, 1 middle, 2 right.
#[no_mangle]
pub unsafe extern "C" fn rc_pointer(session: *const RcSession, x: u32, y: u32, buttons: u8) {
    if let Some(s) = session.as_ref() { s.0.pointer(x, y, buttons) }
}

/// Wheel steps, positive scrolls up.
#[no_mangle]
pub unsafe extern "C" fn rc_scroll(session: *const RcSession, steps: f32) {
    if let Some(s) = session.as_ref() { if steps.is_finite() { s.0.scroll(steps) } }
}

/// key: index into the RC_KEY_* list in remotecore.h.
#[no_mangle]
pub unsafe extern "C" fn rc_key(session: *const RcSession, key: i32, down: bool) {
    use Key::*;
    const KEYS: [Key; 17] = [Backspace, Tab, Enter, Escape, Delete, Home, End, PageUp, PageDown,
                             Left, Up, Right, Down, Windows, Shift, Control, Alt];
    if let (Some(s), Some(&k)) = (session.as_ref(), usize::try_from(key).ok().and_then(|i| KEYS.get(i))) {
        s.0.key(k, down)
    }
}

/// UTF-8 text typed on the remote computer.
#[no_mangle]
pub unsafe extern "C" fn rc_text(session: *const RcSession, utf8: *const c_char) {
    if let Some(s) = session.as_ref() { s.0.text(&text(utf8)) }
}

/// Disconnects and frees the session.
#[no_mangle]
pub unsafe extern "C" fn rc_close(session: *mut RcSession) {
    if !session.is_null() {
        let s = Box::from_raw(session);
        s.0.close();
    }
}
