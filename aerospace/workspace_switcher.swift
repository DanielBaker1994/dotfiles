import AppKit
import Foundation
import Darwin

// MARK: - Layout constants (mirrors the Python/Tk switcher for identical look)

let ROW_H: CGFloat = 30
let PAD: CGFloat = 8
let WIDTH: CGFloat = 250
let PILL_W: CGFloat = 240    // selected-row highlight width (centered)
let PILL_H: CGFloat = ROW_H - 6
let PILL_RADIUS: CGFloat = 6
let PILL_BORDER: CGFloat = 2
let RADIUS: CGFloat = 9
let ICON_SIZE: CGFloat = 22
let ICON_STRIDE: CGFloat = 26
let TEXT_X: CGFloat = PAD + 10
let ICON_X0: CGFloat = PAD + 36
let ROW_TOP: CGFloat = PAD + 28
let HEADER_H: CGFloat = 30
let MAX_ICONS = 3

// MARK: - Colors (parsed from sketchybar colors.sh + aerospacer.sh)

let binDir: String = {
    let u = URL(fileURLWithPath: CommandLine.arguments[0]).absoluteURL
    return u.deletingLastPathComponent().path
}()

let dotfilesDir: String = (binDir as NSString).deletingLastPathComponent

func parseColors() -> [String: NSColor] {
    var out: [String: NSColor] = [:]
    let sources = [
        dotfilesDir + "/sketchybar/colors.sh",
        dotfilesDir + "/sketchybar/plugins/aerospacer.sh",
    ]
    for path in sources {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        let ns = content as NSString
        let regex = try! NSRegularExpression(
            pattern: "^([A-Z_]+)=0x([0-9a-fA-F]{8})",
            options: [.anchorsMatchLines])
        for m in regex.matches(in: content, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: m.range(at: 1))
            let hex = ns.substring(with: m.range(at: 2))
            var v: UInt64 = 0
            Scanner(string: hex).scanHexInt64(&v)
            // 0xAARRGGBB — alpha ignored (matches the Python build's opaque look)
            let r = Double((v >> 16) & 0xFF) / 255.0
            let g = Double((v >> 8) & 0xFF) / 255.0
            let b = Double(v & 0xFF) / 255.0
            out[key] = NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        }
    }
    return out
}

let C = parseColors()
let BAR = C["BAR_COLOR"] ?? NSColor.black
let GROUP_BG = C["GROUP_BG_COLOR"] ?? NSColor.gray
let TEXT = C["WHITE"] ?? NSColor.white
let DIM = C["GREY"] ?? NSColor.gray
let BORDER = C["SPACE_BORDER_COLOR"] ?? NSColor.white

// MARK: - Tmp dir + IPC paths (per-user, matches the launcher)

func tmpDir() -> String {
    let t = ProcessInfo.processInfo.environment["TMPDIR"] ?? ""
    let d = t.isEmpty ? "/tmp/" : t
    return d.hasSuffix("/") ? d : d + "/"
}

let toggleSocketPath = tmpDir() + "workspace-switcher.sock"
let focusFilePath = tmpDir() + "workspace-switcher-focus"

// MARK: - Aerospace IPC (direct socket; falls back to spawning the CLI)

func makeSockAddr(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let chars = path.utf8CString
    let count = min(chars.count, MemoryLayout.size(ofValue: addr.sun_path))
    withUnsafeMutableBytes(of: &addr.sun_path) { dest in
        chars.withUnsafeBufferPointer { src in
            dest.baseAddress?.copyMemory(from: src.baseAddress!, byteCount: count)
        }
    }
    return addr
}

func writeUInt32(_ fd: Int32, _ v: UInt32) {
    var v = v.littleEndian
    _ = write(fd, &v, 4)
}

func readN(_ fd: Int32, _ n: Int) -> Data? {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while data.count < n {
        let got = read(fd, &buf, min(buf.count, n - data.count))
        if got <= 0 { return nil }
        data.append(buf, count: got)
    }
    return data
}

func readUInt32(_ fd: Int32) -> UInt32? {
    guard let d = readN(fd, 4) else { return nil }
    return d.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
}

