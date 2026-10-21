import Foundation

/// File overview:
/// The pure half of the local model endpoint (`LocalModelEndpoint`): reading one HTTP/1.1 request
/// off a byte stream, decoding an OpenAI-style chat request, and encoding the responses. Other apps
/// on this Mac (VoiceInk's and Handy's "Custom" providers) speak exactly this protocol, so they can
/// use Cotabby's already-loaded model instead of loading a second copy of their own.
///
/// Kept free of sockets and the runtime so every rule here is unit-tested without either. Only the
/// subset those clients send is understood: `POST .../chat/completions` (non-streaming, or streaming
/// answered as a single chunk) and `GET .../models`.
nonisolated enum LocalEndpointProtocol {
    /// A request body larger than this is refused: a dictation cleanup is a few kilobytes.
    static let maximumRequestBytes = 1_048_576
    /// Answer length used when the client names none, and the most a client may ask for. The
    /// runtime's context window is 4096 tokens, and the prompt needs room beside the answer.
    static let defaultMaxTokens = 1024
    static let maximumMaxTokens = 2048
    static let defaultTemperature = 0.3

    struct Request: Equatable {
        let method: String
        /// The path without its query string ("/v1/chat/completions?priority=1" -> "/v1/chat/completions").
        let path: String
        /// Header names lowercased.
        let headers: [String: String]
        let body: Data
    }

    enum ParseResult: Equatable {
        case incomplete
        case malformed
        case tooLarge
        case complete(Request)
    }

    /// Parses one request from the bytes received so far on a connection.
    static func parse(_ data: Data) -> ParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else {
            return data.count > maximumRequestBytes ? .tooLarge : .incomplete
        }
        guard let head = String(data: data[data.startIndex ..< headerEnd.lowerBound], encoding: .utf8) else {
            return .malformed
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .malformed }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .malformed }
        guard length <= maximumRequestBytes else { return .tooLarge }
        let bodyStart = headerEnd.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return .complete(Request(
            method: String(requestLine[0]).uppercased(),
            path: path,
            headers: headers,
            body: data.subdata(in: bodyStart ..< bodyStart + length)
        ))
    }

    /// A chat request as the runtime needs it.
    struct ChatRequest: Equatable {
        let messages: [LlamaChatMessage]
        let maxTokens: Int
        let temperature: Double
        let stream: Bool
    }

    enum DecodeError: Error, Equatable {
        case invalidJSON
        case noMessages
    }

    /// Decodes an OpenAI chat request. `content` may be a string or a list of `{type: "text", text}`
    /// parts; non-text parts are dropped. Unknown roles count as "user"; "developer" counts as
    /// "system". Chat-template markers in the text are removed, because the prompt is tokenized with
    /// control tokens parsed and a typed "<end_of_turn>" must not end the turn.
    static func decodeChat(_ body: Data) throws -> ChatRequest {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw DecodeError.invalidJSON
        }
        let rawMessages = object["messages"] as? [[String: Any]] ?? []
        let messages: [LlamaChatMessage] = rawMessages.compactMap { message in
            let text: String
            if let string = message["content"] as? String {
                text = string
            } else if let parts = message["content"] as? [[String: Any]] {
                text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
            } else {
                return nil
            }
            return LlamaChatMessage(role: role(message["role"] as? String), content: withoutTemplateMarkers(text))
        }
        guard messages.contains(where: { $0.role != "system" }) else { throw DecodeError.noMessages }
        let requested = (object["max_completion_tokens"] as? Int) ?? (object["max_tokens"] as? Int)
        return ChatRequest(
            messages: messages,
            maxTokens: min(max(requested ?? defaultMaxTokens, 1), maximumMaxTokens),
            temperature: min(max((object["temperature"] as? Double) ?? defaultTemperature, 0), 2),
            stream: object["stream"] as? Bool ?? false
        )
    }

    private static func role(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "system", "developer": "system"
        case "assistant": "assistant"
        default: "user"
        }
    }

    private static let templateMarkers = [
        "<start_of_turn>", "<end_of_turn>", "<|im_start|>", "<|im_end|>", "<|eot_id|>",
        "<|start_header_id|>", "<|end_header_id|>", "<bos>", "<eos>",
    ]

    static func withoutTemplateMarkers(_ text: String) -> String {
        templateMarkers.reduce(text) { $0.replacingOccurrences(of: $1, with: "") }
    }

    /// The answer as clients expect it: no surrounding whitespace, no stray turn marker.
    static func cleanedAnswer(_ raw: String) -> String {
        withoutTemplateMarkers(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Responses

    static func http(status: Int, contentType: String, body: Data) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 413: "Payload Too Large", 500: "Internal Server Error",
                      503: "Service Unavailable"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func json(status: Int, _ object: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return http(status: status, contentType: "application/json", body: body)
    }

    static func error(status: Int, _ message: String, type: String = "invalid_request_error") -> Data {
        json(status: status, ["error": ["message": message, "type": type]])
    }

    static func models(modelID: String) -> Data {
        json(status: 200, ["object": "list", "data": [["id": modelID, "object": "model", "created": 0, "owned_by": "cotabby"]]])
    }

    static func chatCompletion(text: String, modelID: String, stream: Bool, created: Int, id: String) -> Data {
        guard stream else {
            return json(status: 200, [
                "id": id, "object": "chat.completion", "created": created, "model": modelID,
                "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
            ])
        }
        // Streaming clients get the whole answer as one chunk: the runtime finishes before replying.
        func chunk(_ delta: [String: Any], finish: Any) -> String {
            let object: [String: Any] = [
                "id": id, "object": "chat.completion.chunk", "created": created, "model": modelID,
                "choices": [["index": 0, "delta": delta, "finish_reason": finish]],
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            return "data: \(String(decoding: data, as: UTF8.self))\n\n"
        }
        let events = chunk(["role": "assistant", "content": text], finish: NSNull())
            + chunk([:], finish: "stop") + "data: [DONE]\n\n"
        return http(status: 200, contentType: "text/event-stream", body: Data(events.utf8))
    }
}
