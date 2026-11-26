// Warm/dim filter for every display (built-in and external), applied through the GPU gamma tables.
//
//   screenfilter daemon                  run the filter (launchd keeps this alive)
//   screenfilter status                  settings and whether the filter is on now
//   screenfilter auto | on | off         warm from sunset to sunrise / always / never
//   screenfilter warmth <0-100>          0 = no tint, 100 = deep amber (1900K)
//   screenfilter brightness <10-100>     scales the external display's output, day and night
//   screenfilter laptop-brightness <10-100>  the same for the built-in screen
//
// A gamma table only lasts as long as the process that set it, and macOS resets it on sleep/wake
// and display changes, so the daemon stays running and reapplies on each of those events.
import AppKit
import CoreLocation
import Foundation

// MARK: settings

let configURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/screen-filter/config.json")

struct Settings: Codable {
    var mode = "auto"
    var warmth = 50
    var brightness = 100
    var laptopBrightness = 100
    // Where sunset and sunrise are computed for: the Mac's last location fix (Jacksonville Beach until
    // the first one arrives).
    var latitude = 30.29
    var longitude = -81.39

    init() {}
    // A key missing from the file keeps its default, so adding a setting never invalidates the file.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? mode
        warmth = try c.decodeIfPresent(Int.self, forKey: .warmth) ?? warmth
        brightness = try c.decodeIfPresent(Int.self, forKey: .brightness) ?? brightness
        laptopBrightness = try c.decodeIfPresent(Int.self, forKey: .laptopBrightness) ?? laptopBrightness
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude) ?? latitude
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude) ?? longitude
    }
}

func loadSettings() -> Settings {
    guard let d = try? Data(contentsOf: configURL) else { return Settings() }
    do { return try JSONDecoder().decode(Settings.self, from: d) } catch {
        logError("config unreadable, using defaults: \(error)")
        return Settings()
    }
}

func saveSettings(_ s: Settings) {
    try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    do { try enc.encode(s).write(to: configURL, options: .atomic) } catch { logError("cannot write config: \(error)"); Ops.flush(); exit(1) }
}

func log(_ m: String) { print("\(Date()) \(m)"); fflush(stdout) }
func logError(_ m: String) {
    FileHandle.standardError.write("\(Date()) ERROR \(m)\n".data(using: .utf8)!)
    Ops.error(m)
}

// MARK: ops responder

/// Errors and heartbeats to the ops responder (health/responder), as mac/screen-filter: the same wire
/// format as the ops-report Python package. Only the daemon reports (`Ops.enabled`); the CLI is run by
/// hand and prints its own failures. OPS_URLS and OPS_TOKEN come from the environment or, failing that,
/// ~/.config/ops/env. An error no URL accepted is spooled and sent after the next send that gets through;
/// a missed beat is not kept.
enum Ops {
    static var enabled = false
    static let service = "screen-filter"
    static let env: [String: String] = {
        var out: [String: String] = [:]
        let path = NSHomeDirectory() + "/.config/ops/env"
        for line in ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            out[String(t[..<eq])] = String(t[t.index(after: eq)...])
        }
        return out.merging(ProcessInfo.processInfo.environment) { _, e in e }
    }()
    static let urls = (env["OPS_URLS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    static let token = env["OPS_TOKEN"] ?? ""
    static let spool = env["OPS_SPOOL"] ?? (NSTemporaryDirectory() + "ops-spool-screen-filter.jsonl")
    static let queue = DispatchQueue(label: "ops-report")
    static let pending = DispatchGroup()

    static func start() {
        enabled = true
        if urls.isEmpty || token.isEmpty {
            FileHandle.standardError.write("[ops] \(service): OPS_URLS or OPS_TOKEN is unset: not reporting\n".data(using: .utf8)!)
        }
        queue.async(group: pending) { flushSpool() }
    }

    static func error(_ message: String) {
        guard enabled else { return }
        let at = ISO8601DateFormatter().string(from: Date())
        let item: [String: Any] = ["machine": "mac", "service": service, "message": String(message.prefix(4000)), "at": at]
        queue.async(group: pending) {
            if send("error", [item]) { flushSpool() } else { appendSpool(item) }
        }
    }

    static func beat(_ everyS: Int) {
        guard enabled else { return }
        let item: [String: Any] = ["machine": "mac", "service": service, "every_s": everyS, "info": NSNull()]
        queue.async(group: pending) { if send("beat", [item]) { flushSpool() } }
    }

    /// Waits for queued sends, for a path that is about to exit.
    static func flush() { _ = pending.wait(timeout: .now() + 5) }

    private static func send(_ kind: String, _ items: [[String: Any]]) -> Bool {
        guard !token.isEmpty, let body = try? JSONSerialization.data(withJSONObject: items) else { return false }
        for u in urls {
            guard let url = URL(string: "\(u)/\(kind)") else { continue }
            var req = URLRequest(url: url, timeoutInterval: 8)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let done = DispatchSemaphore(value: 0)
            var ok = false
            URLSession.shared.dataTask(with: req) { _, resp, _ in
                if let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) { ok = true }
                done.signal()
            }.resume()
            done.wait()
            if ok { return true }
        }
        return false
    }

    private static func appendSpool(_ item: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: item) else { return }
        line.append(0x0A)
        if let h = FileHandle(forWritingAtPath: spool) { h.seekToEndOfFile(); h.write(line); h.closeFile() }
        else { FileManager.default.createFile(atPath: spool, contents: line) }
    }

    private static func flushSpool() {
        guard let text = try? String(contentsOfFile: spool, encoding: .utf8) else { return }
        let items = text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        if items.isEmpty || send("error", items) { try? FileManager.default.removeItem(atPath: spool) }
    }
}

