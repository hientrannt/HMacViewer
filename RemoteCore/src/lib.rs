//! Viewer sessions over open protocols (VNC, and RDP to come), with one
//! front-end surface for every app: queued events, a shared 0x00RRGGBB
//! framebuffer with a dirty flag, and mouse/keyboard commands. Each session
//! runs its protocol on its own thread; calls from the UI never block on
//! the network.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

pub mod ffi;
mod rdp;
mod vnc;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Protocol {
    Vnc,
    Rdp,
}

impl Protocol {
    pub fn default_port(self) -> u16 {
        match self {
            Protocol::Vnc => 5900,
            Protocol::Rdp => 3389,
        }
    }
}

#[derive(Clone, Debug)]
pub struct ConnectParams {
    pub protocol: Protocol,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub password: String,
    /// This device's screen size, for protocols that size the remote desktop.
    pub width: u32,
    pub height: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Status(String),
    /// The remote screen is this size; the framebuffer was reallocated.
    Connected { width: u32, height: u32 },
    Closed(String),
}

/// Keys the apps offer besides typed text.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Key {
    Backspace, Tab, Enter, Escape, Delete, Home, End, PageUp, PageDown,
    Left, Up, Right, Down, Windows,
    /// Modifiers, held while other keys or text go out (shortcuts).
    Shift, Control, Alt,
}

/// Mouse buttons as a bit mask.
pub const BUTTON_LEFT: u8 = 1;
pub const BUTTON_MIDDLE: u8 = 2;
pub const BUTTON_RIGHT: u8 = 4;

/// The remote screen, top-down 0x00RRGGBB pixels.
#[derive(Default)]
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u32>,
}

impl Frame {
    fn resize(&mut self, width: u32, height: u32) {
        self.width = width;
        self.height = height;
        self.pixels = vec![0; width as usize * height as usize];
    }

    /// Copies `w`×`h` pixels from `source` (row length `w`) to (x, y), clipped.
    fn blit(&mut self, x: u32, y: u32, w: u32, h: u32, source: impl Fn(usize) -> u32) {
        let (fw, fh) = (self.width as usize, self.height as usize);
        let (x, y, w, h) = (x as usize, y as usize, w as usize, h as usize);
        for row in 0..h.min(fh.saturating_sub(y)) {
            let base = (y + row) * fw + x;
            for col in 0..w.min(fw.saturating_sub(x)) {
                self.pixels[base + col] = source(row * w + col);
            }
        }
    }

    /// Moves a rectangle within the frame, as VNC CopyRect does.
    fn copy(&mut self, dx: u32, dy: u32, sx: u32, sy: u32, w: u32, h: u32) {
        let fw = self.width as usize;
        let fits = |x: u32, y: u32| x + w <= self.width && y + h <= self.height;
        if !fits(dx, dy) || !fits(sx, sy) {
            return;
        }
        let rows: Vec<usize> = if dy > sy { (0..h as usize).rev().collect() } else { (0..h as usize).collect() };
        for row in rows {
            let from = (sy as usize + row) * fw + sx as usize;
            let to = (dy as usize + row) * fw + dx as usize;
            self.pixels.copy_within(from..from + w as usize, to);
        }
    }
}

pub(crate) enum Command {
    Pointer { x: u32, y: u32, buttons: u8 },
    Scroll(f32),
    Key(Key, bool),
    Text(String),
    Close,
}

#[derive(Default)]
pub(crate) struct Shared {
    events: Mutex<VecDeque<Event>>,
    pub(crate) frame: Mutex<Frame>,
    dirty: AtomicBool,
    closed: AtomicBool,
}

impl Shared {
    pub(crate) fn event(&self, event: Event) {
        self.events.lock().unwrap().push_back(event);
    }

    pub(crate) fn status(&self, text: impl Into<String>) {
        self.event(Event::Status(text.into()));
    }

    pub(crate) fn mark_dirty(&self) {
        self.dirty.store(true, Ordering::SeqCst);
    }

    pub(crate) fn finish(&self, reason: String) {
        if !self.closed.swap(true, Ordering::SeqCst) {
            self.event(Event::Closed(reason));
        }
    }
}

/// A running viewer session. Dropping it disconnects.
pub struct Session {
    shared: Arc<Shared>,
    commands: tokio::sync::mpsc::UnboundedSender<Command>,
}

impl Session {
    /// Starts connecting in the background; progress and failures arrive as events.
    pub fn connect(params: ConnectParams) -> Session {
        let shared = Arc::new(Shared::default());
        let (commands, receiver) = tokio::sync::mpsc::unbounded_channel();
        let worker = shared.clone();
        std::thread::Builder::new()
            .name("remotecore-session".into())
            .spawn(move || {
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| match params.protocol {
                    Protocol::Vnc => vnc::run(&params, &worker, receiver),
                    Protocol::Rdp => rdp::run(&params, &worker, receiver),
                }));
                worker.finish(match result {
                    Ok(Ok(())) => "The session ended.".into(),
                    Ok(Err(e)) => e,
                    Err(_) => "The session stopped because of an internal error.".into(),
                });
            })
            .expect("spawn session thread");
        Session { shared, commands }
    }

    pub fn poll_event(&self) -> Option<Event> {
        self.shared.events.lock().unwrap().pop_front()
    }

    /// Runs `f` on the frame if it changed since the last call.
    pub fn with_new_frame<R>(&self, f: impl FnOnce(&Frame) -> R) -> Option<R> {
        if !self.shared.dirty.swap(false, Ordering::SeqCst) {
            return None;
        }
        let frame = self.shared.frame.lock().unwrap();
        (frame.width > 0).then(|| f(&frame))
    }

    /// Marks the frame changed again, after a front end could not show it.
    pub fn redraw_later(&self) {
        self.shared.mark_dirty();
    }

    pub fn is_closed(&self) -> bool {
        self.shared.closed.load(Ordering::SeqCst)
    }

    pub fn pointer(&self, x: u32, y: u32, buttons: u8) {
        let _ = self.commands.send(Command::Pointer { x, y, buttons });
    }

    /// Wheel steps; positive scrolls up.
    pub fn scroll(&self, steps: f32) {
        let _ = self.commands.send(Command::Scroll(steps));
    }

    pub fn key(&self, key: Key, down: bool) {
        let _ = self.commands.send(Command::Key(key, down));
    }

    pub fn text(&self, text: &str) {
        let _ = self.commands.send(Command::Text(text.to_string()));
    }

    pub fn close(&self) {
        let _ = self.commands.send(Command::Close);
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        self.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blit_clips_to_the_frame() {
        let mut f = Frame::default();
        f.resize(4, 3);
        f.blit(2, 1, 4, 4, |i| i as u32 + 1);
        assert_eq!(f.pixels, [0, 0, 0, 0, 0, 0, 1, 2, 0, 0, 5, 6]);
    }

    #[test]
    fn copy_handles_overlap_downwards() {
        let mut f = Frame::default();
        f.resize(2, 3);
        f.pixels = vec![1, 2, 3, 4, 5, 6];
        f.copy(0, 1, 0, 0, 2, 2);
        assert_eq!(f.pixels, [1, 2, 1, 2, 3, 4]);
    }
}
