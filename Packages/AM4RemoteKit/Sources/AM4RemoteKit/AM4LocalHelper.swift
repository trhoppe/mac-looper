import Foundation
#if AM4_SIMULATOR_HELPER
import Network
/// Loopback-only helper with validated, read-back-verified Amp operations.
@MainActor
final class AM4LocalHelper {
    var onStatus: ((String) -> Void)?
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private let state: () -> AM4DeviceState?
    private let setGain: (AM4GainCommand) async throws -> AM4DeviceState
    private let selectPage: (String?) async throws -> AM4DeviceState
    private let editAmp: (AM4AmpEdit) async throws -> AM4DeviceState
    private let selectAmp: (AM4AmpSelection) async throws -> AM4DeviceState
    private let selectEffectPage: (AM4EffectPageSelection) async throws -> AM4DeviceState
    private let editEffect: (AM4EffectEdit) async throws -> AM4DeviceState
    private let selectEffect: (AM4EffectSelection) async throws -> AM4DeviceState
    private let navigate: (AM4NavigationCommand) async throws -> AM4DeviceState
    private let bypassBlock: (AM4BlockBypassCommand) async throws -> AM4DeviceState
    private let setUSBPlayback: (AM4USBPlaybackCommand) async throws -> AM4DeviceState
    private let savePreset: (AM4PresetSaveCommand) async throws -> AM4DeviceState

