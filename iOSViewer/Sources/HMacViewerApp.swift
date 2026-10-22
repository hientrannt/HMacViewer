import SwiftUI

@main
struct HMacViewerApp: App {
    var body: some Scene {
        WindowGroup { ConnectView() }
    }
}

/// Partner ID and password form with the recently used IDs.
struct ConnectView: View {
    @AppStorage("recentIDs") private var recentStorage = ""
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

    private var recent: [String] { recentStorage.split(separator: ",").map(String.init) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image("Logo").resizable().frame(width: 88, height: 88).clipShape(RoundedRectangle(cornerRadius: 20))
                        Text("HMacViewer").font(.title.bold())
                        Text("Control a computer running UltraViewer or HMacViewer.")
                            .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).listRowBackground(Color.clear)
                }
                Section {
                    TextField("Partner ID", text: $id).keyboardType(.numberPad).font(.title3)
                    SecureField("Password", text: $password).font(.title3).focused($passwordFocused)
                        .submitLabel(.go).onSubmit(connect)
                    Button(action: connect) {
                        Text("Connect").font(.headline).frame(maxWidth: .infinity)
                    }
                }
                if !recent.isEmpty {
                    Section("Recent") {
                        ForEach(recent, id: \.self) { item in
                            Button {
                                id = item; passwordFocused = true
                            } label: {
                                Text(stride(from: 0, to: item.count, by: 3).map { start -> String in
                                    let s = item.index(item.startIndex, offsetBy: start)
                                    return String(item[s..<(item.index(s, offsetBy: 3, limitedBy: item.endIndex) ?? item.endIndex)])
                                }.joined(separator: " ")).font(.title3.monospacedDigit())
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
            .alert("Enter the partner's ID and password.", isPresented: $invalid) { Button("OK") {} }
            .fullScreenCover(item: $session) { request in
                SessionScreen(id: request.partner, password: request.password)
            }
        }
    }

    private func connect() {
        let partner = id.filter { !$0.isWhitespace }
        guard !partner.isEmpty, partner.allSatisfy(\.isNumber), !password.isEmpty else { invalid = true; return }
        recentStorage = ([partner] + recent.filter { $0 != partner }).prefix(5).joined(separator: ",")
        session = SessionRequest(partner: partner, password: password)
    }
}
