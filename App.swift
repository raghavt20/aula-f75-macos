// F75 Music — SwiftUI front end.

import SwiftUI
import AppKit
import IOKit.hid

// MARK: - Engine

struct EffectSettings {
    var layers: Set<LayerKind> = [.typing, .starry]
    var palette: Palette = .neon
    var mono = RGB(r: 0, g: 1, b: 0)
    var gain: Float = 1
    var brightness: Double = 1
    var speed: Double = 1
    var layerLevels: [LayerKind: Double] = [:]
}

final class Engine: ObservableObject {
    static let shared = Engine()

    @Published private(set) var connected = false
    @Published private(set) var link: Connection?
    @Published private(set) var running = false
    @Published private(set) var testing = false
    @Published private(set) var listening = false     // system audio is being captured
    @Published private(set) var status = ""
    @Published private(set) var onboardEffect: Int?      // firmware id currently set on the keyboard
    @Published private(set) var applyingOnboard = false
    @Published var onboardChoice: Int = UserDefaults.standard.object(forKey: "onboardChoice") as? Int ?? 20 {
        didSet { UserDefaults.standard.set(onboardChoice, forKey: "onboardChoice") }
    }
    @Published private(set) var keyColors = [RGB](repeating: .black, count: keys.count)

    @Published var layers: Set<LayerKind> { didSet { save() } }
    @Published var palette: Palette { didSet { save() } }
    @Published var color: Color { didSet { save() } }
    @Published var gain: Double { didSet { save() } }
    @Published var brightness: Double { didSet { save() } }
    @Published var speed: Double { didSet { save() } }
    /// Per-effect brightness, e.g. ripples at 100% over a 30% wave.
    @Published var layerLevels: [LayerKind: Double] { didSet { save() } }

    func level(_ k: LayerKind) -> Double { layerLevels[k] ?? k.defaultLevel }
    /// Packets per wireless frame (Bluetooth moves ~33 packets/s): fewer = smoother, more = more keys/colours.
    @Published var wirelessPackets: Double { didSet { save() } }

    /// Name of the preset matching the current layers + palette, or "Custom".
    var presetName: String {
        presets.first { Set($0.layers) == layers && $0.palette == palette }?.name ?? "Custom"
    }

    func apply(_ p: Preset) {
        layers = Set(p.layers)
        palette = p.palette
    }

    static let bandCount = 16
    let kb = F75()
    private let analyzer = Analyzer()
    private let keyWatcher = KeyWatcher()
    private lazy var tap: AudioTap = {
        let t = AudioTap(analyzer)
        t.onStop = { [weak self] err in
            log("audio stopped: \(err)")
            DispatchQueue.main.async {
                self?.listening = false
                self?.status = "Audio capture stopped (\(err.localizedDescription)). Effects keep running; press Stop/Start to retry."
            }
        }
        return t
    }()

    // render-thread state
    private let queue = DispatchQueue(label: "render")
    private var timer: DispatchSourceTimer?
    private let settingsLock = NSLock()
    private var settings = EffectSettings()
    private let extractor = FeatureExtractor(bands: Engine.bandCount)
    private let mixer = Mixer()
    private var hue = 0.0
    private var failures = 0
    private var tick = 0
    // wireless: a separate sender that always transmits the newest frame and drops stale ones
    private let sendQueue = DispatchQueue(label: "send")
    private let pendingLock = NSLock()
    private var pending: [UInt8]?
    private var sending = false
    private var watchdog: Timer?
    private var activity: NSObjectProtocol?

