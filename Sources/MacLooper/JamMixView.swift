import SwiftUI
import JamDesignKit

struct JamMixView: View {
    @ObservedObject var looper: LooperModel
    @ObservedObject var files: AudioFilePlayerModel
    @ObservedObject var drums: PopDrummerModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Mix", systemImage: "slider.vertical.3").font(.headline)
            HStack(alignment: .top, spacing: 18) {
                channel("Player", volume: $files.volume)
                channel("Drummer", volume: $drums.volume)
                channel("Looper", volume: $looper.volume)
            }
        }.padding(20).frame(width: 376).background(JamDesign.card)
            .foregroundStyle(JamDesign.text).tint(JamDesign.accent)
    }
    private func channel(_ name: String, volume: Binding<Double>) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 3) {
                VolumeNumberField(value: Binding(get: { (volume.wrappedValue * 100).rounded() },
                    set: { volume.wrappedValue = min(100, max(0, $0)) / 100 }), label: "Mix \(name) volume percentage")
                    .jamNumberField(width: 42, fontSize: 12)
                Text("%").font(.caption).foregroundStyle(JamDesign.secondary)
            }
            JamMixFader(volume: volume, name: name)
            Text(name).font(.callout.weight(.medium))
        }.frame(maxWidth: .infinity)
    }
}

private struct JamMixFader: View {
    @Binding var volume: Double
    let name: String
    var body: some View {
        GeometryReader { geo in
            let travel = max(1, geo.size.height - 20)
            let position = (1 - min(1, max(0, volume))) * travel + 10
            ZStack(alignment: .top) {
                Capsule().fill(JamDesign.control).frame(width: 5, height: travel).offset(y: 10)
                Capsule().fill(JamDesign.accent).frame(width: 5, height: max(0, travel * volume))
                    .offset(y: position)
                RoundedRectangle(cornerRadius: 5).fill(JamDesign.text).frame(width: 30, height: 16)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 2).offset(y: position - 8)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    volume = min(1, max(0, 1 - (drag.location.y - 10) / travel))
                })
        }.frame(width: 44, height: 154).hoverHighlight()
            .accessibilityElement().accessibilityLabel("Mix \(name) volume")
            .accessibilityValue("\(Int((volume * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                volume = min(1, max(0, volume + (direction == .increment ? 0.1 : -0.1)))
            }
    }
}
