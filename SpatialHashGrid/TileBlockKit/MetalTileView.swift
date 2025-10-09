// File: TileBlockKit/MetalTileView.swift
import SwiftUI
import Metal
import MetalKit
import UniformTypeIdentifiers
import Combine
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Cross‑platform SwiftUI representable
#if canImport(UIKit)
struct MetalTileView: UIViewRepresentable {
    typealias UIViewType = MTKView
    @ObservedObject var vm: TileBlockViewModel
    func makeUIView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero)
        let renderer = TileRenderer(view: v)
        vm.attachRenderer(renderer)
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        v.preferredFramesPerSecond = 60
        return v
    }
    func updateUIView(_ uiView: MTKView, context: Context) { vm.applyConfig() }
    func makeCoordinator() -> Coord { Coord(vm: vm) }
    final class Coord: NSObject {
        var vm: TileBlockViewModel
        init(vm: TileBlockViewModel) { self.vm = vm }
    }
}
#elseif os(macOS)
import AppKit
import MetalKit
import SwiftUI

struct MetalTileView: NSViewRepresentable {
    typealias NSViewType = MTKView
    @ObservedObject var vm: TileBlockViewModel

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero)
        let renderer = TileRenderer(view: v)
        vm.attachRenderer(renderer)
        v.enableSetNeedsDisplay = true
        v.isPaused = true
        v.preferredFramesPerSecond = 60
        return v
    }

    func updateNSView(_ nsView: MTKView, context: Context) { vm.applyConfig() }
    func makeCoordinator() -> Coord { Coord(vm: vm) }
    final class Coord: NSObject {
        var vm: TileBlockViewModel
        init(vm: TileBlockViewModel) { self.vm = vm }
    }
}
#endif

// MARK: - ViewModel uses user's PlatformImage wrapper
@MainActor
final class TileBlockViewModel: ObservableObject {
    struct AtlasSummary: Identifiable {
        let id: UUID
        let index: Int
        let title: String
        let subtitle: String
        let tileCountLabel: String
        let gridLabel: String
        let pixelSizeLabel: String
    }

    struct TileLayoutInfo {
        let frames: [CGRect]
        let contentSize: CGSize
    }

    enum PreviewBackend: String, CaseIterable, Identifiable {
        case metal
        case swiftUI

        var id: String { rawValue }
        var label: String {
            switch self {
            case .metal: return "Metal"
            case .swiftUI: return "SwiftUI"
            }
        }
    }

    @Published var config = TileBlockConfig() {
        didSet { scheduleConfigSync() }
    }
    @Published var mode: TileRenderer.Mode = .gridAllTiles {
        didSet { syncRendererConfig() }
    }
    @Published var selectedAtlas: Int = 0 {
        didSet {
            let clamped = clampIndex(selectedAtlas)
            if clamped != selectedAtlas {
                selectedAtlas = clamped
                return
            }
            syncRendererSelection()
            clampSelection()
        }
    }
    @Published var canExport: Bool = false
    @Published private(set) var atlasSummaries: [AtlasSummary] = []
    @Published var debugLogging: Bool = false {
        didSet { TileBlockDiagnostics.shared.isEnabled = debugLogging }
    }
    @Published private(set) var lastCapturedFrameURL: URL?
    @Published var previewBackend: PreviewBackend = .metal {
        didSet { TileBlockDiagnostics.shared.log("Preview backend switched to \(previewBackend.rawValue)") }
    }
    @Published var selectedTileIndex: Int?
    @Published private(set) var rendererPixelScale: CGFloat = 1

    fileprivate var renderer: TileRenderer?
    private var atlases: [TileAtlas] = []
    private var stagedCGImages: [CGImage] = []
    private var lastSlicingSignature: AtlasSignature?
    private var configSyncScheduled = false

    static let layoutInsets = EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
    static let tilePadding: CGFloat = 6
    static let scaleOptions: [CGFloat] = [1, 2, 3, 4, 6, 8, 12]

    var activeAtlasSummary: AtlasSummary? {
        atlasSummaries.first { $0.index == selectedAtlas }
    }

    var activeAtlas: TileAtlas? {
        atlases[safe: selectedAtlas]
    }

    func applyConfig() {
        syncRendererState()
        renderer?.forceRedraw()
    }