    private init() {
        let d = UserDefaults.standard
        let saved = (d.string(forKey: "layers") ?? "").split(separator: ",").compactMap { LayerKind(rawValue: String($0)) }
        layers = saved.isEmpty ? Set(presets[0].layers) : Set(saved)
        palette = Palette(rawValue: d.string(forKey: "palette") ?? "") ?? presets[0].palette
        color = Color(hex: d.string(forKey: "color") ?? "00ff00")
        gain = d.object(forKey: "gain") as? Double ?? 1.0
        brightness = d.object(forKey: "brightness") as? Double ?? 1.0
        speed = d.object(forKey: "speed") as? Double ?? 1.0
        let savedLevels = d.dictionary(forKey: "layerLevels") as? [String: Double] ?? [:]
        layerLevels = Dictionary(uniqueKeysWithValues: savedLevels.compactMap { k, v in LayerKind(rawValue: k).map { ($0, v) } })
        wirelessPackets = 2   // replaced per link in connect()
        save()
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted { IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        connect()
        keyWatcher.start()
        let args = CommandLine.arguments
        if args.contains("--led-read") {
            DispatchQueue.global().async { _ = self.kb.backupLEDProfile() }
        }
        if let i = args.firstIndex(of: "--led-set"), i + 1 < args.count, let id = UInt8(args[i + 1]) {
            DispatchQueue.global().async {
                _ = self.kb.setOnboardEffect(id)
                usleep(300_000)
                if self.kb.link == .usb, let p = self.kb.readLEDProfile() { log("read back byte10=\(p[10])") }
            }
        }
        if args.contains("--rate-test") {
            // Measure how many wireless frames/packets per second the current link sustains.
            DispatchQueue.global().async {
                for packets in [1, 2, 4] {
                    self.kb.wirelessPackets = packets
                    var n = 0
                    let t0 = Date()
                    while Date().timeIntervalSince(t0) < 3 {
                        var f = solidFrame(0, 0, 0)
                        for k in keys.shuffled().prefix(packets * 14 / 2) { f[k.led * 3 + 2] = 255; f[k.led * 3] = 255 }
                        if self.kb.send(f) { n += 1 }
                    }
                    let fps = Double(n) / Date().timeIntervalSince(t0)
                    log(String(format: "rate-test link=%@ packets/frame=%d -> %.1f frames/s (%.0f packets/s)",
                               self.kb.link?.rawValue ?? "-", packets, fps, fps * Double(packets)))
                }
                self.kb.clear()
                self.kb.wirelessPackets = Int(self.wirelessPackets)
            }
        }
        if args.contains("--overlay-test") {
            // Built-in Rainbow wheel in the background, then stream only W A S D in red for 8 s.
            DispatchQueue.global().async {
                let before = self.kb.link == .usb ? self.kb.readLEDProfile()?[10] : nil
                if let i = args.firstIndex(of: "--overlay-test"), i + 1 < args.count, let off = Int(args[i + 1]) {
                    self.kb.wirelessLedOffset = off
                    log("overlay-test: wireless led offset \(off)")
                } else {
                    log("overlay-test: set onboard Rainbow wheel -> \(self.kb.setOnboardEffect(13))")
                }
                sleep(3)
                var f = solidFrame(0, 0, 0)
                let wasd = keys.filter { ["W", "A", "S", "D"].contains($0.name) }
                for k in wasd { f[k.led * 3] = 255 }
                log("overlay-test: streaming WASD red")
                let t0 = Date()
                while Date().timeIntervalSince(t0) < 8 { _ = self.kb.send(f); usleep(50_000) }
                self.kb.clear()
                log("overlay-test: done (onboard effect stays Rainbow wheel; was \(before.map(String.init) ?? "?"))")
            }
        }
        if args.contains("--autostart") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() }
        }
        for (n, label) in [(NSApplication.didResignActiveNotification, "app -> background"),
                           (NSApplication.didBecomeActiveNotification, "app -> foreground")] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { _ in log(label) }
        }
        if args.contains("--led-restore") {
            DispatchQueue.global().async { log("restore -> \(self.kb.restoreLEDProfile())") }
        }
        // Auto-connect when the keyboard appears (plugged in, woken up, released by a VM, …)
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, !self.connected, !self.running, !self.testing else { return }
            self.connect(quiet: true)
        }
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(layers.map(\.rawValue).sorted().joined(separator: ","), forKey: "layers")
        d.set(palette.rawValue, forKey: "palette")
        d.set(color.hex, forKey: "color")
        d.set(gain, forKey: "gain")
        d.set(brightness, forKey: "brightness")
        d.set(speed, forKey: "speed")
        d.set(Dictionary(uniqueKeysWithValues: layerLevels.map { ($0.key.rawValue, $0.value) }), forKey: "layerLevels")
        if let l = link, l != .usb { d.set(wirelessPackets, forKey: "wirelessPackets.\(l.rawValue)") }
        kb.wirelessPackets = Int(wirelessPackets)
        let (r, g, b) = color.rgb
        settingsLock.lock()
        settings = EffectSettings(layers: layers, palette: palette, mono: RGB(r: r, g: g, b: b),
                                  gain: Float(gain), brightness: brightness, speed: speed, layerLevels: layerLevels)
        settingsLock.unlock()
    }

    func connect(quiet: Bool = false) {
        switch kb.open() {
        case .ok(let l):
            connected = true
            link = l
            if l != .usb {
                // Separate detail setting per link: Bluetooth ~33 packets/s, 2.4 GHz dongle ~330 packets/s.
                wirelessPackets = UserDefaults.standard.object(forKey: "wirelessPackets.\(l.rawValue)") as? Double
                    ?? (l == .dongle ? 6 : 2)
            }
            if !quiet || onboardEffect == nil { refreshOnboard() }
            status = l == .usb
                ? "Connected over USB"
                : "Connected over \(l.rawValue). Wireless is slower than the cable, so the lights update a few times a second."
        case .notFound:
            connected = false; link = nil
            if !quiet { status = "Keyboard not found. Turn it on (USB cable, Bluetooth or 2.4 GHz) and make sure it isn't attached to a VM." }
        case .notPermitted:
            connected = false; link = nil
            status = "macOS blocked access to the keyboard. Allow F75 Music under System Settings → Privacy & Security → Input Monitoring, then reopen the app."
        }
    }

    /// Switch the keyboard's own effect. App lighting is stopped so the built-in effect is visible.
    func applyOnboard() {
        guard connected, !applyingOnboard else { return }
        let id = onboardChoice
        let name = onboardEffects.first { $0.id == id }?.name ?? "effect \(id)"
        if running { stop() }
        applyingOnboard = true
        status = "Setting built-in effect: \(name)…"
        DispatchQueue.global().async {
            usleep(150_000)   // let the stop/clear go out first
            let ok = self.kb.setOnboardEffect(UInt8(id))
            DispatchQueue.main.async {
                self.applyingOnboard = false
                if ok { self.onboardEffect = id }
                self.status = ok ? "Keyboard is now running its built-in “\(name)” effect. Start lighting again to switch back to the app's effects."
                                 : "Couldn't change the built-in effect (see ~/Library/Logs/F75Music.log)."
            }
        }
    }

    /// Read which built-in effect is set (cable/dongle only; Bluetooth replies are unreliable on macOS).
    private func refreshOnboard() {
        guard link == .usb || link == .dongle else { return }
        DispatchQueue.global().async {
            guard let p = self.kb.readLEDProfile(), p.count == 128 else { return }
            DispatchQueue.main.async { self.onboardEffect = Int(p[10]); self.onboardChoice = Int(p[10]) }
        }
    }

    func toggle() { running ? stop() : start() }

    func start() {
        if !connected { connect(); guard connected else { return } }
        running = true
        startTimer()   // keyboard effects run straight away, even before/without audio
        status = "Running (\(link?.rawValue ?? "")). Starting audio capture…"
        Task {
            do {
                try await tap.start()
                await MainActor.run {
                    self.listening = true
                    self.status = "Running (\(self.link?.rawValue ?? "")) · listening to system audio"
                }
            } catch {
                log("audio start failed: \(error)")
                await MainActor.run {
                    self.listening = false
                    self.status = "Running, but can't capture audio, so music effects stay quiet. Allow F75 Music under Privacy & Security → Screen & System Audio Recording, then quit and reopen. (\(error.localizedDescription))"
                }
            }
        }
    }

    func stop() {
        stopTimer()
        running = false
        listening = false
        keyColors = [RGB](repeating: .black, count: keys.count)
        status = connected ? "Stopped" : status
        sendQueue.async { self.kb.clear() }
        Task { await tap.stop() }
    }

    func runTest() {
        guard !running, !testing else { return }
        if !connected { connect(); guard connected else { return } }
        testing = true
        status = "Testing: red → green → blue"
        sendQueue.async {
            var ok = true
            for c in [(255, 0, 0), (0, 255, 0), (0, 0, 255)] as [(UInt8, UInt8, UInt8)] {
                let f = solidFrame(c.0, c.1, c.2)
                let end = Date().addingTimeInterval(1.2)
                while Date() < end && ok { ok = self.kb.send(f); usleep(20_000) }
            }
            self.kb.clear()
            DispatchQueue.main.async {
                self.testing = false
                if ok { self.status = "Test done" } else { self.connected = false; self.status = "Keyboard stopped responding" }
            }
        }
    }

    /// Called on quit: hand the lights back to the keyboard's own effect.
    func shutdown() {
        stopTimer()
        sendQueue.sync { kb.clear() }
    }

    private func startTimer() {
        stopTimer()
        // Keep macOS (App Nap / timer coalescing) from throttling us while the window is hidden.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical],
            reason: "Driving keyboard lighting")
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.frame() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    private var tickStat = 0, tickSince = Date(), pressStat = 0

    // runs on `queue` every 20 ms
    private func frame() {
        tickStat += 1
        if Date().timeIntervalSince(tickSince) >= 2 { tickStat = 0; pressStat = 0; tickSince = Date() }
        settingsLock.lock(); let s = settings; settingsLock.unlock()
        var f = extractor.update(db: analyzer.bands(Engine.bandCount), gain: s.gain)
        f.presses = keyWatcher.drain()
        pressStat += f.presses.count
        hue += 0.0015 * s.speed
        let ctx = LayerContext(palette: s.palette, mono: s.mono, speed: s.speed, hue: hue, wireless: kb.link == .bluetooth)
        let colors = mixer.render(f, layers: Array(s.layers), levels: s.layerLevels, context: ctx)
        let out = Mixer.frame(colors, brightness: s.brightness)
        if kb.link == .usb {
            noteResult(kb.send(out), limit: 25)
        } else {
            submitWireless(out)
        }
        tick += 1
        if tick % 2 == 0 {
            let b = s.brightness
            let preview = colors.map { $0 * b }
            DispatchQueue.main.async { self.keyColors = preview }
        }
    }

    /// Queue the newest frame; if the radio is still busy with the previous one, this replaces it.
    private func submitWireless(_ frame: [UInt8]) {
        pendingLock.lock()
        pending = frame
        let start = !sending
        if start { sending = true }
        pendingLock.unlock()
        guard start else { return }
        sendQueue.async { [weak self] in
            guard let self else { return }
            while true {
                self.pendingLock.lock()
                guard let f = self.pending, self.timer != nil else {
                    self.sending = false; self.pendingLock.unlock(); return
                }
                self.pending = nil
                self.pendingLock.unlock()
                let ok = self.kb.send(f)
                self.queue.async { self.noteResult(ok, limit: 5) }
            }
        }
    }

    // runs on `queue`
    private func noteResult(_ ok: Bool, limit: Int) {
        if ok { failures = 0; return }
        failures += 1
        if failures == limit {
            DispatchQueue.main.async {
                self.stop()
                self.connected = false
                self.link = nil
                self.status = "Keyboard stopped responding (turned off, out of range, or grabbed by a VM). It will reconnect automatically."
            }
        }
    }
}

