import AppKit
import SwiftUI

enum RecorderHUDPhase {
    case opening
    case recording
    case closing
}

struct StatusNotice {
    let title: String
    let detail: String
    let symbol: String
    var badgeText: String?
    var tint: Color = .accentColor
    var isWorking = false
    var recorderPhase: RecorderHUDPhase?
}

@MainActor
final class StatusHUD {
    private static let size = NSSize(width: 364, height: 198)
    private let state = State()
    private lazy var panel: NSPanel = {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: NoticeView(state: state))
        return panel
    }()
    private var hideTask: Task<Void, Never>?
    private var closingTask: Task<Void, Never>?

    func show(_ notice: StatusNotice, duration: Duration? = nil) {
        hideTask?.cancel()
        closingTask?.cancel()
        closingTask = nil
        if notice.recorderPhase != state.notice?.recorderPhase { state.phaseStartedAt = .now }
        if notice.recorderPhase != nil, state.openedAt == nil {
            state.openedAt = .now
            state.wavefield = RecordingWavefield()
        } else if notice.recorderPhase == nil, state.openedAt != nil {
            state.openedAt = nil
            state.wavefield = RecordingWavefield()
        }
        state.notice = notice
        if !panel.isVisible {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 18, y: frame.minY + 14))
            }
            panel.orderFrontRegardless()
        }
        if let duration {
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled else { return }
                self?.hide()
            }
        }
        if notice.recorderPhase == .closing {
            closingTask = Task { [weak self] in
                try? await Task.sleep(for: ToiletRecordingView.closingDuration)
                guard !Task.isCancelled else { return }
                var progress = notice
                progress.recorderPhase = nil
                progress.isWorking = true
                self?.show(progress)
            }
        }
    }

    func updateWaveform(_ waveform: RecordingWaveform) {
        guard state.notice?.recorderPhase == .recording, panel.isVisible else { return }
        state.wavefield.receive(waveform)
    }

    private func hide() {
        hideTask?.cancel()
        hideTask = nil
        closingTask?.cancel()
        closingTask = nil
        panel.orderOut(nil)
    }

    @MainActor
    private final class State: ObservableObject {
        @Published var wavefield = RecordingWavefield()
        var openedAt: Date?
        var phaseStartedAt: Date = .now
        @Published var notice: StatusNotice?
    }

    private struct NoticeView: View {
        @ObservedObject var state: State

        var body: some View {
            Group {
                if let notice = state.notice {
                    if notice.recorderPhase != nil, let openedAt = state.openedAt {
                        ToiletRecordingView(notice: notice, field: state.wavefield, openedAt: openedAt,
                                            phaseStartedAt: state.phaseStartedAt)
                    } else {
                        messageCard(notice)
                    }
                }
            }
            .padding(.trailing, 10)
            .padding(.bottom, 10)
            .frame(width: StatusHUD.size.width, height: StatusHUD.size.height, alignment: .bottomTrailing)
        }

        private func messageCard(_ notice: StatusNotice) -> some View {
            HStack(spacing: 10) {
                Group {
                    if notice.isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: notice.symbol)
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(notice.tint)
                    }
                }
                .frame(width: 28, height: 28)
                .background(notice.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7.5, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title).font(.system(size: 12.5, weight: .semibold))
                    if !notice.detail.isEmpty {
                        Text(notice.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: Self.panelWidth, alignment: .leading)
            .background {
                FrostedBackground().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }

        private static let panelWidth: CGFloat = 310
    }

    private struct FrostedBackground: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .popover
            view.blendingMode = .behindWindow
            view.state = .active
            return view
        }

        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
    }
}
