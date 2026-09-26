import AppKit
import ServiceManagement
import SwiftUI

/// Hosts the settings form in a plain NSWindow so it can be opened from anywhere (menu, first launch).
@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    func show(controller: AppController) {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(controller: controller)))
            window.title = "Skryba Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // Skryba is a menu-bar-only app, so it has to pull itself forward.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    let controller: AppController
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var apiKeyDraft: String
    @State private var apiKeyStatus: APIKeyStatus?

    private enum APIKeyStatus {
        case saved, failed
    }

    init(controller: AppController) {
        self.controller = controller
        _apiKeyDraft = State(initialValue: controller.settings.apiKey)
    }

    var body: some View {
        @Bindable var settings = controller.settings

        Form {
            Section("Groq") {
                HStack {
                    SecureField("API key", text: $apiKeyDraft, prompt: Text("gsk_…"))
                        .onSubmit(saveAPIKey)
                        .onChange(of: apiKeyDraft) { apiKeyStatus = nil }
                    Button("Save", action: saveAPIKey)
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines) == settings.apiKey)
                }
                switch apiKeyStatus {
                case .saved:
                    Label("Saved to your Keychain.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                case .failed:
                    Label("Couldn't save to your Keychain. The previous key is unchanged.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red).font(.callout)
                case nil:
                    EmptyView()
                }
                Link("Get a free key at console.groq.com", destination: URL(string: "https://console.groq.com/keys")!)
                    .font(.callout)
            }

            Section("Dictation") {
                Picker("Hold to dictate", selection: $settings.trigger) {
                    Text("Fn (🌐) key").tag(Settings.Trigger.fn)
                    Text("Custom shortcut").tag(Settings.Trigger.shortcut)
                }
                .onChange(of: settings.trigger) { controller.applyTrigger() }

                switch settings.trigger {
                case .fn:
                    if !controller.fnKeyFree {
                        HStack(alignment: .firstTextBaseline) {
                            Text("macOS also acts on 🌐. Set **Keyboard → Press 🌐 key to → Do Nothing**.")
                                .font(.callout)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("Open Keyboard Settings") { SystemSettings.open(.keyboard) }
                        }
                    }
                case .shortcut:
                    LabeledContent("Shortcut") {
                        ShortcutRecorder(
                            shortcut: $settings.shortcut,
                            onBegin: controller.suspendHotKey,
                            onEnd: controller.applyTrigger
                        )
                    }
                    if let error = controller.hotKeyError {
                        Text(error).foregroundStyle(.red).font(.callout)
                    }
                }
                Picker("Language", selection: $settings.language) {
                    ForEach(Settings.languages, id: \.code) { language in
                        Text(language.name).tag(language.code)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Vocabulary", text: $settings.vocabulary, axis: .vertical)
                        .lineLimit(2...4)
                    Text("Comma-separated names Whisper should spell right. Near misses like “Hrtmade” are fixed after transcription.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Permissions") {
                PermissionRow(
                    title: "Microphone",
                    detail: "To hear you while the shortcut is held.",
                    granted: controller.microphoneGranted,
                    action: controller.requestMicrophone
                )
                PermissionRow(
                    title: "Accessibility",
                    detail: "To paste the text into the app you're typing in.",
                    granted: controller.accessibilityGranted,
                    action: controller.requestAccessibility
                )
            }

            Section {
                Toggle("Play sounds", isOn: $settings.playSounds)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        try? enabled ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
            } header: {
                Text("General")
            } footer: {
                HeartmadeCredit()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension SettingsView {
    private func saveAPIKey() {
        apiKeyStatus = controller.settings.saveAPIKey(apiKeyDraft) ? .saved : .failed
    }
}

private struct HeartmadeCredit: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("Skryba \(version) · Vibe-coded by **Heartmade**")
            Link("heartmade.pl", destination: Heartmade.url)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant…", action: action)
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}
