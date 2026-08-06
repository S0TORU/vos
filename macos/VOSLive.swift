import AVFoundation
import Cocoa

// VOS Live HUD v2 — compact voice orchestrator.
// Keeps the original small floating panel; adds:
//   - native VAD auto-stop (no fixed window)
//   - live level meter while listening
//   - state dot + status line (listening → transcribing → thinking → speaking)
//   - clean transcript + Activity peek
//   - conversation loop (click Talk once), push-to-talk (hold Space / hold Talk)
//   - Esc cancel, R recap, menu-bar dot, auto daily briefing
// Build: swiftc -O -o dist/VOSLive macos/VOSLive.swift -framework Cocoa -framework AVFoundation

// MARK: - State

enum Phase {
    case idle, listening, transcribing, thinking, speaking, cancelled

    var label: String {
        switch self {
        case .idle: return "Ready — click Talk"
        case .listening: return "Listening — speak now"
        case .transcribing: return "Transcribing…"
        case .thinking: return "Thinking…"
        case .speaking: return "Speaking…"
        case .cancelled: return "Cancelled"
        }
    }
    var color: NSColor {
        switch self {
        case .idle: return .systemGray
        case .listening: return .systemRed
        case .transcribing: return .systemOrange
        case .thinking: return .systemYellow
        case .speaking: return .systemGreen
        case .cancelled: return .systemRed
        }
    }
}

// MARK: - Level meter (thin bar under the status line)

final class LevelMeterView: NSView {
    var levels: [CGFloat] = []

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let color = NSColor.systemRed
        ctx.setFillColor(color.withAlphaComponent(0.9).cgColor)
        let n = max(levels.count, 8)
        let w = bounds.width / CGFloat(n)
        for (i, lv) in levels.enumerated() {
            let h = bounds.height * max(0.06, min(1, lv))
            ctx.fill(CGRect(x: CGFloat(i) * w + 0.5, y: 0, width: max(1, w - 1), height: h))
        }
    }

    func push(_ v: CGFloat) {
        levels.append(min(1, max(0, v)))
        if levels.count > 40 { levels.removeFirst(levels.count - 40) }
        needsDisplay = true
    }

    func clear() {
        levels.removeAll()
        needsDisplay = true
    }
}

// MARK: - HUD controller

final class HudController: NSObject, AVAudioRecorderDelegate {
    let panel: NSPanel
    let titleLabel = NSTextField(labelWithString: "VOS")
    let statusDot = NSView()
    let statusLabel = NSTextField(labelWithString: Phase.idle.label)
    let meter = LevelMeterView()
    let logView = NSTextView()
    let talkButton = NSButton(title: "Talk", target: nil, action: nil)
    let recapButton = NSButton(title: "Recap", target: nil, action: nil)
    let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    let activityToggle = NSSegmentedControl(labels: ["Transcript", "Activity"], trackingMode: .selectOne, target: nil, action: nil)
    let hintLabel = NSTextField(labelWithString: "hold Space = talk · Esc = cancel · R = recap")
    let scroll = NSScrollView()
    private let activityStorage = NSMutableAttributedString()

    var phase: Phase = .idle { didSet { updatePhaseUI() } }
    var recorder: AVAudioRecorder?
    var meterTimer: Timer?
    var speechStarted = false
    var quietTime: TimeInterval = 0
    var loopMode = false
    var isRecording = false
    var showingActivity = false
    let transcriptStore = NSMutableAttributedString()

    var askProcess: Process?
    var ttsProcess: Process?
    var sessionPath: String?
    var statusItem: NSStatusItem?

    let home = FileManager.default.homeDirectoryForCurrentUser.path

    // MARK: init

