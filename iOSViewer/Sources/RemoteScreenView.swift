import UIKit

/**
 Shows the remote screen and turns touches into mouse input.

 Touchpad mode (default) works like a laptop trackpad: sliding moves the
 cursor, tap clicks at the cursor, two-finger tap right-clicks, and
 hold-then-slide drags. Direct mode clicks where the finger lands. In both,
 two fingers scroll, pinch zooms around the cursor, and a zoomed view
 follows the cursor. Typing goes through UIKeyInput.
 */
final class RemoteScreenView: UIView, UIKeyInput {
    weak var model: SessionModel?

    var image: CGImage? {
        didSet {
            if image?.width != oldValue?.width || image?.height != oldValue?.height, let image {
                cursor = CGPoint(x: CGFloat(image.width) / 2, y: CGFloat(image.height) / 2)
                pan = .zero
            }
            imageLayer.contents = image
            layoutScreen()
        }
    }
    var touchpadMode = true
    /// Fill crops the remote desktop to cover the whole display (foldables and
    /// tall phones); off fits it inside with black bars.
    var fillScreen = UserDefaults.standard.object(forKey: "fillScreen") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(fillScreen, forKey: "fillScreen")
            followCursor(); layoutScreen()
        }
    }
    var zoom: CGFloat = 1 {
        didSet { zoom = min(max(zoom, 1), Self.maxZoom); followCursor(); layoutScreen() }
    }

    private static let maxZoom: CGFloat = 6
    private let imageLayer = CALayer()
    private let cursorLayer = CAShapeLayer()
    private var pan = CGPoint.zero
    private var cursor = CGPoint.zero

    // Gesture state.
    private var touches = Set<UITouch>()
    private var downPoint = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private var downTime = Date()
    private var moved = false
    private var holding = false
    private var multiTouch = false
    private var multiStart = Date()
    private var multiMode: MultiMode = .undecided
    private var lastDistance: CGFloat = 0
    private var lastFocusY: CGFloat = 0
    private var holdTimer: Timer?

    private enum MultiMode { case undecided, scroll, pinch }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        imageLayer.magnificationFilter = .linear
        imageLayer.minificationFilter = .trilinear
        imageLayer.actions = ["contents": NSNull(), "frame": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer.addSublayer(imageLayer)
        let arrow = UIBezierPath()
        arrow.move(to: .zero)
        for p in [(0, 22), (5.5, 17), (9.5, 25.5), (13, 24), (9, 15.5), (16, 15.5)] {
            arrow.addLine(to: CGPoint(x: p.0, y: p.1))
        }
        arrow.close()
        cursorLayer.path = arrow.cgPath
        cursorLayer.fillColor = UIColor.white.cgColor
        cursorLayer.strokeColor = UIColor.black.cgColor
        cursorLayer.lineWidth = 1.5
        cursorLayer.lineJoin = .round
        cursorLayer.actions = ["position": NSNull()]
        layer.addSublayer(cursorLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Geometry

    private var imageSize: CGSize {
        guard let image else { return .zero }
        return CGSize(width: image.width, height: image.height)
    }

    /// View points per remote pixel.
    private var scale: CGFloat {
        let size = imageSize
        guard size.width > 0, size.height > 0 else { return 1 }
        let x = bounds.width / size.width, y = bounds.height / size.height
        return (fillScreen ? max(x, y) : min(x, y)) * zoom
    }

    private var origin: CGPoint {
        let size = imageSize
        return CGPoint(x: (bounds.width - size.width * scale) / 2 + pan.x,
                       y: (bounds.height - size.height * scale) / 2 + pan.y)
    }

    private func clampPan() {
        let size = imageSize
        let spareX = max(0, (size.width * scale - bounds.width) / 2)
        let spareY = max(0, (size.height * scale - bounds.height) / 2)
        pan.x = min(max(pan.x, -spareX), spareX)
        pan.y = min(max(pan.y, -spareY), spareY)
    }

    /// Pans a zoomed view so the cursor stays inside a margin of the screen.
    private func followCursor() {
        let margin = min(bounds.width, bounds.height) * 0.2
        let p = CGPoint(x: origin.x + cursor.x * scale, y: origin.y + cursor.y * scale)
        if p.x < margin { pan.x += margin - p.x } else if p.x > bounds.width - margin { pan.x -= p.x - (bounds.width - margin) }
        if p.y < margin { pan.y += margin - p.y } else if p.y > bounds.height - margin { pan.y -= p.y - (bounds.height - margin) }
        clampPan()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clampPan()
        layoutScreen()
    }

    private func layoutScreen() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = imageSize
        imageLayer.frame = CGRect(origin: origin, size: CGSize(width: size.width * scale, height: size.height * scale))
        cursorLayer.position = CGPoint(x: origin.x + cursor.x * scale, y: origin.y + cursor.y * scale)
        cursorLayer.isHidden = image == nil
        CATransaction.commit()
    }

    private func place(at point: CGPoint) {
        let size = imageSize
        guard size.width > 0 else { return }
        cursor.x = min(max((point.x - origin.x) / scale, 0), size.width - 1)
        cursor.y = min(max((point.y - origin.y) / scale, 0), size.height - 1)
    }

    private func move(by delta: CGPoint) {
        let size = imageSize
        guard size.width > 0 else { return }
        // Faster finger movement travels further, like a trackpad.
        let gain = (1 + min(hypot(delta.x, delta.y) / 12, 1.5)) / scale
        cursor.x = min(max(cursor.x + delta.x * gain, 0), size.width - 1)
        cursor.y = min(max(cursor.y + delta.y * gain, 0), size.height - 1)
    }

    private func sendCursor() {
        model?.pointer(x: Int(cursor.x), y: Int(cursor.y))
        followCursor()
        layoutScreen()
    }

    private func click(_ button: Int) {
        model?.button(button, pressed: true, x: Int(cursor.x), y: Int(cursor.y))
        model?.button(button, pressed: false, x: Int(cursor.x), y: Int(cursor.y))
        followCursor()
        layoutScreen()
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        self.touches.formUnion(touches)
        if self.touches.count == 1, !multiTouch {
            let t = touches.first!
            downPoint = t.location(in: self); lastPoint = downPoint
            downTime = Date(); moved = false; holding = false
            holdTimer?.invalidate()
            holdTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in self?.holdBegan() }
        } else if self.touches.count >= 2 {
            holdTimer?.invalidate()
            if !multiTouch {
                multiTouch = true; multiStart = Date(); multiMode = .undecided
            }
            if holding, touchpadMode {
                holding = false
                model?.button(0, pressed: false, x: Int(cursor.x), y: Int(cursor.y))
            }
            (lastDistance, lastFocusY) = pairMetrics()
        }
    }

    private func holdBegan() {
        guard !moved, !multiTouch, !touches.isEmpty else { return }
        holding = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if touchpadMode {
            model?.button(0, pressed: true, x: Int(cursor.x), y: Int(cursor.y))
        } else {
            // Direct mode: holding without moving is a right click.
            place(at: downPoint)
            click(1)
        }
    }

    private func pairMetrics() -> (CGFloat, CGFloat) {
        let points = touches.prefix(2).map { $0.location(in: self) }
        guard points.count == 2 else { return (lastDistance, lastFocusY) }
        return (hypot(points[0].x - points[1].x, points[0].y - points[1].y), (points[0].y + points[1].y) / 2)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        if multiTouch {
            guard self.touches.count >= 2 else { return }
            let (distance, focusY) = pairMetrics()
            let dd = distance - lastDistance
            let dy = focusY - lastFocusY
            if multiMode == .undecided, abs(dd) + abs(dy) > 8 {
                multiMode = abs(dd) > abs(dy) ? .pinch : .scroll
            }
            switch multiMode {
            case .pinch where lastDistance > 0:
                // Zoom around the cursor so the point being worked on stays put.
                let before = CGPoint(x: origin.x + cursor.x * scale, y: origin.y + cursor.y * scale)
                zoom *= distance / lastDistance
                pan.x += before.x - (origin.x + cursor.x * scale)
                pan.y += before.y - (origin.y + cursor.y * scale)
                clampPan(); layoutScreen()
            case .scroll:
                // About one wheel step per 30 pt; fingers up scroll the content down.
                model?.scroll(Double(dy / 30))
            default: break
            }
            lastDistance = distance; lastFocusY = focusY
            return
        }
        guard let t = touches.first else { return }
        let p = t.location(in: self)
        if !moved, hypot(p.x - downPoint.x, p.y - downPoint.y) > 8 {
            moved = true
            holdTimer?.invalidate()
            if !touchpadMode, !holding {
                // Direct mode: a drag presses where the finger went down.
                place(at: downPoint)
                holding = true
                model?.button(0, pressed: true, x: Int(cursor.x), y: Int(cursor.y))
            }
        }
        if moved {
            if touchpadMode { move(by: CGPoint(x: p.x - lastPoint.x, y: p.y - lastPoint.y)) } else { place(at: p) }
            sendCursor()
        }
        lastPoint = p
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, cancelled: true)
    }

    private func finish(_ ended: Set<UITouch>, cancelled: Bool) {
        let lastTouch = ended.first?.location(in: self) ?? lastPoint
        self.touches.subtract(ended)
        guard self.touches.isEmpty else {
            (lastDistance, lastFocusY) = pairMetrics()
            return
        }
        holdTimer?.invalidate()
        let quick = Date().timeIntervalSince(multiTouch ? multiStart : downTime) < 0.3
        if cancelled {
            if holding { model?.button(0, pressed: false, x: Int(cursor.x), y: Int(cursor.y)) }
        } else if multiTouch {
            if multiMode == .undecided, quick { click(1) }
        } else if holding {
            if touchpadMode || moved { model?.button(0, pressed: false, x: Int(cursor.x), y: Int(cursor.y)) }
        } else if !moved, quick {
            if !touchpadMode { place(at: lastTouch) }
            click(0)
        }
        holding = false
        multiTouch = false
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no

    func insertText(_ text: String) {
        if text == "\n" { model?.key(.enter) } else { model?.type(text) }
    }

    func deleteBackward() {
        model?.key(.backspace)
    }
}