func aerospaceSocket(_ args: [String]) -> String? {
    let path = "/tmp/bobko.aerospace-\(NSUserName()).sock"
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var addr = makeSockAddr(path)
    let ok = withUnsafePointer(to: &addr) { ptr -> Bool in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
    guard ok else { return nil }
    writeUInt32(fd, 1)
    guard readUInt32(fd) != nil else { return nil }
    let payload: [String: Any] = [
        "args": args, "stdin": "", "windowId": NSNull(), "workspace": NSNull(),
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    writeUInt32(fd, UInt32(data.count))
    data.withUnsafeBytes { _ = write(fd, $0.baseAddress, data.count) }
    guard let len = readUInt32(fd), let body = readN(fd, Int(len)) else { return nil }
    guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
    return obj["stdout"] as? String ?? ""
}

func aerospaceFallback(_ args: [String]) -> String {
    let candidates = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace", "aerospace"]
    for c in candidates {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: c)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { continue }
        p.waitUntilExit()
        if p.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
    return ""
}

func aerospaceCall(_ args: [String]) -> String {
    aerospaceSocket(args) ?? aerospaceFallback(args)
}

// MARK: - Data model

struct AppInfo {
    let name: String
    let bundleID: String?
}

struct WorkspaceInfo {
    let id: String
    var apps: [AppInfo]
}

func gatherWorkspaces() -> [WorkspaceInfo] {
    let order = aerospaceCall(["list-workspaces", "--all"])
        .split(separator: "\n").map(String.init)
    var dict = Dictionary(uniqueKeysWithValues: order.map { ($0, WorkspaceInfo(id: $0, apps: [])) })
    let wins = aerospaceCall([
        "list-windows", "--all",
        "--format", "%{app-name}|%{app-bundle-id}|%{workspace}",
    ])
    for line in wins.split(separator: "\n") {
        let parts = line.split(separator: "|").map(String.init)
        guard parts.count == 3, var ws = dict[parts[2]] else { continue }
        ws.apps.append(AppInfo(name: parts[0], bundleID: parts[1].isEmpty ? nil : parts[1]))
        dict[parts[2]] = ws
    }
    // letters (alphabetical) first, then numbers (numeric)
    return order.compactMap { dict[$0] }.sorted { a, b in
        let an = Int(a.id), bn = Int(b.id)
        switch (an, bn) {
        case (nil, nil): return a.id.localizedCaseInsensitiveCompare(b.id) == .orderedAscending
        case (nil, .some): return true   // letter before number
        case (.some, nil): return false
        case (.some, .some): return an! < bn!
        }
    }
}

// MARK: - Icons

let missingIcon: NSImage = {
    let img = NSImage(size: NSSize(width: ICON_SIZE, height: ICON_SIZE))
    img.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: ICON_SIZE, height: ICON_SIZE)
    let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
    GROUP_BG.setFill()
    path.fill()
    BORDER.setStroke()
    path.lineWidth = 1
    path.stroke()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 14), .foregroundColor: TEXT,
    ]
    let s = "?" as NSString
    let sz = s.size(withAttributes: attrs)
    s.draw(at: NSPoint(x: (ICON_SIZE - sz.width) / 2, y: (ICON_SIZE - sz.height) / 2),
           withAttributes: attrs)
    img.unlockFocus()
    return img
}()

let appDirs = [
    "/Applications", "/Applications/Utilities",
    "/System/Applications", "/System/Applications/Utilities",
    "/System/Library/CoreServices",
    NSHomeDirectory() + "/Applications",
]

func iconForApp(_ app: AppInfo) -> NSImage {
    var url: URL?
    if let bid = app.bundleID {
        url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
    }
    if url == nil {
        for dir in appDirs where FileManager.default.fileExists(
            atPath: dir + "/" + app.name + ".app") {
            url = URL(fileURLWithPath: dir + "/" + app.name + ".app")
            break
        }
    }
    if let url { return NSWorkspace.shared.icon(forFile: url.path) }
    return missingIcon
}

// MARK: - Filter text field

