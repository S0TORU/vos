import AVFoundation
import Cocoa

// VOS Live HUD — refined monochrome + teal instrument surface.
// Features preserved: VAD auto-stop, phases, transcript/activity, loop Talk,
// Space PTT, Esc cancel, R recap, menu-bar dot, daily briefing, remember.
// Build: swiftc -O -o dist/VOSLive macos/VOSLive.swift -framework Cocoa -framework AVFoundation

// MARK: - Tokens (LURA-ish monochrome + accent)

enum VosTheme {
    static let accent = NSColor(calibratedRed: 0.17, green: 0.78, blue: 0.72, alpha: 1)      // #2CC8B8
    static let accentSoft = NSColor(calibratedRed: 0.17, green: 0.78, blue: 0.72, alpha: 0.18)
    static let ink = NSColor.white.withAlphaComponent(0.92)
    static let ink2 = NSColor.white.withAlphaComponent(0.58)
    static let ink3 = NSColor.white.withAlphaComponent(0.38)
    static let line = NSColor.white.withAlphaComponent(0.10)
    static let panelFill = NSColor(calibratedWhite: 0.07, alpha: 0.94)
    static let well = NSColor.white.withAlphaComponent(0.04)
    static let you = NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.95, alpha: 1)
    static let vos = accent
}

// MARK: - State

enum Phase {
    case idle, listening, transcribing, thinking, speaking, cancelled

    var label: String {
        switch self {
        case .idle: return "Ready"
        case .listening: return "Listening"
        case .transcribing: return "Transcribing"
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        case .cancelled: return "Cancelled"
        }
    }

    var color: NSColor {
        switch self {
        case .idle: return VosTheme.ink3
        case .listening: return VosTheme.accent
        case .transcribing: return NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.35, alpha: 1)
        case .thinking: return NSColor(calibratedRed: 0.95, green: 0.82, blue: 0.35, alpha: 1)
        case .speaking: return NSColor(calibratedRed: 0.45, green: 0.85, blue: 0.55, alpha: 1)
        case .cancelled: return NSColor(calibratedRed: 0.9, green: 0.35, blue: 0.35, alpha: 1)
        }
    }
}

// MARK: - Level meter

final class LevelMeterView: NSView {
    var levels: [CGFloat] = []

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let n = max(levels.count, 12)
        let w = bounds.width / CGFloat(n)
        for (i, lv) in levels.enumerated() {
            let a = 0.35 + 0.65 * max(0.05, min(1, lv))
            ctx.setFillColor(VosTheme.accent.withAlphaComponent(a).cgColor)
            let h = bounds.height * max(0.08, min(1, lv))
            let rect = CGRect(x: CGFloat(i) * w + 0.6, y: 0, width: max(1.2, w - 1.2), height: h)
            let path = CGPath(roundedRect: rect, cornerWidth: 1, cornerHeight: 1, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }
    }

    func push(_ v: CGFloat) {
        levels.append(min(1, max(0, v)))
        if levels.count > 48 { levels.removeFirst(levels.count - 48) }
        needsDisplay = true
    }

    func clear() {
        levels.removeAll()
        needsDisplay = true
    }
}

// MARK: - Pill button

final class PillButton: NSButton {
    var filled = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        if filled {
            VosTheme.accent.setFill()
            path.fill()
            (isHighlighted ? NSColor.black.withAlphaComponent(0.7) : NSColor.black.withAlphaComponent(0.88)).set()
        } else {
            VosTheme.well.setFill()
            path.fill()
            VosTheme.line.setStroke()
            path.lineWidth = 1
            path.stroke()
            (isHighlighted ? VosTheme.ink : VosTheme.ink2).set()
        }
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        let title = self.title as NSString
        let font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: filled ? NSColor.black.withAlphaComponent(0.9) : VosTheme.ink,
            .paragraphStyle: p,
        ]
        let size = title.size(withAttributes: attrs)
        title.draw(in: NSRect(x: 0, y: (bounds.height - size.height) / 2 - 0.5, width: bounds.width, height: size.height), withAttributes: attrs)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 88, height: 28) }
}

// MARK: - HUD

