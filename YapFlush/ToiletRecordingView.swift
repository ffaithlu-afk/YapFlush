import ImageIO
import SwiftUI

// MARK: - Voice-Reactive Motion Simulation

struct RecordingWavefield {
    struct LaunchSpark: Sendable {
        let angle: Double
        let distance: Double
        let size: Double
        let paletteIndex: Int
    }

    struct FlyingSymbol: Sendable {
        let id: Int
        let spriteIndex: Int
        let spawnAt: Date
        let travelTime: TimeInterval
        let origin: CGPoint
        let control: CGPoint
        let size: Double
        let baseTilt: Double
        let spinSpeed: Double
        let accentStrength: Double
        let launchSparks: [LaunchSpark]

        func landing(releasedAt release: Date?) -> Date {
            let natural = spawnAt.addingTimeInterval(travelTime)
            guard let release else { return natural }
            if natural <= release { return natural }
            // Quickly vacuum airborne symbols into the bowl as soon as the key is released.
            let vacuumEnd = release.addingTimeInterval(0.115)
            return min(natural, max(spawnAt.addingTimeInterval(0.05), vacuumEnd))
        }

        func progress(at time: Date, releasedAt release: Date?) -> Double {
            guard time >= spawnAt else { return -1 }
            let natural = spawnAt.addingTimeInterval(travelTime)
            if let release, time >= release, release < natural {
                let target = landing(releasedAt: release)
                let startProgress = max(0, min(1, release.timeIntervalSince(spawnAt) / travelTime))
                let remDuration = max(0.025, target.timeIntervalSince(release))
                let accel = min(1, max(0, time.timeIntervalSince(release) / remDuration))
                return startProgress + (1 - startProgress) * (accel * accel * (3 - 2 * accel))
            }
            return time.timeIntervalSince(spawnAt) / travelTime
        }

        func position(at easedT: Double, target: CGPoint) -> CGPoint {
            let inv = 1 - easedT
            let x = inv * inv * origin.x + 2 * inv * easedT * control.x + easedT * easedT * target.x
            let y = inv * inv * origin.y + 2 * inv * easedT * control.y + easedT * easedT * target.y
            return CGPoint(x: x, y: y)
        }

        func velocity(at easedT: Double, target: CGPoint) -> CGVector {
            let dx = 2 * (1 - easedT) * (control.x - origin.x) + 2 * easedT * (target.x - control.x)
            let dy = 2 * (1 - easedT) * (control.y - origin.y) + 2 * easedT * (target.y - control.y)
            return CGVector(dx: dx, dy: dy)
        }
    }

    struct DropletSeed: Sendable {
        let vx: Double
        let vy: Double
        let offsetX: Double
        let size: Double
        let lifetime: TimeInterval
        let colorKind: Int // 0 = cyan water, 1 = cream foam, 2 = orange accent spark
    }

    struct SplashEvent: Sendable {
        let landingAt: Date
        let strength: Double
        let droplets: [DropletSeed]
    }

    private(set) var symbols: [FlyingSymbol] = []
    private(set) var liveLevel: Double = 0
    private(set) var liveBars: [Double] = [0.12, 0.14, 0.16, 0.14, 0.12]
    private(set) var lastSampleAt: Date?
    private(set) var lastVoiceAt: Date?

    private var voicedDuration: TimeInterval = 0
    private var baseline: Double = 0
    private var sequence: Int = 0
    private var lastSpawnAt: Date?
    private var lastSector: Int = -1
    private var shuffleBag: [Int] = []
    private var lastSpriteIndex: Int = -1

    mutating func receive(_ waveform: RecordingWaveform, now: Date = .now) {
        symbols.removeAll { now.timeIntervalSince($0.spawnAt) > 1.45 }
        let dt = lastSampleAt.map { min(0.09, max(0.008, now.timeIntervalSince($0))) } ?? 0.035
        lastSampleAt = now

        // Fast attack / smooth release envelope so the toilet and equalizer react instantaneously.
        let level = min(1, max(0, waveform.level))
        let attack = 1 - exp(-dt / 0.042)
        let release = 1 - exp(-dt / 0.155)
        liveLevel += (level - liveLevel) * (level > liveLevel ? attack : release)

        updateLiveBars(from: waveform, dt: dt)

        let rise = level - baseline
        baseline += rise * (1 - exp(-dt / 0.16))

        guard level >= 0.105 else { return }

        let phraseStart = lastVoiceAt.map { now.timeIntervalSince($0) >= 0.19 } ?? true
        lastVoiceAt = now
        voicedDuration += dt

        let buildup = min(1, voicedDuration / 3.8)
        let sinceLast = lastSpawnAt.map { now.timeIntervalSince($0) } ?? .infinity
        let strongAccent = rise >= 0.11 || (level >= 0.68 && rise >= 0.06)
        let baseCadence = 0.34 - 0.11 * buildup - 0.05 * level
        let activeCount = symbols.filter { $0.landing(releasedAt: nil) > now }.count

        guard activeCount < 5,
              phraseStart || sinceLast >= baseCadence || (strongAccent && sinceLast >= 0.18) else {
            return
        }

        lastSpawnAt = now
        let burstCount: Int
        if activeCount <= 2 && (level >= 0.76 || (strongAccent && voicedDuration >= 1.5)) {
            burstCount = 2
        } else {
            burstCount = 1
        }

        let spriteCount = max(1, SymbolSpriteSheet.sprites.count)
        for indexInBurst in 0..<burstCount {
            let delay = Double(indexInBurst) * 0.095
            let spawnAt = now.addingTimeInterval(delay)
            let spriteIndex = nextSpriteIndex(count: spriteCount)
            let sector = pickSector(preferOpposite: indexInBurst > 0)
            let (origin, control) = makeTrajectory(for: sector, energy: level)
            let travel = max(0.36, 0.48 - 0.09 * level + Double.random(in: -0.02...0.03))
            let size = (25.0 + 9.0 * level) * (1.0 - Double(indexInBurst) * 0.10)
            let tiltSign = origin.x < PixelStage.bowl.x ? 1.0 : -1.0
            let sparks = (0..<3).map { idx in
                LaunchSpark(
                    angle: Double(idx) * (2 * .pi / 3) + Double.random(in: -0.35...0.35),
                    distance: Double.random(in: 10...16),
                    size: Double.random(in: 2.2...3.2),
                    paletteIndex: idx % 3
                )
            }

            let symbol = FlyingSymbol(
                id: sequence,
                spriteIndex: spriteIndex,
                spawnAt: spawnAt,
                travelTime: travel,
                origin: origin,
                control: control,
                size: size,
                baseTilt: tiltSign * Double.random(in: 0.10...0.22),
                spinSpeed: tiltSign * Double.random(in: 0.24...0.46),
                accentStrength: min(1, max(0.24, level + (strongAccent ? 0.18 : 0))),
                launchSparks: sparks
            )
            sequence += 1
            symbols.append(symbol)
        }
    }

    func decayedLevel(at time: Date) -> Double {
        guard let lastSampleAt else { return 0 }
        let stale = max(0, time.timeIntervalSince(lastSampleAt))
        return liveLevel * exp(-stale / 0.18)
    }

