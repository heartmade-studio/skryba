import AppKit
import Observation
import SwiftUI

/// A small pill near the bottom of the screen showing what Skryba is doing.
///
/// It is a non-activating panel: it never takes focus, so ⌘V still lands in the app you were typing in.
/// While a transcription can be cancelled it accepts clicks on its Cancel button, still without
/// activating Skryba.
@MainActor
final class RecordingHUD {
    enum Style: Equatable {
        case recording, handsFree, cleaningUp
        /// Sending to the cloud; attempts after the first mean the connection is struggling.
        case transcribing(attempt: Int)
        case transcribingLocally
        case info(String)
        case error(String)

        var isCancellable: Bool {
            switch self {
            case .transcribing, .transcribingLocally: true
            default: false
            }
        }
    }

    @Observable
    final class Model {
        var style: Style = .recording
        /// A second, smaller line, such as "Offline · will be saved".
        var note: String?
        var onCancel: () -> Void = {}
    }

    private let model = Model()
    private var panel: NSPanel?

    /// Called when the user clicks Cancel in the HUD.
    var onCancel: () -> Void {
        get { model.onCancel }
        set { model.onCancel = newValue }
    }

    private(set) var style: Style?

    func show(_ style: Style, note: String? = nil) {
        self.style = style
        model.style = style
        model.note = note
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.ignoresMouseEvents = !style.isCancellable
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        style = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = FirstClickHostingView(rootView: HUDView(model: model))
        return panel
    }

    /// Bottom-centre of the screen the mouse is on — usually the one you're working on.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame, let content = panel.contentView else { return }
        let size = content.fittingSize
        panel.setFrame(
            NSRect(x: visible.midX - size.width / 2, y: visible.minY + 28, width: size.width, height: size.height),
            display: true
        )
    }
}

private struct HUDView: View {
    let model: RecordingHUD.Model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                content
            }
            if let note = model.note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(8) // room for the shadow
        .fixedSize()
    }

    private var cancelButton: some View {
        Button("Cancel") { model.onCancel() }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(.white.opacity(0.18), in: Capsule())
    }

    @ViewBuilder private var content: some View {
        switch model.style {
        case .recording:
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
            Text("Listening…")
        case .handsFree:
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
            Text("Hands-free · tap Fn to stop")
        case .transcribing(let attempt):
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text(attempt == 1 ? "Transcribing…" : "Connection trouble · attempt \(attempt) of \(Retry.maximumAttempts)…")
            cancelButton
        case .transcribingLocally:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("Transcribing on this Mac…")
            cancelButton
        case .info(let message):
            Image(systemName: "tray.full.fill")
                .foregroundStyle(.orange)
            Text(message)
                .frame(maxWidth: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        case .cleaningUp:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("Cleaning up…")
        case .error(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .frame(maxWidth: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Lets the Cancel button work on the first click, although the panel never becomes key.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
