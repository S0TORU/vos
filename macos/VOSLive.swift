import Cocoa
import Foundation

// Floating SuperWhisper-style HUD for VOS.
// Build: swiftc -O -o dist/VOSLive macos/VOSLive.swift -framework Cocoa
// Run:   open / path or vos live

final class HudController: NSObject {
    let panel: NSPanel
    let titleLabel = NSTextField(labelWithString: "VOS")
    let statusLabel = NSTextField(labelWithString: "Ready — click Talk")
    let logView = NSTextView()
    let talkButton = NSButton(title: "Talk 20s", target: nil, action: nil)
    let recapButton = NSButton(title: "Recap", target: nil, action: nil)
    let quitButton = NSButton(title: "Quit", target: nil, action: nil)
    var busy = false

    override init() {
        let style: NSWindow.StyleMask = [.titled, .closable, .nonactivatingPanel, .fullSizeContentView]
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        super.init()
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

        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.frame = NSRect(x: 16, y: 240, width: 200, height: 24)

        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        statusLabel.frame = NSRect(x: 16, y: 218, width: 320, height: 18)

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 56, width: 328, height: 150))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        logView.isEditable = false
        logView.isRichText = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .white
        logView.backgroundColor = NSColor.white.withAlphaComponent(0.06)
        logView.string = "Floating voice HUD.\nTalk → local Whisper → DeepSeek → speak.\n"
        scroll.documentView = logView

        talkButton.bezelStyle = .rounded
        talkButton.frame = NSRect(x: 16, y: 16, width: 100, height: 28)
        talkButton.target = self
        talkButton.action = #selector(onTalk)

        recapButton.bezelStyle = .rounded
        recapButton.frame = NSRect(x: 128, y: 16, width: 80, height: 28)
        recapButton.target = self
        recapButton.action = #selector(onRecap)

        quitButton.bezelStyle = .rounded
        quitButton.frame = NSRect(x: 268, y: 16, width: 76, height: 28)
        quitButton.target = self
        quitButton.action = #selector(onQuit)

        content.addSubview(titleLabel)
        content.addSubview(statusLabel)
        content.addSubview(scroll)
        content.addSubview(talkButton)
        content.addSubview(recapButton)
        content.addSubview(quitButton)
        panel.contentView = content

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.maxX - 380, y: f.maxY - 320))
        }
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func appendLog(_ s: String) {
        DispatchQueue.main.async {
            self.logView.string += s
            if self.logView.string.count > 12000 {
                self.logView.string = String(self.logView.string.suffix(8000))
            }
            self.logView.scrollToEndOfDocument(nil)
        }
    }

    func setStatus(_ s: String) {
        DispatchQueue.main.async {
            self.statusLabel.stringValue = s
        }
    }

    func vosBin() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/bin/vos",
            "\(home)/vos/bin/vos",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return "vos"
    }

    func runVos(args: [String], label: String) {
        if busy { return }
        busy = true
        setStatus(label)
        appendLog("\n— \(label) —\n")
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let cmd = ([self.vosBin()] + args)
                .map { $0.replacingOccurrences(of: "'", with: "'\\''") }
                .map { "'\($0)'" }
                .joined(separator: " ")
            proc.arguments = ["-lc", "export PATH=\"$HOME/bin:/opt/homebrew/bin:$PATH\"; \(cmd)"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            do {
                try proc.run()
                proc.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8) ?? ""
                self.appendLog(out + "\n")
                self.setStatus(proc.terminationStatus == 0 ? "Ready" : "Error (see log)")
            } catch {
                self.appendLog("Failed: \(error)\n")
                self.setStatus("Failed")
            }
            self.busy = false
        }
    }

    @objc func onTalk() {
        // listen already speaks via vos
        runVos(args: ["listen", "20"], label: "Listening 20s…")
    }

    @objc func onRecap() {
        runVos(args: ["recap"], label: "Recap…")
    }

    @objc func onQuit() {
        NSApp.terminate(nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let hud = HudController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        hud.show()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // no dock bounce spam; still floating panel
app.run()
