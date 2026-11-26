import Foundation

// MARK: - Provider Abstraction & Shared Types

enum AIProtocolKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case geminiInteractions = "gemini"
    case openAICompatible = "openai"

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .geminiInteractions: "Gemini Interactions API"
        case .openAICompatible: "OpenAI Compatible API"
        }
    }
}

enum AIProviderPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case gemini
    case openai
    case groq
    case customOpenAI

    var id: String { rawValue }

    var name: String {
        switch self {
        case .gemini: "Google Gemini"
        case .openai: "OpenAI"
        case .groq: "Groq（高速 Whisper）"
        case .customOpenAI: "自定义 OpenAI 兼容"
        }
    }

    var protocolKind: AIProtocolKind {
        self == .gemini ? .geminiInteractions : .openAICompatible
    }

    var defaultBaseURL: String {
        switch self {
        case .gemini: "https://generativelanguage.googleapis.com"
        case .openai: "https://api.openai.com/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .customOpenAI: "https://api.openai.com/v1"
        }
    }

    var defaultTranscribeModel: String {
        switch self {
        case .gemini: "gemini-3.5-transcribe"
        case .openai: "gpt-4o-mini-transcribe"
        case .groq: "whisper-large-v3-turbo"
        case .customOpenAI: "whisper-1"
        }
    }

    var defaultRewriteModel: String {
        switch self {
        case .gemini: "gemini-3.5-flash-lite"
        case .openai: "gpt-4o-mini"
        case .groq: "llama-3.3-70b-versatile"
        case .customOpenAI: "gpt-4o-mini"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .gemini: "粘贴 Google AI Studio API Key"
        case .openai: "粘贴 OpenAI API Key (sk-…)"
        case .groq: "粘贴 Groq API Key (gsk_…)"
        case .customOpenAI: "粘贴 API Key（本地 localhost 服务可留空）"
        }
    }

    var apiKeyURL: URL? {
        switch self {
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .openai: URL(string: "https://platform.openai.com/api-keys")
        case .groq: URL(string: "https://console.groq.com/keys")
        case .customOpenAI: nil
        }
    }

    var usageDashboardURL: URL? {
        switch self {
        case .gemini: URL(string: "https://aistudio.google.com/usage")
        case .openai: URL(string: "https://platform.openai.com/usage")
        case .groq: URL(string: "https://console.groq.com/dashboard/usage")
        case .customOpenAI: nil
        }
    }

    var keychainAccount: String { "provider-\(rawValue)-api-key" }
}

struct AIEndpointConfig: Sendable, Equatable {
    let protocolKind: AIProtocolKind
    let baseURL: String
    let model: String
    let apiKey: String

    var normalizedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var isLocalhost: Bool {
        guard let host = URL(string: normalizedBaseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    var hasValidAuth: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLocalhost
    }
}

struct TokenUsage: Sendable, Codable, Equatable {
    let inputTokens: Int
    let outputTokens: Int
    let thoughtTokens: Int
    let cachedTokens: Int
    let totalTokens: Int

    static let zero = TokenUsage(inputTokens: 0, outputTokens: 0, thoughtTokens: 0, cachedTokens: 0, totalTokens: 0)

    var billableOutputTokens: Int { outputTokens + thoughtTokens }
}

struct AIResult: Sendable {
    let text: String
    let usage: TokenUsage
    let model: String
}

protocol SpeechTranscriber: Sendable {
    func transcribe(wav: Data) async throws -> AIResult
}

protocol TextRewriter: Sendable {
    func rewrite(_ transcript: String, prompt: String) async throws -> AIResult
}

// MARK: - Unified Multi-Provider AI Client

struct AIClient: SpeechTranscriber, TextRewriter, Sendable {
    private let transcribeConfig: AIEndpointConfig
    private let rewriteConfig: AIEndpointConfig
    private let session: URLSession

    init(
        transcribe: AIEndpointConfig,
        rewrite: AIEndpointConfig,
        session: URLSession? = nil
    ) {
        self.transcribeConfig = transcribe
        self.rewriteConfig = rewrite
        self.session = session ?? Self.ephemeralSession
    }

