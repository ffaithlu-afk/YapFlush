import AppKit
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "通用"
    case shortcuts = "快捷键"
    case ai = "AI 服务"
    case usage = "用量"

    var id: String { rawValue }

    var subtitle: String {
        switch self {
        case .general: "系统权限、音频输入与启动选项"
        case .shortcuts: "全局按住说话热键与粘贴行为"
        case .ai: "多服务商接入、自定义接口地址与改写风格"
        case .usage: "本地 Token 消耗统计与按官方单价估算花费"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .shortcuts: "keyboard"
        case .ai: "sparkles"
        case .usage: "chart.bar.fill"
        }
    }

    var badgeGradient: [Color] {
        switch self {
        case .general: [Color(red: 0.52, green: 0.54, blue: 0.58), Color(red: 0.38, green: 0.40, blue: 0.44)]
        case .shortcuts: [Color(red: 0.18, green: 0.56, blue: 1.0), Color(red: 0.06, green: 0.40, blue: 0.92)]
        case .ai: [Color(red: 0.54, green: 0.36, blue: 0.98), Color(red: 0.38, green: 0.24, blue: 0.86)]
        case .usage: [Color(red: 0.18, green: 0.78, blue: 0.48), Color(red: 0.08, green: 0.62, blue: 0.38)]
        }
    }
}

private enum UsageScope: String, CaseIterable, Identifiable {
    case today = "今日"
    case month = "本月"
    case all = "累计"

    var id: String { rawValue }
}

