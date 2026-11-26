import AppKit
import Carbon
import IOKit
import Security
import ServiceManagement

enum OutputMode: String, CaseIterable, Identifiable {
    case english = "X English"
    case chinese = "Chinese"

    var id: String { rawValue }
    var name: String { self == .english ? "英文" : "中文" }
    var defaultShortcut: Shortcut { self == .english ? .leftOption : .leftControl }
    fileprivate var shortcutPreference: String { self == .english ? "shortcut" : "chineseShortcut" }
}

enum StandaloneModifier {
    case leftOption
    case leftControl

    init?(keyCode: UInt16) {
        switch Int(keyCode) {
        case kVK_Option: self = .leftOption
        case kVK_Control: self = .leftControl
        default: return nil
        }
    }

    var shortcut: Shortcut { self == .leftOption ? .leftOption : .leftControl }
    var carbonMask: UInt32 { UInt32(self == .leftOption ? optionKey : controlKey) }

    private var combinedFlag: NSEvent.ModifierFlags { self == .leftOption ? .option : .control }
    private var leftMask: UInt { UInt(self == .leftOption ? NX_DEVICELALTKEYMASK : NX_DEVICELCTLKEYMASK) }
    private var rightMask: UInt { UInt(self == .leftOption ? NX_DEVICERALTKEYMASK : NX_DEVICERCTLKEYMASK) }

    func isDown(in event: NSEvent) -> Bool {
        let raw = event.modifierFlags.rawValue
        let sideBits = raw & (leftMask | rightMask)
        return sideBits == 0 ? event.modifierFlags.contains(combinedFlag) : sideBits & leftMask != 0
    }

    func hasOtherModifier(in event: NSEvent) -> Bool {
        let modifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        return !event.modifierFlags.intersection(modifiers.subtracting(combinedFlag)).isEmpty ||
            event.modifierFlags.rawValue & rightMask != 0
    }
}

struct Shortcut: Codable, Equatable {
    private struct Modifier: Sendable {
        let code: UInt32
        let symbol: String
        let eventFlag: NSEvent.ModifierFlags
        let globalFlag: CGEventFlags

        init(_ code: Int, _ symbol: String, _ eventFlag: NSEvent.ModifierFlags, _ globalFlag: CGEventFlags) {
            self.code = UInt32(code)
            self.symbol = symbol
            self.eventFlag = eventFlag
            self.globalFlag = globalFlag
        }
    }

    private struct Key: Sendable {
        let code: UInt32
        let name: String
        let isFunctionKey: Bool

        init(_ code: Int, _ name: String, functionKey: Bool = false) {
            self.code = UInt32(code)
            self.name = name
            isFunctionKey = functionKey
        }
    }

    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let leftOption = Shortcut(keyCode: UInt32(kVK_Option), modifiers: 0, keyLabel: "左 Option")
    static let leftControl = Shortcut(keyCode: UInt32(kVK_Control), modifiers: 0, keyLabel: "左 Control")

    var standaloneModifier: StandaloneModifier? {
        guard modifiers == 0, let code = UInt16(exactly: keyCode) else { return nil }
        return StandaloneModifier(keyCode: code)
    }

    func matches(_ shortcut: Shortcut) -> Bool {
        keyCode == shortcut.keyCode && modifiers == shortcut.modifiers
    }

    private static let supportedModifiers = [
        Modifier(controlKey, "⌃", .control, .maskControl),
        Modifier(optionKey, "⌥", .option, .maskAlternate),
        Modifier(shiftKey, "⇧", .shift, .maskShift),
        Modifier(cmdKey, "⌘", .command, .maskCommand)
    ]