    private static let ephemeralSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 35
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    func transcribe(wav: Data) async throws -> AIResult {
        try Task.checkCancellation()
        switch transcribeConfig.protocolKind {
        case .geminiInteractions:
            return try await sendGeminiInteraction(
                config: transcribeConfig,
                input: [[
                    "type": "audio",
                    "mime_type": "audio/wav",
                    "data": wav.base64EncodedString()
                ]],
                generationConfig: ["transcription_config": ["mode": ["type": "verbatim"]]],
                emptyErrorMessage: "没有识别出文字。请确认麦克风已接收声音，再试一次。"
            )
        case .openAICompatible:
            return try await sendOpenAITranscription(config: transcribeConfig, wav: wav)
        }
    }

    func rewrite(_ transcript: String, prompt: String) async throws -> AIResult {
        try Task.checkCancellation()
        switch rewriteConfig.protocolKind {
        case .geminiInteractions:
            return try await sendGeminiInteraction(
                config: rewriteConfig,
                input: transcript,
                generationConfig: ["thinking_level": "minimal"],
                systemInstruction: prompt,
                emptyErrorMessage: "模型没有返回改写后的文字。"
            )
        case .openAICompatible:
            return try await sendOpenAIChat(config: rewriteConfig, prompt: prompt, userText: transcript)
        }
    }

    func verifyConnection() async throws {
        try Task.checkCancellation()
        switch rewriteConfig.protocolKind {
        case .geminiInteractions:
            _ = try await sendGeminiInteraction(
                config: rewriteConfig,
                input: "Reply with OK.",
                generationConfig: ["thinking_level": "minimal"],
                emptyErrorMessage: "模型未返回响应。",
                allowRetry: false
            )
        case .openAICompatible:
            _ = try await sendOpenAIChat(
                config: rewriteConfig,
                prompt: "Reply with OK.",
                userText: "ping",
                allowRetry: false
            )
        }
    }

    // MARK: - Gemini Interactions Protocol

    private func sendGeminiInteraction(
        config: AIEndpointConfig,
        input: Any,
        generationConfig: [String: Any],
        systemInstruction: String? = nil,
        emptyErrorMessage: String,
        allowRetry: Bool = true
    ) async throws -> AIResult {
        guard let url = URL(string: "\(config.normalizedBaseURL)/v1beta/interactions") else {
            throw VoiceTypeError.message("Base URL 格式无效，请检查设置中的服务地址。")
        }
        var body: [String: Any] = [
            "model": config.model,
            "input": input,
            "store": false,
            "generation_config": generationConfig
        ]
        if let systemInstruction {
            body["system_instruction"] = systemInstruction
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2026-05-20", forHTTPHeaderField: "Api-Revision")
        if !config.apiKey.isEmpty {
            request.setValue(config.apiKey, forHTTPHeaderField: "x-goog-api-key")
        }

        let data = try await executeWithRetry(request, providerName: "Gemini", allowRetry: allowRetry)
        let decoder = JSONDecoder()
        guard let result = try? decoder.decode(GeminiInteraction.self, from: data) else {
            throw VoiceTypeError.message("Gemini 返回了无法读取的数据。")
        }
        guard result.status == "completed" else {
            if let error = result.error {
                throw Self.mapAPIError(provider: "Gemini", status: nil, code: error.code, reason: error.firstReason, message: error.message)
            }
            throw VoiceTypeError.message("Gemini 未能完成处理，请稍后再试。")
        }

        let text = (result.steps ?? [])
            .filter { $0.type == "model_output" }
            .flatMap { $0.content ?? [] }
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw VoiceTypeError.message(emptyErrorMessage)
        }
        return AIResult(text: text, usage: result.usage?.resolved ?? .zero, model: config.model)
    }

    // MARK: - OpenAI-Compatible Protocol (STT + Chat)

    private func sendOpenAITranscription(config: AIEndpointConfig, wav: Data) async throws -> AIResult {
        guard let url = URL(string: "\(config.normalizedBaseURL)/audio/transcriptions") else {
            throw VoiceTypeError.message("转写服务的 Base URL 格式无效，请检查设置。")
        }

        let boundary = "YapFlush-\(UUID().uuidString)"
        var body = Data()
        func appendField(_ name: String, value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        appendField("model", value: config.model)
        appendField("response_format", value: "json")
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data = try await executeWithRetry(request, providerName: "转写服务", allowRetry: true)
        let decoder = JSONDecoder()

        if let parsed = try? decoder.decode(OpenAITranscriptionResponse.self, from: data) {
            let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw VoiceTypeError.message("没有识别出文字。请确认麦克风已接收声音，再试一次。")
            }
            return AIResult(text: text, usage: parsed.usage?.resolved ?? .zero, model: config.model)
        }

        if let plain = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !plain.isEmpty, !plain.hasPrefix("{") {
            return AIResult(text: plain, usage: .zero, model: config.model)
        }

        throw VoiceTypeError.message("转写接口返回了无法解析的响应格式。")
    }