    func decayedBars(at time: Date) -> [Double] {
        let decay: Double
        if let lastSampleAt {
            decay = exp(-max(0, time.timeIntervalSince(lastSampleAt)) / 0.16)
        } else {
            decay = 0
        }
        let idlePhase = time.timeIntervalSinceReferenceDate
        return liveBars.enumerated().map { idx, bar in
            let idle = 0.12 + 0.05 * sin(idlePhase * 3.4 + Double(idx) * 0.9)
            return max(idle, min(1, bar * decay))
        }
    }

    func splashEvents(releasedAt release: Date?) -> [SplashEvent] {
        // Debounce closely clustered arrivals into one clean splash so droplets never form clutter.
        let ordered = symbols
            .map { (id: $0.id, landing: $0.landing(releasedAt: release), strength: $0.accentStrength) }
            .sorted { $0.landing < $1.landing }

        var events: [SplashEvent] = []
        for item in ordered {
            if let last = events.last, item.landing.timeIntervalSince(last.landingAt) < 0.12 {
                if item.strength > last.strength {
                    events[events.count - 1] = SplashEvent(
                        landingAt: last.landingAt,
                        strength: item.strength,
                        droplets: Self.droplets(for: item.id, strength: item.strength)
                    )
                }
            } else {
                events.append(SplashEvent(
                    landingAt: item.landing,
                    strength: item.strength,
                    droplets: Self.droplets(for: item.id, strength: item.strength)
                ))
            }
        }
        return events
    }

    func waterFrame(at time: Date, releasedAt release: Date?) -> Int {
        let landed = symbols
            .map { (landing: $0.landing(releasedAt: release), strength: $0.accentStrength) }
            .filter { $0.landing <= time }
            .max(by: { $0.landing < $1.landing })

        if let landed {
            let age = time.timeIntervalSince(landed.landing)
            let frames: [Int]
            let stepTime: TimeInterval
            switch landed.strength {
            case 0.72...:
                frames = [8, 9, 10, 11, 12, 13, 14]
                stepTime = 0.048
            case 0.44...:
                frames = [6, 7, 8, 12, 14]
                stepTime = 0.050
            default:
                frames = [5, 6, 14]
                stepTime = 0.054
            }
            let step = Int(age / stepTime)
            if frames.indices.contains(step) { return frames[step] }
        }

        // Immediate micro-ripple response when voice starts before the first symbol lands.
        let level = decayedLevel(at: time)
        if level >= 0.24 {
            let pulse = Int(time.timeIntervalSinceReferenceDate * 9.0) % 3
            return pulse == 0 ? 5 : 4
        }
        return 4
    }

    func squashImpulse(at time: Date, releasedAt release: Date?) -> (sx: Double, sy: Double, dy: Double, tilt: Double) {
        var impactX = 0.0
        var impactY = 0.0
        var impactDy = 0.0
        var impactTilt = 0.0

        for symbol in symbols {
            let landing = symbol.landing(releasedAt: release)
            let age = time.timeIntervalSince(landing)
            guard age >= 0, age < 0.34 else { continue }
            // Damped harmonic bounce: compresses wide & short on hit, then pops slightly tall!
            let amp = (0.045 + 0.065 * symbol.accentStrength) * exp(-12.5 * age)
            let wave = sin(age * 33.0)
            impactX += amp * wave
            impactY -= amp * 0.92 * wave
            impactDy += (1.2 + 2.4 * symbol.accentStrength) * exp(-14.0 * age) * max(0, sin(age * 28.0))
            let dir = symbol.origin.x < PixelStage.bowl.x ? 1.0 : -1.0
            impactTilt += dir * (0.9 + 1.4 * symbol.accentStrength) * exp(-13.0 * age) * wave
        }

        return (
            sx: min(0.14, max(-0.10, impactX)),
            sy: min(0.12, max(-0.13, impactY)),
            dy: min(4.0, impactDy),
            tilt: min(3.2, max(-3.2, impactTilt))
        )
    }

    private mutating func updateLiveBars(from waveform: RecordingWaveform, dt: TimeInterval) {
        let samples = waveform.samples
        let barCount = liveBars.count
        let smooth = 1 - exp(-dt / 0.048)
        let weights: [Double] = [0.78, 1.02, 1.18, 1.02, 0.78]
        // Boost mid/loud speech contrast so the 5-bar pixel meter dances vividly!
        let liftedLevel = pow(min(1, max(0, waveform.level)), 0.78)

        for idx in 0..<barCount {
            let bandEnergy: Double
            if samples.count >= barCount {
                let start = idx * samples.count / barCount
                let end = max(start + 1, (idx + 1) * samples.count / barCount)
                var peak = 0.0
                for s in start..<end { peak = max(peak, abs(samples[s])) }
                bandEnergy = min(1, (0.48 * liftedLevel + 0.68 * min(1, peak) * liftedLevel) * weights[idx])
            } else {
                bandEnergy = min(1, liftedLevel * weights[idx])
            }
            let target = max(0.08, bandEnergy)
            liveBars[idx] += (target - liveBars[idx]) * smooth
        }
    }

    private mutating func nextSpriteIndex(count: Int) -> Int {
        if shuffleBag.isEmpty {
            shuffleBag = Array(0..<count).shuffled()
            if shuffleBag.last == lastSpriteIndex && shuffleBag.count > 1 {
                shuffleBag.swapAt(0, shuffleBag.count - 1)
            }
        }
        let picked = shuffleBag.removeLast()
        lastSpriteIndex = picked
        return picked
    }

    private mutating func pickSector(preferOpposite: Bool = false) -> Int {
        // 5 balanced upper-hemisphere sectors (left wing, upper-left, top, upper-right, right wing).
        // Never spawns from the bottom so icons never cross awkwardly over the toilet's face!
        let candidates: [Int]
        if preferOpposite && lastSector >= 0 {
            if lastSector <= 1 {
                candidates = [3, 4]
            } else if lastSector >= 3 {
                candidates = [0, 1]
            } else {
                candidates = [0, 4]
            }
        } else {
            candidates = (0..<5).filter { $0 != lastSector }
        }
        let chosen = candidates.randomElement() ?? 0
        lastSector = chosen
        return chosen
    }

    private func makeTrajectory(for sector: Int, energy: Double) -> (origin: CGPoint, control: CGPoint) {
        let bowl = PixelStage.bowl
        let origin: CGPoint
        let control: CGPoint
        let loft = 20.0 + 18.0 * energy

        switch sector {
        case 0: // Left wing
            origin = CGPoint(x: CGFloat.random(in: 22...64), y: CGFloat.random(in: 42...102))
            control = CGPoint(x: (origin.x + bowl.x) * 0.48 - 12, y: min(origin.y, bowl.y) - CGFloat(loft + 22))
        case 1: // Upper-left arc
            origin = CGPoint(x: CGFloat.random(in: 38...112), y: CGFloat.random(in: 18...44))
            control = CGPoint(x: origin.x + (bowl.x - origin.x) * 0.64, y: max(8, origin.y - CGFloat(loft * 0.65)))
        case 2: // High overhead sweeping arc
            let side: CGFloat = Bool.random() ? -1 : 1
            origin = CGPoint(x: bowl.x + side * CGFloat.random(in: 24...68), y: CGFloat.random(in: 14...28))
            control = CGPoint(x: bowl.x + side * CGFloat.random(in: 36...58), y: origin.y + 14)
        case 3: // Upper-right arc
            origin = CGPoint(x: CGFloat.random(in: 232...306), y: CGFloat.random(in: 18...44))
            control = CGPoint(x: origin.x + (bowl.x - origin.x) * 0.64, y: max(8, origin.y - CGFloat(loft * 0.65)))
        default: // Right wing
            origin = CGPoint(x: CGFloat.random(in: 280...322), y: CGFloat.random(in: 42...102))
            control = CGPoint(x: (origin.x + bowl.x) * 0.48 + 12, y: min(origin.y, bowl.y) - CGFloat(loft + 22))
        }
        return (origin, control)
    }