    private static let keys = [
        Key(kVK_Space, "Space"), Key(kVK_Return, "Return"), Key(kVK_Tab, "Tab"),
        Key(kVK_Delete, "Delete"), Key(kVK_ForwardDelete, "Forward Delete"),
        Key(kVK_LeftArrow, "←"), Key(kVK_RightArrow, "→"), Key(kVK_UpArrow, "↑"), Key(kVK_DownArrow, "↓"),
        Key(kVK_Home, "Home"), Key(kVK_End, "End"), Key(kVK_PageUp, "Page Up"), Key(kVK_PageDown, "Page Down"),
        Key(kVK_ANSI_A, "A"), Key(kVK_ANSI_B, "B"), Key(kVK_ANSI_C, "C"), Key(kVK_ANSI_D, "D"),
        Key(kVK_ANSI_E, "E"), Key(kVK_ANSI_F, "F"), Key(kVK_ANSI_G, "G"), Key(kVK_ANSI_H, "H"),
        Key(kVK_ANSI_I, "I"), Key(kVK_ANSI_J, "J"), Key(kVK_ANSI_K, "K"), Key(kVK_ANSI_L, "L"),
        Key(kVK_ANSI_M, "M"), Key(kVK_ANSI_N, "N"), Key(kVK_ANSI_O, "O"), Key(kVK_ANSI_P, "P"),
        Key(kVK_ANSI_Q, "Q"), Key(kVK_ANSI_R, "R"), Key(kVK_ANSI_S, "S"), Key(kVK_ANSI_T, "T"),
        Key(kVK_ANSI_U, "U"), Key(kVK_ANSI_V, "V"), Key(kVK_ANSI_W, "W"), Key(kVK_ANSI_X, "X"),
        Key(kVK_ANSI_Y, "Y"), Key(kVK_ANSI_Z, "Z"),
        Key(kVK_ANSI_0, "0"), Key(kVK_ANSI_1, "1"), Key(kVK_ANSI_2, "2"), Key(kVK_ANSI_3, "3"), Key(kVK_ANSI_4, "4"),
        Key(kVK_ANSI_5, "5"), Key(kVK_ANSI_6, "6"), Key(kVK_ANSI_7, "7"), Key(kVK_ANSI_8, "8"), Key(kVK_ANSI_9, "9"),
        Key(kVK_ANSI_Minus, "-"), Key(kVK_ANSI_Equal, "="), Key(kVK_ANSI_LeftBracket, "["), Key(kVK_ANSI_RightBracket, "]"),
        Key(kVK_ANSI_Backslash, "\\"), Key(kVK_ANSI_Semicolon, ";"), Key(kVK_ANSI_Quote, "'"),
        Key(kVK_ANSI_Comma, ","), Key(kVK_ANSI_Period, "."), Key(kVK_ANSI_Slash, "/"), Key(kVK_ANSI_Grave, "`")
    ] + [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
         kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        .enumerated().map { Key($0.element, "F\($0.offset + 1)", functionKey: true) }

    var label: String {
        let symbols = Self.supportedModifiers.filter { modifiers & $0.code != 0 }.map(\.symbol).joined()
        return symbols.isEmpty ? keyLabel : "\(symbols) \(keyLabel)"
    }

    var eventFlags: CGEventFlags {
        Self.supportedModifiers.reduce(into: []) { result, modifier in
            if modifiers & modifier.code != 0 { result.insert(modifier.globalFlag) }
        }
    }

    var isValid: Bool {
        keyCode <= UInt16.max && keyCode != kVK_Escape &&
            (standaloneModifier != nil || (modifiers & UInt32(cmdKey | controlKey | optionKey)) != 0 ||
             Self.keys.contains { $0.code == keyCode && $0.isFunctionKey })
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        let code = UInt32(event.keyCode)
        guard code != kVK_Escape else { return nil }
        let label = Self.keys.first { $0.code == code }?.name ?? event.charactersIgnoringModifiers?.uppercased()
        guard let label, !label.isEmpty, label.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .privateUse
        }) else { return nil }

        let modifiers = Self.supportedModifiers.filter { event.modifierFlags.contains($0.eventFlag) }.reduce(0) { $0 | $1.code }
        self.init(keyCode: code, modifiers: modifiers, keyLabel: label)
        guard isValid else { return nil }
    }
}

enum VoiceTypeError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

// MARK: - Provider Settings & App Preferences

struct ProviderSettings: Codable, Equatable {
    var baseURL: String
    var transcribeModel: String
    var rewriteModel: String

    static func defaults(for preset: AIProviderPreset) -> ProviderSettings {
        ProviderSettings(
            baseURL: preset.defaultBaseURL,
            transcribeModel: preset.defaultTranscribeModel,
            rewriteModel: preset.defaultRewriteModel
        )
    }
}

struct RewriteOverrideSettings: Codable, Equatable {
    var enabled: Bool = false
    var protocolKind: AIProtocolKind = .openAICompatible
    var baseURL: String = "https://api.deepseek.com/v1"
    var model: String = "deepseek-chat"
}

@MainActor
final class Preferences: ObservableObject {
    private let defaults = UserDefaults.standard