    private func sendOpenAIChat(
        config: AIEndpointConfig,
        prompt: String,
        userText: String,
        allowRetry: Bool = true
    ) async throws -> AIResult {
        guard let url = URL(string: "\(config.normalizedBaseURL)/chat/completions") else {
            throw VoiceTypeError.message("改写服务的 Base URL 格式无效，请检查设置。")
        }

        let payload: [String: Any] = [
            "model": config.model,
            "temperature": 0.3,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": userText]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data = try await executeWithRetry(request, providerName: "改写服务", allowRetry: allowRetry)
        let decoder = JSONDecoder()
        guard let parsed = try? decoder.decode(OpenAIChatResponse.self, from: data) else {
            throw VoiceTypeError.message("改写接口返回了无法解析的数据。")
        }

        let text = (parsed.choices?.first?.message?.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw VoiceTypeError.message("模型没有返回改写后的文字。")
        }
        return AIResult(text: text, usage: parsed.usage?.resolved ?? .zero, model: config.model)
    }

    // MARK: - HTTP Execution & Transient Retry

    private struct TransientError: Error {
        let underlying: Error
    }

    private func executeWithRetry(_ request: URLRequest, providerName: String, allowRetry: Bool) async throws -> Data {
        let maxAttempts = allowRetry ? 2 : 1
        var lastError: Error?

        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                try await Task.sleep(for: .milliseconds(700))
                try Task.checkCancellation()
            }
            do {
                return try await performHTTP(request, providerName: providerName)
            } catch let transient as TransientError {
                lastError = transient.underlying
                if attempt + 1 >= maxAttempts { throw transient.underlying }
            }
        }
        throw lastError ?? VoiceTypeError.message("\(providerName)处理失败，请稍后再试。")
    }

    private func performHTTP(_ request: URLRequest, providerName: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut {
                throw TransientError(underlying: VoiceTypeError.message("\(providerName)请求超时，请稍后再试。"))
            }
            let message = VoiceTypeError.message("无法连接\(providerName)（\(error.code.rawValue)），请检查网络或 Base URL。")
            if error.code == .networkConnectionLost || error.code == .cannotConnectToHost {
                throw TransientError(underlying: message)
            }
            throw message
        }

        guard let http = response as? HTTPURLResponse else {
            throw VoiceTypeError.message("\(providerName)返回了无法识别的响应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            let decoder = JSONDecoder()
            let apiErr = (try? decoder.decode(ErrorEnvelope.self, from: data).error) ??
                (try? decoder.decode([ErrorEnvelope].self, from: data).first?.error)
            let mapped = Self.mapAPIError(
                provider: providerName,
                status: http.statusCode,
                code: apiErr?.code,
                reason: apiErr?.firstReason,
                message: apiErr?.message
            )
            if http.statusCode == 503 || http.statusCode == 504 {
                throw TransientError(underlying: mapped)
            }
            throw mapped
        }
        return data
    }

