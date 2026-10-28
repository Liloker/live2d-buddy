// Live2D Buddy — a tiny native macOS shell for a Live2D desktop pet.
//
// One borderless, transparent, always-on-top NSPanel hosts a WKWebView that
// renders the character (web/pet.js). No Electron, no background network
// traffic; the only download is the user-initiated "Get demo characters…".
//
// The same binary is also a command-line client (`Live2DBuddy --cli say hi`,
// wrapped by bin/buddy). Commands reach the running pet through the
// live2dbuddy:// URL scheme, so anything that can run a shell command or open
// a URL — Claude Code hooks, Codex notify, Raycast, Shortcuts, cron — can
// drive it.

import AppKit
import WebKit

let bundleID = "io.github.liloker.live2dbuddy"
let urlScheme = "live2dbuddy"
let dataFolderName = "Live2D Buddy"

// MARK: - Localisation (menu strings only; bubble lines live in web/lines/*.json)

let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false
func tr(_ zh: String, _ en: String) -> String { isChinese ? zh : en }

enum Paths {
    /// ~/Library/Application Support/Live2D Buddy — runtime, models and user overrides.
    static var dataDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dataFolderName, isDirectory: true)
    }
    static var webDir: URL { Bundle.main.resourceURL!.appendingPathComponent("Web", isDirectory: true) }
}

// MARK: - Asset scheme: petasset://app/<path>

/// Serves the page and its assets. UI code always comes from the app bundle;
/// third-party files (runtime, models) and user overrides (characters.json,
/// lines/) are looked up in the data folder first.
final class AssetHandler: NSObject, WKURLSchemeHandler {
    let bundleRoot: URL
    let dataRoot: URL
    static let overridable = ["models/", "lines/", "live2d.min.js", "characters.json"]
    static let mimeTypes = [
        "html": "text/html", "js": "application/javascript", "json": "application/json",
        "png": "image/png", "mtn": "text/plain", "moc": "application/octet-stream", "css": "text/css",
    ]

    init(bundleRoot: URL, dataRoot: URL) {
        self.bundleRoot = bundleRoot.standardizedFileURL
        self.dataRoot = dataRoot.standardizedFileURL
    }

