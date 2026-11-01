import AppKit
import Foundation
import RemoteCoreKit
import UltraViewerProtocol

/// Sends "vnc://…" and "rdp://…" targets (see `DirectTarget.label`) to RemoteCore
/// and every other partner ID to UltraViewer.
@MainActor
final class RoutingSessionAdapter: MacViewerSessionAdapter {
    private let ultraViewer: any MacViewerSessionAdapter
    private let direct = DirectSessionAdapter()
    private var active: any MacViewerSessionAdapter

    init(ultraViewer: any MacViewerSessionAdapter) {
        self.ultraViewer = ultraViewer
        active = ultraViewer
    }

    var availability: SessionAvailability { ultraViewer.availability }

    func connect(partnerID: String, password: String) async throws -> AsyncThrowingStream<RemoteSessionEvent, Error> {
        let next: any MacViewerSessionAdapter = DirectTarget(label: partnerID) == nil ? ultraViewer : direct
        if next !== active { active.disconnect() }
        active = next
        return try await next.connect(partnerID: partnerID, password: password)
    }

    func send(_ input: RemoteInput) async throws { try await active.send(input) }
    func sendChat(_ text: String) async throws { try await active.sendChat(text) }
    func sendTyping(_ typing: Bool) async throws { try await active.sendTyping(typing) }
    func sendCommand(_ message: RemoteControlCommands.Message, requiresControl: Bool) async throws {
        try await active.sendCommand(message, requiresControl: requiresControl)
    }
    func sendClipboard(_ text: String) async throws { try await active.sendClipboard(text) }
    func setClipboardSharing(_ enabled: Bool) async throws { try await active.setClipboardSharing(enabled) }
    func setComputerAudioEnabled(_ enabled: Bool) async throws { try await active.setComputerAudioEnabled(enabled) }
    func sendFile(_ url: URL) async throws -> String { try await active.sendFile(url) }
    func acceptFile(_ transferID: String, to destination: URL) async throws {
        try await active.acceptFile(transferID, to: destination)
    }
    func cancelFile(_ transferID: String) async throws { try await active.cancelFile(transferID) }
    func disconnect() { active.disconnect() }
    func waitUntilClosed() async {
        await ultraViewer.waitUntilClosed()
        await direct.waitUntilClosed()
    }
}

/// A VNC or RDP session through RemoteCore. Polling and frame copies run off
/// the main thread; events are delivered on it.
@MainActor
final class DirectSessionAdapter: MacViewerSessionAdapter {
    let availability = SessionAvailability.available
    private var session: DirectSession?
    private var poller: Task<Void, Never>?
    private var output: AsyncThrowingStream<RemoteSessionEvent, Error>.Continuation?
    private var buttons: UInt8 = 0
    private var pointer = (x: 0, y: 0)
    private var heldModifiers: Set<DirectKey> = []
    private var wheelRemainder = 0.0

