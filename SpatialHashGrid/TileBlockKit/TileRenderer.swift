// File: TileBlockKit/TileRenderer.swift
import Foundation
import SwiftUI
import Metal
import MetalKit
import os.log
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

final class TileRenderer: NSObject, MTKViewDelegate {
    var config = TileBlockConfig() {
        didSet {
            if config.filterMode != oldValue.filterMode {
                buildSampler()
            }
            buildInstances()
        }
    }
    var atlases: [TileAtlas] = [] { didSet { buildInstances() } }
    var selectedAtlasIndex: Int = 0 { didSet { buildInstances() } }

    let device: MTLDevice
    private weak var view: MTKView?
    private let queue: MTLCommandQueue
    private let library: MTLLibrary
    private var pso: MTLRenderPipelineState!
    private var sampler: MTLSamplerState!
    private var quad: MTLBuffer!
    private var instBuf: MTLBuffer?
    private var uniBuf: MTLBuffer!

    private var instances: [TileInstance] = []
    private var instanceCapacity = 0
    private(set) var pixelScale: CGFloat = 1
    var pixelScaleDidChange: ((CGFloat) -> Void)?
    var tilePadding: Float = 6
    private let diagnostics = TileBlockDiagnostics.shared
    private var pendingFrameCapture: ((URL?) -> Void)?
    private var pendingCaptureTexture: MTLTexture?

    enum Mode { case gridAllTiles, previewBlocks }
    var mode: Mode = .gridAllTiles { didSet { buildInstances() } }
    #if canImport(UIKit)
    var contentInsets = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    #else
    var contentInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    #endif
    var exportScale: CGFloat = 1.0

    private var lastDrawableSize: CGSize = .zero

    init(view: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal not available") }
        self.device = device
        self.queue = device.makeCommandQueue()!
        #if SWIFT_PACKAGE
        self.library = try! device.makeDefaultLibrary(bundle: .module)
        #else
        self.library = (try? device.makeDefaultLibrary(bundle: .main)) ?? (device.makeDefaultLibrary()!)
        #endif
        self.view = view
        super.init()
        view.device = device
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColorMake(0.12, 0.12, 0.14, 1)
        view.framebufferOnly = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        PlatformDisplayUtilities.configureFrameRate(for: view, preferredFramesPerSecond: 60)
        view.delegate = self
        buildPipeline(); buildQuad(); buildUniforms(); buildSampler()
        setNeedsDisplay()
    }

