//! JNI surface for `io.github.hientrannt.hmacviewer.NativeSession`. The
//! protocol, TLS relay and screen decoding are LinuxViewer's; this file only
//! queues session events for the UI thread, copies frames out and encodes
//! touch and IME input as Windows mouse/keyboard messages.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use jni::objects::{JClass, JIntArray, JString};
use jni::sys::{jboolean, jfloat, jint, jlong, jstring, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;
use linuxviewer::client::{self, ClientEvent, ClientSession, ConnectOptions};
use linuxviewer::input::{self, KEY_DOWN, KEY_UP};
use linuxviewer::profile::Profile;

static LAST_ERROR: Mutex<String> = Mutex::new(String::new());

/// Events for the UI, polled as short tagged strings:
/// `S:<status>`, `C:<width>:<height>`, `V:<0|1>` (view only), `X:<reason>` (closed).
struct Session {
    session: ClientSession,
    events: Arc<Mutex<VecDeque<String>>>,
    frame_dirty: Arc<AtomicBool>,
    mouse: Mutex<Mouse>,
}

/// Pointer state for MouseMessage flags (MacRemoteInputEncoder's mouse half).
#[derive(Default)]
struct Mouse {
    buttons: u8,
    position: (i32, i32),
    origin: (i32, i32),
    binary_keyboard: bool,
    wheel_remainder: f32,
}

impl Mouse {
    fn flags(&self) -> i32 {
        let mut f = 0;
        if self.buttons & 1 != 0 { f |= 0x01; }
        if self.buttons & 2 != 0 { f |= 0x02; }
        if self.buttons & 4 != 0 { f |= 0x10; }
        f
    }

    fn packed(&self) -> i32 {
        input::packed_position(self.position.0 as i16, self.position.1 as i16)
    }

    fn remote(&self, x: i32, y: i32) -> (i32, i32) {
        (x + self.origin.0, y + self.origin.1)
    }
}

fn session<'a>(handle: jlong) -> Option<&'a Session> {
    // SAFETY: handles come from `nativeConnect` and stay valid until `nativeClose`.
    (handle != 0).then(|| unsafe { &*(handle as *const Session) })
}

fn string(env: &mut JNIEnv, s: &JString) -> String {
    env.get_string(s).map(Into::into).unwrap_or_default()
}

fn send(s: &Session, payloads: Vec<Vec<u8>>) {
    if s.session.is_view_only() {
        return;
    }
    for p in payloads {
        s.session.send_input(p);
    }
}

#[no_mangle]
pub extern "system" fn Java_io_github_hientrannt_hmacviewer_NativeSession_nativeInit(
    mut env: JNIEnv, _: JClass, files_dir: JString, device_name: JString) {
    // Profile keeps its ID under $XDG_CONFIG_HOME/linuxviewer; the name is shown to the partner.
    std::env::set_var("XDG_CONFIG_HOME", string(&mut env, &files_dir));
    std::env::set_var("HOME", string(&mut env, &files_dir));
    let name = string(&mut env, &device_name);
    if !name.is_empty() {
        std::env::set_var("LINUXVIEWER_NAME", name);
    }
}

#[no_mangle]
pub extern "system" fn Java_io_github_hientrannt_hmacviewer_NativeSession_nativeConnect(
    mut env: JNIEnv, _: JClass, id: JString, password: JString, width: jint, height: jint) -> jlong {
    let (id, password) = (string(&mut env, &id), string(&mut env, &password));
    let id: String = id.chars().filter(|c| !c.is_whitespace()).collect();
    let result = Profile::load_or_create().and_then(|profile| {
        let events: Arc<Mutex<VecDeque<String>>> = Arc::default();
        let frame_dirty = Arc::new(AtomicBool::new(false));
        let (queue, dirty) = (events.clone(), frame_dirty.clone());
        let options = ConnectOptions {
            local_screen: Some((width.max(1) as u32, height.max(1) as u32)),
            ..Default::default()
        };
        let session = client::connect_with(&profile, &id, &password, options, Box::new(move |event| {
            let line = match event {
                ClientEvent::Status(s) => format!("S:{s}"),
                ClientEvent::Connected { width, height } => format!("C:{width}:{height}"),
                ClientEvent::FrameReady => {
                    dirty.store(true, Ordering::SeqCst);
                    return;
                }
                ClientEvent::ViewOnly(v) => format!("V:{}", v as u8),
                ClientEvent::Closed(reason) => format!("X:{reason}"),
                _ => return,
            };
            queue.lock().unwrap().push_back(line);
        }))?;
        Ok(Session { session, events, frame_dirty, mouse: Mutex::default() })
    });
    match result {
        Ok(s) => Box::into_raw(Box::new(s)) as jlong,
        Err(e) => {
            *LAST_ERROR.lock().unwrap() = e.to_string();
            0
        }
    }
}

#[no_mangle]
pub extern "system" fn Java_io_github_hientrannt_hmacviewer_NativeSession_nativeLastError(
    env: JNIEnv, _: JClass) -> jstring {
    let message = LAST_ERROR.lock().unwrap().clone();
    env.new_string(message).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut())
}

