// VoicePaste — global hotkey → record mic → STT → clipboard → paste into frontmost app.
//
// Hotkey: ⌘⇧Space
//   • tap   = start recording; stops automatically when you stop talking
//             (or tap again to stop early)
//   • hold  = push-to-talk; release to stop (auto-stop disabled while held)
// Config: ~/.config/voicepaste/config.json

import AppKit
import AVFoundation
import Carbon
import ApplicationServices
import Speech
import SwiftUI

// MARK: - Config

struct Config: Codable {
    var url: String
    var key: String
    var model: String
    var language: String?
    var restoreClipboard: Bool?
    var silenceSeconds: Double?     // pause length that ends a recording (default 1.5)
    var noSpeechTimeout: Double?    // give up if nothing said within this (default 8)
    var speechMarginDb: Double?     // how far above the noise floor counts as speech (default 14)
    var debugLevels: Bool?          // log mic levels to Console / stdout
    var engine: String?             // "apple" (built-in), "server" (OpenAI-compatible API) or "command" (local CLI)
    var command: String?            // for "command": shell command; {file} = path to the WAV, prints text to stdout
    var appleLocale: String?        // e.g. "en-GB"; default = system language

    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/voicepaste/config.json")

    static let defaults = Config(
        url: "https://api.openai.com/v1/audio/transcriptions",
        key: "",
        model: "whisper-1",
        language: nil,
        restoreClipboard: false,
        silenceSeconds: 1.5,
        noSpeechTimeout: 8,
        speechMarginDb: 14,
        debugLevels: false,
        engine: "apple",          // works out of the box, no API key needed
        command: "whisper-cli -m ~/.cache/whisper/ggml-base.en.bin -nt -np -f {file}",
        appleLocale: nil
    )

    var useApple: Bool { engine == "apple" }
    var useCommand: Bool { engine == "command" }

    func save() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Config.path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(self) else { return }
        try? data.write(to: Config.path, options: .atomic)
        // Holds an API key — keep it private to this user.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Config.path.path)
    }

    /// Set when the config file exists but couldn't be parsed.
    static var loadError: String?

    /// Returns nil if the file exists but is unreadable (so callers don't clobber it).
    static func tryLoad() -> Config? {
        guard FileManager.default.fileExists(atPath: path.path) else { return defaults }
        guard let data = try? Data(contentsOf: path),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return nil }
        return cfg
    }

    static func load() -> Config {
        if !FileManager.default.fileExists(atPath: path.path) { defaults.save(); return defaults }
        if let cfg = tryLoad() { return cfg }
        loadError = "Couldn't parse \(path.path) — using defaults for now. The file was left untouched; fix it or re-save from Settings."
        return defaults
    }
}

// MARK: - App

