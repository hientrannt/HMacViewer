//! MouseMessage.swift + KeyboardMessage.swift, encode (viewer) and decode
//! (host). Windows virtual-key + set-1 scan codes. OWNER: screen.
//! The winit key table mirrors MacRemoteInputEncoder.swift's mapping.

use crate::messages::version_at_least;

#[derive(Clone, Debug, PartialEq)]
pub enum InputEvent {
    /// Windows mouse message (0x200 move, 0x201..0x209 buttons, 0x20a wheel),
    /// position in remote screen pixels, wheel delta for 0x20a.
    Mouse { msg: u32, x: i32, y: i32, wheel: i16 },
    /// kind 1..4 as in KeyboardMessage.swift, vk, scan, utf16 char.
    Key { kind: u8, vk: u8, scan: u16, ch: u16 },
}

pub const WM_MOUSEMOVE: u32 = 0x200;
pub const WM_LBUTTONDOWN: u32 = 0x201;
pub const WM_LBUTTONUP: u32 = 0x202;
pub const WM_RBUTTONDOWN: u32 = 0x204;
pub const WM_RBUTTONUP: u32 = 0x205;
pub const WM_MBUTTONDOWN: u32 = 0x207;
pub const WM_MBUTTONUP: u32 = 0x208;
pub const WM_MOUSEWHEEL: u32 = 0x20a;

pub const KEY_DOWN: u8 = 1;
pub const KEY_UP: u8 = 2;
pub const SYS_KEY_DOWN: u8 = 3;
pub const SYS_KEY_UP: u8 = 4;
pub const VK_PACKET: u8 = 0xe7;

/// The desktop's isTargetVersionGreaterThan6213 branch.
pub fn supports_binary_keyboard(partner_version: &str) -> bool {
    version_at_least(partner_version, [6, 2, 13])
}

fn mouse_text(msg: u32, params: &[i32]) -> Vec<u8> {
    let mut s = format!("8|||{msg}");
    for p in params {
        s.push_str(&format!("|||{p}"));
    }
    s.into_bytes()
}

/// MouseMessage.move: three signed Long parameters.
pub fn mouse_move(wparam: i32, x: i32, y: i32) -> Vec<u8> {
    mouse_text(WM_MOUSEMOVE, &[wparam, x, y])
}

/// MouseMessage.button (0x201..0x209); lParam is packed_position.
pub fn mouse_button(msg: u32, wparam: i32, lparam: i32) -> Vec<u8> {
    mouse_text(msg, &[wparam, lparam])
}

/// MouseMessage.verticalWheel; wParam from wheel_wparam.
pub fn mouse_wheel(wparam: i32, lparam: i32) -> Vec<u8> {
    mouse_text(WM_MOUSEWHEEL, &[wparam, lparam])
}

pub fn packed_position(x: i16, y: i16) -> i32 {
    (x as u16 as u32 | (y as u16 as u32) << 16) as i32
}

pub fn wheel_wparam(delta: i16, key_flags: u16) -> i32 {
    (key_flags as u32 | (delta as u16 as u32) << 16) as i32
}

/// KeyboardMessage.encode: 11 bytes.
pub fn keyboard(kind: u8, vk: u8, scan: u16, ch: u16, caps_lock: bool) -> Vec<u8> {
    vec![30, 0x7c, 0x7c, 0x7c, kind, vk, scan as u8, (scan >> 8) as u8, ch as u8, (ch >> 8) as u8, caps_lock as u8]
}

/// VK_PACKET down/up pairs, one UTF-16 unit each (IME text path).
pub fn text_packets(text: &str, caps_lock: bool) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    for unit in text.encode_utf16() {
        if unit < 0x20 || (0xd800..=0xdfff).contains(&unit) {
            continue;
        }
        out.push(keyboard(KEY_DOWN, VK_PACKET, 0, unit, caps_lock));
        out.push(keyboard(KEY_UP, VK_PACKET, 0, unit, caps_lock));
    }
    out
}

/// Decode an incoming `8|||...` or `[30,'|','|','|',...]` payload (host side).
/// Mirrors MacHostInputMessage.decode; malformed payloads return None.
pub fn decode(payload: &[u8]) -> Option<InputEvent> {
    if payload.first() == Some(&30) {
        if payload.len() != 11 || payload[1..4] != [124, 124, 124] || !(1..=4).contains(&payload[4]) || payload[10] > 1 {
            return None;
        }
        return Some(InputEvent::Key {
            kind: payload[4], vk: payload[5],
            scan: u16::from_le_bytes([payload[6], payload[7]]),
            ch: u16::from_le_bytes([payload[8], payload[9]]),
        });
    }
    if !payload.starts_with(b"8|||") || payload.len() > 256 || !payload.iter().all(|b| (32..=126).contains(b)) {
        return None;
    }
    let text = std::str::from_utf8(payload).ok()?;
    let fields: Vec<&str> = text.split("|||").collect();
    let int = |s: &str| -> Option<i32> { s.parse::<i32>().ok().filter(|v| v.to_string() == s) };
    let msg = u32::try_from(int(fields.get(1)?)?).ok()?;
    if [0x100, 0x101, 0x104, 0x105].contains(&msg) {
        // Legacy VK-only branch Windows still uses for modifiers; -1 sentinels.
        if fields.len() != 5 || fields[3] != "-1" || fields[4] != "-1" {
            return None;
        }
        let vk: u8 = fields[2].parse().ok().filter(|v: &u8| v.to_string() == fields[2])?;
        let kind = match msg { 0x100 => KEY_DOWN, 0x101 => KEY_UP, 0x104 => SYS_KEY_DOWN, _ => SYS_KEY_UP };
        return Some(InputEvent::Key { kind, vk, scan: 0, ch: 0 });
    }
    if !(0x200..=0x20a).contains(&msg) {
        return None;
    }
    let expected = if msg == WM_MOUSEMOVE { 5 } else { 4 };
    if fields.len() != expected {
        return None;
    }
    let v: Vec<i32> = fields[2..].iter().map(|f| int(f)).collect::<Option<_>>()?;
    if msg == WM_MOUSEMOVE {
        return Some(InputEvent::Mouse { msg, x: v[1], y: v[2], wheel: 0 });
    }
    let (x, y) = (v[1] as i16 as i32, (v[1] >> 16) as i16 as i32);
    let wheel = if msg == WM_MOUSEWHEEL { (v[0] >> 16) as i16 } else { 0 };
    Some(InputEvent::Mouse { msg, x, y, wheel })
}