/// The next queued event, or null. A `C:` event also refreshes the
/// coordinate origin and whether the partner accepts keyboard input.
#[no_mangle]
pub extern "system" fn Java_io_github_hientrannt_hmacviewer_NativeSession_nativePoll(
    env: JNIEnv, _: JClass, handle: jlong) -> jstring {
    let Some(s) = session(handle) else { return std::ptr::null_mut() };
    let Some(line) = s.events.lock().unwrap().pop_front() else { return std::ptr::null_mut() };
    if line.starts_with("C:") {
        let origin = s.session.screen.lock().ok()
            .and_then(|r| r.as_ref().map(|r| r.init().origin()))
            .unwrap_or((0, 0));
        let mut mouse = s.mouse.lock().unwrap();
        mouse.origin = origin;
        mouse.binary_keyboard = input::supports_binary_keyboard(&s.session.partner_version());
        drop(mouse);
        // Ask for cursor positions after every init, as the desktop viewers do.
        s.session.send_command(b"28|||1".to_vec(), false);
    }
    env.new_string(line).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut())
}

/// Copies the screen as ARGB ints when a new frame arrived and `out` matches
/// its size. Returns whether `out` changed.
#[no_mangle]
pub extern "system" fn Java_io_github_hientrannt_hmacviewer_NativeSession_nativeCopyFrame(
    env: JNIEnv, _: JClass, handle: jlong, out: JIntArray) -> jboolean {
    let Some(s) = session(handle) else { return JNI_FALSE };
    if !s.frame_dirty.swap(false, Ordering::SeqCst) {
        return JNI_FALSE;
    }
    let Ok(guard) = s.session.screen.lock() else { return JNI_FALSE };
    let Some(renderer) = guard.as_ref() else { return JNI_FALSE };
    let pixels = renderer.pixels();
    if env.get_array_length(&out).ok().map(|n| n as usize) != Some(pixels.len()) {
        s.frame_dirty.store(true, Ordering::SeqCst);
        return JNI_FALSE;
    }
    let argb: Vec<jint> = pixels.iter().map(|p| (p | 0xff00_0000) as jint).collect();
    drop(guard);
    if env.set_int_array_region(&out, 0, &argb).is_err() {
        return JNI_FALSE;
    }
    JNI_TRUE
}

#[no_mangle]
pub extern "system" fn Java_io_github_hientrannt_hmacviewer_NativeSession_nativePointer(
    _: JNIEnv, _: JClass, handle: jlong, x: jint, y: jint) {
    let Some(s) = session(handle) else { return };
    let mut m = s.mouse.lock().unwrap();
    m.position = m.remote(x, y);
    let payload = input::mouse_move(m.flags(), m.position.0, m.position.1);
    drop(m);
    send(s, vec![payload]);
}