    private func scheduleConfigSync() {
        guard !configSyncScheduled else { return }
        configSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.configSyncScheduled = false
            self.refreshAtlasMetadata()
            self.syncRendererConfig()
            self.renderer?.forceRedraw()
        }
    }

    func attachRenderer(_ renderer: TileRenderer) {
        self.renderer = renderer
        #if canImport(UIKit)
        renderer.contentInsets = UIEdgeInsets(top: Self.layoutInsets.top,
                                              left: Self.layoutInsets.leading,
                                              bottom: Self.layoutInsets.bottom,
                                              right: Self.layoutInsets.trailing)
        #else
        renderer.contentInsets = NSEdgeInsets(top: Self.layoutInsets.top,
                                              left: Self.layoutInsets.leading,
                                              bottom: Self.layoutInsets.bottom,
                                              right: Self.layoutInsets.trailing)
        #endif
        renderer.tilePadding = Float(Self.tilePadding)
        renderer.exportScale = config.displayScale
        renderer.pixelScaleDidChange = { [weak self] scale in
            guard let self else { return }
            let clamped = max(scale, 0.0001)
            if abs(self.rendererPixelScale - clamped) > 0.001 {
                self.rendererPixelScale = clamped
            }
        }
        rendererPixelScale = max(renderer.pixelScale, 0.0001)
        ensureTexturesMatchRenderer()
        if !stagedCGImages.isEmpty {
            TileBlockDiagnostics.shared.log("Uploading \(stagedCGImages.count) staged image(s) now that renderer is ready")
            uploadAtlases(from: stagedCGImages)
            stagedCGImages.removeAll()
        }
        syncRendererState()
        TileBlockDiagnostics.shared.log("Renderer attached with device: \(renderer.device.name)")
    }

    private func clampIndex(_ idx: Int) -> Int {
        guard !atlases.isEmpty else { return 0 }
        return max(0, min(idx, atlases.count - 1))
    }

    private func syncRendererState() {
        syncRendererConfig()
        syncRendererAtlases()
        renderer?.forceRedraw()
    }

    private func syncRendererConfig() {
        guard let renderer else { return }
        renderer.config = config
        renderer.mode = mode
        renderer.exportScale = config.displayScale
        renderer.setNeedsDisplay()
        TileBlockDiagnostics.shared.log("Config synced: tileSize=\(config.tileSize) displayScale=\(config.displayScale) mode=\(mode)")
    }

    private func syncRendererAtlases() {
        guard let renderer else { return }
        renderer.atlases = atlases
        renderer.selectedAtlasIndex = clampIndex(selectedAtlas)
        renderer.setNeedsDisplay()
        TileBlockDiagnostics.shared.log("Renderer received \(atlases.count) atlas(es); selected index=\(renderer.selectedAtlasIndex)")
    }

    private func syncRendererSelection() {
        guard let renderer else { return }
        renderer.selectedAtlasIndex = clampIndex(selectedAtlas)
        renderer.setNeedsDisplay()
        TileBlockDiagnostics.shared.log("Renderer selection updated to index=\(renderer.selectedAtlasIndex)")
    }

    // Accepts the user's PlatformImage type
    func importImages(_ images: [PlatformImage]) {
        let cgs = images.map { $0.cgImage }
        guard renderer != nil else {
            TileBlockDiagnostics.shared.log("Renderer not ready; staging \(cgs.count) image(s)")
            stagedCGImages.append(contentsOf: cgs)
            return
        }
        uploadAtlases(from: cgs)
    }

    func removeSelectedAtlas() {
        guard atlases.indices.contains(selectedAtlas) else { return }
        atlases.remove(at: selectedAtlas)
        selectedAtlas = clampIndex(selectedAtlas)
        handleAtlasesDidChange()
    }

    func removeAllAtlases() {
        guard !atlases.isEmpty else { return }
        atlases.removeAll()
        selectedAtlas = 0
        lastSlicingSignature = nil
        selectedTileIndex = nil
        handleAtlasesDidChange()
    }

    private func refreshAtlasMetadata() {
        guard !atlases.isEmpty else {
            syncRendererConfig()
            syncRendererAtlases()
            return
        }
        let signature = AtlasSignature(config: config)
        if signature != lastSlicingSignature {
            atlases = atlases.map { TileAtlas(cgImage: $0.cgImage, texture: $0.texture, config: config) }
            lastSlicingSignature = signature
            selectedAtlas = clampIndex(selectedAtlas)
            handleAtlasesDidChange()
        } else {
            syncRendererConfig()
            syncRendererAtlases()
        }
    }

    private func rebuildAtlasSummaries() {
        atlasSummaries = atlases.enumerated().map { index, atlas in
            AtlasSummary(
                id: atlas.id,
                index: index,
                title: "Tileset \(index + 1)",
                subtitle: "\(atlas.tileCount) tiles • \(atlas.columns)×\(atlas.rows) grid • \(Int(atlas.size.width))×\(Int(atlas.size.height)) px",
                tileCountLabel: "\(atlas.tileCount) tile\(atlas.tileCount == 1 ? "" : "s")",
                gridLabel: "\(atlas.columns)×\(atlas.rows) grid",
                pixelSizeLabel: "\(Int(atlas.size.width))×\(Int(atlas.size.height)) px"
            )
        }
    }

    private func handleAtlasesDidChange() {
        rebuildAtlasSummaries()
        canExport = !atlases.isEmpty
        syncRendererAtlases()
        TileBlockDiagnostics.shared.log("Atlases updated: count=\(atlases.count), canExport=\(canExport)")
        renderer?.forceRedraw()
        clampSelection()
    }

    private struct AtlasSignature: Equatable {
        var tileSize: CGSize
        var margin: CGSize
        var spacing: CGSize

        init(config: TileBlockConfig) {
            tileSize = config.tileSize
            margin = config.margin
            spacing = config.spacing
        }
    }

    func layoutInfo(for mode: TileRenderer.Mode) -> TileLayoutInfo? {
        guard let atlas = activeAtlas else { return nil }
        let pxPerPoint = max(rendererPixelScale, 0.0001)
        let tileWidth = max(1, config.tileSize.width) * config.displayScale / pxPerPoint
        let tileHeight = max(1, config.tileSize.height) * config.displayScale / pxPerPoint
        let columns = max(1, atlas.columns)
        let pad = Self.tilePadding
        let insets = Self.layoutInsets

        var frames: [CGRect] = []
        frames.reserveCapacity(atlas.tiles.count)
        for index in 0..<atlas.tiles.count {
            let columnIndex = index % columns
            let rowIndex = index / columns
            let x = insets.leading + CGFloat(columnIndex) * (tileWidth + pad)
            let y = insets.top + CGFloat(rowIndex) * (tileHeight + pad)
            frames.append(CGRect(x: x, y: y, width: tileWidth, height: tileHeight))
        }

        let contentWidth = insets.leading + CGFloat(columns) * tileWidth + CGFloat(max(columns - 1, 0)) * pad + insets.trailing
        let rows = Int(ceil(Double(atlas.tiles.count) / Double(columns)))
        let contentHeight = insets.top + CGFloat(rows) * tileHeight + CGFloat(max(rows - 1, 0)) * pad + insets.bottom
        return TileLayoutInfo(frames: frames, contentSize: CGSize(width: contentWidth, height: contentHeight))
    }

    func currentContentSize() -> CGSize {
        layoutInfo(for: mode)?.contentSize ?? CGSize(width: 640, height: 640)
    }

    func tileIndex(at point: CGPoint) -> Int? {
        guard let frames = layoutInfo(for: mode)?.frames else { return nil }
        return frames.firstIndex(where: { $0.contains(point) })
    }

    func selectTile(at location: CGPoint) {
        if let idx = tileIndex(at: location) {
            selectedTileIndex = idx
        }
    }

    func selectTile(index: Int?) {
        selectedTileIndex = index
    }

    var selectedTile: Tile? {
        guard let idx = selectedTileIndex, let atlas = activeAtlas, atlas.tiles.indices.contains(idx) else { return nil }
        return atlas.tiles[idx]
    }

    var selectedTileImage: Image? {
        if let idx = selectedTileIndex, let renderer = renderer, let cg = renderer.renderTileImage(at: idx) {
            return Image(decorative: cg, scale: 1, orientation: .up)
        }
        guard let atlas = activeAtlas, let tile = selectedTile, let cg = atlas.cgImage(for: tile) else { return nil }
        return Image(decorative: cg, scale: 1, orientation: .up)
    }

    var selectedTileSize: CGSize? {
        guard selectedTileIndex != nil else { return nil }
        let pxPerPoint = max(rendererPixelScale, 0.0001)
        return CGSize(width: max(1, config.tileSize.width) * config.displayScale / pxPerPoint,
                      height: max(1, config.tileSize.height) * config.displayScale / pxPerPoint)
    }

    var selectedTilePixelSize: CGSize? {
        guard selectedTileIndex != nil else { return nil }
        return CGSize(width: max(1, config.tileSize.width) * config.displayScale,
                      height: max(1, config.tileSize.height) * config.displayScale)
    }

    func setDisplayScale(_ scale: CGFloat) {
        guard abs(config.displayScale - scale) > 0.001 else { return }
        config.displayScale = scale
    }

    private func clampSelection() {
        guard let atlas = activeAtlas else {
            selectedTileIndex = nil
            return
        }
        if let idx = selectedTileIndex, !atlas.tiles.indices.contains(idx) {
            selectedTileIndex = nil
        }
    }

    func capturePreviewFrame() {
        guard let renderer else { return }
        renderer.captureFrame { [weak self] url in
            DispatchQueue.main.async {
                self?.lastCapturedFrameURL = url
                if let url {
                    TileBlockDiagnostics.shared.log("Preview capture saved to \(url.path)")
                } else {
                    TileBlockDiagnostics.shared.log("Preview capture failed")
                }
            }
        }
    }

    private func uploadAtlases(from cgs: [CGImage]) {
        guard let device = renderer?.device else {
            TileBlockDiagnostics.shared.log("uploadAtlases called without renderer device; staging instead")
            stagedCGImages.append(contentsOf: cgs)
            return
        }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: true,
            .origin: MTKTextureLoader.Origin.topLeft,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue)
        ]
        var newAtlases: [TileAtlas] = atlases
        for cg in cgs {
            if let tex = try? loader.newTexture(cgImage: cg, options: options) {
                TileBlockDiagnostics.shared.log(
                    "Imported image: cg=\(cg.width)x\(cg.height), texture=\(tex.width)x\(tex.height), format=\(tex.pixelFormat.rawValue), usage=\(tex.usage.rawValue), storage=\(tex.storageMode.rawValue)"
                )
                let atlas = TileAtlas(cgImage: cg, texture: tex, config: config)
                newAtlases.append(atlas)
            } else {
                TileBlockDiagnostics.shared.log("Failed to create texture for image size=\(cg.width)x\(cg.height)")
            }
        }
        atlases = newAtlases
        selectedAtlas = max(0, newAtlases.count - 1)
        lastSlicingSignature = AtlasSignature(config: config)
        if let atlas = activeAtlas, !atlas.tiles.isEmpty {
            selectedTileIndex = 0
        }
        handleAtlasesDidChange()
    }

    private func ensureTexturesMatchRenderer() {
        guard let renderer, !atlases.isEmpty else { return }
        let needsRebuild = atlases.contains { $0.texture.device !== renderer.device }
        if needsRebuild {
            TileBlockDiagnostics.shared.log("Rebuilding \(atlases.count) atlas texture(s) to match renderer device")
            let cgs = atlases.map { $0.cgImage }
            atlases.removeAll()
            uploadAtlases(from: cgs)
        }
    }

    #if canImport(UIKit)
    func pasteFromClipboard() {
        let pb = UIPasteboard.general
        var imgs: [PlatformImage] = []
        if let uis = pb.images {
            for ui in uis { if let p = PlatformImage(ui) { imgs.append(p) } }
        } else if let data = pb.data(forPasteboardType: UTType.png.identifier),
                  let ui = UIImage(data: data),
                  let p = PlatformImage(ui) {
            imgs.append(p)
        }
        importImages(imgs)
    }
    #else
    func pasteFromClipboard() {
        let pb = NSPasteboard.general
        var imgs: [PlatformImage] = []
        if let items = pb.pasteboardItems {
            for it in items {
                if let data = it.data(forType: .png), let ns = NSImage(data: data),
                   let p = PlatformImage(ns) { imgs.append(p) }
                else if let data = it.data(forType: .tiff), let ns = NSImage(data: data),
                        let p = PlatformImage(ns) { imgs.append(p) }
            }
        }
        importImages(imgs)
    }
    #endif

    func dropProviders(_ providers: [NSItemProvider]) {
        var imgs: [PlatformImage] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                group.enter()
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    defer { group.leave() }
                    guard let data else { return }
                    #if canImport(UIKit)
                    if let ui = UIImage(data: data), let pimg = PlatformImage(ui) {
                        lock.lock(); imgs.append(pimg); lock.unlock()
                    }
                    #elseif canImport(AppKit)
                    if let ns = NSImage(data: data), let pimg = PlatformImage(ns) {
                        lock.lock(); imgs.append(pimg); lock.unlock()
                    }
                    #endif
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    guard let url = item as? URL, let data = try? Data(contentsOf: url) else { return }
                    #if canImport(UIKit)
                    if let ui = UIImage(data: data), let pimg = PlatformImage(ui) {
                        lock.lock(); imgs.append(pimg); lock.unlock()
                    }
                    #elseif canImport(AppKit)
                    if let ns = NSImage(data: data), let pimg = PlatformImage(ns) {
                        lock.lock(); imgs.append(pimg); lock.unlock()
                    }
                    #endif
                }
            }
        }
        group.notify(queue: .main) { self.importImages(imgs) }
    }

    func exportAllProcessed(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let r = renderer else { completion(.failure(NSError(domain: "Export", code: -1))); return }
        DispatchQueue.global(qos: .userInitiated).async {
            do { let url = try r.exportProcessedPNGs(); DispatchQueue.main.async { completion(.success(url)) } }
            catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
}
