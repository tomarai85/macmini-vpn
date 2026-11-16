// Mac mini VPN — a menu-bar app that chooses what leaves through a Mac at home in Japan.
//
// This app only switches routes (by running `mmvpn set ...`) and shows whether the exit works. The
// tunnel itself is kept open by `mmvpn-tunnel` under launchd, which also repairs it, so quitting the
// app changes nothing.
//
// THREE SWITCHES, each on or off; all three on means everything goes through Japan:
//   Chosen sites      the sites in ~/.config/macmini-vpn/sites (PAC)
//   Terminal tools    programs that read HTTPS_PROXY, such as Claude Code (mmvpn-proxy's relay)
//   Everything else   browsers and every other app that follows the system proxy setting (PAC)
// What is on is read from the machine, never from what the app last asked for:
//   sites, rest   the automatic-proxy URL, http://127.0.0.1:1081/jp.pac?routes=sites,rest&v=...
//   tools         the file ~/.config/macmini-vpn/tools-via-japan, read by the relay per connection
// Every switch runs `mmvpn set <the whole new set>`. Reading "on" from whether the SOCKS port
// answered made the icon flicker to "off" every time the tunnel was rebuilt.
//
// WHY "ABEMA ACCEPTS" AND NOT "CONNECTED": a data-centre address can be located in Japan and still be
// refused, so the health shown is ABEMA's own region verdict through the tunnel, not "something
// listens on the port". One failed check does not change what is shown; two in a row do (`fold`).
//
// LOOK
//   * Icon: a rounded box with one lamp (green on, red off, orange on a problem), drawn on whole
//     pixels so it stays sharp on a 1x display. Its outline follows the menu bar's light/dark look.
//   * Menu: one panel with a status line that is always exactly one line and a switch per route.
//     Its size never changes and it is updated in place while open.
//   * `MacminiVPN --render <dir>` draws every state to PNGs (1x and 2x, light and dark);
//     `MacminiVPN --selftest` checks the state rules and the drawing without touching the system.
//
// The process runner drains output on a background queue and waits on a semaphore, so its timeout
// can actually fire: readDataToEndOfFile() alone blocks until the child closes the pipe.

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
let PAC_BASE = "http://127.0.0.1:\(CONF["PAC_PORT"] ?? "1081")/jp.pac"   // `mmvpn set` adds ?routes=
let TOOLS_FLAG = CONF_DIR + "/tools-via-japan"                          // present while tools is on
let PROXY_PORT = UInt16(CONF["SOCKS_PORT"] ?? "") ?? 1082                // the tunnel's SOCKS port

