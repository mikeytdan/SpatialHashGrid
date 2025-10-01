import Combine
import SwiftUI
import simd

// MARK: - DisplayLink (steady ticks, low overhead)
@MainActor
final class DisplayLinkDriver: ObservableObject {
    @Published var timestamp: CFTimeInterval = CACurrentMediaTime()
    private var link: CADisplayLink?

    func start() {
        guard link == nil else { return }
        link = CADisplayLink(target: self, selector: #selector(tick))
        if #available(iOS 15.0, *) {
            link?.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        } else {
            link?.preferredFramesPerSecond = 60
        }
        link?.add(to: .main, forMode: .common)
    }
    func stop() { link?.invalidate(); link = nil }

    @objc private func tick(_ dl: CADisplayLink) { timestamp = dl.timestamp }
}

// MARK: - Model

struct RayViz: Identifiable {
    let id: Int
    let a: Vec2
    let b: Vec2
    let color: SIMD3<Double>
}

struct Unit: Identifiable, Hashable {
    let id: Int
    var pos: Vec2
    var vel: Vec2
    var radius: Double
    var isSpecial: Bool
    var aabb: AABB { AABB.fromCircle(center: pos, radius: radius) }
}

@MainActor
final class SpatialHashDemoModel: ObservableObject {
    @Published var units: [Unit] = []
    @Published var frameCount: Int = 0
    @Published var tintedRGB: [SIMD3<Double>] = []   // final per-unit color used by the renderer
    @Published var worldSize: CGSize                 // now resizable to match available view

    @Published var rays: [RayViz] = []                 // per-frame ray visuals
    @Published var raysPerSpecial: Int = 0             // 0..N rays per special (stress-test)

    let grid: SpatialHashGrid<Int>
    let influenceRadius: Double
    let specialCount: Int

    private var baseRGB: [SIMD3<Double>] = []       // stable unique color per unit
    private let neutralRGB = SIMD3<Double>(repeating: 0.75)
    private var rng = SystemRandomNumberGenerator()

    // scratch buffers to avoid per-frame allocations
    private var scratchIDs: [Int] = []
    private var scratchSeen = Set<Int>()
    private var acc: [SIMD3<Double>] = []
    private var wsum: [Double] = []

    private var rayPhase: [Double] = []                // per-unit phase for rotating rays
    private var baseTintedRGBCopy: [SIMD3<Double>] = []// last computed influence colors (baseline before overrides)

    init(worldSize: CGSize = CGSize(width: 900, height: 600),
         count: Int = 1500,
         specialCount: Int = 10,
         cellSize: Double = 48.0,              // tuned for influenceRadius below
         influenceRadius: Double = 64.0)
    {
        self.worldSize = worldSize
        self.grid = SpatialHashGrid<Int>(cellSize: cellSize,
                                         reserve: count,
                                         estimateCells: Int((worldSize.width*worldSize.height) / (cellSize*cellSize)))
        self.influenceRadius = influenceRadius
        self.specialCount = specialCount

        units.reserveCapacity(count)
        baseRGB.reserveCapacity(count)
        for i in 0..<count {
            let isSp = i < specialCount
            let r: Double = isSp ? 5.0 : 3.0
            let pos = Vec2(Double.random(in: r...(Double(worldSize.width) - r), using: &rng),
                           Double.random(in: r...(Double(worldSize.height) - r), using: &rng))
            let speed = isSp ? 80.0 : 55.0
            let angle = Double.random(in: 0..<(2*Double.pi), using: &rng)
            let vel = Vec2(cos(angle), sin(angle)) * speed
            let u = Unit(id: i, pos: pos, vel: vel, radius: r, isSpecial: isSp)
            units.append(u)
            _ = grid.insert(id: u.id, aabb: u.aabb)

            let hue = fmod(0.61803398875 * Double(i), 1.0) // golden-ratio hue spacing
            baseRGB.append(hslToRgb(hue, 0.75, isSp ? 0.50 : 0.55))
        }
        tintedRGB = Array(repeating: neutralRGB, count: count)
        rayPhase = Array(repeating: 0.0, count: count)
        baseTintedRGBCopy = tintedRGB
        ensureBuffers()
        computeInfluenceColors()
    }

