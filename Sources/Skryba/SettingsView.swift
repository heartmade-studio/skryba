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

    private enum Tab: String, CaseIterable {
        case general = "General"
        case dictation = "Dictation"
        case cleanup = "AI Cleanup"
    }

    @AppStorage("settingsTab") private var tab = Tab.general

    /// Tabs keep each page short enough for a laptop screen; the window resizes to the open tab.
    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.top, 16)

            Group {
                switch tab {
                case .general: generalTab
                case .dictation: dictationTab
                case .cleanup: cleanupTab
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            HeartmadeCredit()
                .padding(.bottom, 16)
        }
        .frame(width: 500)
    }

    private var generalTab: some View {
        @Bindable var settings = controller.settings
        return Form {
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
            }
        }
    }

    private var dictationTab: some View {
        @Bindable var settings = controller.settings
        return Form {
            Section {
                Picker("Hold to dictate", selection: $settings.trigger) {
                    Text("Fn (🌐) key").tag(Settings.Trigger.fn)
                    Text("Custom shortcut").tag(Settings.Trigger.shortcut)
                }
                .onChange(of: settings.trigger) { controller.applyTrigger() }

                switch settings.trigger {
                case .fn:
                    Text("Hold Fn to talk. Tap it three times for hands-free mode, then tap once to stop.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !controller.fnKeyFree {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("macOS also acts on 🌐. Set **Keyboard → Press 🌐 key to → Do Nothing**.")
                                .font(.callout)
                                .foregroundStyle(.orange)
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
            }

            Section {
                TextField("Vocabulary", text: $settings.vocabulary, prompt: Text("Heartmade, Groq, …"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(1...4)
            } header: {
                Text("Vocabulary")
            } footer: {
                FootnoteText("Comma-separated names Whisper should spell right. Near misses like “Hrtmade” are fixed after transcription.")
            }
        }
    }

    private var cleanupTab: some View {
        @Bindable var settings = controller.settings
        let defaultInstructions = TextCleanup.defaultInstructions(language: settings.language)
        return Form {
            Section {
                Toggle("Clean up punctuation and style", isOn: $settings.cleanupEnabled)
            } footer: {
                FootnoteText("""
                    A Groq language model adds punctuation, fixes misheard words and removes fillers like “yyy”. \
                    It's a second request per dictation, so it's a little slower and costs a little: roughly \
                    $0.20 per 1,000 dictations with GPT-OSS, $0.80 with Qwen.
                    """)
            }

            if settings.cleanupEnabled {
                Section {
                    Picker("Model", selection: $settings.cleanupModel) {
                        ForEach(TextCleanup.Model.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                }

                Section {
                    TextEditor(text: $settings.cleanupInstructions)
                        .font(.callout)
                        .frame(height: 150)
                        .scrollDisabled(false) // the form doesn't scroll, but long instructions must
                        .scrollContentBackground(.hidden)
                } header: {
                    HStack {
                        Text("Instructions")
                        Spacer()
                        Button("Reset to default") { settings.cleanupInstructions = defaultInstructions }
                            .disabled(settings.cleanupInstructions == defaultInstructions)
                            .controlSize(.small)
                    }
                } footer: {
                    FootnoteText("Your vocabulary is added to these instructions automatically.")
                }
            }
        }
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
        HStack(spacing: 4) {
            Text("Skryba \(version) · Vibe-coded by **Heartmade** ·")
                .foregroundStyle(.secondary)
            Link("heartmade.pl", destination: Heartmade.url)
        }
        .font(.callout)
    }
}

/// Explanatory text under a settings section, aligned with the section's content.
private struct FootnoteText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