// MARK: sun schedule

/// Sunrise and sunset (NOAA approximation, official zenith) on the local calendar day containing `day`.
func sunTimes(on day: Date, lat: Double, lon: Double) -> (rise: Date, set: Date)? {
    let cal = Calendar.current
    let n = Double(cal.ordinality(of: .day, in: .year, for: day)!)
    let c = cal.dateComponents([.year, .month, .day], from: day)
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    let midnightUTC = utc.date(from: DateComponents(year: c.year, month: c.month, day: c.day))!
    let rad = Double.pi / 180, lngHour = lon / 15
    func event(rising: Bool) -> Date? {
        let t = n + ((rising ? 6 : 18) - lngHour) / 24
        let m = 0.9856 * t - 3.289
        var l = m + 1.916 * sin(m * rad) + 0.020 * sin(2 * m * rad) + 282.634
        l = l.truncatingRemainder(dividingBy: 360); if l < 0 { l += 360 }
        var ra = atan(0.91764 * tan(l * rad)) / rad
        ra = ra.truncatingRemainder(dividingBy: 360); if ra < 0 { ra += 360 }
        ra = (ra + floor(l / 90) * 90 - floor(ra / 90) * 90) / 15
        let sinDec = 0.39782 * sin(l * rad), cosDec = cos(asin(sinDec))
        let cosH = (cos(90.833 * rad) - sinDec * sin(lat * rad)) / (cosDec * cos(lat * rad))
        guard abs(cosH) <= 1 else { return nil }  // no sunrise/sunset that day (polar)
        let h = (rising ? 360 - acos(cosH) / rad : acos(cosH) / rad) / 15
        var ut = (h + ra - 0.06571 * t - 6.622 - lngHour).truncatingRemainder(dividingBy: 24)
        if ut < 0 { ut += 24 }
        // UT is the hour on the UTC day; an evening event west of Greenwich can land after UTC midnight.
        var date = midnightUTC.addingTimeInterval(ut * 3600)
        if cal.startOfDay(for: date) < cal.startOfDay(for: day) { date += 86400 }
        if cal.startOfDay(for: date) > cal.startOfDay(for: day) { date -= 86400 }
        return date
    }
    guard let r = event(rising: true), let s = event(rising: false) else { return nil }
    return (r, s)
}

func isNight(_ s: Settings, at now: Date = Date()) -> Bool {
    guard let t = sunTimes(on: now, lat: s.latitude, lon: s.longitude) else {
        logError("no sunrise/sunset computable for \(s.latitude),\(s.longitude); treating as day"); return false
    }
    return now < t.rise || now >= t.set
}

