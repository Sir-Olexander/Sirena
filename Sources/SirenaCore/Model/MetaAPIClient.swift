import Foundation

// MARK: - Chat completions types (OpenAI-compatible)

public struct ChatToolCall: Codable, Equatable {
    public struct Function: Codable, Equatable {
        public var name: String
        public var arguments: String
        public init(name: String, arguments: String) { self.name = name; self.arguments = arguments }
    }
    public var id: String
    public var type: String
    public var function: Function
    public init(id: String, type: String = "function", function: Function) { self.id = id; self.type = type; self.function = function }

    public var argumentsJSON: JSON { (try? JSON.parse(function.arguments)) ?? .object([:]) }
}

public struct ChatMessage: Codable, Equatable {
    public var role: String
    public var content: String?
    public var tool_calls: [ChatToolCall]?
    public var tool_call_id: String?

    public init(role: String, content: String?, tool_calls: [ChatToolCall]? = nil, tool_call_id: String? = nil) {
        self.role = role; self.content = content; self.tool_calls = tool_calls; self.tool_call_id = tool_call_id
    }
    public static func system(_ text: String) -> ChatMessage { ChatMessage(role: "system", content: text) }
    public static func user(_ text: String) -> ChatMessage { ChatMessage(role: "user", content: text) }
    public static func tool(id: String, content: String) -> ChatMessage { ChatMessage(role: "tool", content: content, tool_call_id: id) }
}

public struct ChatTool: Encodable {
    public struct FunctionDef: Encodable {
        public var name: String
        public var description: String
        public var parameters: JSON
    }
    public var type = "function"
    public var function: FunctionDef
    public init(name: String, description: String, parameters: JSON) {
        function = FunctionDef(name: name, description: description, parameters: parameters)
    }
}

public struct ChatRequest: Encodable {
    public var model: String
    public var messages: [ChatMessage]
    public var tools: [ChatTool]?
    public var tool_choice: String?
    public var reasoning_effort: String?
    public var max_tokens: Int?
    public var temperature: Double?
    public var parallel_tool_calls: Bool?
    public var prompt_cache_key: String?
    public var response_format: JSON?

    public init(model: String, messages: [ChatMessage], tools: [ChatTool]? = nil, reasoning_effort: String? = "minimal",
                max_tokens: Int? = 1500, temperature: Double? = nil, parallel_tool_calls: Bool? = nil,
                prompt_cache_key: String? = nil, response_format: JSON? = nil) {
        self.model = model; self.messages = messages; self.tools = tools
        self.tool_choice = tools == nil ? nil : "auto"
        self.reasoning_effort = reasoning_effort; self.max_tokens = max_tokens; self.temperature = temperature
        self.parallel_tool_calls = parallel_tool_calls; self.prompt_cache_key = prompt_cache_key
        self.response_format = response_format
    }
}

public struct ChatUsage: Decodable {
    public var prompt_tokens: Int?
    public var completion_tokens: Int?
    public struct Details: Decodable { public var reasoning_tokens: Int?; public var cached_tokens: Int? }
    public var completion_tokens_details: Details?
    public var prompt_tokens_details: Details?
}

public struct ChatResponse: Decodable {
    public struct Choice: Decodable {
        public var message: ChatMessage
        public var finish_reason: String?
    }
    public var choices: [Choice]
    public var usage: ChatUsage?
    public var model: String?

    public var message: ChatMessage? { choices.first?.message }
    public var toolCalls: [ChatToolCall] { choices.first?.message.tool_calls ?? [] }
    public var text: String? { choices.first?.message.content }
}

public enum APIError: Error, LocalizedError {
    case missingKey
    case http(Int, String)
    case transport(String)
    case decoding(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "No API key. Add it in the Sirena menu."
        case .http(let code, let body): return "API error \(code): \(body.prefix(200))"
        case .transport(let s): return "Network: \(s)"
        case .decoding(let s): return "Bad response: \(s)"
        case .timeout: return "The model took too long."
        }
    }
}

