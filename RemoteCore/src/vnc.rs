//! RFB (VNC) through vnc-rs: Tight (JPEG), ZRLE, CopyRect and Raw updates,
//! VNC password authentication, X11 keysyms for keys and Unicode text.

use std::time::Duration;

use tokio::net::TcpStream;
use tokio::sync::mpsc::UnboundedReceiver;
use vnc::{PixelFormat, VncConnector, VncEncoding, VncError, VncEvent, X11Event};

use crate::{Command, ConnectParams, Event, Key, Shared};

/// How often an incremental update is requested.
const REFRESH_INTERVAL: Duration = Duration::from_millis(16);

pub(crate) fn run(params: &ConnectParams, shared: &Shared, commands: UnboundedReceiver<Command>) -> Result<(), String> {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    runtime.block_on(session(params, shared, commands))
}

fn sign_in_error(e: VncError) -> String {
    format!("Could not sign in to the VNC server: {e}")
}

/// Pointer and keyboard state turned into RFB input events.
#[derive(Default)]
struct Input {
    buttons: u8,
    position: (u16, u16),
    wheel: f32,
}

impl Input {
    fn mouse(&self, buttons: u8) -> X11Event {
        X11Event::PointerEvent(vnc::ClientMouseEvent {
            position_x: self.position.0, position_y: self.position.1, bottons: buttons,
        })
    }

    fn events(&mut self, command: Command) -> Vec<X11Event> {
        match command {
            Command::Close => vec![],
            Command::Pointer { x, y, buttons } => {
                // RFB: bit 0 left, 1 middle, 2 right, as the shared mask.
                self.buttons = buttons & 7;
                self.position = (x.min(u16::MAX as u32) as u16, y.min(u16::MAX as u32) as u16);
                vec![self.mouse(self.buttons)]
            }
            Command::Scroll(steps) => {
                self.wheel += steps.clamp(-64.0, 64.0);
                let mut out = Vec::new();
                while self.wheel.abs() >= 1.0 {
                    // Buttons 4 and 5 are wheel up and down.
                    let bit = if self.wheel > 0.0 { 8 } else { 16 };
                    out.push(self.mouse(self.buttons | bit));
                    out.push(self.mouse(self.buttons));
                    self.wheel -= self.wheel.signum();
                }
                out
            }
            Command::Key(key, down) => vec![X11Event::KeyEvent((keysym(key), down).into())],
            Command::Text(text) => text.chars().flat_map(|ch| {
                let sym = text_keysym(ch);
                [X11Event::KeyEvent((sym, true).into()), X11Event::KeyEvent((sym, false).into())]
            }).collect(),
        }
    }
}

fn keysym(key: Key) -> u32 {
    match key {
        Key::Backspace => 0xff08, Key::Tab => 0xff09, Key::Enter => 0xff0d, Key::Escape => 0xff1b,
        Key::Delete => 0xffff, Key::Home => 0xff50, Key::Left => 0xff51, Key::Up => 0xff52,
        Key::Right => 0xff53, Key::Down => 0xff54, Key::PageUp => 0xff55, Key::PageDown => 0xff56,
        Key::End => 0xff57, Key::Windows => 0xffeb,
        Key::Shift => 0xffe1, Key::Control => 0xffe3, Key::Alt => 0xffe9,
    }
}

/// Latin-1 characters are their own keysym; others use the Unicode keysym range.
fn text_keysym(ch: char) -> u32 {
    match ch {
        '\n' | '\r' => 0xff0d,
        '\t' => 0xff09,
        c if (c as u32) < 0x100 => c as u32,
        c => 0x0100_0000 | c as u32,
    }
}