struct SettingsView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var preferences: Preferences
    @ObservedObject var usage: UsageStore
    @State private var selection: SettingsSection
    @State private var usageScope: UsageScope = .month
    @State private var showResetConfirm = false
    @State private var primaryKeyInput = ""
    @State private var rewriteKeyInput = ""
    @State private var hoveredSection: SettingsSection?

    init(
        controller: AppController,
        preferences: Preferences,
        usage: UsageStore,
        initialSelection: SettingsSection = .general
    ) {
        self.controller = controller
        self.preferences = preferences
        self.usage = usage
        _selection = State(initialValue: initialSelection)
    }

    private var permissionsReady: Bool {
        controller.microphoneAuthorized && controller.accessibilityAuthorized
    }

    private var appReady: Bool {
        permissionsReady && controller.isProviderConfigured
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detailPane
        }
        .frame(minWidth: 640, minHeight: 500)
    }

    // MARK: - Apple System Settings Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(SettingsSection.allCases) { section in
                    sidebarRow(section)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 46)

            Spacer(minLength: 0)

            Divider()
                .padding(.horizontal, 12)

            HStack(spacing: 9) {
                appIcon
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("YapFlush")
                            .font(.system(size: 12.5, weight: .semibold))
                        Text("口喷桶")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 5) {
                        Circle()
                            .fill(appReady ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(appReady ? "已就绪" : "待完成配置")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(width: 186)
        .background(SidebarVibrancy())
    }

    private func sidebarRow(_ section: SettingsSection) -> some View {
        let isSelected = selection == section
        let isHovered = hoveredSection == section
        let needsAttention = (section == .general && !permissionsReady) ||
            (section == .ai && !controller.isProviderConfigured)

        return Button {
            selection = section
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: section.badgeGradient,
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 22, height: 22)
                    Image(systemName: section.symbol)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                }

                Text(section.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .white : .primary)

                Spacer(minLength: 0)

                if needsAttention {
                    Circle()
                        .fill(isSelected ? Color.white.opacity(0.9) : Color.orange)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.accentColor)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredSection = hovering ? section : (hoveredSection == section ? nil : hoveredSection)
        }
    }

    private var appIcon: some View {
        Group {
            if let icon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
                ?? NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.accentColor.opacity(0.12))
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
    }

    // MARK: - Detail Pane

    private var detailPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(selection.rawValue)
                    .font(.system(size: 20, weight: .semibold))
                Text(selection.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 2)

            Group {
                switch selection {
                case .general: generalTab
                case .shortcuts: shortcutsTab
                case .ai: aiTab
                case .usage: usageTab
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("系统权限") {
                permissionRow(
                    icon: "mic.fill",
                    tint: .red,
                    title: "麦克风",
                    description: "按住快捷键时采集语音音频",
                    authorized: controller.microphoneAuthorized,
                    action: controller.requestMicrophonePermission
                )
                permissionRow(
                    icon: "accessibility",
                    tint: .blue,
                    title: "辅助功能",
                    description: "识别当前焦点输入框并自动粘贴文字",
                    authorized: controller.accessibilityAuthorized,
                    action: controller.requestAccessibilityPermission
                )
            }

            Section("音频与反馈") {
                Picker("输入麦克风", selection: $preferences.microphoneUID) {
                    if let name = controller.defaultMicrophone {
                        Text("系统默认（\(name)）").tag("")
                    } else {
                        Text("系统默认").tag("")
                    }
                    if !preferences.microphoneUID.isEmpty &&
                        !controller.microphones.contains(where: { $0.id == preferences.microphoneUID }) {
                        Text("所选麦克风已断开").tag(preferences.microphoneUID)
                    }
                    ForEach(controller.microphones) { Text($0.name).tag($0.id) }
                }

                Toggle(isOn: $preferences.soundEffectsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("录音提示音")
                        Text("开始与结束录音时播放轻柔的系统提示音")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("应用启动") {
                Toggle(isOn: Binding(
                    get: { controller.launchAtLogin },
                    set: { controller.setLaunchAtLogin($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("登录 macOS 时自动启动")
                        Text("常驻菜单栏，开机即可随时按住快捷键语音输入")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !controller.launchAtLoginNote.isEmpty {
                    Text(controller.launchAtLoginNote)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Shortcuts Tab

    private var shortcutsTab: some View {
        Form {
            Section {
                ForEach(OutputMode.allCases) { mode in
                    shortcutRow(for: mode)
                }
                if !controller.shortcutNote.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text(controller.shortcutNote)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            } header: {
                Text("语音输入快捷键")
            } footer: {
                Text("按住快捷键说话，松开后自动粘贴；录音期间可按 Esc 取消。支持单按左 Option、左 Control、F1–F20 或组合键。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("输入与隐私特性") {
                featureRow(
                    icon: "doc.on.clipboard",
                    title: "无痕自动粘贴",
                    detail: "临时粘贴会自动标记为瞬态内容并在粘贴后还原剪贴板，不污染剪贴板历史。"
                )
                featureRow(
                    icon: "lock.shield",
                    title: "纯内存处理",
                    detail: "录音音频与最近记录仅存于内存，关闭即清空，API Key 仅存于 macOS 钥匙串。"
                )
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Multi-Provider AI & Prompt Tab

    private var aiTab: some View {
        let preset = preferences.activeProvider
        let config = preferences.settings(for: preset)
        let isLocal = AIEndpointConfig(
            protocolKind: preset.protocolKind,
            baseURL: config.baseURL,
            model: config.transcribeModel,
            apiKey: ""
        ).isLocalhost

        let baseURLBinding = Binding<String>(
            get: { preferences.settings(for: preset).baseURL },
            set: { newValue in
                var updated = preferences.settings(for: preset)
                updated.baseURL = newValue
                preferences.updateSettings(updated, for: preset)
            }
        )
        let sttModelBinding = Binding<String>(
            get: { preferences.settings(for: preset).transcribeModel },
            set: { newValue in
                var updated = preferences.settings(for: preset)
                updated.transcribeModel = newValue
                preferences.updateSettings(updated, for: preset)
            }
        )
        let llmModelBinding = Binding<String>(
            get: { preferences.settings(for: preset).rewriteModel },
            set: { newValue in
                var updated = preferences.settings(for: preset)
                updated.rewriteModel = newValue
                preferences.updateSettings(updated, for: preset)
            }
        )

        return Form {
            Section {
                Picker("主服务商", selection: $preferences.activeProvider) {
                    ForEach(AIProviderPreset.allCases) { item in
                        Text(item.name).tag(item)
                    }
                }

                LabeledContent("Base URL") {
                    TextField("", text: baseURLBinding, prompt: Text(preset.defaultBaseURL))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                LabeledContent("转写模型（STT）") {
                    TextField("", text: sttModelBinding, prompt: Text(preset.defaultTranscribeModel))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                if !preferences.rewriteOverride.enabled {
                    LabeledContent("改写模型（LLM）") {
                        TextField("", text: llmModelBinding, prompt: Text(preset.defaultRewriteModel))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: (controller.hasActivePrimaryKey || isLocal) ? "lock.fill" : "key.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle((controller.hasActivePrimaryKey || isLocal) ? .green : .orange)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.hasActivePrimaryKey
                             ? "\(preset.name) Key 已存入钥匙串"
                             : (isLocal ? "检测到本地服务（可免 Key）" : "尚未配置 \(preset.name) API Key"))
                            .font(.system(size: 12.5, weight: .medium))
                        Text(controller.keyNote.isEmpty
                             ? "协议：\(preset.protocolKind.displayName)"
                             : controller.keyNote)
                            .font(.caption)
                            .foregroundStyle(controller.keyNoteIsError ? Color.orange : Color.secondary)
                    }

                    Spacer()

                    Button {
                        controller.testActiveConnection()
                    } label: {
                        if controller.keyTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("测试连接")
                        }
                    }
                    .disabled(controller.keyBusy || controller.keyTesting || (!controller.hasActivePrimaryKey && !isLocal))
                }

                HStack(spacing: 8) {
                    SecureField(
                        "",
                        text: $primaryKeyInput,
                        prompt: Text(controller.hasActivePrimaryKey ? "输入新 Key 以替换…" : preset.keyPlaceholder)
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { savePrimaryKey(for: preset) }

                    Button("保存") { savePrimaryKey(for: preset) }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.keyBusy || primaryKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if controller.hasActivePrimaryKey {
                        Button("移除", role: .destructive) {
                            primaryKeyInput = ""
                            controller.saveAPIKey("", for: preset.keychainAccount)
                        }
                        .disabled(controller.keyBusy || controller.keyTesting)
                    }
                }

                HStack {
                    Button("恢复该服务默认地址与模型") {
                        preferences.resetProviderDefaults(for: preset)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    if let url = preset.apiKeyURL {
                        Link("获取 API Key ↗", destination: url)
                            .font(.caption)
                    }
                }
            } header: {
                Text("AI 服务与模型")
            } footer: {
                Text("OpenAI 兼容协议可直接接入 OpenAI、Groq、DeepSeek、OpenRouter、硅基流动、自建中转站或本地 whisper.cpp / Ollama。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("混搭：独立改写服务（可选）") {
                Toggle(isOn: $preferences.rewriteOverride.enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("英文改写使用独立模型服务")
                        Text("例如：用 Groq Whisper 极速转写 + DeepSeek / OpenAI / Ollama 改写")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if preferences.rewriteOverride.enabled {
                    Picker("改写协议", selection: $preferences.rewriteOverride.protocolKind) {
                        ForEach(AIProtocolKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }

                    LabeledContent("改写 Base URL") {
                        TextField("", text: $preferences.rewriteOverride.baseURL, prompt: Text("https://api.deepseek.com/v1"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }

                    LabeledContent("改写模型名") {
                        TextField("", text: $preferences.rewriteOverride.model, prompt: Text("deepseek-chat"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }

                    HStack(spacing: 8) {
                        SecureField(
                            "",
                            text: $rewriteKeyInput,
                            prompt: Text(controller.hasRewriteOverrideKey ? "独立改写 Key 已存钥匙串（输入替换）" : "独立改写服务 API Key（本地服务可留空）")
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveRewriteKey)

                        Button("保存", action: saveRewriteKey)
                            .disabled(controller.keyBusy || rewriteKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if controller.hasRewriteOverrideKey {
                            Button("移除", role: .destructive) {
                                rewriteKeyInput = ""
                                controller.saveAPIKey("", for: APIKeyStore.rewriteOverrideAccount)
                            }
                            .disabled(controller.keyBusy)
                        }
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("X English 系统 Prompt")
                                .font(.system(size: 13, weight: .medium))
                            Text("用于将语音转写改写为自然地道的目标风格文字")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("恢复默认") {
                            preferences.prompt = Preferences.defaultPrompt
                        }
                        .controlSize(.small)
                        .disabled(preferences.prompt == Preferences.defaultPrompt)
                    }

                    TextEditor(text: $preferences.prompt)
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 112, maxHeight: 144)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
                        }
                        .accessibilityLabel("X English 系统 Prompt")

                    HStack {
                        Text("修改实时自动保存")
                        Spacer()
                        Text("\(preferences.prompt.count) 字符")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Usage & Cost Tab

    private var usageTab: some View {
        let today = usage.summaryForToday()
        let month = usage.summaryForMonth()
        let all = usage.summaryAllTime()
        let selected: UsageSummary = switch usageScope {
        case .today: today
        case .month: month
        case .all: all
        }
        let week = usage.last7Days()
        let maxCount = max(1, week.map(\.count).max() ?? 1)
        let endpoints = controller.currentEndpoints()

        return Form {
            Section {
                HStack(spacing: 10) {
                    usageMetricCard(title: "今日", summary: today, highlighted: usageScope == .today)
                        .onTapGesture { usageScope = .today }
                    usageMetricCard(title: "本月", summary: month, highlighted: usageScope == .month)
                        .onTapGesture { usageScope = .month }
                    usageMetricCard(title: "累计", summary: all, highlighted: usageScope == .all)
                        .onTapGesture { usageScope = .all }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6))
                .listRowBackground(Color.clear)
            }

            Section("最近 7 天活跃") {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(week) { point in
                        VStack(spacing: 5) {
                            Text(point.count > 0 ? "\(point.count)" : "")
                                .font(.system(size: 9.5, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(height: 11)

                            ZStack(alignment: .bottom) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                                    .frame(width: 18, height: 46)

                                if point.count > 0 {
                                    let ratio = CGFloat(point.count) / CGFloat(maxCount)
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(point.isToday ? Color.accentColor : Color.accentColor.opacity(0.45))
                                        .frame(width: 18, height: max(6, 46 * ratio))
                                }
                            }

                            Text(point.label)
                                .font(.system(size: 10.5, weight: point.isToday ? .semibold : .regular))
                                .foregroundStyle(point.isToday ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                HStack {
                    Text("统计范围")
                    Spacer()
                    Picker("", selection: $usageScope) {
                        ForEach(UsageScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }

                usageModelRow(
                    name: "语音转写",
                    model: endpoints.transcribe.model,
                    requests: selected.transcribeRequests,
                    inputTokens: selected.transcribeInputTokens,
                    outputTokens: selected.transcribeOutputTokens,
                    costUSD: selected.transcribeCostUSD
                )

                usageModelRow(
                    name: "英文改写",
                    model: endpoints.rewrite.model,
                    requests: selected.rewriteRequests,
                    inputTokens: selected.rewriteInputTokens,
                    outputTokens: selected.rewriteOutputTokens,
                    costUSD: selected.rewriteCostUSD
                )

                HStack {
                    Text("合计估算")
                        .fontWeight(.medium)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(UsageSummary.formatUSD(selected.totalCostUSD))  ·  \(UsageSummary.formatTokens(selected.totalTokens)) tokens")
                            .font(.system(size: 12.5, weight: .semibold))
                            .monospacedDigit()
                        Text("\(UsageSummary.formatCNY(selected.totalCostCNY))（\(selected.dictationCount) 次 · \(UsageSummary.formatDuration(selected.audioSeconds))）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Token 与费用明细")
            } footer: {
                Text("内置 Gemini / OpenAI / Groq / DeepSeek 常见模型标准单价估算（汇率参考 7.25）。自定义或本地模型仅统计次数、时长与 Token；本地仅存纯数字，不存语音与文字。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("官方账单与管理") {
                HStack {
                    if let dashboard = preferences.activeProvider.usageDashboardURL {
                        Link(destination: dashboard) {
                            Label("查看 \(preferences.activeProvider.name) 官方用量 ↗", systemImage: "arrow.up.right.square")
                        }
                    } else {
                        Text("当前为自定义接口，请前往对应服务商后台查看账单")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("清空本地统计", role: .destructive) {
                        showResetConfirm = true
                    }
                    .disabled(all.dictationCount == 0 && all.totalTokens == 0)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .alert("清空本地用量统计？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { usage.resetAll() }
        } message: {
            Text("仅清除本机记录的次数、时长与估算花费，不会影响服务商官方账单。")
        }
    }

    // MARK: - Reusable Rows & Cards

    private func usageMetricCard(title: String, summary: UsageSummary, highlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(highlighted ? Color.accentColor : .secondary)
                Spacer()
                Text("\(summary.dictationCount) 次")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(UsageSummary.formatUSD(summary.totalCostUSD))
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            HStack(spacing: 4) {
                Text(UsageSummary.formatCNY(summary.totalCostCNY))
                Text("·")
                Text(UsageSummary.formatDuration(summary.audioSeconds))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    highlighted ? Color.accentColor.opacity(0.65) : Color(nsColor: .separatorColor).opacity(0.75),
                    lineWidth: highlighted ? 1.25 : 0.75
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func usageModelRow(
        name: String,
        model: String,
        requests: Int,
        inputTokens: Int,
        outputTokens: Int,
        costUSD: Double
    ) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).fontWeight(.medium)
                    Text(model)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text("\(requests) 次请求 · 输入 \(UsageSummary.formatTokens(inputTokens)) · 输出 \(UsageSummary.formatTokens(outputTokens))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Text(UsageSummary.formatUSD(costUSD))
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
        }
        .padding(.vertical, 1)
    }

    private func permissionRow(
        icon: String,
        tint: Color,
        title: String,
        description: String,
        authorized: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tint.opacity(0.13))
                    .frame(width: 26, height: 26)
                Image(systemName: icon)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if authorized {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.10), in: Capsule())
            } else {
                Button("授权", action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel("授权\(title)")
            }
        }
        .padding(.vertical, 1)
    }

    private func shortcutRow(for mode: OutputMode) -> some View {
        let shortcut = preferences.shortcut(for: mode)
        let listening = controller.shortcutCaptureMode == mode
        let description = mode == .english ? "X English · 转写并改写为自然英文" : "Chinese · 直接输出转写原稿"

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(mode.name)输出").fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !shortcut.matches(mode.defaultShortcut) && controller.shortcutCaptureMode == nil {
                Button {
                    controller.restoreDefaultShortcut(for: mode)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("恢复默认（\(mode.defaultShortcut.label)）")
            }

            Button {
                controller.toggleShortcutCapture(for: mode)
            } label: {
                HStack(spacing: 5) {
                    if listening {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                        Text("按下新快捷键…")
                            .font(.system(size: 12, weight: .medium))
                    } else {
                        Text(shortcut.label)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minWidth: 92)
                .background(
                    listening
                        ? Color.accentColor.opacity(0.12)
                        : Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            listening ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: listening ? 1.25 : 0.75
                        )
                }
            }
            .buttonStyle(.plain)
            .help("点击后按下新的\(mode.name)快捷键")
            .accessibilityLabel(listening ? "等待录入\(mode.name)快捷键" : "更改\(mode.name)快捷键，当前为 \(shortcut.label)")
        }
        .padding(.vertical, 2)
    }

    private func featureRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    private func savePrimaryKey(for preset: AIProviderPreset) {
        let text = primaryKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !controller.keyBusy else { return }
        controller.saveAPIKey(text, for: preset.keychainAccount)
        primaryKeyInput = ""
    }

    private func saveRewriteKey() {
        let text = rewriteKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !controller.keyBusy else { return }
        controller.saveAPIKey(text, for: APIKeyStore.rewriteOverrideAccount)
        rewriteKeyInput = ""
    }
}

private struct SidebarVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