func warmNow(_ s: Settings) -> Bool { s.mode == "on" || (s.mode == "auto" && isNight(s)) }

/// The next sunrise or sunset after `now`.
func nextSunChange(_ s: Settings, after now: Date = Date()) -> Date? {
    for offset in 0...2 {
        let day = Calendar.current.date(byAdding: .day, value: offset, to: now)!
        guard let t = sunTimes(on: day, lat: s.latitude, lon: s.longitude) else { return nil }
        if t.rise > now { return t.rise }
        if t.set > now { return t.set }
    }
    return nil
}

// MARK: gamma

/// RGB multipliers for a color temperature, normalised so 6500K is (1,1,1).
func rgb(kelvin: Double) -> (Double, Double, Double) {
    func raw(_ k: Double) -> (Double, Double, Double) {
        let t = k / 100
        let r = t <= 66 ? 255 : 329.698727446 * pow(t - 60, -0.1332047592)
        let g = t <= 66 ? 99.4708025861 * log(t) - 161.1195681661 : 288.1221695283 * pow(t - 60, -0.0755148492)
        let b = t >= 66 ? 255 : (t <= 19 ? 0 : 138.5177312231 * log(t - 10) - 305.0447927307)
        return (min(max(r, 0), 255), min(max(g, 0), 255), min(max(b, 0), 255))
    }
    let w = raw(6500), c = raw(kelvin)
    return (min(c.0 / w.0, 1), min(c.1 / w.1, 1), min(c.2 / w.2, 1))
}

func displays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
}

/// What a display's table should be right now: (r, g, b) channel scale.
func target(_ s: Settings, _ d: CGDirectDisplayID) -> (Double, Double, Double) {
    let k = warmNow(s) ? 6500 - Double(min(max(s.warmth, 0), 100)) / 100 * (6500 - 1900) : 6500
    let (r, g, b) = rgb(kelvin: k)
    let bright = Double(min(max(CGDisplayIsBuiltin(d) != 0 ? s.laptopBrightness : s.brightness, 10), 100)) / 100
    return (r * bright, g * bright, b * bright)
}

let tableSize = 256

func apply(_ s: Settings, reason: String) {
    for d in displays() {
        let (r, g, b) = target(s, d)
        let ramp = (0..<tableSize).map { CGGammaValue(Double($0) / Double(tableSize - 1)) }
        let err = CGSetDisplayTransferByTable(d, UInt32(tableSize), ramp.map { $0 * CGGammaValue(r) },
                                              ramp.map { $0 * CGGammaValue(g) }, ramp.map { $0 * CGGammaValue(b) })
        if err != .success { logError("gamma set failed on display \(d): \(err.rawValue)") }
        log(String(format: "applied (%@): display %u r %.2f g %.2f b %.2f", reason, d, r, g, b))
    }
}

/// Top-of-ramp value a display is showing, or nil when it cannot be read.
func current(_ d: CGDirectDisplayID) -> (Double, Double, Double)? {
    let cap = Int(CGDisplayGammaTableCapacity(d))
    var r = [CGGammaValue](repeating: 0, count: cap), g = r, b = r; var n: UInt32 = 0
    guard CGGetDisplayTransferByTable(d, UInt32(cap), &r, &g, &b, &n) == .success, n > 0 else { return nil }
    let i = Int(n) - 1
    return (Double(r[i]), Double(g[i]), Double(b[i]))
}

func matches(_ s: Settings) -> Bool {
    return displays().allSatisfy { d in
        let t = target(s, d)
        guard let c = current(d) else { return false }
        return abs(c.0 - t.0) < 0.01 && abs(c.1 - t.1) < 0.01 && abs(c.2 - t.2) < 0.01
    }
}

// MARK: location

/// Keeps the configured coordinates at the Mac's location: one fix at start, then a new one whenever
/// it has moved significantly. Needs Location Services permission for ScreenFilter.app, asked once.
final class Locator: NSObject, CLLocationManagerDelegate {
    let manager = CLLocationManager()
    let onFix: (CLLocation) -> Void
    init(onFix: @escaping (CLLocation) -> Void) {
        self.onFix = onFix
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        switch m.authorizationStatus {
        case .notDetermined: m.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            m.startMonitoringSignificantLocationChanges()
            m.requestLocation()
        default: logError("location permission not granted (status \(m.authorizationStatus.rawValue)); using saved coordinates")
        }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) { if let f = l.last { onFix(f) } }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) { logError("location fix failed: \(e)") }
}