    static let defaultPrompt: String = {
        guard let url = Bundle.main.url(forResource: "XEnglish", withExtension: "txt"),
              let prompt = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("YapFlush is missing the bundled X English system prompt.")
        }
        return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }()

    @Published var microphoneUID: String {
        didSet { defaults.set(microphoneUID, forKey: "microphoneUID") }
    }
    @Published var prompt: String {
        didSet { defaults.set(prompt, forKey: "englishPrompt") }
    }
    @Published var soundEffectsEnabled: Bool {
        didSet { defaults.set(soundEffectsEnabled, forKey: "soundEffectsEnabled") }
    }
    @Published var activeProvider: AIProviderPreset {
        didSet { defaults.set(activeProvider.rawValue, forKey: "activeProvider") }
    }
    @Published private var providerConfigs: [AIProviderPreset: ProviderSettings]
    @Published var rewriteOverride: RewriteOverrideSettings {
        didSet {
            if let data = try? JSONEncoder().encode(rewriteOverride) {
                defaults.set(data, forKey: "rewriteOverride")
            }
        }
    }
    @Published private var shortcuts: [OutputMode: Shortcut]

    func settings(for preset: AIProviderPreset) -> ProviderSettings {
        providerConfigs[preset] ?? .defaults(for: preset)
    }

    func updateSettings(_ settings: ProviderSettings, for preset: AIProviderPreset) {
        providerConfigs[preset] = settings
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: "providerConfig.\(preset.rawValue)")
        }
    }

    func resetProviderDefaults(for preset: AIProviderPreset) {
        updateSettings(.defaults(for: preset), for: preset)
    }

    func shortcut(for mode: OutputMode) -> Shortcut { shortcuts[mode] ?? mode.defaultShortcut }

    func setShortcut(_ shortcut: Shortcut, for mode: OutputMode) {
        shortcuts[mode] = shortcut
        defaults.set(try? JSONEncoder().encode(shortcut), forKey: mode.shortcutPreference)
    }

    var didShowWelcome: Bool {
        get { defaults.bool(forKey: "didShowWelcome") }
        set { defaults.set(newValue, forKey: "didShowWelcome") }
    }

    var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        objectWillChange.send()
    }

    init() {
        microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        prompt = defaults.string(forKey: "englishPrompt") ?? Self.defaultPrompt
        soundEffectsEnabled = defaults.bool(forKey: "soundEffectsEnabled")
        activeProvider = defaults.string(forKey: "activeProvider").flatMap(AIProviderPreset.init) ?? .gemini

        var loadedConfigs: [AIProviderPreset: ProviderSettings] = [:]
        for preset in AIProviderPreset.allCases {
            if let data = defaults.data(forKey: "providerConfig.\(preset.rawValue)"),
               let decoded = try? JSONDecoder().decode(ProviderSettings.self, from: data) {
                loadedConfigs[preset] = decoded
            }
        }
        providerConfigs = loadedConfigs

        if let data = defaults.data(forKey: "rewriteOverride"),
           let decoded = try? JSONDecoder().decode(RewriteOverrideSettings.self, from: data) {
            rewriteOverride = decoded
        } else {
            rewriteOverride = RewriteOverrideSettings()
        }

        var savedShortcuts: [OutputMode: Shortcut] = [:]
        for mode in OutputMode.allCases {
            if let data = defaults.data(forKey: mode.shortcutPreference),
               let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data), shortcut.isValid {
                savedShortcuts[mode] = shortcut
            }
        }
        shortcuts = savedShortcuts
    }
}

// MARK: - macOS Keychain API Key Storage

enum APIKeyStore {
    static let rewriteOverrideAccount = "provider-rewrite-override-api-key"

    private static func identity(account: String) -> [String: String] {
        [
            kSecClass as String: kSecClassGenericPassword as String,
            kSecAttrService as String: "com.yapflush.api",
            kSecAttrAccount as String: account
        ]
    }

    static func read(account: String) throws -> String? {
        var query: [String: Any] = identity(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw failure(status)
        }
        return key
    }

    static func save(_ key: String, account: String) throws {
        let id = identity(account: account)
        if key.isEmpty {
            let status = SecItemDelete(id as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
            return
        }
        let data = Data(key.utf8)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(id as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var query: [String: Any] = id
            query[kSecValueData as String] = data
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw failure(status) }
    }

    private static func failure(_ status: OSStatus) -> VoiceTypeError {
        .message("无法访问钥匙串（\(status)）。请确认登录钥匙串已解锁。")
    }
}

// MARK: - Local Token & Cost Usage Tracking (Numeric Aggregates Only)

enum ModelPricing {
    struct Rate: Sendable {
        let inputPerMillion: Double?
        let outputPerMillion: Double?
        let perAudioMinute: Double?
    }

    static let usdToCNYReference: Double = 7.25

