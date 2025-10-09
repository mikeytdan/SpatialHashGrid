// File: TileBlockKit/TileBlockEditorView.swift
import SwiftUI
import Foundation
import UniformTypeIdentifiers
import Combine
#if os(macOS)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

public struct TileBlockEditorView: View {
    @StateObject private var vm = TileBlockViewModel()
    @State private var latestExportURL: URL?
    @State private var savedExportURL: URL?
    @State private var pendingExportDocument = ExportedArchiveDocument.placeholder()
    @State private var isShowingExporter = false
    @State private var pendingExportFilename: String = TileBlockEditorView.defaultExportBasename
    @State private var pendingExportSourceURL: URL?
    @State private var exportErrorMessage: String?

    public init() {}

    private static let defaultExportBasename = "TileBlockExport"

    private var exportDisplayURL: URL? {
        savedExportURL ?? latestExportURL
    }

    public var body: some View {
        editor
            #if os(iOS)
            .navigationTitle("Tile → Block")
            #endif
            #if os(macOS)
            .frame(minWidth: 940, minHeight: 700)
            #endif
            .fileExporter(
                isPresented: $isShowingExporter,
                document: pendingExportDocument,
                contentType: .zip,
                defaultFilename: pendingExportFilename
            ) { result in
                completeSaveAs(with: result)
            }
            .alert(
                "Export Failed",
                isPresented: Binding(
                    get: { exportErrorMessage != nil },
                    set: { if !$0 { exportErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { exportErrorMessage = nil }
            } message: {
                if let message = exportErrorMessage {
                    Text(message)
                }
            }
    }

    // MARK: - Editor
    private var editor: some View {
        GeometryReader { proxy in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView(.vertical) {
                        controlPanel
                            .padding(14)
                    }
                    .frame(width: min(max(proxy.size.width * 0.34, 320), 420))
                    .background(PlatformColors.secondaryBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    mainArea
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

//                if vm.canExport {
//                    HStack {
//                        Spacer()
//                        TileSelectionPreviewPanel(vm: vm)
//                            .frame(maxWidth: 260)
//                    }
//                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onDrop(of: [UTType.image, UTType.fileURL], isTargeted: nil) { providers in
            vm.dropProviders(providers); return true
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                footbar
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
            }
        }
    }

    // MARK: - Side Panel
    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 16) {

            GroupBox {
                Picker("View", selection: $vm.mode) {
                    Text("Grid").tag(TileRenderer.Mode.gridAllTiles)
                    Text("Preview Blocks").tag(TileRenderer.Mode.previewBlocks)
                }
                .pickerStyle(.segmented)
                
                Picker("Backend", selection: $vm.previewBackend) {
                    ForEach(TileBlockViewModel.PreviewBackend.allCases) { backend in
                        Text(backend.label).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.top, 8)
            } label: { label("Preview") }

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        key("Tile Size")
                        HStack(spacing: 8) {
                            Stepper("", value: Binding(
                                get: { Int(vm.config.tileSize.width) },
                                set: { let v = max(1, $0)
                                    vm.config.tileSize = CGSize(width: .init(v), height: .init(v))
                                    
                                }), in: 8...256
                            ).labelsHidden()
                            valueTag("\(Int(vm.config.tileSize.width)) px")
                        }
                    }
                    GridRow {
                        key("Margin X/Y")
                        axisSteppers(x: $vm.config.margin.width, y: $vm.config.margin.height, range: 0...64)
                    }
                    GridRow {
                        key("Spacing X/Y")
                        axisSteppers(x: $vm.config.spacing.width, y: $vm.config.spacing.height, range: 0...32)
                    }
                    GridRow {
                        key("Display Scale")
                        HStack(spacing: 6) {
                            ForEach(TileBlockViewModel.scaleOptions, id: \.self) { scale in
                                Button(String(format: "%.0fx", scale)) {
                                    vm.setDisplayScale(scale)
                                }
                                .buttonStyle(ScaleButtonStyle(isSelected: abs(vm.config.displayScale - scale) < 0.01))
                            }
                        }
                    }
                    GridRow {
                        key("Filtering")
                        Picker("Filtering", selection: Binding(
                            get: { vm.config.filterMode },
                            set: { vm.config.filterMode = $0 }
                        )) {
                            ForEach(TileFilterMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .controlSize(.small)
            } label: { label("Tile Metrics") }

            GroupBox {
                adaptiveShapePicker(selection: $vm.config.shape)
                    
                Toggle("Hazard Stripes", isOn: $vm.config.hazardStripes)
                                        .toggleStyle(.switch)
                    .padding(.top, 4)

                sliders
            } label: { label("Appearance") }

            GroupBox {
                lightingControls
            } label: { label("Lighting") }

            GroupBox {
                colorControls
            } label: { label("Color Adjustments") }

            GroupBox {
                tilesetSection
            } label: { label("Tilesets") }

            GroupBox {
                Toggle("Enable Debug Logging", isOn: $vm.debugLogging)
                    .toggleStyle(.switch)
                if vm.debugLogging {
                    Text("Logs streamed via Console.app (subsystem: SpatialHashGrid.TileBlockKit).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button {
                        vm.capturePreviewFrame()
                    } label: {
                        Label("Capture Preview Frame", systemImage: "camera")
                    }
                    .buttonStyle(BorderedButtonStyle())
                    .controlSize(.mini)
                    if let captureURL = vm.lastCapturedFrameURL {
                        Text("Last capture: \(captureURL.lastPathComponent)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } label: { label("Debug") }

            GroupBox {
                HStack(spacing: 12) {
                    Button { vm.pasteFromClipboard() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    Button { clearExportState() } label: { Label("Clear Export", systemImage: "trash") }
                        .disabled(exportDisplayURL == nil && !isShowingExporter)
                }
                .buttonStyle(BorderedButtonStyle())
                .controlSize(.small)
            } label: { label("Actions") }
        }
        .controlSize(.small)
    }

    // MARK: - Main Area
    private var mainArea: some View {
        GeometryReader { _ in
            let contentSize = vm.currentContentSize()
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Group {
                        switch vm.previewBackend {
                        case .metal:
                            MetalTileView(vm: vm)
                        case .swiftUI:
                            SwiftUITileGridView(vm: vm)
                        }
                    }
                    .frame(width: contentSize.width, height: contentSize.height)

                    TileSelectionOverlay(vm: vm)
                        .frame(width: contentSize.width, height: contentSize.height)

                    TileTapOverlay(vm: vm)
                        .frame(width: contentSize.width, height: contentSize.height)
                }
                .background(Color(white: 0.12))
            }
            .background(Color(white: 0.12))
            .overlay {
                if !vm.canExport {
                    VStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("Drop or paste a tileset to preview")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - Bottom Bar
    private var footbar: some View {
        HStack {
            SegmentedButtons(
                left: ("Grid", "square.grid.3x3", { vm.mode = .gridAllTiles }),
                right: ("Preview", "rectangle.3.offgrid", { vm.mode = .previewBlocks })
            )

            Text("Mode: \(vm.mode == .gridAllTiles ? "Grid" : "Preview Blocks")")
                .font(.callout)
                .foregroundStyle(.secondary)

            if let summary = vm.activeAtlasSummary, vm.canExport {
                HStack(spacing: 6) {
                    valueTag(summary.tileCountLabel)
                    valueTag(summary.gridLabel)
                    valueTag(summary.pixelSizeLabel)
                }
                .padding(.leading, 8)
            }

            Spacer()

            Menu {
                Button { beginExport(saveAs: false) } label: {
                    Label("Quick Export (ZIP)", systemImage: "shippingbox")
                }
                Button { beginExport(saveAs: true) } label: {
                    Label("Export As…", systemImage: "square.and.arrow.down")
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up.on.square")
            }
            .disabled(!vm.canExport)

            #if os(macOS)
            if exportDisplayURL != nil {
                Button { revealExportLocation() } label: { Label("Show in Finder", systemImage: "folder") }
            }
            #endif

            if let url = exportDisplayURL {
                #if os(iOS)
                ShareLink(item: url) { Label("Share Export", systemImage: "square.and.arrow.up") }
                #else
                Text("Exported: \(url.lastPathComponent)")
                #endif
            }
        }
        .buttonStyle(BorderedButtonStyle())
        .controlSize(.regular)
    }

    // MARK: - Export Helpers
    private func beginExport(saveAs: Bool) {
        vm.exportAllProcessed { result in
            switch result {
            case .success(let url):
                handleExportSuccess(url: url, saveAs: saveAs)
            case .failure(let error):
                presentExportError(error)
            }
        }
    }

    private func handleExportSuccess(url: URL, saveAs: Bool) {
        if saveAs {
            prepareSaveAs(for: url)
        } else {
            removeIfTemporary(latestExportURL)
            latestExportURL = url
            savedExportURL = nil
        }
    }

    private func prepareSaveAs(for url: URL) {
        removeIfTemporary(latestExportURL)
        pendingExportSourceURL = url
        latestExportURL = url
        savedExportURL = nil
        pendingExportFilename = suggestedExportBasename()
        pendingExportDocument = ExportedArchiveDocument(url: url)
        isShowingExporter = true
    }

    private func clearExportState() {
        removeIfTemporary(latestExportURL)
        latestExportURL = nil
        savedExportURL = nil
        pendingExportDocument = ExportedArchiveDocument.placeholder()
        isShowingExporter = false
        cleanupPendingExportSource()
    }

    private func completeSaveAs(with result: Result<URL, Error>) {
        switch result {
        case .success(let destination):
            savedExportURL = destination
            latestExportURL = destination
        case .failure(let error):
            if !isUserCancelled(error) {
                presentExportError(error)
            }
        }
        cleanupPendingExportSource()
        pendingExportDocument = ExportedArchiveDocument.placeholder()
        isShowingExporter = false
    }

    private func cleanupPendingExportSource() {
        if let source = pendingExportSourceURL {
            try? FileManager.default.removeItem(at: source)
        }
        pendingExportSourceURL = nil
    }

    private func removeIfTemporary(_ url: URL?) {
        guard let url else { return }
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        if url.path.hasPrefix(tempDir.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func suggestedExportBasename() -> String {
        if let summary = vm.activeAtlasSummary {
            return "Tileset-\(summary.index + 1)"
        }
        return Self.defaultExportBasename
    }

    private func presentExportError(_ error: Error) {
        exportErrorMessage = error.localizedDescription
    }

    private func isUserCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            return true
        }
        #if canImport(UIKit)
        if nsError.domain == UIDocumentPickerErrorDomain && nsError.code == UIDocumentPickerError.canceled.rawValue {
            return true
        }
        #endif
        return false
    }

#if os(macOS)
    private func revealExportLocation() {
        guard let url = exportDisplayURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #else
    private func revealExportLocation() {}
    #endif

    // MARK: - Controls
    private var sliders: some View {
        VStack(alignment: .leading, spacing: 10) {
            if shouldShowBevelControls(for: vm.config.shape) {
                valueSlider("Bevel", value: $vm.config.bevelWidth, in: 0...0.45)
                valueSlider("Corner", value: $vm.config.cornerRadius, in: 0...0.45)
            }
            valueSlider("Outline", value: $vm.config.outlineWidth, in: 0...0.2)
            valueSlider("Outline Intensity", value: $vm.config.outlineIntensity, in: 0...1)
            valueSlider("Shadow", value: $vm.config.shadowSize, in: 0...0.6)
            Text("Shape: \(vm.config.shape.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    private var tilesetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if vm.atlasSummaries.isEmpty {
                Text("Paste or drop a tileset to populate the preview.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Picker("Tileset", selection: $vm.selectedAtlas) {
                        ForEach(vm.atlasSummaries) { summary in
                            Text(summary.title).tag(summary.index)
                        }
                    }
                    .pickerStyle(.menu)

                    Spacer()

                    Menu {
                        Button(role: .destructive) { vm.removeSelectedAtlas() } label: {
                            Label("Remove Selected", systemImage: "minus.circle")
                        }
                        Button(role: .destructive) { vm.removeAllAtlases() } label: {
                            Label("Remove All", systemImage: "trash")
                        }
                    } label: {
                        Label("Manage", systemImage: "slider.horizontal.3")
                    }
                    .menuIndicator(.visible)
                }

                if let active = vm.activeAtlasSummary {
                    HStack(spacing: 6) {
                        valueTag(active.tileCountLabel)
                        valueTag(active.gridLabel)
                        valueTag(active.pixelSizeLabel)
                        Spacer()
                    }
                    Text(active.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func valueSlider(_ title: String, value: Binding<Float>, in range: ClosedRange<Float>) -> some View {
        LabeledContent(title) {
            Slider(value: value, in: range)
                .frame(maxWidth: 220)
        }
    }

    private var lightingControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: $vm.config.lightingMode) {
                ForEach(TileLightingMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if vm.config.lightingMode == .edgeHighlights {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Highlights Sides").font(.caption).foregroundStyle(.secondary)
                    edgeToggleRow(binding: Binding(
                        get: { vm.config.highlightEdges },
                        set: { vm.config.highlightEdges = $0 }
                    ))
                    valueSlider("Highlight Intensity", value: $vm.config.highlightIntensity, in: 0...1)
                    LabeledContent("Highlight Color") {
                        ColorPicker("", selection: edgeColorBinding(for: \TileBlockConfig.highlightColor))
                            .labelsHidden()
                            .frame(width: 120)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Shadow Sides").font(.caption).foregroundStyle(.secondary)
                    edgeToggleRow(binding: Binding(
                        get: { vm.config.shadowEdges },
                        set: { vm.config.shadowEdges = $0 }
                    ))
                    valueSlider("Shadow Intensity", value: $vm.config.shadowIntensity, in: 0...1)
                    LabeledContent("Shadow Color") {
                        ColorPicker("", selection: edgeColorBinding(for: \TileBlockConfig.shadowColor))
                            .labelsHidden()
                            .frame(width: 120)
                    }
                }

                valueSlider("Edge Falloff", value: $vm.config.edgeFalloff, in: 0.02...0.45)
            } else if vm.config.lightingMode == .glow {
                Text("Glow uses highlight color and intensity to create a soft core.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                valueSlider("Glow Intensity", value: $vm.config.highlightIntensity, in: 0...1)
                LabeledContent("Glow Color") {
                    ColorPicker("", selection: edgeColorBinding(for: \TileBlockConfig.highlightColor))
                        .labelsHidden()
                        .frame(width: 120)
                }
            }
        }
    }

    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            valueSlider("Hue", value: Binding(
                get: { vm.config.hueShiftDegrees },
                set: { vm.config.hueShiftDegrees = max(-360, min(360, $0)) }
            ), in: -180...180)
            valueSlider("Saturation", value: Binding(
                get: { vm.config.saturation },
                set: { vm.config.saturation = max(0, min(3, $0)) }
            ), in: 0...3)
            valueSlider("Brightness", value: Binding(
                get: { vm.config.brightness },
                set: { vm.config.brightness = max(-1, min(1, $0)) }
            ), in: -1...1)
            valueSlider("Contrast", value: Binding(
                get: { vm.config.contrast },
                set: { vm.config.contrast = max(0, min(3, $0)) }
            ), in: 0...3)
            Button("Reset Colors") {
                vm.config.hueShiftDegrees = 0
                vm.config.saturation = 1
                vm.config.brightness = 0
                vm.config.contrast = 1
            }
            .buttonStyle(BorderedButtonStyle())
            .controlSize(.mini)
        }
    }

    private func shouldShowBevelControls(for shape: BlockShapeKind) -> Bool {
        switch shape {
        case .bevel, .inset, .pillow:
            return true
        default:
            return false
        }
    }

    private func edgeToggleRow(binding: Binding<TileEdgeMask>) -> some View {
        HStack(spacing: 8) {
            edgeToggle("Top", systemImage: "arrow.up", edge: .top, binding: binding)
            edgeToggle("Right", systemImage: "arrow.right", edge: .right, binding: binding)
            edgeToggle("Bottom", systemImage: "arrow.down", edge: .bottom, binding: binding)
            edgeToggle("Left", systemImage: "arrow.left", edge: .left, binding: binding)
        }
    }

    private func edgeToggle(_ title: String, systemImage: String, edge: TileEdgeMask, binding: Binding<TileEdgeMask>) -> some View {
        let isOn = Binding<Bool>(
            get: { binding.wrappedValue.contains(edge) },
            set: { newValue in
                var value = binding.wrappedValue
                if newValue { value.insert(edge) } else { value.remove(edge) }
                binding.wrappedValue = value
            }
        )
        return Toggle(isOn: isOn) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .buttonStyle(BorderedButtonStyle())
        .controlSize(.mini)
    }

    private func edgeColorBinding(for keyPath: WritableKeyPath<TileBlockConfig, SIMD3<Float>>) -> Binding<Color> {
        Binding<Color>(
            get: { color(from: vm.config[keyPath: keyPath]) },
            set: { newValue in
                vm.config[keyPath: keyPath] = vector(from: newValue)
                
            }
        )
    }

    private func color(from vector: SIMD3<Float>) -> Color {
        let r = Double(min(max(vector.x, 0), 1))
        let g = Double(min(max(vector.y, 0), 1))
        let b = Double(min(max(vector.z, 0), 1))
        return Color(red: r, green: g, blue: b)
    }

    private func vector(from color: Color) -> SIMD3<Float> {
        #if canImport(UIKit)
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, &g, &b, &a)
        return SIMD3<Float>(Float(r), Float(g), Float(b))
        #elseif os(macOS)
        let ns = NSColor(color)
        guard let converted = ns.usingColorSpace(.deviceRGB) else {
            return SIMD3<Float>(0.0, 0.0, 0.0)
        }
        return SIMD3<Float>(Float(converted.redComponent), Float(converted.greenComponent), Float(converted.blueComponent))
        #else
        return SIMD3<Float>(0.0, 0.0, 0.0)
        #endif
    }

    // Switches to a menu automatically when the segmented control would clip in a sheet.
    @ViewBuilder
    private func adaptiveShapePicker(selection: Binding<BlockShapeKind>) -> some View {
        ViewThatFits(in: .horizontal) {
            Picker("Block", selection: selection) {
                ForEach(BlockShapeKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Menu {
                Picker("Block", selection: selection) {
                    ForEach(BlockShapeKind.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                Label("Block Shape", systemImage: "square.on.square")
            }
            .menuIndicator(.visible)
        }
    }

    // MARK: - Small UI helpers
    private func axisSteppers(x: Binding<CGFloat>, y: Binding<CGFloat>, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 8) {
            Stepper("", value: Binding(
                get: { Int(x.wrappedValue) },
                set: { x.wrappedValue = .init($0) }
            ), in: range).labelsHidden()
            valueTag("\(Int(x.wrappedValue))")

            Stepper("", value: Binding(
                get: { Int(y.wrappedValue) },
                set: { y.wrappedValue = .init($0) }
            ), in: range).labelsHidden()
            valueTag("\(Int(y.wrappedValue))")
        }
    }

    private func key(_ s: String) -> some View {
        Text(s).font(.subheadline).foregroundStyle(.secondary)
    }

    private func valueTag(_ s: String) -> some View {
        Text(s)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
    }

    private func label(_ title: String) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3).fill(.tint).frame(width: 4, height: 16)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Tiny components
private struct SegmentedButtons: View {
    let left: (String, String, () -> Void)
    let right: (String, String, () -> Void)

    var body: some View {
        HStack(spacing: 10) {
            Button(action: left.2)  { Label(left.0,  systemImage: left.1) }
            Button(action: right.2) { Label(right.0, systemImage: right.1) }
        }
    }
}

private struct SwiftUITileGridView: View {
    @ObservedObject var vm: TileBlockViewModel

    var body: some View {
        if let atlas = vm.activeAtlas, let layout = vm.layoutInfo(for: vm.mode) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(atlas.tiles.enumerated()), id: \.1.id) { index, tile in
                    if index < layout.frames.count, let cg = atlas.cgImage(for: tile) {
                        let frame = layout.frames[index]
                        Image(decorative: cg, scale: 1, orientation: .up)
                            .resizable()
                            .interpolation(vm.config.filterMode == .nearest ? .none : .medium)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }
            .frame(width: layout.contentSize.width, height: layout.contentSize.height)
        } else {
            Color.clear
        }
    }
}

private struct TileSelectionOverlay: View {
    @ObservedObject var vm: TileBlockViewModel

    var body: some View {
        Canvas { context, _ in
            guard let info = vm.layoutInfo(for: vm.mode),
                  let selected = vm.selectedTileIndex,
                  selected < info.frames.count else { return }
            var path = Path()
            path.addRect(info.frames[selected])
            context.stroke(path, with: .color(.yellow.opacity(0.9)), lineWidth: 2)
        }
        .allowsHitTesting(false)
    }
}

private struct TileTapOverlay: View {
    @ObservedObject var vm: TileBlockViewModel

    var body: some View {
        GeometryReader { _ in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onEnded { value in
                        let translation = value.translation
                        if abs(translation.width) < 5 && abs(translation.height) < 5 {
                            vm.selectTile(at: value.location)
                        }
                    },
                    including: .subviews
                )
        }
        .allowsHitTesting(vm.canExport)
    }
}

private struct TileSelectionPreviewPanel: View {
    @ObservedObject var vm: TileBlockViewModel

    @ViewBuilder
    var body: some View {
        if vm.canExport {
            VStack(alignment: .leading, spacing: 10) {
                if let image = vm.selectedTileImage, let baseSize = vm.selectedTileSize {
                    TileRepeatView(image: image,
                                   baseTileSize: baseSize,
                                   displayScale: vm.config.displayScale,
                                   filterMode: vm.config.filterMode)
                        .frame(width: baseSize.width * vm.config.displayScale * 4,
                               height: baseSize.height * vm.config.displayScale * 4)
                        .background(Color(white: 0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        )
                    if let tile = vm.selectedTile, let pixelSize = vm.selectedTilePixelSize {
                        Text("Tile #\(tile.id) • \(Int(pixelSize.width))×\(Int(pixelSize.height)) px")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Text("Selected tile repeated 4×4")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Clear Selection") {
                        vm.selectTile(index: nil)
                    }
                    .buttonStyle(BorderedButtonStyle())
                    .controlSize(.mini)
                } else {
                    Text("Tap a tile in the preview to see it tiled here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 8)
            .frame(maxWidth: 240)
        }
    }
}

private struct TileRepeatView: View {
    let image: Image
    let baseTileSize: CGSize
    let displayScale: CGFloat
    let filterMode: TileFilterMode

    var body: some View {
        let tileWidth = max(1, baseTileSize.width) * displayScale
        let tileHeight = max(1, baseTileSize.height) * displayScale
        let repeatCount = 4
        VStack(spacing: 0) {
            ForEach(0..<repeatCount, id: \.self) { _ in
                HStack(spacing: 0) {
                    ForEach(0..<repeatCount, id: \.self) { _ in
                        image.resizable()
                            .interpolation(filterMode == .nearest ? .none : .medium)
                            .frame(width: tileWidth, height: tileHeight)
                    }
                }
            }
        }
        .frame(width: tileWidth * CGFloat(repeatCount), height: tileHeight * CGFloat(repeatCount))
    }
}

private struct ScaleButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.bold())
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .opacity(configuration.isPressed ? 0.7 : 1.0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: 1)
            )
            .foregroundColor(isSelected ? .white : .primary)
    }
}

final class ExportedArchiveDocument: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] { [.zip] }

    typealias Snapshot = URL

    let fileURL: URL

    init(url: URL) {
        self.fileURL = url
    }

    convenience init(configuration: ReadConfiguration) throws {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: nil)
    }

    func snapshot(contentType: UTType) throws -> URL {
        fileURL
    }

    func fileWrapper(snapshot: URL, configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: snapshot, options: .immediate)
    }

    static func placeholder() -> ExportedArchiveDocument {
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ExportPlaceholder.zip")
        if !FileManager.default.fileExists(atPath: tempURL.path) {
            FileManager.default.createFile(atPath: tempURL.path, contents: Data())
        }
        return ExportedArchiveDocument(url: tempURL)
    }
}
