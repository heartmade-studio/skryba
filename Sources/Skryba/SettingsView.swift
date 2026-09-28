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
    @State private var cloudflareTokenDraft: String
    @State private var cloudflareTokenStatus: APIKeyStatus?
    @State private var setupPromptCopied = false

    private enum APIKeyStatus {
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
        case transcription = "Transcription"
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
                case .transcription: transcriptionTab
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
        return Form {
            Section {
                Toggle("Remove hesitations and apply replacements", isOn: $settings.cleanupEnabled)
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

    private var transcriptionTab: some View {
        @Bindable var settings = controller.settings
        return Form {
            Section("Transcription provider") {
                Picker("Primary provider", selection: $settings.primaryTranscriptionProvider) {
                    ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Text(settings.providerSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if settings.primaryTranscriptionProvider == .groq {
                    Toggle("Use local Whisper if Groq fails", isOn: $settings.localFallbackEnabled)
                } else {
                    Toggle("Allow cloud fallback if local Whisper fails", isOn: $settings.allowCloudFallbackWhenLocal)
                    FootnoteText(settings.allowCloudFallbackWhenLocal
                        ? "If enabled, audio may be sent to Groq and then Cloudflare after local recognition fails."
                        : "Local-only mode: audio stays on this Mac, even when local transcription fails.")
                }
            }

            Section("Local Whisper (whisper.cpp)") {
                TextField("whisper-cli path", text: $settings.whisperCLIPath)
                    .textFieldStyle(.roundedBorder)
                TextField("ffmpeg path", text: $settings.ffmpegPath)
                    .textFieldStyle(.roundedBorder)
                TextField("Multilingual model path", text: $settings.whisperModelPath)
                    .textFieldStyle(.roundedBorder)
                Label(settings.localWhisperStatus, systemImage: settings.localWhisperReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(settings.localWhisperReady ? .green : .orange)

                DisclosureGroup("Set up local transcription…") {
                    VStack(alignment: .leading, spacing: 8) {
                        FootnoteText("Install whisper.cpp and ffmpeg, then download the multilingual ggml-small-q5_1.bin model. Set the executable and model paths above; try a short sample in your selected language or Auto-detect. Audio stays on your Mac when local-only mode is selected.")
                        HStack {
                            Link("whisper.cpp source", destination: URL(string: "https://github.com/ggml-org/whisper.cpp")!)
                            Link("Official model files", destination: URL(string: "https://huggingface.co/ggerganov/whisper.cpp")!)
                        }
                        FootnoteText("Expected model SHA-256: ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb")
                        Button(setupPromptCopied ? "Setup prompt copied" : "Copy setup prompt") {
                            copyLocalSetupPrompt()
                        }
                    }
                    .padding(.top, 6)
                }
            }

            Section("Cloudflare Workers AI fallback") {
                Toggle("Enable Cloudflare after earlier providers fail", isOn: $settings.cloudflareFallbackEnabled)
                TextField("Account ID", text: $settings.cloudflareAccountID)
                    .textFieldStyle(.roundedBorder)
                FootnoteText("Cloudflare Account IDs contain 32 hexadecimal characters.")
                HStack {
                    SecureField("API token", text: $cloudflareTokenDraft, prompt: Text("Stored in Keychain"))
                        .onChange(of: cloudflareTokenDraft) { cloudflareTokenStatus = nil }
                    Button("Save token", action: saveCloudflareToken)
                        .disabled(cloudflareTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines) == settings.cloudflareToken)
                }
                switch cloudflareTokenStatus {
                case .saved:
                    Label("Saved to your Keychain.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.callout)
                case .failed:
                    Label("Couldn't save to your Keychain. The previous token is unchanged.", systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red).font(.callout)
                case nil:
                    EmptyView()
                }
                Link("Cloudflare Workers AI setup", destination: URL(string: "https://developers.cloudflare.com/workers-ai/get-started/rest-api/")!)
                    .font(.callout)
                FootnoteText("Audio is sent to your Cloudflare account when this fallback runs. The current Workers Free allowance is 10,000 Neurons/day; this model uses 46.63 Neurons/audio minute (about 214 minutes at the full allowance). This is not guaranteed availability. Workers Paid usage above the daily free allocation is billed. Check Cloudflare pricing and your dashboard.")
                Link("Workers AI pricing", destination: URL(string: "https://developers.cloudflare.com/workers-ai/platform/pricing/")!)
                    .font(.callout)
            }
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

    private func copyLocalSetupPrompt() {
        let prompt = """
        Help me set up local, offline speech transcription for Skryba on this Mac.

        1. Detect the operating system and CPU architecture before choosing installation steps.
        2. Install whisper.cpp (https://github.com/ggml-org/whisper.cpp) and ffmpeg from official sources.
        3. Download the multilingual ggml-small-q5_1.bin model from https://huggingface.co/ggerganov/whisper.cpp.
        4. Verify the model SHA-256 is exactly:
           ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb
        5. Tell me the full paths to whisper-cli, ffmpeg, and the model, then show me how to enter and verify them in Skryba → Settings → Transcription.
        6. Test with a short sample spoken in Skryba's selected language (or Auto-detect), keeping the recording on this Mac.
        7. Explain whether Skryba needs restarting and how to restart it safely.

        Do not ask for API keys or passwords. Do not upload, transmit, or share any recording or transcript. Do not use unofficial model/tool downloads. Explain any privileged or destructive step before running it.
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
        setupPromptCopied = true
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
