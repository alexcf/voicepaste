// Settings window (SwiftUI) — edits the same ~/.config/voicepaste/config.json.

import SwiftUI
import Speech

final class SettingsModel: ObservableObject {
    @Published var engine: String
    @Published var url: String
    @Published var key: String
    @Published var model: String
    @Published var language: String
    @Published var command: String
    @Published var appleLocale: String          // "" = system default
    @Published var silenceSeconds: Double
    @Published var noSpeechTimeout: Double
    @Published var speechMarginDb: Double
    @Published var restoreClipboard: Bool
    @Published var debugLevels: Bool

    init(_ c: Config) {
        engine = c.useApple ? "apple" : c.useCommand ? "command" : "server"
        command = c.command ?? ""
        url = c.url; key = c.key; model = c.model
        language = c.language ?? ""
        appleLocale = c.appleLocale ?? ""
        silenceSeconds = c.silenceSeconds ?? 1.5
        noSpeechTimeout = c.noSpeechTimeout ?? 8
        speechMarginDb = c.speechMarginDb ?? 14
        restoreClipboard = c.restoreClipboard ?? false
        debugLevels = c.debugLevels ?? false
    }

    func applied(to base: Config) -> Config {
        var c = base
        c.engine = engine
        c.url = url.trimmingCharacters(in: .whitespaces)
        c.key = key.trimmingCharacters(in: .whitespaces)
        c.model = model.trimmingCharacters(in: .whitespaces)
        c.language = language.isEmpty ? nil : language
        let cmd = command.trimmingCharacters(in: .whitespacesAndNewlines)
        c.command = cmd.isEmpty ? nil : cmd
        c.appleLocale = appleLocale.isEmpty ? nil : appleLocale
        c.silenceSeconds = (silenceSeconds * 10).rounded() / 10
        c.noSpeechTimeout = noSpeechTimeout
        c.speechMarginDb = speechMarginDb.rounded()
        c.restoreClipboard = restoreClipboard
        c.debugLevels = debugLevels
        return c
    }
}

struct SettingsView: View {
    @ObservedObject var m: SettingsModel
    var onSave: () -> Void
    var onCancel: () -> Void
    var onOpenJSON: () -> Void

    private let locales: [(id: String, name: String)] = SFSpeechRecognizer.supportedLocales()
        .map { ($0.identifier, Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier) }
        .sorted { $0.name < $1.name }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Transcription") {
                    Picker("Engine", selection: $m.engine) {
                        Text("Apple").tag("apple")
                        Text("API").tag("server")
                        Text("Local command").tag("command")
                    }
                    .pickerStyle(.segmented)

                    if m.engine == "server" {
                        LabeledContent("Preset") {
                            HStack {
                                ForEach(Self.apiPresets, id: \.name) { p in
                                    Button(p.name) { m.url = p.url; m.model = p.model }
                                }
                            }
                        }
                        TextField("Endpoint URL", text: $m.url)
                        SecureField("API key", text: $m.key, prompt: Text("not needed for Ollama"))
                        TextField("Model", text: $m.model)
                        TextField("Language", text: $m.language, prompt: Text("auto-detect (e.g. en)"))
                        Text("Any OpenAI-compatible /v1/audio/transcriptions endpoint. Ollama needs an audio-capable model, e.g. `ollama pull lfm3-audio`.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if m.engine == "command" {
                        LabeledContent("Preset") {
                            HStack {
                                ForEach(Self.commandPresets, id: \.name) { p in
                                    Button(p.name) { m.command = p.command }
                                }
                            }
                        }
                        TextField("Command", text: $m.command, axis: .vertical)
                            .lineLimit(2...4)
                            .font(.system(.body, design: .monospaced))
                        Text("Runs in your login shell. `{file}` is replaced with the recorded 16 kHz WAV; the command must print the transcript to stdout. whisper.cpp: `brew install whisper.cpp`, then download a ggml model to the path above.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Language", selection: $m.appleLocale) {
                            Text("System default").tag("")
                            Divider()
                            ForEach(locales, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        Text("Runs on-device where the language supports it. Asks for Speech Recognition permission the first time.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    sliderRow("Stop after a pause of", value: $m.silenceSeconds, range: 0.5...4, step: 0.1,
                              label: String(format: "%.1f s", m.silenceSeconds))
                    sliderRow("Give up if silent for", value: $m.noSpeechTimeout, range: 3...30, step: 1,
                              label: "\(Int(m.noSpeechTimeout)) s")
                    sliderRow("Speech threshold", value: $m.speechMarginDb, range: 6...25, step: 1,
                              label: "\(Int(m.speechMarginDb)) dB")
                } header: {
                    Text("Auto-stop")
                } footer: {
                    Text("Threshold is how far above background noise counts as talking. Lower it if quiet speech is missed; raise it in noisy rooms.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Behaviour") {
                    Toggle("Restore previous clipboard after pasting", isOn: $m.restoreClipboard)
                    Toggle("Log mic levels to stdout (debugging)", isOn: $m.debugLevels)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Open JSON file…", action: onOpenJSON).buttonStyle(.link)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save", action: onSave).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520, height: 680)
    }

    static let apiPresets: [(name: String, url: String, model: String)] = [
        ("OpenAI", "https://api.openai.com/v1/audio/transcriptions", "gpt-4o-mini-transcribe"),
        ("Groq", "https://api.groq.com/openai/v1/audio/transcriptions", "whisper-large-v3-turbo"),
        ("Ollama", "http://localhost:11434/v1/audio/transcriptions", "lfm3-audio"),
    ]

    static let commandPresets: [(name: String, command: String)] = [
        ("whisper.cpp", "whisper-cli -m ~/.cache/whisper/ggml-base.en.bin -nt -np -f {file}"),
        ("openai-whisper", "whisper {file} --model base --output_format txt --output_dir /tmp/voicepaste-whisper >/dev/null 2>&1 && cat /tmp/voicepaste-whisper/voicepaste.txt"),
    ]

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           step: Double, label: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step).frame(width: 170)
                Text(label).monospacedDigit().frame(width: 48, alignment: .trailing)
            }
        }
    }
}
