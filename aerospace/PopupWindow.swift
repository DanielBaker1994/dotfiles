import AppKit
import Foundation
import Darwin

// ============================================================================
// PopupWindow — a reusable AppKit popup framework.
//
// Everything about *building* a searchable popup window lives here:
//   - window/panel construction (borderless, nonactivating, shadow, blur)
//   - dimensions, colors, fonts (all via PopupConfig)
//   - search field + optional handlers (search / navigation / escape / toggle)
//   - row drawing (selection pill + title + optional icons + trailing text)
//
// The host app supplies rows and behavior through closures. No app-specific
// logic (aerospace, commands, icons-by-bundle) lives in this file.
// ============================================================================

// MARK: - Shared socket helpers (framework + host app both use these)

public func popupTmpDir() -> String {
    let t = ProcessInfo.processInfo.environment["TMPDIR"] ?? ""
    let d = t.isEmpty ? "/tmp/" : t
    return d.hasSuffix("/") ? d : d + "/"
}

public func makeUnixSockAddr(_ path: String) -> sockaddr_un {
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

// MARK: - Colors

public struct PopupColors {
    public var background: NSColor   // card fill (blur tinted by tintAlpha)
    public var border: NSColor       // card outline
    public var text: NSColor         // row titles + input text
    public var dim: NSColor          // secondary text (e.g. "+N")
    public var highlight: NSColor    // selected-row pill fill

    public init(background: NSColor = NSColor(srgbRed: 36/255, green: 39/255, blue: 58/255, alpha: 1),
                border: NSColor = NSColor(srgbRed: 159/255, green: 200/255, blue: 232/255, alpha: 1),
                text: NSColor = NSColor(srgbRed: 202/255, green: 211/255, blue: 245/255, alpha: 1),
                dim: NSColor = NSColor(srgbRed: 147/255, green: 154/255, blue: 183/255, alpha: 1),
                highlight: NSColor = NSColor(srgbRed: 63/255, green: 74/255, blue: 90/255, alpha: 1)) {
        self.background = background
        self.border = border
        self.text = text
        self.dim = dim
        self.highlight = highlight
    }
}

// MARK: - Config

public struct PopupConfig {
    // identity
    public var name: String           // used for the toggle socket + window title

    // window geometry (pts)
    public var width: CGFloat = 250
    public var rowHeight: CGFloat = 30
    public var padding: CGFloat = 8
    public var headerHeight: CGFloat = 30
    public var cornerRadius: CGFloat = 9

    // fonts (used by the framework's own input field + default row drawing)
    public var inputFontSize: CGFloat = 12
    public var rowFontSize: CGFloat = 11

    // appearance
    public var tintAlpha: CGFloat = 0.78            // card fill opacity over the blur
    public var material: NSVisualEffectView.Material = .hudWindow
    public var hasShadow: Bool = true
    public var colors: PopupColors = PopupColors()

    // optional behaviors (turn on/off at construction time)
    public var enableSearch: Bool = true            // input field + filtering
    public var enableNavigation: Bool = true        // Down/Up/Tab/ctrl+n/ctrl+p cycling
    public var enableEscape: Bool = true            // Esc dismiss (or onEscape hook)
    public var enableToggle: Bool = true            // Unix-socket toggle server
    public var dismissOnClickOff: Bool = true       // click outside hides
    public var dynamicHeight: Bool = false          // shrink window when filtering narrows rows

    public init(name: String) {
        self.name = name
    }
}

// MARK: - Row model

public protocol PopupRow {
    var title: String { get }
    var icons: [NSImage] { get }   // drawn after the title (optional)
    var trailing: String? { get }  // dim text after the icons (optional)
}

public extension PopupRow {
    var icons: [NSImage] { [] }
    var trailing: String? { nil }
}

// MARK: - Panel

public final class PopupPanel: NSPanel {
    public var onEscape: (() -> Void)?

    // Borderless windows can't become key by default; without this the popup
    // never gets focus (no caret, no keyboard input).
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    public override func cancelOperation(_ sender: Any?) {
        onEscape?()  // Esc even when the input field isn't first responder
    }

    public override func mouseDown(with event: NSEvent) {
        // clicking anywhere on the popup focuses the search field
        if let field = contentView?.subviews.compactMap({ $0 as? NSTextField }).first {
            makeFirstResponder(field)
        }
        super.mouseDown(with: event)
    }
}

// MARK: - Row view

// The framework knows row geometry (rowHeight) but NOT what a row looks like —
// that's the host app's business. If onDrawRow is set, the app renders each
// row rect itself (full control: pill, icons, anything). Otherwise a minimal
// generic default (highlight pill + title) is drawn.
final class PopupRowView: NSView {
    let config: PopupConfig
    var rows: [PopupRow] = []
    var selection = 0
    var onDrawRow: ((NSRect, PopupRow, Bool) -> Void)?

    override var isFlipped: Bool { true }

    init(config: PopupConfig) {
        self.config = config
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func draw(_ dirtyRect: NSRect) {
        var y: CGFloat = config.padding + config.headerHeight - 2
        for (i, row) in rows.enumerated() {
            let rect = NSRect(x: 0, y: y, width: config.width, height: config.rowHeight)
            if let onDrawRow {
                onDrawRow(rect, row, i == selection)
            } else {
                drawDefault(row, in: rect, selected: i == selection)
            }
            y += config.rowHeight
        }
    }

    // Minimal built-in rendering for hosts that don't customize rows.
    private func drawDefault(_ row: PopupRow, in rect: NSRect, selected: Bool) {
        if selected {
            let pill = NSRect(x: 5, y: rect.origin.y + 2,
                              width: config.width - 10,
                              height: config.rowHeight - 6)
            let p = NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6)
            config.colors.highlight.setFill()
            p.fill()
            config.colors.border.setStroke()
            p.lineWidth = 2
            p.stroke()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: config.rowFontSize),
            .foregroundColor: config.colors.text,
        ]
        let str = row.title as NSString
        let sz = str.size(withAttributes: attrs)
        let cy = rect.origin.y + config.rowHeight / 2
        str.draw(at: NSPoint(x: config.padding + 10, y: cy - sz.height / 2),
                 withAttributes: attrs)
    }
}

