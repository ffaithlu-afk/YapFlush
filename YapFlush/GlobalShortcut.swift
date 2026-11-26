import AppKit
import Carbon

@MainActor
final class GlobalShortcut {
    private struct CarbonBinding {
        let id: UInt32
        let ref: EventHotKeyRef
    }

    private struct Binding {
        let shortcut: Shortcut
        let carbon: CarbonBinding?
    }

    private static let signature: OSType = 0x56545950 // VTYP
    private static let cancelID: UInt32 = 0
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?
    private var bindings: [OutputMode: Binding] = [:]
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pendingModifier: (mode: OutputMode, task: Task<Void, Never>)?
    private var heldMode: OutputMode?
    private var escapeMode: OutputMode?
    private var cancelRegistrations: [EventHotKeyRef] = []
    private var releaseTimer: Timer?
    private var sawKeyDown = false
    private var sawModifiersDown = false

    var onPress: ((OutputMode) -> Void)?
    var onRelease: ((OutputMode) -> Void)?
    var onCancel: ((OutputMode) -> Void)?

    func isRegistered(for mode: OutputMode) -> Bool { bindings[mode] != nil }

    func register(_ shortcut: Shortcut, for mode: OutputMode) throws {
        guard shortcut.isValid else {
            throw VoiceTypeError.message("可以单按左 Option、左 Control、F1–F20，或按组合键。")
        }
        if bindings[mode]?.shortcut.matches(shortcut) == true { return }
        if let other = bindings.first(where: { $0.key != mode && $0.value.shortcut.matches(shortcut) })?.key {
            throw VoiceTypeError.message("\(shortcut.label) 已用作\(other.name)快捷键。")
        }
        try installHandler()

        // Prepare the new binding before replacing the previous one.
        let carbon: CarbonBinding?
        if shortcut.standaloneModifier != nil {
            try installMonitors(for: shortcut)
            carbon = nil
        } else {
            carbon = try registerCarbon(shortcut)
        }

        if pendingModifier?.mode == mode { cancelPendingModifier() }
        if heldMode == mode { clearHold() }
        if escapeMode == mode { disableEscape() }
        if let previous = bindings[mode]?.carbon { UnregisterEventHotKey(previous.ref) }
        bindings[mode] = Binding(shortcut: shortcut, carbon: carbon)
        if !bindings.values.contains(where: { $0.shortcut.standaloneModifier != nil }) {
            removeMonitors()
        }
    }

    func suspend() {
        clearHold()
        cancelPendingModifier()
        disableEscape()
        removeMonitors()
        for binding in bindings.values {
            if let carbon = binding.carbon { UnregisterEventHotKey(carbon.ref) }
        }
        bindings.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    func enableEscape(for mode: OutputMode) {
        guard let shortcut = bindings[mode]?.shortcut else { return }
        disableEscape()
        escapeMode = mode
        let heldModifiers = shortcut.standaloneModifier?.carbonMask ?? shortcut.modifiers
        for modifiers in heldModifiers == 0 ? [0] : [0, heldModifiers] {
            var registration: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(kVK_Escape), modifiers, EventHotKeyID(signature: Self.signature, id: Self.cancelID),
                GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &registration
            )
            if status == noErr, let registration { cancelRegistrations.append(registration) }
        }
    }

    func disableEscape() {
        for registration in cancelRegistrations { UnregisterEventHotKey(registration) }
        cancelRegistrations.removeAll()
        escapeMode = nil
    }

