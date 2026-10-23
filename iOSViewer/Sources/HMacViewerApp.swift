import RemoteCoreKit
import SwiftUI

@main
struct HMacViewerApp: App {
    var body: some Scene {
        WindowGroup { ConnectView() }
    }
}

/// UltraViewer, VNC or RDP connection form with the recent connections.
struct ConnectView: View {
    /// Comma-separated UltraViewer IDs and `DirectTarget.label`s.
    @AppStorage("recentIDs") private var recentStorage = ""
    @AppStorage("connectionKind") private var kind = Kind.ultraViewer
    @AppStorage("directUser") private var user = ""
    @State private var id = ""
    @State private var password = ""
    @State private var session: SessionRequest?
    @State private var invalid = false
    @FocusState private var passwordFocused: Bool

    private struct SessionRequest: Identifiable {
        let id = UUID()
        let partner: String
        let password: String
    }

    enum Kind: String, CaseIterable, Identifiable {
        case ultraViewer, vnc, rdp
        var id: String { rawValue }
        var title: String {
            switch self {
            case .ultraViewer: "UltraViewer"
            case .vnc: "VNC"
            case .rdp: "RDP"
            }
        }
        var direct: DirectProtocol? {
            switch self {
            case .ultraViewer: nil
            case .vnc: .vnc
            case .rdp: .rdp
            }
        }
    }

    private var recent: [String] { recentStorage.split(separator: ",").map(String.init) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image("Logo").resizable().frame(width: 88, height: 88).clipShape(RoundedRectangle(cornerRadius: 20))
                        Text("HMacViewer").font(.title.bold())
                        Text("Control a computer by UltraViewer, VNC or Remote Desktop (RDP).")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
                Section {
                    Picker("Connection", selection: $kind) {
                        ForEach(Kind.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if kind == .ultraViewer {
                        TextField("Partner ID", text: $id).keyboardType(.numberPad).font(.title3)
                    } else {
                        TextField("IP address or name, e.g. 192.168.1.20", text: $id)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().font(.title3)
                    }
                    if kind == .rdp {
                        TextField("Windows user name", text: $user)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().font(.title3)
                    }
                    SecureField("Password", text: $password).font(.title3).focused($passwordFocused)
                        .submitLabel(.go).onSubmit(connect)
                    Button(action: connect) {
                        Text("Connect").font(.headline).frame(maxWidth: .infinity)
                    }
                }
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent, id: \.self) { item in
                            Button { select(item) } label: {
                                if DirectTarget(label: item) != nil {
                                    Text(item).font(.body.monospaced())
                                } else {
                                    Text(stride(from: 0, to: item.count, by: 3).map { start -> String in
                                        let s = item.index(item.startIndex, offsetBy: start)
                                        return String(item[s..<(item.index(s, offsetBy: 3, limitedBy: item.endIndex) ?? item.endIndex)])
                                    }.joined(separator: " ")).font(.title3.monospacedDigit())
                                }
                            }
                        }
                    }
                }
                Section {
                    Text("Trần Ngọc Hiện · hiendhg@gmail.com · 0796868079")
                        .font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
            }
            .alert(LocalizedStringKey(kind == .ultraViewer ? "Enter the partner's ID and password."
                                      : "Enter the computer's address and password."),
                   isPresented: $invalid) { Button("OK") {} }
            .fullScreenCover(item: $session) { request in
                SessionScreen(id: request.partner, password: request.password)
            }
        }
    }

    private func select(_ item: String) {
        if let target = DirectTarget(label: item) {
            kind = target.proto == .vnc ? .vnc : .rdp
            id = target.address
            user = target.user
        } else {
            kind = .ultraViewer
            id = item
        }
        passwordFocused = true
    }

    private func connect() {
        let partner: String
        if let proto = kind.direct {
            // VNC servers may have no password; RDP always signs in.
            guard let target = DirectTarget(proto: proto, address: id, user: user),
                  proto == .vnc || !password.isEmpty else { invalid = true; return }
            partner = target.label
        } else {
            partner = id.filter { !$0.isWhitespace }
            guard !partner.isEmpty, partner.allSatisfy(\.isNumber), !password.isEmpty else { invalid = true; return }
        }
        recentStorage = ([partner] + recent.filter { $0 != partner }).prefix(5).joined(separator: ",")
        session = SessionRequest(partner: partner, password: password)
    }
}