/// What can go through Japan. Raw values are `mmvpn set`'s words.
enum Route: String, CaseIterable, Comparable {
    case sites, tools, rest
    var title: String {
        switch self { case .sites: return "Chosen sites"; case .tools: return "Terminal tools"
                      case .rest: return "Everything else" } }
    var hint: String {
        switch self { case .sites: return "Your site list, sign-in and video included"
                      case .tools: return "Programs set to use HTTPS_PROXY"
                      case .rest: return "Browsers and other apps" } }
    static func < (a: Route, b: Route) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}
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
    var routes = Set<Route>()    // what goes through Japan now, read from the machine
    var switching: Set<Route>? = nil   // the set being applied while `mmvpn set` runs
    var verdict = Verdict.unknown
    var misses = 0               // consecutive checks that did not come back Japan
    var failure: String? = nil   // why the last switch failed; cleared by the next one

    var enabled: Bool { !routes.isEmpty }

    var look: Look {
        if let target = switching { return target.isEmpty ? .switchingOff : .switchingOn }
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
    // A failed switch is shown until the next switch, or until the exit answers from Japan again.
    if let f = s.failure, s.switching == nil { return (f, .systemOrange) }
    switch s.look {
    case .good:         return ("Connected via Japan", .systemGreen)
    case .checking:     return ("Checking…", .tertiaryLabelColor)
    case .switchingOn:  return (s.enabled ? "Switching…" : "Turning on…", .tertiaryLabelColor)
    case .switchingOff: return ("Turning off…", .tertiaryLabelColor)
    case .problem:
        // The tunnel repairs itself, so the line says that instead of asking for action.
        return s.verdict == .notJapan ? ("Not seen as Japan", .systemOrange)
                                      : ("Reconnecting…", .systemOrange)
    case .off:
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
    img.accessibilityDescription = "Mac mini VPN: " + statusLine({ var s = State()
        if look != .off { s.routes = [.sites] }
        s.verdict = look == .good ? .japan : (look == .problem ? .noAnswer : .unknown)
        s.switching = look == .switchingOn ? [.sites] : (look == .switchingOff ? [] : nil); return s }()).text
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

/// The whole menu above "Quit": title and one status line, then one switch per route.
/// Fixed size and updated in place (`show`), so the open menu never jumps.
final class Panel: NSView {
    let tile = Canvas()
    let title = NSTextField(labelWithString: "Mac mini VPN")
    let dot = Canvas()
    let spinner = NSProgressIndicator()
    let status = NSTextField(labelWithString: "")
    let rule = NSBox()
    var rows: [(route: Route, toggle: Toggle, label: NSTextField, hint: NSTextField)] = []
    var onChange: ((Route, Bool) -> Void)?
    private var look = Look.off
    private var dotColor = NSColor.tertiaryLabelColor

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        let pad: CGFloat = 14, top: CGFloat = 64, rowH: CGFloat = 42
        let labelFont = NSFont.systemFont(ofSize: 13, weight: .medium), hintFont = NSFont.systemFont(ofSize: 11)

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

        rule.boxType = .separator
        addSubview(rule)

        // Width: whichever is wider of 320 and the longest label or hint beside a switch.
        var textW: CGFloat = 0
        for r in Route.allCases {
            textW = max(textW, ceil((r.title as NSString).size(withAttributes: [.font: labelFont]).width),
                        ceil((r.hint as NSString).size(withAttributes: [.font: hintFont]).width))
        }
        let toggleW: CGFloat = 40
        let width = max(320, pad + textW + 4 + 12 + toggleW + pad)
        let textFrameW = width - 2 * pad - toggleW - 12
        for (i, r) in Route.allCases.enumerated() {
            let y = top + CGFloat(i) * rowH
            let l = NSTextField(labelWithString: r.title)
            l.font = labelFont
            l.frame = NSRect(x: pad, y: y + 4, width: textFrameW, height: 17)
            let h = NSTextField(labelWithString: r.hint)
            h.font = hintFont
            h.textColor = .secondaryLabelColor
            h.frame = NSRect(x: pad, y: y + 21, width: textFrameW, height: 14)
            let t = Toggle(frame: NSRect(x: width - pad - toggleW, y: y + 7, width: toggleW, height: 24))
            t.setAccessibilityLabel(r.title)
            t.onChange = { [unowned self] on in self.onChange?(r, on) }
            addSubview(l); addSubview(h); addSubview(t)
            rows.append((r, t, l, h))
        }
        status.frame = NSRect(x: pad + 58, y: 29, width: width - (pad + 58) - pad, height: 16)
        rule.frame = NSRect(x: pad, y: 56, width: width - 2 * pad, height: 1)
        frame = NSRect(x: 0, y: 0, width: width, height: top + CGFloat(Route.allCases.count) * rowH + 8)
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

    func toggle(_ r: Route) -> Toggle { rows.first { $0.route == r }!.toggle }

    func show(_ s: State) {
        look = s.look
        let line = statusLine(s)
        status.stringValue = line.text
        status.textColor = line.color == .systemOrange ? .systemOrange : .secondaryLabelColor
        dotColor = line.color
        let busy = s.switching != nil
        dot.isHidden = busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        // The switches show what was asked for while it is being done, then what is true.
        let shown = s.switching ?? s.routes
        for row in rows {
            row.toggle.isOn = shown.contains(row.route)
            row.toggle.isEnabled = !busy
            row.label.textColor = busy ? .secondaryLabelColor : .labelColor
        }
        tile.needsDisplay = true
        dot.needsDisplay = true
    }
}

// -------------------------------------------------------------------------------- controller

/// The routes a PAC URL carries. The bare URL (what the one-switch version set) is the sites, as
/// mmvpn-proxy serves it. Terminal tools are never routed by a PAC, so they are never read from one.
func pacRoutes(_ url: String) -> Set<Route> {
    guard url == PAC_BASE || url.hasPrefix(PAC_BASE + "?") else { return [] }
    guard let q = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "routes" }) else {
        return [.sites] }
    return Set((q.value ?? "").split(separator: ",").compactMap { Route(rawValue: String($0)) })
        .subtracting([.tools])
}

