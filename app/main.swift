// Mac mini VPN — a menu-bar switch that sends a few Japanese sites through a Mac at home in Japan.
//
// This app only switches routing on and off (by running `mmvpn up` / `mmvpn down`) and shows
// whether it works. The tunnel itself is kept open by `mmvpn-tunnel` under launchd, which also
// repairs it, so quitting the app changes nothing.
//
// WHAT "ON" MEANS: the system's automatic-proxy URL points at our PAC file. That is the one setting
// `mmvpn up` writes and `mmvpn down` clears. Reading "on" from whether the SOCKS port answers made the
// icon flicker to "off" every time the tunnel was rebuilt.
//
// WHY "ABEMA ACCEPTS" AND NOT "CONNECTED": a data-centre address can be located in Japan and still be
// refused, so the health shown is ABEMA's own region verdict through the tunnel, not "something
// listens on the port". One failed check does not change what is shown; two in a row do (`fold`).
//
// LOOK
//   * Icon: a rounded box with one lamp (green on, red off, orange on a problem), drawn on whole
//     pixels so it stays sharp on a 1x display. Its outline follows the menu bar's light/dark look.
//   * Menu: one panel with a switch, a status line that is always exactly one line, and the sites.
//     Its size never changes and it is updated in place while open.
//   * `MacminiVPN --render <dir>` draws every state to PNGs (1x and 2x, light and dark);
//     `MacminiVPN --selftest` checks the state rules and the drawing without touching the system.

import AppKit

let ENV = ProcessInfo.processInfo.environment
let CONF_DIR = ENV["MMVPN_CONFIG_DIR"] ?? NSString(string: "~/.config/macmini-vpn").expandingTildeInPath

/// KEY=value lines of the shell config the installer and the scripts share (quotes stripped).
func readConfig(_ path: String) -> [String: String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
    var out: [String: String] = [:]
    for raw in text.split(separator: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
        let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
        var val = String(line[line.index(after: eq)...])
        if let hash = val.range(of: " #") { val = String(val[..<hash.lowerBound]) }
        val = val.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        out[key] = val
    }
    return out
}
let CONF = readConfig(CONF_DIR + "/config")
let CTL = ENV["MMVPN_CTL"] ?? NSString(string: "~/.local/bin/mmvpn").expandingTildeInPath
let PAC_URL = "http://127.0.0.1:\(CONF["PAC_PORT"] ?? "1081")/jp.pac"   // what `mmvpn up` sets
let PROXY_PORT = UInt16(CONF["SOCKS_PORT"] ?? "") ?? 1082                // the tunnel's SOCKS port
let SITES = ["Netflix", "ABEMA", "TVer", "radiko", "NHK"]               // the sites jp.pac lists
let UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
         "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"

/// Run a command and return (exit status, stdout). The timeout is real: output is drained on a
/// background queue so the wait can be abandoned, which the first version could not do.
/// A status of -2 means it timed out, kept distinct from a genuine non-zero exit.
@discardableResult
func sh(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()

    let lock = NSLock()
    var buf = Data()
    let done = DispatchSemaphore(value: 0)
    pipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        if d.isEmpty { h.readabilityHandler = nil; done.signal() }
        else { lock.lock(); buf.append(d); lock.unlock() }
    }
    do { try p.run() } catch { return (-1, "") }

    if done.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.lock(); let partial = String(data: buf, encoding: .utf8) ?? ""; lock.unlock()
        return (-2, partial)
    }
    p.waitUntilExit()
    lock.lock(); let out = String(data: buf, encoding: .utf8) ?? ""; lock.unlock()
    return (p.terminationStatus, out)
}

// ------------------------------------------------------------------------------------- state

enum Verdict { case unknown, japan, notJapan, noAnswer }
enum Look { case off, checking, good, problem, switchingOn, switchingOff }

