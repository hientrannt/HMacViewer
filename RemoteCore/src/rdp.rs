//! RDP through IronRDP (TLS + CredSSP/NLA, RemoteFX and bitmap codecs).
//! Keys go as set-1 scan codes, typed text as Unicode keyboard events.

use std::time::Duration;

use ironrdp_client::config::{ConfigBuilder, Destination};
use ironrdp_client::rdp::{RdpClient, RdpInputEvent, RdpOutputEvent};
use ironrdp_pdu::input::fast_path::{FastPathInputEvent, KeyboardFlags};
use ironrdp_pdu::input::mouse::{MousePdu, PointerFlags};
use smallvec::SmallVec;
use tokio::sync::mpsc::UnboundedReceiver;

use crate::{Command, ConnectParams, Event, Key, Shared, BUTTON_LEFT, BUTTON_MIDDLE, BUTTON_RIGHT};

pub(crate) fn run(params: &ConnectParams, shared: &Shared, commands: UnboundedReceiver<Command>) -> Result<(), String> {
    // Apps link more than one rustls backend; pick one for the whole process.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().map_err(|e| e.to_string())?;
    // IronRDP's session future is not Send; it runs on this thread's LocalSet.
    tokio::task::LocalSet::new().block_on(&runtime, session(params, shared, commands))
}

/// Keeps the remote desktop within what phones and laptops show comfortably.
fn desktop_size(params: &ConnectParams) -> (u16, u16) {
    let (w, h) = (params.width.clamp(800, 3840), params.height.clamp(600, 2160));
    // RDP widths must be even.
    ((w & !1) as u16, h as u16)
}

async fn session(params: &ConnectParams, shared: &Shared, mut commands: UnboundedReceiver<Command>) -> Result<(), String> {
    shared.status(format!("Connecting to {}…", params.host));
    // Probe first so an unreachable host gets a plain message.
    let address = (params.host.as_str(), params.port);
    tokio::time::timeout(Duration::from_secs(15), tokio::net::TcpStream::connect(address)).await
        .map_err(|_| format!("{} did not answer on port {}.", params.host, params.port))?
        .map_err(|e| format!("Could not reach {}:{}: {e}", params.host, params.port))?;
    let (width, height) = desktop_size(params);
    let (domain, username) = match params.username.split_once('\\') {
        Some((d, u)) => (Some(d.to_string()), u.to_string()),
        None => (None, params.username.clone()),
    };
    let mut builder = ConfigBuilder::new()
        .with_destination(Destination::from_parts(params.host.clone(), params.port))
        .with_username(username)
        .with_password(params.password.clone())
        .with_client_name("HMacViewer")
        .with_client_build(1)
        .with_client_dir("C:\\Windows\\System32\\mstscax.dll")
        .with_platform(ironrdp_pdu::rdp::capability_sets::MajorPlatformType::UNSPECIFIED)
        .with_desktop_width(width)
        .with_desktop_height(height);
    if let Some(domain) = domain {
        builder = builder.with_domain(domain);
    }
    let config = builder.build().map_err(|e| format!("Bad RDP settings: {e}"))?;
    let (output, mut events) = tokio::sync::mpsc::channel(8);
    let client = RdpClient::new(config, output);
    let input = client.input_sender();
    let driver = tokio::task::spawn_local(client.run());
    shared.status("Signing in…");

    let mut buttons = 0u8;
    let mut position = (0u16, 0u16);
    let mut wheel = 0f32;
    let mut size = (0u16, 0u16);
    let result = loop {
        tokio::select! {
            event = events.recv() => match event {
                None => break Ok(()),
                Some(RdpOutputEvent::Image { buffer, width, height }) => {
                    let (w, h) = (width.get(), height.get());
                    let mut frame = shared.frame.lock().unwrap();
                    if (w, h) != size {
                        size = (w, h);
                        frame.resize(w as u32, h as u32);
                        shared.event(Event::Connected { width: w as u32, height: h as u32 });
                    }
                    if buffer.len() == frame.pixels.len() {
                        frame.pixels.copy_from_slice(&buffer);
                    }
                    drop(frame);
                    shared.mark_dirty();
                }
                Some(RdpOutputEvent::ConnectionFailure(e)) => {
                    let text = e.to_string();
                    break Err(if text.contains("CredSSP") {
                        "Sign-in failed. Check the user name and password, and that Remote Desktop is turned on.".into()
                    } else {
                        format!("Could not connect: {}", text.rsplit("] ").next().unwrap_or(&text))
                    });
                }
                Some(RdpOutputEvent::Terminated(Ok(reason))) => break Err(format!("The session ended: {reason}")),
                Some(RdpOutputEvent::Terminated(Err(e))) => break Err(format!("The session ended: {e}")),
                Some(_) => {}
            },
            command = commands.recv() => {
                let Some(command) = command else { break Ok(()) };
                let mut out: SmallVec<[FastPathInputEvent; 2]> = SmallVec::new();
                match command {
                    Command::Close => break Ok(()),
                    Command::Pointer { x, y, buttons: b } => {
                        position = (x.min(u16::MAX as u32) as u16, y.min(u16::MAX as u32) as u16);
                        out.push(mouse(PointerFlags::MOVE, position, 0));
                        for (bit, flag) in [(BUTTON_LEFT, PointerFlags::LEFT_BUTTON),
                                            (BUTTON_RIGHT, PointerFlags::RIGHT_BUTTON),
                                            (BUTTON_MIDDLE, PointerFlags::MIDDLE_BUTTON_OR_WHEEL)] {
                            if (b ^ buttons) & bit != 0 {
                                let down = if b & bit != 0 { PointerFlags::DOWN } else { PointerFlags::empty() };
                                out.push(mouse(flag | down, position, 0));
                            }
                        }
                        buttons = b;
                    }
                    Command::Scroll(steps) => {
                        wheel += steps.clamp(-64.0, 64.0);
                        let whole = wheel.trunc();
                        wheel -= whole;
                        if whole != 0.0 {
                            let units = (whole * 120.0).clamp(-255.0, 255.0) as i16;
                            let mut flags = PointerFlags::VERTICAL_WHEEL;
                            if units < 0 { flags |= PointerFlags::WHEEL_NEGATIVE }
                            out.push(mouse(flags, position, units));
                        }
                    }
                    Command::Key(key, down) => {
                        let (code, extended) = scancode(key);
                        let mut flags = if down { KeyboardFlags::empty() } else { KeyboardFlags::RELEASE };
                        if extended { flags |= KeyboardFlags::EXTENDED }
                        out.push(FastPathInputEvent::KeyboardEvent(flags, code));
                    }
                    Command::Text(text) => {
                        for ch in text.chars() {
                            type_char(ch, &mut out);
                        }
                    }
                }
                if !out.is_empty() && input.send(RdpInputEvent::FastPath(out)).is_err() {
                    break Err("The connection ended.".into());
                }
            },
        }
    };
    let _ = input.send(RdpInputEvent::Close);
    let _ = tokio::time::timeout(Duration::from_secs(2), driver).await;
    result
}

