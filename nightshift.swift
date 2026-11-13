// Controls macOS Night Shift through the private CoreBrightness CBBlueLightClient.
// usage: nightshift status | on | off | warmth <0-100> | schedule sunset|off|HH:MM-HH:MM
import Foundation

@objc protocol BlueLight {
    func setEnabled(_ on: Bool) -> Bool
    func setStrength(_ s: Float, commit: Bool) -> Bool
    func getStrength(_ s: UnsafeMutablePointer<Float>) -> Bool
    func setMode(_ m: Int32) -> Bool
    func setSchedule(_ s: UnsafeMutableRawPointer) -> Bool
    func getBlueLightStatus(_ s: UnsafeMutableRawPointer) -> Bool
}

guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
      let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else {
    FileHandle.standardError.write("CoreBrightness unavailable\n".data(using: .utf8)!); exit(1)
}
let client = unsafeBitCast(cls.init(), to: BlueLight.self)

// Status struct: active, enabled, sunSchedulePermitted (BOOLs), mode (int),
// schedule {from{hour,minute}, to{hour,minute}} (ints), disableFlags (uint64)
struct Status { var active: Bool = false; var enabled: Bool = false; var sunOK: Bool = false
    var mode: Int32 = 0; var fh: Int32 = 0; var fm: Int32 = 0; var th: Int32 = 0; var tm: Int32 = 0
    var flags: UInt64 = 0; var a: Bool = false; var b: Bool = false }

func status() {
    var s = Status(); var strength: Float = 0
    _ = withUnsafeMutablePointer(to: &s) { client.getBlueLightStatus(UnsafeMutableRawPointer($0)) }
    _ = client.getStrength(&strength)
    let modes = ["manual only", "sunset to sunrise", "custom schedule"]
    let mode = s.mode >= 0 && s.mode < 3 ? modes[Int(s.mode)] : "mode \(s.mode)"
    print("on now:   \(s.active ? "yes" : "no")")
    print("warmth:   \(Int((strength * 100).rounded()))")
    print("schedule: \(mode)" + (s.mode == 2 ? String(format: " %02d:%02d-%02d:%02d", s.fh, s.fm, s.th, s.tm) : ""))
    if s.mode == 1 && !s.sunOK { print("note: sunset schedule needs Location Services for System Services") }
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "status" {
case "status": status()
case "on": _ = client.setEnabled(true); status()
case "off": _ = client.setEnabled(false); status()
case "warmth":
    guard args.count > 1, let v = Float(args[1]), (0...100).contains(v) else { print("warmth 0-100"); exit(2) }
    _ = client.setStrength(v / 100, commit: true); status()
case "schedule":
    let arg = args.count > 1 ? args[1] : ""
    if arg == "sunset" { _ = client.setMode(1) }
    else if arg == "off" { _ = client.setMode(0) }
    else {
        let p = arg.split(whereSeparator: { $0 == "-" || $0 == ":" }).compactMap { Int32($0) }
        guard p.count == 4 else { print("schedule sunset | off | HH:MM-HH:MM"); exit(2) }
        var sched: [Int32] = p
        _ = sched.withUnsafeMutableBytes { client.setSchedule($0.baseAddress!) }
        _ = client.setMode(2)
    }
    status()
default: print("usage: nightshift status | on | off | warmth <0-100> | schedule sunset|off|HH:MM-HH:MM"); exit(2)
}