struct State {
    var enabled = false          // the automatic-proxy URL points at jp.pac
    var switching: Bool? = nil   // set while `mmvpn up` (true) or `down` (false) runs
    var verdict = Verdict.unknown
    var misses = 0               // consecutive checks that did not come back Japan
    var failure: String? = nil   // why the last switch failed; cleared by the next one

    var look: Look {
        if let on = switching { return on ? .switchingOn : .switchingOff }
        guard enabled else { return .off }
        switch verdict {
        case .japan: return .good
        case .unknown: return .checking
        case .notJapan, .noAnswer: return .problem
        }
    }
}

/// Fold one check result into the state. Returns true when the result was held back and a recheck
/// should come soon. A single miss is held: the tunnel closes the port for a few seconds while it
/// is rebuilt, and one slow answer over a home Wi-Fi is not an outage.
@discardableResult
func fold(_ v: Verdict, into s: inout State) -> Bool {
    if v == .japan { s.verdict = .japan; s.misses = 0; return false }
    s.misses += 1
    if s.misses < 2 { return true }
    s.verdict = v
    return false
}

/// The one status line under the title, and its dot colour. Always exactly one line.
func statusLine(_ s: State) -> (text: String, color: NSColor) {
    switch s.look {
    case .good:         return ("Connected via Japan", .systemGreen)
    case .checking:     return ("Checking…", .tertiaryLabelColor)
    case .switchingOn:  return ("Turning on…", .tertiaryLabelColor)
    case .switchingOff: return ("Turning off…", .tertiaryLabelColor)
    case .problem:
        // The tunnel repairs itself, so the line says that instead of asking for action.
        return s.verdict == .notJapan ? ("Not seen as Japan", .systemOrange)
                                      : ("Reconnecting…", .systemOrange)
    case .off:
        if let f = s.failure { return (f, .systemOrange) }
        return ("Off · everything as usual", .systemRed)
    }
}

// -------------------------------------------------------------------------------------- icon

/// A Mac mini seen from the front, reduced to a rounded box and its one lamp: green on, red off.
///
/// WHERE THE SHAPE COMES FROM: the geometry of Phosphor's "hard-drive" line icon (phosphor-icons/core,
/// MIT licence, Copyright (c) 2023 Phosphor Icons): a rounded rectangle and a single dot at 77 % of its
/// width. It is re-drawn here on whole pixels, and the box is made wider and flatter, like a Mac mini.
///
/// GEOMETRY: 22x16 canvas, box (1, 3, 20, 10) with a 1.5 pt line whose outer edge sits on whole
/// pixels (sharp on a 1x display), lamp 4 pt across at (16, 8). The bar centres the 16 pt image, so
/// the box's middle (y 8) is the bar's middle.
let ICON_SIZE = NSSize(width: 22, height: 16)
let MINI_BOX = NSRect(x: 1, y: 3, width: 20, height: 10)
let MINI_LINE: CGFloat = 1.5
let MINI_LAMP = NSRect(x: 14, y: 6, width: 4, height: 4)

/// The Mac mini with its lamp, as a vector image of ICON_SIZE (crisp at any size).
func miniImage(body: NSColor, light: NSColor) -> NSImage {
    NSImage(size: ICON_SIZE, flipped: false) { _ in
        let r = MINI_BOX.insetBy(dx: MINI_LINE / 2, dy: MINI_LINE / 2)
        let box = NSBezierPath(roundedRect: r, xRadius: 1.75, yRadius: 1.75)
        box.lineWidth = MINI_LINE
        body.setStroke(); box.stroke()
        light.setFill(); NSBezierPath(ovalIn: MINI_LAMP).fill()
        return true
    }
}

/// The status light's colour: green on, red off, orange on a problem, unlit while in progress.
func light(_ look: Look, dim: NSColor) -> NSColor {
    switch look {
    case .good: return .systemGreen
    case .off: return .systemRed
    case .problem: return .systemOrange
    case .checking, .switchingOn, .switchingOff: return dim
    }
}