// MARK: menu bar

/// The menu bar icon: mode, warmth and per-screen brightness. Rebuilt from the settings file each
/// time it opens; a choice saves the file, which the daemon's watcher applies like any other change.
final class StatusMenu: NSObject, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    static let warmths = [0, 25, 50, 65, 80, 100]
    static let brightnesses = [100, 85, 70, 55, 40, 30, 20, 10]

    override init() {
        super.init()
        menu.delegate = self
        item.menu = menu
        refreshIcon(loadSettings())
    }

    func refreshIcon(_ s: Settings) { item.button?.title = warmNow(s) ? "◐" : "○" }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let s = loadSettings()
        menu.removeAllItems()
        var auto = "Auto (sunset to sunrise)"
        if let next = nextSunChange(s) {
            let at = next.formatted(date: .omitted, time: .shortened)
            auto = isNight(s) ? "Auto: warm until \(at)" : "Auto: warm from \(at)"
        }
        for (title, mode) in [(auto, "auto"), ("Always on", "on"), ("Off", "off")] {
            menu.addItem(choice(title, s.mode == mode) { $0.mode = mode })
        }
        menu.addItem(.separator())
        menu.addItem(submenu("Warmth", Self.warmths, s.warmth, "") { s, v in s.warmth = v })
        menu.addItem(submenu("Monitor brightness", Self.brightnesses, s.brightness, "%") { s, v in s.brightness = v })
        menu.addItem(submenu("Laptop brightness", Self.brightnesses, s.laptopBrightness, "%") { s, v in s.laptopBrightness = v })
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    private func submenu(_ title: String, _ values: [Int], _ current: Int, _ suffix: String,
                         _ set: @escaping (inout Settings, Int) -> Void) -> NSMenuItem {
        let parent = NSMenuItem(title: "\(title): \(current)\(suffix)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for v in values { sub.addItem(choice("\(v)\(suffix)", v == current) { set(&$0, v) }) }
        parent.submenu = sub
        return parent
    }

    private func choice(_ title: String, _ on: Bool, _ change: @escaping (inout Settings) -> Void) -> NSMenuItem {
        let mi = ClosureItem(title: title) { var s = loadSettings(); change(&s); saveSettings(s) }
        mi.state = on ? .on : .off
        return mi
    }
}

final class ClosureItem: NSMenuItem {
    let run: () -> Void
    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("unused") }
    @objc func fire() { run() }
}

// MARK: daemon

// Present while a daemon runs and removed on each clean stop, so a run that crashed (launchd restarts
// it) is reported by the run that follows it.
let runningMarker = NSTemporaryDirectory() + "screen-filter.running"

