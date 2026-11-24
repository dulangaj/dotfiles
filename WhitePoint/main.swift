import AppKit
import CoreGraphics
import ServiceManagement

/// Soft-knee curve: identity below the knee, then eases into `cap`, ending with slope 1/3
/// so near-whites stay distinguishable. Monotonic for caps from 0.5 to 1.
struct HighlightCurve {
    let cap: Float

    func callAsFunction(_ x: Float) -> Float {
        let knee = max(0, 1 - 3 * (1 - cap))
        guard x > knee, cap < 1 else { return x }
        let a = (1 - cap) / ((1 - knee) * (1 - knee))
        let t = x - knee
        return knee + t - a * t * t
    }
}

/// Applies the curve on top of each display's ColorSync calibration.
final class Dimmer {
    var cap: Float { didSet { scheduleApply() } }
    var isOn: Bool { didSet { isOn ? refresh() : restore() } }
    private var base: [CGDirectDisplayID: Table] = [:]
    private var expected: [CGDirectDisplayID: [Float]] = [:]
    private var applyPending = false

    typealias Table = (r: [Float], g: [Float], b: [Float])

    init(cap: Float, isOn: Bool) { self.cap = cap; self.isOn = isOn }

    static var displays: [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// Re-reads every display's calibration, then applies the curve.
    /// A read that still shows our own table (restore not yet visible) keeps the old base.
    func refresh() {
        CGDisplayRestoreColorSyncSettings()
        for display in Self.displays {
            let table = Self.read(display)
            if base[display] == nil || table.r != expected[display] { base[display] = table }
        }
        apply()
    }

    /// Recomputes from the cached calibration, so dragging the slider never flashes.
    func apply() {
        guard isOn else { return }
        let online = Self.displays
        guard online.allSatisfy({ base[$0] != nil }) else { return refresh() }
        expected = [:]
        for display in online { apply(to: display) }
    }

    /// A fast drag sends ~150 ticks a second; WindowServer applies one table per frame,
    /// so writing every tick backs it up and freezes the UI. Write at most once per 30 Hz frame.
    private func scheduleApply() {
        guard !applyPending else { return }
        applyPending = true
        RunLoop.main.add(Timer(timeInterval: 1.0 / 30, repeats: false) { [weak self] _ in
            self?.applyPending = false
            self?.apply()
        }, forMode: .common)
    }

    /// Re-applies if wake, a display change or anything else replaced our table.
    func reapplyIfReset() {
        if isOn, Self.displays.contains(where: { !matches($0) }) { refresh() }
    }

    func restore() {
        expected = [:]
        CGDisplayRestoreColorSyncSettings()
    }

    private static func read(_ display: CGDirectDisplayID) -> Table {
        let capacity = Int(CGDisplayGammaTableCapacity(display))
        var r = [Float](repeating: 0, count: capacity), g = r, b = r
        var count: UInt32 = 0
        CGGetDisplayTransferByTable(display, UInt32(capacity), &r, &g, &b, &count)
        return (Array(r.prefix(Int(count))), Array(g.prefix(Int(count))), Array(b.prefix(Int(count))))
    }

    private func apply(to display: CGDirectDisplayID) {
        guard let base = base[display], base.r.count > 1 else { expected[display] = []; return }
        let curve = HighlightCurve(cap: cap)
        func remap(_ t: [Float]) -> [Float] {
            let last = Float(t.count - 1)
            return t.indices.map { i in
                let x = curve(Float(i) / last) * last
                let lo = Int(x), hi = min(lo + 1, t.count - 1), f = x - Float(lo)
                return t[lo] * (1 - f) + t[hi] * f
            }
        }
        let r = remap(base.r)
        CGSetDisplayTransferByTable(display, UInt32(r.count), r, remap(base.g), remap(base.b))
        expected[display] = r
    }

    private func matches(_ display: CGDirectDisplayID) -> Bool {
        guard let want = expected[display] else { return false }
        let have = Self.read(display).r
        return want.isEmpty || (have.count == want.count && zip(have, want).allSatisfy { abs($0 - $1) < 0.002 })
    }

    /// Applies 75% white, reads the table back, then restores. Exit code 0 on pass.
    /// Read-back can't catch a display that ignores the table (the M5 Max bug).
    static func selfTest() -> Int32 {
        guard let display = displays.first else { print("FAIL: no display"); return 1 }
        CGDisplayRestoreColorSyncSettings()
        let before = read(display).r
        let dimmer = Dimmer(cap: 0.75, isOn: true)
        dimmer.refresh()
        let after = read(display).r
        defer { dimmer.restore() }
        let n = after.count - 1
        let dark = after[n / 5] - before[n / 5]
        let white = after[n] - before[Int((0.75 * Float(n)).rounded())]
        print(String(format: "display %u, %d entries: 20%% grey moved %.4f, white off target by %.4f", display, after.count, dark, white))
        let ok = abs(dark) < 0.002 && abs(white) < 0.005 && dimmer.matches(display)
        print(ok ? "PASS" : "FAIL")
        return ok ? 0 : 1
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let defaults = UserDefaults.standard
    private lazy var dimmer = Dimmer(
        cap: defaults.object(forKey: "cap") as? Float ?? 0.75,
        isOn: defaults.object(forKey: "on") as? Bool ?? true)
    private let toggle = NSMenuItem(title: "", action: #selector(toggled), keyEquivalent: "")
    private let login = NSMenuItem(title: "Open at Login", action: #selector(loginToggled), keyEquivalent: "")
    private var timer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        let slider = NSSlider(value: Double(dimmer.cap), minValue: 0.5, maxValue: 1, target: self, action: #selector(slid(_:)))
        slider.frame = NSRect(x: 16, y: 0, width: 200, height: 28)
        let row = NSView(frame: NSRect(x: 0, y: 0, width: 232, height: 28))
        row.addSubview(slider)
        let sliderItem = NSMenuItem()
        sliderItem.view = row
        let menu = NSMenu()
        [toggle, sliderItem, .separator(), login, .separator()].forEach(menu.addItem)
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        [toggle, login].forEach { $0.target = self }
        menu.delegate = self
        item.menu = menu

        // Screen parameters also change with EDR headroom on XDR panels, so only re-apply when
        // our table is gone; an unconditional refresh can loop with its own writes.
        let reapply: (Notification) -> Void = { [dimmer] _ in dimmer.reapplyIfReset() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: reapply)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: reapply)
        timer = .scheduledTimer(withTimeInterval: 2, repeats: true) { [dimmer] _ in dimmer.reapplyIfReset() }
        timer?.tolerance = 1

        if dimmer.isOn { dimmer.refresh() }
        updateTitle()
        updateToggle()
    }

    func menuWillOpen(_ menu: NSMenu) {
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// Title shows the reduction, as iOS does. The only thing changed while dragging.
    private func updateTitle() {
        toggle.title = "Reduce White Point  \(Int(((1 - dimmer.cap) * 100).rounded()))%"
    }

    private func updateToggle() {
        toggle.state = dimmer.isOn ? .on : .off
        item.button?.image = NSImage(systemSymbolName: dimmer.isOn ? "sun.min" : "sun.max", accessibilityDescription: "Reduce White Point")
    }

    @objc private func slid(_ slider: NSSlider) {
        dimmer.cap = slider.floatValue
        defaults.set(slider.floatValue, forKey: "cap")
        updateTitle()
    }

    @objc private func toggled() {
        dimmer.isOn.toggle()
        defaults.set(dimmer.isOn, forKey: "on")
        updateToggle()
    }

    @objc private func loginToggled() {
        let service = SMAppService.mainApp
        do {
            try service.status == .enabled ? service.unregister() : service.register()
        } catch {
            NSLog("WhitePoint: Open at Login failed: \(error)")
        }
        login.state = service.status == .enabled ? .on : .off
    }

    func applicationWillTerminate(_ note: Notification) { dimmer.restore() }
}

if CommandLine.arguments.contains("--selftest") { exit(Dimmer.selfTest()) }
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
