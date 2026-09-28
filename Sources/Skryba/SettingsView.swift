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
    @State private var apiKeyStatus: CredentialStatus?
    @State private var cloudflareTokenDraft: String
    @State private var cloudflareTokenStatus: CredentialStatus?

    enum CredentialStatus {
        case saved, failed
    }

    init(controller: AppController) {
        self.controller = controller
        _apiKeyDraft = State(initialValue: controller.settings.apiKey)
        _cloudflareTokenDraft = State(initialValue: controller.settings.cloudflareToken)
    }

    private enum Tab: String, CaseIterable {
        case general = "General"
        case dictation = "Dictation"
        case offline = "Offline"
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
                case .offline: offlineTab
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
            Section("Transcription") {
                Picker("Provider", selection: $settings.provider) {
                    ForEach(Settings.TranscriptionProvider.allCases) { Text($0.displayName).tag($0) }
                }
                switch settings.provider {
                case .groq:
                    groqKeyField
                case .cloudflare:
                    TextField("Account ID", text: $settings.cloudflareAccountID, prompt: Text("32 hex characters"))
                    CredentialField(
                        title: "API token", prompt: "Workers AI token", draft: $cloudflareTokenDraft,
                        saved: settings.cloudflareToken, status: $cloudflareTokenStatus, save: saveCloudflareToken
                    )
                    FootnoteText("""
                        Create a token with the Workers AI permission. Cloudflare runs the same Whisper \
                        model; audio goes to your Cloudflare account instead of Groq.
                        """)
                    Link("Workers AI: get started", destination: URL(string: "https://developers.cloudflare.com/workers-ai/get-started/rest-api/")!)
                        .font(.callout)
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
        return Form {
            Section {
                Toggle("Remove hesitations and apply replacements", isOn: $settings.cleanupEnabled)
                if settings.cleanupEnabled, settings.apiKey.isEmpty {
                    // Cleanup always uses Groq, even when Cloudflare transcribes.
                    groqKeyField
                }
            } footer: {
                FootnoteText("""
                    A Groq language model removes hesitations like “yyy” and “eee”, and applies your \
                    replacements. It changes nothing else; if it does, the plain transcript is pasted. It's a \
                    second request per dictation, so it's a little slower and costs a little: roughly \
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
                    TextEditor(text: $settings.replacements)
                        .font(.callout.monospaced())
                        .frame(height: 150)
                        .scrollDisabled(false) // the form doesn't scroll, but a long list must
                        .scrollContentBackground(.hidden)
                } header: {
                    Text("Replacements")
                } footer: {
                    FootnoteText("""
                        One per line, as you say it → as it should be written, e.g. “claude md → CLAUDE.md” or \
                        “pawel małpa heartmade pl → pawel@heartmade.pl”. Close variants (“klod md”) are caught too.
                        """)
                }
            }
        }
    }

    private var offlineTab: some View {
        @Bindable var settings = controller.settings
        return Form {
            Section {
                FootnoteText("""
                    When a take can't be transcribed (you're offline, the provider fails, or you cancel), \
                    Skryba keeps the recording. Transcribe or delete it from the menu. Saved recordings \
                    stay private on this Mac, aren't backed up, and are deleted after 7 days.
                    """)
            } header: {
                Text("Saved recordings")
            }

            Section {
                Toggle("Transcribe on this Mac when the cloud can't be reached", isOn: $settings.localWhisperEnabled)
                if settings.localWhisperEnabled {
                    TextField("whisper-cli", text: $settings.whisperExecutablePath, prompt: Text(LocalWhisper.defaultExecutablePaths[0]))
                    LabeledContent("Model") {
                        HStack {
                            TextField("Model", text: $settings.whisperModelPath, prompt: Text("~/models/ggml-large-v3-turbo.bin"))
                                .labelsHidden()
                            Button("Choose…") { chooseModel() }
                        }
                    }
                    if let problem = settings.localWhisper.setupProblem {
                        Label(problem.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout)
                    } else {
                        Label("Ready. Audio stays on this Mac.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.callout)
                    }
                }
            } header: {
                Text("Local Whisper (optional)")
            } footer: {
                FootnoteText("""
                    Install whisper.cpp (brew install whisper-cpp) and download a multilingual model, \
                    e.g. ggml-large-v3-turbo.bin (1.6 GB, best for Polish) or ggml-small.bin (0.5 GB, \
                    faster). Skryba uses it only when the cloud is offline or fails; it's slower than Groq.
                    """)
            }
            if settings.localWhisperEnabled {
                Link("whisper.cpp models on Hugging Face", destination: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/tree/main")!)
                    .font(.callout)
            }
        }
    }

    private var groqKeyField: some View {
        Group {
            CredentialField(
                title: "Groq API key", prompt: "gsk_…", draft: $apiKeyDraft,
                saved: controller.settings.apiKey, status: $apiKeyStatus, save: saveAPIKey
            )
            Link("Get a free key at console.groq.com", destination: URL(string: "https://console.groq.com/keys")!)
                .font(.callout)
        }
    }
}

extension SettingsView {
    private func saveAPIKey() {
        apiKeyStatus = controller.settings.saveAPIKey(apiKeyDraft) ? .saved : .failed
    }

    private func saveCloudflareToken() {
        cloudflareTokenStatus = controller.settings.saveCloudflareToken(cloudflareTokenDraft) ? .saved : .failed
    }

    private func chooseModel() {
        let panel = NSOpenPanel()
        panel.message = "Choose a whisper.cpp model (ggml-….bin)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            controller.settings.whisperModelPath = url.path
        }
    }
}

/// A secret with an explicit Save: it goes to the keychain only when the user means it.
private struct CredentialField: View {
    let title: String
    let prompt: String
    @Binding var draft: String
    let saved: String
    @Binding var status: SettingsView.CredentialStatus?
    let save: () -> Void

    var body: some View {
        HStack {
            SecureField(title, text: $draft, prompt: Text(prompt))
                .onSubmit(save)
                .onChange(of: draft) { status = nil }
            Button("Save", action: save)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines) == saved)
        }
        switch status {
        case .saved:
            Label("Saved to your Keychain.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout)
        case .failed:
            Label("Couldn't save to your Keychain. The previous value is unchanged.", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red).font(.callout)
        case nil:
            EmptyView()
        }
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