    private static func droplets(for seed: Int, strength: Double) -> [DropletSeed] {
        // Deterministic hash so droplets are stable across 60fps frames without extra allocation state.
        func rand(_ salt: Int) -> Double {
            var x = UInt64(bitPattern: Int64(seed &* 73_856_093 ^ salt &* 19_349_663))
            x ^= x >> 33
            x &*= 0xff51afd7ed558ccd
            x ^= x >> 33
            x &*= 0xc4ceb9fe1a85ec53
            x ^= x >> 33
            return Double(x & 0xFFFF) / 65535.0
        }

        // Crisp, clean 3–5 outward-fanning droplets that complement (never bury) the hand-drawn pixel splashes.
        let count = strength >= 0.72 ? 5 : (strength >= 0.44 ? 4 : 3)
        return (0..<count).map { idx in
            let side = idx.isMultiple(of: 2) ? -1.0 : 1.0
            let ring = Double(idx / 2 + 1)
            let dir = side * (0.58 + 0.34 * ring + (rand(idx * 7 + 1) - 0.5) * 0.22)
            let vx = dir * (66.0 + 58.0 * strength)
            let vy = -(92.0 + 78.0 * strength + rand(idx * 7 + 2) * 38.0)
            let offsetX = side * (16.0 + 6.0 * ring)
            let size = (2.6 + rand(idx * 7 + 3) * 1.5) * (0.90 + 0.20 * strength)
            let lifetime = 0.22 + rand(idx * 7 + 4) * 0.13
            let colorRoll = rand(idx * 7 + 5)
            let colorKind: Int
            if strength >= 0.68 && idx == 0 {
                colorKind = 2 // Single punchy warm-orange retro pixel spark on loud accent
            } else if colorRoll > 0.55 {
                colorKind = 1 // Cream foam droplet
            } else {
                colorKind = 0 // Aqua-cyan water droplet
            }
            return DropletSeed(vx: vx, vy: vy, offsetX: offsetX, size: size, lifetime: lifetime, colorKind: colorKind)
        }
    }
}

// MARK: - Pixel-Accurate De-Haloed Sprite Matting

private enum SpriteMatte {
    struct Output {
        let image: CGImage
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    static func extract(from crop: CGImage, removeEnclosedHoles: Bool, trim: Bool) -> Output? {
        let w = crop.width
        let h = crop.height
        let stride = w * 4
        let count = w * h
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        var px = [UInt8](repeating: 0, count: stride * h)
        let decoded = px.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(data: bytes.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: stride, space: space, bitmapInfo: format)
            else { return false }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard decoded else { return nil }

        // 1. Estimate exact paper color from the cell's border median.
        var borderR: [Int] = []
        var borderG: [Int] = []
        var borderB: [Int] = []
        borderR.reserveCapacity(2 * (w + h))
        borderG.reserveCapacity(2 * (w + h))
        borderB.reserveCapacity(2 * (w + h))
        for x in 0..<w {
            for y in [0, h - 1] {
                let i = (y * w + x) * 4
                borderR.append(Int(px[i]))
                borderG.append(Int(px[i + 1]))
                borderB.append(Int(px[i + 2]))
            }
        }
        for y in 0..<h {
            for x in [0, w - 1] {
                let i = (y * w + x) * 4
                borderR.append(Int(px[i]))
                borderG.append(Int(px[i + 1]))
                borderB.append(Int(px[i + 2]))
            }
        }
        borderR.sort()
        borderG.sort()
        borderB.sort()
        let bgR = Double(borderR[borderR.count / 2])
        let bgG = Double(borderG[borderG.count / 2])
        let bgB = Double(borderB[borderB.count / 2])
        let bgRB = bgR - bgB
        let bgLuma = 0.299 * bgR + 0.587 * bgG + 0.114 * bgB

        @inline(__always)
        func isOuterPaper(_ idx: Int, maxDist: Double, maxWarmthDelta: Double) -> Bool {
            let i = idx * 4
            let r = Double(px[i])
            let g = Double(px[i + 1])
            let b = Double(px[i + 2])
            let dr = r - bgR
            let dg = g - bgG
            let db = b - bgB
            if dr * dr + dg * dg + db * db > maxDist * maxDist { return false }
            // Cream porcelain has distinctly higher warmth (R - B) than neutral paper.
            return (r - b) - bgRB <= maxWarmthDelta
        }

        @inline(__always)
        func isNeutralHolePaper(_ idx: Int) -> Bool {
            let i = idx * 4
            let r = Double(px[i])
            let g = Double(px[i + 1])
            let b = Double(px[i + 2])
            let lo = min(r, g, b)
            let hi = max(r, g, b)
            // Neutral bright paper inside enclosed holes (e.g., center of # and @) without touching warm cream.
            return lo >= 198 && (hi - lo) <= 16.0 && (r - b) <= 14.5
        }

        // 2. Flood-fill exterior paper strictly from borders (never leaks into warm porcelain highlights).
        var isBg = [Bool](repeating: false, count: count)
        var queue: [Int] = []
        queue.reserveCapacity(count / 2)

        func enqueueOuter(_ p: Int) {
            guard !isBg[p], isOuterPaper(p, maxDist: 16.0, maxWarmthDelta: 5.5) else { return }
            isBg[p] = true
            queue.append(p)
        }
        for x in 0..<w {
            enqueueOuter(x)
            enqueueOuter((h - 1) * w + x)
        }
        for y in 0..<h {
            enqueueOuter(y * w)
            enqueueOuter(y * w + w - 1)
        }

        var head = 0
        while head < queue.count {
            let p = queue[head]
            head += 1
            let x = p % w
            let y = p / w
            if x > 0 { enqueueOuter(p - 1) }
            if x + 1 < w { enqueueOuter(p + 1) }
            if y > 0 { enqueueOuter(p - w) }
            if y + 1 < h { enqueueOuter(p + w) }
        }

        // 3. Erode 2 steps of pale neutral AA halo & paper bridges between detached motion lines.
        for _ in 0..<2 {
            var nextBg: [Int] = []
            for p in 0..<count where !isBg[p] {
                let x = p % w
                let y = p / w
                let touchesBg = (x > 0 && isBg[p - 1]) || (x + 1 < w && isBg[p + 1]) ||
                    (y > 0 && isBg[p - w]) || (y + 1 < h && isBg[p + w])
                guard touchesBg else { continue }
                let i = p * 4
                let r = Double(px[i])
                let g = Double(px[i + 1])
                let b = Double(px[i + 2])
                let dr = r - bgR
                let dg = g - bgG
                let db = b - bgB
                let sat = max(r, g, b) - min(r, g, b)
                let luma = 0.299 * r + 0.587 * g + 0.114 * b
                if dr * dr + dg * dg + db * db <= 52.0 * 52.0 && sat <= 24.0 &&
                    (r - b) - bgRB <= 7.5 && luma >= bgLuma - 48.0 && luma <= bgLuma + 3.5 {
                    nextBg.append(p)
                }
            }
            for p in nextBg { isBg[p] = true }
        }

        // Re-flood outer paper in case an AA bridge previously sealed off a background pocket.
        var q2: [Int] = []
        q2.reserveCapacity(count / 2)
        for p in 0..<count where isBg[p] { q2.append(p) }
        var h2 = 0
        while h2 < q2.count {
            let p = q2[h2]
            h2 += 1
            let x = p % w
            let y = p / w
            if x > 0 {
                let np = p - 1
                if !isBg[np] && isOuterPaper(np, maxDist: 16.0, maxWarmthDelta: 5.5) { isBg[np] = true; q2.append(np) }
            }
            if x + 1 < w {
                let np = p + 1
                if !isBg[np] && isOuterPaper(np, maxDist: 16.0, maxWarmthDelta: 5.5) { isBg[np] = true; q2.append(np) }
            }
            if y > 0 {
                let np = p - w
                if !isBg[np] && isOuterPaper(np, maxDist: 16.0, maxWarmthDelta: 5.5) { isBg[np] = true; q2.append(np) }
            }
            if y + 1 < h {
                let np = p + w
                if !isBg[np] && isOuterPaper(np, maxDist: 16.0, maxWarmthDelta: 5.5) { isBg[np] = true; q2.append(np) }
            }
        }

        // 4. Remove enclosed neutral-paper counter holes (like inside # and @) strictly ringed by dark outline.
        if removeEnclosedHoles {
            var visited = isBg
            for p in 0..<count where !visited[p] && isNeutralHolePaper(p) {
                var comp: [Int] = [p]
                visited[p] = true
                var darkBorder = 0
                var totalBorder = 0
                var ch = 0
                while ch < comp.count {
                    let cp = comp[ch]
                    ch += 1
                    let x = cp % w
                    let y = cp / w
                    let neighbors = [
                        x > 0 ? cp - 1 : -1,
                        x + 1 < w ? cp + 1 : -1,
                        y > 0 ? cp - w : -1,
                        y + 1 < h ? cp + w : -1
                    ]
                    for np in neighbors where np >= 0 {
                        if !visited[np] && isNeutralHolePaper(np) {
                            visited[np] = true
                            comp.append(np)
                        } else if !isBg[np] && !isNeutralHolePaper(np) {
                            totalBorder += 1
                            let ni = np * 4
                            let r = Double(px[ni])
                            let g = Double(px[ni + 1])
                            let b = Double(px[ni + 2])
                            let luma = 0.299 * r + 0.587 * g + 0.114 * b
                            let isCyan = b > r + 15 && g > r + 10
                            let isPink = r > g + 15 && b > g + 5
                            if luma < 195 && !isCyan && !isPink {
                                darkBorder += 1
                            }
                        }
                    }
                }
                if comp.count <= 900 && totalBorder > 0 && Double(darkBorder) / Double(totalBorder) >= 0.78 {
                    for cp in comp { isBg[cp] = true }
                }
            }
        }

        // 5. Remove tiny isolated stray dust specks (< 14px).
        var fgVisited = isBg
        for p in 0..<count where !fgVisited[p] {
            var comp: [Int] = [p]
            fgVisited[p] = true
            var ch = 0
            while ch < comp.count {
                let cp = comp[ch]
                ch += 1
                let x = cp % w
                let y = cp / w
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        let ny = y + dy
                        if nx >= 0 && nx < w && ny >= 0 && ny < h {
                            let np = ny * w + nx
                            if !fgVisited[np] {
                                fgVisited[np] = true
                                comp.append(np)
                            }
                        }
                    }
                }
            }
            if comp.count < 14 {
                for cp in comp { isBg[cp] = true }
            }
        }