func runDaemon() -> Never {
    Ops.start()
    if let prev = try? String(contentsOfFile: runningMarker, encoding: .utf8) {
        logError("previous daemon run (pid \(prev.trimmingCharacters(in: .whitespacesAndNewlines))) ended without a clean stop")
    }
    FileManager.default.createFile(atPath: runningMarker, contents: "\(getpid())\n".data(using: .utf8))
    func cleanStop(_ why: String) {
        log(why); CGDisplayRestoreColorSyncSettings()
        try? FileManager.default.removeItem(atPath: runningMarker)
        Ops.flush()
    }
    var settings = loadSettings()
    _ = NSApplication.shared
    let statusMenu = StatusMenu()
    let reapply: (String) -> Void = { reason in DispatchQueue.main.async { apply(settings, reason: reason) } }

    // Display added, removed or reconfigured: macOS restores the default table, so set ours again.
    CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
        if !flags.contains(.beginConfigurationFlag) {
            DispatchQueue.main.async { apply(loadSettings(), reason: "display change") }
        }
    }, nil)

    let ws = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
        ws.addObserver(forName: name, object: nil, queue: .main) { _ in reapply(name.rawValue) }
    }

    // Sunset and sunrise: sleep to exactly the next one. Wall-clock time, so it still fires on time
    // after the Mac has slept; every apply re-arms it for the change after that.
    let sunTimer = DispatchSource.makeTimerSource(queue: .main)
    func armSunTimer() {
        guard let next = nextSunChange(settings) else { return }
        sunTimer.schedule(wallDeadline: DispatchWallTime(timespec: timespec(tv_sec: Int(next.timeIntervalSince1970), tv_nsec: 0)) + 1)
        log("next sun change \(next)")
    }
    sunTimer.setEventHandler { apply(settings, reason: "sun"); statusMenu.refreshIcon(settings); armSunTimer() }
    sunTimer.resume()
    armSunTimer()

    // Settings changes from the CLI. Watch the directory: the CLI replaces the file atomically.
    try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(configURL.deletingLastPathComponent().path, O_EVTONLY)
    let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
    watcher.setEventHandler {
        settings = loadSettings()
        apply(settings, reason: "settings")
        armSunTimer()
        statusMenu.refreshIcon(settings)
    }
    watcher.resume()

    // A new location moves sunset and sunrise; saving it reaches the watcher above, which re-arms.
    let locator = Locator { fix in
        var s = loadSettings()
        let lat = (fix.coordinate.latitude * 100).rounded() / 100, lon = (fix.coordinate.longitude * 100).rounded() / 100
        guard lat != s.latitude || lon != s.longitude else { return }
        log("location \(lat),\(lon)")
        s.latitude = lat; s.longitude = lon
        saveSettings(s)
    }
    _ = locator

    // Backstop behind the events above: something they did not announce reset the table. Each pass is
    // also the daemon's heartbeat, so a wedged main queue goes quiet.
    let backstop = DispatchSource.makeTimerSource(queue: .main)
    backstop.schedule(deadline: .now(), repeating: 300)
    backstop.setEventHandler {
        Ops.beat(300)
        if !matches(settings) {
            logError("gamma table was reset without an event; reapplying")
            apply(settings, reason: "backstop")
        }
    }
    backstop.resume()

    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler { cleanStop("stopping"); exit(0) }
    // Quit from the menu: restore the screens on the way out. launchd starts it again only at login,
    // because KeepAlive is set to restart on a crash, not on a clean exit.
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        cleanStop("quit from menu")
    }
    term.resume()

    apply(settings, reason: "start")
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
    exit(0)
}

// MARK: CLI

func printStatus() {
    let s = loadSettings()
    let running = matches(s)
    let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
    let next = nextSunChange(s).map { " next change \(f.string(from: $0))" } ?? ""
    print("mode:       \(s.mode)   (\(isNight(s) ? "night" : "day") now;\(next))")
    print("warmth:     \(s.warmth)")
    print("brightness: \(s.brightness)   laptop: \(s.laptopBrightness)")
    print("location:   \(s.latitude),\(s.longitude)")
    for d in displays() {
        let name = CGDisplayIsBuiltin(d) != 0 ? "laptop" : "external \(d)"
        if let c = current(d) { print(String(format: "%@:  r %.2f g %.2f b %.2f", name, c.0, c.1, c.2)) }
    }
    if !running { print("filter is NOT applied (daemon not running?)") }
}

let args = Array(CommandLine.arguments.dropFirst())
var s = loadSettings()
func intArg(_ range: ClosedRange<Int>) -> Int {
    guard args.count > 1, let v = Int(args[1]), range.contains(v) else {
        print("expected a number \(range.lowerBound)-\(range.upperBound)"); exit(2)
    }
    return v
}
switch args.first ?? "status" {
case "daemon": runDaemon()
case "status": printStatus(); exit(0)
case "auto", "on", "off": s.mode = args[0]
case "warmth": s.warmth = intArg(0...100)
case "brightness": s.brightness = intArg(10...100)
case "laptop-brightness": s.laptopBrightness = intArg(10...100)
default:
    print("usage: screenfilter status | auto | on | off | warmth <0-100> | brightness <10-100> | laptop-brightness <10-100>"); exit(2)
}
saveSettings(s)
// The daemon applies the change; report what the display shows once it has.
let deadline = Date().addingTimeInterval(2)
while !matches(s) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
printStatus()