// Helper for drawing NSImages in a flipped (row) context — NSImage.draw(in:)
// mirrors vertically there, so flip the CTM around the rect's center first.
public func popupDrawImage(_ img: NSImage, in rect: NSRect) {
    guard let ctx = NSGraphicsContext.current else { return }
    ctx.saveGraphicsState()
    let t = NSAffineTransform()
    t.translateX(by: 0, yBy: rect.origin.y * 2 + rect.height)
    t.scaleX(by: 1, yBy: -1)
    t.concat()
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    ctx.restoreGraphicsState()
}

// MARK: - Popup window

public final class PopupWindow: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    public let config: PopupConfig

    // behavior hooks
    public var onFilter: ((String) -> [PopupRow])?   // query -> rows to display
    public var onAccept: ((PopupRow) -> Void)?       // Enter/Return on a row
    public var onEscape: (() -> Void)?               // Esc (overrides default hide)
    public var onHide: ((Bool) -> Void)?             // called after hide, with the restore flag
    // row rendering: if set, the app draws each row rect itself (pill, icons,
    // etc.); otherwise the framework draws a minimal generic default.
    public var onDrawRow: ((NSRect, PopupRow, Bool) -> Void)? {
        didSet { rowView.onDrawRow = onDrawRow }
    }

    public private(set) var rows: [PopupRow] = []
    public var selection = 0 {
        didSet {
            rowView.selection = selection
            rowView.needsDisplay = true
        }
    }
    public private(set) var isShown = false

    private let panel: PopupPanel
    private let field: NSTextField
    private let rowView: PopupRowView
    private var monitors: [Any] = []
    private var focusRetries = 0

    public init(config: PopupConfig) {
        self.config = config

        let initialHeight = config.padding * 2 + config.headerHeight + config.rowHeight
        panel = PopupPanel(contentRect: NSRect(x: 0, y: 0, width: config.width, height: initialHeight),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered,
                           defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = config.hasShadow
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.title = config.name

        // Backdrop: rounded container that clips a blurred material + tint,
        // for a sleek translucent look with real see-through corners.
        let backdrop = NSView(frame: NSRect(x: 0, y: 0, width: config.width, height: initialHeight))
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = config.cornerRadius
        backdrop.layer?.masksToBounds = true
        backdrop.layer?.borderWidth = 1
        backdrop.layer?.borderColor = config.colors.border.cgColor

        if config.tintAlpha > 0 {
            let fx = NSVisualEffectView(frame: backdrop.bounds)
            fx.material = config.material
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.autoresizingMask = [.width, .height]
            backdrop.addSubview(fx)
        }

        let tint = NSView(frame: backdrop.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor =
            config.colors.background.withAlphaComponent(config.tintAlpha).cgColor
        tint.autoresizingMask = [.width, .height]
        backdrop.addSubview(tint)

        rowView = PopupRowView(config: config)
        rowView.frame = backdrop.bounds
        rowView.autoresizingMask = [.width, .height]
        backdrop.addSubview(rowView)

        field = NSTextField(frame: NSRect(x: config.padding + 2, y: config.padding,
                                          width: config.width - 2 * config.padding - 4,
                                          height: 24))
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = config.enableSearch
        field.isSelectable = config.enableSearch
        field.font = NSFont.systemFont(ofSize: config.inputFontSize)
        field.textColor = config.colors.text
        field.alignment = .left
        field.focusRingType = .none
        rowView.addSubview(field)

        panel.contentView = backdrop

        super.init()
        panel.delegate = self
        panel.onEscape = { [weak self] in
            self?.handleEscape()
        }
        field.delegate = self
        panel.orderOut(nil)
    }

    // MARK: Lifecycle

    public func start() {
        if config.enableToggle {
            startToggleServer()
        }
    }

    public func show() {
        let initial = onFilter?("") ?? []
        setRows(initial)
        field.stringValue = ""

        let height = config.padding * 2 + config.headerHeight
            + CGFloat(rows.count) * config.rowHeight
        let origin = centeredOrigin(width: config.width, height: height)
        panel.setContentSize(NSSize(width: config.width, height: height))
        panel.setFrameOrigin(origin)
        rowView.frame = NSRect(x: 0, y: 0, width: config.width, height: height)
        rowView.needsDisplay = true

        isShown = true
        installMonitors()
        focusRetries = 0
        takeFocus()
    }

    public func hide(restore: Bool) {
        guard isShown else { return }
        isShown = false
        removeMonitors()
        panel.orderOut(nil)
        onHide?(restore)
    }

    public func toggle() {
        if isShown {
            hide(restore: true)
        } else {
            show()
        }
    }

    public func setRows(_ newRows: [PopupRow]) {
        rows = newRows
        if selection >= rows.count {
            selection = max(0, rows.count - 1)
        }
        rowView.rows = rows
        rowView.selection = selection
        rowView.needsDisplay = true
        if config.dynamicHeight, isShown {
            let height = config.padding * 2 + config.headerHeight
                + CGFloat(rows.count) * config.rowHeight
            panel.setContentSize(NSSize(width: config.width, height: height))
            rowView.frame = NSRect(x: 0, y: 0, width: config.width, height: height)
        }
    }

    public func clearInput() {
        field.stringValue = ""
    }

    // MARK: Focus

    private func takeFocus() {
        guard isShown else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        if !panel.isKeyWindow, focusRetries < 10 {
            focusRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.takeFocus()
            }
        }
    }

    // MARK: Event monitors

    private func installMonitors() {
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: {
            [weak self] event in
            guard let self, self.isShown else { return event }
            if self.handleKey(event.keyCode, event.modifierFlags) {
                return nil  // consumed
            }
            return event   // pass through (text input)
        }) {
            monitors.append(m)
        }
        if config.dismissOnClickOff,
           let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: {
            [weak self] event in
            guard let self, self.isShown else { return }
            let p = NSEvent.mouseLocation
            if !self.panel.frame.contains(p) {
                self.hide(restore: false)
            }
        }) {
            monitors.append(m)
        }
    }

    private func removeMonitors() {
        for m in monitors {
            NSEvent.removeMonitor(m)
        }
        monitors = []
    }

    // MARK: Keys

    private func handleKey(_ code: UInt16, _ mods: NSEvent.ModifierFlags) -> Bool {
        if config.enableNavigation {
            let ctrl = mods.contains(.control)
            switch (code, ctrl) {
            case (125, _): moveSelection(1); return true                          // Down
            case (126, _): moveSelection(-1); return true                         // Up
            case (48, _): moveSelection(mods.contains(.shift) ? -1 : 1); return true  // Tab
            case (45, true): moveSelection(1); return true                        // C-n
            case (35, true): moveSelection(-1); return true                       // C-p
            case (36, _), (38, true): acceptSelection(); return true              // Return / C-j
            default: break
            }
        }
        if config.enableEscape && code == 53 {
            handleEscape()
            return true
        }
        return false
    }

    private func moveSelection(_ delta: Int) {
        guard config.enableNavigation, rows.count > 0 else { return }
        selection = (selection + delta + rows.count) % rows.count
    }

    private func acceptSelection() {
        guard !rows.isEmpty else {
            hide(restore: true)
            return
        }
        onAccept?(rows[selection])
    }

    private func handleEscape() {
        if let onEscape {
            onEscape()
        } else {
            hide(restore: true)
        }
    }

    // MARK: NSTextFieldDelegate

    public func controlTextDidChange(_ obj: Notification) {
        guard config.enableSearch else { return }
        let q = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newRows = onFilter?(q) ?? []
        setRows(newRows)
    }

    // MARK: NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        if isShown {
            hide(restore: false)
        }
    }

    // MARK: Placement

    private func centeredOrigin(width: CGFloat, height: CGFloat) -> NSPoint {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main!
        let vis = screen.visibleFrame
        return NSPoint(x: vis.midX - width / 2, y: vis.midY - height / 2)
    }

    // MARK: Toggle server (name-scoped messages)

    private func startToggleServer() {
        let socketPath = popupTmpDir() + config.name + ".sock"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            unlink(socketPath)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            var addr = makeUnixSockAddr(socketPath)
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
                    let expected = "toggle \(self?.config.name ?? "")"
                    if msg.trimmingCharacters(in: .whitespacesAndNewlines) == expected {
                        DispatchQueue.main.async { self?.toggle() }
                    }
                }
            }
        }
    }
}

// MARK: - Toggle client

public func popupSocketPath(name: String) -> String {
    popupTmpDir() + name + ".sock"
}

@discardableResult
public func sendToggle(name: String) -> Bool {
    let path = popupSocketPath(name: name)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = makeUnixSockAddr(path)
    let ok = withUnsafePointer(to: &addr) { ptr -> Bool in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
        }
    }
    guard ok else { return false }
    let msg = "toggle \(name)\n"
    msg.withCString { _ = write(fd, $0, msg.count) }
    return true
}