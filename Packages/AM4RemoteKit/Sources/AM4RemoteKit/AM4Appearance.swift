import SwiftUI

enum AM4Appearance {
    static let accent = Color(red: 0.259, green: 0.788, blue: 0.961)
    static let background = Color(red: 0.065, green: 0.075, blue: 0.085)
    static let panel = Color(red: 0.075, green: 0.085, blue: 0.10)
}

/// Match the song/file rows. Hover state stays local, independent of MIDI updates.
private struct AM4HoverHighlight: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var radius: CGFloat
    var suppressHover: Bool
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius)
                    .fill(.white.opacity(enabled && hovering && !suppressHover ? 0.075 : 0))
                    .shadow(color: .black.opacity(enabled && hovering && !suppressHover ? 0.12 : 0), radius: 3, y: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: radius))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: enabled && hovering && !suppressHover)
    }
}

extension View {
    func am4HoverHighlight(radius: CGFloat = 6, suppressHover: Bool = false) -> some View {
        modifier(AM4HoverHighlight(radius: radius, suppressHover: suppressHover))
    }
}

/// Explicitly include the label's padding and spacers in the button hit region.
struct AM4ButtonStyle: ButtonStyle {
    var isSelected = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(configuration.isPressed ? 0.12 : 0)))
            .am4HoverHighlight(suppressHover: isSelected)
            .opacity(enabled ? 1 : 0.45)
    }
}

struct AM4MenuChoice: Identifiable, Equatable {
    let id: String
    let name: String
}

enum AM4MenuChoices {
    static let ampTypes = models(AM4AmpCatalog.shared.models)
    static let ampLibrary = AM4AmpLibrary.shared.entries.map { AM4MenuChoice(id: $0.id, name: $0.name) }
    static let effectTypes = Dictionary(uniqueKeysWithValues: AM4EffectsCatalog.shared.effects.map { ($0.block, models($0.models)) })
    static let effectLibraries = Dictionary(uniqueKeysWithValues: AM4EffectsCatalog.shared.effects.map { effect in
        (effect.block, AM4EffectsLibrary.shared.entries.filter { $0.block == effect.block }.map {
            AM4MenuChoice(id: $0.id, name: $0.name + ($0.parsed?.allChannels == true ? " · All channels" : ""))
        })
    })
    private static func models(_ names: [String]) -> [AM4MenuChoice] {
        names.enumerated().map { AM4MenuChoice(id: String($0.offset), name: $0.element) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Native popup controls, isolated from frequent meter/MIDI publications.
/// Identity includes the expected hardware context: replacing it when context
/// changes closes an old popup instead of applying its choice to another preset.
struct AM4Dropdown: View, Equatable {
    let title: String
    let accessibilityName: String
    let choices: [AM4MenuChoice]
    let selected: String?
    var placeholder: String? = nil
    let identity: String
    let choose: (String) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.title == rhs.title && lhs.accessibilityName == rhs.accessibilityName && lhs.choices == rhs.choices &&
        lhs.selected == rhs.selected && lhs.placeholder == rhs.placeholder && lhs.identity == rhs.identity
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Picker(title, selection: Binding(get: { selected }, set: { value in
                guard let value, value != selected else { return }
                choose(value)
            })) {
                if let placeholder { Text(placeholder).tag(String?.none) }
                ForEach(choices) { Text($0.name).tag(Optional($0.id)) }
            }.labelsHidden().pickerStyle(.menu).controlSize(.regular)
                .frame(maxWidth: .infinity, minHeight: 28).am4ControlHover()
                .accessibilityLabel(accessibilityName)
                .disabled(choices.isEmpty)
                .id(identity)
        }
    }
}

/// Keep the compact single header on Mac, wrapping fields below the title when
/// an iPad window does not have room for both native dropdowns on the same line.
struct AM4EditorHeader<Controls: View>: View {
    let title: String
    let subtitle: String?
    let busy: Bool
    let close: () -> Void
    @ViewBuilder let controls: () -> Controls
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                heading.fixedSize(horizontal: true, vertical: false)
                controls().frame(width: 500)
                Spacer(minLength: 4)
                closeButton
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack { heading; Spacer(); closeButton }
                controls().frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }
    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold))
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var closeButton: some View {
        HStack(spacing: 12) {
            if busy { ProgressView().controlSize(.small) }
            Button("Close", action: close).buttonStyle(AM4NativeButtonStyle())
                .accessibilityLabel("Close block editor").disabled(busy)
        }
    }
}

// Full-width preset feedback shares the selected row's exact bounds and fill.
private struct AM4PresetRowHighlight: ViewModifier {
    let selected: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(selected || (enabled && hovering) ? Color(white: 0.19) : AM4Appearance.background)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: selected || (enabled && hovering))
    }
}

extension View {
    func am4PresetRowHighlight(selected: Bool) -> some View { modifier(AM4PresetRowHighlight(selected: selected)) }
}

private struct AM4ControlHover: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func body(content: Content) -> some View {
        content.overlay {
            RoundedRectangle(cornerRadius: 6)
                .fill(.white.opacity(enabled && hovering ? 0.075 : 0))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(enabled && hovering ? 0.14 : 0)) }
                .allowsHitTesting(false)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: enabled && hovering)
    }
}

extension View {
    func am4ControlHover() -> some View { modifier(AM4ControlHover()) }
}

struct AM4NativeButtonStyle: PrimitiveButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        Group {
            if prominent { Button(configuration).buttonStyle(.borderedProminent) }
            else { Button(configuration).buttonStyle(.bordered) }
        }.am4ControlHover()
    }
}
