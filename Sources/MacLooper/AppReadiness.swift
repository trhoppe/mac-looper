import SwiftUI
import Combine

struct AppReadiness: Equatable {
    let title: String
    let detail: String
    var ready: Bool { title == "Ready" }
    var warning: Bool { title.hasPrefix("Check") }
}

@MainActor final class AppReadinessModel: ObservableObject {
    @Published private(set) var value = AppReadiness(title: "Connecting", detail: "Preparing audio")
    init(audio: LooperModel, drums: PopDrummerModel, files: AudioFilePlayerModel, library: SongLibraryModel) {
        let route = Publishers.CombineLatest3(audio.$running, audio.$starting, audio.$error)
        let instrument = Publishers.CombineLatest3(drums.$ready, drums.$loading, drums.$error)
        let loading = Publishers.CombineLatest4(files.$loading, library.$syncing, files.$error, library.$error)
        Publishers.CombineLatest3(route, instrument, loading).map { route, instrument, loading in
            if let error = route.2 { return AppReadiness(title: "Check audio", detail: error) }
            if let error = instrument.2 { return AppReadiness(title: "Check drummer", detail: error) }
            if let error = loading.2 { return AppReadiness(title: "Check player", detail: error) }
            if let error = loading.3 { return AppReadiness(title: "Check library", detail: error) }
            if route.1 { return AppReadiness(title: "Connecting", detail: "Preparing audio") }
            if !route.0 { return AppReadiness(title: "Waiting", detail: "Connect your audio interface or check Settings") }
            if loading.0 || loading.1 { return AppReadiness(title: "Loading", detail: "Loading your track or song library") }
            return AppReadiness(title: "Ready", detail: instrument.1 ? "Audio ready · Drummer loading" : "Audio ready")
        }.removeDuplicates().assign(to: &$value)
    }
}

struct AppReadinessBadge: View {
    @ObservedObject var model: AppReadinessModel
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(model.value.ready ? Color.cyan : model.value.warning ? .orange : .secondary).frame(width: 7, height: 7)
            Text(model.value.title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }.help(model.value.detail).accessibilityLabel("App status: \(model.value.title)")
    }
}