    private func ensureBuffers() {
        let n = units.count
        if tintedRGB.count != n { tintedRGB = Array(repeating: neutralRGB, count: n) }
        if acc.count != n { acc = Array(repeating: .zero, count: n) }
        if wsum.count != n { wsum = Array(repeating: 0, count: n) }
        if rayPhase.count != n { rayPhase = Array(repeating: 0.0, count: n) }
        if baseTintedRGBCopy.count != n { baseTintedRGBCopy = Array(repeating: neutralRGB, count: n) }
    }

    /// Resize world and clamp existing units so they stay visible.
    func setWorldSize(_ size: CGSize) {
        guard size.width > 2, size.height > 2 else { return }
        if worldSize == size { return }
        worldSize = size

        let w = Double(size.width), h = Double(size.height)
        for i in units.indices {
            units[i].pos.x = min(max(units[i].pos.x, units[i].radius), w - units[i].radius)
            units[i].pos.y = min(max(units[i].pos.y, units[i].radius), h - units[i].radius)
            grid.update(id: units[i].id, newAABB: units[i].aabb)
        }
        computeInfluenceColors()
    }

    /// Simulation step (no UI work here)
    func step(dt: Double) {
        let w = Double(worldSize.width), h = Double(worldSize.height)
        let allowMovement = frameCount % 4 == 0
        for i in units.indices {
            guard units[i].isSpecial || allowMovement else { continue }
            units[i].pos += units[i].vel * dt
            // Bounce on bounds
            if units[i].pos.x < units[i].radius { units[i].pos.x = units[i].radius; units[i].vel.x = abs(units[i].vel.x) }
            if units[i].pos.y < units[i].radius { units[i].pos.y = units[i].radius; units[i].vel.y = abs(units[i].vel.y) }
            if units[i].pos.x > w - units[i].radius { units[i].pos.x = w - units[i].radius; units[i].vel.x = -abs(units[i].vel.x) }
            if units[i].pos.y > h - units[i].radius { units[i].pos.y = h - units[i].radius; units[i].vel.y = -abs(units[i].vel.y) }

            grid.update(id: units[i].id, newAABB: units[i].aabb)
        }
        frameCount &+= 1
    }

