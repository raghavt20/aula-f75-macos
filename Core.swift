// Core of F75 Music: keyboard protocol, audio capture, spectrum analysis, LED rendering.
//
// Protocol (reverse engineered from the vendor's OemDrv.exe, CDevG5KB vtable+0x38 -> AccessData):
//   HID feature report 0x06, 520 bytes total:
//     [0x06, cmd=0x08, 0x00, 0x00, nPages=1, page=0, lenLo, lenHi] + 512 data bytes
//   data = 378 bytes = 126 LEDs * (R, G, B), LED-indexed.
//   LED index of a key = column * 6 + row (row 0 = F-key row, row 5 = bottom row).
//   The vendor app streams one frame every 20 ms; no mode switch is sent first.

import Foundation
import IOKit.hid
import CoreGraphics
import ScreenCaptureKit
import CoreMedia
import Accelerate

// MARK: - Keyboard layout (from Dev/kb/1/KB.ini: name, x-left, x-right, led index)

struct Key {
    let name: String
    let x0: Double, x1: Double   // horizontal extent in KB.ini pixels
    let led: Int
    var row: Int { led % 6 }      // 0 = F-key row … 5 = bottom row
    var x: Double { (x0 + x1) / 2 }
    var y: Double { 43.5 + Double(row) * 39 }   // approximate vertical centre, same pixel units
    /// 0…1 across the board
    var u: Double { (x - 30) / 600 }
}

private let rawKeys: [(String, Int, Int, Int)] = [
    ("Esc",30,55,0),("F1",107,132,12),("F2",144,169,18),("F3",183,208,24),("F4",222,247,30),
    ("F5",269,294,36),("F6",305,330,42),("F7",343,368,48),("F8",388,413,54),("F9",439,464,60),
    ("F10",477,502,66),("F11",516,541,72),("F12",555,580,78),
    ("`",31,56,1),("1",70,95,7),("2",108,133,13),("3",147,172,19),("4",184,209,25),("5",223,248,31),
    ("6",262,287,37),("7",300,325,43),("8",338,363,49),("9",377,402,55),("0",416,441,61),
    ("-",453,478,67),("=",491,516,73),("Backspace",531,591,79),("Delete",604,629,85),
    ("Tab",34,78,2),("Q",89,114,8),("W",127,152,14),("E",165,190,20),("R",204,229,26),("T",242,267,32),
    ("Y",280,305,38),("U",318,343,44),("I",356,381,50),("O",395,420,56),("P",433,458,62),
    ("[",471,496,68),("]",509,534,74),("\\",549,593,80),("PgUp",605,630,86),
    ("CapsLock",33,85,3),("A",98,123,9),("S",136,161,15),("D",174,199,21),("F",213,238,27),
    ("G",252,277,33),("H",290,315,39),("J",327,352,45),("K",366,391,51),("L",405,430,57),
    (";",443,468,63),("'",481,506,69),("Enter",521,591,81),("PgDn",604,629,87),
    ("LShift",33,105,4),("Z",116,141,10),("X",155,180,16),("C",193,218,22),("V",232,257,28),
    ("B",270,295,34),("N",309,334,40),("M",347,372,46),(",",384,409,52),(".",424,449,58),
    ("/",463,488,64),("RShift",502,558,70),("Up",567,592,82),("End",605,630,88),
    ("LCtrl",34,69,5),("LWin",79,114,11),("LAlt",122,157,17),("Space",174,400,35),("FN",414,449,53),
    ("RCtrl",463,497,59),("Left",529,554,77),("Down",568,593,83),("Right",605,630,89),
]
let keys: [Key] = rawKeys.map { Key(name: $0.0, x0: Double($0.1), x1: Double($0.2), led: $0.3) }

let kLedCount = 126
let kRows = 6

// MARK: - Diagnostics (~/Library/Logs/F75Music.log)