func isDark(_ a: NSAppearance) -> Bool {
    a.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map {
        $0 == .darkAqua || $0 == .vibrantDark } ?? false
}

/// The menu-bar image for a state. Same size in every state, so the item never changes width.
func icon(_ look: Look, dark: Bool) -> NSImage {
    let fg = dark ? NSColor.white : NSColor.black
    let img = miniImage(body: fg, light: light(look, dim: fg.withAlphaComponent(0.35)))
    img.isTemplate = false
    img.accessibilityDescription = "Mac mini VPN: " + statusLine({ var s = State(); s.enabled = look != .off
        s.verdict = look == .good ? .japan : (look == .problem ? .noAnswer : .unknown)
        s.switching = look == .switchingOn ? true : (look == .switchingOff ? false : nil); return s }()).text
    return img
}

// ------------------------------------------------------------------------------------- panel

/// A view that draws itself with a closure, so system colours resolve at draw time (light/dark).
final class Canvas: NSView {
    var paint: (NSRect) -> Void = { _ in }
    var topDown = true
    override var isFlipped: Bool { topDown }
    override func draw(_ dirtyRect: NSRect) { paint(bounds) }
}

/// The on/off switch, drawn here because NSSwitch can't be coloured, and in a menu (never the key
/// window) it draws its "on" track grey. Green when on, red when off.
final class Toggle: NSView {
    var isOn = false { didSet { needsDisplay = true; setAccessibilityValue(isOn) } }
    var isEnabled = true { didSet { needsDisplay = true } }
    var onChange: ((Bool) -> Void)?
    var trackColor: NSColor { isOn ? .systemGreen : .systemRed }
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel("Mac mini VPN")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let track = bounds.insetBy(dx: 1, dy: 1)
        (isEnabled ? trackColor : trackColor.withAlphaComponent(0.45)).setFill()
        NSBezierPath(roundedRect: track, xRadius: track.height / 2, yRadius: track.height / 2).fill()
        let d = track.height - 4
        let knob = NSRect(x: isOn ? track.maxX - 2 - d : track.minX + 2, y: track.minY + 2, width: d, height: d)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 1.5
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    // A view in a menu item gets its mouse events directly; mouseDown must be taken for mouseUp to come.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { press() }
    }
    override func accessibilityPerformPress() -> Bool { press(); return true }

    func press() {
        guard isEnabled else { return }
        isOn.toggle()
        onChange?(isOn)
    }
}

/// The whole menu above "Quit": title, one status line and a switch; then the five sites.
/// Fixed size and updated in place (`show`), so the open menu never jumps.
final class Panel: NSView {
    let tile = Canvas()
    let title = NSTextField(labelWithString: "Mac mini VPN")
    let dot = Canvas()
    let spinner = NSProgressIndicator()
    let status = NSTextField(labelWithString: "")
    let toggle = Toggle(frame: NSRect(x: 0, y: 0, width: 40, height: 24))
    let rule = NSBox()
    let caption = NSTextField(labelWithString: "Only these 5 go through Japan")
    var chips: [(Canvas, NSTextField)] = []
    let note = NSTextField(labelWithString: "Search and all other sites go direct, as usual")
    var onToggle: ((Bool) -> Void)?
    private var look = Look.off
    private var dotColor = NSColor.tertiaryLabelColor

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        let pad: CGFloat = 14, chipFont = NSFont.systemFont(ofSize: 12, weight: .medium)

        tile.paint = { [unowned self] r in self.paintTile(r) }
        tile.topDown = false   // the Mac mini is drawn bottom-up
        tile.frame = NSRect(x: pad, y: 12, width: 32, height: 32)
        addSubview(tile)

        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = NSRect(x: pad + 44, y: 10, width: 160, height: 18)
        addSubview(title)

