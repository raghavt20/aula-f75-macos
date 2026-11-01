// Effects for F75 Music: audio features, palettes, mixable layers and presets.

import Foundation

// MARK: - Colour

struct RGB {
    var r: Double, g: Double, b: Double
    static let black = RGB(r: 0, g: 0, b: 0)
    static func + (a: RGB, b: RGB) -> RGB { RGB(r: a.r + b.r, g: a.g + b.g, b: a.b + b.b) }
    static func * (a: RGB, k: Double) -> RGB { RGB(r: a.r * k, g: a.g * k, b: a.b * k) }
    var clamped: RGB { RGB(r: min(1, max(0, r)), g: min(1, max(0, g)), b: min(1, max(0, b))) }
}

func hsv(_ h: Double, _ s: Double, _ v: Double) -> RGB {
    let hh = (h.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
    let i = Int(hh * 6) % 6, f = hh * 6 - floor(hh * 6)
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    let c = [(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)][i]
    return RGB(r: c.0, g: c.1, b: c.2)
}

// MARK: - Palettes

enum Palette: String, CaseIterable, Identifiable {
    case rainbow, heat, ocean, sunset, neon, mono
    var id: Self { self }
    var label: String {
        ["rainbow": "Rainbow", "heat": "Heat", "ocean": "Ocean", "sunset": "Sunset", "neon": "Neon", "mono": "Single colour"][rawValue]!
    }

    /// Colour at position t (0…1, wraps), full brightness.
    func color(_ t: Double, mono: RGB) -> RGB {
        let x = (t.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
        switch self {
        case .rainbow: return hsv(x, 1, 1)
        case .heat:    return gradient(x, [RGB(r: 0, g: 1, b: 0), RGB(r: 1, g: 1, b: 0), RGB(r: 1, g: 0.3, b: 0), RGB(r: 1, g: 0, b: 0)])
        case .ocean:   return gradient(x, [RGB(r: 0, g: 0.2, b: 1), RGB(r: 0, g: 0.8, b: 1), RGB(r: 0, g: 1, b: 0.6), RGB(r: 0.3, g: 0.3, b: 1)])
        case .sunset:  return gradient(x, [RGB(r: 1, g: 0.1, b: 0.3), RGB(r: 1, g: 0.5, b: 0), RGB(r: 1, g: 0.85, b: 0.2), RGB(r: 0.6, g: 0, b: 1)])
        case .neon:    return gradient(x, [RGB(r: 1, g: 0, b: 1), RGB(r: 0, g: 1, b: 1), RGB(r: 0.5, g: 1, b: 0), RGB(r: 1, g: 0, b: 0.5)])
        case .mono:    return mono
        }
    }

    private func gradient(_ x: Double, _ stops: [RGB]) -> RGB {
        // cyclic gradient so palettes can scroll seamlessly
        let n = Double(stops.count)
        let p = x * n, i = Int(p) % stops.count, f = p - floor(p)
        let a = stops[i], b = stops[(i + 1) % stops.count]
        return a * (1 - f) + b * f
    }
}

// MARK: - Audio features

struct Features {
    var bands: [Float]       // 0…1 per band, smoothed
    var bass: Double = 0     // 0…1
    var mid: Double = 0
    var treble: Double = 0
    var level: Double = 0    // overall loudness 0…1
    var beat = false         // bass onset this frame
    var t: Double = 0        // seconds since start
    var dt: Double = 0.02
    var presses: [Int] = []  // indices into `keys` pressed since the last frame
}

/// Turns raw dB bands into normalised levels + beat detection.
final class FeatureExtractor {
    private var smooth: [Float]
    private var ceilDb: Float = 20
    private var bassAvg: Double = 0
    private var lastBeat: Double = -1
    private var prevBass: Double = 0
    private let start = Date()

    init(bands: Int) { smooth = [Float](repeating: 0, count: bands) }

    func update(db: [Float], gain: Float) -> Features {
        let n = db.count
        ceilDb = max(db.max() ?? 0, ceilDb - 0.15)   // adaptive range: quiet and loud music both fill the board
        let floorDb = ceilDb - 45
        var raw = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var v = (db[i] - floorDb) / (ceilDb - floorDb)
            v = max(0, min(1, v * gain))
            v = v * v
            raw[i] = v
            smooth[i] = v > smooth[i] ? v : smooth[i] * 0.85 + v * 0.15
        }
        func avg(_ r: Range<Int>, _ a: [Float]) -> Double {
            let s = r.clamped(to: 0..<n); return s.isEmpty ? 0 : Double(s.map { a[$0] }.reduce(0, +)) / Double(s.count)
        }
        var f = Features(bands: smooth)
        f.t = Date().timeIntervalSince(start)
        let bassNow = avg(0..<max(1, n / 6), raw)
        f.bass = avg(0..<max(1, n / 6), smooth)
        f.mid = avg(n / 6..<n * 2 / 3, smooth)
        f.treble = avg(n * 2 / 3..<n, smooth)
        f.level = avg(0..<n, smooth)
        // Beat: bass jumps clearly above its running average, at most ~6 per second.
        bassAvg = bassAvg * 0.95 + bassNow * 0.05
        if bassNow > max(0.12, bassAvg * 1.35), bassNow > prevBass, f.t - lastBeat > 0.16 {
            f.beat = true
            lastBeat = f.t
        }
        prevBass = bassNow
        return f
    }
}

// MARK: - Layers

enum LayerKind: String, CaseIterable, Identifiable {
    // keyboard-style effects (work without music)
    case solid, breathing, wave, starry, typing
    // music-reactive effects
    case spectrum, ripple, pulse, rain
    var id: Self { self }
    var label: String {
        switch self {
        case .solid: return "Static"
        case .breathing: return "Breathing"
        case .wave: return "Wave"
        case .starry: return "Starry"
        case .typing: return "Typing Ripple"
        case .spectrum: return "Spectrum"
        case .ripple: return "Beat Ripple"
        case .pulse: return "Pulse"
        case .rain: return "Rain"
        }
    }
    var musical: Bool { [.spectrum, .ripple, .pulse, .rain].contains(self) }
    /// Starting brightness: background effects dimmer so ripples stand out on top.
    var defaultLevel: Double {
        switch self {
        case .solid: return 0.35
        case .breathing, .wave: return 0.45
        case .starry: return 0.6
        default: return 1
        }
    }
    var help: String {
        switch self {
        case .solid:     return "Whole board in the palette colours"
        case .breathing: return "Slowly fades in and out"
        case .wave:      return "Colours flow across the board (faster when music is loud)"
        case .starry:    return "Keys twinkle like stars (more with treble)"
        case .typing:    return "A ring spreads from every key you press"
        case .spectrum:  return "Bars rise with each frequency band, bass on the left"
        case .ripple:    return "A ring spreads from a random key on every beat"
        case .pulse:     return "The whole board flashes with the bass"
        case .rain:      return "Drops fall down the columns on beats and hi-hats"
        }
    }
    func make() -> Layer {
        switch self {
        case .solid:     return SolidLayer()
        case .breathing: return BreathingLayer()
        case .wave:      return WaveLayer()
        case .starry:    return StarryLayer()
        case .typing:    return RippleLayer(trigger: .keys)
        case .spectrum:  return SpectrumLayer()
        case .ripple:    return RippleLayer(trigger: .beat)
        case .pulse:     return PulseLayer()
        case .rain:      return RainLayer()
        }
    }
}

struct LayerContext {
    var palette: Palette
    var mono: RGB
    var speed: Double     // 0.25…3
    var hue: Double       // slowly drifting palette offset
    var wireless = false  // low frame rate + small frames: keep effects compact
}

protocol Layer: AnyObject {
    /// Add this layer's colour for every key into `out` (indexed like `keys`).
    func render(_ f: Features, _ c: LayerContext, into out: inout [RGB])
}

final class SpectrumLayer: Layer {
    func render(_ f: Features, _ c: LayerContext, into out: inout [RGB]) {
        let n = f.bands.count
        for (i, k) in keys.enumerated() {
            let band = min(n - 1, max(0, Int(k.u * Double(n))))
            let height = 5 - k.row
            let fill = max(0, min(1, Double(f.bands[band]) * 6 - Double(height)))
            guard fill > 0 else { continue }
            let col = c.palette == .heat ? c.palette.color(Double(height) / 6, mono: c.mono)
                                         : c.palette.color(Double(band) / Double(n) + c.hue, mono: c.mono)
            out[i] = out[i] + col * fill
        }
    }
}

final class SolidLayer: Layer {
    func render(_ f: Features, _ c: LayerContext, into out: inout [RGB]) {
        for (i, k) in keys.enumerated() {
            out[i] = out[i] + c.palette.color(k.u * 0.35 + c.hue, mono: c.mono) * 0.55
        }
    }
}

final class BreathingLayer: Layer {
    func render(_ f: Features, _ c: LayerContext, into out: inout [RGB]) {
        let v = 0.5 - 0.5 * cos(f.t * c.speed * .pi * 2 / 4)   // 4 s cycle at speed 1
        let col = c.palette.color(f.t * c.speed / 24 + c.hue, mono: c.mono)
        for i in keys.indices { out[i] = out[i] + col * (v * 0.8) }
    }
}

final class RippleLayer: Layer {
    enum Trigger { case beat, keys }
    private struct Ring { var x, y, born: Double; var color: RGB }
    private var rings: [Ring] = []
    private let trigger: Trigger
    init(trigger: Trigger) { self.trigger = trigger }

    func render(_ f: Features, _ c: LayerContext, into out: inout [RGB]) {
        var origins: [Key] = []
        switch trigger {
        case .beat: if f.beat { origins.append(keys.randomElement()!) }
        case .keys: origins = f.presses.map { keys[$0] }
        }
        for k in origins {
            // Typing ripples share the current palette colour (overlaps blend cleanly and, on wireless,
            // cost no extra colour groups); beat ripples get a random palette colour.
            let shade = trigger == .keys ? c.hue : Double.random(in: 0..<1) + c.hue
            rings.append(Ring(x: k.x, y: k.y, born: f.t, color: c.palette.color(shade, mono: c.mono)))
            if rings.count > 12 { rings.removeFirst() }
        }
        // Wireless: shorter reach and a thicker band, so a ring is ~20 keys and moves ~1 key per frame.
        let v = (c.wireless ? 300 : 380) * c.speed            // px per second (a key is ~38 px)
        let reach = c.wireless ? 170.0 : 520.0                 // px
        let width = c.wireless ? 46.0 : 52.0                   // half-width of the soft band
        let life = reach / v
        rings.removeAll { f.t - $0.born > life }
        for r in rings {
            let age = f.t - r.born
            let radius = age * v
            let p = age / life
            let fade = (1 - p) * (1 - p)                      // ease out
            for (i, k) in keys.enumerated() {
                let dist = hypot(k.x - r.x, k.y - r.y)
                let d = abs(dist - radius)
                var a = 0.0
                if d < width { a = 0.5 + 0.5 * cos(d / width * .pi) }   // smooth band, no popping
                if dist < 1, age < 0.15 { a = max(a, 1) }               // flash the pressed key
                if a > 0 { out[i] = out[i] + r.color * (a * fade) }
            }
        }
    }
}

final class StarryLayer: Layer {
    private var stars = [Double](repeating: 0, count: keys.count)
    private var colors = [RGB](repeating: .black, count: keys.count)
    func render(_ f: Features, _ c: LayerContext, into out: inout [RGB]) {
        // A few stars always twinkle; treble and beats add more.
        let rate = (0.6 + f.treble * 25 + (f.beat ? 6 : 0)) * c.speed * f.dt
        var spawn = rate
        while spawn > 0 {
            if Double.random(in: 0..<1) < spawn {
                let i = Int.random(in: 0..<keys.count)
                stars[i] = 1
                colors[i] = Double.random(in: 0..<1) < 0.35 ? RGB(r: 1, g: 1, b: 1)
                                                           : c.palette.color(Double.random(in: 0..<1) + c.hue, mono: c.mono)
            }
            spawn -= 1
        }
        let decay = pow(0.12, f.dt * c.speed)   // ~1 s fade at speed 1
        for i in 0..<keys.count where stars[i] > 0.01 {
            out[i] = out[i] + colors[i] * stars[i]
            stars[i] *= decay
        }
    }
}

final class PulseLayer: Layer {
    private var env = 0.0
    func render(_ f: Features, _ c: LayerContext, into out: inout [RGB]) {
        let target = pow(f.bass, 1.3)
        env = target > env ? target : env * pow(0.05, f.dt * c.speed) + target * 0.02
        guard env > 0.02 else { return }
        for (i, k) in keys.enumerated() {
            out[i] = out[i] + c.palette.color(k.u * 0.3 + c.hue, mono: c.mono) * (env * 0.9)
        }
    }
}

final class WaveLayer: Layer {
    private var phase = 0.0
    func render(_ f: Features, _ c: LayerContext, into out: inout [RGB]) {
        phase += f.dt * c.speed * (0.15 + f.level * 1.2)
        let bright = 0.25 + 0.75 * min(1, f.level * 1.6)
        for (i, k) in keys.enumerated() {
            let v = 0.5 + 0.5 * sin((k.u * 2 - phase) * .pi * 2)
            out[i] = out[i] + c.palette.color(k.u - phase * 0.5, mono: c.mono) * (bright * (0.35 + 0.65 * v))
        }
    }
}

final class RainLayer: Layer {
    private struct Drop { var col: Double; var y: Double; var color: RGB }
    private var drops: [Drop] = []
    private var trebleAvg = 0.0
    func render(_ f: Features, _ c: LayerContext, into out: inout [RGB]) {
        trebleAvg = trebleAvg * 0.9 + f.treble * 0.1
        var n = f.beat ? 3 : 0
        if f.treble > trebleAvg * 1.25 && f.treble > 0.08 { n += 1 }
        if Double.random(in: 0..<1) < 0.4 * f.dt * c.speed { n += 1 }   // light drizzle in silence
        for _ in 0..<n {
            drops.append(Drop(col: Double.random(in: 0..<1), y: -0.5,
                              color: c.palette.color(Double.random(in: 0..<1) + c.hue, mono: c.mono)))
        }
        if drops.count > 24 { drops.removeFirst(drops.count - 24) }
        for j in drops.indices { drops[j].y += f.dt * 9 * c.speed }
        drops.removeAll { $0.y > 8 }
        for d in drops {
            for (i, k) in keys.enumerated() {
                guard abs(k.u - d.col) < 0.045 else { continue }
                let dy = d.y - Double(k.row)       // head at d.y, trail above it
                if dy >= -0.5 && dy < 2.5 { out[i] = out[i] + d.color * (dy < 0.5 ? 1 : max(0, 1 - (dy - 0.5) / 2)) }
            }
        }
    }
}

// MARK: - Presets

struct Preset: Identifiable, Hashable {
    let name: String
    let layers: [LayerKind]
    let palette: Palette
    var id: String { name }
}

let presets: [Preset] = [
    Preset(name: "Typing Ripple + Stars", layers: [.typing, .starry], palette: .neon),
    Preset(name: "Static + Typing Ripple", layers: [.solid, .typing], palette: .ocean),
    Preset(name: "Breathing + Ripples", layers: [.breathing, .typing, .ripple], palette: .sunset),
    Preset(name: "Rainbow Wave + Ripples", layers: [.wave, .typing, .ripple], palette: .rainbow),
    Preset(name: "Spectrum", layers: [.spectrum], palette: .rainbow),
    Preset(name: "Ripple + Stars", layers: [.ripple, .starry], palette: .neon),
    Preset(name: "Starry Night", layers: [.starry, .wave], palette: .ocean),
    Preset(name: "Spectrum + Stars", layers: [.spectrum, .starry], palette: .rainbow),
    Preset(name: "Pulse + Ripple", layers: [.pulse, .ripple], palette: .sunset),
    Preset(name: "Rainstorm", layers: [.rain, .ripple], palette: .ocean),
    Preset(name: "Party", layers: [.ripple, .rain, .starry, .pulse], palette: .rainbow),
    Preset(name: "Lava", layers: [.wave, .pulse], palette: .heat),
    Preset(name: "Equaliser Fire", layers: [.spectrum, .ripple], palette: .heat),
]

// MARK: - Mixer

final class Mixer {
    private var instances: [LayerKind: Layer] = [:]

    /// Returns per-key colours (indexed like `keys`), additive blend of all enabled layers.
    /// `levels`: per-layer brightness 0…1 (missing = the layer's default).
    func render(_ f: Features, layers: [LayerKind], levels: [LayerKind: Double], context: LayerContext) -> [RGB] {
        var out = [RGB](repeating: .black, count: keys.count)
        for kind in LayerKind.allCases where layers.contains(kind) {
            if instances[kind] == nil { instances[kind] = kind.make() }
            var layer = [RGB](repeating: .black, count: keys.count)
            instances[kind]!.render(f, context, into: &layer)
            let k = levels[kind] ?? kind.defaultLevel
            for i in out.indices { out[i] = out[i] + layer[i].clamped * k }
        }
        return out.map { $0.clamped }
    }

    /// Per-key colours -> 378-byte LED frame.
    static func frame(_ colors: [RGB], brightness: Double) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: kLedCount * 3)
        for (i, k) in keys.enumerated() {
            let c = colors[i]
            f[k.led * 3] = UInt8(c.r * brightness * 255)
            f[k.led * 3 + 1] = UInt8(c.g * brightness * 255)
            f[k.led * 3 + 2] = UInt8(c.b * brightness * 255)
        }
        return f
    }
}