func log(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/F75Music.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - HID
//
// Two protocols, both from OemDrv.exe:
//  • USB cable (258a:010c), class CDevG5KB: feature report 0x06, 520 bytes,
//      [0x06, 0x08, 0, 0, nPages=1, page=0, lenLo, lenHi] + 378 bytes LED-indexed RGB.
//  • Bluetooth / 2.4 GHz (vendor 0x3554), class CDev3632: output report 0x13, 20 bytes,
//      [0x13, cmd=0x88, nPackets, index, (sub<<4)|len, data[14], checksum(sum of bytes 0..18)]
//    Music data is the compact form: groups of [R, G, B, count, led...], at most 200 bytes, sub=1.
//    Wireless writes are slow (~30 ms each), so frames are small and sent as fast as the link allows.

enum Connection: String { case usb = "USB", bluetooth = "Bluetooth", dongle = "2.4 GHz" }

enum OpenResult { case ok(Connection), notFound, notPermitted }

final class F75 {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private(set) var link: Connection?
    private let lock = NSLock()

    func open() -> OpenResult {
        lock.lock(); defer { lock.unlock() }
        if let m = manager { IOHIDManagerClose(m, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil; link = nil; inputQueue = nil
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = m
        IOHIDManagerSetDeviceMatchingMultiple(m, [
            [kIOHIDVendorIDKey: 0x258a, kIOHIDProductIDKey: 0x010c],
            [kIOHIDVendorIDKey: 0x3554],
        ] as CFArray)
        let mr = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        let set = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>) ?? []
        log("open: manager=\(hex(mr)) access=\(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent).rawValue) devices=\(set.count)")
        var denied = mr == kIOReturnNotPermitted

        // Prefer the cable: much faster.
        for d in set where vendor(d) == 0x258a && intProp(d, kIOHIDMaxFeatureReportSizeKey) >= 520 {
            let r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
            log("  usb iface open=\(hex(r))")
            if r == kIOReturnNotPermitted { denied = true; continue }
            device = d; link = .usb
            if sendLocked(solidFrame(0, 0, 0)) { return .ok(.usb) }
            log("  usb probe frame failed")
        }
        for d in set where vendor(d) == 0x3554 {
            let pid = intProp(d, kIOHIDProductIDKey)
            let vendorPage = hasUsagePage(d, 0xFF02)
            let r = IOHIDDeviceOpen(d, IOOptionBits(kIOHIDOptionsTypeNone))
            log("  wireless pid=\(String(format: "%04x", pid)) ff02=\(vendorPage) open=\(hex(r))")
            if !vendorPage { continue }
            if r == kIOReturnNotPermitted { denied = true; continue }
            let transport = (IOHIDDeviceGetProperty(d, kIOHIDTransportKey as CFString) as? String) ?? ""
            let l: Connection = transport.localizedCaseInsensitiveContains("bluetooth") ? .bluetooth : .dongle
            device = d; link = l
            startInput(d)
            return .ok(l)   // wireless writes are slow; don't block on a probe frame
        }
        device = nil; link = nil
        return denied ? .notPermitted : .notFound
    }

    private func hex(_ r: IOReturn) -> String { String(format: "0x%08x", UInt32(bitPattern: r)) }

    /// frame: 378 bytes, LED-indexed RGB.
    @discardableResult
    func send(_ frame: [UInt8]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sendLocked(frame)
    }

    /// Ask the keyboard to leave music mode (wireless) / clear the music layer (USB).
    func clear() {
        lock.lock(); defer { lock.unlock() }
        if link == .usb { _ = sendLocked(solidFrame(0, 0, 0)) } else { _ = sendWireless([0, 0, 0], sub: 2) }
    }

    private func sendLocked(_ frame: [UInt8]) -> Bool {
        guard device != nil, let l = link else { return false }
        return l == .usb ? sendUSB(frame) : sendWireless(compact(frame), sub: 1)
    }

    // MARK: Onboard lighting profile (128 bytes, ends with 5A A5)
    //   byte 10 = active built-in effect (firmware id, e.g. 20 = Ripples shining, 17 = Reaction)
    //   USB:      feature report 0x06, cmd 0x84 = read / 0x04 = write  (CDevG5KB GetLED/SetLED)
    //   Wireless: output/input report 0x13, cmd 0x44 = read / 0x04 = write (CDev3632 GetLED/SetLED)

    private var inputQueue: DispatchQueue?
    private var inputBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let inputLock = NSLock()
    private var inputs: [[UInt8]] = []
    private let inputSignal = DispatchSemaphore(value: 0)

    private func startInput(_ d: IOHIDDevice) {
        guard inputQueue == nil else { return }
        let q = DispatchQueue(label: "hid-input")
        inputQueue = q
        IOHIDDeviceSetDispatchQueue(d, q)
        IOHIDDeviceRegisterInputReportCallback(d, inputBuf, 64, { ctx, _, _, _, id, rep, len in
            guard id == 0x13 else { return }
            let me = Unmanaged<F75>.fromOpaque(ctx!).takeUnretainedValue()
            var r = Array(UnsafeBufferPointer(start: rep, count: len))
            if r.first != 0x13 { r.insert(0x13, at: 0) }      // some stacks strip the report ID
            me.inputLock.lock(); me.inputs.append(r); me.inputLock.unlock()
            me.inputSignal.signal()
        }, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceActivate(d)
    }

    private func nextInput(timeout: Double) -> [UInt8]? {
        if inputSignal.wait(timeout: .now() + timeout) == .timedOut { return nil }
        inputLock.lock(); defer { inputLock.unlock() }
        return inputs.isEmpty ? nil : inputs.removeFirst()
    }

    private func wirelessPacket(cmd: UInt8, count: Int, index: Int, sub: UInt8, chunk: ArraySlice<UInt8>) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 20)
        p[0] = 0x13; p[1] = cmd; p[2] = UInt8(count); p[3] = UInt8(index)
        p[4] = (sub << 4) | UInt8(chunk.count)
        for (j, b) in chunk.enumerated() { p[5 + j] = b }
        p[19] = UInt8(truncatingIfNeeded: p[0..<19].reduce(0) { $0 + Int($1) })
        return p
    }

    func readLEDProfile() -> [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        guard let d = device, let l = link else { return nil }
        if l == .usb {
            var req = [UInt8](repeating: 0, count: 520)
            req[0] = 0x06; req[1] = 0x84; req[4] = 1; req[5] = 0; req[6] = 0x80
            guard IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 0x06, req, req.count) == kIOReturnSuccess else { return nil }
            usleep(20_000)
            var resp = [UInt8](repeating: 0, count: 520)
            var len = resp.count
            guard IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 0x06, &resp, &len) == kIOReturnSuccess else { return nil }
            log("usb led read hdr: " + resp[0..<8].map { String(format: "%02x", $0) }.joined(separator: " "))
            return Array(resp[8..<(8 + 128)])
        }
        // Replies are 10 packets of 14 bytes; Bluetooth drops some, so collect by index and re-request.
        var slots = [[UInt8]?](repeating: nil, count: 10)
        var total = 10
        for attempt in 0..<40 {
            inputLock.lock(); inputs.removeAll(); inputLock.unlock()
            while inputSignal.wait(timeout: .now()) == .success {}
            let req = wirelessPacket(cmd: 0x44, count: 1, index: 0, sub: 0, chunk: [])
            let sr = IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0x13, req, req.count)
            if sr != kIOReturnSuccess { log("led read request \(attempt) -> \(String(format: "0x%08x", UInt32(bitPattern: sr)))"); usleep(200_000); continue }
            while let r = nextInput(timeout: 0.4) {
                guard r.count >= 20, r[1] == 0x44 else { continue }
                total = max(1, min(slots.count, Int(r[2] & 0x7f)))
                let idx = Int(r[3])
                if idx < slots.count { slots[idx] = Array(r[5..<(5 + min(14, Int(r[4] & 0x0f)))]) }
                if slots[0..<total].allSatisfy({ $0 != nil }) { break }
            }
            let have = slots[0..<total].filter { $0 != nil }.count
            log("led read attempt \(attempt): \(have)/\(total) packets, have=\(slots.enumerated().filter { $0.element != nil }.map { $0.offset })")
            if have == total { break }
        }
        guard slots[0..<total].allSatisfy({ $0 != nil }) else { return nil }
        let data = slots[0..<total].flatMap { $0! }
        return data.count >= 128 ? Array(data[0..<128]) : nil
    }

    /// Read the profile and keep a one-time backup of the original.
    func backupLEDProfile() -> [UInt8]? {
        guard let p = readLEDProfile() else { log("led read failed"); return nil }
        for i in stride(from: 0, to: p.count, by: 16) {
            log(String(format: "led %02x: ", i) + p[i..<min(i + 16, p.count)].map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/F75Music")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("led_profile_backup.bin")
        if !FileManager.default.fileExists(atPath: f.path), p.count == 128, p[126] == 0x5A, p[127] == 0xA5 {
            try? Data(p).write(to: f); log("saved backup to \(f.path)")
        }
        return p
    }

    static var backupURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/F75Music/led_profile_backup.bin")
    }

    /// Switch the keyboard's built-in (onboard) effect, keeping every other setting.
    /// Over the cable the live profile is read first; over Bluetooth replies are unreliable on macOS,
    /// so the saved profile is used as the base (only byte 10 changes).
    func setOnboardEffect(_ id: UInt8) -> Bool {
        var base: [UInt8]?
        // Live profile over the cable or the dongle (reliable replies); Bluetooth drops replies on macOS.
        if link == .usb || link == .dongle { base = readLEDProfile() }
        if base == nil || base!.count != 128 { base = (try? Data(contentsOf: F75.backupURL)).map { [UInt8]($0) } }
        guard var p = base, p.count == 128, p[126] == 0x5A, p[127] == 0xA5 else { log("no valid base profile"); return false }
        p[10] = id
        let ok = writeLEDProfile(p)
        log("set onboard effect \(id) -> \(ok)")
        return ok
    }

    func restoreLEDProfile() -> Bool {
        guard let d = try? Data(contentsOf: F75.backupURL) else { return false }
        return writeLEDProfile([UInt8](d))
    }

    func writeLEDProfile(_ profile: [UInt8]) -> Bool {
        guard profile.count == 128, profile[126] == 0x5A, profile[127] == 0xA5 else { log("refusing to write: bad profile"); return false }
        lock.lock(); defer { lock.unlock() }
        guard let d = device, let l = link else { return false }
        if l == .usb {
            var req = [UInt8](repeating: 0, count: 520)
            req[0] = 0x06; req[1] = 0x04; req[4] = 1; req[5] = 0; req[6] = 0x80
            for i in 0..<128 { req[8 + i] = profile[i] }
            return IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 0x06, req, req.count) == kIOReturnSuccess
        }
        inputLock.lock(); inputs.removeAll(); inputLock.unlock()
        while inputSignal.wait(timeout: .now()) == .success {}
        let n = (128 + 13) / 14
        for i in 0..<n {
            let p = wirelessPacket(cmd: 0x04, count: n, index: i, sub: 0, chunk: profile[(i * 14)..<min(128, i * 14 + 14)])
            guard IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0x13, p, p.count) == kIOReturnSuccess else { return false }
            _ = nextInput(timeout: 0.5)   // wait for the keyboard's acknowledgement
            usleep(15_000)
        }
        return true
    }

    // Diagnostics: one log line per second summarising frame sends.
    private var statOK = 0, statFail = 0, statLastErr: IOReturn = 0, statSince = Date()
    private func noteSend(_ r: IOReturn) {
        if r == kIOReturnSuccess { statOK += 1 } else { statFail += 1; statLastErr = r }
        if Date().timeIntervalSince(statSince) >= 10 {
            if statFail > 0 { log("sends (10s): ok=\(statOK) fail=\(statFail) lastErr=\(String(format: "0x%08x", UInt32(bitPattern: statLastErr)))") }
            statOK = 0; statFail = 0; statLastErr = 0; statSince = Date()
        }
    }

    private func sendUSB(_ frame: [UInt8]) -> Bool {
        guard let d = device else { return false }
        let len = min(frame.count, 378)
        var report = [UInt8](repeating: 0, count: 520)
        report[0] = 0x06            // report ID (Fw=0x18 boards)
        report[1] = 0x08            // command: music real-time data
        report[4] = 1               // number of pages
        report[5] = 0               // page index
        report[6] = UInt8(len & 0xff)
        report[7] = UInt8(len >> 8)
        for i in 0..<len { report[8 + i] = frame[i] }
        let r = IOHIDDeviceSetReport(d, kIOHIDReportTypeFeature, 0x06, report, report.count)
        noteSend(r)
        return r == kIOReturnSuccess
    }

    private func sendWireless(_ data: [UInt8], sub: UInt8) -> Bool {
        guard let d = device, !data.isEmpty else { return false }
        let n = (data.count + 13) / 14
        for i in 0..<n {
            var p = [UInt8](repeating: 0, count: 20)
            let chunk = data[(i * 14)..<min(data.count, i * 14 + 14)]
            p[0] = 0x13; p[1] = 0x88; p[2] = UInt8(n); p[3] = UInt8(i)
            p[4] = (sub << 4) | UInt8(chunk.count)
            for (j, b) in chunk.enumerated() { p[5 + j] = b }
            p[19] = UInt8(truncatingIfNeeded: p[0..<19].reduce(0) { $0 + Int($1) })
            let r = IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 0x13, p, p.count)
            noteSend(r)
            if r != kIOReturnSuccess { return false }
        }
        return true
    }

    /// LED-indexed RGB -> groups of [R, G, B, count, led...] (lit keys only), capped at 200 bytes.
    /// Wireless frame size in 20-byte packets. The Bluetooth link moves one packet per ~30 ms,
    /// so 2 packets ≈ 16 fps, 3 ≈ 11 fps, 6 ≈ 5 fps.
    var wirelessPackets: Int {
        get { lock.lock(); defer { lock.unlock() }; return _wirelessPackets }
        set { lock.lock(); _wirelessPackets = max(1, min(14, newValue)); lock.unlock() }
    }
    private var _wirelessPackets = 2
    /// Wireless key numbering vs. the KB.ini LED index (measured: the keyboard lights index+1).
    var wirelessLedOffset: Int {
        get { lock.lock(); defer { lock.unlock() }; return _wirelessLedOffset }
        set { lock.lock(); _wirelessLedOffset = newValue; lock.unlock() }
    }
    private var _wirelessLedOffset = -1   // verified on the 2.4 GHz link: W A S D sent as index-1 light W A S D

    /// LED-indexed RGB -> groups of [R, G, B, count, led...] that fit the packet budget.
    /// Colours are simplified (3 hue levels per channel x 3 brightness levels) so keys share groups,
    /// and the brightest keys win when the budget runs out.
    private func compact(_ frame: [UInt8]) -> [UInt8] {
        let budget = _wirelessPackets * 14
        struct Lit { let led: UInt8; let color: UInt32; let v: Int }
        var lit: [Lit] = []
        for k in keys {
            let r = Int(frame[k.led * 3]), g = Int(frame[k.led * 3 + 1]), b = Int(frame[k.led * 3 + 2])
            let m = max(r, g, b)
            if m < (link == .bluetooth ? 48 : 20) { continue }
            // Fewer distinct colours on Bluetooth (tiny frames); finer steps on the faster 2.4 GHz dongle.
            let steps = link == .bluetooth ? 3.0 : 8.0, hues = link == .bluetooth ? 2.0 : 4.0
            let level = (Double(m) / 255 * steps).rounded() / steps
            func q(_ c: Int) -> UInt32 { UInt32(((Double(c) / Double(m) * hues).rounded() / hues * level * 255).rounded()) }
            let c = q(r) << 16 | q(g) << 8 | q(b)
            if c == 0 { continue }
            lit.append(Lit(led: UInt8(k.led), color: c, v: m))
        }
        lit.sort { $0.v > $1.v }
        var order: [UInt32] = []
        var groups: [UInt32: [UInt8]] = [:]
        var size = 0
        for l in lit {
            let cost = groups[l.color] == nil ? 5 : 1
            if size + cost > budget { continue }
            if groups[l.color] == nil { order.append(l.color); groups[l.color] = [] }
            groups[l.color]!.append(UInt8(truncatingIfNeeded: Int(l.led) + _wirelessLedOffset))
            size += cost
        }
        var out: [UInt8] = []
        for c in order {
            let ledsForColor = groups[c]!
            out += [UInt8(c >> 16 & 0xff), UInt8(c >> 8 & 0xff), UInt8(c & 0xff), UInt8(ledsForColor.count)] + ledsForColor
        }
        return out.isEmpty ? [0, 0, 0, 0] : out
    }

    private func vendor(_ d: IOHIDDevice) -> Int { intProp(d, kIOHIDVendorIDKey) }
    private func intProp(_ d: IOHIDDevice, _ k: String) -> Int { (IOHIDDeviceGetProperty(d, k as CFString) as? Int) ?? 0 }
    private func hasUsagePage(_ d: IOHIDDevice, _ page: Int) -> Bool {
        guard let pairs = IOHIDDeviceGetProperty(d, kIOHIDDeviceUsagePairsKey as CFString) as? [[String: Int]] else { return false }
        return pairs.contains { $0[kIOHIDDeviceUsagePageKey] == page }
    }
}