    override init() {
        let style: NSWindow.StyleMask = [.titled, .closable, .nonactivatingPanel, .fullSizeContentView]
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
            styleMask: style, backing: .buffered, defer: false
        )
        super.init()
        buildPanel()
        restoreFrame()
        phase = .idle
        checkDailyBriefing()
    }

    // MARK: layout (compact, mirrors the original HUD)

    func buildPanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "VOS"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = NSColor.black.withAlphaComponent(0.82)
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        let content = NSView(frame: panel.contentView!.bounds)
        content.autoresizingMask = [.width, .height]

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.sizeToFit()
        let titleF = titleLabel.frame
        titleLabel.frame = NSRect(x: 14, y: 250, width: titleF.width, height: 20)

        statusDot.frame = NSRect(x: titleF.width + 22, y: 250, width: 9, height: 9)
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4.5
        statusDot.layer?.backgroundColor = Phase.idle.color.cgColor

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.8)
        statusLabel.frame = NSRect(x: titleF.width + 36, y: 244, width: 300 - titleF.width, height: 18)

        // meter between status and log
        meter.frame = NSRect(x: 14, y: 232, width: 332, height: 6)
        meter.isHidden = true
        meter.wantsLayer = true

        // log scroll (transcript = clean; activity = raw)
        scroll.frame = NSRect(x: 12, y: 62, width: 336, height: 160)
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        logView.isEditable = false
        logView.isRichText = true
        logView.drawsBackground = false
        logView.textContainerInset = NSSize(width: 6, height: 6)
        logView.string = "Floating voice HUD.\nTalk → auto-stop on silence → DeepSeek → speak.\n"
        scroll.documentView = logView

        // Transcript / Activity toggle — small, sits above the buttons
        activityToggle.segmentStyle = .smallSquare    // compact
        activityToggle.selectedSegment = 0
        activityToggle.target = self
        activityToggle.action = #selector(onToggleActivity)
        activityToggle.frame = NSRect(x: 12, y: 38, width: 150, height: 18)

        hintLabel.font = NSFont.systemFont(ofSize: 9)
        hintLabel.textColor = NSColor.white.withAlphaComponent(0.4)
        hintLabel.frame = NSRect(x: 170, y: 38, width: 180, height: 16)

        talkButton.bezelStyle = .rounded
        talkButton.frame = NSRect(x: 12, y: 8, width: 96, height: 26)
        talkButton.target = self
        talkButton.action = #selector(onTalkToggle)

        recapButton.bezelStyle = .rounded
        recapButton.frame = NSRect(x: 120, y: 8, width: 80, height: 26)
        recapButton.target = self
        recapButton.action = #selector(onRecap)

        quitButton.bezelStyle = .rounded
        quitButton.frame = NSRect(x: 272, y: 8, width: 74, height: 26)
        quitButton.target = self
        quitButton.action = #selector(onQuit)

        content.addSubview(titleLabel)
        content.addSubview(statusDot)
        content.addSubview(statusLabel)
        content.addSubview(meter)
        content.addSubview(scroll)
        content.addSubview(activityToggle)
        content.addSubview(hintLabel)
        content.addSubview(talkButton)
        content.addSubview(recapButton)
        content.addSubview(quitButton)
        panel.contentView = content
    }

    func restoreFrame() {
        let def = UserDefaults.standard
        if let x = def.object(forKey: "vosx") as? Double, let y = def.object(forKey: "vosy") as? Double {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 380, y: f.maxY - 320))
        }
    }

    func saveFrame() {
        let f = panel.frame.origin
        UserDefaults.standard.set(Double(f.x), forKey: "vosx")
        UserDefaults.standard.set(Double(f.y), forKey: "vosy")
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: transcript / activity

    func vosHome() -> String { "\(home)/.vos" }

    func appendTranscript(_ role: String, _ text: String, color: NSColor) {
        DispatchQueue.main.async {
            self.transcriptStore.append(NSAttributedString(string: "\n"))
            self.transcriptStore.append(NSAttributedString(
                string: "\(role)  ",
                attributes: [.foregroundColor: color, .font: NSFont.boldSystemFont(ofSize: 11.5)]))
            self.transcriptStore.append(NSAttributedString(
                string: text + "\n",
                attributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 11.5)]))
            if self.transcriptStore.length > 60000 {
                self.transcriptStore.deleteCharacters(in: NSRange(location: 0, length: self.transcriptStore.length - 40000))
            }
            if !self.showingActivity {
                self.logView.textStorage?.setAttributedString(self.transcriptStore)
                self.logView.scrollToEndOfDocument(nil)
            }
            self.saveSession(role: role, text: text)
        }
    }

    func appendActivity(_ s: String) {
        DispatchQueue.main.async {
            self.activityStorage.append(NSAttributedString(
                string: s,
                attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.75),
                             .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)]))
            if self.activityStorage.length > 60000 {
                self.activityStorage.deleteCharacters(in: NSRange(location: 0, length: self.activityStorage.length - 40000))
            }
            if self.showingActivity {
                self.logView.textStorage?.setAttributedString(self.activityStorage)
                self.logView.scrollToEndOfDocument(nil)
            }
        }
    }

    func saveSession(role: String, text: String) {
        let dir = "\(vosHome())/state/sessions"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if sessionPath == nil {
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone(identifier: "UTC")
            sessionPath = "\(dir)/hud_\(df.string(from: Date())).md"
            try? "## hud session (voice HUD)\n".write(toFile: sessionPath!, atomically: true, encoding: .utf8)
        }
        guard let p = sessionPath else { return }
        let line = "## \(role.lowercased())\n\(text)\n\n"
        if let fh = FileHandle(forWritingAtPath: p) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8) ?? Data())
            try? fh.close()
        }
    }

    // MARK: phase UI

    func updatePhaseUI() {
        DispatchQueue.main.async {
            self.statusLabel.stringValue = self.phase.label
            self.statusLabel.textColor = self.phase.color.withAlphaComponent(0.95)
            self.statusDot.layer?.backgroundColor = self.phase.color.cgColor
            self.meter.isHidden = self.phase != .listening
            self.talkButton.title = (self.loopMode && (self.isRecording || self.phase != .idle)) ? "■ Stop" : "Talk"
            self.updateMenuDot()
            if self.phase != .listening {
                self.meterTimer?.invalidate()
            }
        }
    }

    @objc func onToggleActivity() {
        showingActivity = activityToggle.selectedSegment == 1
        if showingActivity {
            logView.textStorage?.setAttributedString(activityStorage)
        } else {
            logView.textStorage?.setAttributedString(transcriptStore)
        }
        logView.scrollToEndOfDocument(nil)
    }

    // MARK: recording

    func wavPath() -> String { "\(vosHome())/state/hud_last.wav" }

    func startRecording(maxSeconds: TimeInterval = 45) {
        guard !isRecording else { return }
        requestMicIfNeeded { ok in
            guard ok else {
                self.appendActivity("Microphone access denied. System Settings → Privacy → Microphone.\n")
                self.setPhase(.cancelled)
                return
            }
            self.beginRecording(maxSeconds: maxSeconds)
        }
    }

    func beginRecording(maxSeconds: TimeInterval) {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
        ]
        let url = URL(fileURLWithPath: wavPath())
        try? FileManager.default.removeItem(at: url)
        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.isMeteringEnabled = true
            rec.delegate = self
            recorder = rec
            isRecording = true
            speechStarted = false
            quietTime = 0
            phase = .listening
            meter.clear()
            let start = Date()
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                guard let self = self, let rec = self.recorder, rec.isRecording else { return }
                rec.updateMeters()
                let power = rec.averagePower(forChannel: 0)
                let peak = rec.peakPower(forChannel: 0)
                let level = CGFloat((power * 0.6 + peak * 0.4) + 60) / 50
                self.meter.push(max(0, min(1, level)))
                let elapsed = Date().timeIntervalSince(start)
                if power > -38 {
                    if self.speechStarted {
                        self.quietTime = 0
                    } else if elapsed > 0.3 {
                        self.speechStarted = true
                        self.quietTime = 0
                        self.appendActivity("(speech detected)\n")
                    }
                } else if self.speechStarted {
                    self.quietTime += 0.07
                    if self.quietTime > 1.1 && elapsed > 0.6 {
                        self.appendActivity(String(format: "(silence %.1fs → stop)\n", self.quietTime))
                        self.stopRecording()
                    }
                }
                if elapsed > maxSeconds {
                    self.appendActivity("(max time reached)\n")
                    self.stopRecording()
                }
            }
            rec.record()
        } catch {
            appendActivity("recorder error: \(error)\n")
            setPhase(.cancelled)
        }
    }

    func stopRecording() {
        guard let rec = recorder else { return }
        recorder = nil
        isRecording = false
        meterTimer?.invalidate()
        rec.stop()
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard flag else {
            setPhase(.cancelled)
            appendActivity("(recording failed)\n")
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: wavPath())
        let size = (attrs?[.size] as? Int) ?? 0
        if size < 2000 || !speechStarted {
            appendActivity("(no speech heard)\n")
            if loopMode { rearmListening() } else { setPhase(.idle) }
            return
        }
        transcribe(path: wavPath())
    }

    // MARK: transcribe → think → speak

    func transcribe(path: String) {
        setPhase(.transcribing)
        guard let model = resolveWhisperModel() else {
            appendTranscript("VOS", "No whisper model found in ~/.whisper-models/", color: .systemRed)
            setPhase(.cancelled)
            return
        }
        runShell("/usr/bin/env whisper-cli -m '\(model)' -f '\(path)' -nt") { [weak self] out, _ in
            guard let self = self else { return }
            var text = out
                .replacingOccurrences(of: "\\[[0-9.:]+ --> [0-9.:]+\\]", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\n", with: " ")
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = text.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            if text.isEmpty {
                self.appendActivity("(empty transcript)\n")
                if self.loopMode { self.rearmListening() } else { self.setPhase(.idle) }
                return
            }
            self.appendTranscript("YOU", text, color: .systemCyan)
            self.think(userText: text)
        }
    }

    func think(userText: String) {
        setPhase(.thinking)
        let lower = userText.lowercased()
        let isStop = lower.contains("stop") || lower.contains("goodbye") || lower.contains("good bye")
            || lower.contains("cancel") || lower.contains("that's all") || lower.contains("shut up")
            || lower.contains("shut down") || lower.contains("exit") || lower.contains("pause")
        if isStop {
            appendTranscript("VOS", "Shutting down. Ready when you are.", color: .systemGreen)
            setPhase(.idle)
            loopMode = false
            talkButton.title = "Talk"
            speak("Shutting down VOS. Ready when you are.")
            return
        }
        if lower.contains("recap") && userText.count < 60 {
            runRecap(spoken: true)
            return
        }
        if lower.contains("remember that") || lower.contains("remember this") || lower.contains("remember to") {
            remember(fact: userText)
            return
        }
        askBrain(userText: userText)
    }

    func askBrain(userText: String) {
        setPhase(.thinking)
        let escaped = userText.replacingOccurrences(of: "'", with: "'\\''")
        runShell("\(vosBin()) ask '\(escaped)'") { [weak self] out, raw in
            guard let self = self else { return }
            self.appendActivity(raw + "\n")
            let answer = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.isEmpty {
                self.appendTranscript("VOS", "(offline — no conductor response)", color: .systemRed)
                self.doneCycle()
                return
            }
            self.appendTranscript("VOS", answer, color: .systemGreen)
            self.speak(answer)
        }
    }

    // MARK: recap

    func runRecap(spoken: Bool) {
        setPhase(.thinking)
        runShell("\(vosBin()) recap") { [weak self] out, raw in
            guard let self = self else { return }
            self.appendActivity(raw + "\n")
            let briefing = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !briefing.isEmpty {
                self.appendTranscript("VOS · BRIEFING", briefing, color: .systemGreen)
            }
            if spoken {
                self.runShell("\(self.vosBin()) recap --short") { shortOut, _ in
                    let short = shortOut.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.speak(short.isEmpty ? String(briefing.prefix(900)) : short)
                }
            }
            self.doneCycle()
        }
    }

    // MARK: remember

    func remember(fact: String) {
        var fact = fact
        for prefix in ["remember that ", "remember this ", "remember to ", "remember "] {
            if fact.lowercased().hasPrefix(prefix) {
                fact = String(fact.dropFirst(prefix.count))
                break
            }
        }
        let escaped = fact.replacingOccurrences(of: "'", with: "'\\''")
        setPhase(.thinking)
        runShell("\(vosBin()) remember '\(escaped)'") { [weak self] out, _ in
            guard let self = self else { return }
            let msg = out.trimmingCharacters(in: .whitespacesAndNewlines)
            self.appendTranscript("VOS", msg.isEmpty ? "Remembered: \(fact)" : msg, color: .systemGreen)
            self.speak(msg.isEmpty ? "Okay, remembered." : msg)
        }
    }

    // MARK: TTS

    func speak(_ text: String) {
        setPhase(.speaking)
        let clean = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: " ")
        let voice = UserDefaults.standard.string(forKey: "vosvoice") ?? ""
        let aiff = "\(vosHome())/state/hud_speech.aiff"
        let aiffArg = aiff.replacingOccurrences(of: "'", with: "'\\''")
        let voiceArg = voice.isEmpty ? "" : "-v '\(voice.replacingOccurrences(of: "'", with: "'\\''"))' "
        let escaped = clean.replacingOccurrences(of: "'", with: "'\\''")
        ttsProcess = runShellRaw("/bin/zsh -lc '\(voiceArg)say -r 195 -o \(aiffArg) \"\(escaped)\" && /usr/bin/afplay \(aiffArg)'") { [weak self] _, _ in
            guard let self = self else { return }
            self.doneCycle()
        }
    }

    func stopSpeaking() {
        if let p = ttsProcess {
            p.terminate()
            ttsProcess = nil
        }
    }

    // MARK: cycle

    func doneCycle() {
        DispatchQueue.main.async {
            if self.loopMode {
                self.rearmListening()
            } else {
                self.setPhase(.idle)
                self.talkButton.title = "Talk"
            }
        }
    }

    func rearmListening() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, self.loopMode, !self.isRecording else { return }
            self.appendActivity("…listening again\n")
            self.startRecording()
        }
    }

    func setPhase(_ p: Phase) {
        phase = p
    }

    // MARK: shell plumbing

    func vosBin() -> String {
        let candidates = ["\(home)/bin/vos", "\(home)/vos/bin/vos"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "vos"
    }

    func resolveWhisperModel() -> String? {
        if let m = ProcessInfo.processInfo.environment["VOS_MODEL"], FileManager.default.fileExists(atPath: m) { return m }
        let fm = FileManager.default
        let dirs = ["\(home)/.whisper-models"]
        for d in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: d) else { continue }
            let sorted = items.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }.sorted()
            for name in sorted {
                if name.contains("small") || name.contains("base.en") || name.contains("base") || name.contains("medium") {
                    return "\(d)/\(name)"
                }
            }
            if let first = sorted.first { return "\(d)/\(first)" }
        }
        return nil
    }

    func runShell(_ cmd: String, completion: @escaping (String, String) -> Void) {
        askProcess = runShellRaw(cmd) { [weak self] out, raw in
            self?.askProcess = nil
            completion(out, raw)
        }
    }

    func runShellRaw(_ cmd: String, completion: @escaping (String, String) -> Void) -> Process {
        let wrapper = """
        import subprocess, sys, os
        p = subprocess.Popen(sys.argv[1], shell=True, start_new_session=True)
        rc = p.wait()
        sys.exit(rc)
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let full = "export PATH=\"$HOME/bin:/opt/homebrew/bin:/usr/local/bin:$PATH\"; cd \"$HOME\"; " + cmd
        proc.arguments = ["-c", wrapper, full]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        var acc = ""
        let fh = pipe.fileHandleForReading
        let source = DispatchSource.makeReadSource(fileDescriptor: fh.fileDescriptor)
        source.setEventHandler {
            let data = fh.availableData
            if let s = String(data: data, encoding: .utf8) {
                acc += s
                DispatchQueue.main.async { self.appendActivity(s) }
            }
        }
        source.setCancelHandler { try? fh.close() }
        source.resume()
        proc.terminationHandler = { _ in
            source.cancel()
            DispatchQueue.main.async { completion(acc, acc) }
        }
        do {
            try proc.run()
        } catch {
            completion("", "launch error: \(error)")
        }
        return proc
    }

    func cancelAll() {
        stopSpeaking()
        if let p = askProcess {
            let pid = p.processIdentifier
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/bin/kill")
            kill.arguments = ["-TERM", "-\(pid)"]
            try? kill.run()
            p.terminate()
            askProcess = nil
        }
        if isRecording { stopRecording() }
        loopMode = false
        talkButton.title = "Talk"
        setPhase(.cancelled)
        appendTranscript("VOS", "Cancelled.", color: .systemRed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            if self?.phase == .cancelled { self?.setPhase(.idle) }
        }
    }

    // MARK: mic permission

    func requestMicIfNeeded(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in completion(ok) }
        default: completion(false)
        }
    }

    // MARK: buttons

    @objc func onTalkToggle() {
        if isRecording || phase == .listening {
            stopRecording()
            return
        }
        if phase == .thinking || phase == .transcribing || phase == .speaking {
            cancelAll()
            return
        }
        loopMode = true
        talkButton.title = "■ Stop"
        startRecording()
    }

    // Push-to-talk via keyboard: hold Space = record only while held
    func startKeyHeld() {
        if isRecording || phase == .listening { return }
        if phase == .thinking || phase == .transcribing || phase == .speaking {
            cancelAll()
            return
        }
        loopMode = false
        talkButton.title = "■ Stop"
        startRecording()
    }

    func endKeyHeld() {
        if isRecording { stopRecording() }
        if !loopMode {
            talkButton.title = "Talk"
        }
    }

    @objc func onCancel() { cancelAll() }

    @objc func onRecap() {
        if phase == .listening { return }
        cancelAll()
        loopMode = false
        runRecap(spoken: true)
    }

    @objc func onQuit() {
        saveFrame()
        NSApp.terminate(nil)
    }

    // MARK: menu bar

    func updateMenuDot() {
        DispatchQueue.main.async {
            guard let btn = self.statusItem?.button else { return }
            btn.image = self.dotImage(color: self.phase.color, size: NSSize(width: 14, height: 14))
        }
    }

    func dotImage(color: NSColor, size: NSSize) -> NSImage? {
        let img = NSImage(size: size)
        img.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: size.width - 4, height: size.height - 4)).fill()
        img.unlockFocus()
        return img
    }

    // MARK: menu bar actions

    @objc func onMenuClick() {
        if let btn = statusItem?.button, let menu = btn.menu, let event = NSApp.currentEvent {
            btn.performClick(nil)
            _ = menu; _ = event
        }
    }

    @objc func onMenuOpen() { show() }

    @objc func onMenuRecap() {
        show()
        runRecap(spoken: false)
    }

    @objc func onMenuCopy() {
        let paste = NSPasteboard.general
        paste.clearContents()
        paste.setString(logView.string, forType: .string)
    }

    // MARK: daily briefing (once per day)

    func checkDailyBriefing() {
        let briefPath = "\(vosHome())/state/last_briefing.md"
        let startOfDay = Calendar.current.startOfDay(for: Date())
        var needsBrief = true
        if let attrs = try? FileManager.default.attributesOfItem(atPath: briefPath),
           let mtime = attrs[.modificationDate] as? Date {
            needsBrief = mtime < startOfDay
        }
        guard needsBrief else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            self.appendActivity("(refreshing daily briefing)\n")
            self.runShell("\(self.vosBin()) recap") { out, _ in
                let b = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !b.isEmpty {
                    self.appendTranscript("VOS · BRIEFING", b, color: .systemGreen)
                }
                self.setPhase(.idle)
            }
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    let hud = HudController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = item.button {
            btn.image = hud.dotImage(color: .systemGray, size: NSSize(width: 14, height: 14))
        }
        hud.statusItem = item
        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open VOS", action: #selector(HudController.onMenuOpen), keyEquivalent: "")
        openItem.target = hud
        let recapItem = NSMenuItem(title: "Recap", action: #selector(HudController.onMenuRecap), keyEquivalent: "")
        recapItem.target = hud
        let copyItem = NSMenuItem(title: "Copy Transcript", action: #selector(HudController.onMenuCopy), keyEquivalent: "")
        copyItem.target = hud
        let quitItem = NSMenuItem(title: "Quit VOS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(openItem)
        menu.addItem(recapItem)
        menu.addItem(copyItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)
        item.menu = menu
        installKeyboardMonitor()
        hud.show()
    }

    // Space hold = push-to-talk, Esc = cancel, R = recap
    func installKeyboardMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === self.hud.panel else { return event }
            switch event.keyCode {
            case 49: // Space
                self.hud.startKeyHeld()
                return nil
            case 53: // Esc
                self.hud.cancelAll()
                return nil
            case 15: // R
                self.hud.onRecap()
                return nil
            default:
                return event
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            guard event.window === self.hud.panel else { return event }
            if event.keyCode == 49 {
                self.hud.endKeyHeld()
                return nil
            }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        hud.saveFrame()
    }
}

// MARK: - Main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
