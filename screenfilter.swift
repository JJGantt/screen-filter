// Warm/dim filter for external displays, applied through the GPU gamma tables.
//
//   screenfilter daemon                  run the filter (launchd keeps this alive)
//   screenfilter status                  settings and whether the filter is on now
//   screenfilter auto | on | off         warm when Night Shift is active / always / never
//   screenfilter warmth <0-100>          0 = no tint, 100 = deep amber (1900K)
//   screenfilter brightness <10-100>     scales the external display's output, day and night
//
// A gamma table only lasts as long as the process that set it, and macOS resets it on sleep/wake
// and display changes, so the daemon stays running and reapplies on each of those events.
import AppKit
import Foundation

// MARK: settings

let configURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/screen-filter/config.json")

struct Settings: Codable {
    var mode = "auto"
    var warmth = 50
    var brightness = 100
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
    do { try enc.encode(s).write(to: configURL, options: .atomic) } catch { logError("cannot write config: \(error)"); exit(1) }
}

func log(_ m: String) { print("\(Date()) \(m)"); fflush(stdout) }
func logError(_ m: String) { FileHandle.standardError.write("\(Date()) ERROR \(m)\n".data(using: .utf8)!) }

// MARK: Night Shift state (private CoreBrightness CBBlueLightClient)

@objc protocol BlueLight {
    func getBlueLightStatus(_ s: UnsafeMutableRawPointer) -> Bool
    func setStatusNotificationBlock(_ b: @escaping @convention(block) (UnsafeMutableRawPointer?) -> Void)
}

struct BlueLightStatus {
    var supported = false, on = false, sunOK = false  // `on`: the tint is showing now; the first byte stays set
    var mode: Int32 = 0, fh: Int32 = 0, fm: Int32 = 0, th: Int32 = 0, tm: Int32 = 0
    var flags: UInt64 = 0, available = false, extra = false
}

let blueLight: BlueLight? = {
    guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
          let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
    return unsafeBitCast(cls.init(), to: BlueLight.self)
}()

func nightShiftActive() -> Bool {
    guard let bl = blueLight else { logError("CoreBrightness unavailable; treating Night Shift as off"); return false }
    var s = BlueLightStatus()
    _ = withUnsafeMutablePointer(to: &s) { bl.getBlueLightStatus(UnsafeMutableRawPointer($0)) }
    return s.on
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

func externalDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
}

/// What each external display's table should be right now: (r, g, b) channel scale.
func target(_ s: Settings) -> (Double, Double, Double) {
    let warm = s.mode == "on" || (s.mode == "auto" && nightShiftActive())
    let k = warm ? 6500 - Double(min(max(s.warmth, 0), 100)) / 100 * (6500 - 1900) : 6500
    let (r, g, b) = rgb(kelvin: k)
    let bright = Double(min(max(s.brightness, 10), 100)) / 100
    return (r * bright, g * bright, b * bright)
}

let tableSize = 256

func apply(_ s: Settings, reason: String) {
    let (r, g, b) = target(s)
    for d in externalDisplays() {
        let ramp = (0..<tableSize).map { CGGammaValue(Double($0) / Double(tableSize - 1)) }
        let err = CGSetDisplayTransferByTable(d, UInt32(tableSize), ramp.map { $0 * CGGammaValue(r) },
                                              ramp.map { $0 * CGGammaValue(g) }, ramp.map { $0 * CGGammaValue(b) })
        if err != .success { logError("gamma set failed on display \(d): \(err.rawValue)") }
    }
    log(String(format: "applied (%@): r %.2f g %.2f b %.2f on %d display(s)", reason, r, g, b, externalDisplays().count))
}

/// Top-of-ramp value each external display is showing, or nil when it cannot be read.
func current(_ d: CGDirectDisplayID) -> (Double, Double, Double)? {
    let cap = Int(CGDisplayGammaTableCapacity(d))
    var r = [CGGammaValue](repeating: 0, count: cap), g = r, b = r; var n: UInt32 = 0
    guard CGGetDisplayTransferByTable(d, UInt32(cap), &r, &g, &b, &n) == .success, n > 0 else { return nil }
    let i = Int(n) - 1
    return (Double(r[i]), Double(g[i]), Double(b[i]))
}

func matches(_ s: Settings) -> Bool {
    let t = target(s)
    return externalDisplays().allSatisfy { d in
        guard let c = current(d) else { return false }
        return abs(c.0 - t.0) < 0.01 && abs(c.1 - t.1) < 0.01 && abs(c.2 - t.2) < 0.01
    }
}

// MARK: daemon

func runDaemon() -> Never {
    var settings = loadSettings()
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

    // Night Shift turning on or off at sunset/sunrise is what moves the filter in auto mode.
    blueLight?.setStatusNotificationBlock { _ in reapply("night shift") }

    // Settings changes from the CLI. Watch the directory: the CLI replaces the file atomically.
    try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fd = open(configURL.deletingLastPathComponent().path, O_EVTONLY)
    let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
    watcher.setEventHandler {
        settings = loadSettings()
        apply(settings, reason: "settings")
    }
    watcher.resume()

    // Backstop behind the events above: something they did not announce reset the table.
    let backstop = DispatchSource.makeTimerSource(queue: .main)
    backstop.schedule(deadline: .now() + 300, repeating: 300)
    backstop.setEventHandler {
        if !matches(settings) {
            logError("gamma table was reset without an event; reapplying")
            apply(settings, reason: "backstop")
        }
    }
    backstop.resume()

    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler { log("stopping"); CGDisplayRestoreColorSyncSettings(); exit(0) }
    term.resume()

    apply(settings, reason: "start")
    NSApplication.shared.setActivationPolicy(.prohibited)
    NSApplication.shared.run()
    exit(0)
}

// MARK: CLI

func printStatus() {
    let s = loadSettings()
    let running = matches(s)
    print("mode:       \(s.mode)   (night shift active now: \(nightShiftActive() ? "yes" : "no"))")
    print("warmth:     \(s.warmth)")
    print("brightness: \(s.brightness)")
    for d in externalDisplays() {
        if let c = current(d) { print(String(format: "display %u:  r %.2f g %.2f b %.2f", d, c.0, c.1, c.2)) }
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
default:
    print("usage: screenfilter status | auto | on | off | warmth <0-100> | brightness <10-100>"); exit(2)
}
saveSettings(s)
// The daemon applies the change; report what the display shows once it has.
let deadline = Date().addingTimeInterval(2)
while !matches(s) && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
printStatus()