        dot.paint = { [unowned self] r in
            self.dotColor.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5)).fill() }
        dot.frame = NSRect(x: pad + 45, y: 33, width: 7, height: 7)
        addSubview(dot)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: pad + 43, y: 30, width: 12, height: 12)
        addSubview(spinner)
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        addSubview(status)

        toggle.onChange = { [unowned self] on in self.onToggle?(on) }
        addSubview(toggle)

        rule.boxType = .separator
        addSubview(rule)

        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .secondaryLabelColor
        addSubview(caption)
        for name in SITES {
            let bg = Canvas()
            bg.paint = { r in
                // Not .withAlphaComponent on a system colour: that REPLACES its alpha (white at 60 %
                // in dark mode, seen in --render), it does not fade it.
                NSColor.quaternaryLabelColor.setFill()
                NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill() }
            let l = NSTextField(labelWithString: name)
            l.font = chipFont
            l.alignment = .center
            bg.addSubview(l)
            addSubview(bg)
            chips.append((bg, l))
        }
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        addSubview(note)

        // Width: whichever is widest of the chip row and the note, so nothing is clipped.
        var x = pad
        for (bg, l) in chips {
            let w = ceil((l.stringValue as NSString).size(withAttributes: [.font: chipFont]).width) + 18
            bg.frame = NSRect(x: x, y: 88, width: w, height: 22)
            l.frame = NSRect(x: 0, y: 3, width: w, height: 16)
            x += w + 6
        }
        let noteW = ceil((note.stringValue as NSString).size(withAttributes: [.font: note.font!]).width) + 4
        let width = max(320, x - 6 + pad, noteW + 2 * pad)
        toggle.frame.origin = NSPoint(x: width - pad - toggle.frame.width,
                                      y: 28 - toggle.frame.height / 2)
        status.frame = NSRect(x: pad + 58, y: 29, width: toggle.frame.minX - (pad + 58) - 8, height: 16)
        rule.frame = NSRect(x: pad, y: 56, width: width - 2 * pad, height: 1)
        caption.frame = NSRect(x: pad, y: 66, width: width - 2 * pad, height: 15)
        note.frame = NSRect(x: pad, y: 118, width: width - 2 * pad, height: 15)
        frame = NSRect(x: 0, y: 0, width: width, height: 142)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The tile repeats the menu-bar icon on a quiet grey disc.
    private func paintTile(_ r: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(ovalIn: r).fill()
        let w = ICON_SIZE.width, h = ICON_SIZE.height
        miniImage(body: .labelColor, light: light(look, dim: .tertiaryLabelColor))
            .draw(in: NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
    }

    func show(_ s: State) {
        look = s.look
        let line = statusLine(s)
        status.stringValue = line.text
        status.textColor = line.color == .systemOrange ? .systemOrange : .secondaryLabelColor
        dotColor = line.color
        let busy = s.switching != nil
        dot.isHidden = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        // The switch shows what was asked for while it is being done, then what is true.
        toggle.isOn = s.switching ?? s.enabled
        toggle.isEnabled = !busy
        let on = s.switching ?? s.enabled
        for (_, l) in chips { l.textColor = on ? .labelColor : .secondaryLabelColor }
        tile.needsDisplay = true
        dot.needsDisplay = true
    }
}

// -------------------------------------------------------------------------------- controller

/// Whether the automatic-proxy URL points at jp.pac: the setting `mmvpn up` writes.
func pacEnabled() -> Bool {
    guard let d = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else {
        return false }
    return (d["ProxyAutoConfigEnable"] as? Int) == 1 && (d["ProxyAutoConfigURLString"] as? String) == PAC_URL
}

func portOpen() -> Bool {
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = PROXY_PORT.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { if fd >= 0 { close(fd) } }
    guard fd >= 0 else { return false }
    var t = timeval(tv_sec: 1, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, socklen_t(MemoryLayout<timeval>.size))
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
}