    func buildPipeline() {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "tileVertex")
        desc.fragmentFunction = library.makeFunction(name: "tileFragment")
        desc.colorAttachments[0].pixelFormat = view?.colorPixelFormat ?? .bgra8Unorm_srgb
        pso = try! device.makeRenderPipelineState(descriptor: desc)
    }
    func buildSampler() {
        let sd = MTLSamplerDescriptor()
        switch config.filterMode {
        case .linear:
            sd.minFilter = .linear; sd.magFilter = .linear
        case .nearest:
            sd.minFilter = .nearest; sd.magFilter = .nearest
        }
        sd.mipFilter = .notMipmapped
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: sd)
    }
    func buildQuad() {
        struct V { var pos: SIMD2<Float>; var uv: SIMD2<Float> }
        let verts: [V] = [
            .init(pos: [0,0], uv: [0,0]), .init(pos: [1,0], uv: [1,0]), .init(pos: [0,1], uv: [0,1]),
            .init(pos: [1,0], uv: [1,0]), .init(pos: [1,1], uv: [1,1]), .init(pos: [0,1], uv: [0,1]),
        ]
        quad = device.makeBuffer(bytes: verts, length: MemoryLayout<V>.stride * verts.count)
    }
    func buildUniforms() { uniBuf = device.makeBuffer(length: MemoryLayout<Uniforms>.stride, options: [.storageModeShared]) }

    private func makeInstance(at origin: SIMD2<Float>, size: SIMD2<Float>, uv: CGRect,
                              tint: SIMD4<Float>, effectMask: UInt32, shape: BlockShapeKind) -> TileInstance {
        TileInstance(originPx: origin,
                     sizePx: size,
                     uvRect: .init(Float(uv.origin.x), Float(uv.origin.y), Float(uv.size.width), Float(uv.size.height)),
                     tint: tint, effectMask: effectMask, shapeKind: shape.rawValue)
    }

    private func updatePixelScaleIfNeeded() {
        guard let view else { return }
        let bounds = view.bounds.size
        guard bounds.width > 0.0, bounds.height > 0.0 else { return }
        let drawable = view.drawableSize
        let widthScale = bounds.width > 0.0 ? drawable.width / bounds.width : 0.0
        let heightScale = bounds.height > 0.0 ? drawable.height / bounds.height : 0.0
        let inferred = max(1.0, [widthScale, heightScale].filter { $0.isFinite && $0 > 0.0 }.max() ?? 1.0)
        if abs(inferred - pixelScale) > 0.001 {
            pixelScale = inferred
            if let callback = pixelScaleDidChange {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    callback(self.pixelScale)
                }
            }
        }
    }

    private func buildInstances() {
        updatePixelScaleIfNeeded()
        guard let atlas = atlases[safe: selectedAtlasIndex] else {
            diagnostics.log("buildInstances aborted: no atlas at index \(selectedAtlasIndex)")
            instances = []
            instBuf = nil
            return
        }
        let tileW = Float(config.tileSize.width) * Float(config.displayScale)
        let tileH = Float(config.tileSize.height) * Float(config.displayScale)
        let scale = Float(max(pixelScale, 0.0001))
        let pad: Float = tilePadding * scale
        let left = Float(contentInsets.left) * scale
        let top = Float(contentInsets.top) * scale
        let cols = max(1, atlas.columns)
        diagnostics.log("buildInstances: mode=\(mode) tiles=\(atlas.tiles.count) tilePx=\(tileW)x\(tileH) columns=\(cols)")

        var inst: [TileInstance] = []
        var x = left
        var y = top
        var columnIndex = 0
        for t in atlas.tiles {
            let uv = t.uvRect
            if diagnostics.isEnabled && inst.isEmpty {
                diagnostics.log("First tile uvRect=\(uv.origin.x),\(uv.origin.y) size=\(uv.size.width)x\(uv.size.height)")
            }
            let effectMask: UInt32
            switch mode {
            case .gridAllTiles:
                effectMask = config.hazardStripes ? 0x1 : 0x0
            case .previewBlocks:
                effectMask = config.hazardStripes ? 0x1 | 0x2 : 0x2
            }
            inst.append(makeInstance(at: [x,y], size: [tileW,tileH], uv: uv,
                                     tint: [1,1,1,1],
                                     effectMask: effectMask,
                                     shape: config.shape))
            columnIndex += 1
            if columnIndex >= cols {
                columnIndex = 0
                x = left
                y += tileH + pad
            } else {
                x += tileW + pad
            }
        }
        instances = inst
        ensureInstanceBufferCapacity(inst.count)
        if let ib = instBuf, !inst.isEmpty {
            let ptr = ib.contents().bindMemory(to: TileInstance.self, capacity: inst.count)
            for i in 0..<inst.count { ptr[i] = inst[i] }
        }
        setNeedsDisplay()
        diagnostics.log("buildInstances complete: instanceCount=\(instances.count) bufferCapacity=\(instanceCapacity)")
    }

    private func ensureInstanceBufferCapacity(_ count: Int) {
        if count == 0 {
            instanceCapacity = 0
            instBuf = nil
            return
        }
        if count > instanceCapacity || instBuf == nil {
            instanceCapacity = max(count, max(instanceCapacity * 2 + 64, 64))
            instBuf = device.makeBuffer(length: MemoryLayout<TileInstance>.stride * instanceCapacity, options: [.storageModeShared])
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lastDrawableSize = size; buildInstances()
        diagnostics.log("drawableSizeWillChange -> \(size)")
    }

    func draw(in view: MTKView) {
        if lastDrawableSize != view.drawableSize {
            lastDrawableSize = view.drawableSize
            buildInstances()
        }

        guard let drawable = view.currentDrawable, let rpd = view.currentRenderPassDescriptor else {
            diagnostics.log("draw skipped: missing drawable or render pass descriptor")
            return
        }
        if let ub = uniBuf {
            let u = ub.contents().bindMemory(to: Uniforms.self, capacity: 1)
            u.pointee.viewportSizePx = SIMD2(Float(lastDrawableSize.width), Float(lastDrawableSize.height))
            u.pointee.bevelWidth = config.bevelWidth
            u.pointee.cornerRadius = config.cornerRadius
            u.pointee.outlineWidth = config.outlineWidth
            u.pointee.outlineIntensity = config.outlineIntensity
            u.pointee.shadowSize = config.shadowSize
            u.pointee.tilePx = SIMD2(Float(config.tileSize.width) * Float(config.displayScale),
                                     Float(config.tileSize.height) * Float(config.displayScale))
            u.pointee.stripeAngle = config.stripeAngle
            u.pointee.stripeWidth = config.stripeWidth
            u.pointee.stripeA = config.stripeColorA
            u.pointee.stripeB = config.stripeColorB
            u.pointee.highlightMask = config.highlightEdges.rawValue
            u.pointee.shadowMask = config.shadowEdges.rawValue
            u.pointee.lightingMode = config.lightingMode.rawValue
            u.pointee.highlightIntensity = config.highlightIntensity
            u.pointee.shadowIntensity = config.shadowIntensity
            u.pointee.edgeFalloff = config.edgeFalloff
            u.pointee.hueShift = config.hueShiftDegrees * .pi / 180
            u.pointee.saturation = config.saturation
            u.pointee.brightness = config.brightness
            u.pointee.contrast = config.contrast
            u.pointee.highlightColor = SIMD4<Float>(config.highlightColor.x, config.highlightColor.y, config.highlightColor.z, 1.0)
            u.pointee.shadowColor = SIMD4<Float>(config.shadowColor.x, config.shadowColor.y, config.shadowColor.z, 1.0)
        }
        guard let cmd = queue.makeCommandBuffer() else {
            diagnostics.log("Failed to make command buffer; skipping draw")
            return
        }
        let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!
        enc.setRenderPipelineState(pso)
        enc.setVertexBuffer(quad, offset: 0, index: 0)
        enc.setVertexBuffer(uniBuf, offset: 0, index: 2)
        enc.setFragmentBuffer(uniBuf, offset: 0, index: 2)
        if let atlas = atlases[safe: selectedAtlasIndex] { enc.setFragmentTexture(atlas.texture, index: 0) }
        enc.setFragmentSamplerState(sampler, index: 0)
        if let instBuf = instBuf, !instances.isEmpty {
            enc.setVertexBuffer(instBuf, offset: 0, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
            diagnostics.log("draw issued: instanceCount=\(instances.count)")
        } else {
            enc.setVertexBuffer(nil, offset: 0, index: 1)
            diagnostics.log("draw skipped: no instances or buffer")
        }
        enc.endEncoding()

        if let captureCallback = pendingFrameCapture {
            pendingFrameCapture = nil
            let w = drawable.texture.width
            let h = drawable.texture.height
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: drawable.texture.pixelFormat, width: w, height: h, mipmapped: false)
            td.storageMode = .shared
            td.usage = [.shaderRead, .shaderWrite]
            if let captureTex = device.makeTexture(descriptor: td) {
                pendingCaptureTexture = captureTex
                if let blit = cmd.makeBlitCommandEncoder() {
                    blit.copy(from: drawable.texture,
                              sourceSlice: 0,
                              sourceLevel: 0,
                              sourceOrigin: .init(x: 0, y: 0, z: 0),
                              sourceSize: .init(width: w, height: h, depth: 1),
                              to: captureTex,
                              destinationSlice: 0,
                              destinationLevel: 0,
                              destinationOrigin: .init(x: 0, y: 0, z: 0))
                    blit.endEncoding()
                }
                cmd.addCompletedHandler { [weak self, weak captureTex] _ in
                    guard let self else { return }
                    var url: URL? = nil
                    if let capTex = captureTex, let image = capTex.toCGImage() {
                        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TileBlockPreview-\(UUID().uuidString).png")
                        do {
                            try image.writePNG(to: fileURL)
                            url = fileURL
                        } catch {
                            self.diagnostics.log("Failed to write capture: \(error.localizedDescription)")
                        }
                    }
                    self.pendingCaptureTexture = nil
                    DispatchQueue.main.async {
                        captureCallback(url)
                    }
                }
            } else {
                diagnostics.log("Failed to allocate capture texture")
                DispatchQueue.main.async { captureCallback(nil) }
            }
        }

        if pendingFrameCapture != nil {
            cmd.present(drawable)
            cmd.commit()
            cmd.waitUntilCompleted()
        } else {
            cmd.present(drawable)
            cmd.commit()
        }
    }


    private func renderPassDescriptor(for texture: MTLTexture) -> MTLRenderPassDescriptor {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = texture
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        return rpd
    }

    func setNeedsDisplay() {
        guard let view else { return }
        #if canImport(UIKit)
        view.setNeedsDisplay()
        view.draw()
        #elseif canImport(AppKit)
        view.setNeedsDisplay(view.bounds)
        view.displayIfNeeded()
        #endif
    }

    func forceRedraw() {
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsDisplay()
        }
    }

    func captureFrame(completion: @escaping (URL?) -> Void) {
        pendingFrameCapture = completion
        setNeedsDisplay()
    }

    func renderTileImage(at index: Int) -> CGImage? {
        guard let atlas = atlases[safe: selectedAtlasIndex], atlas.tiles.indices.contains(index) else { return nil }
        let tileW = max(1, Int(config.tileSize.width * config.displayScale))
        let tileH = max(1, Int(config.tileSize.height * config.displayScale))
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: view?.colorPixelFormat ?? .bgra8Unorm_srgb, width: tileW, height: tileH, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead, .shaderWrite]
        td.storageMode = .shared
        guard let target = device.makeTexture(descriptor: td) else { return nil }

        let tile = atlas.tiles[index]
        let uv = tile.uvRect
        let single = TileInstance(originPx: .init(0,0), sizePx: .init(Float(tileW), Float(tileH)),
                                  uvRect: .init(Float(uv.origin.x), Float(uv.origin.y), Float(uv.size.width), Float(uv.size.height)),
                                  tint: .init(1,1,1,1),
                                  effectMask: config.hazardStripes ? ((mode == .previewBlocks) ? 0x1 | 0x2 : 0x1) : ((mode == .previewBlocks) ? 0x2 : 0),
                                  shapeKind: config.shape.rawValue)
        guard let instBuf = device.makeBuffer(bytes: [single], length: MemoryLayout<TileInstance>.stride),
              let u = device.makeBuffer(length: MemoryLayout<Uniforms>.stride) else { return nil }

        let up = u.contents().bindMemory(to: Uniforms.self, capacity: 1)
        up.pointee.viewportSizePx = SIMD2(Float(tileW), Float(tileH))
        up.pointee.bevelWidth = config.bevelWidth
        up.pointee.cornerRadius = config.cornerRadius
        up.pointee.outlineWidth = config.outlineWidth
        up.pointee.outlineIntensity = config.outlineIntensity
        up.pointee.shadowSize = config.shadowSize
        up.pointee.tilePx = SIMD2(Float(tileW), Float(tileH))
        up.pointee.stripeAngle = config.stripeAngle
        up.pointee.stripeWidth = config.stripeWidth
        up.pointee.stripeA = config.stripeColorA
        up.pointee.stripeB = config.stripeColorB
        up.pointee.highlightMask = config.highlightEdges.rawValue
        up.pointee.shadowMask = config.shadowEdges.rawValue
        up.pointee.lightingMode = config.lightingMode.rawValue
        up.pointee.highlightIntensity = config.highlightIntensity
        up.pointee.shadowIntensity = config.shadowIntensity
        up.pointee.edgeFalloff = config.edgeFalloff
        up.pointee.hueShift = config.hueShiftDegrees * .pi / 180
        up.pointee.saturation = config.saturation
        up.pointee.brightness = config.brightness
        up.pointee.contrast = config.contrast
        up.pointee.highlightColor = SIMD4<Float>(config.highlightColor.x, config.highlightColor.y, config.highlightColor.z, 1.0)
        up.pointee.shadowColor = SIMD4<Float>(config.shadowColor.x, config.shadowColor.y, config.shadowColor.z, 1.0)

        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: renderPassDescriptor(for: target)) else { return nil }

        enc.setRenderPipelineState(pso)
        enc.setVertexBuffer(quad, offset: 0, index: 0)
        enc.setVertexBuffer(instBuf, offset: 0, index: 1)
        enc.setVertexBuffer(u, offset: 0, index: 2)
        enc.setFragmentBuffer(u, offset: 0, index: 2)
        enc.setFragmentTexture(atlas.texture, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return target.toCGImage()
    }

    func exportProcessedPNGs() throws -> URL {
        guard let atlas = atlases[safe: selectedAtlasIndex] else {
            throw NSError(domain: "TileRenderer", code: -1, userInfo: [NSLocalizedDescriptionKey: "No atlas"])
        }
        let tileW = Int(config.tileSize.width * exportScale)
        let tileH = Int(config.tileSize.height * exportScale)
        let dir = try FileManager.default.urlForNewExportFolder()
        diagnostics.log("Exporting \(atlas.tiles.count) tiles at \(tileW)x\(tileH) px to \(dir.path)")
        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: tileW, height: tileH, mipmapped: false)
        td.usage = [.renderTarget, .shaderRead, .shaderWrite]
        td.storageMode = .shared
        for (i, t) in atlas.tiles.enumerated() {
            guard let target = device.makeTexture(descriptor: td) else { continue }
            let uv = t.uvRect
            let single = TileInstance(originPx: .init(0,0), sizePx: .init(Float(tileW), Float(tileH)),
                                      uvRect: .init(Float(uv.origin.x), Float(uv.origin.y), Float(uv.size.width), Float(uv.size.height)),
                                      tint: .init(1,1,1,1),
                                      effectMask: config.hazardStripes ? 0x1 : 0,
                                      shapeKind: config.shape.rawValue)
            let instBuf = device.makeBuffer(bytes: [single], length: MemoryLayout<TileInstance>.stride)!
            let u = device.makeBuffer(length: MemoryLayout<Uniforms>.stride)!
            let up = u.contents().bindMemory(to: Uniforms.self, capacity: 1)
            up.pointee.viewportSizePx = SIMD2(Float(tileW), Float(tileH))
            up.pointee.bevelWidth = config.bevelWidth
            up.pointee.cornerRadius = config.cornerRadius
            up.pointee.outlineWidth = config.outlineWidth
            up.pointee.outlineIntensity = config.outlineIntensity
            up.pointee.shadowSize = 0.0
            up.pointee.tilePx = SIMD2(Float(tileW), Float(tileH))
            up.pointee.stripeAngle = config.stripeAngle
            up.pointee.stripeWidth = config.stripeWidth
            up.pointee.stripeA = config.stripeColorA
            up.pointee.stripeB = config.stripeColorB
            up.pointee.highlightMask = config.highlightEdges.rawValue
            up.pointee.shadowMask = config.shadowEdges.rawValue
            up.pointee.lightingMode = config.lightingMode.rawValue
            up.pointee.highlightIntensity = config.highlightIntensity
            up.pointee.shadowIntensity = config.shadowIntensity
            up.pointee.edgeFalloff = config.edgeFalloff
            up.pointee.hueShift = config.hueShiftDegrees * .pi / 180
            up.pointee.saturation = config.saturation
            up.pointee.brightness = config.brightness
            up.pointee.contrast = config.contrast
            up.pointee.highlightColor = SIMD4<Float>(config.highlightColor.x, config.highlightColor.y, config.highlightColor.z, 1.0)
            up.pointee.shadowColor = SIMD4<Float>(config.shadowColor.x, config.shadowColor.y, config.shadowColor.z, 1.0)

            let cmd = queue.makeCommandBuffer()!
            let enc = cmd.makeRenderCommandEncoder(descriptor: renderPassDescriptor(for: target))!
            enc.setRenderPipelineState(pso)
            enc.setVertexBuffer(quad, offset: 0, index: 0)
            enc.setVertexBuffer(instBuf, offset: 0, index: 1)
            enc.setVertexBuffer(u, offset: 0, index: 2)
            enc.setFragmentBuffer(u, offset: 0, index: 2)
            enc.setFragmentTexture(atlas.texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            enc.endEncoding()
            cmd.commit(); cmd.waitUntilCompleted()
            if let img = target.toCGImage() {
                let url = dir.appendingPathComponent(String(format:"tile_%04d.png", i))
                try img.writePNG(to: url)
            }
        }
        let zipURL = try FileManager.default.zipContents(ofDirectory: dir)
        diagnostics.log("Export complete: \(zipURL.path)")
        return zipURL
    }
}