        // 6. Compute distance from transparent background (up to 3px) for boundary color unmixing.
        var distToBg = [Int](repeating: 99, count: count)
        var dq: [Int] = []
        dq.reserveCapacity(count)
        for p in 0..<count where isBg[p] {
            distToBg[p] = 0
            dq.append(p)
        }
        var dh = 0
        while dh < dq.count {
            let p = dq[dh]
            dh += 1
            let d = distToBg[p]
            if d >= 3 { continue }
            let x = p % w
            let y = p / w
            if x > 0 && distToBg[p - 1] > d + 1 { distToBg[p - 1] = d + 1; dq.append(p - 1) }
            if x + 1 < w && distToBg[p + 1] > d + 1 { distToBg[p + 1] = d + 1; dq.append(p + 1) }
            if y > 0 && distToBg[p - w] > d + 1 { distToBg[p - w] = d + 1; dq.append(p - w) }
            if y + 1 < h && distToBg[p + w] > d + 1 { distToBg[p + w] = d + 1; dq.append(p + w) }
        }

        // 7. Unmix paper pigment out of the 1-2px AA boundary ring so edges stay crisp on both light and dark screens.
        var out = [UInt8](repeating: 0, count: count * 4)
        for p in 0..<count {
            let i = p * 4
            if isBg[p] { continue }
            let d = distToBg[p]
            if d >= 3 {
                out[i] = px[i]
                out[i + 1] = px[i + 1]
                out[i + 2] = px[i + 2]
                out[i + 3] = 255
                continue
            }

            let x = p % w
            let y = p / w
            let obsR = Double(px[i])
            let obsG = Double(px[i + 1])
            let obsB = Double(px[i + 2])
            var bestFgR = obsR
            var bestFgG = obsG
            var bestFgB = obsB
            var bestScore = Double.greatestFiniteMagnitude
            var bestAlpha = 1.0
            var foundInterior = false

            for dy in -2...2 {
                for dx in -2...2 {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0 && nx < w && ny >= 0 && ny < h else { continue }
                    let np = ny * w + nx
                    guard distToBg[np] >= 2 && (d == 1 || distToBg[np] >= 3) else { continue }
                    let ni = np * 4
                    let fgR = Double(px[ni])
                    let fgG = Double(px[ni + 1])
                    let fgB = Double(px[ni + 2])
                    let vr = fgR - bgR
                    let vg = fgG - bgG
                    let vb = fgB - bgB
                    let denom = vr * vr + vg * vg + vb * vb
                    guard denom > 400 else { continue }
                    let wr = obsR - bgR
                    let wg = obsG - bgG
                    let wb = obsB - bgB
                    let alpha = min(1.0, max(0.0, (wr * vr + wg * vg + wb * vb) / denom))
                    let projR = bgR + alpha * vr
                    let projG = bgG + alpha * vg
                    let projB = bgB + alpha * vb
                    let err = ((obsR - projR) * (obsR - projR) +
                               (obsG - projG) * (obsG - projG) +
                               (obsB - projB) * (obsB - projB)).squareRoot()
                    let score = err + Double(dx * dx + dy * dy) * 0.8
                    if score < bestScore {
                        bestScore = score
                        bestFgR = fgR
                        bestFgG = fgG
                        bestFgB = fgB
                        bestAlpha = alpha
                        foundInterior = true
                    }
                }
            }

            if foundInterior && bestScore < 34.0 {
                if bestAlpha >= 0.28 {
                    let cleanAlpha = min(1.0, max(0.0, (bestAlpha - 0.24) / 0.50))
                    out[i] = UInt8(min(255, max(0, Int((bestFgR * cleanAlpha).rounded()))))
                    out[i + 1] = UInt8(min(255, max(0, Int((bestFgG * cleanAlpha).rounded()))))
                    out[i + 2] = UInt8(min(255, max(0, Int((bestFgB * cleanAlpha).rounded()))))
                    out[i + 3] = UInt8(min(255, max(0, Int((cleanAlpha * 255.0).rounded()))))
                }
            } else {
                out[i] = px[i]
                out[i + 1] = px[i + 1]
                out[i + 2] = px[i + 2]
                out[i + 3] = 255
            }
        }