/// The set after one switch changes: only that switch's route moves.
func applying(_ r: Route, _ on: Bool, to routes: Set<Route>) -> Set<Route> {
    on ? routes.union([r]) : routes.subtracting([r])
}

/// `mmvpn set` with the whole set, in a fixed order.
func setArgs(_ t: Set<Route>) -> [String] { ["set"] + t.sorted().map(\.rawValue) }

/// What goes through Japan now: the automatic-proxy URL plus the terminal-tools flag.
func currentRoutes() -> Set<Route> {
    var r = Set<Route>()
    if let d = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
       (d["ProxyAutoConfigEnable"] as? Int) == 1, let url = d["ProxyAutoConfigURLString"] as? String {
        r = pacRoutes(url)
    }
    if FileManager.default.fileExists(atPath: TOOLS_FLAG) { r.insert(.tools) }
    return r
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
        quit.toolTip = "Closes the icon only. What goes through Japan stays as it is."
        menu.addItem(quit)
        item.menu = menu
        panel.onChange = { [weak self] r, on in self?.flip(r, on) }
        // The Mac mini is drawn in the bar's own text colour; redraw when the bar turns light/dark.
        watch = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.render() } }
        state.routes = currentRoutes()
        render()
        check()
        // .common so both keep running while the menu is open.
        let poll = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
        let recheck = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.check() }
        RunLoop.main.add(poll, forMode: .common)
        RunLoop.main.add(recheck, forMode: .common)
    }

    /// Notice a change made elsewhere (`mmvpn set` in a terminal) within five seconds.
    func poll() {
        guard state.switching == nil else { return }
        let now = currentRoutes()
        guard now != state.routes else { return }
        gen += 1
        state.routes = now
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
                if self.state.verdict == .japan { self.state.failure = nil }
                self.render()
            }
        }
    }

    /// One switch changed: apply the whole new set with `mmvpn set`.
    func flip(_ r: Route, _ on: Bool) {
        guard state.switching == nil else { return }
        let target = applying(r, on, to: state.routes)
        guard target != state.routes else { render(); return }
        gen += 1
        state.switching = target
        state.failure = nil
        render()
        let args = [CTL] + setArgs(target)
        DispatchQueue.global().async { [weak self] in
            // Adding a route waits up to 40 s for the Mac mini to answer from Japan; on a failure
            // nothing changes, so the switch falls back to what is true.
            let (code, _) = sh("/bin/bash", args, timeout: 300)
            DispatchQueue.main.async {
                guard let self else { return }
                self.gen += 1
                self.state.switching = nil
                self.state.routes = currentRoutes()
                self.state.verdict = .unknown
                self.state.misses = 0
                if code != 0 {
                    self.state.failure = target.isEmpty ? "Couldn't turn off" : "Home Mac not responding"
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
        var good = State(); good.routes = [.sites]; good.verdict = .japan
        var both = State(); both.routes = [.sites, .tools]; both.verdict = .japan
        var all = State(); all.routes = Set(Route.allCases); all.verdict = .japan
        var checking = State(); checking.routes = [.tools]
        var problem = State(); problem.routes = [.sites]; problem.verdict = .noAnswer
        var notJP = State(); notJP.routes = [.sites]; notJP.verdict = .notJapan
        let off = State()
        var failed = State(); failed.failure = "Home Mac not responding"
        var turningOn = State(); turningOn.switching = [.sites]
        var switching = State(); switching.routes = [.sites]; switching.switching = [.sites, .tools]
        var turningOff = State(); turningOff.routes = [.sites]; turningOff.switching = []
        return [("good", good), ("sites-tools", both), ("all", all), ("checking", checking),
                ("problem", problem), ("notjapan", notJP), ("off", off), ("failed", failed),
                ("turning-on", turningOn), ("switching", switching), ("turning-off", turningOff)]
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
    var s = State(); s.routes = [.sites]; s.verdict = .japan
    expect("one failed check does not change what is shown", fold(.noAnswer, into: &s) && s.look == .good)
    expect("two failed checks in a row show a problem", !fold(.noAnswer, into: &s) && s.look == .problem)
    expect("Japan again recovers at once", !fold(.japan, into: &s) && s.look == .good && s.misses == 0)
    s.verdict = .unknown; s.misses = 0
    expect("a first miss while checking stays checking", fold(.notJapan, into: &s) && s.look == .checking)
    expect("two not-Japan answers read as not seen as Japan", !fold(.notJapan, into: &s) && s.verdict == .notJapan)
    var off = State()
    expect("off is off", off.look == .off && statusLine(off).text.hasPrefix("Off"))
    off.failure = "x"
    expect("a failure shows on the off line", statusLine(off).text == "x")
    var onFail = State(); onFail.routes = [.sites]; onFail.verdict = .japan; onFail.failure = "Home Mac not responding"
    expect("a failed add shows while the other routes stay on", statusLine(onFail).text == "Home Mac not responding")
    var sw = State(); sw.switching = [.sites]
    expect("from off: Turning on", sw.look == .switchingOn && statusLine(sw).text == "Turning on…")
    sw.routes = [.sites]; sw.switching = [.sites, .tools]
    expect("adding to a running set: Switching", statusLine(sw).text == "Switching…")
    sw.switching = []
    expect("removing the last route: Turning off", sw.look == .switchingOff && statusLine(sw).text == "Turning off…")

    // What is on is read back from the PAC URL that `mmvpn set` writes.
    expect("the bare PAC URL is the sites", pacRoutes(PAC_BASE) == [.sites])
    expect("routes=sites,rest", pacRoutes(PAC_BASE + "?routes=sites,rest") == [.sites, .rest])
    expect("routes=rest", pacRoutes(PAC_BASE + "?routes=rest") == [.rest])
    expect("the version after the routes is ignored", pacRoutes(PAC_BASE + "?routes=sites,rest&v=1a2b3c4d") == [.sites, .rest])
    expect("an empty routes= is nothing", pacRoutes(PAC_BASE + "?routes=").isEmpty)
    expect("terminal tools are never read from a PAC", pacRoutes(PAC_BASE + "?routes=tools,sites") == [.sites])
    expect("another PAC is nothing", pacRoutes("http://127.0.0.1:1081/other.pac").isEmpty
           && pacRoutes("http://example.com/jp.pac").isEmpty && pacRoutes(PAC_BASE + "x?routes=sites").isEmpty)
    // A switch changes only its own route, and `mmvpn set` gets the whole set in a fixed order.
    expect("adding terminal tools keeps the sites", applying(.tools, true, to: [.sites]) == [.sites, .tools])
    expect("removing the sites keeps the rest", applying(.sites, false, to: [.sites, .rest]) == [.rest])
    expect("mmvpn gets the whole set in order", setArgs([.rest, .sites, .tools]) == ["set", "sites", "tools", "rest"])
    expect("an empty set turns everything off", setArgs([]) == ["set"])
    for look in [Look.off, .checking, .good, .problem, .switchingOn, .switchingOff] {
        for dark in [true, false] {
            let i = icon(look, dark: dark)
            expect("the icon has the same size in every state (\(look), \(dark ? "dark" : "light"))",
                   i.size == ICON_SIZE)
        }
    }
    // The bar centres the image, so the box's middle must be the image's middle (y 8), and the lamp
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
    let heights = Set([State(), { var x = State(); x.routes = [.sites]; x.verdict = .noAnswer; return x }(),
                       { var x = State(); x.failure = "Home Mac not responding"; return x }(),
                       { var x = State(); x.switching = Set(Route.allCases); return x }()]
        .map { st -> CGFloat in let p = Panel(); p.show(st); return p.frame.height })
    expect("the panel height does not change with the state", heights.count == 1)
    // Each switch reaches the controller with its own route and the state asked for.
    let sp = Panel()
    var asked: (Route, Bool)? = nil
    sp.onChange = { asked = ($0, $1) }
    sp.show(State())
    expect("one switch per route, in order", sp.rows.map(\.route) == Route.allCases)
    expect("off switches are red", Route.allCases.allSatisfy {
        sp.toggle($0).trackColor == .systemRed && !sp.toggle($0).isOn })
    sp.toggle(.tools).press()
    expect("pressing terminal tools from off asks for them on", asked?.0 == .tools && asked?.1 == true)
    var on = State(); on.routes = [.sites, .rest]; on.verdict = .japan
    sp.show(on)
    expect("each switch shows its own route", sp.toggle(.sites).isOn && !sp.toggle(.tools).isOn && sp.toggle(.rest).isOn)
    expect("on switches are green", sp.toggle(.sites).trackColor == .systemGreen)
    expect("the lamp is green on and red off", light(.good, dim: .gray) == .systemGreen && light(.off, dim: .gray) == .systemRed)
    sp.toggle(.sites).press()
    expect("pressing an on switch asks for it off", asked?.0 == .sites && asked?.1 == false)
    var busy = State(); busy.routes = [.sites]; busy.switching = [.sites, .tools]
    sp.show(busy)
    expect("while switching, the switches show the set being applied", sp.toggle(.tools).isOn && sp.toggle(.sites).isOn)
    asked = nil
    sp.toggle(.rest).press()
    expect("while switching, no switch can be pressed", !sp.toggle(.rest).isEnabled && asked == nil && !sp.toggle(.rest).isOn)
    // Every status line, label and hint fits its one line: a truncated "…" was the first --render.
    let probePanel = Panel()
    func fits(_ t: String, _ f: NSTextField) -> Bool {
        (t as NSString).size(withAttributes: [.font: f.font!]).width + 4 <= f.frame.width }
    for v in [Verdict.japan, .unknown, .noAnswer, .notJapan] {
        var x = State(); x.routes = [.sites]; x.verdict = v
        for st in [x, State(), { var f = State(); f.failure = "Home Mac not responding"; return f }(),
                   { var f = State(); f.failure = "Couldn't turn off"; return f }(),
                   { var f = State(); f.switching = [.sites]; return f }(),
                   { var f = State(); f.routes = [.sites]; f.switching = [.sites, .rest]; return f }(),
                   { var f = State(); f.routes = [.sites]; f.switching = []; return f }()] {
            let t = statusLine(st).text
            expect("the status line fits one line: \(t)", fits(t, probePanel.status))
        }
    }
    for row in probePanel.rows {
        expect("\(row.route.title) and its hint fit", fits(row.route.title, row.label) && fits(row.route.hint, row.hint))
    }
    print(fails == 0 ? "  selftest OK" : "  selftest FAIL \(fails)")
    return fails == 0 ? 0 : 1
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--selftest") { exit(selftest()) }
if CommandLine.arguments.contains("--print-config") {   // what this app will use (for the tests)
    print("pac \(PAC_BASE)\nsocks \(PROXY_PORT)\nctl \(CTL)\nflag \(TOOLS_FLAG)")
    exit(0)
}
if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
    renderPreviews(to: CommandLine.arguments[i + 1])
    exit(0)
}
app.setActivationPolicy(.accessory)   // menu-bar only: no Dock icon, no window
let c = Controller()
app.run()
