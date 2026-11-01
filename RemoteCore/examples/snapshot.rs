//! `cargo run --example snapshot -- vnc HOST PORT PASSWORD out.png`: connect,
//! click and type a little, then save the remote screen. Used to test against
//! a real server.

use std::time::{Duration, Instant};

use remotecore::{ConnectParams, Event, Protocol, Session, BUTTON_LEFT};

fn main() {
    let a: Vec<String> = std::env::args().skip(1).collect();
    let protocol = match a[0].as_str() { "vnc" => Protocol::Vnc, "rdp" => Protocol::Rdp, p => panic!("unknown protocol {p}") };
    let session = Session::connect(ConnectParams {
        protocol, host: a[1].clone(), port: a[2].parse().unwrap(), username: a.get(5).cloned().unwrap_or_default(),
        password: a[3].clone(), width: 1280, height: 800,
    });
    let start = Instant::now();
    let mut connected = None;
    let mut frames = 0;
    while start.elapsed() < Duration::from_secs(8) {
        while let Some(e) = session.poll_event() {
            println!("event: {e:?}");
            if let Event::Connected { width, height } = e {
                connected = Some((width, height));
                session.pointer(200, 200, 0);
                session.pointer(200, 200, BUTTON_LEFT);
                session.pointer(200, 200, 0);
                session.text("echo hello-from-remotecore\n");
            }
            if let Event::Closed(_) = e { return }
        }
        if session.with_new_frame(|_| ()).is_some() { frames += 1 }
        std::thread::sleep(Duration::from_millis(20));
    }
    println!("connected: {connected:?}, frame updates seen: {frames}");
    session.with_new_frame(|_| ());
    std::thread::sleep(Duration::from_millis(500));
    let saved = session.with_new_frame(|f| save(f, &a[4])).or_else(|| { std::thread::sleep(Duration::from_millis(500)); None });
    if saved.is_none() {
        // No update in the last half second: force one by moving the pointer.
        session.pointer(201, 201, 0);
        std::thread::sleep(Duration::from_millis(500));
        session.with_new_frame(|f| save(f, &a[4]));
    }
}

fn save(f: &remotecore::Frame, path: &str) {
    let file = std::fs::File::create(path).unwrap();
    let mut encoder = png::Encoder::new(file, f.width, f.height);
    encoder.set_color(png::ColorType::Rgb);
    let bytes: Vec<u8> = f.pixels.iter().flat_map(|p| [(p >> 16) as u8, (p >> 8) as u8, *p as u8]).collect();
    encoder.write_header().unwrap().write_image_data(&bytes).unwrap();
    println!("saved {path} ({}x{})", f.width, f.height);
}