        let data = Data(out)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: stride, space: space, bitmapInfo: CGBitmapInfo(rawValue: format),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }

        guard trim else { return Output(image: image, pixels: out, width: w, height: h) }

        var minX = w
        var maxX = -1
        var minY = h
        var maxY = -1
        for y in 0..<h {
            for x in 0..<w where out[(y * w + x) * 4 + 3] >= 32 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard minX <= maxX,
              let trimmed = image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
        else { return nil }
        return Output(image: trimmed, pixels: out, width: trimmed.width, height: trimmed.height)
    }
}

enum ToiletSpriteSheet {
    static let frameWidth = 232
    static let frameHeight = 244
    static let anchorBottomY = 232

    static let frames: [CGImage] = {
        guard let url = Bundle.main.url(forResource: "toilet_sheet", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return extract(from: sheet)
    }()

    static func prewarm() {
        Task.detached(priority: .utility) {
            _ = ToiletSpriteSheet.frames
            _ = SymbolSpriteSheet.sprites
        }
    }

    static func extract(from sheet: CGImage) -> [CGImage] {
        guard sheet.width == 1774, sheet.height == 887 else { return [] }
        var frames: [CGImage] = []
        frames.reserveCapacity(18)
        for row in 0..<3 {
            for column in 0..<6 {
                let x = max(0, column * sheet.width / 6 + 32)
                let y = max(0, row * sheet.height / 3 + 36)
                let rect = CGRect(x: x, y: y, width: min(frameWidth, sheet.width - x), height: min(frameHeight, sheet.height - y))
                guard let crop = sheet.cropping(to: rect),
                      let matted = SpriteMatte.extract(from: crop, removeEnclosedHoles: true, trim: false),
                      let aligned = alignBase(matted) else { return [] }
                frames.append(aligned)
            }
        }
        return frames
    }

    private static func alignBase(_ matted: SpriteMatte.Output) -> CGImage? {
        let w = matted.width
        let h = matted.height
        let px = matted.pixels
        var baseMinX = w
        var baseMaxX = -1
        var baseMaxY = -1

        for y in (h * 2 / 3)..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                guard px[i + 3] >= 200 else { continue }
                let r = Int(px[i])
                let g = Int(px[i + 1])
                let b = Int(px[i + 2])
                if r < 115 && g < 115 && b < 95 {
                    baseMinX = min(baseMinX, x)
                    baseMaxX = max(baseMaxX, x)
                    baseMaxY = max(baseMaxY, y)
                }
            }
        }

        let centerX = baseMinX <= baseMaxX ? (baseMinX + baseMaxX) / 2 : w / 2
        let shiftX = (frameWidth / 2) - centerX
        let dyTop = baseMaxY >= 0 ? (anchorBottomY - baseMaxY) : 0
        let drawY = frameHeight - dyTop - h

        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let format = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(data: nil, width: frameWidth, height: frameHeight, bitsPerComponent: 8,
                                  bytesPerRow: frameWidth * 4, space: space, bitmapInfo: format) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(matted.image, in: CGRect(x: CGFloat(shiftX), y: CGFloat(drawY), width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }
}

enum SymbolSpriteSheet {
    static let sprites: [CGImage] = {
        guard let url = Bundle.main.url(forResource: "symbol_sheet", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        return extract(from: sheet)
    }()

    static func extract(from sheet: CGImage) -> [CGImage] {
        guard sheet.width == 1448, sheet.height == 1086 else { return [] }
        var icons: [CGImage] = []
        icons.reserveCapacity(20)
        for row in 0..<4 {
            for column in 0..<5 {
                let left = column * sheet.width / 5
                let top = row * sheet.height / 4
                let rect = CGRect(x: left, y: top, width: (column + 1) * sheet.width / 5 - left,
                                  height: (row + 1) * sheet.height / 4 - top)
                guard let cell = sheet.cropping(to: rect),
                      let icon = SpriteMatte.extract(from: cell, removeEnclosedHoles: true, trim: true)?.image
                else { return [] }
                icons.append(icon)
            }
        }
        return icons
    }
}

// MARK: - Recording Stage View

struct ToiletRecordingView: View {
    static let closingDuration: Duration = .milliseconds(380)

    let notice: StatusNotice
    let field: RecordingWavefield
    let openedAt: Date
    let phaseStartedAt: Date
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { tick in
            stage(at: tick.date)
        }
        .frame(width: PixelStage.width, height: PixelStage.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(notice.title)。\(notice.detail)")
    }

    func snapshotAt(_ time: Date) -> some View {
        stage(at: time)
            .frame(width: PixelStage.width, height: PixelStage.height)
    }

    private func stage(at time: Date) -> some View {
        let frames = ToiletSpriteSheet.frames
        let index = frameIndex(at: time)
        let closingAt = notice.recorderPhase == .closing ? phaseStartedAt : nil
        let isRecording = notice.recorderPhase == .recording
        let voiceLevel = isRecording ? field.decayedLevel(at: time) : 0
        let motion = toiletTransform(at: time, voiceLevel: voiceLevel, closingAt: closingAt)

        return ZStack(alignment: .bottom) {
            ZStack {
                // 1. Ground shadow & voice-reactive bowl halo behind the toilet
                Canvas { context, _ in
                    PixelStage.drawBackdrop(
                        in: context,
                        voiceLevel: voiceLevel,
                        entrance: motion.entrance,
                        squashX: motion.scaleX,
                        isClosing: closingAt != nil,
                        time: time
                    )
                }

                // 2. Pixel-accurate, base-anchored toilet sprite with spring squash & stretch
                if frames.indices.contains(index) {
                    Image(decorative: frames[index], scale: 2, orientation: .up)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: PixelStage.toiletSize.width, height: PixelStage.toiletSize.height)
                        .scaleEffect(
                            x: motion.scaleX * motion.entranceScale,
                            y: motion.scaleY * motion.entranceScale,
                            anchor: PixelStage.toiletBaseAnchor
                        )
                        .rotationEffect(.degrees(motion.tiltDegrees), anchor: PixelStage.toiletBaseAnchor)
                        .offset(y: motion.offsetY)
                        .opacity(motion.opacity)
                        .position(PixelStage.toiletCenter)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.red)
                        .position(PixelStage.toiletCenter)
                }

                // 3. Parabolic diving symbols (clipped at bowl front lip), splash droplets, ripples & bubbles
                if !reduceMotion && frames.indices.contains(index) {
                    Canvas { context, _ in
                        PixelStage.drawForegroundEffects(
                            in: context,
                            field: field,
                            phase: notice.recorderPhase,
                            openedAt: openedAt,
                            closingAt: closingAt,
                            voiceLevel: voiceLevel,
                            toiletOffsetY: motion.offsetY,
                            at: time
                        )
                    }
                }
            }
            .frame(width: PixelStage.width, height: PixelStage.height)
            .accessibilityHidden(true)