    func resolve(_ relative: String) -> URL? {
        var roots = [bundleRoot]
        if Self.overridable.contains(where: { relative == $0 || relative.hasPrefix($0) }) {
            roots.insert(dataRoot, at: 0)
        }
        for root in roots {
            let file = root.appendingPathComponent(relative).standardizedFileURL
            guard file.path.hasPrefix(root.path + "/") else { continue } // no path traversal
            if FileManager.default.isReadableFile(atPath: file.path) { return file }
        }
        return nil
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "app" else {
            task.didFailWithError(NSError(domain: "Assets", code: 403))
            return
        }
        let relative = url.path == "/" ? "index.html" : String(url.path.dropFirst())
        guard let file = resolve(relative), let bytes = try? Data(contentsOf: file) else {
            // A real 404 lets the page tell "asset missing" apart from other failures.
            task.didReceive(HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
            task.didReceive(Data())
            task.didFinish()
            return
        }
        let ext = file.pathExtension.lowercased()
        let textual = ["html", "js", "json", "mtn", "css"].contains(ext)
        task.didReceive(URLResponse(url: url, mimeType: Self.mimeTypes[ext] ?? "application/octet-stream",
                                    expectedContentLength: bytes.count, textEncodingName: textual ? "utf-8" : nil))
        task.didReceive(bytes)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - Window

final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func accessibilityPerformRaise() -> Bool { orderFrontRegardless(); return true }
}

/// Transparent view on top of the web view: drag to move, click to interact, right-click for the menu.
final class InteractionView: NSView {
    weak var petWeb: WKWebView?
    var petMenu: (() -> NSMenu)?
    var onMoved: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(tr("桌宠角色：点击互动，拖动移动，右键菜单", "Desktop pet: click to interact, drag to move, right-click for menu"))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        petWeb?.evaluateJavaScript("pet.tap()", completionHandler: nil)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        let origin = window.frame.origin
        window.performDrag(with: event)
        // Moving less than 4 points counts as a click, not a drag.
        if hypot(window.frame.origin.x - origin.x, window.frame.origin.y - origin.y) < 4 {
            let p = convert(event.locationInWindow, from: nil)
            petWeb?.evaluateJavaScript("pet.tap(\(p.x),\(bounds.height - p.y))", completionHandler: nil)
        }
        onMoved?()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = petMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
}

// MARK: - App

struct Character {
    let id: String
    let name: String
    let aspect: Double
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    var panel: PetPanel!
    var web: WKWebView!
    var statusItem: NSStatusItem!
    var timer: Timer?
    var hitBusy = false
    var loaded = false
    var characters: [Character] = []
    var currentID = ""
    var pending: [URL] = []
    var lastPointer = NSPoint(x: -1, y: -1)
    var idleTicks = 0
    var downloading = false
    let prefs = UserDefaults.standard
    let smoke = CommandLine.arguments.contains("--smoke-test")
    var smokeQueue: [String] = []

    var bubblesOn: Bool {
        get { prefs.object(forKey: "bubbles") == nil ? true : prefs.bool(forKey: "bubbles") }
        set { prefs.set(newValue, forKey: "bubbles") }
    }
    var aspect: Double { characters.first { $0.id == currentID }?.aspect ?? 0.82 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !smoke && !others.isEmpty { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(at: Paths.dataDir, withIntermediateDirectories: true)

        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(AssetHandler(bundleRoot: Paths.webDir, dataRoot: Paths.dataDir), forURLScheme: "petasset")
        config.userContentController.add(self, name: "pet")
        let frame = NSRect(x: 0, y: 0, width: 450, height: 620)
        web = WKWebView(frame: frame, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self

        panel = PetPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Live2D Buddy"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let container = NSView(frame: frame)
        web.autoresizingMask = [.width, .height]
        container.addSubview(web)
        let interaction = InteractionView(frame: frame)
        interaction.autoresizingMask = [.width, .height]
        interaction.petWeb = web
        interaction.petMenu = { [weak self] in self?.buildMenu() ?? NSMenu() }
        interaction.onMoved = { [weak self] in self?.savePosition() }
        container.addSubview(interaction)
        panel.contentView = container
        panel.ignoresMouseEvents = true // until the cursor is over opaque pixels

        let h = prefs.double(forKey: "height")
        setHeight(h > 0 ? h : 620)
        if let pos = prefs.array(forKey: "position") as? [Double], pos.count == 2 {
            panel.setFrameOrigin(NSPoint(x: pos[0], y: pos[1]))
            keepOnScreen()
        } else if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - panel.frame.width - 45, y: screen.visibleFrame.minY + 30))
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Live2D Buddy")
        statusItem.menu = buildMenu()

        web.load(URLRequest(url: URL(string: "petasset://app/index.html")!))
        panel.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.pointer() }
        if smoke { DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("SMOKE TIMEOUT"); exit(2) } }
    }

    // MARK: JS bridge

