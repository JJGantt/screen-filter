// DDC/CI over the M1's DCP AV service: read or set a VCP value on external displays.
// usage: ddc get <vcp> | ddc set <vcp> <value>   (vcp in hex or decimal; 0x10 brightness, 0x12 contrast)
import Foundation
import IOKit

typealias IOAVService = CFTypeRef
@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ a: CFAllocator?, _ s: io_service_t) -> Unmanaged<IOAVService>?
@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ s: IOAVService, _ chip: UInt32, _ off: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn
@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ s: IOAVService, _ chip: UInt32, _ off: UInt32, _ buf: UnsafeMutableRawPointer, _ len: UInt32) -> IOReturn

func externalServices() -> [IOAVService] {
    var out: [IOAVService] = []
    var it = io_iterator_t()
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return out }
    while case let s = IOIteratorNext(it), s != 0 {
        let loc = IORegistryEntryCreateCFProperty(s, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        if loc == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, s) { out.append(av.takeRetainedValue()) }
        IOObjectRelease(s)
    }
    IOObjectRelease(it)
    return out
}

// Checksum seed: a set-VCP packet includes the 0x51 source address, a get-VCP request does not
// (the convention LG and most monitors answer to; with 0x51 in a request they reply with a null message).
func write(_ av: IOAVService, _ payload: [UInt8]) -> Bool {
    var pkt = [UInt8(0x80 | payload.count)] + payload
    pkt.append(pkt.reduce(payload.count == 2 ? UInt8(0x6E) : UInt8(0x6E ^ 0x51), ^))
    // The DDC/CI spec requires a gap between messages; retry because monitors drop the odd packet.
    for _ in 0..<3 {
        usleep(10_000)
        if IOAVServiceWriteI2C(av, 0x37, 0x51, &pkt, UInt32(pkt.count)) == kIOReturnSuccess { return true }
    }
    return false
}

func get(_ av: IOAVService, _ vcp: UInt8) -> (cur: Int, max: Int)? {
    for _ in 0..<3 {
        guard write(av, [0x01, vcp]) else { continue }
        usleep(50_000)  // DDC/CI: host waits >= 40ms before reading the reply
        var r = [UInt8](repeating: 0, count: 12)
        let rr = IOAVServiceReadI2C(av, 0x37, 0x51, &r, 12); if ProcessInfo.processInfo.environment["DDC_DEBUG"] != nil { print(rr, r.map { String(format: "%02x", $0) }.joined(separator: " ")) }; guard rr == kIOReturnSuccess, r[3] == vcp, r[2] == 0 else { continue }
        return ((Int(r[8]) << 8) | Int(r[9]), (Int(r[6]) << 8) | Int(r[7]))
    }
    return nil
}

func num(_ s: String) -> Int? { s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s) }

let a = Array(CommandLine.arguments.dropFirst())
let svcs = externalServices()
guard !svcs.isEmpty else { FileHandle.standardError.write("no external display\n".data(using: .utf8)!); exit(1) }
guard a.count >= 2, let vcp = num(a[1]).map(UInt8.init) else { print("usage: ddc get <vcp> | ddc set <vcp> <value>"); exit(2) }
var failed = false
for av in svcs {
    switch a[0] {
    case "get":
        if let v = get(av, vcp) { print("\(v.cur) / \(v.max)") } else { print("no reply"); failed = true }
    case "set":
        guard a.count == 3, let v = num(a[2]) else { print("usage: ddc set <vcp> <value>"); exit(2) }
        if !write(av, [0x03, vcp, UInt8(v >> 8), UInt8(v & 0xff)]) { print("write failed"); failed = true }
    default: print("usage: ddc get <vcp> | ddc set <vcp> <value>"); exit(2)
    }
}
exit(failed ? 1 : 0)
