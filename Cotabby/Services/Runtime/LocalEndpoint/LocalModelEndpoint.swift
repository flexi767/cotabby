import Foundation
import Logging
import Network

/// File overview:
/// Lets other apps on this Mac use Cotabby's already-loaded llama model, so dictation apps
/// (VoiceInk's and Handy's "Custom" providers) share one model in memory instead of each loading
/// their own. It is a small HTTP listener on 127.0.0.1 speaking the OpenAI chat protocol; the pure
/// request and response rules live in `LocalEndpointProtocol`.
///
/// Off by default: `defaults write <bundle id> cotabbyLocalEndpointEnabled -bool YES`, optional
/// `cotabbyLocalEndpointPort` (default 11435), read at launch. Safety:
/// - it listens on the loopback interface only, so nothing outside this Mac can connect;
/// - a request carrying an `Origin` header is refused: browsers send one on every cross-site
///   request, so a web page cannot make Cotabby generate;
/// - requests run one at a time through the same runtime as autocomplete (`generateChat`).
///
/// Owned by `CotabbyAppEnvironment` for the app's lifetime. Connections are handled on a private
/// queue; generation hops to the main actor, where `LlamaRuntimeManager` lives.
final class LocalModelEndpoint: @unchecked Sendable {
    static let enabledDefaultsKey = "cotabbyLocalEndpointEnabled"
    static let portDefaultsKey = "cotabbyLocalEndpointPort"
    static let defaultPort: UInt16 = 11435

    private let runtime: LlamaRuntimeManager
    private let queue = DispatchQueue(label: "com.cotabby.local-endpoint")
    private var listener: NWListener?

    init(runtime: LlamaRuntimeManager) {
        self.runtime = runtime
    }

    /// Starts listening when the hidden setting is on; otherwise does nothing.
    func startIfEnabled(defaults: UserDefaults = .standard) {
        guard defaults.bool(forKey: Self.enabledDefaultsKey) else { return }
        let configured = defaults.integer(forKey: Self.portDefaultsKey)
        let port = (1 ... 65535).contains(configured) ? UInt16(configured) : Self.defaultPort
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        do {
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    CotabbyLogger.runtime.info("Local model endpoint listening", metadata: ["port": .stringConvertible(port)])
                case let .failed(error):
                    CotabbyLogger.runtime.error("Local model endpoint failed", metadata: ["error": .string("\(error)")])
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            CotabbyLogger.runtime.error("Local model endpoint could not start", metadata: ["error": .string("\(error)")])
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch LocalEndpointProtocol.parse(buffer) {
            case .incomplete where error == nil && !isComplete:
                self.receive(on: connection, buffer: buffer)
            case .incomplete, .malformed:
                self.send(LocalEndpointProtocol.error(status: 400, "Malformed request"), on: connection)
            case .tooLarge:
                self.send(LocalEndpointProtocol.error(status: 413, "Request too large"), on: connection)
            case let .complete(request):
                Task { @MainActor in
                    let response = await self.respond(to: request)
                    self.send(response, on: connection)
                }
            }
        }
    }

    private func send(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    @MainActor
    private func respond(to request: LocalEndpointProtocol.Request) async -> Data {
        if request.headers["origin"] != nil {
            return LocalEndpointProtocol.error(status: 403, "Browser requests are not accepted", type: "forbidden")
        }
        let modelID = runtime.currentModelFilename.map { ($0 as NSString).deletingPathExtension } ?? "cotabby"
        switch (request.method, request.path) {
        case ("GET", let path) where path.hasSuffix("/models"):
            return LocalEndpointProtocol.models(modelID: modelID)
        case ("POST", let path) where path.hasSuffix("/chat/completions"):
            let chat: LocalEndpointProtocol.ChatRequest
            do {
                chat = try LocalEndpointProtocol.decodeChat(request.body)
            } catch {
                return LocalEndpointProtocol.error(status: 400, "Expected an OpenAI chat request with messages")
            }
            let started = Date()
            do {
                let output = try await runtime.generateChat(
                    messages: chat.messages, maxTokens: chat.maxTokens, temperature: chat.temperature
                )
                CotabbyLogger.runtime.info("Local endpoint answered", metadata: [
                    "messages": .stringConvertible(chat.messages.count),
                    "ms": .stringConvertible(Int(Date().timeIntervalSince(started) * 1000)),
                ])
                return LocalEndpointProtocol.chatCompletion(
                    text: LocalEndpointProtocol.cleanedAnswer(output.text), modelID: modelID, stream: chat.stream,
                    created: Int(Date().timeIntervalSince1970), id: "chatcmpl-\(UUID().uuidString)"
                )
            } catch {
                CotabbyLogger.runtime.error("Local endpoint generation failed", metadata: ["error": .string("\(error)")])
                return LocalEndpointProtocol.error(status: 503, "The local model is not available: \(error)", type: "unavailable")
            }
        case (_, let path) where path.hasSuffix("/models") || path.hasSuffix("/chat/completions"):
            return LocalEndpointProtocol.error(status: 405, "Method not allowed")
        default:
            return LocalEndpointProtocol.error(status: 404, "Not found")
        }
    }
}
