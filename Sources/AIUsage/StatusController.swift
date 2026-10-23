import AppKit
import Combine
import SwiftUI

/// Borderless, transparent panel so the SwiftUI glass is the only visible surface.
final class GlassPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 500),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // The window shadow is computed from the first, still-rectangular frame and shows up
        // as a dark box around the rounded glass; the glass draws its own soft edge instead.
        hasShadow = false
        level = .statusBar
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }
    override var canBecomeKey: Bool { true }
}

@MainActor
final class StatusController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel = GlassPanel()
    private let state: AppState
    private var hosting: NSHostingController<AnyView>!
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        super.init()

        hosting = NSHostingController(rootView: AnyView(PanelView().environmentObject(state)))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = .clear
        panel.contentViewController = hosting

        item.autosaveName = Self.autosaveName
        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        updateButton()

        state.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateButton() } }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: panel)
            .sink { [weak self] _ in self?.reposition() }
            .store(in: &cancellables)
    }

    /// Menu bar shows one colored ring per plan, filled by what's left of its 5-hour window:
    /// orange for Claude, green for Codex.
    private static let autosaveName = "AIUsage"

    /// macOS remembers each status item's spot as a distance from the right edge of the
    /// screen. Writing a huge distance before the item exists puts it leftmost, right
    /// after the app menus; it's rewritten on every launch so a drag elsewhere won't stick.
    static func pinLeftmost() {
        for name in [autosaveName, "Item-0"] {
            UserDefaults.standard.set(100_000, forKey: "NSStatusItem Preferred Position \(name)")
        }
    }

    private func updateButton() {
        guard let button = item.button else { return }
        let parts: [(String, Double?, NSColor)] = [
            ("Claude", state.claudeShortRemaining, NSColor(red: 1.0, green: 0.48, blue: 0.19, alpha: 1)),
            ("Codex", state.codexShortRemaining, NSColor(red: 0.30, green: 0.77, blue: 0.38, alpha: 1)),
        ]
        let shown = parts.compactMap { name, value, color in value.map { (name, $0, color) } }

        guard !shown.isEmpty else {
            button.attributedTitle = NSAttributedString()
            button.image = Self.ringImage(progress: 0, color: nil)
            button.toolTip = L("AI 用量", "AI Usage")
            return
        }

        button.image = nil
        let title = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        for (i, part) in shown.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
            let ring = NSTextAttachment()
            ring.image = Self.ringImage(progress: part.1 / 100, color: part.2)
            ring.bounds = CGRect(x: 0, y: -2.5, width: 14, height: 14)
            title.append(NSAttributedString(attachment: ring))
            title.append(NSAttributedString(string: " \(Int(part.1.rounded()))%",
                                            attributes: [.font: font, .foregroundColor: NSColor.labelColor]))
        }
        button.attributedTitle = title
        button.toolTip = shown.map { L("\($0.0) 5 小时剩余 \(Int($0.1.rounded()))%", "\($0.0): \(Int($0.1.rounded()))% of 5-hour limit left") }.joined(separator: "\n")
    }

    @objc func toggle() {
        panel.isVisible ? close() : open()
    }

    func open() {
        state.showingSettings = false
        reposition()
        panel.makeKeyAndOrderFront(nil)
        Task { await state.refresh() }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.close(); return nil }   // Esc
            return event
        }
    }

    func close() {
        panel.orderOut(nil)
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// Keeps the panel's top edge pinned just under the menu bar icon as its height changes.
    private func reposition() {
        guard let button = item.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let m = PanelView.margin
        var x = anchor.midX - size.width / 2
        x = min(max(x, screen.minX + 8 - m), screen.maxX - size.width - 8 + m)
        let y = anchor.minY - 6 - size.height + m
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// A nil color draws a template ring that follows the menu bar's own text color.
    static func ringImage(progress: Double, color: NSColor?) -> NSImage {
        let ink = color ?? .black
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            let lw: CGFloat = 2.4
            let r = rect.insetBy(dx: lw / 2 + 0.5, dy: lw / 2 + 0.5)
            let track = NSBezierPath(ovalIn: r)
            track.lineWidth = lw
            ink.withAlphaComponent(0.3).setStroke()
            track.stroke()

            let p = min(max(progress, 0), 1)
            guard p > 0 else { return true }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY), radius: r.width / 2,
                          startAngle: 90, endAngle: 90 - 360 * p, clockwise: true)
            arc.lineWidth = lw
            arc.lineCapStyle = .round
            ink.setStroke()
            arc.stroke()
            return true
        }
        image.isTemplate = color == nil
        return image
    }
}