final class FilterField: NSTextField {
    var onKeyDown: ((UInt16, NSEvent.ModifierFlags) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let handled = onKeyDown?(event.keyCode, event.modifierFlags) ?? false
        if !handled { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        _ = onKeyDown?(53, [])  // Escape
    }
}

// MARK: - Window (borderless but key-capable)

final class SwitcherWindow: NSPanel {
    var onCancel: (() -> Void)?

    // Borderless windows can't become key by default; without this the popup
    // never gets focus (no caret, no keyboard input).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()  // Esc even when the filter field isn't first responder
    }

    override func mouseDown(with event: NSEvent) {
        // clicking anywhere on the popup focuses the search field
        if let field = contentView?.subviews.compactMap({ $0 as? NSTextField }).first {
            makeFirstResponder(field)
        }
        super.mouseDown(with: event)
    }
}

// MARK: - Card view (rows drawn with Core Graphics)

final class CardView: NSView {
    var workspaces: [WorkspaceInfo] = []
    var visible: [WorkspaceInfo] = []
    var selection = 0
    var iconCache: [String: NSImage] = [:]

    override var isFlipped: Bool { true }

    private func icon(_ app: AppInfo) -> NSImage {
        let key = app.bundleID ?? app.name
        if let cached = iconCache[key] { return cached }
        let img = iconForApp(app)
        iconCache[key] = img
        return img
    }

    // NSImage.draw(in:) mirrors images vertically inside a flipped view, so
    // flip the CTM around the target rect's vertical center first.
    private func drawImage(_ img: NSImage, in rect: NSRect) {
        guard let ctx = NSGraphicsContext.current else { return }
        ctx.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: 0, yBy: rect.origin.y * 2 + rect.height)
        t.scaleX(by: 1, yBy: -1)
        t.concat()
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        ctx.restoreGraphicsState()
    }

    override func draw(_ dirtyRect: NSRect) {
        var y: CGFloat = ROW_TOP
        for (i, ws) in visible.enumerated() {
            if i == selection {
                let pill = NSRect(x: (WIDTH - PILL_W) / 2, y: y + 2,
                                  width: PILL_W, height: PILL_H)
                let p = NSBezierPath(roundedRect: pill, xRadius: PILL_RADIUS,
                                     yRadius: PILL_RADIUS)
                GROUP_BG.setFill()
                p.fill()
                BORDER.setStroke()
                p.lineWidth = PILL_BORDER
                p.stroke()
            }
            let cy = y + PILL_H / 2 + 2
            let titleAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: TEXT,
            ]
            let title = ws.id as NSString
            let ts = title.size(withAttributes: titleAttrs)
            title.draw(at: NSPoint(x: TEXT_X, y: cy - ts.height / 2),
                       withAttributes: titleAttrs)
            var ix: CGFloat = ICON_X0
            for app in ws.apps.prefix(MAX_ICONS) {
                let img = icon(app)
                drawImage(img, in: NSRect(x: ix, y: cy - ICON_SIZE / 2,
                                          width: ICON_SIZE, height: ICON_SIZE))
                ix += ICON_STRIDE
            }
            let extra = ws.apps.count - MAX_ICONS
            if extra > 0 {
                let dimAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: DIM,
                ]
                let s = "+\(extra)" as NSString
                let ss = s.size(withAttributes: dimAttrs)
                s.draw(at: NSPoint(x: ix + 2, y: cy - ss.height / 2),
                       withAttributes: dimAttrs)
            }
            y += ROW_H
        }
    }
}

// MARK: - Controller