/// ABEMA's own region verdict through the tunnel. Repair belongs to mmvpn-tunnel; this only reports.
func probe() -> Verdict {
    guard portOpen() else { return .noAnswer }
    let (_, out) = sh("/usr/bin/curl", ["-s", "-m", "20", "--proxy", "socks5h://127.0.0.1:\(PROXY_PORT)",
                      "-A", UA, "https://api.abema.io/v1/ip/check?device=android"], timeout: 26)
    if out.contains("\"isoCountryCode\":\"JP\"") { return .japan }
    if out.contains("\"isoCountryCode\":\"") { return .notJapan }
    return .noAnswer
}

final class Controller: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let panel = Panel()
    var state = State()
    var gen = 0                  // bumped on every switch or outside change; stale checks are dropped
    var inFlight = false
    var lastCheck = Date.distantPast
    var watch: NSKeyValueObservation?

    override init() {
        super.init()
        menu.delegate = self
        let p = NSMenuItem()
        p.view = panel
        menu.addItem(p)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.toolTip = "Closes the icon only. Mac mini VPN stays on or off as it is."
        menu.addItem(quit)
        item.menu = menu
        panel.onToggle = { [weak self] on in self?.flip(on) }
        // The Mac mini is drawn in the bar's own text colour; redraw when the bar turns light/dark.
        watch = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.render() } }
        state.enabled = pacEnabled()
        render()
        check()
        // .common so both keep running while the menu is open.
        let poll = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
        let recheck = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(poll, forMode: .common)
        RunLoop.main.add(recheck, forMode: .common)
    }

    /// Notice a switch made elsewhere (`mmvpn up/down` in a terminal) within five seconds.
    func poll() {
        guard state.switching == nil else { return }
        let on = pacEnabled()
        guard on != state.enabled else { return }
        gen += 1
        state.enabled = on
        state.verdict = .unknown
        state.misses = 0
        render()
        check()
    }

    func check() {
        guard state.enabled, state.switching == nil, !inFlight else { return }
        inFlight = true
        let g = gen
        DispatchQueue.global().async { [weak self] in
            let v = probe()
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight = false
                self.lastCheck = Date()
                guard g == self.gen, self.state.enabled, self.state.switching == nil else { return }
                if fold(v, into: &self.state) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.check() }
                }
                self.render()
            }
        }
    }

    func flip(_ on: Bool) {
        guard state.switching == nil else { return }
        gen += 1
        state.switching = on
        state.failure = nil
        render()
        DispatchQueue.global().async { [weak self] in
            // `up` waits up to 40 s for the tunnel to answer from Japan before routing anything.
            let (code, _) = sh("/bin/bash", [CTL, on ? "up" : "down"], timeout: 300)
            DispatchQueue.main.async {
                guard let self else { return }
                self.gen += 1
                self.state.switching = nil
                self.state.enabled = pacEnabled()
                self.state.verdict = .unknown
                self.state.misses = 0
                if code != 0 {
                    self.state.failure = on ? "Home Mac not responding" : "Couldn't turn off"
                }
                self.render()
                self.check()
            }
        }
    }

    func render() {
        if let b = item.button {
            b.image = icon(state.look, dark: isDark(b.effectiveAppearance))
            b.imagePosition = .imageOnly
            b.toolTip = "Mac mini VPN: " + statusLine(state).text
        }
        panel.show(state)
    }

    func menuWillOpen(_ m: NSMenu) {
        poll()
        render()
        if Date().timeIntervalSince(lastCheck) > 15 { check() }
    }
}

// ----------------------------------------------------------------------------- render, tests

