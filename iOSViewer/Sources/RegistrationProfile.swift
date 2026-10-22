import CryptoKit
import Darwin
import Foundation
import UIKit
import UltraViewerProtocol

/// This iPhone's UltraViewer client identity, kept in Application Support.
/// iOS hides hardware addresses, so the MAC field is derived from the
/// installation's device identity and stays stable across launches.
enum RegistrationProfile {
    enum ProfileError: LocalizedError {
        case networkUnavailable

        var errorDescription: String? {
            String(localized: "No IPv4 network is available. Turn on Wi-Fi or mobile data and try again.")
        }
    }

    static func loadOrCreate() throws -> ClientRegistration.Request {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let directory = support.appendingPathComponent("HMacViewer", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("registration.json")
        let stored = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(ClientRegistration.Request.self, from: $0) }
        let identity = stored?.deviceIdentity ?? deviceIdentity(UUID())
        let password = stored?.password ?? (0..<8).map { _ in String(Int.random(in: 0...9)) }.joined()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let request = ClientRegistration.Request(
            deviceIdentity: identity, password: password, localAddress: try localAddress(),
            computerNameUTF8Base64: Data(UIDevice.current.model.utf8).base64EncodedString(),
            clientVersion: "6.6.133", macAddress: hardwareAddress(for: identity), diskIdentity: "",
            operatingSystem: "\(version.patchVersion)|\(version.majorVersion)|0|\(version.minorVersion)|0|0",
            installerReferral: 0, customPassword: "", usesProxy: false, quickSupportMetadata: "",
            userNameWireValue: "mobile", activeSessionID: 0, processSessionID: 0, preferredIDText: "0",
            referralIDText: "0", automaticUpdate: 0, systemFolderCreationTicks: "0", programFilesCreationTicks: "0",
            systemVolumeInformationCreationTicks: "0", licenseContext1: "", licenseContext2: "", captchaToken: "")
        _ = try request.encode()
        try JSONEncoder().encode(request).write(to: file, options: [.atomic, .completeFileProtection])
        return request
    }

    /// Name shown to the partner: ASCII only, at most 20 characters.
    static var loginDisplayName: String {
        let name = UIDevice.current.model.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == " ") }
        return name.isEmpty ? "HMacViewer" : "HMacViewer \(name)".prefix(20).description
    }

    private static func deviceIdentity(_ uuid: UUID) -> String {
        var bytes = uuid.uuid
        let digest = withUnsafeBytes(of: &bytes) { Insecure.MD5.hash(data: Data($0)) }
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    /// A locally administered unicast address from the device identity.
    private static func hardwareAddress(for identity: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(6))
        bytes[0] = (bytes[0] | 0x02) & 0xfe
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    /// Wi-Fi (en0) first, then cellular, then any other active IPv4 interface.
    private static func localAddress() throws -> RelayIPv4Address {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { throw ProfileError.networkUnavailable }
        defer { if let head { freeifaddrs(head) } }
        var found: [(name: String, address: String)] = []
        var cursor = head
        while let node = cursor {
            defer { cursor = node.pointee.ifa_next }
            let entry = node.pointee
            guard entry.ifa_flags & UInt32(IFF_UP) != 0, entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil else { continue }
            let text = String(cString: buffer)
            if !text.hasPrefix("169.254.") { found.append((String(cString: entry.ifa_name), text)) }
        }
        let rank = { (name: String) -> Int in name == "en0" ? 0 : name.hasPrefix("pdp_ip") ? 1 : 2 }
        guard let best = found.min(by: { rank($0.name) < rank($1.name) }),
              let address = try? RelayIPv4Address(best.address) else { throw ProfileError.networkUnavailable }
        return address
    }
}