    /// Compute per-unit tinted colors:
    /// - Specials: their base color
    /// - Others: lighten/mix colors of influencing specials within radius (distance-weighted, no sqrt)
    func computeInfluenceColors() {
        ensureBuffers()

        // clear accumulators
        for i in 0..<acc.count { acc[i] = .zero }
        for i in 0..<wsum.count { wsum[i] = 0 }

        let ir = influenceRadius
        let ir2 = ir * ir

        // Iterate only specials, then visit their neighbors once — O(S * neighbors)
        for s in units where s.isSpecial {
            let sid = s.id
            let scol = baseRGB[sid]
            let influenceAABB = AABB.fromCircle(center: s.pos, radius: ir)
            grid.query(aabb: influenceAABB, into: &scratchIDs, scratch: &scratchSeen)
            for nid in scratchIDs {
                if nid == sid { continue }
                let v = units[nid]
                let dx = v.pos.x - s.pos.x
                let dy = v.pos.y - s.pos.y
                let d2 = dx*dx + dy*dy
                if d2 <= ir2 {
                    let w = max(0.0, 1.0 - d2 / ir2) // linear falloff without sqrt
                    acc[nid] = simd_muladd(scol, SIMD3<Double>(repeating: w), acc[nid]) // acc += scol * w
                    wsum[nid] += w
                }
            }
        }

        // Precompute special indices for nearest-special fallback
        let specialIdxs = units.indices.filter { units[$0].isSpecial }
        // Finalize tints
        for i in units.indices {
            if units[i].isSpecial {
                tintedRGB[i] = baseRGB[i]
            } else {
                let w = wsum[i]
                if w > 0 {
                    var rgb = acc[i] / SIMD3<Double>(repeating: w) // weighted mean
                    // lighten toward white so influenced units are a lighter version
                    rgb = rgb * 0.65 + SIMD3<Double>(repeating: 0.35)
                    tintedRGB[i] = rgb
                } else {
                    // Nearest-special fallback to avoid dull neutrals when just outside radius
                    var best = -1
                    var bestD2 = Double.greatestFiniteMagnitude
                    let p = units[i].pos
                    for sIdx in specialIdxs {
                        let sp = units[sIdx].pos
                        let dx = sp.x - p.x
                        let dy = sp.y - p.y
                        let d2 = dx*dx + dy*dy
                        if d2 < bestD2 { bestD2 = d2; best = sIdx }
                    }
                    if best >= 0 {
                        var rgb = baseRGB[best]
                        rgb = rgb * 0.65 + SIMD3<Double>(repeating: 0.35)
                        tintedRGB[i] = rgb
                    } else {
                        tintedRGB[i] = neutralRGB
                    }
                }
            }
        }

        baseTintedRGBCopy = tintedRGB
    }

    /// Convenience to run both steps safely from the UI tick
    func stepAndTint(dt: Double) {
        step(dt: dt)
        computeInfluenceColors()
    }

    /// Update rotating raycasts for specials, compute per-frame ray visuals and color overrides.
    func updateRays(dt: Double) {
        ensureBuffers()

        // Reset to baseline colors and clear visuals
        tintedRGB = baseTintedRGBCopy
        rays.removeAll(keepingCapacity: true)
        rays.reserveCapacity(specialCount * max(0, raysPerSpecial))

        guard raysPerSpecial > 0 else { return }

        // Parameters: ray length extends outside influence radius
        let rayLen = influenceRadius * 20.8
        let twoPi = 2.0 * Double.pi
        let angularSpeed = 0.1// 0.8 // rad/s

        var rayIDCounter = 0

        for s in units where s.isSpecial {
            let sid = s.id
            // Advance phase
            rayPhase[sid] = fmod(rayPhase[sid] + angularSpeed * dt, twoPi)

            for k in 0..<raysPerSpecial {
                let angle = rayPhase[sid] + twoPi * (Double(k) / Double(raysPerSpecial))
                let dir = Vec2(cos(angle), sin(angle))
                let a = s.pos
                let b = a + dir * rayLen

                // Collect candidates along the segment via grid DDA
                scratchIDs.removeAll(keepingCapacity: true)
                scratchSeen.removeAll(keepingCapacity: true)
                grid.raycast(from: a, to: b, into: &scratchIDs, scratch: &scratchSeen)

                // Narrow-phase: find closest circle hit (non-special targets only)
                var bestT = Double.infinity
                var bestID: Int = -1
                for id in scratchIDs {
                    if id == sid { continue }
                    let u = units[id]
                    if u.isSpecial { continue } // do not recolor specials
                    if let t = intersectSegmentCircle(a: a, b: b, center: u.pos, radius: u.radius), t < bestT {
                        bestT = t
                        bestID = id
                    }
                }

                let hitPoint: Vec2
                if bestID >= 0 {
                    hitPoint = a + (b - a) * bestT
                    // Override target color to match special's base color
                    tintedRGB[bestID] = baseRGB[sid]
                } else {
                    hitPoint = b
                }

                rays.append(RayViz(id: rayIDCounter, a: a, b: hitPoint, color: baseRGB[sid]))
                rayIDCounter &+= 1
            }
        }
    }

