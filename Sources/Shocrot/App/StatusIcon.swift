import AppKit

/// The menu bar icon, optionally with a small orange dot in its top-right corner.
enum StatusIcon {
    static func image(attention: Bool) -> NSImage? {
        guard let base = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: "Shocrot") else { return nil }
        guard attention else {
            base.isTemplate = true
            return base
        }
        let size = base.size
        // Drawn on demand, so labelColor resolves against the menu bar's current appearance.
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            NSColor.labelColor.set()
            rect.fill(using: .sourceAtop)
            let d = (size.height * 0.36).rounded()
            let dot = CGRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
            // Cut a gap around the dot so it doesn't merge with the viewfinder's corner.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = L("status.icon.attention")
        return image
    }
}
