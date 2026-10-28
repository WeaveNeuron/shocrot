import AppKit

/// A floating, always-on-top image ("贴图"). Drag to move, scroll/pinch to zoom, double-click or Esc to close.
final class PinWindow: NSPanel {
    private static var open: [PinWindow] = []

    private let image: CGImage
    private let scale: CGFloat
    private let baseSize: CGSize
    private var zoom: CGFloat = 1
    private let zoomLabel = NSTextField(labelWithString: "")
    private var labelWork: DispatchWorkItem?

    static func pin(_ image: CGImage, scale: CGFloat, at rect: CGRect? = nil) {
        let pin = PinWindow(image: image, scale: scale, rect: rect)
        open.append(pin)
        pin.orderFrontRegardless()
        pin.makeKey()
    }

    static func closeAll() { open.forEach { $0.close() } }

    private init(image: CGImage, scale: CGFloat, rect: CGRect?) {
        self.image = image
        self.scale = scale
        baseSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        var frame = rect ?? CGRect(origin: .zero, size: baseSize)
        if rect == nil, let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let fit = min(1, screen.visibleFrame.width * 0.8 / baseSize.width, screen.visibleFrame.height * 0.8 / baseSize.height)
            frame.size = CGSize(width: baseSize.width * fit, height: baseSize.height * fit)
            frame.origin = CGPoint(x: screen.visibleFrame.midX - frame.width / 2, y: screen.visibleFrame.midY - frame.height / 2)
            zoom = fit
        }
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = PinContentView(frame: CGRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        content.layer?.cornerRadius = 4
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.6).cgColor
        content.owner = self

        content.layer?.contents = image
        content.layer?.contentsGravity = .resize

        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        zoomLabel.textColor = .white
        zoomLabel.alignment = .center
        zoomLabel.wantsLayer = true
        zoomLabel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        zoomLabel.layer?.cornerRadius = 4
        zoomLabel.isHidden = true
        content.addSubview(zoomLabel)

        contentView = content
        content.menu = makeMenu()
    }

    override var canBecomeKey: Bool { true }

    override func close() {
        PinWindow.open.removeAll { $0 === self }
        super.close()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.keyCode == 53 { close(); return }
        if flags == .command {
            switch key {
            case "c": copyImage()
            case "s": saveImage()
            case "w": close()
            case "t": recognizeText()
            case "=", "+": setZoom(zoom * 1.1, anchor: nil)
            case "-": setZoom(zoom / 1.1, anchor: nil)
            case "0": setZoom(1, anchor: nil)
            default: super.keyDown(with: event)
            }
            return
        }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command) {
            // ⌥/⌘ + scroll changes opacity.
            alphaValue = min(1, max(0.2, alphaValue + (event.scrollingDeltaY > 0 ? 0.05 : -0.05)))
            showLabel("\(Int(alphaValue * 100))% 不透明")
            return
        }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.05
        setZoom(zoom * (1 + delta), anchor: NSEvent.mouseLocation)
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: NSEvent.mouseLocation)
    }

    private func setZoom(_ z: CGFloat, anchor: CGPoint?) {
        let newZoom = min(max(z, 0.1), 8)
        let old = frame
        let size = CGSize(width: baseSize.width * newZoom, height: baseSize.height * newZoom)
        let a = anchor ?? CGPoint(x: old.midX, y: old.midY)
        let fx = (a.x - old.minX) / old.width, fy = (a.y - old.minY) / old.height
        let origin = CGPoint(x: a.x - size.width * fx, y: a.y - size.height * fy)
        zoom = newZoom
        setFrame(CGRect(origin: origin, size: size).integral, display: true)
        showLabel("\(Int(round(zoom * 100)))%")
    }

    private func showLabel(_ text: String) {
        zoomLabel.stringValue = text
        zoomLabel.sizeToFit()
        let w = zoomLabel.frame.width + 12, h: CGFloat = 20
        zoomLabel.frame = CGRect(x: (frame.width - w) / 2, y: (frame.height - h) / 2, width: w, height: h)
        zoomLabel.isHidden = false
        labelWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.zoomLabel.isHidden = true }
        labelWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "复制", action: #selector(copyImage), keyEquivalent: "c").target = self
        menu.addItem(withTitle: "保存…", action: #selector(saveImage), keyEquivalent: "s").target = self
        menu.addItem(withTitle: "识别文字", action: #selector(recognizeText), keyEquivalent: "t").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "原始大小", action: #selector(resetZoom), keyEquivalent: "0").target = self
        let opacity = NSMenuItem(title: "不透明度", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in [100, 80, 60, 40] {
            let item = NSMenuItem(title: "\(v)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = v
            item.target = self
            sub.addItem(item)
        }
        opacity.submenu = sub
        menu.addItem(opacity)
        menu.addItem(.separator())
        menu.addItem(withTitle: "关闭", action: #selector(closePin), keyEquivalent: "w").target = self
        menu.addItem(withTitle: "关闭全部贴图", action: #selector(closeAllPins), keyEquivalent: "").target = self
        return menu
    }

    @objc private func copyImage() {
        ImageOutput.copy(image, scale: scale)
        Feedback.toast("已复制图片")
    }

    @objc private func saveImage() { ImageOutput.saveAs(image) }
    @objc private func recognizeText() { AppController.shared.recognize(image: image, scale: scale) }
    @objc private func resetZoom() { setZoom(1, anchor: nil) }
    @objc private func setOpacity(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }
    @objc private func closePin() { close() }
    @objc private func closeAllPins() { PinWindow.closeAll() }
}

private final class PinContentView: NSView {
    weak var owner: PinWindow?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { owner?.close(); return }
        window?.performDrag(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