// MARK: - Audio analysis

final class Analyzer {
    let fftSize = 2048
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]
    private var ring: [Float]
    private var ringPos = 0
    private let lock = NSLock()
    var sampleRate: Double = 48000

    init() {
        log2n = vDSP_Length(log2(Double(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: fftSize)
    }

    func push(_ samples: UnsafePointer<Float>, count: Int) {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<count {
            ring[ringPos] = samples[i]
            ringPos = (ringPos + 1) % fftSize
        }
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        for i in 0..<fftSize { ring[i] = 0 }
    }

    /// Returns `n` log-spaced band magnitudes in dB (unnormalised).
    func bands(_ n: Int) -> [Float] {
        var buf = [Float](repeating: 0, count: fftSize)
        lock.lock()
        for i in 0..<fftSize { buf[i] = ring[(ringPos + i) % fftSize] }
        lock.unlock()
        vDSP_vmul(buf, 1, window, 1, &buf, 1, vDSP_Length(fftSize))

        let half = fftSize / 2
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var mags = [Float](repeating: 0, count: half)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                buf.withUnsafeBufferPointer { bp in
                    bp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(half))
            }
        }
        let binHz = sampleRate / Double(fftSize)
        let fLo = 40.0, fHi = 14000.0
        var out = [Float](repeating: 0, count: n)
        for b in 0..<n {
            let f0 = fLo * pow(fHi / fLo, Double(b) / Double(n))
            let f1 = fLo * pow(fHi / fLo, Double(b + 1) / Double(n))
            let i0 = max(1, Int(f0 / binHz)), i1 = max(i0 + 1, min(half, Int(f1 / binHz)))
            var peak: Float = 0
            for i in i0..<i1 { peak = max(peak, mags[i]) }
            let tilt = Float(1.0 + 1.5 * Double(b) / Double(n)) // keep highs visible next to bass
            out[b] = 20 * log10(max(peak * tilt, 1e-6))
        }
        return out
    }
}

