import AppKit
import Foundation
import Darwin

// ============================================================================
// Workspace switcher — host app built on the PopupWindow framework.
// This file only contains app-specific logic: workspace/command data, the
// aerospace socket IPC, app icons, the persistent shell, and behavior hooks.
// ============================================================================

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

// MARK: - Focus file (captured by the launcher at keypress time)

let focusFilePath = popupTmpDir() + "workspace-switcher-focus"

func readFocusFile() -> (String?, pid_t?) {
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

// MARK: - Aerospace IPC (direct socket; falls back to spawning the CLI)

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
    var addr = makeUnixSockAddr(path)
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

// MARK: - Command palette (loaded once from commands.conf)

struct Command {
    let name: String
    let script: String
}

func loadCommands() -> [Command] {
    let path = binDir + "/commands.conf"
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        FileHandle.standardError.write(Data("ws: commands.conf missing — no command palette\n".utf8))
        return []
    }
    var cmds: [Command] = []
    for line in content.split(separator: "\n") {
        let s = line.trimmingCharacters(in: .whitespaces)
        if s.isEmpty || s.hasPrefix("#") { continue }
        guard let eq = s.firstIndex(of: "=") else { continue }
        let name = s[..<eq].trimmingCharacters(in: .whitespaces)
        let script = s[s.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if !name.isEmpty && !script.isEmpty {
            cmds.append(Command(name: name, script: script))
        }
    }
    return cmds
}

// Runs commands through a persistent bash (spawned once at startup) so
// executing a command never pays shell startup cost.
final class CommandRunner {
    private let proc: Process
    private let wFd: Int32
    private var output = ""
    private var pending: [String: (String) -> Void] = [:]
    private let q = DispatchQueue(label: "ws.command-runner")

    init?() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        let inp = Pipe()
        let outp = Pipe()
        p.standardInput = inp
        p.standardOutput = outp
        p.standardError = outp
        do { try p.run() } catch { return nil }
        proc = p
        wFd = inp.fileHandleForWriting.fileDescriptor
        let rFd = outp.fileHandleForReading.fileDescriptor
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buf = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(rFd, &buf, buf.count)
                if n <= 0 { return }
                self?.append(String(decoding: buf[..<n], as: UTF8.self))
            }
        }
    }

    func run(_ script: String, completion: @escaping (String) -> Void) {
        q.async { [weak self] in
            guard let self else { return }
            let token = "__WS_DONE_\(UUID().uuidString)__"
            self.pending[token] = completion
            let line = "( \(script) ; echo \"\(token)\" ) 2>&1\n"
            let data = Data(line.utf8)
            data.withUnsafeBytes { _ = write(self.wFd, $0.baseAddress, data.count) }
        }
    }

    private func append(_ s: String) {
        q.sync {
            output += s
            for (token, completion) in pending {
                if let range = output.range(of: token) {
                    let result = String(output[..<range.lowerBound])
                    output.removeSubrange(output.startIndex..<range.upperBound)
                    pending.removeValue(forKey: token)
                    DispatchQueue.main.async { completion(result) }
                }
            }
        }
    }
}

// MARK: - Icons

let appIconSize: CGFloat = 22

// Row rendering constants — these are the workspace switcher's own look; the
// framework knows nothing about them (rows are drawn via popup.onDrawRow).
let rowPillW: CGFloat = 240
let rowPillH: CGFloat = 24
let rowPillRadius: CGFloat = 6
let rowPillBorder: CGFloat = 2
let rowTextX: CGFloat = 18
let rowIconSize: CGFloat = 22
let rowIconX: CGFloat = 44
let rowIconStride: CGFloat = 26
let rowMaxIcons = 3