    func connect(partnerID: String, password: String) async throws -> AsyncThrowingStream<RemoteSessionEvent, Error> {
        disconnect()
        guard DirectSession.isAvailable else {
            throw NativeSessionError.unavailable("VNC and RDP are not included in this build.")
        }
        guard let target = DirectTarget(label: partnerID) else { throw NativeSessionError.invalidPartnerID }
        // Ask RDP for a desktop that fills this Mac's screen at full resolution.
        let screen = NSScreen.main ?? NSScreen.screens.first
        let scale = screen?.backingScaleFactor ?? 2
        let size = screen?.frame.size ?? CGSize(width: 1920, height: 1080)
        let session = DirectSession(target: target, password: password,
                                    width: Int(size.width * scale), height: Int(size.height * scale))
        self.session = session
        let pair = AsyncThrowingStream<RemoteSessionEvent, Error>.makeStream()
        output = pair.continuation
        poller = Task { [weak self] in
            var connected = false
            while !Task.isCancelled {
                let batch = await Task.detached { () -> ([DirectEvent], CGImage?) in
                    var events: [DirectEvent] = []
                    while let event = session.pollEvent() { events.append(event) }
                    return (events, session.copyFrame())
                }.value
                guard !Task.isCancelled, let self, self.session === session else { return }
                for event in batch.0 {
                    switch event {
                    case let .status(message):
                        pair.continuation.yield(.status(message))
                    case .connected:
                        var info = RemoteSessionInfo(partnerID: target.label)
                        info.displayName = target.address
                        info.allowsRemoteInput = true
                        pair.continuation.yield(connected ? .screenGeometryChanged(info) : .connected(info))
                        connected = true
                    case let .closed(message):
                        if connected { pair.continuation.finish() }
                        else { pair.continuation.finish(throwing: NativeSessionError.unavailable(message)) }
                        return
                    }
                }
                if let image = batch.1 { pair.continuation.yield(.frame(RemoteScreenFrame(image: image))) }
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
        return pair.stream
    }

    func send(_ input: RemoteInput) async throws {
        guard let session else { throw NativeSessionError.unavailable("There is no connected remote session.") }
        switch input {
        case let .pointerMoved(x, y):
            pointer = (x, y)
            session.pointer(x: x, y: y, buttons: buttons)
        case let .pointerButton(button, pressed, x, y):
            pointer = (x, y)
            let bit = Self.buttonBit(button)
            buttons = pressed ? buttons | bit : buttons & ~bit
            session.pointer(x: x, y: y, buttons: buttons)
        case let .doubleClick(button, x, y):
            pointer = (x, y)
            let bit = Self.buttonBit(button)
            for _ in 0..<2 {
                session.pointer(x: x, y: y, buttons: buttons | bit)
                session.pointer(x: x, y: y, buttons: buttons & ~bit)
            }
        case let .scroll(_, deltaY):
            guard deltaY.isFinite else { return }
            let total = wheelRemainder + min(256, max(-256, deltaY))
            let steps = total.rounded(.towardZero)
            wheelRemainder = total - steps
            if steps != 0 { session.scroll(steps) }
        case let .key(keyCode, characters, pressed, modifiers):
            setModifiers(modifiers, on: session)
            if let key = Self.keys[keyCode] {
                session.key(key, down: pressed)
            } else if pressed {
                if !modifiers.isDisjoint(with: [.control, .option, .command]), let letter = Self.shortcutCharacters[keyCode] {
                    session.text(letter)
                } else if let characters, !characters.isEmpty, characters.unicodeScalars.allSatisfy({
                    $0.value >= 0x20 && $0.value != 0x7f && !(0xf700...0xf8ff).contains($0.value)
                }) {
                    session.text(characters)
                }
            }
        case let .text(text):
            session.text(text)
        case let .modifiers(modifiers):
            setModifiers(modifiers, on: session)
        case .releaseAll:
            setModifiers([], on: session)
            if buttons != 0 {
                buttons = 0
                session.pointer(x: pointer.x, y: pointer.y, buttons: 0)
            }
        }
    }

    /// Commands, chat, clipboard and audio are UltraViewer features; ignore them here.
    func sendCommand(_ message: RemoteControlCommands.Message, requiresControl: Bool) async throws {}
    func setComputerAudioEnabled(_ enabled: Bool) async throws {
        if enabled { throw NativeSessionError.unavailable("Computer audio is unavailable for VNC and RDP connections.") }
    }

    func disconnect() {
        poller?.cancel()
        poller = nil
        if let session {
            setModifiers([], on: session)
            if buttons != 0 { session.pointer(x: pointer.x, y: pointer.y, buttons: 0) }
            session.close()
        }
        session = nil
        buttons = 0
        wheelRemainder = 0
        output?.finish()
        output = nil
    }

    /// Command is sent as Control so ⌘C, ⌘V and ⌘Z do what a Mac user expects.
    private func setModifiers(_ modifiers: RemoteModifiers, on session: DirectSession) {
        var wanted: Set<DirectKey> = []
        if modifiers.contains(.shift) { wanted.insert(.shift) }
        if !modifiers.isDisjoint(with: [.control, .command]) { wanted.insert(.control) }
        if modifiers.contains(.option) { wanted.insert(.alt) }
        for key in heldModifiers.subtracting(wanted) { session.key(key, down: false) }
        for key in wanted.subtracting(heldModifiers) { session.key(key, down: true) }
        heldModifiers = wanted
    }

    private static func buttonBit(_ button: Int) -> UInt8 {
        switch button {
        case 1: 4 // right
        case 2: 2 // middle
        default: 1
        }
    }

    private static let keys: [UInt16: DirectKey] = [
        36: .enter, 76: .enter, 48: .tab, 51: .backspace, 53: .escape, 117: .delete,
        115: .home, 119: .end, 116: .pageUp, 121: .pageDown,
        123: .left, 124: .right, 125: .down, 126: .up,
    ]

    /// US-layout characters for shortcuts, where AppKit's `characters` is a control code.
    private static let shortcutCharacters: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b",
        12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o",
        32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";", 42: "\\",
        43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 49: " ", 50: "`",
    ]
}
