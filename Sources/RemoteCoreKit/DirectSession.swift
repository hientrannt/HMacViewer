import CoreGraphics
import Foundation
#if canImport(RemoteCoreFFI)
import RemoteCoreFFI
#endif

/// A direct VNC or RDP connection to a computer, without UltraViewer.
public enum DirectProtocol: Int32, CaseIterable, Sendable {
    case vnc = 1
    case rdp = 2

    public var defaultPort: UInt16 { self == .vnc ? 5900 : 3389 }
    public var scheme: String { self == .vnc ? "vnc" : "rdp" }
    public var title: String { self == .vnc ? "VNC" : "RDP" }
}

/// Keys without a text equivalent. Raw values match RC_KEY_* in remotecore.h.
public enum DirectKey: Int32, Sendable {
    case backspace, tab, enter, escape, delete, home, end, pageUp, pageDown
    case left, up, right, down, windows, shift, control, alt
}

public enum DirectEvent: Sendable {
    case status(String)
    case connected(width: Int, height: Int)
    case closed(String)
}

/// Where to connect: host with an optional port, and the user name for RDP.
public struct DirectTarget: Equatable, Sendable {
    public var proto: DirectProtocol
    public var host: String
    public var port: UInt16
    public var user: String

    public init(proto: DirectProtocol, host: String, port: UInt16? = nil, user: String = "") {
        self.proto = proto
        self.host = host
        self.port = port ?? proto.defaultPort
        self.user = user
    }

    /// Parses "host", "host:port", "[v6]:port" or a bare IPv6 address.
    public init?(proto: DirectProtocol, address: String, user: String = "") {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = text
        var port: UInt16?
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.hasPrefix(":") { port = UInt16(rest.dropFirst()); if port == nil { return nil } }
        } else if text.filter({ $0 == ":" }).count == 1, let colon = text.lastIndex(of: ":") {
            host = String(text[..<colon])
            guard let value = UInt16(text[text.index(after: colon)...]), value > 0 else { return nil }
            port = value
        }
        guard !host.isEmpty, !host.contains(where: \.isWhitespace) else { return nil }
        self.init(proto: proto, host: host, port: port, user: user.trimmingCharacters(in: .whitespaces))
    }

    /// "rdp://user@host:port", also used as the recent-connection entry.
    public var label: String {
        let address = host.contains(":") ? "[\(host)]" : host
        let port = port == proto.defaultPort ? "" : ":\(port)"
        return "\(proto.scheme)://\(user.isEmpty ? "" : user + "@")\(address)\(port)"
    }

    public init?(label: String) {
        guard let proto = DirectProtocol.allCases.first(where: { label.hasPrefix($0.scheme + "://") }) else { return nil }
        var rest = String(label.dropFirst(proto.scheme.count + 3))
        var user = ""
        if let at = rest.lastIndex(of: "@") { user = String(rest[..<at]); rest = String(rest[rest.index(after: at)...]) }
        self.init(proto: proto, address: rest, user: user)
    }

    public var address: String {
        let address = host.contains(":") ? "[\(host)]" : host
        return port == proto.defaultPort ? address : "\(address):\(port)"
    }
}

/// Thread-safe wrapper over the RemoteCore C interface. Every call returns at once.
public final class DirectSession: @unchecked Sendable {
    #if canImport(RemoteCoreFFI)
    public static let isAvailable = true
    #else
    public static let isAvailable = false
    #endif

    private let lock = NSLock()
    private var handle: OpaquePointer?
    private var pixels: [UInt32] = []

    /// `width`/`height` are the preferred desktop size for RDP.
    public init(target: DirectTarget, password: String, width: Int, height: Int) {
        #if canImport(RemoteCoreFFI)
        handle = rc_connect(target.proto.rawValue, target.host, target.port, target.user, password,
                            UInt32(clamping: width), UInt32(clamping: height))
        #endif
    }

    deinit { close() }

    public func pollEvent() -> DirectEvent? {
        #if canImport(RemoteCoreFFI)
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return nil }
        var buffer = [CChar](repeating: 0, count: 1024)
        var width: UInt32 = 0
        var height: UInt32 = 0
        let kind = rc_poll_event(handle, &buffer, buffer.count, &width, &height)
        let text = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        switch kind {
        case 1: return .status(text)
        case 2: return .connected(width: Int(width), height: Int(height))
        case 3: return .closed(text)
        default: return nil
        }
        #else
        return .closed("VNC and RDP are not included in this build.")
        #endif
    }

    /// The screen when it changed since the last call.
    public func copyFrame() -> CGImage? {
        #if canImport(RemoteCoreFFI)
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return nil }
        var width: UInt32 = 0
        var height: UInt32 = 0
        var copied = pixels.withUnsafeMutableBufferPointer {
            rc_copy_frame(handle, $0.baseAddress, $0.count, &width, &height)
        }
        if copied == 0, Int(width) * Int(height) > pixels.count {
            // The screen grew; the session marked it dirty again, so retry now.
            pixels = [UInt32](repeating: 0, count: Int(width) * Int(height))
            copied = pixels.withUnsafeMutableBufferPointer {
                rc_copy_frame(handle, $0.baseAddress, $0.count, &width, &height)
            }
        }
        guard copied == 1, width > 0, height > 0 else { return nil }
        let count = Int(width) * Int(height)
        let data = pixels.withUnsafeBytes { Data($0.prefix(count * 4)) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: Int(width) * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                           | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        #else
        return nil
        #endif
    }

    /// Bit 0 left, 1 middle, 2 right.
    public func pointer(x: Int, y: Int, buttons: UInt8) {
        #if canImport(RemoteCoreFFI)
        withHandle { rc_pointer($0, UInt32(clamping: max(0, x)), UInt32(clamping: max(0, y)), buttons) }
        #endif
    }

    /// Wheel steps; positive scrolls up.
    public func scroll(_ steps: Double) {
        #if canImport(RemoteCoreFFI)
        withHandle { rc_scroll($0, Float(steps)) }
        #endif
    }

    public func key(_ key: DirectKey, down: Bool) {
        #if canImport(RemoteCoreFFI)
        withHandle { rc_key($0, key.rawValue, down) }
        #endif
    }

    public func text(_ text: String) {
        #if canImport(RemoteCoreFFI)
        guard !text.isEmpty else { return }
        withHandle { rc_text($0, text) }
        #endif
    }

    public func close() {
        lock.lock()
        let old = handle
        handle = nil
        lock.unlock()
        #if canImport(RemoteCoreFFI)
        if let old { rc_close(old) }
        #endif
    }

    private func withHandle(_ body: (OpaquePointer) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let handle { body(handle) }
    }
}