final class AudioTap: NSObject, SCStreamOutput, SCStreamDelegate {
    let analyzer: Analyzer
    var onStop: ((Error) -> Void)?
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "audio")

    init(_ a: Analyzer) { analyzer = a }

    func start() async throws {
        if stream != nil { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "F75Music", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 1
        cfg.width = 2; cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        analyzer.sampleRate = 48000
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        try? await s.stopCapture()
        analyzer.clear()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid else { return }
        var blockBuffer: CMBlockBuffer?
        var abl = AudioBufferList()
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard st == noErr, let data = abl.mBuffers.mData else { return }
        let n = Int(abl.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
        analyzer.push(data.assumingMemoryBound(to: Float.self), count: n)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }
}

// MARK: - Frames

func solidFrame(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> [UInt8] {
    var f = [UInt8](repeating: 0, count: kLedCount * 3)
    for k in keys { f[k.led * 3] = r; f[k.led * 3 + 1] = g; f[k.led * 3 + 2] = b }
    return f
}

// MARK: - Key presses (for Typing Ripple) — needs Input Monitoring

final class KeyWatcher {
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let lock = NSLock()
    private var pressed: [Int] = []
    private var started = false

    /// HID keyboard usage (page 0x07) -> key name used in `keys`
    private static let usageNames: [Int: String] = {
        var m: [Int: String] = [:]
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { m[4 + i] = String(c) }
        for (i, c) in "1234567890".enumerated() { m[30 + i] = String(c) }
        for i in 0..<12 { m[58 + i] = "F\(i + 1)" }
        let rest: [Int: String] = [
            40: "Enter", 41: "Esc", 42: "Backspace", 43: "Tab", 44: "Space", 45: "-", 46: "=", 47: "[", 48: "]",
            49: "\\", 51: ";", 52: "'", 53: "`", 54: ",", 55: ".", 56: "/", 57: "CapsLock",
            75: "PgUp", 76: "Delete", 77: "End", 78: "PgDn", 79: "Right", 80: "Left", 81: "Down", 82: "Up",
            224: "LCtrl", 225: "LShift", 226: "LAlt", 227: "LWin", 228: "RCtrl", 229: "RShift", 230: "RCtrl", 231: "RCtrl",
        ]
        m.merge(rest) { $1 }
        return m
    }()
    private static let indexByName: [String: Int] = Dictionary(uniqueKeysWithValues: keys.enumerated().map { ($1.name, $0) })

    /// macOS virtual key code -> key name used in `keys` (F75 in Mac mode: Win = Option, Alt = Command).
    private static let keyCodeNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Enter",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Backspace", 53: "Esc", 54: "RCtrl", 55: "LAlt", 56: "LShift",
        57: "CapsLock", 58: "LWin", 59: "LCtrl", 60: "RShift", 61: "RCtrl", 62: "RCtrl", 63: "FN",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 116: "PgUp", 121: "PgDn", 117: "Delete", 119: "End",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
    ]
    private static let modifierMask: [Int: CGEventFlags] = [
        54: .maskCommand, 55: .maskCommand, 56: .maskShift, 60: .maskShift, 57: .maskAlphaShift,
        58: .maskAlternate, 61: .maskAlternate, 59: .maskControl, 62: .maskControl, 63: .maskSecondaryFn,
    ]
    private var tap: CFMachPort?

    func start() {
        guard !started else { return }
        started = true
        // A listen-only event tap sees key presses whichever app is in front (needs Input Monitoring).
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: CGEventMask(mask), callback: { _, type, event, ctx in
            let me = Unmanaged<KeyWatcher>.fromOpaque(ctx!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return Unmanaged.passUnretained(event) }
            if type == .flagsChanged {   // modifier: only react on press, not release
                guard let m = KeyWatcher.modifierMask[code], event.flags.contains(m) else { return Unmanaged.passUnretained(event) }
            }
            if let name = KeyWatcher.keyCodeNames[code], let idx = KeyWatcher.indexByName[name] {
                me.lock.lock(); me.pressed.append(idx); me.lock.unlock()
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: ctx)
        if let t = tap {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            log("keywatcher: event tap active")
            return
        }
        // Fallback (no permission for a tap): HID values, which macOS only delivers while we're in front.
        log("keywatcher: event tap unavailable, falling back to HID (foreground only)")
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDVendorIDKey: 0x258a, kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6],
            [kIOHIDVendorIDKey: 0x3554, kIOHIDDeviceUsagePageKey: 1, kIOHIDDeviceUsageKey: 6],
        ] as CFArray)
        IOHIDManagerRegisterInputValueCallback(manager, { ctx, _, _, value in
            let me = Unmanaged<KeyWatcher>.fromOpaque(ctx!).takeUnretainedValue()
            let e = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(e) == 0x07, IOHIDValueGetIntegerValue(value) == 1 else { return }
            if IOHIDElementGetUsage(e) > 0xE7 { return }
            let usage = Int(IOHIDElementGetUsage(e))
            guard let name = KeyWatcher.usageNames[usage], let idx = KeyWatcher.indexByName[name] else { return }
            me.lock.lock(); me.pressed.append(idx); me.lock.unlock()
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Keys pressed since the last call.
    func drain() -> [Int] {
        lock.lock(); defer { lock.unlock() }
        let p = pressed; pressed.removeAll(keepingCapacity: true); return p
    }
}