            // 4. Crisp bottom status capsule with live 5-bar pixel audio equalizer
            statusPill(at: time, voiceLevel: voiceLevel)
                .padding(.bottom, 2)
        }
        .frame(width: PixelStage.width, height: PixelStage.height)
    }

    private func statusPill(at time: Date, voiceLevel: Double) -> some View {
        let isRecording = notice.recorderPhase == .recording
        let isClosing = notice.recorderPhase == .closing
        let bars = isRecording ? field.decayedBars(at: time) : [0.16, 0.24, 0.34, 0.24, 0.16]
        let pulse = 0.5 + 0.5 * sin(time.timeIntervalSinceReferenceDate * 4.8)
        let label = notice.badgeText ?? (isClosing ? "转写中" : notice.title)

        return HStack(spacing: 6) {
            ZStack {
                if isRecording && !reduceMotion {
                    Circle()
                        .fill(Color(red: 1.0, green: 0.32, blue: 0.34).opacity(0.24 + 0.22 * voiceLevel))
                        .frame(width: 8.5 + 3.5 * pulse, height: 8.5 + 3.5 * pulse)
                }
                Circle()
                    .fill(isRecording ? Color(red: 1.0, green: 0.33, blue: 0.35)
                          : (isClosing ? Color(red: 0.34, green: 0.86, blue: 0.96)
                             : Color(red: 1.0, green: 0.72, blue: 0.28)))
                    .frame(width: 5, height: 5)
            }
            .frame(width: 10, height: 10)

            if isRecording {
                HStack(alignment: .center, spacing: 1.8) {
                    ForEach(0..<bars.count, id: \.self) { idx in
                        let height = 2.5 + bars[idx] * 9.0
                        Capsule()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.62, green: 0.96, blue: 1.0),
                                        Color(red: 0.30, green: 0.80, blue: 0.96).opacity(0.88)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 2.0, height: height)
                    }
                }
                .frame(height: 12)

                Rectangle()
                    .fill(.white.opacity(0.16))
                    .frame(width: 0.6, height: 9)
            }

            Text(label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .tracking(0.3)
                .foregroundStyle(.white.opacity(isRecording ? 0.94 : 0.82))
        }
        .padding(.horizontal, isRecording ? 10 : 11)
        .padding(.vertical, 4.5)
        .background {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.11, green: 0.14, blue: 0.19).opacity(0.84),
                            Color(red: 0.06, green: 0.08, blue: 0.12).opacity(0.92)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .overlay {
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.26), .white.opacity(0.08)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.65
                )
        }
        .shadow(color: .black.opacity(0.24), radius: 8, y: 3)
    }

    private struct ToiletMotion {
        let entrance: Double
        let entranceScale: Double
        let scaleX: Double
        let scaleY: Double
        let offsetY: Double
        let tiltDegrees: Double
        let opacity: Double
    }

    private func toiletTransform(at time: Date, voiceLevel: Double, closingAt: Date?) -> ToiletMotion {
        if reduceMotion {
            return ToiletMotion(entrance: 1, entranceScale: 1, scaleX: 1, scaleY: 1, offsetY: 0, tiltDegrees: 0, opacity: 1)
        }

        // Snappy spring-pop entrance over first 0.25s
        let openElapsed = max(0, time.timeIntervalSince(openedAt))
        let entranceProgress = min(1, openElapsed / 0.24)
        let entranceOvershoot: Double
        if openElapsed < 0.28 {
            let t = openElapsed / 0.28
            entranceOvershoot = 1 - exp(-8.5 * t) * cos(t * 7.2)
        } else {
            entranceOvershoot = 1
        }
        let entranceScale = 0.74 + 0.26 * entranceOvershoot
        let entranceOffsetY = (1 - entranceOvershoot) * 14.0
        let opacity = min(1, openElapsed / 0.085)

        // Subtle organic idle float & breathing
        let t = time.timeIntervalSinceReferenceDate
        let idleFloatY = sin(t * 3.1) * 1.15
        let idleBreath = sin(t * 3.1 + 0.6) * 0.012

        // Live voice-reactive bounce & tilt
        let voiceBounceY = -voiceLevel * 2.2 * (0.5 + 0.5 * sin(t * 17.0))
        let voiceSquash = voiceLevel * 0.025 * sin(t * 17.0)
        let voiceTilt = voiceLevel * 1.45 * sin(t * 9.5)

        // Splash impact damped-spring squash & stretch
        let splash = field.squashImpulse(at: time, releasedAt: closingAt)

        // Opening lid-snap anticipation & closing lid-slam bounce
        var phaseSX = 0.0
        var phaseSY = 0.0
        var phaseDy = 0.0
        if openElapsed >= 0.07 && openElapsed < 0.24 {
            let p = (openElapsed - 0.07) / 0.17
            let pop = sin(p * .pi)
            phaseSX -= 0.05 * pop
            phaseSY += 0.06 * pop
        }
        if let closingAt {
            let closeElapsed = max(0, time.timeIntervalSince(closingAt))
            let slamAge = closeElapsed - 0.26
            if slamAge >= 0 && slamAge < 0.14 {
                let damp = exp(-18.0 * slamAge) * sin(slamAge * 42.0)
                phaseSX += 0.09 * damp
                phaseSY -= 0.09 * damp
                phaseDy += 2.2 * max(0, damp)
            }
        }

        return ToiletMotion(
            entrance: entranceProgress,
            entranceScale: entranceScale,
            scaleX: 1.0 + idleBreath + voiceSquash + splash.sx + phaseSX,
            scaleY: 1.0 - idleBreath - voiceSquash + splash.sy + phaseSY,
            offsetY: entranceOffsetY + idleFloatY + voiceBounceY + splash.dy + phaseDy,
            tiltDegrees: voiceTilt + splash.tilt,
            opacity: opacity
        )
    }

    func frameIndex(at time: Date) -> Int {
        if notice.recorderPhase == .closing {
            if reduceMotion { return 17 }
            let elapsed = max(0, time.timeIntervalSince(phaseStartedAt))
            let lidTime = elapsed - 0.135
            if lidTime < 0 { return field.waterFrame(at: time, releasedAt: phaseStartedAt) }
            // Frames 14 -> 15 -> 16 -> 17 crisp lid-slam
            return min(17, 14 + Int(lidTime / 0.042))
        }
        if reduceMotion { return 4 }
        let elapsed = max(0, time.timeIntervalSince(openedAt))
        if elapsed < 0.175 { return min(3, Int(elapsed / 0.044)) }
        return field.waterFrame(at: time, releasedAt: nil)
    }
}

// MARK: - Pixel-Art Canvas Effects

private enum PixelStage {
    static let width: CGFloat = 344
    static let height: CGFloat = 186

