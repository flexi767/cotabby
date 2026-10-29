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
        "<|turn>", "<turn|>", "<|channel>", "<channel|>", "<|think|>",
    ]

    static func withoutTemplateMarkers(_ text: String) -> String {
        templateMarkers.reduce(text) { $0.replacingOccurrences(of: $1, with: "") }
    }

    /// A chat turn format written out by Cotabby for a model whose GGUF carries no
    /// `tokenizer.chat_template` (base and many imatrix re-quants of Gemma ship without one), so
    /// llama.cpp has nothing to apply. The runtime recognizes the format from the vocabulary: a
    /// model whose turn markers are single control tokens was trained on that turn format.
    ///
    /// Neither format writes `<bos>`: llama.cpp adds it while tokenizing (for Gemma 4 it forces
    /// `add_bos` on even when the GGUF says false). The answer stops at the closing marker because
    /// llama.cpp counts `<end_of_turn>` and `<turn|>` as end-of-generation tokens.
    enum FallbackChatFormat: CaseIterable {
        /// Gemma 4 (Google's `chat_template.jinja` for gemma-4-*-it): a leading system message gets
        /// its own `<|turn>system` turn; every turn is `<|turn>{role}\n{text}<turn|>\n`.
        case gemma4
        /// Gemma 2 and 3: no system turn, so a leading system message opens the first user turn,
        /// separated by a blank line (Google's Gemma 3 template and llama.cpp's built-in "gemma").
        case gemma

        /// The opening and closing turn markers; both must be single tokens in the vocabulary.
        var turnMarkers: (open: String, close: String) {
            switch self {
            case .gemma4: ("<|turn>", "<turn|>")
            case .gemma: ("<start_of_turn>", "<end_of_turn>")
            }
        }

        /// Whether the GGUF's own `general.*` metadata names an instruction-tuned model, which
        /// is the only kind this fallback may serve. A template-less Gemma GGUF is in practice a
        /// *base* (pretrained) conversion: every published Gemma 3/4 instruction quant checked
        /// (ggml-org, unsloth, bartowski, lmstudio-community, mradermacher) embeds its template,
        /// and the template-less ones are `gemma-4-E2B`/`gemma-4-E4B`/`gemma-3-4b-pt`. A base model
        /// given chat turns answers with unrelated text, and a client that falls back to its own
        /// input on an error (VoiceInk keeps the raw dictation) would replace good text with it.
        ///
        /// So the rule fails closed: only an explicit instruction tag passes. llama.cpp's converter
        /// derives `general.finetune` and `general.name` from the Hugging Face repo name
        /// ("gemma-3-4b-it" -> finetune "it", name "... It"), and `general.source.url` names the
        /// original repo, so an instruction tune says "it", "instruct" or "chat" as a whole word in
        /// one of them. `general.url` is ignored: it names the quantizer's repo, not the model.
        static func isInstructionTuned(_ metadata: [String: String]) -> Bool {
            let sourceRepo = metadata["general.source.url"].flatMap { URL(string: $0)?.lastPathComponent }
            let fields = [metadata["general.finetune"], metadata["general.name"], sourceRepo]
            return fields.compactMap { $0 }.contains { field in
                field.lowercased()
                    .split { !$0.isLetter && !$0.isNumber }
                    .contains { ["it", "instruct", "chat"].contains($0) }
            }
        }

        /// `messages` as a prompt in this format, ending with the model's turn opened.
        func prompt(for messages: [LlamaChatMessage]) -> String {
            let (open, close) = turnMarkers
            var remaining = messages[...]
            var prompt = ""
            var firstUserPrefix = ""
            if let first = remaining.first, first.role == "system" {
                remaining = remaining.dropFirst()
                let system = first.content.trimmingCharacters(in: .whitespacesAndNewlines)
                switch self {
                case .gemma4: prompt += "\(open)system\n\(system)\(close)\n"
                case .gemma: firstUserPrefix = system.isEmpty ? "" : system + "\n\n"
                }
            }
            for message in remaining {
                // Both templates call the assistant "model"; Gemma 4 passes other roles through.
                let role = message.role == "assistant" ? "model" : message.role
                var text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if role == "user", !firstUserPrefix.isEmpty {
                    text = firstUserPrefix + text
                    firstUserPrefix = ""
                }
                prompt += "\(open)\(role)\n\(text)\(close)\n"
            }
            return prompt + "\(open)model\n"
        }
    }

    /// The chat prompt for the loaded model: its own template's rendering when llama.cpp produced
    /// one (whatever the metadata says, as before the fallback existed), else the fallback format
    /// for an instruction-tuned model, else nil so the endpoint fails before generating.
    static func chatPrompt(
        templated: String?,
        fallbackFormat: FallbackChatFormat?,
        metadata: [String: String],
        messages: [LlamaChatMessage]
    ) -> String? {
        if let templated, !templated.isEmpty { return templated }
        guard let fallbackFormat, FallbackChatFormat.isInstructionTuned(metadata) else { return nil }
        return fallbackFormat.prompt(for: messages)
    }

    /// The string-valued `general.*` keys of a GGUF file's header (`general.name`,
    /// `general.finetune`, `general.source.url`, ...), or nil when `data` is not a GGUF v2/v3
    /// header. Other keys are skipped without decoding, including the tokenizer's arrays of
    /// hundreds of thousands of strings, which may come before `general.source.url`. Pass the file
    /// memory-mapped: only the header's pages are touched, never the tensor data.
    ///
    /// Layout (ggml's gguf.h): "GGUF", u32 version, u64 tensor count, u64 key count, then per key a
    /// string name, a u32 value type and the value; strings are a u64 byte length and UTF-8 bytes.
    static func ggufGeneralStrings(_ data: Data) -> [String: String]? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [String: String]? in
            var offset = 0
            func integer<T: FixedWidthInteger>(_: T.Type) -> T? {
                guard offset + MemoryLayout<T>.size <= raw.count else { return nil }
                defer { offset += MemoryLayout<T>.size }
                return T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
            }
            func string() -> String? {
                guard let length = integer(UInt64.self), length <= UInt64(raw.count - offset) else { return nil }
                defer { offset += Int(length) }
                return String(decoding: raw[offset ..< offset + Int(length)], as: UTF8.self)
            }
            // Byte size of one fixed-width value type; nil for string (8), array (9) or unknown.
            func fixedSize(_ type: UInt32) -> Int? {
                switch type {
                case 0, 1, 7: 1
                case 2, 3: 2
                case 4, 5, 6: 4
                case 10, 11, 12: 8
                default: nil
                }
            }
            func skipValue(_ type: UInt32) -> Bool {
                if let size = fixedSize(type) {
                    guard offset + size <= raw.count else { return false }
                    offset += size
                    return true
                }
                switch type {
                case 8:
                    return string() != nil
                case 9:
                    guard let elementType = integer(UInt32.self), let count = integer(UInt64.self) else { return false }
                    if let size = fixedSize(elementType) {
                        guard count <= UInt64(raw.count - offset) / UInt64(size) else { return false }
                        offset += Int(count) * size
                        return true
                    }
                    guard count <= UInt64(raw.count - offset) else { return false }
                    for _ in 0 ..< count where !skipValue(elementType) { return false }
                    return true
                default:
                    return false
                }
            }

            guard raw.count >= 4, raw.prefix(4).elementsEqual("GGUF".utf8) else { return nil }
            offset = 4
            // Version 1 used 32-bit lengths; llama.cpp writes v3 and reads only v2 and later.
            guard let version = integer(UInt32.self), version >= 2,
                  integer(UInt64.self) != nil, // tensor count
                  let keyCount = integer(UInt64.self) else { return nil }
            var result: [String: String] = [:]
            for _ in 0 ..< keyCount {
                guard let key = string(), let type = integer(UInt32.self) else { return nil }
                if type == 8, key.hasPrefix("general.") {
                    guard let value = string() else { return nil }
                    result[key] = value
                } else if !skipValue(type) {
                    return nil
                }
            }
            return result
        }
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