let missingIcon: NSImage = {
    let img = NSImage(size: NSSize(width: appIconSize, height: appIconSize))
    img.lockFocus()
    let rect = NSRect(x: 0, y: 0, width: appIconSize, height: appIconSize)
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
    s.draw(at: NSPoint(x: (appIconSize - sz.width) / 2, y: (appIconSize - sz.height) / 2),
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

// MARK: - Rows (framework PopupRow adapters)

struct WorkspaceRow: PopupRow {
    let title: String
    let icons: [NSImage]
    let trailing: String?

    init(ws: WorkspaceInfo, iconCache: inout [String: NSImage]) {
        title = ws.id
        var imgs: [NSImage] = []
        for app in ws.apps.prefix(rowMaxIcons) {
            let key = app.bundleID ?? app.name
            if let cached = iconCache[key] {
                imgs.append(cached)
            } else {
                let img = iconForApp(app)
                iconCache[key] = img
                imgs.append(img)
            }
        }
        icons = imgs
        let extra = ws.apps.count - rowMaxIcons
        trailing = extra > 0 ? "+\(extra)" : nil
    }
}

struct CommandRow: PopupRow {
    let title: String
    let command: Command
    init(_ c: Command) { title = "> \(c.name)"; command = c }
}

// MARK: - App controller (behavior hooks only; window logic lives in PopupWindow)

final class SwitcherController: NSObject {
    let popup: PopupWindow
    let commandRunner: CommandRunner?
    var workspaces: [WorkspaceInfo] = []
    var commands: [Command] = []
    var commandMode = false
    var workspaceSelection = 0
    var commandSelection = 0
    var savedWID: String?
    var savedPID: pid_t?
    private var iconCache: [String: NSImage] = [:]

    override init() {
        var config = PopupConfig(name: "workspace-switcher")
        config.colors = PopupColors(background: BAR, border: BORDER,
                                    text: TEXT, dim: DIM, highlight: GROUP_BG)
        popup = PopupWindow(config: config)
        commandRunner = CommandRunner()
        super.init()
        commands = loadCommands()

        popup.onFilter = { [weak self] query in
            self?.filter(query) ?? []
        }
        popup.onAccept = { [weak self] row in
            self?.accept(row)
        }
        popup.onEscape = { [weak self] in
            self?.handleEscape()
        }
        popup.onHide = { [weak self] restore in
            self?.restoreFocus(restore)
        }
        popup.onDrawRow = { [weak self] rect, row, selected in
            self?.drawRow(rect, row, selected)
        }
    }

    func start() {
        popup.start()
    }

    func show() {
        (savedWID, savedPID) = readFocusFile()
        workspaces = gatherWorkspaces()
        guard !workspaces.isEmpty else { return }
        commandMode = false
        workspaceSelection = 0
        commandSelection = 0
        popup.show()
    }

    // MARK: Hooks

    // Row rendering — the workspace switcher's own look (pill + title + app
    // icons + "+N"). The framework only hands us the row rect.
    private func drawRow(_ rect: NSRect, _ row: PopupRow, _ selected: Bool) {
        if selected {
            let pill = NSRect(x: (rect.width - rowPillW) / 2, y: rect.origin.y + 2,
                              width: rowPillW, height: rowPillH)
            let p = NSBezierPath(roundedRect: pill, xRadius: rowPillRadius,
                                 yRadius: rowPillRadius)
            GROUP_BG.setFill()
            p.fill()
            BORDER.setStroke()
            p.lineWidth = rowPillBorder
            p.stroke()
        }
        let cy = rect.origin.y + rowPillH / 2 + 2
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: TEXT,
        ]
        let title = row.title as NSString
        let ts = title.size(withAttributes: titleAttrs)
        title.draw(at: NSPoint(x: rowTextX, y: cy - ts.height / 2),
                   withAttributes: titleAttrs)
        var ix: CGFloat = rowIconX
        for img in row.icons {
            popupDrawImage(img, in: NSRect(x: ix, y: cy - rowIconSize / 2,
                                           width: rowIconSize, height: rowIconSize))
            ix += rowIconStride
        }
        if let trailing = row.trailing {
            let dimAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: DIM,
            ]
            let s = trailing as NSString
            let ss = s.size(withAttributes: dimAttrs)
            s.draw(at: NSPoint(x: ix + 2, y: cy - ss.height / 2),
                   withAttributes: dimAttrs)
        }
    }

    private func filter(_ query: String) -> [PopupRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.hasPrefix("/") {
            // command palette mode: search commands by what follows the slash
            if !commandMode {
                workspaceSelection = popup.selection
                commandMode = true
                popup.selection = commandSelection
            }
            let sub = String(q.dropFirst()).trimmingCharacters(in: .whitespaces)
            let cmds = sub.isEmpty
                ? commands
                : commands.filter { $0.name.lowercased().contains(sub) }
            if popup.selection >= cmds.count {
                popup.selection = max(0, cmds.count - 1)
            }
            return cmds.map { CommandRow($0) }
        }
        // workspace mode (slash removed or never typed)
        if commandMode {
            commandSelection = popup.selection
            commandMode = false
            popup.selection = workspaceSelection
        }
        let vis = q.isEmpty
            ? workspaces
            : workspaces.filter { ws in
                ws.id.lowercased().contains(q)
                    || ws.apps.contains { $0.name.lowercased().contains(q) }
            }
        if popup.selection >= vis.count {
            popup.selection = max(0, vis.count - 1)
        }
        return vis.map { WorkspaceRow(ws: $0, iconCache: &iconCache) }
    }

    private func accept(_ row: PopupRow) {
        if let cr = row as? CommandRow {
            popup.hide(restore: true)
            let cmd = cr.command
            commandRunner?.run(cmd.script) { out in
                FileHandle.standardError.write(
                    Data("ws: cmd '\(cmd.name)' -> \(out)\n".utf8))
            }
            return
        }
        if let wr = row as? WorkspaceRow {
            popup.hide(restore: false)
            _ = aerospaceCall(["workspace", wr.title])
        }
    }

    private func handleEscape() {
        if commandMode {
            // command menu is showing: drop back to the workspace view,
            // restoring the previous selection
            commandSelection = popup.selection
            commandMode = false
            popup.selection = workspaceSelection
            popup.clearInput()
            popup.setRows(workspaces.map { WorkspaceRow(ws: $0, iconCache: &iconCache) })
        } else {
            popup.hide(restore: true)
        }
    }

    private func restoreFocus(_ restore: Bool) {
        if restore, let pid = savedPID {
            NSRunningApplication(processIdentifier: pid)?.activate(
                options: [.activateAllWindows])
        }
        if restore, let wid = savedWID {
            _ = aerospaceCall(["focus", "--window-id", wid])
        }
        savedWID = nil
        savedPID = nil
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
            c.show()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}