import SwiftUI
import UIKit

/// Keeps one RemoteScreenView for the life of the session screen.
@MainActor
final class ScreenHolder: ObservableObject {
    let view = RemoteScreenView()
}

private struct RemoteScreen: UIViewRepresentable {
    let holder: ScreenHolder
    let model: SessionModel
    let image: CGImage?

    func makeUIView(context: Context) -> RemoteScreenView {
        holder.view.model = model
        return holder.view
    }

    func updateUIView(_ view: RemoteScreenView, context: Context) {
        if view.image !== image { view.image = image }
    }
}

/// Full-screen session with a floating toolbar.
struct SessionScreen: View {
    let id: String
    let password: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SessionModel()
    @StateObject private var holder = ScreenHolder()
    @State private var showToolbar = true
    @State private var touchpad = true
    @State private var fill = UserDefaults.standard.object(forKey: "fillScreen") as? Bool ?? true
    @State private var confirmDisconnect = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            RemoteScreen(holder: holder, model: model, image: model.image).ignoresSafeArea()
            if model.image == nil {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text(model.status.isEmpty ? String(localized: "Connecting…") : model.status)
                        .foregroundStyle(.white).multilineTextAlignment(.center).padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
            HStack(alignment: .top) {
                Spacer()
                if showToolbar { toolbar }
                Spacer()
                Button { showToolbar.toggle() } label: {
                    Image(systemName: "ellipsis.circle.fill").font(.title2).foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.5), in: Circle())
                }
            }
            .padding(.horizontal, 8)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            let size = UIScreen.main.nativeBounds.size
            model.connect(id: id, password: password,
                          screenWidth: Int(max(size.width, size.height)), screenHeight: Int(min(size.width, size.height)))
        }
        .onChange(of: model.phase) { phase in
            // Fitted on a phone a whole desktop is tiny: start zoomed in around the cursor.
            if phase == .connected, !fill, holder.view.zoom == 1, UIDevice.current.userInterfaceIdiom == .phone {
                holder.view.zoom = 2
            }
        }
        .alert("Disconnect from the other computer?", isPresented: $confirmDisconnect) {
            Button("Disconnect", role: .destructive) { model.disconnect(); dismiss() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Session ended", isPresented: Binding(get: { endReason != nil && !confirmDisconnect }, set: { _ in })) {
            Button("OK") { dismiss() }
        } message: {
            Text(endReason ?? "")
        }
    }

    private var endReason: String? {
        if case let .ended(reason) = model.phase { return reason }
        return nil
    }

    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                tool("keyboard", "Keyboard") {
                    if holder.view.isFirstResponder { holder.view.resignFirstResponder() } else { holder.view.becomeFirstResponder() }
                }
                tool(touchpad ? "rectangle.and.hand.point.up.left" : "hand.tap", touchpad ? "Touchpad" : "Direct touch") {
                    touchpad.toggle(); holder.view.touchpadMode = touchpad
                }
                tool(fill ? "rectangle.inset.filled" : "rectangle.arrowtriangle.2.inward", fill ? "Fill" : "Fit") {
                    fill.toggle(); holder.view.fillScreen = fill
                }
                tool("plus.magnifyingglass", "Zoom") { holder.view.zoom = holder.view.zoom > 1.05 ? 1 : 2.5 }
                if !model.isDirect {
                    tool(model.sharpImage ? "sparkles" : "hare", model.sharpImage ? "Sharp" : "Fast") { model.sharpImage.toggle() }
                }
                tool(nil, "Esc") { model.key(.escape) }
                tool(nil, "Tab") { model.key(.tab) }
                tool("square.grid.2x2", "Win") { model.key(.windows) }
                tool("arrow.left", nil) { model.key(.left) }
                tool("arrow.right", nil) { model.key(.right) }
                tool("arrow.up", nil) { model.key(.up) }
                tool("arrow.down", nil) { model.key(.down) }
                tool("xmark.circle", "Disconnect") { confirmDisconnect = true }
            }
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: 640)
        .background(.black.opacity(0.6), in: Capsule())
        .padding(.top, 4)
    }

    private func tool(_ symbol: String?, _ title: LocalizedStringKey?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol) }
                if let title { Text(title) }
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 8)
        }
    }
}