    /// Segment-circle intersection. Returns parametric t in [0,1] for the first hit, or nil if no hit.
    private func intersectSegmentCircle(a: Vec2, b: Vec2, center c: Vec2, radius r: Double) -> Double? {
        let d = b - a
        let f = a - c
        let A = d.x*d.x + d.y*d.y
        let B = 2.0 * (f.x*d.x + f.y*d.y)
        let C = (f.x*f.x + f.y*f.y) - r*r
        let disc = B*B - 4*A*C
        if disc < 0 { return nil }
        let sqrtDisc = sqrt(disc)
        let inv2A = 0.5 / A
        let t1 = (-B - sqrtDisc) * inv2A
        if t1 >= 0.0 && t1 <= 1.0 { return t1 }
        let t2 = (-B + sqrtDisc) * inv2A
        if t2 >= 0.0 && t2 <= 1.0 { return t2 }
        return nil
    }
}

// MARK: - View

public struct SpatialHashGridDemoView: View {
    @Environment(\.displayScale) private var displayScale
    
    @StateObject private var model = SpatialHashDemoModel()
    @StateObject private var driver = DisplayLinkDriver()
    @State private var lastTick = CACurrentMediaTime()
    @State private var fpsEMA: Double = 60.0
    @State private var hudText: String = ""
    @State private var qualityLevel: Int = 0 // 0=high, 1=medium, 2=low
//    Removed: @State private var colorKeys: [UInt8] = [] // per-unit bucket key for non-specials

    @State private var gridPathCache: Path = Path()
    @State private var gridCacheSize: CGSize = .zero
    @State private var gridCacheCell: Double = 0
    @State private var gridImageCache: CGImage?

    @State private var normalCirclePath: CGPath = CGMutablePath()
    @State private var specialCirclePath: CGPath = CGMutablePath()

    @State private var nonspecialsImageCache: CGImage?
    @State private var isBuildingNonSpecialsImage: Bool = false