/// `MacminiVPN --render <dir>`: draw the menu-bar strip (1x and 2x) and the panel for every state, light
/// and dark, to PNGs, and exit. The status item itself cannot be screenshotted here.
func renderPreviews(to dir: String) {
    let states: [(String, State)] = {
        var good = State(); good.enabled = true; good.verdict = .japan
        var checking = State(); checking.enabled = true
        var problem = State(); problem.enabled = true; problem.verdict = .noAnswer
        var notJP = State(); notJP.enabled = true; notJP.verdict = .notJapan
        let off = State()
        var failed = State(); failed.failure = "Home Mac not responding"
        var turningOn = State(); turningOn.switching = true
        var turningOff = State(); turningOff.enabled = true; turningOff.switching = false
        return [("good", good), ("checking", checking), ("problem", problem), ("notjapan", notJP),
                ("off", off), ("failed", failed), ("turning-on", turningOn), ("turning-off", turningOff)]
    }()
    for (mode, name) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
        let appearance = NSAppearance(named: name)!
        appearance.performAsCurrentDrawingAppearance {
            for (label, s) in states {
                let panel = Panel()
                panel.appearance = appearance
                panel.show(s)
                let w = panel.frame.width, top: CGFloat = 40
                let canvas = NSView(frame: NSRect(x: 0, y: 0, width: w, height: panel.frame.height + top))
                canvas.appearance = appearance
                canvas.wantsLayer = true
                canvas.layer?.backgroundColor = (mode == "dark" ? NSColor(white: 0.16, alpha: 1)
                                                                : NSColor(white: 0.96, alpha: 1)).cgColor
                let bar = NSView(frame: NSRect(x: 0, y: panel.frame.height + 6, width: w, height: 28))
                bar.wantsLayer = true
                bar.layer?.backgroundColor = (mode == "dark" ? NSColor.black
                                                             : NSColor(white: 0.86, alpha: 1)).cgColor
                let iv = NSImageView(frame: NSRect(x: 10, y: 6, width: ICON_SIZE.width, height: ICON_SIZE.height))
                iv.image = icon(s.look, dark: mode == "dark")
                bar.addSubview(iv)
                canvas.addSubview(bar)
                canvas.addSubview(panel)
                canvas.layoutSubtreeIfNeeded()
                for scale in [1, 2] {
                    let px = NSSize(width: canvas.bounds.width * CGFloat(scale),
                                    height: canvas.bounds.height * CGFloat(scale))
                    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width),
                              pixelsHigh: Int(px.height), bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                    rep.size = canvas.bounds.size
                    canvas.cacheDisplay(in: canvas.bounds, to: rep)
                    let url = URL(fileURLWithPath: dir).appendingPathComponent("\(label)-\(mode)@\(scale)x.png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                }
            }
        }
    }
}