async fn session(params: &ConnectParams, shared: &Shared, mut commands: UnboundedReceiver<Command>) -> Result<(), String> {
    shared.status(format!("Connecting to {}…", params.host));
    let tcp = tokio::time::timeout(Duration::from_secs(15), TcpStream::connect((params.host.as_str(), params.port))).await
        .map_err(|_| format!("{} did not answer on port {}.", params.host, params.port))?
        .map_err(|e| format!("Could not reach {}:{}: {e}", params.host, params.port))?;
    let _ = tcp.set_nodelay(true);
    shared.status("Signing in…");
    let password = params.password.clone();
    let client = VncConnector::new(tcp)
        .set_auth_method(async move { Ok(password) })
        .add_encoding(VncEncoding::Tight)
        .add_encoding(VncEncoding::Zrle)
        .add_encoding(VncEncoding::CopyRect)
        .add_encoding(VncEncoding::Raw)
        .add_encoding(VncEncoding::DesktopSizePseudo)
        .allow_shared(true)
        .set_pixel_format(PixelFormat::bgra())
        .build().map_err(sign_in_error)?
        .try_start().await.map_err(sign_in_error)?
        .finish().map_err(sign_in_error)?;

    let mut refresh = tokio::time::interval(REFRESH_INTERVAL);
    refresh.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut input = Input::default();
    let result = 'session: loop {
        tokio::select! {
            event = client.recv_event() => match event {
                Ok(event) => if let Err(e) = apply(shared, event) { break Err(e) },
                Err(e) => break Err(format!("The connection ended: {e}")),
            },
            command = commands.recv() => {
                let Some(mut command) = command else { break Ok(()) };
                // Drain what queued up meanwhile; consecutive moves with the
                // same buttons collapse into the newest.
                let mut batch = Vec::new();
                loop {
                    if matches!(command, Command::Close) { break 'session Ok(()) }
                    match commands.try_recv() {
                        Ok(next) => {
                            let collapses = matches!((&command, &next),
                                (Command::Pointer { buttons: a, .. }, Command::Pointer { buttons: b, .. }) if a == b);
                            if !collapses { batch.push(command) }
                            command = next;
                        }
                        Err(_) => { batch.push(command); break }
                    }
                }
                for command in batch {
                    for event in input.events(command) {
                        if client.input(event).await.is_err() { break 'session Err("The connection ended.".into()) }
                    }
                }
            },
            _ = refresh.tick() => {
                if client.input(X11Event::Refresh).await.is_err() { break Err("The connection ended.".into()) }
            },
        }
    };
    let _ = client.close().await;
    result
}

/// Applies one server event to the shared framebuffer.
fn apply(shared: &Shared, event: VncEvent) -> Result<(), String> {
    match event {
        VncEvent::SetResolution(screen) => {
            shared.frame.lock().unwrap().resize(screen.width as u32, screen.height as u32);
            shared.event(Event::Connected { width: screen.width as u32, height: screen.height as u32 });
        }
        VncEvent::RawImage(rect, data) => {
            // BGRA bytes: little-endian 0xAARRGGBB.
            let mut frame = shared.frame.lock().unwrap();
            frame.blit(rect.x as u32, rect.y as u32, rect.width as u32, rect.height as u32, |i| {
                data.get(i * 4..i * 4 + 4).map_or(0, |p| u32::from_le_bytes([p[0], p[1], p[2], 0]))
            });
            shared.mark_dirty();
        }
        VncEvent::Copy(to, from) => {
            shared.frame.lock().unwrap().copy(to.x as u32, to.y as u32, from.x as u32, from.y as u32,
                                              to.width as u32, to.height as u32);
            shared.mark_dirty();
        }
        VncEvent::JpegImage(rect, data) => {
            let mut decoder = jpeg_decoder::Decoder::new(data.as_slice());
            let pixels = decoder.decode().map_err(|e| format!("Bad JPEG update: {e}"))?;
            let rgb = decoder.info().map(|i| i.pixel_format == jpeg_decoder::PixelFormat::RGB24).unwrap_or(false);
            let mut frame = shared.frame.lock().unwrap();
            frame.blit(rect.x as u32, rect.y as u32, rect.width as u32, rect.height as u32, |i| {
                if rgb {
                    pixels.get(i * 3..i * 3 + 3).map_or(0, |p| u32::from_be_bytes([0, p[0], p[1], p[2]]))
                } else {
                    pixels.get(i).map_or(0, |&l| u32::from_be_bytes([0, l, l, l]))
                }
            });
            shared.mark_dirty();
        }
        VncEvent::Error(e) => return Err(format!("The VNC server reported an error: {e}")),
        _ => {}
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_uses_latin1_and_unicode_keysyms() {
        assert_eq!(text_keysym('a'), 0x61);
        assert_eq!(text_keysym('é'), 0xe9);
        assert_eq!(text_keysym('ệ'), 0x0100_1ec7);
        assert_eq!(text_keysym('\n'), 0xff0d);
    }

    #[test]
    fn scroll_presses_and_releases_wheel_buttons() {
        let mut input = Input::default();
        assert!(input.events(Command::Scroll(0.5)).is_empty());
        let events = input.events(Command::Scroll(0.6));
        assert_eq!(events.len(), 2);
        assert!(matches!(&events[0], X11Event::PointerEvent(m) if m.bottons == 8));
        assert!(matches!(&events[1], X11Event::PointerEvent(m) if m.bottons == 0));
    }
}