// MARK: - Colour helpers

extension Color {
    init(hex: String) {
        let v = UInt32(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0x00ff00
        self.init(.sRGB, red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
    init(_ c: RGB) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b) }
    var rgb: (Double, Double, Double) {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .green
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
    var hex: String {
        let (r, g, b) = rgb
        return String(format: "%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

// MARK: - Views

/// Live preview drawn with the F75's real key layout.
struct KeyboardPreview: View {
    let colors: [RGB]

    var body: some View {
        Canvas { ctx, size in
            let sx = size.width / 610, rowH = size.height / 6
            for (i, k) in keys.enumerated() {
                let rect = CGRect(x: (k.x0 - 25) * sx + 1, y: CGFloat(k.row) * rowH + 1,
                                  width: (k.x1 - k.x0) * sx - 2 + (k.name == "Space" ? 0 : 6 * sx), height: rowH - 2)
                let path = Path(roundedRect: rect, cornerRadius: 3)
                ctx.fill(path, with: .color(.white.opacity(0.07)))
                let c = colors[i]
                let v = max(c.r, c.g, c.b)
                if v > 0.01 { ctx.fill(path, with: .color(Color(c).opacity(0.3 + 0.7 * v))) }
            }
        }
        .frame(height: 130)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85)))
    }
}

/// One effect: on/off plus its own brightness.
struct LayerRow: View {
    @ObservedObject var engine: Engine
    let kind: LayerKind
    var body: some View {
        let on = engine.layers.contains(kind)
        HStack(spacing: 8) {
            Toggle(kind.label, isOn: Binding(
                get: { on },
                set: { v in if v { engine.layers.insert(kind) } else { engine.layers.remove(kind) } }))
                .toggleStyle(.checkbox)
                .frame(width: 118, alignment: .leading)
                .help(kind.help)
            Slider(value: Binding(get: { engine.level(kind) }, set: { engine.layerLevels[kind] = $0 }), in: 0.05...1)
                .controlSize(.small)
                .disabled(!on)
                .help("Brightness of \(kind.label) in the mix")
            Text("\(Int(engine.level(kind) * 100))%")
                .font(.caption).monospacedDigit()
                .foregroundStyle(on ? .secondary : .tertiary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}

struct ContentView: View {
    @ObservedObject var engine = Engine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "keyboard").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AULA F75").font(.headline)
                    HStack(spacing: 6) {
                        Circle().fill(engine.connected ? Color.green : Color.red).frame(width: 8, height: 8)
                        Text(engine.connected ? "Connected · \(engine.link?.rawValue ?? "")" : "Not connected")
                            .font(.caption).foregroundStyle(.secondary)
                        if engine.listening {
                            Image(systemName: "waveform").font(.caption).foregroundStyle(.green).help("Listening to system audio")
                        }
                    }
                }
                Spacer()
                Button("Reconnect") { engine.connect() }
                    .disabled(engine.running)
            }

            KeyboardPreview(colors: engine.keyColors)

            Button(action: engine.toggle) {
                Label(engine.running ? "Stop" : "Start lighting", systemImage: engine.running ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(engine.running ? .red : .accentColor)
            .disabled(engine.testing)

            Picker("Preset", selection: Binding(
                get: { engine.presetName },
                set: { name in if let p = presets.first(where: { $0.name == name }) { engine.apply(p) } })) {
                ForEach(presets) { Text($0.name).tag($0.name) }
                if engine.presetName == "Custom" { Divider(); Text("Custom").tag("Custom") }
            }

            GroupBox("Keyboard effects · brightness in the mix") {
                VStack(spacing: 4) {
                    ForEach(LayerKind.allCases.filter { !$0.musical }) { LayerRow(engine: engine, kind: $0) }
                }
                .padding(4)
            }
            GroupBox("Music effects") {
                VStack(spacing: 4) {
                    ForEach(LayerKind.allCases.filter(\.musical)) { LayerRow(engine: engine, kind: $0) }
                }
                .padding(4)
            }

            Form {
                Picker("Colours", selection: $engine.palette) {
                    ForEach(Palette.allCases) { Text($0.label).tag($0) }
                }
                if engine.palette == .mono {
                    ColorPicker("Colour", selection: $engine.color, supportsOpacity: false)
                }
                slider("Speed", value: $engine.speed, range: 0.25...3, text: String(format: "%.1f×", engine.speed))
                slider("Sensitivity", value: $engine.gain, range: 0.3...3, text: String(format: "%.1f×", engine.gain))
                slider("Master", value: $engine.brightness, range: 0.1...1, text: "\(Int(engine.brightness * 100))%")
                if engine.link != nil && engine.link != .usb {
                    LabeledContent("Wireless") {
                        HStack {
                            Text("Smooth").font(.caption).foregroundStyle(.secondary)
                            Slider(value: $engine.wirelessPackets, in: 1...(engine.link == .dongle ? 14 : 8), step: 1)
                            Text("Detailed").font(.caption).foregroundStyle(.secondary)
                            Text("~\(min(50, Int((engine.link == .dongle ? 333 : 33) / engine.wirelessPackets))) fps").monospacedDigit().frame(width: 52, alignment: .trailing)
                        }
                    }
                    .help("Bluetooth carries one small packet every ~30 ms. Fewer packets per frame = smoother animation but fewer lit keys and colours. Use the USB cable for full 50 fps.")
                }
            }
            .formStyle(.columns)

            GroupBox("Built-in effect · drawn by the keyboard itself") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("", selection: $engine.onboardChoice) {
                            ForEach(onboardEffects) { e in
                                Text(e.name + (e.reactive ? "  ⌨︎" : "") + (engine.onboardEffect == e.id ? "  ✓" : "")).tag(e.id)
                            }
                        }
                        .labelsHidden()
                        Button(engine.applyingOnboard ? "Applying…" : "Apply", action: engine.applyOnboard)
                            .disabled(!engine.connected || engine.applyingOnboard)
                    }
                    Text("Smooth on any connection and needs no app, but can't be mixed with the effects above: the keyboard shows it whenever app lighting is stopped. ⌨︎ = reacts to typing.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            }

            HStack {
                Button("Test LEDs", action: engine.runTest)
                    .disabled(engine.running || engine.testing)
                Spacer()
                Text("Effects mix: tick any combination")
                    .font(.caption).foregroundStyle(.tertiary)
            }

            Text(engine.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 440)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(text).monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Closing the window keeps the app (and the lighting) running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { Engine.shared.shutdown() }
}

struct MenuBarMenu: View {
    @ObservedObject var engine = Engine.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(engine.connected ? "AULA F75 · \(engine.link?.rawValue ?? "")" : "AULA F75 · not connected")
        Divider()
        Button(engine.running ? "Stop lighting" : "Start lighting") { engine.toggle() }
            .disabled(!engine.connected && !engine.running)
        Menu("Preset") {
            ForEach(presets) { p in
                Button((engine.presetName == p.name ? "✓ " : "") + p.name) { engine.apply(p) }
            }
        }
        Button("Show window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit F75 Music") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@main
struct F75MusicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var engine = Engine.shared

    var body: some Scene {
        Window("F75 Music", id: "main") {
            ContentView()
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarMenu()
        } label: {
            Image(systemName: engine.running ? "waveform" : "keyboard")
        }
    }
}