    /// Calls into the page with arguments passed as values, never spliced into source.
    func callJS(_ body: String, _ arguments: [String: Any] = [:]) {
        web?.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
            if case .failure(let error) = result { NSLog("Live2D Buddy JS error: \(error.localizedDescription)") }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "boot":
            callJS("await pet.init(opts)", ["opts": ["lang": isChinese ? "zh-CN" : "en", "bubbles": bubblesOn]])
        case "characters":
            let list = body["list"] as? [[String: Any]] ?? []
            characters = list.compactMap { item in
                guard let id = item["id"] as? String else { return nil }
                return Character(id: id, name: item["name"] as? String ?? id, aspect: (item["aspect"] as? NSNumber)?.doubleValue ?? 0.82)
            }
            let saved = prefs.string(forKey: "character") ?? ""
            var id = characters.contains { $0.id == saved } ? saved : (body["default"] as? String ?? characters.first?.id ?? "")
            if smoke {
                smokeQueue = characters.map(\.id)
                if smokeQueue.isEmpty { print("SMOKE FAIL no characters (run scripts/fetch-assets.sh)"); exit(3) }
                id = smokeQueue.removeFirst()
            }
            loadCharacter(id)
        case "hit": // up to 30×/s — keep this path cheap
            panel.ignoresMouseEvents = !(body["hit"] as? Bool ?? false)
        case "ready":
            loaded = true
            lastPointer = NSPoint(x: -1, y: -1)
            print("READY \(body)")
            flushPending()
            refreshMenu()
            if smoke { smokeStep() }
        case "error":
            print("RENDER ERROR \(body)")
            refreshMenu()
            if smoke { exit(3) }
        default:
            break
        }
    }

    func loadCharacter(_ id: String) {
        guard !id.isEmpty else { return }
        currentID = id
        if !smoke { prefs.set(id, forKey: "character") }
        loaded = false
        setHeight(panel.frame.height)
        callJS("pet.load(id)", ["id": id])
        refreshMenu()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.scheme == "petasset" ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        webView.reload() // recover instead of silently disappearing
    }

    // MARK: Pointer tracking (no Accessibility permission needed)

    func pointer() {
        guard loaded, panel.isVisible, !hitBusy else { return }
        let p = NSEvent.mouseLocation
        if p == lastPointer {
            idleTicks += 1
            if idleTicks % 10 != 0 { return } // cursor still: re-check ~3×/s instead of 30×/s
        } else {
            idleTicks = 0
        }
        lastPointer = p
        let x = p.x - panel.frame.minX, y = panel.frame.maxY - p.y
        hitBusy = true
        web.evaluateJavaScript("window.pet && pet.pointer(\(x),\(y))") { [weak self] _, _ in self?.hitBusy = false }
    }

    // MARK: Window geometry

    func setHeight(_ value: Double) {
        let available = NSScreen.main?.visibleFrame.height ?? 900
        let h = min(max(value, 360), available - 30)
        let old = panel.frame
        panel.setFrame(NSRect(x: old.minX, y: old.minY, width: (h - 70) * aspect, height: h), display: true)
        if !smoke { prefs.set(h, forKey: "height") }
        keepOnScreen()
        lastPointer = NSPoint(x: -1, y: -1)
    }

    func keepOnScreen() {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) }) ?? NSScreen.main else { return }
        let b = screen.visibleFrame
        var r = panel.frame
        r.origin.x = max(b.minX, min(r.origin.x, b.maxX - r.width))
        r.origin.y = max(b.minY, min(r.origin.y, b.maxY - r.height))
        panel.setFrame(r, display: true)
    }

    func savePosition() {
        if !smoke { prefs.set([panel.frame.origin.x, panel.frame.origin.y], forKey: "position") }
    }

    // MARK: URL scheme — live2dbuddy://<command>?<args>

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == urlScheme {
            if loaded { handle(url) } else if pending.count < 20 { pending.append(url) }
        }
    }

    func flushPending() {
        let queued = pending
        pending = []
        queued.forEach(handle)
    }

    func handle(_ url: URL) {
        NSLog("Live2D Buddy: received command %@", url.host ?? "?") // command name only, never the text
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        switch url.host ?? "" {
        case "say":
            let seconds = min(max(Double(query["duration"] ?? "") ?? 6.5, 1), 60)
            callJS("pet.say(text, ms, 9, true)", ["text": String((query["text"] ?? "").prefix(280)), "ms": seconds * 1000])
        case "react":
            callJS("pet.react(kind)", ["kind": query["kind"] ?? "tap"])
        case "event":
            callJS("pet.event(name, message)", ["name": query["name"] ?? "done", "message": String((query["message"] ?? "").prefix(280))])
        case "character":
            if let id = query["id"], characters.contains(where: { $0.id == id }) { loadCharacter(id) }
        case "show":
            if !panel.isVisible { toggleVisible() }
        case "hide":
            if panel.isVisible { toggleVisible() }
        default:
            NSLog("Live2D Buddy: unknown command \(url.absoluteString)")
        }
    }

    // MARK: Menu (status bar + right click)

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector?, tag: Int = 0, on: Bool = false, enabled: Bool = true, object: Any? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.state = on ? .on : .off
            item.isEnabled = enabled
            item.representedObject = object
            menu.addItem(item)
        }
        if characters.isEmpty { add(tr("（还没有角色）", "(no characters yet)"), nil, enabled: false) }
        for c in characters { add(c.name, #selector(chooseCharacter(_:)), on: c.id == currentID, object: c.id) }
        menu.addItem(.separator())
        add(tr("大一些", "Bigger"), #selector(resizePet(_:)), tag: 1)
        add(tr("小一些", "Smaller"), #selector(resizePet(_:)), tag: -1)
        add(tr("偶尔冒文字气泡", "Random bubbles"), #selector(toggleBubbles), on: bubblesOn)
        add(tr("说句话", "Say something"), #selector(saySomething))
        menu.addItem(.separator())
        add(downloading ? tr("正在下载示例角色…", "Downloading demo characters…") : tr("下载示例角色…", "Get demo characters…"),
            #selector(downloadAssets), enabled: !downloading)
        add(tr("打开资源文件夹", "Open assets folder"), #selector(openAssetsFolder))
        menu.addItem(.separator())
        add(panel?.isVisible == true ? tr("隐藏桌宠", "Hide pet") : tr("显示桌宠", "Show pet"), #selector(toggleVisible))
        add(tr("退出", "Quit"), #selector(quit))
        return menu
    }

    func refreshMenu() { statusItem?.menu = buildMenu() }

    @objc func chooseCharacter(_ item: NSMenuItem) {
        if let id = item.representedObject as? String { loadCharacter(id) }
    }

    @objc func resizePet(_ item: NSMenuItem) { setHeight(panel.frame.height + Double(item.tag) * 80) }

    @objc func toggleBubbles() {
        bubblesOn.toggle()
        callJS("pet.bubbles(on)", ["on": bubblesOn])
        refreshMenu()
    }

    @objc func saySomething() { callJS("pet.sayIdle()") }

    @objc func toggleVisible() {
        if panel.isVisible {
            panel.orderOut(nil)
            callJS("pet.visible(false)")
        } else {
            panel.orderFrontRegardless()
            callJS("pet.visible(true)")
        }
        refreshMenu()
    }

    @objc func openAssetsFolder() {
        try? FileManager.default.createDirectory(at: Paths.dataDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Paths.dataDir)
    }

    @objc func downloadAssets() {
        let alert = NSAlert()
        alert.messageText = tr("下载示例角色？", "Download the demo characters?")
        alert.informativeText = tr(
            "将从 jsDelivr / GitHub 下载 Live2D Cubism 2 运行库（© Live2D Inc.）和两个示例模型（来自 fghrsh/live2d_api：Nepgear © IDEA FACTORY / COMPILE HEART，Tia © Potion Maker）。\n\n它们是第三方作品，不属于本项目的开源许可；上游声明仅供学习与个人使用、不得商用。约 4 MB，每个文件都会校验 SHA-256。",
            "This downloads the Live2D Cubism 2 runtime (© Live2D Inc.) and two demo models from fghrsh/live2d_api (Nepgear © IDEA FACTORY / COMPILE HEART, Tia © Potion Maker) via jsDelivr / GitHub.\n\nThey are third-party works, not covered by this project's licence; upstream allows study and personal use only, no commercial use. About 4 MB, every file is verified against a pinned SHA-256.")
        alert.addButton(withTitle: tr("下载", "Download"))
        alert.addButton(withTitle: tr("取消", "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let script = Bundle.main.url(forResource: "fetch-assets", withExtension: "sh") else { return }

        downloading = true
        refreshMenu()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path, "--yes", "--quiet", "--dest", Paths.dataDir.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] proc in
            let log = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.downloading = false
                self.refreshMenu()
                if proc.terminationStatus == 0 {
                    self.loaded = false
                    self.web.reload()
                } else {
                    let failure = NSAlert()
                    failure.messageText = tr("下载失败", "Download failed")
                    failure.informativeText = String(log.suffix(600)) + tr("\n\n可在终端运行 scripts/fetch-assets.sh 查看详情，或用 --from 从本地导入。",
                                                                         "\n\nRun scripts/fetch-assets.sh in Terminal for details, or import a local copy with --from.")
                    NSApp.activate(ignoringOtherApps: true)
                    failure.runModal()
                }
            }
        }
        do { try process.run() } catch { downloading = false; refreshMenu() }
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: Smoke test (--smoke-test): every character renders, regions, bubbles, URL commands

    func smokeStep() {
        let id = currentID
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            let checks = """
            const r = pet.inspect().artwork;
            pet.tap(r.x + r.width / 2, r.y + r.height * .15);
            if (pet.inspect().lastRegion !== 'head') throw Error('head region failed');
            pet.tap(r.x + r.width / 2, r.y + r.height * .58);
            if (pet.inspect().lastRegion !== 'upper') throw Error('upper region failed');
            pet.bubbles(false);
            if (pet.inspect().bubbleVisible) throw Error('bubble toggle failed');
            pet.bubbles(true);
            return JSON.stringify(pet.inspect());
            """
            self.web.callAsyncJavaScript(checks, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value): print("DIAGNOSTIC \(id) \(value)")
                case .failure(let error): print("DIAGNOSTIC FAILED \(id) \(error)"); exit(4)
                }
                self.handle(URL(string: "\(urlScheme)://say?text=smoke%20ok&duration=3")!)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.web.evaluateJavaScript("pet.inspect().message") { value, _ in
                        guard (value as? String) == "smoke ok" else { print("URL COMMAND FAILED \(String(describing: value))"); exit(5) }
                        self.web.takeSnapshot(with: WKSnapshotConfiguration()) { image, _ in
                            if let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                               let png = rep.representation(using: .png, properties: [:]) {
                                let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("live2d-buddy-smoke-\(id).png")
                                try? png.write(to: out)
                                print("SNAPSHOT \(out.path)")
                            }
                            if self.smokeQueue.isEmpty {
                                print("SMOKE PASS \(self.characters.count) characters")
                                NSApp.terminate(nil)
                            } else {
                                self.loadCharacter(self.smokeQueue.removeFirst())
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Command-line client (`Live2DBuddy --cli …`, normally via bin/buddy)

enum CLI {
    static let usage = """
    Usage: buddy <command> [args] [--launch]

      say <text…> [--duration SEC]   show a speech bubble
      react [tap|success|fail|attention|thinking]
      event <done|attention|error|thinking> [message…]
      character <id>                 switch character
      show | hide | start | status
      hook claude [--preview]        read a Claude Code hook event (JSON on stdin)
      hook codex <json> [--preview]  handle a Codex `notify` payload

    Commands are ignored (exit 0) when the pet is not running, unless --launch is given.
    --dry-run prints the live2dbuddy:// URL instead of sending it.
    """

    static func fail(_ message: String, code: Int32 = 64) -> Int32 {
        FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
        return code
    }

    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    static func open(_ arguments: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = arguments
        do { try p.run() } catch { return fail("buddy: could not run /usr/bin/open: \(error)", code: 1) }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func url(_ command: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents()
        c.scheme = urlScheme
        c.host = command
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }

    /// Map a Claude Code hook payload to a pet event name (nil = ignore).
    static func claudeEvent(_ json: [String: Any], preview: Bool) -> (String, String)? {
        let name = json["hook_event_name"] as? String ?? ""
        let message: String
        switch name {
        case "Stop":
            message = preview ? (json["last_assistant_message"] as? String ?? "") : ""
            return ("done", message)
        case "Notification", "PermissionRequest":
            message = preview ? (json["message"] as? String ?? "") : ""
            return ("attention", message)
        case "StopFailure":
            return ("error", "")
        case "UserPromptSubmit":
            return ("thinking", "")
        default:
            return nil
        }
    }

    static func run(_ argv: [String]) -> Int32 {
        var args = argv
        let launch = args.contains("--launch")
        let preview = args.contains("--preview")
        let dryRun = args.contains("--dry-run")
        args.removeAll { $0 == "--launch" || $0 == "--preview" || $0 == "--dry-run" }
        var duration: String?
        if let i = args.firstIndex(where: { $0 == "--duration" || $0 == "-d" }), i + 1 < args.count {
            duration = args[i + 1]
            args.removeSubrange(i...(i + 1))
        }
        guard let command = args.first else { print(usage); return 64 }
        let rest = Array(args.dropFirst())

        let target: URL
        switch command {
        case "help", "-h", "--help":
            print(usage); return 0
        case "status":
            print(isRunning ? "running" : "not running"); return isRunning ? 0 : 1
        case "start":
            if isRunning { return 0 }
            return open(["-g", Bundle.main.bundlePath])
        case "say":
            guard !rest.isEmpty else { return fail("buddy say: missing text") }
            var q = ["text": rest.joined(separator: " ")]
            if let d = duration { q["duration"] = d }
            target = url("say", q)
        case "react":
            target = url("react", ["kind": rest.first ?? "tap"])
        case "event":
            guard let name = rest.first else { return fail("buddy event: missing name (done|attention|error|thinking)") }
            target = url("event", ["name": name, "message": rest.dropFirst().joined(separator: " ")])
        case "character":
            guard let id = rest.first else { return fail("buddy character: missing id") }
            target = url("character", ["id": id])
        case "show", "hide":
            target = url(command)
        case "hook":
            let source = rest.first ?? ""
            var event: (String, String)?
            if source == "claude" {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                event = claudeEvent(json, preview: preview)
            } else if source == "codex" {
                let payload = rest.dropFirst().last ?? "{}"
                let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] ?? [:]
                if json["type"] as? String == "agent-turn-complete" {
                    event = ("done", preview ? (json["last-assistant-message"] as? String ?? "") : "")
                }
            } else {
                return fail("buddy hook: expected 'claude' or 'codex'")
            }
            guard let (name, message) = event else { return 0 }
            let trimmed = message.replacingOccurrences(of: "\n", with: " ")
            target = url("event", ["name": name, "message": trimmed.count > 120 ? String(trimmed.prefix(117)) + "…" : trimmed])
        default:
            return fail("buddy: unknown command '\(command)'\n\n\(usage)")
        }

        if dryRun { print(target.absoluteString); return 0 }
        if isRunning { return open(["-g", target.absoluteString]) }
        if launch { return open(["-g", "-a", Bundle.main.bundlePath, target.absoluteString]) }
        FileHandle.standardError.write("buddy: Live2D Buddy is not running (add --launch to start it)\n".data(using: .utf8)!)
        return 0
    }
}

// MARK: - Entry point

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--cli") {
    exit(CLI.run(Array(arguments[(i + 1)...])))
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
