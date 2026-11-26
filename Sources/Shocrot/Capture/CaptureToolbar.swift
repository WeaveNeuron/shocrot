import SwiftUI

enum ToolbarAction {
    case undo, redo, ocr, translate, pin, scroll, record, save, saveAs, cancel, copy
}

/// Annotation tool state; shared so the last tool/color/size are remembered between captures.
final class OverlayState: ObservableObject {
    static let shared = OverlayState()

    static let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.84, blue: 0.04, alpha: 1), // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // green
        NSColor(srgbRed: 0.04, green: 0.52, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1), // purple
        .white,
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1), // black
    ]
    static let widths: [CGFloat] = [2, 4, 7]

    @Published var tool: Tool?
    @Published var color: NSColor = palette[0]
    @Published var widthIndex = 1
    @Published var canUndo = false
    @Published var canRedo = false

    var width: CGFloat { OverlayState.widths[widthIndex] }
}

struct CaptureToolbar: View {
    @ObservedObject var state: OverlayState
    let showsAnnotationTools: Bool
    let onAction: (ToolbarAction) -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                if showsAnnotationTools {
                    ForEach(Tool.allCases) { tool in
                        ToolButton(symbol: tool.symbol, help: tool.title, selected: state.tool == tool) {
                            state.tool = state.tool == tool ? nil : tool
                        }
                    }
                    Divider().frame(height: 18).padding(.horizontal, 4)
                    ToolButton(symbol: "arrow.uturn.backward", help: L("toolbar.undo"), enabled: state.canUndo) { onAction(.undo) }
                    ToolButton(symbol: "arrow.uturn.forward", help: L("toolbar.redo"), enabled: state.canRedo) { onAction(.redo) }
                    Divider().frame(height: 18).padding(.horizontal, 4)
                }
                ToolButton(symbol: "text.viewfinder", help: L("toolbar.ocr")) { onAction(.ocr) }
                ToolButton(symbol: "translate", help: L("toolbar.translate")) { onAction(.translate) }
                ToolButton(symbol: "pin", help: L("toolbar.pin")) { onAction(.pin) }
                ToolButton(symbol: "rectangle.expand.vertical", help: L("toolbar.scroll")) { onAction(.scroll) }
                ToolButton(symbol: "record.circle", help: L("toolbar.record")) { onAction(.record) }
                ToolButton(symbol: "square.and.arrow.down", help: L("toolbar.save")) { onAction(.save) }
                    .contextMenu { Button(L("common.saveAs")) { onAction(.saveAs) } }
                Divider().frame(height: 18).padding(.horizontal, 4)
                ToolButton(symbol: "xmark", help: L("toolbar.cancel")) { onAction(.cancel) }
                ToolButton(symbol: "checkmark", help: L("toolbar.copyDone"), tint: .accentColor) { onAction(.copy) }
            }
            .padding(5)
            .background(Panel())

            if let tool = state.tool {
                HStack(spacing: 8) {
                    if tool.usesColor {
                        ForEach(Array(OverlayState.palette.enumerated()), id: \.offset) { _, color in
                            Button { state.color = color } label: {
                                Circle()
                                    .fill(Color(nsColor: color))
                                    .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                                    .frame(width: 16, height: 16)
                                    .padding(3)
                                    .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: state.color == color ? 2 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(color.hexString)
                            .accessibilityAddTraits(state.color == color ? .isSelected : [])
                        }
                        Divider().frame(height: 18)
                    }
                    ForEach(OverlayState.widths.indices, id: \.self) { i in
                        Button { state.widthIndex = i } label: {
                            Circle()
                                .fill(.primary)
                                .frame(width: 4 + CGFloat(i) * 4, height: 4 + CGFloat(i) * 4)
                                .frame(width: 24, height: 24)
                                .background(RoundedRectangle(cornerRadius: 6)
                                    .fill(state.widthIndex == i ? Color.primary.opacity(0.14) : .clear))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help([L("toolbar.width.thin"), L("toolbar.width.medium"), L("toolbar.width.thick")][i])
                        .accessibilityLabel([L("toolbar.width.thin"), L("toolbar.width.medium"), L("toolbar.width.thick")][i])
                        .accessibilityAddTraits(state.widthIndex == i ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Panel())
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: state.tool)
        .fixedSize()
    }
}

private struct Panel: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(.regularMaterial)
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

struct ToolButton: View {
    let symbol: String
    let help: String
    var selected = false
    var enabled = true
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(selected ? Color.white : (tint ?? Color.primary))
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selected ? Color.accentColor : (hovering ? Color.primary.opacity(0.1) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(help)
        // VoiceOver: the tool's name ("箭头"), not the symbol's description ("右上对角箭头").
        .accessibilityLabel(help.components(separatedBy: " (").first ?? help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
