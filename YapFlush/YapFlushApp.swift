import AppKit
import AVFoundation
import Carbon
import SwiftUI

@main
struct YapFlushApp: App {
    @NSApplicationDelegateAdaptor(AppController.self) private var controller

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, ObservableObject {
    let preferences = Preferences()
    let usage = UsageStore()
    @Published private(set) var microphones: [Microphone] = []
    @Published private(set) var defaultMicrophone: String?
    @Published private(set) var microphoneAuthorized = false
    @Published private(set) var accessibilityAuthorized = false
    @Published private(set) var apiKeys: [String: String] = [:]
    @Published private(set) var keyBusy = false
    @Published private(set) var keyTesting = false
    @Published private(set) var keyNote = ""
    @Published private(set) var keyNoteIsError = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginNote = ""
    @Published private(set) var shortcutCaptureMode: OutputMode?
    @Published private(set) var shortcutNote = ""

    private enum Stage {
        case preparing, recording, transcribing, rewriting
    }

    private struct Job {
        let id: UUID
        let target: PasteTarget?
        let mode: OutputMode
        let prompt: String
        let transcribeConfig: AIEndpointConfig
        let rewriteConfig: AIEndpointConfig
        let startedAt: ContinuousClock.Instant
        var stage: Stage = .preparing
    }

    private struct ResultText {
        let text: String
        let label: String
        let mode: OutputMode
    }

    private struct FailedAudio {
        let wav: Data
        let mode: OutputMode
        let prompt: String
    }

    private let recorder = AudioRecorder()
    private let hotkey = GlobalShortcut()
    private let insertion = TextInsertion()
    private let hud = StatusHUD()
    private let menu = NSMenu()
    private var item: NSStatusItem?
    private var window: NSWindow?
    private var shortcutMonitor: Any?
    private var shortcutCaptureTimeout: Task<Void, Never>?
    private var capturingModifier: StandaloneModifier?
    private var deviceObservers: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var job: Job?
    private var processing: Task<Void, Never>?
    private var recordingLimit: Task<Void, Never>?
    private var recentResults: [ResultText] = []
    private var lastFailedAudio: FailedAudio?
    private var menuStatus = ""

    // MARK: - Active Provider Config Helpers

    var hasActivePrimaryKey: Bool {
        let key = apiKeys[preferences.activeProvider.keychainAccount] ?? ""
        return !key.isEmpty
    }

    var hasRewriteOverrideKey: Bool {
        let key = apiKeys[APIKeyStore.rewriteOverrideAccount] ?? ""
        return !key.isEmpty
    }

    var isProviderConfigured: Bool {
        let endpoints = currentEndpoints()
        let sttOK = endpoints.transcribe.hasValidAuth && !endpoints.transcribe.model.isEmpty && !endpoints.transcribe.normalizedBaseURL.isEmpty
        let llmOK = endpoints.rewrite.hasValidAuth && !endpoints.rewrite.model.isEmpty && !endpoints.rewrite.normalizedBaseURL.isEmpty
        return sttOK && llmOK
    }

    func currentEndpoints() -> (transcribe: AIEndpointConfig, rewrite: AIEndpointConfig) {
        let preset = preferences.activeProvider
        let config = preferences.settings(for: preset)
        let primaryKey = apiKeys[preset.keychainAccount] ?? ""
        let stt = AIEndpointConfig(
            protocolKind: preset.protocolKind,
            baseURL: config.baseURL,
            model: config.transcribeModel.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: primaryKey
        )
        let llm: AIEndpointConfig
        if preferences.rewriteOverride.enabled {
            let ov = preferences.rewriteOverride
            llm = AIEndpointConfig(
                protocolKind: ov.protocolKind,
                baseURL: ov.baseURL,
                model: ov.model.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: apiKeys[APIKeyStore.rewriteOverrideAccount] ?? ""
            )
        } else {
            llm = AIEndpointConfig(
                protocolKind: preset.protocolKind,
                baseURL: config.baseURL,
                model: config.rewriteModel.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: primaryKey
            )
        }
        return (stt, llm)
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menu.delegate = self
        menu.autoenablesItems = false
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item = statusItem
        statusItem.menu = menu
        updateIcon("waveform")
        hotkey.onPress = { [weak self] mode in
            guard let self else { return }
            if let captureMode = self.shortcutCaptureMode, self.window?.isKeyWindow == true {
                self.setShortcut(self.preferences.shortcut(for: mode), for: captureMode)
            } else {
                self.startRecording(for: mode)
            }
        }
        hotkey.onRelease = { [weak self] mode in
            guard let self, self.job?.mode == mode else { return }
            self.finishRecording()
        }
        hotkey.onCancel = { [weak self] mode in
            guard let self, let job = self.job, job.mode == mode,
                  job.stage == .preparing || job.stage == .recording else { return }
            self.cancelOperation()
        }
        registerShortcuts()
        loadAllKeys()
        refreshPermissions()
        refreshLaunchAtLogin()
        ToiletSpriteSheet.prewarm()

        let names = [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification]
        deviceObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMicrophones() }
            }
        }

        if !preferences.didShowWelcome {
            preferences.didShowWelcome = true
            openSettings()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissions()
        refreshMicrophones()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        processing?.cancel()
        if let job { recorder.cancel(id: job.id) }
        hotkey.suspend()
        insertion.restore()
        deviceObservers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Menu Bar

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshPermissions()
        menu.removeAllItems()
        let title = addItem("YapFlush · 口喷桶", action: nil)
        title.isEnabled = false
        let today = usage.summaryForToday()
        if today.dictationCount > 0 {
            let costPart = today.totalCostUSD > 0 ? " · 约 \(UsageSummary.formatUSD(today.totalCostUSD))" : ""
            let summary = "今日 \(today.dictationCount) 次 · \(UsageSummary.formatDuration(today.audioSeconds))\(costPart)"
            addItem(summary, action: nil).isEnabled = false
        }
        if !menuStatus.isEmpty { addItem(menuStatus, action: nil).isEnabled = false }
        menu.addItem(.separator())

        for mode in OutputMode.allCases {
            addItem("\(mode.name) · \(preferences.shortcut(for: mode).label)", action: nil).isEnabled = false
        }
        menu.addItem(.separator())
        if job != nil { addItem("取消当前操作", action: #selector(cancelFromMenu)) }
        if let failed = lastFailedAudio, job == nil {
            addItem("重试上次失败录音（\(failed.mode.name)）", action: #selector(retryFailedAudio))
        }
        if let latest = recentResults.first {
            addItem(latest.label, action: #selector(copyResult))
        }
        if recentResults.count > 1 {
            let historyItem = NSMenuItem(title: "最近记录", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for (index, entry) in recentResults.enumerated() {
                let compact = entry.text.replacingOccurrences(of: "\n", with: " ")
                let preview = compact.count > 34 ? "\(compact.prefix(34))…" : compact
                let row = NSMenuItem(title: "\(entry.mode.name) · \(preview)", action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                row.target = self
                row.tag = index
                submenu.addItem(row)
            }
            historyItem.submenu = submenu
            menu.addItem(historyItem)
        }
        if !microphoneAuthorized || !accessibilityAuthorized {
            addItem("完成权限设置…", action: #selector(openSettings))
        }
        addItem("设置…", action: #selector(openSettings), key: ",")
        menu.addItem(.separator())
        addItem("退出 YapFlush", action: #selector(quit), key: "q")
    }

    // MARK: - Settings Window

    @objc func openSettings() {
        refreshPermissions()
        refreshMicrophones()
        refreshLaunchAtLogin()
        if window == nil {
            let settings = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            settings.title = "YapFlush 设置"
            settings.titleVisibility = .hidden
            settings.titlebarAppearsTransparent = true
            settings.isMovableByWindowBackground = true
            settings.isReleasedWhenClosed = false
            settings.contentMinSize = NSSize(width: 640, height: 500)
            settings.collectionBehavior = [.moveToActiveSpace]
            settings.delegate = self
            settings.contentView = NSHostingView(rootView: SettingsView(controller: self, preferences: preferences, usage: usage))
            settings.center()
            window = settings
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshPermissions()
                    self?.refreshDefaultMicrophone()
                    self?.refreshLaunchAtLogin()
                }
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if shortcutCaptureMode != nil { stopShortcutCapture() }
    }

    func windowWillClose(_ notification: Notification) {
        if shortcutCaptureMode != nil { stopShortcutCapture() }
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    // MARK: - Permissions & Keychain

    func requestMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refreshPermissions() }
            }
        case .denied, .restricted:
            openPrivacyPane("Privacy_Microphone")
        case .authorized:
            refreshPermissions()
        @unknown default:
            openPrivacyPane("Privacy_Microphone")
        }
    }

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            openPrivacyPane("Privacy_Accessibility")
        }
        refreshPermissions()
    }

    func saveAPIKey(_ input: String, for account: String) {
        guard !keyBusy else { return }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) ||
            CharacterSet.controlCharacters.contains($0) }) else {
            keyNoteIsError = true
            keyNote = "API Key 中包含空格或换行，请检查后再保存。"
            return
        }
        keyBusy = true
        keyNote = ""
        keyNoteIsError = false
        Task {
            defer { keyBusy = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try APIKeyStore.save(trimmed, account: account)
                }.value
                if trimmed.isEmpty {
                    apiKeys.removeValue(forKey: account)
                    keyNote = "已移除 API Key"
                } else {
                    apiKeys[account] = trimmed
                    keyNote = "已安全保存到 macOS 钥匙串"
                }
                keyNoteIsError = false
            } catch {
                keyNoteIsError = true
                keyNote = error.localizedDescription
            }
        }
    }

    func testActiveConnection() {
        guard !keyBusy, !keyTesting else { return }
        let endpoints = currentEndpoints()
        guard endpoints.rewrite.hasValidAuth else {
            keyNoteIsError = true
            keyNote = "请先保存当前服务的 API Key（本地 localhost 服务除外）。"
            return
        }
        keyTesting = true
        keyNoteIsError = false
        keyNote = "正在测试连接（\(endpoints.rewrite.model)）…"
        Task {
            defer { keyTesting = false }
            do {
                try await AIClient(transcribe: endpoints.transcribe, rewrite: endpoints.rewrite).verifyConnection()
                keyNoteIsError = false
                keyNote = "连接正常，模型 \(endpoints.rewrite.model) 响应成功"
            } catch {
                keyNoteIsError = true
                keyNote = error.localizedDescription
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginNote = ""
        do {
            try preferences.setLaunchAtLogin(enabled)
            refreshLaunchAtLogin()
        } catch {
            refreshLaunchAtLogin()
            launchAtLoginNote = "无法修改启动项，请将 YapFlush.app 移至「应用程序」文件夹后重试。"
        }
    }

    private func refreshLaunchAtLogin() {
        let enabled = preferences.launchAtLoginEnabled
        if enabled != launchAtLogin { launchAtLogin = enabled }
    }

    private func loadAllKeys() {
        keyBusy = true
        let accounts = AIProviderPreset.allCases.map(\.keychainAccount) + [APIKeyStore.rewriteOverrideAccount]
        Task {
            defer { keyBusy = false }
            let loaded: [String: String] = await Task.detached {
                var result: [String: String] = [:]
                for account in accounts {
                    if let key = try? APIKeyStore.read(account: account), !key.isEmpty {
                        result[account] = key
                    }
                }
                return result
            }.value
            apiKeys = loaded
        }
    }

    // MARK: - Shortcut Capture

    func toggleShortcutCapture(for mode: OutputMode) {
        if let current = shortcutCaptureMode {
            stopShortcutCapture()
            if current == mode { return }
        }
        shortcutCaptureMode = mode
        shortcutNote = "按 Esc 取消。"
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, self.shortcutCaptureMode == mode, self.window?.isKeyWindow == true else { return event }
            if event.type == .flagsChanged {
                if let modifier = StandaloneModifier(keyCode: event.keyCode) {
                    if modifier.isDown(in: event) {
                        self.capturingModifier = modifier.hasOtherModifier(in: event) || self.capturingModifier != nil ? nil : modifier
                    } else if self.capturingModifier == modifier {
                        self.setShortcut(modifier.shortcut, for: mode)
                    }
                } else {
                    self.capturingModifier = nil
                }
                return event
            }
            self.capturingModifier = nil
            guard !event.isARepeat else { return nil }
            if event.keyCode == kVK_Escape {
                self.stopShortcutCapture()
            } else if let shortcut = Shortcut(event: event) {
                self.setShortcut(shortcut, for: mode)
            } else {
                self.shortcutNote = "可以单按左 Option、左 Control、F1–F20，或按组合键。"
            }
            return nil
        }
        shortcutCaptureTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, !Task.isCancelled, self.shortcutCaptureMode == mode else { return }
            self.stopShortcutCapture()
            self.shortcutNote = "没有录入快捷键。点击当前键可重试。"
        }
    }

    private func stopShortcutCapture() {
        shortcutCaptureTimeout?.cancel()
        shortcutCaptureTimeout = nil
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
        capturingModifier = nil
        shortcutCaptureMode = nil
        shortcutNote = ""
    }

    func restoreDefaultShortcut(for mode: OutputMode) {
        setShortcut(mode.defaultShortcut, for: mode)
    }

    private func setShortcut(_ candidate: Shortcut, for mode: OutputMode) {
        stopShortcutCapture()
        if let other = OutputMode.allCases.first(where: { $0 != mode && preferences.shortcut(for: $0).matches(candidate) }) {
            shortcutNote = "\(candidate.label) 已用作\(other.name)快捷键。"
            return
        }
        do {
            try hotkey.register(candidate, for: mode)
            if job?.mode == mode { cancelOperation() }
            preferences.setShortcut(candidate, for: mode)
            shortcutNote = "\(mode.name)已设为 \(candidate.label)"
        } catch {
            shortcutNote = error.localizedDescription
        }
    }

    private func registerShortcuts() {
        var failures: [String] = []
        for mode in OutputMode.allCases {
            do {
                try hotkey.register(preferences.shortcut(for: mode), for: mode)
            } catch {
                failures.append("\(mode.name)快捷键 · \(error.localizedDescription)")
            }
        }
        shortcutNote = failures.joined(separator: "\n")
        if !failures.isEmpty {
            notify("快捷键不可用", detail: shortcutNote, symbol: "keyboard.badge.exclamationmark", tint: .orange)
        }
    }

    private func refreshPermissions() {
        let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let accessibility = AXIsProcessTrusted() && CGPreflightPostEventAccess()
        if microphone != microphoneAuthorized { microphoneAuthorized = microphone }
        if accessibility != accessibilityAuthorized {
            accessibilityAuthorized = accessibility
            if accessibility, OutputMode.allCases.contains(where: {
                preferences.shortcut(for: $0).standaloneModifier != nil && !hotkey.isRegistered(for: $0)
            }) {
                registerShortcuts()
            }
        }
    }

    private func refreshMicrophones() {
        microphones = Microphone.available()
        refreshDefaultMicrophone()
    }

    private func refreshDefaultMicrophone() {
        let name = Microphone.defaultName
        if name != defaultMicrophone { defaultMicrophone = name }
    }

    private func openPrivacyPane(_ name: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(name)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Recording & AI Pipeline

    private func startRecording(for mode: OutputMode) {
        guard job == nil, shortcutCaptureMode == nil, window?.isKeyWindow != true else { return }
        refreshPermissions()
        guard microphoneAuthorized else {
            notify("麦克风需要授权", detail: "请从 YapFlush 菜单打开权限设置。", symbol: "mic.slash", tint: .orange)
            return
        }
        let endpoints = currentEndpoints()
        guard endpoints.transcribe.hasValidAuth,
              mode == .chinese || endpoints.rewrite.hasValidAuth else {
            notify("需要配置 API Key", detail: keyBusy ? "正在读取钥匙串。" : "请在 YapFlush 设置的「AI 服务」中保存 API Key。",
                   symbol: "key", tint: .orange)
            return
        }

        let id = UUID()
        let startedAt = ContinuousClock.now
        recorder.begin(id: id, deviceUID: preferences.microphoneUID) { [weak self] deviceName in
            Task { @MainActor in self?.captureReady(id: id, deviceName: deviceName) }
        } onFailure: { [weak self] error in
            Task { @MainActor in self?.fail(id: id, title: "录音失败", detail: error.localizedDescription) }
        } onWaveform: { [weak self] waveform in
            Task { @MainActor in
                guard let self, self.job?.id == id, self.job?.stage == .recording else { return }
                self.hud.updateWaveform(waveform)
            }
        }
        job = Job(
            id: id,
            target: accessibilityAuthorized ? PasteTarget.capture() : nil,
            mode: mode,
            prompt: preferences.prompt,
            transcribeConfig: endpoints.transcribe,
            rewriteConfig: endpoints.rewrite,
            startedAt: startedAt
        )
        hotkey.enableEscape(for: mode)
        updateIcon("mic.fill", tint: .systemRed)
        progress("正在打开麦克风 · \(mode.name)", detail: "松开结束  ·  Esc 取消", badgeText: mode.name, recorderPhase: .opening)
        recordingLimit = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Wave.maximumSeconds))
            guard !Task.isCancelled else { return }
            self?.finishRecording(reachedLimit: true)
        }
    }

    private func captureReady(id: UUID, deviceName: String) {
        guard let job, job.id == id, job.stage == .preparing else { return }
        self.job?.stage = .recording
        playCue("Tink")
        progress("正在录音 · \(job.mode.name)", detail: "\(deviceName) · 松开结束  ·  Esc 取消", badgeText: job.mode.name, recorderPhase: .recording)
    }

    private func finishRecording(reachedLimit: Bool = false) {
        guard let snapshot = job, snapshot.stage == .recording || snapshot.stage == .preparing else { return }
        recordingLimit?.cancel()
        recordingLimit = nil
        hotkey.disableEscape()
        guard snapshot.startedAt.duration(to: .now) >= .milliseconds(180) else {
            fail(id: snapshot.id, title: "录音太短", detail: "请按住快捷键再说话。")
            return
        }

        job?.stage = .transcribing
        playCue("Pop")
        updateIcon("waveform")
        progress("正在识别…", detail: reachedLimit ? "已达到 5 分钟录音上限" : snapshot.mode.rawValue, badgeText: "转写中", recorderPhase: .closing)
        processing = Task {
            let client = AIClient(transcribe: snapshot.transcribeConfig, rewrite: snapshot.rewriteConfig)
            var capturedWav: Data?
            var transcript: String?
            do {
                let wav = try await recorder.finish(id: snapshot.id)
                capturedWav = wav
                try Task.checkCancellation()
                let audioSeconds = Double(max(0, wav.count - 44)) / Double(Wave.bytesPerSecond)
                let transcribed = try await client.transcribe(wav: wav)
                usage.recordTranscribe(model: transcribed.model, audioSeconds: audioSeconds, usage: transcribed.usage)
                let rawText = transcribed.text
                transcript = rawText
                try Task.checkCancellation()

                var result = rawText
                if snapshot.mode == .english {
                    job?.stage = .rewriting
                    progress("正在改写成英文…", detail: snapshot.rewriteConfig.model)
                    let prompt = snapshot.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rewritten = try await client.rewrite(rawText, prompt: prompt.isEmpty ? Preferences.defaultPrompt : prompt)
                    usage.recordRewrite(model: rewritten.model, usage: rewritten.usage)
                    result = rewritten.text
                }
                try Task.checkCancellation()
                guard job?.id == snapshot.id else { return }
                lastFailedAudio = nil
                recordResult(ResultText(text: result, label: "复制上次结果", mode: snapshot.mode))
                clearJob()
                do {
                    guard accessibilityAuthorized else { throw VoiceTypeError.message("辅助功能未授权。") }
                    let pasteText = snapshot.mode == .english
                        ? "\(result.trimmingCharacters(in: .whitespacesAndNewlines)) "
                        : result
                    try insertion.paste(pasteText, into: snapshot.target)
                    notify("已发送粘贴", detail: "可从菜单复制上次结果", symbol: "checkmark")
                } catch {
                    notify("结果已保留", detail: "\(error.localizedDescription) 可从菜单复制。",
                           symbol: "doc.on.clipboard", tint: .orange)
                }
            } catch is CancellationError {
                if job?.id == snapshot.id && !Task.isCancelled { cancelOperation() }
            } catch {
                guard job?.id == snapshot.id, !Task.isCancelled else { return }
                if let transcript {
                    lastFailedAudio = nil
                    recordResult(ResultText(text: transcript, label: "复制上次转写原稿", mode: .chinese))
                    fail(id: snapshot.id, title: "英文改写失败", detail: "\(error.localizedDescription) 可从菜单复制原稿。")
                } else {
                    if let capturedWav {
                        lastFailedAudio = FailedAudio(wav: capturedWav, mode: snapshot.mode, prompt: snapshot.prompt)
                    }
                    let title = (error as? VoiceTypeError) != nil ? "未生成文字" : "处理失败"
                    let suffix = capturedWav != nil ? " 可从菜单重试上次录音。" : ""
                    fail(id: snapshot.id, title: title, detail: "\(error.localizedDescription)\(suffix)")
                }
            }
        }
    }

    private func cancelOperation() {
        guard let job else { return }
        recorder.cancel(id: job.id)
        processing?.cancel()
        clearJob()
        notify("已取消", detail: "", symbol: "xmark", duration: .seconds(1))
    }

    private func fail(id: UUID, title: String, detail: String) {
        guard job?.id == id else { return }
        recorder.cancel(id: id)
        processing?.cancel()
        clearJob()
        notify(title, detail: detail, symbol: "exclamationmark", tint: .orange)
    }

    private func clearJob() {
        job = nil
        processing = nil
        recordingLimit?.cancel()
        recordingLimit = nil
        hotkey.disableEscape()
        updateIcon("waveform")
    }

    private func progress(_ title: String, detail: String, badgeText: String? = nil, recorderPhase: RecorderHUDPhase? = nil) {
        menuStatus = title
        hud.show(StatusNotice(title: title, detail: detail, symbol: recorderPhase == nil ? "waveform" : "mic.fill",
                              badgeText: badgeText,
                              tint: recorderPhase == .recording ? .red : .accentColor,
                              isWorking: recorderPhase == nil, recorderPhase: recorderPhase))
    }

    private func notify(
        _ title: String, detail: String, symbol: String, tint: Color = .accentColor,
        duration: Duration = .seconds(4)
    ) {
        menuStatus = title
        hud.show(StatusNotice(title: title, detail: detail, symbol: symbol, tint: tint), duration: duration)
    }

    private func recordResult(_ entry: ResultText) {
        recentResults.insert(entry, at: 0)
        if recentResults.count > 5 { recentResults.removeLast(recentResults.count - 5) }
    }

    private func playCue(_ name: String) {
        guard preferences.soundEffectsEnabled, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.35
        sound.play()
    }

    private func updateIcon(_ symbol: String, tint: NSColor? = nil) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "YapFlush（口喷桶）")
        image?.isTemplate = tint == nil
        item?.button?.image = image
        item?.button?.contentTintColor = tint
        item?.button?.toolTip = "YapFlush · 口喷桶"
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector?, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    @objc private func cancelFromMenu() { cancelOperation() }

    @objc private func retryFailedAudio() {
        guard job == nil, let failed = lastFailedAudio else { return }
        let endpoints = currentEndpoints()
        guard endpoints.transcribe.hasValidAuth,
              failed.mode == .chinese || endpoints.rewrite.hasValidAuth else {
            notify("需要配置 API Key", detail: "请在设置中保存当前服务的 API Key 后重试。", symbol: "key", tint: .orange)
            return
        }
        let id = UUID()
        let target = accessibilityAuthorized ? PasteTarget.capture() : nil
        job = Job(
            id: id,
            target: target,
            mode: failed.mode,
            prompt: failed.prompt,
            transcribeConfig: endpoints.transcribe,
            rewriteConfig: endpoints.rewrite,
            startedAt: .now,
            stage: .transcribing
        )
        progress("正在重新识别…", detail: failed.mode.rawValue)
        processing = Task {
            let client = AIClient(transcribe: endpoints.transcribe, rewrite: endpoints.rewrite)
            var transcript: String?
            do {
                let audioSeconds = Double(max(0, failed.wav.count - 44)) / Double(Wave.bytesPerSecond)
                let transcribed = try await client.transcribe(wav: failed.wav)
                usage.recordTranscribe(model: transcribed.model, audioSeconds: audioSeconds, usage: transcribed.usage)
                let rawText = transcribed.text
                transcript = rawText
                try Task.checkCancellation()
                var result = rawText
                if failed.mode == .english {
                    job?.stage = .rewriting
                    progress("正在改写成英文…", detail: endpoints.rewrite.model)
                    let prompt = failed.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                    let rewritten = try await client.rewrite(rawText, prompt: prompt.isEmpty ? Preferences.defaultPrompt : prompt)
                    usage.recordRewrite(model: rewritten.model, usage: rewritten.usage)
                    result = rewritten.text
                }
                try Task.checkCancellation()
                guard job?.id == id else { return }
                lastFailedAudio = nil
                recordResult(ResultText(text: result, label: "复制上次结果", mode: failed.mode))
                clearJob()
                if insertion.copy(result) {
                    notify("重新识别完成并已复制", detail: "在目标输入框按 ⌘V 粘贴。", symbol: "checkmark")
                } else {
                    notify("重新识别完成", detail: "请从菜单复制结果。", symbol: "doc.on.clipboard")
                }
            } catch is CancellationError {
                if job?.id == id && !Task.isCancelled { cancelOperation() }
            } catch {
                guard job?.id == id, !Task.isCancelled else { return }
                if let transcript {
                    lastFailedAudio = nil
                    recordResult(ResultText(text: transcript, label: "复制上次转写原稿", mode: .chinese))
                    fail(id: id, title: "英文改写失败", detail: "\(error.localizedDescription) 可从菜单复制原稿。")
                } else {
                    fail(id: id, title: "重试失败", detail: error.localizedDescription)
                }
            }
        }
    }

    @objc private func copyResult() {
        guard let latest = recentResults.first else { return }
        copyTextToClipboard(latest.text)
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard recentResults.indices.contains(sender.tag) else { return }
        copyTextToClipboard(recentResults[sender.tag].text)
    }

    private func copyTextToClipboard(_ text: String) {
        if insertion.copy(text) {
            notify("已复制", detail: "在目标输入框按 ⌘V 粘贴。", symbol: "doc.on.clipboard")
        } else {
            notify("复制失败", detail: "文字仍在 YapFlush 中，可以再试一次。", symbol: "exclamationmark", tint: .orange)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