struct TileInstance {
    var originPx: SIMD2<Float>
    var sizePx: SIMD2<Float>
    var uvRect: SIMD4<Float>
    var tint: SIMD4<Float>
    var effectMask: UInt32
    var shapeKind: UInt32
}
struct Uniforms {
    var viewportSizePx: SIMD2<Float> = .zero
    var bevelWidth: Float = 0
    var cornerRadius: Float = 0
    var outlineWidth: Float = 0
    var outlineIntensity: Float = 0
    var shadowSize: Float = 0
    var tilePx: SIMD2<Float> = .zero
    var pad0: SIMD2<Float> = .zero
    var stripeAngle: Float = 0
    var stripeWidth: Float = 0
    var stripeA: SIMD4<Float> = .zero
    var stripeB: SIMD4<Float> = .zero
    var highlightMask: UInt32 = 0
    var shadowMask: UInt32 = 0
    var lightingMode: UInt32 = 0
    var padLighting: UInt32 = 0
    var highlightIntensity: Float = 0
    var shadowIntensity: Float = 0
    var edgeFalloff: Float = 0
    var hueShift: Float = 0
    var saturation: Float = 1
    var brightness: Float = 0
    var contrast: Float = 1
    var highlightColor: SIMD4<Float> = .init(repeating: 0)
    var shadowColor: SIMD4<Float> = .init(repeating: 0)
}
extension Array {
    subscript(safe idx: Int) -> Element? { indices.contains(idx) ? self[idx] : nil }
}
import UniformTypeIdentifiers
extension CGImage {
    func writePNG(to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw NSError(domain: "PNG", code: -1, userInfo: [NSLocalizedDescriptionKey: "CGImageDestination nil"])
        }
        CGImageDestinationAddImage(dest, self, nil); CGImageDestinationFinalize(dest)
    }
}
extension FileManager {
    func urlForNewExportFolder() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BlockExport-\(UUID().uuidString)")
        try createDirectory(at: dir, withIntermediateDirectories: true); return dir
    }
    func zipContents(ofDirectory dir: URL) throws -> URL {
        let zip = dir.appendingPathExtension("zip")
        #if os(macOS)
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.currentDirectoryURL = dir.deletingLastPathComponent()
        task.arguments = ["-r", zip.lastPathComponent, dir.lastPathComponent]
        try task.run(); task.waitUntilExit()
        #endif
        return zip
    }
}
