import Foundation

/// Opt-in checks using the SAME app-owned connection and verified edit methods
/// as the UI. No preset navigation/model replacement or permanent Save commands.
@MainActor public enum AM4RemoteDiagnostics {
    public static func run(session: AM4RemoteSession, exerciseControls: Bool = false) async throws -> [String] {
        #if targetEnvironment(simulator)
        throw Failure("AM4 hardware checks require a native Mac or iPad USB connection.")
        #else
        let connection = session.connection
        session.present()
        defer { session.dismiss() }
        for _ in 0..<150 {
            if connection.isConnected, connection.snapshot != nil, connection.location != nil, connection.blocks != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard connection.isConnected, let snapshot = connection.snapshot, let location = connection.location,
              let blocks = connection.blocks else { throw Failure("AM4 did not complete its initial read: " + connection.status + " / " + connection.blockStatus) }
        // Page requests below explicitly refresh. Suppress independent polling
        // during the checks so each batch has one owner.
        connection.pollingEnabled = false
        var completed = false
        var report = ["AM4 USB connected: \(AM4Message.locationLabel(location)), scene \(snapshot.scene + 1), \(blocks.blocks.count) blocks"]
        defer { if !completed { for line in report { print("AM4 check: " + line) } } }
        if snapshot.blockIDs.contains(58) {
            for page in AM4AmpCatalog.shared.pages {
                await connection.showAmpPage(page.id)
                guard let controls = connection.ampControls, controls.page == page.id,
                      controls.context.location == location, controls.context.scene == snapshot.scene else {
                    throw Failure("Amp page \(page.id) was not verified: " + connection.gainStatus)
                }
                report.append("Amp / \(page.title): \(controls.values.count) values read and context verified")
            }
            if exerciseControls {
                try await exerciseGainAndClose(session: session, report: &report)
                try await exerciseAmpEditor(session: session, report: &report)
            }
        } else { report.append("SKIP: this preset has no Amp block; no Gain edit performed") }
        for block in blocks.blocks {
            guard let effect = AM4EffectsCatalog.shared.effect(Int(block.type)) else { continue }
            for page in effect.pages {
                try await connection.showEffectPage(AM4EffectPageSelection(slot: block.slot, block: Int(block.type), page: page.id))
                guard let controls = connection.effectControls, controls.page == page.id,
                      controls.context.location == location, controls.context.scene == snapshot.scene else {
                    throw Failure("\(effect.name) / \(page.title) was not verified: " + connection.gainStatus)
                }
                report.append("\(effect.name) / \(page.title): \(controls.values.count) values read and context verified")
            }
            if exerciseControls, let page = effect.pages.first {
                try await exerciseEffectEditor(connection: connection,
                    selection: AM4EffectPageSelection(slot: block.slot, block: Int(block.type), page: page.id), report: &report)
            }
        }
        session.dismiss()
        guard connection.ampPage == nil, connection.effectPage == nil else { throw Failure("Remote retained a hidden page subscription.") }
        session.present(); connection.pollingEnabled = false
        guard session.connection === connection, connection.ampPage == nil, connection.effectPage == nil else { throw Failure("Remote did not reopen on its main page.") }
        report.append("Remote Close/reopen preserves its connection and clears page subscriptions")
        report.append("PASS: native USB reads verified; no permanent preset save or preset/scene navigation")
        completed = true
        return report
        #endif
    }
    private static func exerciseGainAndClose(session: AM4RemoteSession, report: inout [String]) async throws {
        let connection = session.connection
        await connection.showAmpPage("Amp")
        guard let original = connection.amp else { throw Failure("No current Amp Gain to test.") }
        let target = original.gain < 9.8 ? original.gain + 0.1 : original.gain - 0.1
        do {
            let edit = Task { try await connection.changeGain(AM4GainCommand(expected: original, gain: target)) }
            for _ in 0..<100 where !connection.isApplyingGain { await Task.yield() }
            guard connection.isApplyingGain else { try await edit.value; throw Failure("Gain edit finished before Close could be exercised.") }
            session.dismiss()
            let pageCleared = connection.ampPage == nil && connection.effectPage == nil
            try await edit.value
            guard pageCleared else { throw Failure("Close retained the Amp page during a verified edit.") }
            guard let changed = connection.amp, changed.context == original.context, abs(changed.gain - target) <= 0.005 else { throw Failure("Temporary Gain change was not read back.") }
            session.present(); connection.pollingEnabled = false
            try await connection.changeGain(AM4GainCommand(expected: changed, gain: original.gain))
            guard let restored = connection.amp, restored.matches(original) else { throw Failure("Original Gain was not restored.") }
            report.append(String(format: "Gain %.2f → %.2f → %.2f verified; Close during edit completed without disconnecting", original.gain, target, restored.gain))
        } catch {
            let editError = error
            // Restore only in the original preset/scene/channel, using a fresh
            // read as the expected value. Never write blindly into a new context.
            await connection.showAmpPage("Amp")
            guard let current = connection.amp, current.context == original.context else {
                throw Failure("Check the AM4: its context changed before Gain restoration. Original Gain was \(original.gain). " + editError.localizedDescription)
            }
            if !current.matches(original) {
                do { try await connection.changeGain(AM4GainCommand(expected: current, gain: original.gain)) }
                catch { throw Failure("Original Gain \(original.gain) could not be restored/verified. " + error.localizedDescription) }
            }
            throw editError
        }
    }
    private static func exerciseAmpEditor(session: AM4RemoteSession, report: inout [String]) async throws {
        let connection = session.connection
        await connection.showAmpPage("Amp")
        guard let original = connection.ampControls, let value = original.values["58:11"] else {
            report.append("SKIP: current Amp model has no front-panel Gain control"); return
        }
        let target = value.normalized < 0.98 ? value.normalized + 0.01 : value.normalized - 0.01
        do {
            let command = AM4AmpEdit(context: original.context, model: original.model, page: original.page, key: "58:11", expected: value, normalized: target)
            var finished = false
            let edit = Task { defer { finished = true }; try await connection.changeAmpParameter(command) }
            // Wait until the verified edit has actually sent its write, so Close
            // exercises read-back completion rather than cancelling a preflight.
            for _ in 0..<1000 {
                if connection.gainStatus == "Applying change…" || finished { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            let closedWhileBusy = connection.isApplyingGain
            session.dismiss()
            try await edit.value
            guard closedWhileBusy, connection.ampPage == nil else { throw Failure("Could not exercise Close during the Amp editor write.") }
            session.present(); connection.pollingEnabled = false
            await connection.showAmpPage(original.page)
            guard let changed = connection.ampControls, changed.context == original.context, changed.model == original.model,
                  let actual = changed.values["58:11"], command.isConfirmed(by: actual) else { throw Failure("Amp editor change was not verified.") }
            try await restoreAmp(connection, original: original, value: value)
            report.append("Amp editor parameter write/read-back/restore verified; Close after send preserved verification")
        } catch {
            let failure = error
            do { try await restoreAmp(connection, original: original, value: value) }
            catch { throw Failure("Amp editor restoration was not verified: " + error.localizedDescription) }
            throw failure
        }
    }
    private static func restoreAmp(_ connection: AM4Connection, original: AM4AmpControls, value: AM4ParameterValue) async throws {
        await connection.showAmpPage(original.page)
        guard let current = connection.ampControls, current.context == original.context, current.model == original.model,
              let actual = current.values["58:11"] else { throw Failure("Original Amp preset/scene/channel is no longer active.") }
        if !actual.matches(value) {
            try await connection.changeAmpParameter(AM4AmpEdit(context: current.context, model: current.model, page: current.page,
                key: "58:11", expected: actual, normalized: value.normalized))
        }
        guard let restored = connection.ampControls?.values["58:11"], abs(restored.normalized - value.normalized) <= 3 / 65534 else { throw Failure("Original Amp Gain was not restored.") }
    }
    private static func exerciseEffectEditor(connection: AM4Connection, selection: AM4EffectPageSelection, report: inout [String]) async throws {
        try await connection.showEffectPage(selection)
        guard let original = connection.effectControls, let effect = AM4EffectsCatalog.shared.effect(selection.block),
              let control = effect.controls(page: original.page, values: original.values).first(where: { ["BLOCK_LEVEL", "FUZZ_LEVEL"].contains(effect.definition($0.key)?.symbol ?? "") }),
              let value = original.values[control.key] else { report.append("SKIP: no front-panel effect Level control"); return }
        let target = value.normalized < 0.98 ? value.normalized + 0.01 : value.normalized - 0.01
        do {
            let edit = AM4EffectEdit(state: original, key: control.key, expected: value, normalized: target)
            try await connection.changeEffectParameter(edit)
            guard let changed = connection.effectControls?.values[control.key], edit.confirmed(changed, reset: nil) else { throw Failure("Effect editor change was not verified.") }
            try await restoreEffect(connection, selection: selection, original: original, key: control.key, value: value)
            report.append("\(effect.name) Level: editor write/read-back/restore verified")
        } catch {
            let failure = error
            do { try await restoreEffect(connection, selection: selection, original: original, key: control.key, value: value) }
            catch { throw Failure("Effect Level restoration was not verified: " + error.localizedDescription) }
            throw failure
        }
    }
    private static func restoreEffect(_ connection: AM4Connection, selection: AM4EffectPageSelection, original: AM4EffectControls, key: String, value: AM4ParameterValue) async throws {
        try await connection.showEffectPage(selection)
        guard let current = connection.effectControls, current.context == original.context, current.model == original.model,
              let actual = current.values[key] else { throw Failure("Original effect preset/scene/channel is no longer active.") }
        if !actual.matches(value) { try await connection.changeEffectParameter(AM4EffectEdit(state: current, key: key, expected: actual, normalized: value.normalized)) }
        guard let restored = connection.effectControls?.values[key], abs(restored.normalized - value.normalized) <= 3 / 65534 else { throw Failure("Original effect Level was not restored.") }
    }
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