// MARK: - Built-in (onboard) effects
// Names from the vendor app (Text/en/text.xml), firmware ids from Dev/kb/1/KB.ini (LedOptN = ui, hw, …).

struct OnboardEffect: Identifiable, Hashable {
    let name: String
    let id: Int
    let reactive: Bool   // reacts to typing
}

let onboardEffects: [OnboardEffect] = [
    OnboardEffect(name: "Fixed on", id: 1, reactive: false),
    OnboardEffect(name: "Respire", id: 3, reactive: false),
    OnboardEffect(name: "Rainbow", id: 2, reactive: false),
    OnboardEffect(name: "Flash away", id: 19, reactive: true),
    OnboardEffect(name: "Raindrops", id: 15, reactive: false),
    OnboardEffect(name: "Rainbow wheel", id: 13, reactive: false),
    OnboardEffect(name: "Ripples shining", id: 20, reactive: true),
    OnboardEffect(name: "Stars twinkle", id: 16, reactive: false),
    OnboardEffect(name: "Shadow disappear", id: 18, reactive: true),
    OnboardEffect(name: "Retro snake", id: 5, reactive: false),
    OnboardEffect(name: "Neon stream", id: 7, reactive: false),
    OnboardEffect(name: "Reaction", id: 17, reactive: true),
    OnboardEffect(name: "Sine wave", id: 12, reactive: false),
    OnboardEffect(name: "Retinue scanning", id: 8, reactive: false),
    OnboardEffect(name: "Rotating windmill", id: 28, reactive: false),
    OnboardEffect(name: "Colorful waterfall", id: 30, reactive: false),
    OnboardEffect(name: "Blossoming", id: 14, reactive: false),
    OnboardEffect(name: "Rotating storm", id: 29, reactive: false),
]