/// button: 0 left, 1 right, 2 middle.
#[no_mangle]
pub extern "system" fn Java_io_github_hientrannt_hmacviewer_NativeSession_nativeButton(
    _: JNIEnv, _: JClass, handle: jlong, button: jint, pressed: jboolean, x: jint, y: jint) {
    let Some(s) = session(handle) else { return };
    let pressed = pressed != JNI_FALSE;
    let (msg, bit) = match (button, pressed) {
        (0, true) => (input::WM_LBUTTONDOWN, 1), (0, false) => (input::WM_LBUTTONUP, 1),
        (1, true) => (input::WM_RBUTTONDOWN, 2), (1, false) => (input::WM_RBUTTONUP, 2),
        (2, true) => (input::WM_MBUTTONDOWN, 4), (2, false) => (input::WM_MBUTTONUP, 4),
        _ => return,
    };
    let mut m = s.mouse.lock().unwrap();
    m.position = m.remote(x, y);
    let mut out = vec![input::mouse_move(m.flags(), m.position.0, m.position.1)];
    if pressed { m.buttons |= bit } else { m.buttons &= !bit }
    out.push(input::mouse_button(msg, m.flags(), m.packed()));
    drop(m);
    send(s, out);
}

/// Wheel steps at the last pointer position (positive scrolls up); fractions carry over.
#[no_mangle]
pub extern "system" fn Java_io_github_hientrannt_hmacviewer_NativeSession_nativeScroll(
    _: JNIEnv, _: JClass, handle: jlong, steps: jfloat) {
    let Some(s) = session(handle) else { return };
    if !steps.is_finite() {
        return;
    }
    let mut m = s.mouse.lock().unwrap();
    let total = m.wheel_remainder + steps.clamp(-64.0, 64.0);
    let whole = total.trunc();
    m.wheel_remainder = total - whole;
    if whole == 0.0 {
        return;
    }
    let payload = input::mouse_wheel(input::wheel_wparam((whole * 120.0) as i16, m.flags() as u16), m.packed());
    drop(m);
    send(s, vec![payload]);
}

/// Typed text as Unicode key packets (needs a partner from 6.2.13 on).
#[no_mangle]
pub extern "system" fn Java_io_github_hientrannt_hmacviewer_NativeSession_nativeText(
    mut env: JNIEnv, _: JClass, handle: jlong, text: JString) {
    let Some(s) = session(handle) else { return };
    if !s.mouse.lock().unwrap().binary_keyboard {
        return;
    }
    let text = string(&mut env, &text);
    send(s, input::text_packets(&text, false));
}

/// A Windows virtual key; `ch` is the character Windows reports with it (0 if none).
#[no_mangle]
pub extern "system" fn Java_io_github_hientrannt_hmacviewer_NativeSession_nativeKey(
    _: JNIEnv, _: JClass, handle: jlong, vk: jint, scan: jint, ch: jint, pressed: jboolean) {
    let Some(s) = session(handle) else { return };
    if !s.mouse.lock().unwrap().binary_keyboard {
        return;
    }
    let kind = if pressed != JNI_FALSE { KEY_DOWN } else { KEY_UP };
    send(s, vec![input::keyboard(kind, vk as u8, scan as u16, ch as u16, false)]);
}

/// Disconnects and frees the session; the handle must not be used again.
#[no_mangle]
pub extern "system" fn Java_io_github_hientrannt_hmacviewer_NativeSession_nativeClose(
    _: JNIEnv, _: JClass, handle: jlong) {
    if handle == 0 {
        return;
    }
    // SAFETY: the handle came from Box::into_raw in nativeConnect and is closed once.
    let s = unsafe { Box::from_raw(handle as *mut Session) };
    s.session.close();
}