    init(state: @escaping () -> AM4DeviceState?,
         setGain: @escaping (AM4GainCommand) async throws -> AM4DeviceState,
         selectPage: @escaping (String?) async throws -> AM4DeviceState,
         editAmp: @escaping (AM4AmpEdit) async throws -> AM4DeviceState,
         selectAmp: @escaping (AM4AmpSelection) async throws -> AM4DeviceState,
         selectEffectPage: @escaping (AM4EffectPageSelection) async throws -> AM4DeviceState,
         editEffect: @escaping (AM4EffectEdit) async throws -> AM4DeviceState,
         selectEffect: @escaping (AM4EffectSelection) async throws -> AM4DeviceState,
         navigate: @escaping (AM4NavigationCommand) async throws -> AM4DeviceState,
         bypassBlock: @escaping (AM4BlockBypassCommand) async throws -> AM4DeviceState,
         setUSBPlayback: @escaping (AM4USBPlaybackCommand) async throws -> AM4DeviceState,
         savePreset: @escaping (AM4PresetSaveCommand) async throws -> AM4DeviceState) {
        self.state = state
        self.setGain = setGain
        self.selectPage = selectPage
        self.editAmp = editAmp
        self.selectAmp = selectAmp
        self.selectEffectPage = selectEffectPage
        self.editEffect = editEffect
        self.selectEffect = selectEffect
        self.navigate = navigate
        self.bypassBlock = bypassBlock
        self.setUSBPlayback = setUSBPlayback; self.savePreset = savePreset
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 32174)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] event in
                Task { @MainActor in
                    switch event {
                    case .ready: self?.onStatus?("Helper ready · localhost:32174")
                    case .failed(let error): self?.onStatus?("Helper unavailable: \(error.localizedDescription). Close any older Mac helper.")
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
        } catch { onStatus?("Helper could not start: \(error.localizedDescription)") }
    }

    func stop() {
        listener?.cancel(); listener = nil
        let active = Array(connections.values)
        connections.removeAll()
        for connection in active { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        read(connection, id: id, buffer: Data())
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            self?.finish(id)
        }
    }

    private func read(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.connections[id] != nil else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                guard buffer.count <= 36_864, error == nil else { self.finish(id); return }
                guard let separator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    if complete { self.finish(id) }
                    else { self.read(connection, id: id, buffer: buffer) }
                    return
                }
                let lines = String(decoding: buffer[..<separator.lowerBound], as: UTF8.self)
                    .components(separatedBy: "\r\n")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else {
                        self.respond(id, status: "400 Bad Request", body: Data()); return
                    }
                    let name = line[..<colon].lowercased()
                    guard headers[name] == nil else {
                        self.respond(id, status: "400 Bad Request", body: Data()); return
                    }
                    headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                guard headers["transfer-encoding"] == nil,
                      let length = Int(headers["content-length"] ?? "0"), (0...32_768).contains(length) else {
                    self.respond(id, status: "400 Bad Request", body: Data()); return
                }
                let end = separator.upperBound + length
                guard buffer.count >= end else {
                    if complete { self.finish(id) }
                    else { self.read(connection, id: id, buffer: buffer) }
                    return
                }
                guard buffer.count == end else {
                    self.respond(id, status: "400 Bad Request", body: Data()); return
                }
                let line = lines.first ?? ""
                if line == "GET /state HTTP/1.1" || line == "GET /state HTTP/1.0" {
                    guard length == 0, let state = self.state(), let body = try? JSONEncoder().encode(state) else {
                        self.respond(id, status: "503 Service Unavailable", body: Data()); return
                    }
                    self.respond(id, status: "200 OK", body: body)
                } else if line == "POST /amp/gain HTTP/1.1" {
                    guard headers["x-am4-client"] == "AM4Remote/2", headers["origin"] == nil,
                          headers["content-type"] == "application/json",
                          let command = try? JSONDecoder().decode(AM4GainCommand.self, from:
                            buffer.subdata(in: separator.upperBound..<end)), command.isValid else {
                        self.respond(id, status: "400 Bad Request", body: Data()); return
                    }
                    do {
                        let state = try await self.setGain(command)
                        self.respond(id, status: "200 OK", body: try JSONEncoder().encode(state))
                    } catch {
                        let body = (try? JSONEncoder().encode(AM4ControlError(message: error.localizedDescription))) ?? Data()
                        self.respond(id, status: "409 Conflict", body: body)
                    }
                } else if line == "POST /amp/page HTTP/1.1" || line == "POST /amp/parameter HTTP/1.1" || line == "POST /amp/select HTTP/1.1" || line == "POST /effect/page HTTP/1.1" || line == "POST /effect/parameter HTTP/1.1" || line == "POST /effect/select HTTP/1.1" || line == "POST /navigate HTTP/1.1" || line == "POST /blocks/bypass HTTP/1.1" || line == "POST /usb/playback HTTP/1.1" || line == "POST /preset/save HTTP/1.1" {
                    guard headers["x-am4-client"] == "AM4Remote/9", headers["origin"] == nil,
                          headers["content-type"] == "application/json" else {
                        self.respond(id, status: "400 Bad Request", body: Data()); return
                    }
                    let body = buffer.subdata(in: separator.upperBound..<end)
                    do {
                        let result: AM4DeviceState
                        if line == "POST /preset/save HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4PresetSaveCommand.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.savePreset(command)
                        } else if line == "POST /effect/page HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4EffectPageSelection.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.selectEffectPage(command)
                        } else if line == "POST /effect/parameter HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4EffectEdit.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.editEffect(command)
                        } else if line == "POST /effect/select HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4EffectSelection.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.selectEffect(command)
                        } else if line == "POST /amp/page HTTP/1.1" {
                            guard let selection = try? JSONDecoder().decode(AM4PageSelection.self, from: body),
                                  selection.page == nil || AM4AmpCatalog.shared.page(selection.page!) != nil else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.selectPage(selection.page)
                        } else if line == "POST /amp/select HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4AmpSelection.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.selectAmp(command)
                        } else if line == "POST /usb/playback HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4USBPlaybackCommand.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.setUSBPlayback(command)
                        } else if line == "POST /blocks/bypass HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4BlockBypassCommand.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.bypassBlock(command)
                        } else if line == "POST /navigate HTTP/1.1" {
                            guard let command = try? JSONDecoder().decode(AM4NavigationCommand.self, from: body), command.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.navigate(command)
                        } else {
                            guard let edit = try? JSONDecoder().decode(AM4AmpEdit.self, from: body), edit.isValid else {
                                self.respond(id, status: "400 Bad Request", body: Data()); return
                            }
                            result = try await self.editAmp(edit)
                        }
                        self.respond(id, status: "200 OK", body: try JSONEncoder().encode(result))
                    } catch {
                        let body = (try? JSONEncoder().encode(AM4ControlError(message: error.localizedDescription))) ?? Data()
                        self.respond(id, status: "409 Conflict", body: body)
                    }
                } else { self.respond(id, status: "404 Not Found", body: Data()) }
            }
        }
    }

    private func respond(_ id: UUID, status: String, body: Data) {
        guard let connection = connections[id] else { return }
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.finish(id) }
        })
    }

    private func finish(_ id: UUID) { connections.removeValue(forKey: id)?.cancel() }
}
#endif
