import CoreGraphics
import Foundation
import UltraViewerProtocol

/// One remote session: connects through the relay, publishes frames and
/// status for the UI, and sends mouse and keyboard input in order.
@MainActor
final class SessionModel: ObservableObject {
    enum Phase: Equatable { case connecting, connected, ended(String) }

    @Published private(set) var phase = Phase.connecting
    @Published private(set) var status = ""
    @Published private(set) var image: CGImage?
    @Published private(set) var viewOnly = false
    @Published var sharpImage = false {
        didSet { applyQuality() }
    }

    private let session = UltraViewerRelaySession()
    private var reader: Task<Void, Never>?
    private var origin = (x: Int32(0), y: Int32(0))
    private var keyboardSupported = false
    private var buttons: Int32 = 0
    private var position = (x: Int32(0), y: Int32(0))
    private var wheelRemainder = 0.0
    // Input goes out one payload at a time; only the newest pointer move waits.
    private var outbox: [Data] = []
    private var pendingMove: Data?
    private var sending = false

    func connect(id: String, password: String, screenWidth: Int, screenHeight: Int) {
        reader = Task {
            do {
                let profile = try RegistrationProfile.loadOrCreate()
                let configuration = UltraViewerRelaySession.Configuration(registration: profile,
                    localScreenWidth: Int32(screenWidth), localScreenHeight: Int32(screenHeight),
                    displayName: RegistrationProfile.loginDisplayName)
                let events = try await session.connect(configuration: configuration, partnerID: id, password: password)
                for try await event in events { handle(event) }
                end(String(localized: "The session ended."))
            } catch is CancellationError {
            } catch {
                end(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        reader?.cancel()
        let session = session
        Task { await session.close() }
        end(String(localized: "Disconnected."))
    }

    private func end(_ reason: String) {
        if case .ended = phase { return }
        phase = .ended(reason)
    }

    private func handle(_ event: UltraViewerRelaySession.Event) {
        switch event {
        case let .status(text):
            status = text
        case let .accepted(peer), let .screenChanged(peer):
            origin = (peer.virtualLeft, peer.virtualTop)
            keyboardSupported = peer.supportsBinaryKeyboard
            viewOnly = !peer.allowsRemoteInput
            phase = .connected
            applyQuality()
            command(RemoteControlCommands.wallpaper(visible: false))
            command(RemoteControlCommands.cursorPositions(enabled: true))
        case let .frame(latest):
            if let next = latest.take()?.makeCGImage() { image = next }
        case let .inputPermission(allowed):
            viewOnly = !allowed
        default:
            break
        }
    }

    /// Fast (30) for slower phone links unless the user picked a sharp image.
    private func applyQuality() {
        guard phase == .connected else { return }
        for message in RemoteControlCommands.qualityPreset(sharpImage ? .quality : .speed) { command(message) }
    }

    private func command(_ message: RemoteControlCommands.Message) {
        let session = session
        Task { try? await session.sendCommand(message, requiresControl: false) }
    }

    // MARK: Input (remote screen pixels)

    private var flags: Int32 {
        (buttons & 1 != 0 ? 0x01 : 0) | (buttons & 2 != 0 ? 0x02 : 0) | (buttons & 4 != 0 ? 0x10 : 0)
    }

    private func remote(_ x: Int, _ y: Int) -> (x: Int32, y: Int32) {
        (Int32(x) + origin.x, Int32(y) + origin.y)
    }

    func pointer(x: Int, y: Int) {
        position = remote(x, y)
        pendingMove = MouseMessage.move(wParam: flags, x: position.x, y: position.y).encode()
        pump()
    }

    /// button: 0 left, 1 right.
    func button(_ button: Int, pressed: Bool, x: Int, y: Int) {
        position = remote(x, y)
        pendingMove = nil
        enqueue(MouseMessage.move(wParam: flags, x: position.x, y: position.y).encode())
        let bit: Int32 = button == 0 ? 1 : 2
        if pressed { buttons |= bit } else { buttons &= ~bit }
        let kind: MouseMessage.Button = switch (button, pressed) {
        case (0, true): .leftDown
        case (0, false): .leftUp
        case (_, true): .rightDown
        case (_, false): .rightUp
        }
        let packed = MouseMessage.packedPosition(x: Int16(truncatingIfNeeded: position.x),
                                                 y: Int16(truncatingIfNeeded: position.y))
        enqueue(MouseMessage.button(kind, wParam: flags, lParam: packed).encode())
    }

    /// Wheel steps, positive scrolls up; fractions carry over.
    func scroll(_ steps: Double) {
        let total = wheelRemainder + max(-64, min(64, steps))
        let whole = total.rounded(.towardZero)
        wheelRemainder = total - whole
        guard whole != 0 else { return }
        let packed = MouseMessage.packedPosition(x: Int16(truncatingIfNeeded: position.x),
                                                 y: Int16(truncatingIfNeeded: position.y))
        enqueue(MouseMessage.verticalWheel(wParam: MouseMessage.wheelWParam(delta: Int16(whole * 120),
            keyFlags: UInt16(truncatingIfNeeded: flags)), lParam: packed).encode())
    }

    /// Text as VK_PACKET key pairs, one UTF-16 unit each.
    func type(_ text: String) {
        guard keyboardSupported else { return }
        for unit in text.utf16 where unit >= 0x20 && !(0xd800...0xdfff).contains(unit) {
            enqueue(KeyboardMessage(kind: .keyDown, virtualKey: 0xe7, scanCode: 0, character: unit, capsLockOn: false).encode())
            enqueue(KeyboardMessage(kind: .keyUp, virtualKey: 0xe7, scanCode: 0, character: unit, capsLockOn: false).encode())
        }
    }

    func key(_ key: RemoteKey) {
        guard keyboardSupported else { return }
        for kind in [KeyboardMessage.Kind.keyDown, .keyUp] {
            enqueue(KeyboardMessage(kind: kind, virtualKey: key.virtualKey, scanCode: key.scanCode,
                                    character: key.character, capsLockOn: false).encode())
        }
    }

    private func enqueue(_ payload: Data) {
        guard !viewOnly else { return }
        if let move = pendingMove { outbox.append(move); pendingMove = nil }
        outbox.append(payload)
        pump()
    }

    private func pump() {
        guard !sending, !viewOnly else { return }
        let next: Data
        if !outbox.isEmpty { next = outbox.removeFirst() }
        else if let move = pendingMove { next = move; pendingMove = nil }
        else { return }
        sending = true
        let session = session
        Task {
            try? await session.send(next)
            sending = false
            pump()
        }
    }
}

/// Windows virtual keys with set-1 scan codes and the character Windows reports.
enum RemoteKey {
    case backspace, tab, enter, escape, delete, left, right, up, down, windows

    var virtualKey: UInt8 {
        switch self {
        case .backspace: 0x08
        case .tab: 0x09
        case .enter: 0x0d
        case .escape: 0x1b
        case .delete: 0x2e
        case .left: 0x25
        case .up: 0x26
        case .right: 0x27
        case .down: 0x28
        case .windows: 0x5b
        }
    }

    var scanCode: UInt16 {
        switch self {
        case .backspace: 0x0e
        case .tab: 0x0f
        case .enter: 0x1c
        case .escape: 0x01
        case .delete: 0xe053
        case .left: 0xe04b
        case .up: 0xe048
        case .right: 0xe04d
        case .down: 0xe050
        case .windows: 0xe05b
        }
    }

    var character: UInt16 {
        switch self {
        case .backspace: 8
        case .tab: 9
        case .enter: 13
        case .escape: 27
        default: 0
        }
    }
}