fn mouse(flags: PointerFlags, (x, y): (u16, u16), wheel: i16) -> FastPathInputEvent {
    FastPathInputEvent::MouseEvent(MousePdu { flags, number_of_wheel_rotation_units: wheel, x_position: x, y_position: y })
}

/// Set-1 scan code and whether it is an extended (E0) key.
fn scancode(key: Key) -> (u8, bool) {
    match key {
        Key::Backspace => (0x0e, false), Key::Tab => (0x0f, false), Key::Enter => (0x1c, false),
        Key::Escape => (0x01, false), Key::Delete => (0x53, true), Key::Home => (0x47, true),
        Key::End => (0x4f, true), Key::PageUp => (0x49, true), Key::PageDown => (0x51, true),
        Key::Left => (0x4b, true), Key::Up => (0x48, true), Key::Right => (0x4d, true),
        Key::Down => (0x50, true), Key::Windows => (0x5b, true),
        Key::Shift => (0x2a, false), Key::Control => (0x1d, false), Key::Alt => (0x38, false),
    }
}

/// ASCII goes as US-layout scan codes (with Shift where needed), which every
/// server understands; anything else as Unicode keyboard events.
fn type_char(ch: char, out: &mut SmallVec<[FastPathInputEvent; 2]>) {
    let key = |flags: KeyboardFlags, code: u8| FastPathInputEvent::KeyboardEvent(flags, code);
    if let Some((code, shift)) = ascii_scancode(ch) {
        if shift { out.push(key(KeyboardFlags::empty(), 0x2a)) }
        out.push(key(KeyboardFlags::empty(), code));
        out.push(key(KeyboardFlags::RELEASE, code));
        if shift { out.push(key(KeyboardFlags::RELEASE, 0x2a)) }
        return;
    }
    let mut units = [0u16; 2];
    for &unit in ch.encode_utf16(&mut units).iter() {
        out.push(FastPathInputEvent::UnicodeKeyboardEvent(KeyboardFlags::empty(), unit));
        out.push(FastPathInputEvent::UnicodeKeyboardEvent(KeyboardFlags::RELEASE, unit));
    }
}

/// US keyboard set-1 scan code for an ASCII character and whether it needs Shift.
fn ascii_scancode(ch: char) -> Option<(u8, bool)> {
    const ROWS: [(&str, &str, u8); 4] = [
        ("1234567890-=", "!@#$%^&*()_+", 0x02),
        ("qwertyuiop[]", "QWERTYUIOP{}", 0x10),
        ("asdfghjkl;'`", "ASDFGHJKL:\"~", 0x1e),
        ("\\zxcvbnm,./", "|ZXCVBNM<>?", 0x2b),
    ];
    match ch {
        ' ' => return Some((0x39, false)),
        '\n' | '\r' => return Some((0x1c, false)),
        '\t' => return Some((0x0f, false)),
        _ => {}
    }
    for (plain, shifted, first) in ROWS {
        if let Some(i) = plain.chars().position(|c| c == ch) { return Some((first + i as u8, false)) }
        if let Some(i) = shifted.chars().position(|c| c == ch) { return Some((first + i as u8, true)) }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ascii_maps_to_us_scancodes() {
        assert_eq!(ascii_scancode('a'), Some((0x1e, false)));
        assert_eq!(ascii_scancode('A'), Some((0x1e, true)));
        assert_eq!(ascii_scancode('1'), Some((0x02, false)));
        assert_eq!(ascii_scancode('-'), Some((0x0c, false)));
        assert_eq!(ascii_scancode('`'), Some((0x29, false)));
        assert_eq!(ascii_scancode('\\'), Some((0x2b, false)));
        assert_eq!(ascii_scancode('z'), Some((0x2c, false)));
        assert_eq!(ascii_scancode('/'), Some((0x35, false)));
        assert_eq!(ascii_scancode('?'), Some((0x35, true)));
        assert_eq!(ascii_scancode('ệ'), None);
    }
}