/// Modifier flags (RemoteModifiers).
pub const SHIFT: u8 = 1;
pub const CONTROL: u8 = 2;
pub const ALT: u8 = 4;
pub const SUPER: u8 = 8;
pub const CAPS_LOCK: u8 = 16;

#[cfg(feature = "desktop")]
mod encoder;
#[cfg(feature = "desktop")]
pub use encoder::*;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keyboard_payload_matches_recovered_byte_layout() {
        assert_eq!(keyboard(1, 0x41, 0x001e, 0x0041, false), [0x1e, 0x7c, 0x7c, 0x7c, 0x01, 0x41, 0x1e, 0x00, 0x41, 0x00, 0x00]);
        let system = keyboard(4, 0xa5, 0x1234, 0x20ac, true);
        assert_eq!(system, [0x1e, 0x7c, 0x7c, 0x7c, 0x04, 0xa5, 0x34, 0x12, 0xac, 0x20, 0x01]);
        assert_eq!(keyboard(2, 0, 0, 0, false), [30, 124, 124, 124, 2, 0, 0, 0, 0, 0, 0]);
        assert_eq!(keyboard(3, 255, 0xffff, 0xffff, true), [30, 124, 124, 124, 3, 255, 255, 255, 255, 255, 1]);
    }

    #[test]
    fn mouse_shapes_and_packing() {
        assert_eq!(mouse_move(1, -1920, 1080), b"8|||512|||1|||-1920|||1080");
        assert_eq!(mouse_button(0x201, 1, 0x0028_001e), b"8|||513|||1|||2621470");
        for msg in 0x201..=0x209 {
            assert_eq!(mouse_button(msg, 0, -1), format!("8|||{msg}|||0|||-1").into_bytes());
        }
        let wp = wheel_wparam(-120, 8);
        let lp = packed_position(-10, -20);
        assert_eq!((wp, lp), (-7_864_312, -1_245_194));
        assert_eq!(mouse_wheel(wp, lp), b"8|||522|||-7864312|||-1245194");
        assert_eq!(wheel_wparam(120, 0), 7_864_320);
        assert_eq!(packed_position(30, 40), 2_621_470);
        assert_eq!(mouse_move(i32::MIN, i32::MAX, i32::MIN), b"8|||512|||-2147483648|||2147483647|||-2147483648");
        assert_eq!(wheel_wparam(i16::MIN, 0), i32::MIN);
        assert_eq!(wheel_wparam(-1, u16::MAX), -1);
        assert_eq!(packed_position(-1, -1), -1);
    }

    #[test]
    fn decode_round_trips() {
        assert_eq!(decode(&keyboard(4, 0xa5, 0x1234, 0x20ac, true)),
                   Some(InputEvent::Key { kind: 4, vk: 0xa5, scan: 0x1234, ch: 0x20ac }));
        assert_eq!(decode(&mouse_move(0, -5, 7)), Some(InputEvent::Mouse { msg: 0x200, x: -5, y: 7, wheel: 0 }));
        assert_eq!(decode(&mouse_button(0x204, 2, packed_position(30, 40))),
                   Some(InputEvent::Mouse { msg: 0x204, x: 30, y: 40, wheel: 0 }));
        assert_eq!(decode(&mouse_wheel(wheel_wparam(-120, 8), packed_position(-10, -20))),
                   Some(InputEvent::Mouse { msg: 0x20a, x: -10, y: -20, wheel: -120 }));
        assert_eq!(decode(b"8|||256|||16|||-1|||-1"), Some(InputEvent::Key { kind: 1, vk: 16, scan: 0, ch: 0 }));
        assert_eq!(decode(b"8|||261|||18|||-1|||-1"), Some(InputEvent::Key { kind: 4, vk: 18, scan: 0, ch: 0 }));
        for bad in [&b"8|||512|||1|||2"[..], b"8|||513|||01|||2", b"8|||9999|||1|||2", b"8|||256|||16|||0|||-1",
                    &[30, 124, 124, 124, 5, 0, 0, 0, 0, 0, 0], &[30, 124, 124, 124, 1, 0, 0, 0, 0, 0, 2], b"28|||1"] {
            assert_eq!(decode(bad), None, "{:?}", String::from_utf8_lossy(bad));
        }
    }
}