    private static func mapAPIError(
        provider: String,
        status: Int?,
        code: String?,
        reason: String?,
        message: String?
    ) -> VoiceTypeError {
        let lowCode = code?.lowercased() ?? ""
        let lowReason = reason?.lowercased() ?? ""
        let lowMsg = message?.lowercased() ?? ""
        let suffix = status.map { "（HTTP \($0)）" } ?? ""

        if status == 429 || ["resource_exhausted", "rate_limit_exceeded", "quota_exceeded", "too_many_requests", "insufficient_quota"].contains(lowCode) {
            return .message("\(provider)配额或速率已达上限\(suffix)，请检查账号余额与限额。")
        }
        if status == 401 || lowCode == "unauthenticated" || lowCode == "invalid_api_key" || lowReason.hasPrefix("api_key") ||
            ["api key", "api_key", "api-key", "incorrect api key"].contains(where: lowMsg.contains) {
            return .message("\(provider) API Key 无效、已过期或受限\(suffix)，请在设置中更新。")
        }
        if status == 403 || lowCode == "permission_denied" {
            return .message("\(provider)拒绝访问\(suffix)，请检查账号权限与区域限制。")
        }
        if status == 404 || lowCode == "not_found" || lowCode == "model_not_found" {
            return .message("未找到指定的模型或接口路径\(suffix)，请检查模型名与 Base URL。")
        }
        if status == 503 || status == 504 || lowCode == "unavailable" {
            return .message("\(provider)暂时不可用\(suffix)，请稍后再试。")
        }
        if status == 400 || lowCode == "invalid_request" {
            if lowMsg.contains("location") || lowMsg.contains("region") {
                return .message("\(provider)在当前网络地区不可用\(suffix)。")
            }
            return .message("\(provider)拒绝了请求\(suffix)，请检查模型与配置。")
        }
        return .message("\(provider)处理失败\(suffix)，请稍后再试。")
    }

    // MARK: - Wire Decodables

    private struct GeminiInteraction: Decodable {
        let status: String
        let steps: [Step]?
        let usage: GeminiRawUsage?
        let error: APIError?

        struct Step: Decodable {
            let type: String
            let content: [Part]?
        }

        struct Part: Decodable {
            let type: String
            let text: String?
        }
    }

    private struct GeminiRawUsage: Decodable {
        let total_input_tokens: Int?
        let total_output_tokens: Int?
        let total_thought_tokens: Int?
        let total_cached_tokens: Int?
        let total_tokens: Int?
        let input_tokens_by_modality: [ModalityTokens]?
        let output_tokens_by_modality: [ModalityTokens]?

        struct ModalityTokens: Decodable {
            let modality: String?
            let tokens: Int?
        }

        var resolved: TokenUsage {
            let input = total_input_tokens ?? (input_tokens_by_modality?.compactMap(\.tokens).reduce(0, +) ?? 0)
            let output = total_output_tokens ?? (output_tokens_by_modality?.compactMap(\.tokens).reduce(0, +) ?? 0)
            let thought = total_thought_tokens ?? 0
            let cached = total_cached_tokens ?? 0
            let total = total_tokens ?? (input + output + thought)
            return TokenUsage(
                inputTokens: max(0, input),
                outputTokens: max(0, output),
                thoughtTokens: max(0, thought),
                cachedTokens: max(0, cached),
                totalTokens: max(0, total)
            )
        }
    }

    private struct OpenAITranscriptionResponse: Decodable {
        let text: String
        let usage: OpenAIUsage?
    }

    private struct OpenAIChatResponse: Decodable {
        let choices: [Choice]?
        let usage: OpenAIUsage?

        struct Choice: Decodable {
            let message: Message?
        }

        struct Message: Decodable {
            let content: String?
        }
    }

    private struct OpenAIUsage: Decodable {
        let prompt_tokens: Int?
        let completion_tokens: Int?
        let total_tokens: Int?
        let input_tokens: Int?
        let output_tokens: Int?

        var resolved: TokenUsage {
            let input = input_tokens ?? prompt_tokens ?? 0
            let output = output_tokens ?? completion_tokens ?? 0
            let total = total_tokens ?? (input + output)
            return TokenUsage(
                inputTokens: max(0, input),
                outputTokens: max(0, output),
                thoughtTokens: 0,
                cachedTokens: 0,
                totalTokens: max(0, total)
            )
        }
    }

    private struct ErrorEnvelope: Decodable {
        let error: APIError
    }

    private struct APIError: Decodable {
        let code: String?
        let message: String?
        let details: [Detail]?

        struct Detail: Decodable { let reason: String? }

        var firstReason: String? { details?.compactMap(\.reason).first }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            code = (try? fields.decode(String.self, forKey: .code)) ??
                (try? fields.decode(String.self, forKey: .status)) ??
                (try? fields.decode(String.self, forKey: .type))
            message = try? fields.decode(String.self, forKey: .message)
            details = try? fields.decode([Detail].self, forKey: .details)
        }

        private enum CodingKeys: String, CodingKey {
            case code, status, type, message, details
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