    // Toilet sprite (232x244 @2x -> 116x122 pt) positioned cleanly above the status pill
    static let toiletSize = CGSize(width: 116, height: 122)
    static let toiletCenter = CGPoint(x: 172, y: 92)
    static let toiletBaseAnchor = UnitPoint(x: 0.5, y: 232.0 / 244.0)

    // Exact open water surface and front porcelain rim clip line inside the 344x186 stage
    static let bowl = CGPoint(x: 172, y: 107.5)
    static let bowlFrontLipY: CGFloat = 114.5
    static let groundShadowCenter = CGPoint(x: 172, y: 150.5)

    // Exact palette matched to 最新马桶.png & 復古像素风图标合集.png
    private static let cyanWater = Color(red: 0.25, green: 0.82, blue: 0.92)
    private static let brightCyan = Color(red: 0.52, green: 0.95, blue: 1.0)
    private static let creamFoam = Color(red: 0.98, green: 0.96, blue: 0.89)
    private static let warmOrange = Color(red: 0.96, green: 0.53, blue: 0.14)
    private static let pixelOutline = Color(red: 0.29, green: 0.29, blue: 0.17)

    static func drawBackdrop(
        in context: GraphicsContext,
        voiceLevel: Double,
        entrance: Double,
        squashX: Double,
        isClosing: Bool,
        time: Date
    ) {
        // Soft grounded contact shadow under the toilet base
        let shadowW = 56.0 * entrance * squashX
        let shadowH = 9.0 * entrance
        let shadowRect = CGRect(
            x: groundShadowCenter.x - shadowW / 2,
            y: groundShadowCenter.y - shadowH / 2,
            width: shadowW,
            height: shadowH
        )
        var shadowCtx = context
        shadowCtx.addFilter(.blur(radius: 3.5))
        shadowCtx.fill(Path(ellipseIn: shadowRect), with: .color(.black.opacity(0.28 * entrance)))

        // Subtle aqua-cyan bowl aura reacting gently to live voice energy
        guard !isClosing else { return }
        let idlePulse = 0.5 + 0.5 * sin(time.timeIntervalSinceReferenceDate * 3.6)
        let glowStrength = (0.07 + 0.04 * idlePulse + 0.22 * voiceLevel) * entrance
        let radius = 32.0 + 18.0 * voiceLevel
        let gradient = Gradient(stops: [
            .init(color: brightCyan.opacity(glowStrength), location: 0),
            .init(color: cyanWater.opacity(glowStrength * 0.42), location: 0.55),
            .init(color: .clear, location: 1)
        ])
        let glowCenter = CGPoint(x: bowl.x, y: bowl.y - 4)
        context.fill(
            Path(ellipseIn: CGRect(x: glowCenter.x - radius, y: glowCenter.y - radius * 0.72,
                                   width: radius * 2, height: radius * 1.44)),
            with: .radialGradient(gradient, center: glowCenter, startRadius: 2, endRadius: radius)
        )
    }

    static func drawForegroundEffects(
        in context: GraphicsContext,
        field: RecordingWavefield,
        phase: RecorderHUDPhase?,
        openedAt: Date,
        closingAt: Date?,
        voiceLevel: Double,
        toiletOffsetY: Double,
        at time: Date
    ) {
        let bowlCenter = CGPoint(x: bowl.x, y: bowl.y + toiletOffsetY)
        let frontLipY = bowlFrontLipY + toiletOffsetY
        let splashes = field.splashEvents(releasedAt: closingAt)
        // Fade out water ripples & splash droplets swiftly once the lid starts closing so the lid-slam is super clean!
        let lidFade: Double
        if let closingAt {
            let lidTime = time.timeIntervalSince(closingAt) - 0.13
            lidFade = lidTime <= 0 ? 1.0 : max(0, 1.0 - lidTime / 0.065)
        } else {
            lidFade = 1.0
        }

        // 1. Subtle expanding pixel-cohesive water ripple strictly on the latest splash (never over closing lid!)
        if lidFade > 0, let latestSplash = splashes.last(where: { $0.landingAt <= time }) {
            let age = time.timeIntervalSince(latestSplash.landingAt)
            if age >= 0, age < 0.22 {
                let p = age / 0.22
                let ease = 1 - (1 - p) * (1 - p)
                let rw = 16.0 + (20.0 + 8.0 * latestSplash.strength) * ease
                let rh = 4.5 + (5.0 + 2.5 * latestSplash.strength) * ease
                let rippleRect = CGRect(x: bowlCenter.x - rw / 2, y: bowlCenter.y - rh / 2, width: rw, height: rh)
                let alpha = (1 - p) * (0.52 + 0.18 * latestSplash.strength) * lidFade
                context.stroke(Path(ellipseIn: rippleRect), with: .color(brightCyan.opacity(alpha)), lineWidth: 1.5)
            }
        }

        // 2. Subtle ambient listening bubbles rising from the open bowl while recording
        if phase == .recording && time.timeIntervalSince(openedAt) > 0.22 {
            drawAmbientBubbles(in: context, bowlCenter: bowlCenter, voiceLevel: voiceLevel, at: time)
        }

        // 3. Parabolic flying pixel symbols + launch pop sparks + pixel motion trail + bowl submersion clip
        let sprites = SymbolSpriteSheet.sprites
        for symbol in field.symbols {
            drawLaunchSparks(symbol, at: time, in: context)

            let rawProgress = symbol.progress(at: time, releasedAt: closingAt)
            guard rawProgress >= 0, rawProgress < 1, time < symbol.landing(releasedAt: closingAt) else { continue }

            // Gravity/suction ease: graceful arc at launch, brisk plunge into the bowl!
            let easedT = rawProgress * (0.64 + 0.36 * rawProgress)
            drawMotionTrail(symbol, rawProgress: rawProgress, target: bowlCenter, in: context)
            drawSymbol(symbol, rawProgress: rawProgress, easedT: easedT, target: bowlCenter,
                       frontLipY: frontLipY, sprites: sprites, in: context)
        }

        // 4. Clean outward-fanning ballistic pixel splash droplets on water impact!
        if lidFade > 0 {
            for splash in splashes {
                let age = time.timeIntervalSince(splash.landingAt)
                guard age >= 0, age < 0.38 else { continue }
                for droplet in splash.droplets {
                    guard age < droplet.lifetime else { continue }
                    let lifeP = age / droplet.lifetime
                    let x = bowlCenter.x + droplet.offsetX + droplet.vx * age
                    let y = (bowlCenter.y - 4) + droplet.vy * age + 0.5 * 500.0 * age * age
                    guard y <= frontLipY + 1 else { continue }
                    let fade = (lifeP > 0.60 ? max(0, 1 - (lifeP - 0.60) / 0.40) : 1.0) * lidFade
                    let size = droplet.size * (1 - 0.26 * lifeP)
                    let fillColor: Color
                    switch droplet.colorKind {
                    case 2: fillColor = warmOrange
                    case 1: fillColor = creamFoam
                    default: fillColor = cyanWater
                    }
                    let rect = CGRect(x: (x - size / 2).rounded(), y: (y - size / 2).rounded(), width: size, height: size)
                    if size >= 3.0 {
                        context.fill(Path(rect.insetBy(dx: -0.85, dy: -0.85)), with: .color(pixelOutline.opacity(0.62 * fade)))
                    }
                    context.fill(Path(rect), with: .color(fillColor.opacity(0.95 * fade)))
                }
            }
        }

        // 5. Crisp retro confirmation sparks right as the lid slams shut!
        if let closingAt {
            let slamAge = time.timeIntervalSince(closingAt) - 0.255
            if slamAge >= 0 && slamAge < 0.14 {
                let p = slamAge / 0.14
                let ease = 1 - (1 - p) * (1 - p)
                let fade = 1 - p
                let originY = toiletCenter.y - 42 + toiletOffsetY
                let angles: [Double] = [-2.35, -1.85, -1.28, -0.78]
                for (idx, angle) in angles.enumerated() {
                    let dist = 10.0 + 22.0 * ease
                    let sx = bowl.x + cos(angle) * dist
                    let sy = originY + sin(angle) * dist
                    let sz = (idx.isMultiple(of: 2) ? 4.0 : 3.0) * (1 - 0.35 * p)
                    let color = idx.isMultiple(of: 2) ? warmOrange : brightCyan
                    let rect = CGRect(x: sx - sz / 2, y: sy - sz / 2, width: sz, height: sz)
                    context.fill(Path(rect.insetBy(dx: -0.8, dy: -0.8)), with: .color(pixelOutline.opacity(0.6 * fade)))
                    context.fill(Path(rect), with: .color(color.opacity(fade)))
                }
            }
        }
    }