final class HudController: NSObject, AVAudioRecorderDelegate {
    let panel: NSPanel
    let chrome = NSVisualEffectView()
    let titleLabel = NSTextField(labelWithString: "VOS")
    let statusDot = NSView()
    let statusLabel = NSTextField(labelWithString: Phase.idle.label)
    let meter = LevelMeterView()
    let logView = NSTextView()
    let talkButton = PillButton(title: "Talk", target: nil, action: nil)
    let recapButton = PillButton(title: "Recap", target: nil, action: nil)
    let quitButton = PillButton(title: "Quit", target: nil, action: nil)
    let activityToggle = NSSegmentedControl(labels: ["Transcript", "Activity"], trackingMode: .selectOne, target: nil, action: nil)
    let hintLabel = NSTextField(labelWithString: "Space hold · Esc cancel · R recap")
    let scroll = NSScrollView()
    let well = NSView()
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

    override init() {
        let style: NSWindow.StyleMask = [.titled, .closable, .nonactivatingPanel, .fullSizeContentView]
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 352, height: 292),
            styleMask: style, backing: .buffered, defer: false
        )
        super.init()
        buildPanel()
        restoreFrame()
        phase = .idle
        seedWelcome()
        checkDailyBriefing()
    }

    func buildPanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "VOS"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true

        // Frosted glass base
        chrome.material = .hudWindow
        chrome.blendingMode = .behindWindow
        chrome.state = .active
        chrome.wantsLayer = true
        chrome.layer?.cornerRadius = 14
        chrome.layer?.masksToBounds = true
        chrome.frame = panel.contentView!.bounds
        chrome.autoresizingMask = [.width, .height]

        // Subtle border
        let border = CALayer()
        border.frame = chrome.bounds
        border.cornerRadius = 14
        border.borderWidth = 1
        border.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        border.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        chrome.layer?.addSublayer(border)

        let content = NSView(frame: chrome.bounds)
        content.autoresizingMask = [.width, .height]
        chrome.addSubview(content)

        // Header
        titleLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = VosTheme.ink
        titleLabel.stringValue = "VOS"
        titleLabel.frame = NSRect(x: 16, y: 258, width: 48, height: 18)

        statusDot.wantsLayer = true
        statusDot.frame = NSRect(x: 62, y: 261, width: 8, height: 8)
        statusDot.layer?.cornerRadius = 4
        statusDot.layer?.backgroundColor = Phase.idle.color.cgColor
        statusDot.layer?.borderWidth = 0.5
        statusDot.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        statusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.textColor = VosTheme.ink2
        statusLabel.frame = NSRect(x: 76, y: 256, width: 250, height: 18)

        meter.frame = NSRect(x: 16, y: 246, width: 320, height: 5)
        meter.isHidden = true

        // Transcript well
        well.wantsLayer = true
        well.layer?.cornerRadius = 10
        well.layer?.backgroundColor = VosTheme.well.cgColor
        well.layer?.borderWidth = 1
        well.layer?.borderColor = VosTheme.line.cgColor
        well.frame = NSRect(x: 12, y: 58, width: 328, height: 178)

        scroll.frame = well.bounds.insetBy(dx: 2, dy: 2)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        logView.isEditable = false
        logView.isRichText = true
        logView.drawsBackground = false
        logView.textContainerInset = NSSize(width: 10, height: 10)
        logView.textContainer?.lineFragmentPadding = 0
        scroll.documentView = logView
        well.addSubview(scroll)

        activityToggle.segmentStyle = .rounded
        activityToggle.selectedSegment = 0
        activityToggle.target = self
        activityToggle.action = #selector(onToggleActivity)
        activityToggle.frame = NSRect(x: 12, y: 36, width: 148, height: 20)
        if #available(macOS 11.0, *) {
            activityToggle.controlSize = .small
        }

        hintLabel.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
        hintLabel.textColor = VosTheme.ink3
        hintLabel.frame = NSRect(x: 168, y: 36, width: 172, height: 18)
        hintLabel.alignment = .right

        talkButton.filled = true
        talkButton.frame = NSRect(x: 12, y: 8, width: 100, height: 26)
        talkButton.target = self
        talkButton.action = #selector(onTalkToggle)

        recapButton.frame = NSRect(x: 120, y: 8, width: 88, height: 26)
        recapButton.target = self
        recapButton.action = #selector(onRecap)

        quitButton.frame = NSRect(x: 264, y: 8, width: 76, height: 26)
        quitButton.target = self
        quitButton.action = #selector(onQuit)

        content.addSubview(titleLabel)
        content.addSubview(statusDot)
        content.addSubview(statusLabel)
        content.addSubview(meter)
        content.addSubview(well)
        content.addSubview(activityToggle)
        content.addSubview(hintLabel)
        content.addSubview(talkButton)
        content.addSubview(recapButton)
        content.addSubview(quitButton)

        panel.contentView = chrome
        setupStatusItem()
        setupKeyMonitor()
    }

    func seedWelcome() {
        let intro = "Instrument surface · Talk auto-stops on silence · DeepSeek brain\n"
        transcriptStore.append(NSAttributedString(
            string: intro,
            attributes: [
                .foregroundColor: VosTheme.ink3,
                .font: NSFont.systemFont(ofSize: 11),
            ]))
        logView.textStorage?.setAttributedString(transcriptStore)
    }

    func restoreFrame() {
        let def = UserDefaults.standard
        if let x = def.object(forKey: "vosx") as? Double, let y = def.object(forKey: "vosy") as? Double {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 372, y: f.maxY - 330))
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
            let roleColor = role.uppercased().hasPrefix("YOU") ? VosTheme.you : color
            self.transcriptStore.append(NSAttributedString(string: "\n"))
            self.transcriptStore.append(NSAttributedString(
                string: "\(role)  ",
                attributes: [
                    .foregroundColor: roleColor.withAlphaComponent(0.95),
                    .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
                ]))
            self.transcriptStore.append(NSAttributedString(
                string: text + "\n",
                attributes: [
                    .foregroundColor: VosTheme.ink,
                    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                ]))
            if self.transcriptStore.length > 50000 {
                self.transcriptStore.deleteCharacters(in: NSRange(location: 0, length: self.transcriptStore.length - 35000))
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
                attributes: [
                    .foregroundColor: VosTheme.ink3,
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                ]))
            if self.activityStorage.length > 50000 {
                self.activityStorage.deleteCharacters(in: NSRange(location: 0, length: self.activityStorage.length - 35000))
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

    func updatePhaseUI() {
        DispatchQueue.main.async {
            self.statusLabel.stringValue = self.phase.label
            self.statusLabel.textColor = self.phase == .idle ? VosTheme.ink2 : self.phase.color
            self.statusDot.layer?.backgroundColor = self.phase.color.cgColor
            self.meter.isHidden = self.phase != .listening
            let stop = self.loopMode && (self.isRecording || self.phase != .idle)
            self.talkButton.title = stop ? "Stop" : "Talk"
            self.talkButton.filled = !stop
            self.talkButton.needsDisplay = true
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

    // MARK: recording (VAD)

    func wavPath() -> String { "\(vosHome())/state/hud_last.wav" }

    func startRecording(maxSeconds: TimeInterval = 45) {
        guard !isRecording else { return }
        requestMicIfNeeded { ok in
            guard ok else {
                self.appendActivity("Microphone denied — System Settings → Privacy → Microphone.\n")
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
                        self.appendActivity("speech\n")
                    }
                } else if self.speechStarted {
                    self.quietTime += 0.07
                    if self.quietTime > 1.1 && elapsed > 0.6 {
                        self.appendActivity(String(format: "silence %.1fs → stop\n", self.quietTime))
                        self.stopRecording()
                    }
                }
                if elapsed > maxSeconds {
                    self.appendActivity("max time\n")
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
            appendActivity("recording failed\n")
            return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: wavPath())
        let size = (attrs?[.size] as? Int) ?? 0
        if size < 2000 || !speechStarted {
            appendActivity("no speech\n")
            if loopMode { rearmListening() } else { setPhase(.idle) }
            return
        }
        transcribe(path: wavPath())
    }

    // MARK: pipeline

    func transcribe(path: String) {
        setPhase(.transcribing)
        guard let model = resolveWhisperModel() else {
            appendTranscript("VOS", "No whisper model in ~/.whisper-models/", color: VosTheme.cancelledColor)
            setPhase(.cancelled)
            return
        }
        let m = model.replacingOccurrences(of: "'", with: "'\\''")
        let p = path.replacingOccurrences(of: "'", with: "'\\''")
        runShell("/usr/bin/env whisper-cli -m '\(m)' -f '\(p)' -nt") { [weak self] out, _ in
            guard let self = self else { return }
            var text = out
            if let re = try? NSRegularExpression(pattern: "\\[[0-9.:]+ --> [0-9.:]+\\]") {
                text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            }
            text = text.replacingOccurrences(of: "\n", with: " ")
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = text.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)
            if text.isEmpty {
                self.appendActivity("empty transcript\n")
                if self.loopMode { self.rearmListening() } else { self.setPhase(.idle) }
                return
            }
            self.appendTranscript("YOU", text, color: VosTheme.you)
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
            appendTranscript("VOS", "Shutting down. Ready when you are.", color: VosTheme.vos)
            setPhase(.idle)
            loopMode = false
            talkButton.title = "Talk"
            talkButton.filled = true
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
            self.appendActivity(String(raw.prefix(2000)) + "\n")
            let answer = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer.isEmpty {
                self.appendTranscript("VOS", "(no conductor response)", color: Phase.cancelled.color)
                self.doneCycle()
                return
            }
            // Keep spoken answer short for TTS if huge
            self.appendTranscript("VOS", answer, color: VosTheme.vos)
            let spoken = answer.count > 1200 ? String(answer.prefix(1100)) + "…" : answer
            self.speak(spoken)
        }
    }

    func runRecap(spoken: Bool) {
        setPhase(.thinking)
        runShell("\(vosBin()) recap") { [weak self] out, raw in
            guard let self = self else { return }
            self.appendActivity(String(raw.prefix(1500)) + "\n")
            let briefing = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !briefing.isEmpty {
                self.appendTranscript("VOS · BRIEFING", briefing, color: VosTheme.vos)
            }
            if spoken {
                self.runShell("\(self.vosBin()) recap --short") { shortOut, _ in
                    let short = shortOut.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.speak(short.isEmpty ? String(briefing.prefix(700)) : short)
                }
            } else {
                self.doneCycle()
            }
        }
    }

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
            self.appendTranscript("VOS", msg.isEmpty ? "Remembered." : msg, color: VosTheme.vos)
            self.speak(msg.isEmpty ? "Okay, remembered." : msg)
        }
    }

    func speak(_ text: String) {
        setPhase(.speaking)
        let clean = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "#", with: " ")
            .replacingOccurrences(of: "—", with: " - ")
        let voice = UserDefaults.standard.string(forKey: "vosvoice") ?? ""
        let aiff = "\(vosHome())/state/hud_speech.aiff"
        let aiffArg = aiff.replacingOccurrences(of: "'", with: "'\\''")
        let voiceArg = voice.isEmpty ? "" : "-v '\(voice.replacingOccurrences(of: "'", with: "'\\''"))' "
        // Use heredoc-safe approach via printf
        let b64 = Data(clean.utf8).base64EncodedString()
        ttsProcess = runShellRaw("/bin/zsh -lc 'printf %s \(b64) | base64 -d | \(voiceArg)say -r 195 -o \(aiffArg) && /usr/bin/afplay \(aiffArg)'") { [weak self] _, _ in
            self?.doneCycle()
        }
    }

    func stopSpeaking() {
        if let p = ttsProcess {
            p.terminate()
            ttsProcess = nil
        }
    }

    func doneCycle() {
        DispatchQueue.main.async {
            if self.loopMode {
                self.rearmListening()
            } else {
                self.setPhase(.idle)
                self.talkButton.title = "Talk"
                self.talkButton.filled = true
                self.talkButton.needsDisplay = true
            }
        }
    }

    func rearmListening() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self = self, self.loopMode, !self.isRecording else { return }
            self.appendActivity("…listening\n")
            self.startRecording()
        }
    }

    func setPhase(_ p: Phase) { phase = p }

    // MARK: shell

    func vosBin() -> String {
        let candidates = ["\(home)/bin/vos", "\(home)/vos/bin/vos"]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
        return "vos"
    }

    func resolveWhisperModel() -> String? {
        if let m = ProcessInfo.processInfo.environment["VOS_MODEL"], FileManager.default.fileExists(atPath: m) { return m }
        let fm = FileManager.default
        let d = "\(home)/.whisper-models"
        guard let items = try? fm.contentsOfDirectory(atPath: d) else { return nil }
        let sorted = items.filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }.sorted()
        for name in ["ggml-small.en.bin", "ggml-base.en.bin", "ggml-base.bin"] {
            if sorted.contains(name) { return "\(d)/\(name)" }
        }
        if let first = sorted.first { return "\(d)/\(first)" }
        return nil
    }

    @discardableResult
    func runShellRaw(_ cmd: String, completion: @escaping (String, String) -> Void) -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-lc", "export PATH=\"$HOME/bin:/opt/homebrew/bin:$PATH\"; \(cmd)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            DispatchQueue.global(qos: .userInitiated).async {
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8) ?? ""
                // Prefer stdout-ish final: strip common noise
                let out = raw
                DispatchQueue.main.async { completion(out, raw) }
            }
        } catch {
            completion("", "error: \(error)")
        }
        return proc
    }

    func runShell(_ cmd: String, completion: @escaping (String, String) -> Void) {
        askProcess = runShellRaw(cmd) { [weak self] out, raw in
            self?.askProcess = nil
            completion(out, raw)
        }
    }

    // MARK: mic permission

    func requestMicIfNeeded(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { done(ok) }
            }
        default: done(false)
        }
    }

    // MARK: actions

    @objc func onTalkToggle() {
        if isRecording || (loopMode && phase != .idle) {
            cancelAll()
            return
        }
        loopMode = true
        startRecording()
    }

    @objc func onRecap() {
        if isRecording { stopRecording() }
        runRecap(spoken: true)
    }

    @objc func onQuit() {
        saveFrame()
        cancelAll()
        NSApp.terminate(nil)
    }

    func cancelAll() {
        loopMode = false
        if isRecording { stopRecording() }
        askProcess?.terminate()
        askProcess = nil
        stopSpeaking()
        setPhase(.idle)
        talkButton.title = "Talk"
        talkButton.filled = true
        talkButton.needsDisplay = true
        appendActivity("cancelled\n")
    }

    // MARK: keys + menu bar

    func setupKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .keyUp]) { [weak self] ev in
            guard let self = self else { return ev }
            // Esc
            if ev.type == .keyDown && ev.keyCode == 53 {
                self.cancelAll()
                return nil
            }
            // R recap
            if ev.type == .keyDown && ev.charactersIgnoringModifiers?.lowercased() == "r"
                && !ev.modifierFlags.contains(.command) {
                if self.phase == .idle || self.phase == .cancelled {
                    self.onRecap()
                    return nil
                }
            }
            // Space PTT
            if ev.keyCode == 49 {
                if ev.type == .keyDown && !ev.isARepeat {
                    if !self.isRecording && self.phase == .idle {
                        self.loopMode = false
                        self.startRecording()
                    }
                    return nil
                }
                if ev.type == .keyUp && self.isRecording && !self.loopMode {
                    self.stopRecording()
                    return nil
                }
            }
            return ev
        }
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem?.button {
            btn.title = "●"
            btn.font = NSFont.systemFont(ofSize: 11)
            btn.contentTintColor = VosTheme.ink3
            btn.toolTip = "VOS"
            btn.target = self
            btn.action = #selector(onStatusClick)
        }
    }

    @objc func onStatusClick() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    func updateMenuDot() {
        statusItem?.button?.contentTintColor = phase == .idle ? VosTheme.ink3 : phase.color
    }

    // MARK: daily briefing

    func checkDailyBriefing() {
        let key = "vos_last_brief_day"
        let day = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        let last = UserDefaults.standard.string(forKey: key)
        if last != day {
            UserDefaults.standard.set(day, forKey: key)
            appendActivity("daily briefing refresh…\n")
            // silent recap into transcript (no TTS spam on boot)
            runShell("\(vosBin()) recap") { [weak self] out, _ in
                let b = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if !b.isEmpty {
                    self?.appendTranscript("VOS · BRIEFING", b, color: VosTheme.vos)
                }
            }
        }
    }
}

private extension VosTheme {
    static var cancelledColor: NSColor { Phase.cancelled.color }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let hud = HudController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        hud.show()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        hud.saveFrame()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
