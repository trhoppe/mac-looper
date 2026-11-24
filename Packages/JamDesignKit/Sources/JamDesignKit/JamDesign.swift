import SwiftUI

public enum JamDesign {
    private static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
    public static let ground = color(0x121214)
    public static let card = color(0x1B1B1F)
    public static let control = color(0x26262C)
    public static let text = color(0xF2F2F5)
    public static let secondary = color(0xA3A3AD)
    public static let accent = color(0x5AB8F5)
    public static let recording = color(0xFF4D4F)
    public static let playing = color(0x34D399)
    public static let armed = color(0xF5A524)
    public static let border = Color.white.opacity(0.09)
    public static let selection = color(0x303036)
    public static let radius: CGFloat = 14
    public static let gap: CGFloat = 12
    public static let target: CGFloat = 36
    public static let moduleTitleFont = Font.system(size: 15, weight: .semibold)

}

private struct JamFeedback: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    let radius: CGFloat
    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: radius).fill(.white.opacity(enabled && hovering ? 0.065 : 0))
                .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(enabled && hovering ? 0.13 : 0)) }
                .allowsHitTesting(false)
        }.contentShape(RoundedRectangle(cornerRadius: radius))
            .onHover { hovering = $0 }.animation(.easeOut(duration: 0.12), value: hovering)
    }
}

public extension View {
    func jamFeedback(radius: CGFloat = 8) -> some View { modifier(JamFeedback(radius: radius)) }
    func jamSurface(padding: CGFloat = 16, border: Color = JamDesign.border) -> some View {
        self.padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(JamDesign.card, in: RoundedRectangle(cornerRadius: JamDesign.radius))
            .overlay { RoundedRectangle(cornerRadius: JamDesign.radius).strokeBorder(border) }
    }
}

public struct JamControlStyle: ButtonStyle {
    public var active: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlSize) private var size
    public init(active: Bool = false) { self.active = active }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .medium))
            .foregroundStyle(active ? JamDesign.accent : JamDesign.text)
            .padding(.horizontal, size == .small || size == .mini ? 8 : 12)
            .padding(.vertical, size == .small || size == .mini ? 5 : 8)
            .background(active ? JamDesign.accent.opacity(0.16) : JamDesign.control, in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.35).jamFeedback()
    }
}

public struct JamIconStyle: ButtonStyle {
    public var active: Bool
    @Environment(\.isEnabled) private var enabled
    public init(active: Bool = false) { self.active = active }
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 17, weight: .regular))
            .frame(width: JamDesign.target, height: JamDesign.target)
            .background(active ? JamDesign.accent.opacity(0.16) : JamDesign.control, in: RoundedRectangle(cornerRadius: 8))
            .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.35).jamFeedback()
    }
}

public struct JamScreenHeader: View {
    let title: String
    let icon: String
    let close: () -> Void
    let closeOnEscape: Bool
    public init(_ title: String, icon: String, closeOnEscape: Bool = true, close: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.closeOnEscape = closeOnEscape; self.close = close
    }
    public var body: some View {
        HStack {
            Label(title, systemImage: icon).font(.system(size: 17, weight: .semibold))
            Spacer()
            Button("Close", action: close).buttonStyle(JamControlStyle()).keyboardShortcut(closeOnEscape ? KeyboardShortcut.cancelAction : nil)
                .accessibilityLabel("Close \(title)")
        }.padding(.horizontal, 20).padding(.vertical, 14)
            .foregroundStyle(JamDesign.text).background(JamDesign.card)
    }
}

/// Module headings use the same type and icon size in every layout.
public struct JamModuleTitle: View {
    let title: String
    let icon: String
    public init(_ title: String, icon: String) { self.title = title; self.icon = icon }
    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 17, weight: .regular))
            Text(title).font(JamDesign.moduleTitleFont)
        }.foregroundStyle(JamDesign.text).fixedSize(horizontal: true, vertical: false)
    }
}

/// Shared trigger treatment for the app's bounded dropdowns.
public struct JamDropdownLabel: View {
    let title: String
    let icon: String?
    let compact: Bool
    let active: Bool
    let moduleTitle: Bool
    public init(_ title: String, icon: String? = nil, compact: Bool = false, active: Bool = false, moduleTitle: Bool = false) {
        self.title = title; self.icon = icon; self.compact = compact; self.active = active; self.moduleTitle = moduleTitle
    }
    public var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 17, weight: .regular)) }
            if !compact { Text(title).font(moduleTitle ? JamDesign.moduleTitleFont : .system(size: 14, weight: .medium)) }
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium))
        }.foregroundStyle(moduleTitle ? JamDesign.text : active ? JamDesign.accent : JamDesign.secondary)
            .padding(.horizontal, 8).frame(minHeight: JamDesign.target)
            .background(active ? JamDesign.accent.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
    }
}