enum State { case idle, recording, transcribing }

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!

    var statusItem: NSStatusItem!
    var state: State = .idle { didSet { updateIcon() } }
    var recorder: AVAudioRecorder?
    var targetApp: NSRunningApplication?
    var pressedAt: Date?
    var lastText: String?
    var config = Config.load()
    var hotKeyRef: EventHotKeyRef?

    // Voice-activity detection
    var meterTimer: Timer?
    var keyHeld = false
    var noiseFloor: Float = 0
    var heardSpeech = false
    var lastLoud = Date()
    var recordStart = Date()
    let maxDuration: TimeInterval = 300

    let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("voicepaste.wav")
    let holdThreshold: TimeInterval = 0.45

    func applicationDidFinishLaunching(_ note: Notification) {
        AppDelegate.shared = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        updateIcon()
        registerHotKey()
        if CommandLine.arguments.contains("--settings") { openSettings() }
        if let err = Config.loadError { notify(err) }

        // Ask one permission at a time — macOS stacks the dialogs and one hides the other.
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            DispatchQueue.main.async {
                if !ok { self.notify("Microphone access denied — enable it in System Settings › Privacy › Microphone") }
                self.ensureAccessibility()
            }
        }
    }

    /// Accessibility is only needed for the auto-paste (synthetic ⌘V).
    func ensureAccessibility() {
        if AXIsProcessTrusted() { return }
        // Registers the app in the Accessibility list (so the toggle exists).
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)

        let alert = NSAlert()
        alert.messageText = "VoicePaste needs Accessibility access"
        alert.informativeText = "This lets it paste the transcript into the app you're using. Turn on VoicePaste in the list that opens. (If it's already on from an older build, remove it with − and add it again.)"
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openAX() }

        // Confirm once it's granted.
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { t in
            if AXIsProcessTrusted() {
                t.invalidate()
                NSSound(named: "Glass")?.play()
            }
        }
    }

    // MARK: Menu

    func buildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "Toggle recording  (⌘⇧Space)", action: #selector(toggleFromMenu), keyEquivalent: "")
        m.addItem(withTitle: "Cancel recording", action: #selector(cancel), keyEquivalent: "")
        m.addItem(withTitle: "Paste last transcript", action: #selector(pasteLast), keyEquivalent: "")
        m.addItem(.separator())
        let apple = m.addItem(withTitle: "Transcribe with: Apple (built-in)", action: #selector(useAppleEngine), keyEquivalent: "")
        apple.state = config.useApple ? .on : .off
        let server = m.addItem(withTitle: "Transcribe with: API", action: #selector(useServerEngine), keyEquivalent: "")
        server.state = (!config.useApple && !config.useCommand) ? .on : .off
        let cmd = m.addItem(withTitle: "Transcribe with: local command", action: #selector(useCommandEngine), keyEquivalent: "")
        cmd.state = config.useCommand ? .on : .off
        m.addItem(.separator())
        m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        m.addItem(withTitle: "Accessibility settings…", action: #selector(openAX), keyEquivalent: "")
        m.addItem(.separator())
        m.addItem(withTitle: "Quit VoicePaste", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in m.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
        statusItem.menu = m
    }

    func updateIcon() {
        DispatchQueue.main.async {
            let (name, tint): (String, NSColor?) = {
                switch self.state {
                case .idle: return ("mic", nil)
                case .recording: return ("mic.fill", .systemRed)
                case .transcribing: return ("ellipsis.circle", .systemOrange)
                }
            }()
            let img = NSImage(systemSymbolName: name, accessibilityDescription: "VoicePaste")
            img?.isTemplate = (tint == nil)
            self.statusItem.button?.image = img
            self.statusItem.button?.contentTintColor = tint
        }
    }

    @objc func toggleFromMenu() {
        // From the menu, the "target" is whatever was frontmost before the menu opened.
        if state == .idle { start() } else if state == .recording { stop() }
    }
    @objc func openConfig() { NSWorkspace.shared.open(Config.path) }
    @objc func useServerEngine() { config.engine = "server"; config.save(); buildMenu() }
    @objc func useCommandEngine() { config.engine = "command"; config.save(); buildMenu() }
    @objc func useAppleEngine() {
        var c = config; c.engine = "apple"
        commit(c)
    }

    /// Saves a new config; switching to Apple first makes sure Speech Recognition is allowed.
    func commit(_ c: Config, then done: (() -> Void)? = nil) {
        let apply = {
            self.config = c; c.save(); self.buildMenu(); done?()
        }
        guard c.useApple, SFSpeechRecognizer.authorizationStatus() != .authorized else { apply(); return }
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                guard status == .authorized else {
                    self.notify("Speech Recognition access denied — enable it in System Settings › Privacy & Security › Speech Recognition")
                    return
                }
                apply()
            }
        }
    }

    // MARK: Settings window

    var settingsWindow: NSWindow?

    @objc func openSettings() {
        if let fresh = Config.tryLoad() { config = fresh; buildMenu() }
        let model = SettingsModel(config)
        let view = SettingsView(
            m: model,
            onSave: { [weak self] in
                guard let self = self else { return }
                self.commit(model.applied(to: self.config)) { self.settingsWindow?.close() }
            },
            onCancel: { [weak self] in self?.settingsWindow?.close() },
            onOpenJSON: { [weak self] in self?.settingsWindow?.close(); self?.openConfig() }
        )
        let win = settingsWindow ?? {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "VoicePaste Settings"
            w.isReleasedWhenClosed = false
            return w
        }()
        win.contentViewController = NSHostingController(rootView: view)
        win.center()
        settingsWindow = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }
    @objc func openAX() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func pasteLast() {
        guard let t = lastText else { NSSound.beep(); return }
        targetApp = NSWorkspace.shared.frontmostApplication
        deliver(t)
    }

    // MARK: Hotkey (Carbon — no Accessibility permission needed for this part)

    func registerHotKey() {
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            let kind = GetEventKind(event)
            DispatchQueue.main.async {
                if kind == UInt32(kEventHotKeyPressed) { AppDelegate.shared.hotKeyDown() }
                else { AppDelegate.shared.hotKeyUp() }
            }
            return noErr
        }, 2, &specs, nil, nil)

        let id = EventHotKeyID(signature: OSType(0x56505354) /* 'VPST' */, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { notify("Couldn't register ⌘⇧Space (already used by another app?)") }
    }

    func hotKeyDown() {
        keyHeld = true
        switch state {
        case .idle: pressedAt = Date(); start()
        case .recording: pressedAt = nil; stop()
        case .transcribing: NSSound.beep()
        }
    }

    func hotKeyUp() {
        keyHeld = false
        // Held long enough → push-to-talk: stop on release.
        if state == .recording, let t = pressedAt, Date().timeIntervalSince(t) >= holdThreshold {
            stop()
        }
        pressedAt = nil
    }

    // MARK: Recording

    func start() {
        targetApp = NSWorkspace.shared.frontmostApplication
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            try? FileManager.default.removeItem(at: wavURL)
            let r = try AVAudioRecorder(url: wavURL, settings: settings)
            guard r.record() else { throw NSError(domain: "VoicePaste", code: 1) }
            r.isMeteringEnabled = true
            recorder = r
            state = .recording
            NSSound(named: "Tink")?.play()
            startVAD()
        } catch {
            notify("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    @objc func cancel() {
        stopVAD()
        recorder?.stop(); recorder = nil
        state = .idle
    }

    func stop() {
        guard let r = recorder else { return }
        stopVAD()
        let duration = r.currentTime
        r.stop(); recorder = nil
        NSSound(named: "Pop")?.play()
        if duration < 0.3 { state = .idle; return }   // accidental tap
        state = .transcribing
        transcribe()
    }

    // MARK: Voice-activity detection (auto-stop when you stop talking)
    //
    // Polls the recorder's level every 50 ms. The noise floor adapts to the room:
    // it drops instantly to quieter readings and creeps up slowly, so steady
    // background noise (fans, AC) gets absorbed but speech doesn't. Once speech
    // has been heard, `silenceSeconds` of near-floor level ends the recording.

    func startVAD() {
        heardSpeech = false
        noiseFloor = 0
        recordStart = Date()
        lastLoud = Date()
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.vadTick() }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    func stopVAD() { meterTimer?.invalidate(); meterTimer = nil }

    func vadTick() {
        guard let r = recorder, state == .recording else { return }
        r.updateMeters()
        let level = r.averagePower(forChannel: 0)          // dBFS, -160…0
        let elapsed = Date().timeIntervalSince(recordStart)

        // First ~150 ms: seed the floor (also skips the start-sound bleed).
        if elapsed < 0.15 { noiseFloor = noiseFloor == 0 ? level : min(noiseFloor, level); return }
        if level < noiseFloor { noiseFloor = level } else { noiseFloor += 0.01 }
        noiseFloor = max(noiseFloor, -75)                   // digital-silence guard

        let margin = Float(config.speechMarginDb ?? 14)
        let speaking = level > noiseFloor + margin
        let quiet = level < noiseFloor + margin * 0.6      // hysteresis
        if speaking { heardSpeech = true; lastLoud = Date() }
        else if !quiet { lastLoud = Date() }               // in-between: don't count as silence

        if config.debugLevels ?? false {
            print(String(format: "level %6.1f  floor %6.1f  %@", level, noiseFloor, speaking ? "SPEECH" : quiet ? "quiet" : "-"))
            fflush(stdout)
        }

        if keyHeld { return }                               // push-to-talk: user decides
        if elapsed > maxDuration { stop(); return }
        if !heardSpeech {
            if elapsed > (config.noSpeechTimeout ?? 8) { cancel(); NSSound(named: "Basso")?.play() }
            return
        }
        if Date().timeIntervalSince(lastLoud) >= (config.silenceSeconds ?? 1.5) { stop() }
    }

    // MARK: STT

    func transcribe() {
        if config.useApple { transcribeApple() }
        else if config.useCommand { transcribeCommand() }
        else { transcribeServer() }
    }

    func finish(_ raw: String?, error: String? = nil) {
        state = .idle
        if let error = error { notify(error); return }
        let text = Self.clean(raw ?? "")
        if text.isEmpty { NSSound(named: "Basso")?.play(); return }
        lastText = text
        deliver(text)
    }

    // Built-in macOS speech recognition (on-device when the language supports it).
    var appleTask: SFSpeechRecognitionTask?

    func transcribeApple() {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: break
        case .notDetermined:
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    if status == .authorized { self.transcribeApple() }
                    else { self.finish(nil, error: "Speech Recognition access denied — enable it in System Settings › Privacy & Security › Speech Recognition") }
                }
            }
            return
        default:
            finish(nil, error: "Speech Recognition access is off — enable it in System Settings › Privacy & Security › Speech Recognition, or switch to a server in Settings.")
            return
        }
        let locale = config.appleLocale.map { Locale(identifier: $0) } ?? Locale.current
        guard let rec = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            finish(nil, error: "Apple speech recognition isn't available for \(locale.identifier)"); return
        }
        guard rec.isAvailable else { finish(nil, error: "Apple speech recognition is currently unavailable"); return }
        let req = SFSpeechURLRecognitionRequest(url: wavURL)
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        var done = false
        appleTask = rec.recognitionTask(with: req) { result, error in
            DispatchQueue.main.async {
                guard !done else { return }
                if let result = result, result.isFinal {
                    done = true; self.appleTask = nil
                    self.finish(result.bestTranscription.formattedString)
                } else if let error = error {
                    done = true; self.appleTask = nil
                    // "No speech detected" comes back as an error — treat as empty.
                    let ns = error as NSError
                    if ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110 { self.finish("") }
                    else { self.finish(nil, error: "Apple STT failed: \(error.localizedDescription)") }
                }
            }
        }
    }

    func transcribeServer() {
        guard let audio = try? Data(contentsOf: wavURL), let url = URL(string: config.url) else {
            state = .idle; return
        }
        let boundary = "vp-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", config.model)
        field("response_format", "json")
        if let lang = config.language, !lang.isEmpty { field("language", lang) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"rec.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audio)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        let key = config.key.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { data, resp, err in
            DispatchQueue.main.async {
                if let err = err { self.finish(nil, error: "STT failed: \(err.localizedDescription)"); return }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    let snippet = data.flatMap { String(data: $0, encoding: .utf8) }?.prefix(200) ?? ""
                    let hint = (code == 401 || code == 403) ? "\n\nCheck the API key in Settings." : ""
                    self.finish(nil, error: "STT HTTP \(code): \(snippet)\(hint)"); return
                }
                self.finish((json["text"] as? String) ?? (json["transcript"] as? String) ?? "")
            }
        }.resume()
    }

    // Local command (whisper.cpp, openai-whisper, anything that prints text to stdout).
    func transcribeCommand() {
        let template = (config.command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { finish(nil, error: "No local command set — add one in Settings."); return }
        let quoted = "'" + wavURL.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let cmd = template.contains("{file}") ? template.replacingOccurrences(of: "{file}", with: quoted)
                                              : template + " " + quoted

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", cmd]                      // login shell → user's PATH
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        DispatchQueue.global(qos: .userInitiated).async {
            do { try p.run() } catch {
                DispatchQueue.main.async { self.finish(nil, error: "Couldn't run command: \(error.localizedDescription)") }
                return
            }
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: killer)
            // Drain both pipes concurrently so a chatty stderr can't deadlock the process.
            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            p.waitUntilExit()
            killer.cancel()
            let stdout = String(decoding: outData, as: UTF8.self)
            let stderr = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if p.terminationStatus != 0 {
                    self.finish(nil, error: "Command failed (exit \(p.terminationStatus)):\n\(stderr.suffix(400))")
                } else {
                    // Join per-segment lines into one paragraph.
                    let text = stdout.split(whereSeparator: \.isNewline)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    self.finish(text)
                }
            }
        }
    }

    /// Qwen-style ASR sometimes returns "language English<asr_text>actual words".
    static func clean(_ s: String) -> String {
        var t = s
        if let r = t.range(of: "<asr_text>") { t = String(t[r.upperBound...]) }
        // Whisper non-speech markers, e.g. "[BLANK_AUDIO]", "[MUSIC]".
        t = t.replacingOccurrences(of: #"\[[A-Z_ ]+\]"#, with: "", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Clipboard + paste

    func deliver(_ text: String) {
        let pb = NSPasteboard.general
        let previous: [NSPasteboardItem]? = (config.restoreClipboard ?? false) ? Self.snapshot(pb) : nil
        pb.clearContents()
        pb.setString(text, forType: .string)
        let ourChange = pb.changeCount

        guard AXIsProcessTrusted() else {
            notify("Copied to clipboard. Grant Accessibility access to auto-paste.")
            return
        }
        if let app = targetApp, app != NSRunningApplication.current { app.activate() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            Self.sendCmdV()
            if let prev = previous, !prev.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    // Don't clobber something the user copied in the meantime.
                    guard pb.changeCount == ourChange else { return }
                    pb.clearContents(); pb.writeObjects(prev)
                }
            }
        }
    }

    static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem] {
        (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
    }

    /// Key code that produces "v" with ⌘ held in the current layout (Dvorak, AZERTY, "Dvorak-QWERTY ⌘"…).
    static func pasteKeyCode() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return fallback }
            let cmdState = UInt32((cmdKey >> 8) & 0xFF)
            for code in 0..<128 {
                var dead: UInt32 = 0, len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let st = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), cmdState,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &dead, 4, &len, &chars)
                if st == noErr, len == 1, chars[0] == 0x76 /* v */ { return CGKeyCode(code) }
            }
            return fallback
        }
    }

    static func sendCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = pasteKeyCode()
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    // MARK: Feedback

    func notify(_ msg: String) {
        NSLog("VoicePaste: %@", msg)
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "VoicePaste"
            alert.informativeText = msg
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