    @State private var lastFrameCount: Int = 0
    @State private var lastNonSpecialsImageBuildFrame: Int = 0

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            VStack(spacing: 8) {
                Text(hudText)
                    .font(.footnote.monospaced())
                    .padding(.top, 8)

                HStack {
                    Text("Rays/special: \(model.raysPerSpecial)")
                        .font(.footnote.monospaced())
                    Spacer()
                    Stepper("", value: $model.raysPerSpecial, in: 0...44)
                        .labelsHidden()
                }
                .padding(.horizontal, 12)

                Canvas { ctx, size in
                    if qualityLevel < 2 {
                        if let img = gridImageCache {
                            ctx.withCGContext { cg in
                                cg.interpolationQuality = .none
                                cg.draw(img, in: CGRect(origin: .zero, size: size))
                            }
                        } else {
                            ctx.stroke(gridPathCache, with: .color(Color.black.opacity(0.06)), lineWidth: 0.25)
                        }
                    }

                    ctx.withCGContext { cg in
                        cg.setAllowsAntialiasing(false)
                        cg.setShouldAntialias(false)

//                        let levels = (qualityLevel == 0 ? 4 : (qualityLevel == 1 ? 3 : 2))
                        //let bucketCount = levels * levels * levels
//                        Removed line:
//                        if colorKeys.count != model.units.count { colorKeys = Array(repeating: 0, count: model.units.count) }

                        // Draw specials individually (few items)
                        if model.specialCount > 0 {
                            for u in model.units where u.isSpecial {
                                let rgb = model.tintedRGB[u.id]
                                cg.setFillColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
                                cg.saveGState()
                                cg.translateBy(x: CGFloat(u.pos.x - u.radius), y: CGFloat(u.pos.y - u.radius))
                                cg.addPath(specialCirclePath)
                                cg.fillPath()
                                cg.restoreGState()
                            }
                        }

                        // Replaced the precompute + bucket emission with local bucketed paths:
                        // Draw non-specials via local bucketed paths unless a cached image is available
                        if nonspecialsImageCache == nil {
                            for u in model.units where !u.isSpecial {
                                let rgb = model.tintedRGB[u.id]
                                cg.setFillColor(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
                                cg.saveGState()
                                cg.translateBy(x: CGFloat(u.pos.x - u.radius), y: CGFloat(u.pos.y - u.radius))
                                cg.addPath(normalCirclePath)
                                cg.fillPath()
                                cg.restoreGState()
                            }
                        }
                    }

                    // Draw cached non-specials image if available
                    if let img = nonspecialsImageCache {
                        ctx.withCGContext { cg in
                            cg.interpolationQuality = .none
                            cg.draw(img, in: CGRect(origin: .zero, size: size))
                        }
                    }

                    // Draw rays (on top)
                    if model.raysPerSpecial > 0 {
                        ctx.withCGContext { cg in
                            cg.setAllowsAntialiasing(true)
                            cg.setShouldAntialias(true)
                            cg.setLineWidth(1.0)
                            for rv in model.rays {
                                cg.setStrokeColor(red: CGFloat(rv.color.x), green: CGFloat(rv.color.y), blue: CGFloat(rv.color.z), alpha: 0.9)
                                cg.move(to: CGPoint(x: rv.a.x, y: rv.a.y))
                                cg.addLine(to: CGPoint(x: rv.b.x, y: rv.b.y))
                                cg.strokePath()
                            }
                        }
                    }
                }
//                .drawingGroup() // let Metal composite; smoother on many devices  <-- removed as per instructions
                .onAppear {
                    model.setWorldSize(geo.size) // match visible area
                    rebuildGridPath(size: geo.size, cell: model.grid.cellSize)
                    rebuildGridImage(size: geo.size, cell: model.grid.cellSize)
                    rebuildCirclePaths()
                    hudText = buildHUDText()
                    driver.start()
                    scheduleNonSpecialsImageRebuild(size: geo.size)
                }
                .onDisappear { driver.stop() }
                .onChange(of: geo.size) { _, newSize in
                    model.setWorldSize(newSize)
                    rebuildGridPath(size: newSize, cell: model.grid.cellSize)
                    rebuildGridImage(size: newSize, cell: model.grid.cellSize)
                    scheduleNonSpecialsImageRebuild(size: newSize)
                }
                .onReceive(driver.$timestamp) { t in
                    let dt = min(0.050, t - lastTick)
                    lastTick = t

                    // Update FPS EMA
                    let instFPS = 1.0 / max(1e-4, dt)
                    fpsEMA = fpsEMA * 0.9 + instFPS * 0.1

                    // Adaptive quality with wider hysteresis to reduce oscillation
                    var newQuality = qualityLevel
                    if fpsEMA < 55.0 { newQuality = 2 }        // drop to low if we dip under 55
                    else if fpsEMA < 58.5 { newQuality = 1 }  // medium band
                    else if fpsEMA > 59.7 { newQuality = 0 }  // only go back to high near perfect 60
                    if newQuality != qualityLevel { qualityLevel = newQuality }

                    // Simulation step
                    model.step(dt: dt)

                    // Rays update and color overrides (every frame)
                    model.updateRays(dt: dt)

                    // Adaptive tint cadence (less frequent on lower quality)
                    let tintStride = (qualityLevel == 0 ? 3 : (qualityLevel == 1 ? 4 : 5))
                    let willRecomputeTint = (model.frameCount % tintStride) == 0
                    if willRecomputeTint { model.computeInfluenceColors() }

                    // Rebuild non-specials image at most every N frames (throttle), and only when positions or colors changed
                    let minFramesBetweenRebuilds = (qualityLevel == 0 ? 3 : (qualityLevel == 1 ? 4 : 6))
                    let framesSinceBuild = model.frameCount &- lastNonSpecialsImageBuildFrame
                    let movedNonSpecials = (lastFrameCount % 3) == 0 // non-specials move every 3rd frame in step()
                    if (movedNonSpecials || willRecomputeTint) && framesSinceBuild >= minFramesBetweenRebuilds {
                        scheduleNonSpecialsImageRebuild(size: geo.size)
                    }

                    // HUD update (cheaper, less frequent)
                    if (model.frameCount % 12) == 0 { hudText = buildHUDText() }

                    // Track last frame
                    lastFrameCount = model.frameCount
                }
                .frame(width: geo.size.width, height: geo.size.height * 0.9) // fill most of the space
                .background(.black.opacity(0.02))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.black.opacity(0.08)))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }

    private func rebuildGridPath(size: CGSize, cell: Double) {
        // Rebuild only when inputs change
        if gridCacheSize == size && gridCacheCell == cell { return }
        gridCacheSize = size
        gridCacheCell = cell

        var path = Path()
        guard cell > 2 else { gridPathCache = path; return }
        let cols = Int(size.width / cell)
        let rows = Int(size.height / cell)
        for c in 0...cols {
            let x = Double(c) * cell
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        for r in 0...rows {
            let y = Double(r) * cell
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        gridPathCache = path
    }

    private func rebuildGridImage(size: CGSize, cell: Double) {
        // Rebuild only when inputs change; image cache depends on same keys as path
        if gridCacheSize == size && gridCacheCell == cell && gridImageCache != nil { return }
        gridCacheSize = size
        gridCacheCell = cell

        guard cell > 2, size.width > 1, size.height > 1 else {
            gridImageCache = nil
            return
        }

        let scale = currentImageScale()
        let width = max(1, Int(size.width * scale))
        let height = max(1, Int(size.height * scale))

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            gridImageCache = nil
            return
        }

        // Draw grid lines in pixel space for crispness
        ctx.setAllowsAntialiasing(false)
        ctx.setShouldAntialias(false)
        ctx.setStrokeColor(CGColor(gray: 0.0, alpha: 0.06))
        ctx.setLineWidth(0.25 * scale) // 0.25pt equivalent

        let cols = Int(size.width / cell)
        let rows = Int(size.height / cell)
        let cellPx = CGFloat(cell) * scale

        for c in 0...cols {
            let x = CGFloat(c) * cellPx
            ctx.move(to: CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: CGFloat(height)))
        }
        for r in 0...rows {
            let y = CGFloat(r) * cellPx
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: CGFloat(width), y: y))
        }
        ctx.strokePath()

        gridImageCache = ctx.makeImage()
    }

    private func rebuildCirclePaths() {
        // Determine radii from current model (fallbacks match defaults)
        let normalRadius = model.units.first(where: { !$0.isSpecial })?.radius ?? 3.0
        let specialRadius = model.units.first(where: { $0.isSpecial })?.radius ?? 5.0

        // Build paths at origin; we translate per unit at draw time
        let normalRect = CGRect(x: 0, y: 0, width: normalRadius * 2.0, height: normalRadius * 2.0)
        let specialRect = CGRect(x: 0, y: 0, width: specialRadius * 2.0, height: specialRadius * 2.0)

        if let p1 = CGPath(ellipseIn: normalRect, transform: nil).copy() {
            normalCirclePath = p1
        }
        if let p2 = CGPath(ellipseIn: specialRect.insetBy(dx: -0.5, dy: -0.5), transform: nil).copy() {
            specialCirclePath = p2
        }
    }

    private func buildHUDText() -> String {
        String(
            format: "Spatial Hash Grid Demo • %d units • %d specials • frame %d • %.1f FPS",
            model.units.count, model.specialCount, model.frameCount, fpsEMA
        )
    }

    private func currentImageScale() -> CGFloat {
        let native = displayScale
        switch qualityLevel {
        case 0: return native
        case 1: return max(1.0, min(native, 2.0))
        default: return 1.0
        }
    }

    private func scheduleNonSpecialsImageRebuild(size: CGSize) {
        guard size.width > 1, size.height > 1 else { nonspecialsImageCache = nil; return }
        if isBuildingNonSpecialsImage { return }
        isBuildingNonSpecialsImage = true

        // Snapshot data on main thread
        let scale = displayScale

        struct NSItem { let x: Double; let y: Double; let r: Double; let rgb: SIMD3<Double> }
        var items: [NSItem] = []
        items.reserveCapacity(model.units.count - model.specialCount)
        for u in model.units where !u.isSpecial {
            let c = model.tintedRGB[u.id]
            items.append(NSItem(x: u.pos.x, y: u.pos.y, r: u.radius, rgb: c))
        }
        let pathNormal = normalCirclePath // immutable CGPath is thread-safe to share

        let targetSize = size

        // Build off the main thread
        Task.detached(priority: .utility) {
            let width = max(1, Int(targetSize.width * scale))
            let height = max(1, Int(targetSize.height * scale))

            guard let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                await MainActor.run { isBuildingNonSpecialsImage = false }
                return
            }

            ctx.setAllowsAntialiasing(false)
            ctx.setShouldAntialias(false)

            // Scale context so 1pt maps to `scale` pixels; our geometry uses point coordinates
            ctx.scaleBy(x: scale, y: scale)

            // High-quality rendering: draw each non-special with its true color
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)

            for it in items {
                ctx.setFillColor(red: CGFloat(it.rgb.x), green: CGFloat(it.rgb.y), blue: CGFloat(it.rgb.z), alpha: 1)
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(it.x - it.r), y: CGFloat(it.y - it.r))
                ctx.addPath(pathNormal)
                ctx.fillPath()
                ctx.restoreGState()
            }

            let image = ctx.makeImage()
            await MainActor.run {
                nonspecialsImageCache = image
                lastNonSpecialsImageBuildFrame = model.frameCount
                isBuildingNonSpecialsImage = false
            }
        }
    }
}