    private func installHandler() throws {
        guard handler == nil else { return }
        let events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            // Carbon delivers application-target events on the main run loop.
            return MainActor.assumeIsolated {
                Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue().receive(event)
            }
        }, events.count, events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            throw VoiceTypeError.message("无法启动全局快捷键（\(status)）。")
        }
    }

    private func registerCarbon(_ shortcut: Shortcut) throws -> CarbonBinding {
        let id = nextID
        nextID = nextID == UInt32.max ? 1 : nextID + 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &ref
        )
        guard status == noErr, let ref else {
            if status == eventHotKeyExistsErr {
                throw VoiceTypeError.message("\(shortcut.label) 已被系统或其他 App 占用。请换一个键。")
            }
            throw VoiceTypeError.message("macOS 无法启用 \(shortcut.label)（\(status)）。请试试加上 ⌃ 或 ⌘。")
        }
        return CarbonBinding(id: id, ref: ref)
    }

    private func installMonitors(for shortcut: Shortcut) throws {
        guard AXIsProcessTrusted() else {
            throw VoiceTypeError.message("请先授权辅助功能，以使用\(shortcut.label)。")
        }
        guard globalMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        guard let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.handleModifierEvent(event, allowStart: true)
        }) else {
            throw VoiceTypeError.message("无法监听 \(shortcut.label)。请检查辅助功能权限。")
        }
        guard let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            self?.handleModifierEvent(event, allowStart: false)
            return event
        }) else {
            NSEvent.removeMonitor(global)
            throw VoiceTypeError.message("无法监听 \(shortcut.label)。请重新打开 YapFlush 后重试。")
        }
        globalMonitor = global
        localMonitor = local
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func handleModifierEvent(_ event: NSEvent, allowStart: Bool) {
        let modifier = event.type == .flagsChanged ? StandaloneModifier(keyCode: event.keyCode) : nil
        if let mode = pendingModifier?.mode ?? heldMode,
           let active = bindings[mode]?.shortcut.standaloneModifier {
            if modifier == active {
                if !active.isDown(in: event) {
                    cancelPendingModifier()
                    endHold(for: mode)
                }
                return
            }
            // A key or click while a modifier is down belongs to the foreground app.
            cancelModifierHold()
        }

        guard allowStart, heldMode == nil, pendingModifier == nil, let modifier,
              modifier.isDown(in: event), !modifier.hasOtherModifier(in: event),
              let mode = bindings.first(where: { $0.value.shortcut.standaloneModifier == modifier })?.key else { return }

        let task = Task { [weak self] in
            // Let regular modifier combinations reach the foreground app before opening the microphone.
            try? await Task.sleep(for: .milliseconds(140))
            guard let self, !Task.isCancelled, self.pendingModifier?.mode == mode else { return }
            self.pendingModifier = nil
            self.heldMode = mode
            self.onPress?(mode)
        }
        pendingModifier = (mode, task)
    }

    private func cancelPendingModifier() {
        pendingModifier?.task.cancel()
        pendingModifier = nil
    }

    private func cancelModifierHold() {
        cancelPendingModifier()
        if let mode = heldMode, bindings[mode]?.shortcut.standaloneModifier != nil {
            clearHold()
            onCancel?(mode)
        }
    }

    private func receive(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
        )
        guard status == noErr, hotKeyID.signature == Self.signature else { return OSStatus(eventNotHandledErr) }

        let pressed = GetEventKind(event) == kEventHotKeyPressed
        if hotKeyID.id == Self.cancelID {
            if pressed, let mode = escapeMode { onCancel?(mode) }
        } else if let mode = bindings.first(where: { $0.value.carbon?.id == hotKeyID.id })?.key {
            if pressed {
                cancelModifierHold()
                guard heldMode == nil else { return noErr }
                heldMode = mode
                sawKeyDown = false
                sawModifiersDown = false
                // Carbon can miss a release when modifiers change before the primary key goes up.
                let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkKeyState(for: mode) }
                }
                RunLoop.main.add(timer, forMode: .common)
                releaseTimer = timer
                onPress?(mode)
            } else {
                endHold(for: mode)
            }
        }
        return noErr
    }

    private func checkKeyState(for mode: OutputMode) {
        guard heldMode == mode, let shortcut = bindings[mode]?.shortcut else { return }
        let keyDown = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(shortcut.keyCode))
        let modifiersDown = CGEventSource.flagsState(.combinedSessionState).contains(shortcut.eventFlags)
        if (sawKeyDown && !keyDown) || (sawModifiersDown && !modifiersDown) {
            endHold(for: mode)
        } else {
            sawKeyDown = sawKeyDown || keyDown
            sawModifiersDown = sawModifiersDown || modifiersDown
        }
    }

    private func clearHold() {
        heldMode = nil
        releaseTimer?.invalidate()
        releaseTimer = nil
    }

    private func endHold(for mode: OutputMode) {
        guard heldMode == mode else { return }
        clearHold()
        onRelease?(mode)
    }
}