    static func rate(for model: String) -> Rate? {
        let m = model.lowercased()
        if m.contains("gemini-3.5-transcribe-live") {
            return Rate(inputPerMillion: 3.50, outputPerMillion: 21.00, perAudioMinute: nil)
        }
        if m.contains("gemini-3.5-transcribe") {
            return Rate(inputPerMillion: 2.00, outputPerMillion: 12.00, perAudioMinute: nil)
        }
        if m.contains("gemini-3.5-flash-lite") {
            return Rate(inputPerMillion: 0.30, outputPerMillion: 2.50, perAudioMinute: nil)
        }
        if m.contains("gpt-4o-mini-transcribe") {
            return Rate(inputPerMillion: 3.00, outputPerMillion: 5.00, perAudioMinute: 0.003)
        }
        if m.contains("gpt-4o-transcribe") {
            return Rate(inputPerMillion: 6.00, outputPerMillion: 10.00, perAudioMinute: 0.006)
        }
        if m == "whisper-1" {
            return Rate(inputPerMillion: nil, outputPerMillion: nil, perAudioMinute: 0.006)
        }
        if m.contains("whisper-large-v3-turbo") {
            return Rate(inputPerMillion: nil, outputPerMillion: nil, perAudioMinute: 0.00067)
        }
        if m.contains("whisper-large-v3") {
            return Rate(inputPerMillion: nil, outputPerMillion: nil, perAudioMinute: 0.00185)
        }
        if m.contains("gpt-4o-mini") {
            return Rate(inputPerMillion: 0.15, outputPerMillion: 0.60, perAudioMinute: nil)
        }
        if m.contains("gpt-4.1-mini") {
            return Rate(inputPerMillion: 0.40, outputPerMillion: 1.60, perAudioMinute: nil)
        }
        if m.contains("llama-3.3-70b") {
            return Rate(inputPerMillion: 0.59, outputPerMillion: 0.79, perAudioMinute: nil)
        }
        if m.contains("deepseek-chat") {
            return Rate(inputPerMillion: 0.27, outputPerMillion: 1.10, perAudioMinute: nil)
        }
        return nil
    }

    static func estimateCostUSD(model: String, inputTokens: Int, outputTokens: Int, audioSeconds: Double) -> Double {
        guard let rate = rate(for: model) else { return 0 }
        if (inputTokens > 0 || outputTokens > 0), let inPrice = rate.inputPerMillion, let outPrice = rate.outputPerMillion {
            return (Double(inputTokens) / 1_000_000.0) * inPrice +
                   (Double(outputTokens) / 1_000_000.0) * outPrice
        }
        if audioSeconds > 0, let perMin = rate.perAudioMinute {
            return (audioSeconds / 60.0) * perMin
        }
        return 0
    }
}

struct UsageSummary: Equatable, Sendable {
    var dictationCount: Int = 0
    var audioSeconds: Double = 0
    var transcribeRequests: Int = 0
    var transcribeInputTokens: Int = 0
    var transcribeOutputTokens: Int = 0
    var transcribeCostUSD: Double = 0
    var rewriteRequests: Int = 0
    var rewriteInputTokens: Int = 0
    var rewriteOutputTokens: Int = 0
    var rewriteCostUSD: Double = 0

    var totalInputTokens: Int { transcribeInputTokens + rewriteInputTokens }
    var totalOutputTokens: Int { transcribeOutputTokens + rewriteOutputTokens }
    var totalTokens: Int { totalInputTokens + totalOutputTokens }
    var totalCostUSD: Double { transcribeCostUSD + rewriteCostUSD }
    var totalCostCNY: Double { totalCostUSD * ModelPricing.usdToCNYReference }

    mutating func merge(_ other: DailyUsageRecord) {
        dictationCount += other.dictationCount
        audioSeconds += other.audioSeconds
        transcribeRequests += other.transcribeRequests
        transcribeInputTokens += other.transcribeInputTokens
        transcribeOutputTokens += other.transcribeOutputTokens
        transcribeCostUSD += other.transcribeCostUSD
        rewriteRequests += other.rewriteRequests
        rewriteInputTokens += other.rewriteInputTokens
        rewriteOutputTokens += other.rewriteOutputTokens
        rewriteCostUSD += other.rewriteCostUSD
    }

    static func formatUSD(_ amount: Double) -> String {
        if amount == 0 { return "$0.00" }
        if amount < 0.0001 { return "<$0.0001" }
        if amount < 0.01 { return String(format: "$%.4f", amount) }
        if amount < 1.0 { return String(format: "$%.3f", amount) }
        return String(format: "$%.2f", amount)
    }

    static func formatCNY(_ amount: Double) -> String {
        if amount == 0 { return "≈ ¥0.00" }
        if amount < 0.01 { return String(format: "≈ ¥%.3f", amount) }
        return String(format: "≈ ¥%.2f", amount)
    }