// MARK: - Helpers

@inline(__always) private func hslToRgb(_ h: Double, _ s: Double, _ l: Double) -> SIMD3<Double> {
    if s == 0 { return SIMD3<Double>(repeating: l) }
    let q = l < 0.5 ? l * (1 + s) : l + s - l * s
    let p = 2 * l - q
    let r = hue2rgb(p, q, h + 1/3)
    let g = hue2rgb(p, q, h)
    let b = hue2rgb(p, q, h - 1/3)
    return SIMD3(r, g, b)
}

@inline(__always) private func hue2rgb(_ p: Double, _ q: Double, _ tIn: Double) -> Double {
    var t = tIn
    if t < 0 { t += 1 }
    if t > 1 { t -= 1 }
    if t < 1/6 { return p + (q - p) * 6 * t }
    if t < 1/2 { return q }
    if t < 2/3 { return p + (q - p) * (2/3 - t) * 6 }
    return p
}

extension Vec2 {
    static func random(in xr: ClosedRange<Double>, _ yr: ClosedRange<Double>, using rng: inout some RandomNumberGenerator) -> Vec2 {
        .init(Double.random(in: xr, using: &rng), Double.random(in: yr, using: &rng))
    }
    static func * (lhs: Vec2, rhs: Double) -> Vec2 { .init(lhs.x * rhs, lhs.y * rhs) }
    static func *= (lhs: inout Vec2, rhs: Double) { lhs = lhs * rhs }
    static func / (lhs: Vec2, rhs: Double) -> Vec2 { .init(lhs.x / rhs, lhs.y / rhs) }
    static func + (lhs: Vec2, rhs: Vec2) -> Vec2 { .init(lhs.x + rhs.x, lhs.y + rhs.y) }
    static func - (lhs: Vec2, rhs: Vec2) -> Vec2 { .init(lhs.x - rhs.x, lhs.y - rhs.y) }
}