/// Thin client for the Meta Model API (also works against any OpenAI-compatible local server).
public final class MetaAPIClient: @unchecked Sendable {
    public let baseURL: URL
    public var apiKey: String?
    /// Idle timeout per request (time between packets).
    public var timeout: TimeInterval = 25
    /// Hard wall-clock limit for a chat completion.
    public var chatDeadline: TimeInterval = 45
    /// Hard wall-clock limit for a Responses API call (computer use sends images, allow more).
    public var responsesDeadline: TimeInterval = 60
    private let session: URLSession

    public static let metaBaseURL = URL(string: "https://api.meta.ai/v1")!

    public init(baseURL: URL = MetaAPIClient.metaBaseURL, apiKey: String?) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    public var isLocal: Bool { baseURL.host == "localhost" || baseURL.host == "127.0.0.1" }

    private func request(path: String, body: Data, contentType: String = "application/json", accept: String = "application/json") throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        if let key = apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        } else if !isLocal {
            throw APIError.missingKey
        } else {
            req.setValue("Bearer local-only", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = body
        return req
    }

    private func perform(_ req: URLRequest) async throws -> Data {
        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw APIError.timeout
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw APIError.transport("no HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    /// Runs `operation` with a wall-clock deadline.
    static func withDeadline<T>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.1, seconds) * 1_000_000_000))
                throw APIError.timeout
            }
            guard let result = try await group.next() else { throw APIError.timeout }
            group.cancelAll()
            return result
        }
    }

    /// Set SIRENA_DEBUG_DUMP=/path/dir to write every chat request/response body there (never includes the key).
    static let debugDumpDir: URL? = ProcessInfo.processInfo.environment["SIRENA_DEBUG_DUMP"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    private func dump(_ name: String, _ data: Data) {
        guard let dir = MetaAPIClient.debugDumpDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        try? data.write(to: dir.appendingPathComponent("\(stamp)-\(name).json"))
    }

    public func chat(_ request: ChatRequest) async throws -> ChatResponse {
        let body = try JSONEncoder().encode(request)
        dump("chat-request", body)
        let req = try self.request(path: "chat/completions", body: body)
        let deadline = chatDeadline
        let started = Date()
        let data = try await MetaAPIClient.withDeadline(deadline) { [self] in try await perform(req) }
        Log.model.info("chat completion in \(Int(Date().timeIntervalSince(started) * 1000)) ms (\(body.count) bytes)")
        dump("chat-response", data)
        do { return try JSONDecoder().decode(ChatResponse.self, from: data) }
        catch { throw APIError.decoding(String(data: data, encoding: .utf8)?.prefix(300).description ?? error.localizedDescription) }
    }

    /// Responses API (used for computer use). Dynamic JSON in and out.
    public func responses(_ body: JSON) async throws -> JSON {
        let req = try self.request(path: "responses", body: try body.data())
        let deadline = responsesDeadline
        let data = try await MetaAPIClient.withDeadline(deadline) { [self] in try await perform(req) }
        do { return try JSON.parse(data) }
        catch { throw APIError.decoding(error.localizedDescription) }
    }

    public func listModels() async throws -> [String] {
        var req = URLRequest(url: baseURL.appendingPathComponent("models"))
        req.timeoutInterval = 4
        if let key = apiKey, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let data = try await perform(req)
        let json = try JSON.parse(data)
        return json["data"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
    }

    /// One-shot transcription of a 16 kHz/24 kHz mono 16-bit WAV (fallback when realtime is unavailable).
    public func transcribe(wav: Data, model: String = "muse-voice-transcribe-1.0", keywords: [String]) async throws -> String {
        let boundary = "sirena-\(UUID().uuidString)"
        var body = Data()
        func part(_ s: String) { body.append(Data(s.utf8)) }
        let requestJSON: JSON = .object([
            "model": .string(model), "audioEncoding": "WAV", "mode": "ENDPOINTING",
            "keywords": .array(keywords.map { .string($0) }), "languageBias": ["English"],
        ])
        part("--\(boundary)\r\nContent-Disposition: form-data; name=\"request\"\r\nContent-Type: application/json\r\n\r\n")
        body.append(try requestJSON.data())
        part("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"utterance.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wav)
        part("\r\n--\(boundary)--\r\n")
        let req = try self.request(path: "asr/transcribe", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        let data = try await MetaAPIClient.withDeadline(30) { [self] in try await perform(req) }
        let json = try JSON.parse(data)
        return json["transcript"]?.stringValue ?? ""
    }
}