    static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)秒" }
        let minutes = total / 60
        let rem = total % 60
        if minutes < 60 {
            return rem == 0 ? "\(minutes)分" : "\(minutes)分\(rem)秒"
        }
        let hours = minutes / 60
        let remMin = minutes % 60
        return "\(hours)小时\(remMin)分"
    }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.2fM", Double(count) / 1_000_000.0) }
        if count >= 10_000 { return String(format: "%.1fK", Double(count) / 1_000.0) }
        if count >= 1_000 { return String(format: "%.2fK", Double(count) / 1_000.0) }
        return "\(count)"
    }
}

struct DailyUsageRecord: Codable, Equatable, Sendable {
    var dictationCount: Int = 0
    var audioSeconds: Double = 0
    var transcribeRequests: Int = 0
    var transcribeInputTokens: Int = 0
    var transcribeOutputTokens: Int = 0
    var transcribeCostUSD: Double = 0
    var rewriteRequests: Int = 0
    var rewriteInputTokens: Int = 0
    var rewriteOutputTokens: Int = 0
    var rewriteCostUSD: Double = 0

    var estimatedCostUSD: Double { transcribeCostUSD + rewriteCostUSD }
}

struct DailyUsagePoint: Identifiable, Equatable {
    let id: String
    let label: String
    let isToday: Bool
    let count: Int
    let audioSeconds: Double
    let costUSD: Double
}

@MainActor
final class UsageStore: ObservableObject {
    private static let storageKey = "yapflush.usage.daily.v2"
    private let defaults = UserDefaults.standard
    @Published private(set) var daily: [String: DailyUsageRecord] = [:]

    init() {
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([String: DailyUsageRecord].self, from: data) {
            daily = decoded
        }
    }

    func recordTranscribe(model: String, audioSeconds: Double, usage: TokenUsage, countAsDictation: Bool = true, at date: Date = .now) {
        let key = Self.dayKey(for: date)
        var record = daily[key] ?? DailyUsageRecord()
        if countAsDictation { record.dictationCount += 1 }
        let sec = max(0, audioSeconds)
        record.audioSeconds += sec
        record.transcribeRequests += 1
        record.transcribeInputTokens += usage.inputTokens
        record.transcribeOutputTokens += usage.billableOutputTokens
        record.transcribeCostUSD += ModelPricing.estimateCostUSD(
            model: model,
            inputTokens: usage.inputTokens,
            outputTokens: usage.billableOutputTokens,
            audioSeconds: sec
        )
        daily[key] = record
        persist()
    }

    func recordRewrite(model: String, usage: TokenUsage, at date: Date = .now) {
        let key = Self.dayKey(for: date)
        var record = daily[key] ?? DailyUsageRecord()
        record.rewriteRequests += 1
        record.rewriteInputTokens += usage.inputTokens
        record.rewriteOutputTokens += usage.billableOutputTokens
        record.rewriteCostUSD += ModelPricing.estimateCostUSD(
            model: model,
            inputTokens: usage.inputTokens,
            outputTokens: usage.billableOutputTokens,
            audioSeconds: 0
        )
        daily[key] = record
        persist()
    }

    func resetAll() {
        daily.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
    }

    func summaryForToday(now: Date = .now) -> UsageSummary {
        var summary = UsageSummary()
        if let record = daily[Self.dayKey(for: now)] { summary.merge(record) }
        return summary
    }

    func summaryForMonth(now: Date = .now) -> UsageSummary {
        let prefix = Self.monthPrefix(for: now)
        var summary = UsageSummary()
        for (key, record) in daily where key.hasPrefix(prefix) {
            summary.merge(record)
        }
        return summary
    }

    func summaryAllTime() -> UsageSummary {
        var summary = UsageSummary()
        for record in daily.values { summary.merge(record) }
        return summary
    }

    func last7Days(now: Date = .now) -> [DailyUsagePoint] {
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]
        return (-6...0).compactMap { offset -> DailyUsagePoint? in
            guard let day = calendar.date(byAdding: .day, value: offset, to: todayStart) else { return nil }
            let key = Self.dayKey(for: day)
            let record = daily[key] ?? DailyUsageRecord()
            let weekday = calendar.component(.weekday, from: day)
            let label = offset == 0 ? "今" : weekdaySymbols[(weekday - 1) % 7]
            return DailyUsagePoint(
                id: key,
                label: label,
                isToday: offset == 0,
                count: record.dictationCount,
                audioSeconds: record.audioSeconds,
                costUSD: record.estimatedCostUSD
            )
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(daily) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    private static func dayKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
    }

    private static func monthPrefix(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d-", c.year ?? 2026, c.month ?? 1)
    }
}