    private static func drawAmbientBubbles(
        in context: GraphicsContext,
        bowlCenter: CGPoint,
        voiceLevel: Double,
        at time: Date
    ) {
        let now = time.timeIntervalSinceReferenceDate
        let period = 1.65
        for idx in 0..<3 {
            let phase = (now / period + Double(idx) * 0.333).truncatingRemainder(dividingBy: 1.0)
            let xOff = (Double(idx) - 1.0) * 11.5 + sin(phase * 6.0 + Double(idx) * 2.1) * 3.2
            let rise = phase * (18.0 + 10.0 * voiceLevel)
            let alpha = sin(phase * .pi) * (0.42 + 0.38 * voiceLevel)
            let sz = (idx == 1 ? 3.2 : 2.5) * (0.85 + 0.25 * sin(phase * .pi))
            let rect = CGRect(x: bowlCenter.x + xOff - sz / 2, y: bowlCenter.y - 3 - rise - sz / 2, width: sz, height: sz)
            context.fill(Path(rect), with: .color((idx == 1 ? brightCyan : creamFoam).opacity(alpha)))
        }
    }

    private static func drawLaunchSparks(
        _ symbol: RecordingWavefield.FlyingSymbol,
        at time: Date,
        in context: GraphicsContext
    ) {
        let age = time.timeIntervalSince(symbol.spawnAt)
        guard age >= 0, age < 0.16 else { return }
        let p = age / 0.16
        let ease = 1 - (1 - p) * (1 - p)
        let fade = 1 - p
        for spark in symbol.launchSparks {
            let x = symbol.origin.x + cos(spark.angle) * spark.distance * ease
            let y = symbol.origin.y + sin(spark.angle) * spark.distance * ease
            let sz = spark.size * (1 - 0.45 * p)
            let color: Color = spark.paletteIndex == 0 ? brightCyan : (spark.paletteIndex == 1 ? warmOrange : creamFoam)
            context.fill(Path(CGRect(x: x - sz / 2, y: y - sz / 2, width: sz, height: sz)), with: .color(color.opacity(fade * 0.92)))
        }
    }

    private static func drawMotionTrail(
        _ symbol: RecordingWavefield.FlyingSymbol,
        rawProgress: Double,
        target: CGPoint,
        in context: GraphicsContext
    ) {
        guard rawProgress > 0.08 else { return }
        for step in 1...3 {
            let trailRaw = rawProgress - Double(step) * 0.055
            guard trailRaw > 0.02 else { continue }
            let trailT = trailRaw * (0.64 + 0.36 * trailRaw)
            let pos = symbol.position(at: trailT, target: target)
            guard pos.y < bowlFrontLipY - 2 else { continue }
            let sz = max(2.0, 4.2 - Double(step) * 0.85)
            let alpha = (0.55 - Double(step) * 0.14) * min(1, (1 - rawProgress) * 4.5)
            let color = step == 1 ? creamFoam : brightCyan
            context.fill(
                Path(CGRect(x: pos.x - sz / 2, y: pos.y - sz / 2, width: sz, height: sz)),
                with: .color(color.opacity(alpha))
            )
        }
    }

    private static func drawSymbol(
        _ symbol: RecordingWavefield.FlyingSymbol,
        rawProgress: Double,
        easedT: Double,
        target: CGPoint,
        frontLipY: CGFloat,
        sprites: [CGImage],
        in context: GraphicsContext
    ) {
        let pos = symbol.position(at: easedT, target: target)
        let vel = symbol.velocity(at: easedT, target: target)

        // Elastic pop-in on launch, steady mid-flight, then swift suction shrink into the bowl!
        let popScale: Double
        if rawProgress < 0.20 {
            let p = rawProgress / 0.20
            popScale = 0.22 + 0.92 * sin(p * .pi * 0.62)
        } else if rawProgress > 0.72 {
            let p = (rawProgress - 0.72) / 0.28
            popScale = max(0.28, 1.0 - 0.68 * p * p)
        } else {
            popScale = 1.0
        }

        // Subtle suction stretch as it plunges into the water mouth
        let plungeFactor = max(0, (rawProgress - 0.68) / 0.32)
        let scaleX = popScale * (1 - 0.22 * plungeFactor)
        let scaleY = popScale * (1 + 0.16 * plungeFactor)

        let opacity: Double
        if rawProgress < 0.08 {
            opacity = rawProgress / 0.08
        } else if rawProgress > 0.86 {
            opacity = max(0, 1 - (rawProgress - 0.86) / 0.14)
        } else {
            opacity = 1.0
        }

        // Gentle playful tilt aligned with trajectory
        let velTilt = max(-0.26, min(0.26, Double(vel.dx) / 700.0))
        let angle = symbol.baseTilt + velTilt + sin(rawProgress * .pi * 2.0) * symbol.spinSpeed * 0.24

        var tile = context
        // Clip at the front porcelain rim during final approach so icons genuinely submerge INTO the water!
        if rawProgress > 0.52 {
            tile.clip(to: Path(CGRect(x: 0, y: 0, width: width, height: frontLipY)))
        }
        tile.opacity = opacity
        tile.translateBy(x: pos.x, y: pos.y)
        tile.rotate(by: .radians(angle))
        tile.scaleBy(x: scaleX, y: scaleY)

        if sprites.indices.contains(symbol.spriteIndex) {
            let image = sprites[symbol.spriteIndex]
            let fit = symbol.size / Double(max(image.width, image.height))
            let drawW = Double(image.width) * fit
            let drawH = Double(image.height) * fit
            tile.draw(
                Image(decorative: image, scale: 2, orientation: .up).interpolation(.medium),
                in: CGRect(x: -drawW / 2, y: -drawH / 2, width: drawW, height: drawH)
            )
        } else {
            let s = symbol.size * 0.36
            tile.fill(Path(CGRect(x: -s / 2, y: -s / 2, width: s, height: s)), with: .color(brightCyan))
        }
    }
}