final class SwitcherController: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    let window: SwitcherWindow
    let cardView: CardView
    let filterField: FilterField
    var workspaces: [WorkspaceInfo] = []
    var visible: [WorkspaceInfo] = []
    var selection = 0
    var savedWID: String?
    var savedPID: pid_t?
    var shown = false
    var focusRetries = 0
    var keyMonitor: Any?
    var mouseMonitor: Any?

    override init() {
        window = SwitcherWindow(contentRect: NSRect(x: 0, y: 0, width: WIDTH, height: 200),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered,
                                defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.title = "workspace-switcher"

        // Backdrop: rounded container that clips a blurred material + BAR
        // tint, so the popup gets a sleek translucent look with real
        // see-through corners (and a drop shadow from the panel).
        let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: WIDTH, height: 200))
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = RADIUS
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = BORDER.cgColor

        let fx = NSVisualEffectView(frame: backdrop.bounds)
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.autoresizingMask = [.width, .height]
        backdrop.addSubview(fx)

        let tint = NSView(frame: backdrop.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = BAR.withAlphaComponent(0.78).cgColor
        tint.autoresizingMask = [.width, .height]
        backdrop.addSubview(tint)

        cardView = CardView(frame: backdrop.bounds)
        cardView.autoresizingMask = [.width, .height]
        backdrop.addSubview(cardView)
        window.contentView = backdrop

        filterField = FilterField(frame: NSRect(x: PAD + 2, y: PAD,
                                                width: WIDTH - 2 * PAD - 4, height: 24))
        filterField.isBezeled = false
        filterField.drawsBackground = false
        filterField.isEditable = true
        filterField.isSelectable = true
        filterField.font = NSFont.systemFont(ofSize: 12)
        filterField.textColor = TEXT
        filterField.alignment = .left
        filterField.focusRingType = .none
        cardView.addSubview(filterField)

        super.init()
        window.delegate = self
        window.onCancel = { [weak self] in
            self?.hide(restore: true)
        }
        filterField.delegate = self
        filterField.onKeyDown = { [weak self] code, mods in
            self?.handleKey(code, mods) ?? false
        }
        window.orderOut(nil)
    }

    func start() {
        startToggleServer()
    }

    // MARK: Toggle server (background thread, message "toggle\n")

    private func startToggleServer() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            unlink(toggleSocketPath)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            var addr = makeSockAddr(toggleSocketPath)
            let bound = withUnsafePointer(to: &addr) { ptr -> Bool in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
                }
            }
            guard bound else { close(fd); return }
            listen(fd, 4)
            while true {
                let cfd = accept(fd, nil, nil)
                guard cfd >= 0 else { continue }
                var buf = [UInt8](repeating: 0, count: 128)
                let n = read(cfd, &buf, buf.count)
                close(cfd)
                if n > 0 {
                    let msg = String(bytes: buf[..<n], encoding: .utf8) ?? ""
                    if msg.contains("toggle") {
                        DispatchQueue.main.async { self?.toggle() }
                    }
                }
            }
        }
    }

    // MARK: Toggle / show / hide

    func toggle() {
        if shown {
            hide(restore: true)
        } else {
            show()
        }
    }

    func show() {
        // consume focus info captured by the launcher at keypress time
        (savedWID, savedPID) = readFocusFile()
        workspaces = gatherWorkspaces()
        guard !workspaces.isEmpty else { return }
        visible = workspaces
        selection = 0
        filterField.stringValue = ""
        cardView.workspaces = workspaces
        cardView.visible = visible
        cardView.selection = 0

        let height = PAD * 2 + HEADER_H + CGFloat(workspaces.count) * ROW_H
        let origin = centeredOrigin(width: WIDTH, height: height)
        window.setContentSize(NSSize(width: WIDTH, height: height))
        window.setFrameOrigin(origin)
        cardView.frame = NSRect(x: 0, y: 0, width: WIDTH, height: height)
        cardView.needsDisplay = true

        shown = true
        // The field editor swallows most keys before our NSTextField override,
        // so intercept navigation keys with a local event monitor (the
        // standard command-palette approach) and let text pass through.
        installKeyMonitor()
        focusRetries = 0
        takeFocus()
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.shown else { return event }
            if self.handleKey(event.keyCode, event.modifierFlags) {
                return nil  // consumed
            }
            return event   // pass through (text input for filtering)
        }
        // Clicking anywhere outside the popup dismisses it (standard launcher
        // behavior). The nonactivating panel never resigns key on its own, so
        // watch for global mouse-downs outside our frame.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] event in
            guard let self, self.shown else { return }
            let p = NSEvent.mouseLocation
            if !self.window.frame.contains(p) {
                self.hide(restore: false)
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
        if let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
    }

    private func takeFocus() {
        guard shown else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(filterField)
        if !window.isKeyWindow, focusRetries < 10 {
            focusRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.takeFocus()
            }
        }
    }

    func hide(restore: Bool) {
        guard shown else { return }
        shown = false
        removeKeyMonitor()
        window.orderOut(nil)
        if restore {
            if let pid = savedPID {
                NSRunningApplication(processIdentifier: pid)?.activate(
                    options: [.activateAllWindows])
            }
            if let wid = savedWID {
                _ = aerospaceCall(["focus", "--window-id", wid])
            }
        }
        savedWID = nil
        savedPID = nil
        shown = false
    }

    private func readFocusFile() -> (String?, pid_t?) {
        guard let content = try? String(contentsOfFile: focusFilePath, encoding: .utf8)
        else { return (nil, nil) }
        try? FileManager.default.removeItem(atPath: focusFilePath)
        let parts = content.split(separator: " ")
        guard let wid = parts.first, parts.count > 1,
              let pid = Int32(parts[1]) else {
            return parts.first.map { (String($0), nil) } ?? (nil, nil)
        }
        return (String(wid), pid)
    }

    private func centeredOrigin(width: CGFloat, height: CGFloat) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        let vis = screen.visibleFrame
        return NSPoint(x: vis.midX - width / 2, y: vis.midY - height / 2)
    }

    // MARK: Navigation / actions

    private func handleKey(_ code: UInt16, _ mods: NSEvent.ModifierFlags) -> Bool {
        let ctrl = mods.contains(.control)
        switch (code, ctrl) {
        case (125, _): moveSelection(1); return true              // Down
        case (126, _): moveSelection(-1); return true             // Up
        case (48, _): moveSelection(mods.contains(.shift) ? -1 : 1); return true  // Tab
        case (45, true): moveSelection(1); return true            // C-n
        case (35, true): moveSelection(-1); return true           // C-p
        case (36, _), (38, true): jump(); return true             // Return / C-j
        case (53, _): hide(restore: true); return true            // Escape
        default: return false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !visible.isEmpty else { return }
        selection = (selection + delta + visible.count) % visible.count
        cardView.selection = selection
        cardView.needsDisplay = true
    }

    private func jump() {
        guard !visible.isEmpty else { hide(restore: true); return }
        let sid = visible[selection].id
        hide(restore: false)
        _ = aerospaceCall(["workspace", sid])
    }

    // MARK: NSWindowDelegate

    // Clicking anywhere outside the popup dismisses it (standard launcher
    // behavior). Don't restore focus here — the app the user clicked already
    // has it; restoring would yank focus away from their click.
    func windowDidResignKey(_ notification: Notification) {
        if shown {
            hide(restore: false)
        }
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        let q = filterField.stringValue
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            visible = workspaces
        } else {
            visible = workspaces.filter { ws in
                ws.id.lowercased().contains(q)
                    || ws.apps.contains { $0.name.lowercased().contains(q) }
            }
        }
        if selection >= visible.count {
            selection = max(0, visible.count - 1)
        }
        cardView.visible = visible
        cardView.selection = selection
        cardView.needsDisplay = true
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: SwitcherController?
    let showOnLaunch: Bool

    init(showOnLaunch: Bool) {
        self.showOnLaunch = showOnLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let c = SwitcherController()
        controller = c
        c.start()
        if showOnLaunch {
            // launched fresh: show the popup right away (launcher sent "show")
            c.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

// MARK: - Entry point

func toggleClient() -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = makeSockAddr(toggleSocketPath)
    let ok = withUnsafePointer(to: &addr) { ptr -> Bool in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
    guard ok else { return false }
    let msg = "toggle\n"
    msg.withCString { _ = write(fd, $0, msg.count) }
    return true
}

let cliArgs = CommandLine.arguments
if cliArgs.count > 1 && cliArgs[1] == "toggle" {
    exit(toggleClient() ? 0 : 1)
}
let showOnLaunch = cliArgs.count > 1 && cliArgs[1] == "show"

let app = NSApplication.shared
let delegate = AppDelegate(showOnLaunch: showOnLaunch)
app.delegate = delegate
app.run()
