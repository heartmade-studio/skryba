import AppKit
import Observation
import SwiftUI

/// A small pill near the bottom of the screen showing what Skryba is doing.
///
/// It is a non-activating panel: it never takes focus, so ⌘V still lands in the app you were typing in.
@MainActor
final class RecordingHUD {
    enum Style: Equatable {
        case recording, handsFree, transcribing, cleaningUp
        case tryingProvider(String)
        case error(String)
    }

    @Observable
    final class Model {
        var style: Style = .recording
    }

    private let model = Model()
    private var panel: NSPanel?

    func show(_ style: Style) {
        model.style = style
        let panel = panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
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
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
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
        HStack(spacing: 8) {
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
            case .transcribing:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Transcribing…")
            case .cleaningUp:
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Cleaning up…")
            case .tryingProvider(let message):
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text(message)
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .frame(maxWidth: 320, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
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
}