/// `MacminiVPN --selftest`: the state rules, without touching the menu bar or the system.
func selftest() -> Int32 {
    var fails = 0
    func expect(_ name: String, _ ok: Bool) { print(ok ? "  PASS  \(name)" : "  FAIL  \(name)"); if !ok { fails += 1 } }
    var s = State(); s.enabled = true; s.verdict = .japan
    expect("one failed check does not change what is shown", fold(.noAnswer, into: &s) && s.look == .good)
    expect("two failed checks in a row show a problem", !fold(.noAnswer, into: &s) && s.look == .problem)
    expect("an answer from Japan recovers at once", !fold(.japan, into: &s) && s.look == .good && s.misses == 0)
    s.verdict = .unknown; s.misses = 0
    expect("one failure during the first check stays \"checking\"", fold(.notJapan, into: &s) && s.look == .checking)
    expect("two non-Japan answers mean not seen as Japan", !fold(.notJapan, into: &s) && s.verdict == .notJapan)
    var off = State()
    expect("off is off", off.look == .off && statusLine(off).text.hasPrefix("Off"))
    off.failure = "x"
    expect("the reason for a failed switch shows on the off line", statusLine(off).text == "x")
    var sw = State(); sw.enabled = false; sw.switching = true
    expect("switching shows switching", sw.look == .switchingOn)
    for look in [Look.off, .checking, .good, .problem, .switchingOn, .switchingOff] {
        for dark in [true, false] {
            let i = icon(look, dark: dark)
            expect("icon has the same size in every state (\(look), \(dark ? "dark" : "light"))",
                   i.size == ICON_SIZE)
        }
    }
    // The bar centres the image, so the body's middle must be the image's middle (y 8), and the lamp
    // must not be cut off at the top.
    func extent(_ img: NSImage) -> (lo: CGFloat, hi: CGFloat) {
        let k: CGFloat = 8
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(img.size.width * k),
                  pixelsHigh: Int(img.size.height * k), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return (-1, -1) }
        rep.size = img.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(origin: .zero, size: img.size))
        NSGraphicsContext.restoreGraphicsState()
        var top = Int.max, bottom = -1
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
            top = min(top, y); bottom = max(bottom, y) } }
        return (img.size.height - CGFloat(bottom + 1) / k, img.size.height - CGFloat(top) / k)
    }
    let bodyOnly = extent(miniImage(body: .white, light: .clear))
    expect("the box is centred vertically (y 8±0.25): \(bodyOnly)", abs((bodyOnly.lo + bodyOnly.hi) / 2 - ICON_SIZE.height / 2) <= 0.25)
    let whole = extent(miniImage(body: .white, light: .systemGreen))
    expect("the lamp is not clipped: \(whole)", whole.hi <= ICON_SIZE.height - 0.1)
    let heights = Set([State(), { var x = State(); x.enabled = true; x.verdict = .noAnswer; return x }(),
                       { var x = State(); x.failure = "Home Mac not responding"; return x }()]
        .map { st -> CGFloat in let p = Panel(); p.show(st); return p.frame.height })
    expect("the panel height is the same in every state", heights.count == 1)
    // The switch reaches the controller with the state asked for, and is locked while switching.
    let sp = Panel()
    var asked: Bool? = nil
    sp.onToggle = { asked = $0 }
    sp.show(State())
    expect("the switch is red when off", sp.toggle.trackColor == .systemRed && !sp.toggle.isOn)
    sp.toggle.press()
    expect("pressing the switch when off asks for on", asked == true)
    var onState = State(); onState.enabled = true; onState.verdict = .japan
    sp.show(onState)
    expect("the switch is green when on", sp.toggle.trackColor == .systemGreen && sp.toggle.isOn)
    expect("the lamp is green on and red off", light(.good, dim: .gray) == .systemGreen && light(.off, dim: .gray) == .systemRed)
    var busy = State(); busy.switching = true
    sp.show(busy)
    asked = nil
    sp.toggle.press()
    expect("the switch cannot be pressed while switching", !sp.toggle.isEnabled && sp.toggle.isOn && asked == nil)
    // Every status line fits its one line: a truncated "…" was the first --render of this panel.
    let probePanel = Panel()
    for look in [Verdict.japan, .unknown, .noAnswer, .notJapan] {
        var x = State(); x.enabled = true; x.verdict = look
        for st in [x, State(), { var f = State(); f.failure = "Home Mac not responding"; return f }(),
                   { var f = State(); f.failure = "Couldn't turn off"; return f }(),
                   { var f = State(); f.switching = true; return f }(),
                   { var f = State(); f.enabled = true; f.switching = false; return f }()] {
            let t = statusLine(st).text
            let w = (t as NSString).size(withAttributes: [.font: probePanel.status.font!]).width
            expect("the status line fits on one line: \(t)", w + 4 <= probePanel.status.frame.width)
        }
    }
    print(fails == 0 ? "  selftest OK" : "  selftest FAIL \(fails)")
    return fails == 0 ? 0 : 1
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--selftest") { exit(selftest()) }
if CommandLine.arguments.contains("--print-config") {   // what this app will use (for the tests)
    print("pac \(PAC_URL)\nsocks \(PROXY_PORT)\nctl \(CTL)")
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    renderPreviews(to: CommandLine.arguments[i + 1])
    exit(0)
}
app.setActivationPolicy(.accessory)   // menu-bar only: no Dock icon, no window
let c = Controller()
app.run()
