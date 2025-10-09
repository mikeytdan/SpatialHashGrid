import SwiftUI

struct MapEditorView: View {
    private typealias EnemyMovementChoice = MapEditorViewModel.EnemyMovementChoice
    private typealias EnemyBehaviorChoice = MapEditorViewModel.EnemyBehaviorChoice
    private typealias EnemyAttackChoice = MapEditorViewModel.EnemyAttackChoice

    @StateObject private var viewModel = MapEditorViewModel()
    @State private var isPreviewing = false
    @State private var spawnNameDraft: String = ""
    @State private var input = InputController()
    @State private var editorFocused = true
    @State private var showingTileBlockEditor = false
    @State private var isShowingExporter = false
    @State private var isShowingImporter = false
    @State private var pendingExportDocument = MapFileDocument.placeholder()
    @State private var pendingExportFilename: String = "Map"
    @State private var persistenceErrorMessage: String?
    @State private var sidebarWidth: CGFloat = 320
    @State private var inspectorWidth: CGFloat = 360
    @State private var inspectorTab: InspectorTab = .context
    @State private var showInspector: Bool = true
    @State private var sidebarDragInitial: CGFloat?
    @State private var inspectorDragInitial: CGFloat?
    @State private var tilePaletteHeight: CGFloat = 260
    @State private var tilePaletteDragStart: CGFloat?

    private let adapter = MetalLevelPreviewAdapter()

    private let minSidebarWidth: CGFloat = 260
    private let minInspectorWidth: CGFloat = 280
    private let minCanvasWidth: CGFloat = 520
    private let dividerHitArea: CGFloat = 10
    private let minTilePaletteHeight: CGFloat = 180
    private let maxTilePaletteFraction: CGFloat = 0.65
    private let tileDividerThickness: CGFloat = 6

    private enum InspectorTab: String, CaseIterable, Identifiable {
        case context = "Context"
        case entities = "Entities"
        case level = "Level"

        var id: String { rawValue }
    }

    var body: some View {
        ZStack {
            if isPreviewing {
                adapter.makePreview(for: viewModel.blueprint, input: input) {
                    isPreviewing = false
                    focusEditor()
                }
                .ignoresSafeArea()
            } else {
                editorWorkspace
            }
        }
        .sheet(isPresented: $showingTileBlockEditor) {
            NavigationStack { TileBlockEditorView() }
        }
        .onChange(of: viewModel.selectedSpawnID) {
            spawnNameDraft = viewModel.selectedSpawn?.name ?? ""
        }
        .onChange(of: viewModel.blueprint.spawnPoints) {
            spawnNameDraft = viewModel.selectedSpawn?.name ?? ""
        }
        .onAppear {
            focusEditor()
        }
        .onChange(of: isPreviewing) { _, previewing in
            DispatchQueue.main.async {
                if previewing {
                    input.reset()
                } else {
                    focusEditor()
                }
            }
        }
        .fileExporter(
            isPresented: $isShowingExporter,
            document: pendingExportDocument,
            contentType: MapFileDocument.contentType,
            defaultFilename: pendingExportFilename
        ) { result in
            if case let .failure(error) = result {
                persistenceErrorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $isShowingImporter,
            allowedContentTypes: MapFileDocument.readableContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleImportResult(result)
        }
        .alert(
            "File Operation Failed",
            isPresented: Binding(
                get: { persistenceErrorMessage != nil },
                set: { newValue in
                    if !newValue { persistenceErrorMessage = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) { persistenceErrorMessage = nil }
        } message: {
            if let message = persistenceErrorMessage {
                Text(message)
            }
        }
        .keyboardInput(focused: $editorFocused, onEvent: handleKeyboardEvent)
    }

    private var editorWorkspace: some View {
        VStack(spacing: 0) {
            workspaceToolbar
            Divider()
            GeometryReader { geometry in
                let totalWidth = geometry.size.width
                let canShowInspector = showInspector && totalWidth > (minSidebarWidth + minCanvasWidth + minInspectorWidth + 40)
                let sidebarLimit = max(minSidebarWidth, totalWidth - minCanvasWidth - (canShowInspector ? minInspectorWidth : 0))
                let currentSidebarWidth = min(max(sidebarWidth, minSidebarWidth), sidebarLimit)
                let inspectorLimit = canShowInspector ? max(minInspectorWidth, totalWidth - minCanvasWidth - currentSidebarWidth) : 0
                let currentInspectorWidth = canShowInspector ? min(max(inspectorWidth, minInspectorWidth), inspectorLimit) : 0

                HStack(spacing: 0) {
                    sidebarPanel
                        .frame(width: currentSidebarWidth)
                        .background(PlatformColors.secondaryBackground)

                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1)
                        .contentShape(Rectangle().inset(by: -dividerHitArea))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if sidebarDragInitial == nil {
                                        sidebarDragInitial = sidebarWidth
                                    }
                                    let initialWidth = sidebarDragInitial ?? sidebarWidth
                                    let proposed = initialWidth + value.translation.width
                                    let upperBound = max(minSidebarWidth, totalWidth - minCanvasWidth - (canShowInspector ? minInspectorWidth : 0))
                                    sidebarWidth = min(max(proposed, minSidebarWidth), upperBound)
                                }
                                .onEnded { _ in
                                    sidebarDragInitial = nil
                                }
                        )

                    mapStage
                        .frame(minWidth: minCanvasWidth, maxWidth: .infinity, maxHeight: .infinity)
                        .background(PlatformColors.secondaryBackground)

                    if canShowInspector {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 1)
                            .contentShape(Rectangle().inset(by: -dividerHitArea))
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        if inspectorDragInitial == nil {
                                            inspectorDragInitial = inspectorWidth
                                        }
                                        let initialWidth = inspectorDragInitial ?? inspectorWidth
                                        let proposed = initialWidth - value.translation.width
                                        let upperBound = max(minInspectorWidth, totalWidth - minCanvasWidth - min(sidebarWidth, sidebarLimit))
                                        inspectorWidth = min(max(proposed, minInspectorWidth), upperBound)
                                    }
                                    .onEnded { _ in
                                        inspectorDragInitial = nil
                                    }
                            )

                        inspectorPanel
                            .frame(width: currentInspectorWidth)
                            .background(PlatformColors.secondaryBackground)
                    }
                }
                .frame(width: totalWidth, height: geometry.size.height)
                .background(PlatformColors.workspaceBackground)
            }
        }
        .background(PlatformColors.workspaceBackground.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: showInspector)
    }

    private var workspaceToolbar: some View {
        HStack(spacing: 12) {
            Label("Map Editor", systemImage: "square.grid.2x2")
                .font(.title3.bold())

            Divider()
                .frame(height: 24)

            Label(viewModel.tool.label, systemImage: viewModel.tool.systemImage)
                .font(.subheadline)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(Capsule())

            Spacer()

            HStack(spacing: 8) {
                Button(action: viewModel.undo) {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!viewModel.canUndo)

                Button(action: viewModel.redo) {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!viewModel.canRedo)
            }
            .buttonStyle(.borderless)

            Divider()
                .frame(height: 24)

            Menu {
                Button("Export Map…", action: beginExport)
                Button("Import Map…") { isShowingImporter = true }
                Divider()
                Button("Tile Block Editor") { showingTileBlockEditor = true }
            } label: {
                Label("File", systemImage: "tray.and.arrow.down")
            }
            .accessibilityLabel("File Actions")

            Button(action: viewModel.zoomOut) {
                Image(systemName: "minus.magnifyingglass")
            }
            .accessibilityLabel("Zoom Out")

            Button(action: viewModel.zoomIn) {
                Image(systemName: "plus.magnifyingglass")
            }
            .accessibilityLabel("Zoom In")

            Button(action: viewModel.resetZoom) {
                Image(systemName: "arrow.counterclockwise")
            }
            .accessibilityLabel("Reset Zoom")

            Divider()
                .frame(height: 24)

            Button(action: viewModel.toggleGrid) {
                Image(systemName: viewModel.showGrid ? "square.grid.3x3.fill" : "square.grid.3x3")
                    .foregroundStyle(viewModel.showGrid ? Color.accentColor : Color.primary)
            }
            .accessibilityLabel(viewModel.showGrid ? "Hide Grid" : "Show Grid")

            Button(action: openPreviewIfPossible) {
                Image(systemName: "play.circle")
            }
            .disabled(viewModel.blueprint.spawnPoints.isEmpty)
            .accessibilityLabel("Playtest Level")

            Button(action: { withAnimation { showInspector.toggle() } }) {
                Image(systemName: "sidebar.right")
                    .symbolVariant(showInspector ? .none : .slash)
            }
            .accessibilityLabel(showInspector ? "Hide Inspector" : "Show Inspector")
        }
        .buttonStyle(.plain)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var mapStage: some View {
        let tilePixels = CGFloat(viewModel.blueprint.tileSize) * CGFloat(viewModel.zoom)
        let mapWidth = tilePixels * CGFloat(viewModel.blueprint.columns)
        let mapHeight = tilePixels * CGFloat(viewModel.blueprint.rows)
        let frameWidth = max(mapWidth, minCanvasWidth)
        let frameHeight = max(mapHeight, minCanvasWidth)

        return ScrollView([.horizontal, .vertical]) {
            MapCanvasView(
                blueprint: viewModel.blueprint,
                previewTiles: viewModel.shapePreview,
                showGrid: viewModel.showGrid,
                zoom: viewModel.zoom,
                selectedSpawnID: viewModel.selectedSpawnID,
                selectedPlatformID: viewModel.selectedPlatformID,
                selectedSentryID: viewModel.selectedSentryID,
                selectedEnemyID: viewModel.selectedEnemyID,
                previewColor: viewModel.paintTileKind.fillColor,
                hoveredPoint: viewModel.hoveredPoint,
                selectionState: viewModel.selectionRenderState,
                onHover: viewModel.updateHover,
                onDragBegan: viewModel.handleDragBegan,
                onDragChanged: viewModel.handleDragChanged,
                onDragEnded: viewModel.handleDragEnded,
                onFocusRequested: focusEditorIfNeeded
            )
            .frame(width: frameWidth, height: frameHeight)
            .padding(40)
        }
        .scrollIndicators(.hidden)
        .background(PlatformColors.secondaryBackground)
    }

    private var sidebarPanel: some View {
        GeometryReader { geometry in
            let bottomInset = geometry.safeAreaInsets.bottom
            let minPalette = minTilePaletteHeight
            let maxPalette = max(minPalette, (geometry.size.height - bottomInset) * maxTilePaletteFraction)
            let paletteHeight = min(max(tilePaletteHeight, minPalette), maxPalette)
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 16) {
                        levelHeader
                        toolGrid
                        panelCard { toolOptionsSection }
                    }
                    .padding(.vertical, 18)
                    .padding(.horizontal, 14)
                }
                .frame(height: max(0, geometry.size.height - paletteHeight - tileDividerThickness - bottomInset))

                dividerHandle(minPalette: minPalette, maxPalette: maxPalette)

                tilePaletteDock
                    .frame(height: paletteHeight)
                    .background(.ultraThinMaterial)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .padding(.bottom, bottomInset)
            .onAppear {
                tilePaletteHeight = min(max(tilePaletteHeight, minPalette), maxPalette)
            }
            .onChange(of: geometry.size.height) {
                tilePaletteHeight = min(max(tilePaletteHeight, minPalette), maxPalette)
            }
        }
    }

    private var inspectorPanel: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    switch inspectorTab {
                    case .context:
                        contextInspector
                    case .entities:
                        entitiesInspector
                    case .level:
                        levelInspector
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder
    private var contextInspector: some View {
        if let enemy = viewModel.selectedEnemy {
            panelCard { enemyDetailPanel(enemy: enemy) }
        } else if let platform = viewModel.selectedPlatform {
            panelCard { platformDetailPanel(platform: platform) }
        } else if let sentry = viewModel.selectedSentry {
            panelCard { sentryDetailPanel(sentry: sentry) }
        } else if let spawn = viewModel.selectedSpawn {
            panelCard { spawnDetailPanel(spawn: spawn) }
        } else {
            panelCard { selectionPlaceholder }
        }
    }

    @ViewBuilder
    private var entitiesInspector: some View {
        panelCard { spawnSection }
        panelCard { platformSection }
        panelCard { sentrySection }
        panelCard { enemySection }
    }

    @ViewBuilder
    private var levelInspector: some View {
        panelCard { levelOverviewSection }
        panelCard { quickActions }
    }

    private func panelCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var levelHeader: some View {
        panelCard { levelNameSection }
    }

    private var toolGrid: some View {
        panelCard { toolsSection }
    }

    private var tilePaletteDock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tiles")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView(.vertical, showsIndicators: true) {
                tilePaletteSection
            }
            .frame(maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(isTileEditingTool ? 1 : 0.35)
            .allowsHitTesting(isTileEditingTool)
            .overlay(alignment: .center) {
                if !isTileEditingTool {
                    emptyHint("Select a tile tool to edit the palette.")
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            Button(action: { showingTileBlockEditor = true }) {
                Label("Tile Block Editor", systemImage: "rectangle.grid.2x2")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func platformDetailPanel(platform: MovingPlatformBlueprint) -> some View {
        let current = viewModel.selectedPlatform ?? platform
        return VStack(alignment: .leading, spacing: 12) {
            Text("Selected Platform")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("Origin r\(current.origin.row) c\(current.origin.column) • Size \(current.size.columns)×\(current.size.rows)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            let rowBinding = Binding<Int>(
                get: { viewModel.selectedPlatform?.target.row ?? current.target.row },
                set: { viewModel.updateSelectedPlatformTarget(row: $0) }
            )
            let columnBinding = Binding<Int>(
                get: { viewModel.selectedPlatform?.target.column ?? current.target.column },
                set: { viewModel.updateSelectedPlatformTarget(column: $0) }
            )

            Stepper(value: rowBinding, in: viewModel.platformTargetRowRange(current)) {
                Text("Target Row: \(rowBinding.wrappedValue)")
            }

            Stepper(value: columnBinding, in: viewModel.platformTargetColumnRange(current)) {
                Text("Target Column: \(columnBinding.wrappedValue)")
            }

            let speedBinding = Binding<Double>(
                get: { viewModel.selectedPlatform?.speed ?? current.speed },
                set: { viewModel.updateSelectedPlatformSpeed($0) }
            )

            VStack(alignment: .leading, spacing: 4) {
                Slider(value: speedBinding, in: 0.1...5.0, step: 0.05)
                Text(String(format: "Speed: %.2f tiles/s", speedBinding.wrappedValue))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            let progressBinding = Binding<Double>(
                get: { viewModel.selectedPlatform?.initialProgress ?? current.initialProgress },
                set: { viewModel.updateSelectedPlatformInitialProgress($0) }
            )

            VStack(alignment: .leading, spacing: 4) {
                Slider(value: progressBinding, in: 0...1, step: 0.01)
                Text(String(format: "Start Position: %.0f%%", progressBinding.wrappedValue * 100))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    viewModel.duplicateSelectedPlatform()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }

                Spacer()

                Button(role: .destructive) {
                    viewModel.removePlatform(current)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private func sentryDetailPanel(sentry: SentryBlueprint) -> some View {
        let current = viewModel.selectedSentry ?? sentry
        let angleRange = viewModel.sentryInitialAngleRange(current)

        return VStack(alignment: .leading, spacing: 12) {
            Text("Selected Sentry")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("Coordinate r\(current.coordinate.row) c\(current.coordinate.column)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Group {
                let rangeBinding = Binding<Double>(
                    get: { viewModel.selectedSentry?.scanRange ?? current.scanRange },
                    set: { viewModel.updateSelectedSentryRange($0) }
                )
                SliderRow(title: "Scan Range", value: rangeBinding, range: 1.0...32.0, step: 0.5, formatter: { String(format: "%.1f tiles", $0) })

                let centerBinding = Binding<Double>(
                    get: { viewModel.selectedSentry?.scanCenterDegrees ?? current.scanCenterDegrees },
                    set: { viewModel.updateSelectedSentryCenter($0) }
                )
                SliderRow(title: "Scan Center", value: centerBinding, range: -180.0...180.0, step: 1.0, formatter: { String(format: "%.0f°", $0) })

                let arcBinding = Binding<Double>(
                    get: { viewModel.selectedSentry?.scanArcDegrees ?? current.scanArcDegrees },
                    set: { viewModel.updateSelectedSentryArc($0) }
                )
                SliderRow(title: "Sweep Arc", value: arcBinding, range: 10.0...240.0, step: 1.0, formatter: { String(format: "%.0f°", $0) })

                let initialBinding = Binding<Double>(
                    get: { viewModel.selectedSentry?.initialFacingDegrees ?? current.initialFacingDegrees },
                    set: { viewModel.updateSelectedSentryInitialAngle($0) }
                )
                SliderRow(title: "Initial Angle", value: initialBinding, range: angleRange.lowerBound...angleRange.upperBound, step: 1.0, formatter: { String(format: "%.0f°", $0) })

                let sweepBinding = Binding<Double>(
                    get: { viewModel.selectedSentry?.sweepSpeedDegreesPerSecond ?? current.sweepSpeedDegreesPerSecond },
                    set: { viewModel.updateSelectedSentrySweepSpeed($0) }
                )
                SliderRow(title: "Sweep Speed", value: sweepBinding, range: 10.0...360.0, step: 5.0, formatter: { String(format: "%.0f°/s", $0) })
            }

            let projectileKindBinding = Binding<SentryBlueprint.ProjectileKind>(
                get: { viewModel.selectedSentry?.projectileKind ?? current.projectileKind },
                set: { viewModel.updateSelectedSentryProjectileKind($0) }
            )

            Picker("Projectile", selection: projectileKindBinding) {
                ForEach(SentryBlueprint.ProjectileKind.allCases, id: \.self) { kind in
                    Text(kind.displayLabel).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            let activeKind = viewModel.selectedSentry?.projectileKind ?? current.projectileKind

            Group {
                let speedBinding = Binding<Double>(
                    get: { viewModel.selectedSentry?.projectileSpeed ?? current.projectileSpeed },
                    set: { viewModel.updateSelectedSentryProjectileSpeed($0) }
                )
                SliderRow(
                    title: activeKind == .laser ? "Beam Intensity" : "Projectile Speed",
                    value: speedBinding,
                    range: 50.0...2000.0,
                    step: 25.0,
                    formatter: { String(format: "%.0f", $0) }
                )
                .disabled(activeKind == .laser)

                let sizeBinding = Binding<Double>(
                    get: { viewModel.selectedSentry?.projectileSize ?? current.projectileSize },
                    set: { viewModel.updateSelectedSentryProjectileSize($0) }
                )
                SliderRow(title: "Projectile Size", value: sizeBinding, range: 0.05...2.0, step: 0.05, formatter: { String(format: "%.2f tiles", $0) })

                let lifetimeBinding = Binding<Double>(
                    get: { viewModel.selectedSentry?.projectileLifetime ?? current.projectileLifetime },
                    set: { viewModel.updateSelectedSentryProjectileLifetime($0) }
                )
                SliderRow(title: activeKind == .laser ? "Beam Duration" : "Lifetime", value: lifetimeBinding, range: 0.1...12.0, step: 0.1, formatter: { String(format: "%.1fs", $0) })

                let burstBinding = Binding<Int>(
                    get: { viewModel.selectedSentry?.projectileBurstCount ?? current.projectileBurstCount },
                    set: { viewModel.updateSelectedSentryProjectileBurstCount($0) }
                )
                Stepper(value: burstBinding, in: 1...12) {
                    Text("Burst Count: \(burstBinding.wrappedValue)")
                }

                let spreadBinding = Binding<Double>(
                    get: { viewModel.selectedSentry?.projectileSpreadDegrees ?? current.projectileSpreadDegrees },
                    set: { viewModel.updateSelectedSentryProjectileSpread($0) }
                )
                SliderRow(title: "Spread", value: spreadBinding, range: 0.0...90.0, step: 1.0, formatter: { String(format: "%.0f°", $0) })
                    .disabled(burstBinding.wrappedValue <= 1)

                if activeKind == .heatSeeking {
                    let turnBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.heatSeekingTurnRateDegreesPerSecond ?? current.heatSeekingTurnRateDegreesPerSecond },
                        set: { viewModel.updateSelectedSentryHeatTurnRate($0) }
                    )
                    SliderRow(title: "Turn Rate", value: turnBinding, range: 30.0...720.0, step: 10.0, formatter: { String(format: "%.0f°/s", $0) })
                }

                let cooldownBinding = Binding<Double>(
                    get: { viewModel.selectedSentry?.fireCooldown ?? current.fireCooldown },
                    set: { viewModel.updateSelectedSentryCooldown($0) }
                )
                Stepper(value: cooldownBinding, in: 0.2...5.0, step: 0.1) {
                    Text(String(format: "Cooldown: %.1fs", cooldownBinding.wrappedValue))
                }

                let toleranceBinding = Binding<Double>(
                    get: { viewModel.selectedSentry?.aimToleranceDegrees ?? current.aimToleranceDegrees },
                    set: { viewModel.updateSelectedSentryAimTolerance($0) }
                )
                Stepper(value: toleranceBinding, in: 2...45, step: 1) {
                    Text(String(format: "Aim Tolerance: %.0f°", toleranceBinding.wrappedValue))
                }
            }

            HStack {
                Button {
                    viewModel.duplicateSelectedSentry()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }

                Spacer()

                Button(role: .destructive) {
                    viewModel.removeSentry(current)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private func spawnDetailPanel(spawn: PlayerSpawnPoint) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Selected Spawn")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("Coordinate r\(spawn.coordinate.row) c\(spawn.coordinate.column)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            TextField("Name", text: $spawnNameDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit { viewModel.renameSelectedSpawn(to: spawnNameDraft) }

            HStack {
                Button(action: { viewModel.renameSelectedSpawn(to: spawnNameDraft) }) {
                    Label("Save Name", systemImage: "checkmark.circle")
                }

                Spacer()

                Button(role: .destructive, action: viewModel.removeSelectedSpawn) {
                    Label("Remove", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
        }
    }

    private var selectionPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No Selection")
                .font(.headline)
            Text("Choose a tool or select an item in the canvas to edit its properties here.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var levelOverviewSection: some View {
        let blueprint = viewModel.blueprint
        let tileCount = blueprint.tileEntries().count
        let solidCount = blueprint.solidTiles().count

        return VStack(alignment: .leading, spacing: 10) {
            Text("Level Overview")
                .font(.caption)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    overviewKey("Size")
                    Text("\(blueprint.columns) × \(blueprint.rows)")
                }
                GridRow {
                    overviewKey("Tile Size")
                    Text(String(format: "%.0f px", blueprint.tileSize))
                }
                GridRow {
                    overviewKey("Tiles")
                    Text("\(tileCount) total • \(solidCount) solid")
                }
                GridRow {
                    overviewKey("Spawns")
                    Text("\(blueprint.spawnPoints.count)")
                }
                GridRow {
                    overviewKey("Platforms")
                    Text("\(blueprint.movingPlatforms.count)")
                }
                GridRow {
                    overviewKey("Sentries")
                    Text("\(blueprint.sentries.count)")
                }
                GridRow {
                    overviewKey("Enemies")
                    Text("\(blueprint.enemies.count)")
                }
            }
            .font(.footnote)

            Divider()
                .padding(.vertical, 6)

            let rowsBinding = Binding<Int>(
                get: { viewModel.blueprint.rows },
                set: { viewModel.updateLevelRows($0) }
            )

            let columnsBinding = Binding<Int>(
                get: { viewModel.blueprint.columns },
                set: { viewModel.updateLevelColumns($0) }
            )

            Stepper(value: rowsBinding, in: 4...256) {
                Text("Rows: \(rowsBinding.wrappedValue)")
            }

            Stepper(value: columnsBinding, in: 4...256) {
                Text("Columns: \(columnsBinding.wrappedValue)")
            }

            let tileSizeBinding = Binding<Double>(
                get: { viewModel.blueprint.tileSize },
                set: { viewModel.updateTileSize($0) }
            )

            VStack(alignment: .leading, spacing: 4) {
                Slider(value: tileSizeBinding, in: 8...128, step: 1)
                Text(String(format: "Tile Size: %.0f px", tileSizeBinding.wrappedValue))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func SliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        formatter: (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Slider(value: value, in: range, step: step)
            Text("\(title): \(formatter(value.wrappedValue))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func overviewKey(_ label: String) -> some View {
        Text(label)
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func dividerHandle(minPalette: CGFloat, maxPalette: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: tileDividerThickness)
            .overlay(
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 40, height: 3)
            )
            .contentShape(Rectangle().inset(by: -dividerHitArea))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if tilePaletteDragStart == nil {
                            tilePaletteDragStart = min(max(tilePaletteHeight, minPalette), maxPalette)
                        }
                        let initial = tilePaletteDragStart ?? tilePaletteHeight
                        let proposed = initial - value.translation.height
                        tilePaletteHeight = min(max(proposed, minPalette), maxPalette)
                    }
                    .onEnded { _ in
                        tilePaletteDragStart = nil
                    }
            )
    }

    private func header(title: String, addAction: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: addAction) {
                Image(systemName: "plus")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Add \(title)")
        }
    }

    private func entityRow(title: String, subtitle: String, color: Color, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? color.opacity(0.18) : PlatformColors.secondaryBackground)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func emptyHint(_ message: String) -> some View {
        Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    private var isTileEditingTool: Bool {
        switch viewModel.tool {
        case .pencil, .flood, .line, .rectangle, .circle, .eraser, .rectErase:
            return true
        default:
            return false
        }
    }

    private var enemySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(title: "Enemies") { viewModel.addEnemyAtCenter() }

            let enemies = viewModel.blueprint.enemies
            if enemies.isEmpty {
                emptyHint("Drop enemies onto the map to populate encounters.")
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(enemies.enumerated()), id: \.element.id) { index, enemy in
                        entityRow(
                            title: "Enemy \(index + 1)",
                            subtitle: "r\(enemy.coordinate.row) c\(enemy.coordinate.column)",
                            color: viewModel.enemyColor(for: index),
                            isSelected: viewModel.selectedEnemyID == enemy.id
                        ) {
                            viewModel.selectEnemy(enemy)
                        }
                        .accessibilityLabel("Enemy #\(index + 1)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func enemyDetailPanel(enemy: EnemyBlueprint) -> some View {
        let current = viewModel.selectedEnemy ?? enemy
        VStack(alignment: .leading, spacing: 14) {
            Text("Selected Enemy")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("Coordinate: r\(current.coordinate.row) c\(current.coordinate.column)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Group {
                let widthBinding = Binding<Double>(
                    get: {
                        viewModel.selectedEnemy?.size.x ?? current.size.x
                    },
                    set: { viewModel.updateSelectedEnemySizeWidth($0) }
                )
                Slider(value: widthBinding, in: 20...160, step: 2)
                Text(String(format: "Width: %.0f", widthBinding.wrappedValue))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                let heightBinding = Binding<Double>(
                    get: { viewModel.selectedEnemy?.size.y ?? current.size.y },
                    set: { viewModel.updateSelectedEnemySizeHeight($0) }
                )
                Slider(value: heightBinding, in: 20...220, step: 2)
                Text(String(format: "Height: %.0f", heightBinding.wrappedValue))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Group {
                let movementBinding = Binding<EnemyMovementChoice>(
                    get: { viewModel.selectedEnemyMovementChoice },
                    set: { viewModel.setSelectedEnemyMovementChoice($0) }
                )
                Picker("Movement", selection: movementBinding) {
                    ForEach(EnemyMovementChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.menu)

                switch current.movement {
                case .patrolHorizontal(let span, let speed):
                    let spanBinding = Binding<Double>(
                        get: {
                            if case .patrolHorizontal(let value, _) = viewModel.selectedEnemy?.movement { return value }
                            return span
                        },
                        set: { viewModel.updateSelectedEnemyHorizontalSpan($0) }
                    )
                    Slider(value: spanBinding, in: 16...800, step: 4)
                    Text(String(format: "Span: %.0f", spanBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    let speedBinding = Binding<Double>(
                        get: {
                            if case .patrolHorizontal(_, let value) = viewModel.selectedEnemy?.movement { return value }
                            return speed
                        },
                        set: { viewModel.updateSelectedEnemyHorizontalSpeed($0) }
                    )
                    Slider(value: speedBinding, in: 20...400, step: 5)
                    Text(String(format: "Speed: %.0f", speedBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                case .patrolVertical(let span, let speed):
                    let spanBinding = Binding<Double>(
                        get: {
                            if case .patrolVertical(let value, _) = viewModel.selectedEnemy?.movement { return value }
                            return span
                        },
                        set: { viewModel.updateSelectedEnemyVerticalSpan($0) }
                    )
                    Slider(value: spanBinding, in: 16...800, step: 4)
                    Text(String(format: "Span: %.0f", spanBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    let speedBinding = Binding<Double>(
                        get: {
                            if case .patrolVertical(_, let value) = viewModel.selectedEnemy?.movement { return value }
                            return speed
                        },
                        set: { viewModel.updateSelectedEnemyVerticalSpeed($0) }
                    )
                    Slider(value: speedBinding, in: 20...400, step: 5)
                    Text(String(format: "Speed: %.0f", speedBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                case .perimeter(let width, let height, let speed, let clockwise):
                    let widthBinding = Binding<Double>(
                        get: {
                            if case .perimeter(let value, _, _, _) = viewModel.selectedEnemy?.movement { return value }
                            return width
                        },
                        set: { viewModel.updateSelectedEnemyPerimeterWidth($0) }
                    )
                    Slider(value: widthBinding, in: 16...800, step: 4)
                    Text(String(format: "Width: %.0f", widthBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    let heightBinding = Binding<Double>(
                        get: {
                            if case .perimeter(_, let value, _, _) = viewModel.selectedEnemy?.movement { return value }
                            return height
                        },
                        set: { viewModel.updateSelectedEnemyPerimeterHeight($0) }
                    )
                    Slider(value: heightBinding, in: 16...800, step: 4)
                    Text(String(format: "Height: %.0f", heightBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    let speedBinding = Binding<Double>(
                        get: {
                            if case .perimeter(_, _, let value, _) = viewModel.selectedEnemy?.movement { return value }
                            return speed
                        },
                        set: { viewModel.updateSelectedEnemyPerimeterSpeed($0) }
                    )
                    Slider(value: speedBinding, in: 20...400, step: 5)
                    Text(String(format: "Speed: %.0f", speedBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Toggle("Clockwise", isOn: Binding<Bool>(
                        get: {
                            if case .perimeter(_, _, _, let value) = viewModel.selectedEnemy?.movement { return value }
                            return clockwise
                        },
                        set: { viewModel.updateSelectedEnemyPerimeterClockwise($0) }
                    ))

                case .wallBounce(let axis, let speed):
                    Picker("Axis", selection: Binding<EnemyController.MovementPattern.Axis>(
                        get: {
                            if case .wallBounce(let value, _) = viewModel.selectedEnemy?.movement { return value }
                            return axis
                        },
                        set: { viewModel.updateSelectedEnemyWallBounceAxis($0) }
                    )) {
                        Text("Horizontal").tag(EnemyController.MovementPattern.Axis.horizontal)
                        Text("Vertical").tag(EnemyController.MovementPattern.Axis.vertical)
                    }
                    .pickerStyle(.segmented)

                    let speedBinding = Binding<Double>(
                        get: {
                            if case .wallBounce(_, let value) = viewModel.selectedEnemy?.movement { return value }
                            return speed
                        },
                        set: { viewModel.updateSelectedEnemyWallBounceSpeed($0) }
                    )
                    Slider(value: speedBinding, in: 40...400, step: 5)
                    Text(String(format: "Speed: %.0f", speedBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                case .waypoints:
                    Text("Waypoint movement editing is not yet available in the editor.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .idle:
                    EmptyView()
                }
            }

            Group {
                let behaviorBinding = Binding<EnemyBehaviorChoice>(
                    get: { viewModel.selectedEnemyBehaviorChoice },
                    set: { viewModel.setSelectedEnemyBehaviorChoice($0) }
                )
                Picker("Behaviour", selection: behaviorBinding) {
                    ForEach(EnemyBehaviorChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.menu)

                switch current.behavior {
                case .passive:
                    EmptyView()
                case .chase(let range, let multiplier, let tolerance):
                    Slider(value: Binding<Double>(
                        get: { if case .chase(let value, _, _) = viewModel.selectedEnemy?.behavior { return value }; return range },
                        set: { viewModel.updateSelectedEnemyChaseRange($0) }
                    ), in: 32...1200, step: 10)
                    let displayedRange = viewModel.selectedEnemy.flatMap { $0.behavior.flatChaseRange } ?? range
                    Text(String(format: "Sight Range: %.0f", displayedRange))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .chase(_, let value, _) = viewModel.selectedEnemy?.behavior { return value }; return multiplier },
                        set: { viewModel.updateSelectedEnemyChaseMultiplier($0) }
                    ), in: 0.5...3.0, step: 0.05)
                    let displayedMultiplier = viewModel.selectedEnemy.flatMap { $0.behavior.flatChaseMultiplier } ?? multiplier
                    Text(String(format: "Speed Multiplier: %.2f", displayedMultiplier))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .chase(_, _, let value) = viewModel.selectedEnemy?.behavior { return value }; return tolerance },
                        set: { viewModel.updateSelectedEnemyChaseTolerance($0) }
                    ), in: 0...400, step: 5)
                    let displayedTolerance = viewModel.selectedEnemy.flatMap { $0.behavior.flatChaseTolerance } ?? tolerance
                    Text(String(format: "Vertical Tolerance: %.0f", displayedTolerance))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                case .flee(let range, let safe, let run):
                    Slider(value: Binding<Double>(
                        get: { if case .flee(let value, _, _) = viewModel.selectedEnemy?.behavior { return value }; return range },
                        set: { viewModel.updateSelectedEnemyFleeRange($0) }
                    ), in: 32...1200, step: 10)
                    let fleeRange = viewModel.selectedEnemy.flatMap { $0.behavior.flatFleeRange } ?? range
                    Text(String(format: "Sight Range: %.0f", fleeRange))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .flee(_, let value, _) = viewModel.selectedEnemy?.behavior { return value }; return safe },
                        set: { viewModel.updateSelectedEnemyFleeSafeDistance($0) }
                    ), in: 32...1200, step: 10)
                    let safeDistance = viewModel.selectedEnemy.flatMap { $0.behavior.flatFleeSafe } ?? safe
                    Text(String(format: "Safe Distance: %.0f", safeDistance))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .flee(_, _, let value) = viewModel.selectedEnemy?.behavior { return value }; return run },
                        set: { viewModel.updateSelectedEnemyFleeRunMultiplier($0) }
                    ), in: 0.5...3.0, step: 0.05)
                    let fleeMultiplier = viewModel.selectedEnemy.flatMap { $0.behavior.flatFleeRun } ?? run
                    Text(String(format: "Run Multiplier: %.2f", fleeMultiplier))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                case .strafe(let range, let preferred, let speed):
                    Slider(value: Binding<Double>(
                        get: { if case .strafe(let value, _, _) = viewModel.selectedEnemy?.behavior { return value }; return range },
                        set: { viewModel.updateSelectedEnemyStrafeRange($0) }
                    ), in: 60...1600, step: 10)
                    let strafeRange = viewModel.selectedEnemy.flatMap { $0.behavior.flatStrafeRange } ?? range
                    Text(String(format: "Sight Range: %.0f", strafeRange))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .strafe(_, let value, _) = viewModel.selectedEnemy?.behavior { return value.lowerBound }; return preferred.lowerBound },
                        set: { viewModel.updateSelectedEnemyStrafeNearDistance($0) }
                    ), in: 40...max(60, preferred.upperBound - 8), step: 5)
                    let strafeNear = viewModel.selectedEnemy.flatMap { $0.behavior.flatStrafeNear } ?? preferred.lowerBound
                    Text(String(format: "Preferred Near: %.0f", strafeNear))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .strafe(_, let value, _) = viewModel.selectedEnemy?.behavior { return value.upperBound }; return preferred.upperBound },
                        set: { viewModel.updateSelectedEnemyStrafeFarDistance($0) }
                    ), in: preferred.lowerBound + 8...1600, step: 5)
                    let strafeFar = viewModel.selectedEnemy.flatMap { $0.behavior.flatStrafeFar } ?? preferred.upperBound
                    Text(String(format: "Preferred Far: %.0f", strafeFar))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .strafe(_, _, let value) = viewModel.selectedEnemy?.behavior { return value }; return speed },
                        set: { viewModel.updateSelectedEnemyStrafeSpeed($0) }
                    ), in: 30...320, step: 5)
                    let strafeSpeed = viewModel.selectedEnemy.flatMap { $0.behavior.flatStrafeSpeed } ?? speed
                    Text(String(format: "Strafe Speed: %.0f", strafeSpeed))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                let attackBinding = Binding<EnemyAttackChoice>(
                    get: { viewModel.selectedEnemyAttackChoice },
                    set: { viewModel.setSelectedEnemyAttackChoice($0) }
                )
                Picker("Attack", selection: attackBinding) {
                    ForEach(EnemyAttackChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.menu)

                switch current.attack {
                case .none:
                    EmptyView()
                case .shooter(let speed, let cooldown, let range):
                    Slider(value: Binding<Double>(
                        get: { if case .shooter(let value, _, _) = viewModel.selectedEnemy?.attack { return value }; return speed },
                        set: { viewModel.updateSelectedEnemyShooterSpeed($0) }
                    ), in: 80...900, step: 10)
                    let bulletSpeed = viewModel.selectedEnemy.flatMap { $0.attack.flatShooterSpeed } ?? speed
                    Text(String(format: "Bullet Speed: %.0f", bulletSpeed))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .shooter(_, let value, _) = viewModel.selectedEnemy?.attack { return value }; return cooldown },
                        set: { viewModel.updateSelectedEnemyShooterCooldown($0) }
                    ), in: 0.1...4, step: 0.05)
                    let bulletCooldown = viewModel.selectedEnemy.flatMap { $0.attack.flatShooterCooldown } ?? cooldown
                    Text(String(format: "Cooldown: %.2fs", bulletCooldown))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .shooter(_, _, let value) = viewModel.selectedEnemy?.attack { return value }; return range },
                        set: { viewModel.updateSelectedEnemyShooterRange($0) }
                    ), in: 80...1600, step: 10)
                    let bulletRange = viewModel.selectedEnemy.flatMap { $0.attack.flatShooterRange } ?? range
                    Text(String(format: "Range: %.0f", bulletRange))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                case .sword(let range, let cooldown, let knock):
                    Slider(value: Binding<Double>(
                        get: { if case .sword(let value, _, _) = viewModel.selectedEnemy?.attack { return value }; return range },
                        set: { viewModel.updateSelectedEnemySwordRange($0) }
                    ), in: 16...160, step: 2)
                    let meleeRange = viewModel.selectedEnemy.flatMap { $0.attack.flatMeleeRange } ?? range
                    Text(String(format: "Range: %.0f", meleeRange))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .sword(_, let value, _) = viewModel.selectedEnemy?.attack { return value }; return cooldown },
                        set: { viewModel.updateSelectedEnemySwordCooldown($0) }
                    ), in: 0.2...4, step: 0.05)
                    let meleeCooldown = viewModel.selectedEnemy.flatMap { $0.attack.flatMeleeCooldown } ?? cooldown
                    Text(String(format: "Cooldown: %.2fs", meleeCooldown))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .sword(_, _, let value) = viewModel.selectedEnemy?.attack { return value }; return knock },
                        set: { viewModel.updateSelectedEnemySwordKnockback($0) }
                    ), in: 0...600, step: 10)
                    let meleeKnock = viewModel.selectedEnemy.flatMap { $0.attack.flatMeleeKnockback } ?? knock
                    Text(String(format: "Knockback: %.0f", meleeKnock))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                case .punch(let range, let cooldown, let knock):
                    Slider(value: Binding<Double>(
                        get: { if case .punch(let value, _, _) = viewModel.selectedEnemy?.attack { return value }; return range },
                        set: { viewModel.updateSelectedEnemyPunchRange($0) }
                    ), in: 8...120, step: 2)
                    let meleeRange = viewModel.selectedEnemy.flatMap { $0.attack.flatMeleeRange } ?? range
                    Text(String(format: "Range: %.0f", meleeRange))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .punch(_, let value, _) = viewModel.selectedEnemy?.attack { return value }; return cooldown },
                        set: { viewModel.updateSelectedEnemyPunchCooldown($0) }
                    ), in: 0.2...4, step: 0.05)
                    let meleeCooldown = viewModel.selectedEnemy.flatMap { $0.attack.flatMeleeCooldown } ?? cooldown
                    Text(String(format: "Cooldown: %.2fs", meleeCooldown))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .punch(_, _, let value) = viewModel.selectedEnemy?.attack { return value }; return knock },
                        set: { viewModel.updateSelectedEnemyPunchKnockback($0) }
                    ), in: 0...600, step: 10)
                    let meleeKnock = viewModel.selectedEnemy.flatMap { $0.attack.flatMeleeKnockback } ?? knock
                    Text(String(format: "Knockback: %.0f", meleeKnock))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                Slider(value: Binding<Double>(
                    get: { viewModel.selectedEnemy?.acceleration ?? current.acceleration },
                    set: { viewModel.updateSelectedEnemyAcceleration($0) }
                ), in: 2...30, step: 0.5)
                Text(String(format: "Acceleration: %.1f", viewModel.selectedEnemy?.acceleration ?? current.acceleration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Slider(value: Binding<Double>(
                    get: { viewModel.selectedEnemy?.maxSpeed ?? current.maxSpeed },
                    set: { viewModel.updateSelectedEnemyMaxSpeed($0) }
                ), in: 60...600, step: 5)
                Text(String(format: "Max Speed: %.0f", viewModel.selectedEnemy?.maxSpeed ?? current.maxSpeed))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Affected by Gravity", isOn: Binding<Bool>(
                    get: { viewModel.selectedEnemy?.affectedByGravity ?? current.affectedByGravity },
                    set: { viewModel.updateSelectedEnemyGravityEnabled($0) }
                ))

                let gravityBinding = Binding<Double>(
                    get: { viewModel.selectedEnemy?.gravityScale ?? current.gravityScale },
                    set: { viewModel.updateSelectedEnemyGravityScale($0) }
                )
                Slider(value: gravityBinding, in: 0...2.0, step: 0.05)
                    .disabled(!(viewModel.selectedEnemy?.affectedByGravity ?? current.affectedByGravity))
                Text(String(format: "Gravity Scale: %.2f", gravityBinding.wrappedValue))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    viewModel.duplicateSelectedEnemy()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                        .font(.caption)
                }

                Spacer()

                Button(role: .destructive) {
                    viewModel.removeSelectedEnemy()
                } label: {
                    Label("Remove", systemImage: "trash")
                        .font(.caption)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var levelNameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Level Name")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $viewModel.levelName)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button(action: beginExport) {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Button {
                    isShowingImporter = true
                } label: {
                    Label("Import JSON", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var tilePaletteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            let columns = [GridItem(.adaptive(minimum: 52, maximum: 80), spacing: 8)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(viewModel.tilePalette, id: \.self) { tile in
                    Button {
                        viewModel.selectedTileKind = tile
                    } label: {
                        TileSwatch(tile: tile, isSelected: viewModel.selectedTileKind == tile)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tile.displayName)
                }
            }

            Text("Selected: \(viewModel.selectedTileKind.displayName)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if viewModel.selectedTileKind.isRamp {
                Button {
                    viewModel.toggleSelectedRampOrientation()
                } label: {
                    Label("Flip Ramp", systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tools")
                .font(.caption)
                .foregroundStyle(.secondary)

            let columns = [GridItem(.adaptive(minimum: 72, maximum: 120), spacing: 8)]
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(MapEditorViewModel.Tool.allCases) { tool in
                    Button {
                        viewModel.tool = tool
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: tool.systemImage)
                                .font(.title3)
                            Text(tool.label)
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(viewModel.tool == tool ? Color.accentColor.opacity(0.2) : PlatformColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var shapeModePicker: some View {
        Picker("Draw Mode", selection: $viewModel.drawMode) {
            ForEach(MapEditorViewModel.ShapeDrawMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var toolOptionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tool Options")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch viewModel.tool {
            case .select:
                selectionToolOptions
            case .pencil:
                Text("Click or drag to paint tiles. Hold Option while clicking to sample from the canvas.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .flood:
                Text("Flood fill replaces contiguous regions using the selected tile. Double-click to flood the entire layer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .line, .rectangle, .circle:
                shapeModePicker
                Text("Hold Shift to constrain angles and Option to erase instead of fill.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .rectErase:
                Text("Drag to erase a rectangular area. Hold Option to invert the selection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .eraser:
                Text("Drag to clear tiles. Hold Option while dragging to toggle solids instead of wiping.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .spawn:
                Button(action: addSpawn) {
                    Label("Add Spawn At Center", systemImage: "plus.circle")
                }
                .buttonStyle(.bordered)
                Text("Use the Spawn tool to drag existing spawns to new tiles.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .platform:
                Button(action: viewModel.addPlatformAtCenter) {
                    Label("Add Platform Near Center", systemImage: "rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                Text("Drag in the canvas to define a platform. Adjust its path and speed from the inspector.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .sentry:
                Button(action: viewModel.addSentryAtCenter) {
                    Label("Add Sentry Near Center", systemImage: "dot.radiowaves.right")
                }
                .buttonStyle(.bordered)
                Text("Place a sentry on a solid tile. Use the inspector to tune sweep angles, projectiles, and targeting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .enemy:
                Button(action: viewModel.addEnemyAtCenter) {
                    Label("Drop Enemy Near Center", systemImage: "figure.walk")
                }
                .buttonStyle(.bordered)
                Text("Enemies inherit movement, behavior, and attack presets that you can refine in the inspector.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectionToolOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Selection Mask")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("All") { viewModel.setSelectionMask(.everything) }
                Button("Tiles") { viewModel.setSelectionMask([.tiles]) }
                Button("Entities") { viewModel.setSelectionMask(.entities) }
            }
            .buttonStyle(.bordered)

            VStack(alignment: .leading, spacing: 6) {
                maskToggle(label: "Tiles", flag: .tiles)
                maskToggle(label: "Spawns", flag: .spawns)
                maskToggle(label: "Platforms", flag: .platforms)
                maskToggle(label: "Sentries", flag: .sentries)
                maskToggle(label: "Enemies", flag: .enemies)
            }

            Divider()

            if let selection = viewModel.multiSelection {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tiles: \(selection.tiles.count)  Spawns: \(selection.spawns.count)  Platforms: \(selection.platforms.count)  Sentries: \(selection.sentries.count)  Enemies: \(selection.enemies.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if selection.offset != .zero {
                        Text("Pending offset r\(selection.offset.row) c\(selection.offset.column)")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            } else {
                Text("Drag to select tiles and entities. Use the mask to control what gets captured.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Button("Copy") { viewModel.copySelection() }
                    .disabled(!viewModel.hasSelection)
                Button("Cut") { viewModel.cutSelection() }
                    .disabled(!viewModel.hasSelection)
                Button("Paste") { viewModel.pasteSelection() }
                    .disabled(!viewModel.canPasteSelection)
            }
            .buttonStyle(.bordered)

            HStack(spacing: 10) {
                Button("Commit Move") { viewModel.commitSelectionMove() }
                    .disabled(!viewModel.canCommitSelectionMove)
                Button("Cancel Move") { viewModel.cancelSelectionMove() }
                    .disabled(!viewModel.canCommitSelectionMove)
            }
            .buttonStyle(.bordered)
        }
    }

    private func maskToggle(label: String, flag: MapEditorViewModel.SelectionMask) -> some View {
        Toggle(label, isOn: Binding(
            get: { viewModel.selectionMask.contains(flag) },
            set: { newValue in
                var mask = viewModel.selectionMask
                if newValue {
                    mask.insert(flag)
                } else {
                    mask.remove(flag)
                }
                viewModel.setSelectionMask(mask)
            }
        ))
        .toggleStyle(.switch)
    }

    private var sentrySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(title: "Sentries") { viewModel.addSentryAtCenter() }

            let sentries = viewModel.blueprint.sentries
            if sentries.isEmpty {
                emptyHint("Place sentries on solid tiles to create defensive coverage.")
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(sentries.enumerated()), id: \.element.id) { index, sentry in
                        entityRow(
                            title: "Sentry \(index + 1)",
                            subtitle: "r\(sentry.coordinate.row) c\(sentry.coordinate.column)",
                            color: viewModel.sentryColor(for: index),
                            isSelected: viewModel.selectedSentryID == sentry.id
                        ) {
                            viewModel.selectSentry(sentry)
                        }
                    }
                }
            }
        }
    }
    
    private func isHandledKey(_ input: KeyboardInput) -> Bool {
        // Any key we map in InputController should return handled.
        // This avoids arrow keys accidentally scrolling a parent scroll view.
        if let key = input.key {
            switch key {
            case .leftArrow, .rightArrow, .upArrow, .escape, .downArrow:
                return true
            default:
                break
            }
        }

        let ch = input.characters.lowercased()
        if ch == "a" || ch == "d" || ch == "w" || ch == " " { return true }
        if input.modifiers.contains(.command), ["z", "y", "r", "c", "x", "v"].contains(ch) { return true }
        if ch == "\r" || ch == "\n" { return true }
        return false
    }

    private var platformSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(title: "Platforms") { viewModel.addPlatformAtCenter() }

            let platforms = viewModel.blueprint.movingPlatforms
            if platforms.isEmpty {
                emptyHint("Drag with the Platform tool to define moving platforms.")
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(platforms.enumerated()), id: \.element.id) { index, platform in
                        entityRow(
                            title: "Platform \(index + 1)",
                            subtitle: "r\(platform.origin.row) c\(platform.origin.column) → r\(platform.target.row) c\(platform.target.column)",
                            color: viewModel.platformColor(for: index),
                            isSelected: viewModel.selectedPlatformID == platform.id
                        ) {
                            viewModel.selectPlatform(platform)
                        }
                    }
                }
            }
        }
    }

    private var spawnSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            header(title: "Spawn Points") { addSpawn() }

            let spawns = viewModel.blueprint.spawnPoints
            if spawns.isEmpty {
                emptyHint("No spawns yet. Use the Spawn tool or tap + to add one.")
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(spawns.enumerated()), id: \.element.id) { index, spawn in
                        entityRow(
                            title: spawn.name,
                            subtitle: "r\(spawn.coordinate.row) c\(spawn.coordinate.column)",
                            color: viewModel.spawnColor(for: index),
                            isSelected: viewModel.selectedSpawnID == spawn.id
                        ) {
                            viewModel.selectSpawn(spawn)
                            spawnNameDraft = spawn.name
                        }
                    }
                }
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Actions")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: viewModel.fillGround) {
                Label("Fill Ground", systemImage: "square.stack.3d.up.fill")
            }
            Button(action: viewModel.buildRampTestLayouts) {
                Label("Ramp Test Layout", systemImage: "triangle.lefthalf.filled")
            }
            Button(role: .destructive, action: viewModel.clearLevel) {
                Label("Clear Map", systemImage: "trash")
            }
        }
    }

    private func addSpawn() {
        viewModel.addSpawnAtCenter()
    }

    private func focusEditor() {
        editorFocused = true
    }

    private func focusEditorIfNeeded() {
        if !editorFocused {
            focusEditor()
        }
    }

    private func beginExport() {
        pendingExportDocument = MapFileDocument(document: viewModel.makeMapDocument())
        pendingExportFilename = viewModel.makeExportFilename()
        isShowingExporter = true
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                persistenceErrorMessage = "No file selected."
                return
            }
            loadMap(from: url)
        case .failure(let error):
            persistenceErrorMessage = error.localizedDescription
        }
    }

    private func loadMap(from url: URL) {
        var data: Data?
        let needsStop = url.startAccessingSecurityScopedResource()
        defer {
            if needsStop {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            data = try Data(contentsOf: url)
        } catch {
            persistenceErrorMessage = error.localizedDescription
            return
        }

        guard let data else {
            persistenceErrorMessage = "The selected file could not be read."
            return
        }

        do {
            try viewModel.importJSON(data)
        } catch {
            if let error = error as? MapDocumentError {
                persistenceErrorMessage = error.localizedDescription
            } else if error is DecodingError {
                persistenceErrorMessage = "The selected file is not a valid map." 
            } else {
                persistenceErrorMessage = error.localizedDescription
            }
        }
    }

    @discardableResult
    private func handleKeyboardEvent(phase: KeyboardInputPhase, event: KeyboardInput) -> Bool {
        switch phase {
        case .down:
            input.handleKeyDown(event)
            if handleEditorCommand(for: event) { return true }
            if !isPreviewing { input.drainPressedCommands() }
            return isHandledKey(event)
        case .up:
            input.handleKeyUp(event)
            if !isPreviewing { input.drainPressedCommands() }
            return isHandledKey(event)
        }
    }

    private func handleEditorCommand(for input: KeyboardInput) -> Bool {
        let normalized = input.characters.lowercased()
        let hasCommand = input.modifiers.contains(.command)
        let hasShift = input.modifiers.contains(.shift)

        var action: (() -> Void)?

        if input.key == .escape {
            action = {
                if viewModel.canCommitSelectionMove {
                    viewModel.cancelSelectionMove()
                } else if isPreviewing {
                    isPreviewing = false
                }
                focusEditor()
            }
        } else if hasCommand {
            if normalized.contains("z") {
                action = {
                    if hasShift {
                        if viewModel.canRedo { viewModel.redo() }
                    } else {
                        if viewModel.canUndo { viewModel.undo() }
                    }
                }
            } else if normalized.contains("y") {
                action = {
                    if viewModel.canRedo { viewModel.redo() }
                }
            } else if normalized.contains("r") {
                action = openPreviewIfPossible
            } else if normalized.contains("c") {
                action = {
                    if viewModel.hasSelection { viewModel.copySelection() }
                }
            } else if normalized.contains("x") {
                action = {
                    if viewModel.hasSelection { viewModel.cutSelection() }
                }
            } else if normalized.contains("v") {
                action = {
                    if viewModel.canPasteSelection { viewModel.pasteSelection() }
                }
            }
        } else if normalized == "\r" || normalized == "\n" {
            if viewModel.canCommitSelectionMove {
                action = {
                    viewModel.commitSelectionMove()
                }
            }
        }

        guard let action else { return false }

        DispatchQueue.main.async {
            action()
        }

        return true
    }

    private func openPreviewIfPossible() {
        guard !isPreviewing else { return }
        guard !viewModel.blueprint.spawnPoints.isEmpty else { return }
        isPreviewing = true
    }
}

extension SentryBlueprint.ProjectileKind {
    var displayLabel: String {
        switch self {
        case .bolt: return "Bolt"
        case .heatSeeking: return "Heat"
        case .laser: return "Laser"
        }
    }
}

private extension EnemyBlueprint.Behavior {
    var flatChaseRange: Double? {
        if case .chase(let range, _, _) = self { return range }
        return nil
    }

    var flatChaseMultiplier: Double? {
        if case .chase(_, let multiplier, _) = self { return multiplier }
        return nil
    }

    var flatChaseTolerance: Double? {
        if case .chase(_, _, let tolerance) = self { return tolerance }
        return nil
    }

    var flatFleeRange: Double? {
        if case .flee(let range, _, _) = self { return range }
        return nil
    }

    var flatFleeSafe: Double? {
        if case .flee(_, let safe, _) = self { return safe }
        return nil
    }

    var flatFleeRun: Double? {
        if case .flee(_, _, let run) = self { return run }
        return nil
    }

    var flatStrafeRange: Double? {
        if case .strafe(let range, _, _) = self { return range }
        return nil
    }

    var flatStrafeNear: Double? {
        if case .strafe(_, let preferred, _) = self { return preferred.lowerBound }
        return nil
    }

    var flatStrafeFar: Double? {
        if case .strafe(_, let preferred, _) = self { return preferred.upperBound }
        return nil
    }

    var flatStrafeSpeed: Double? {
        if case .strafe(_, _, let speed) = self { return speed }
        return nil
    }
}

extension EnemyBlueprint.Attack {
    var flatShooterSpeed: Double? {
        if case .shooter(let speed, _, _) = self { return speed }
        return nil
    }

    var flatShooterCooldown: Double? {
        if case .shooter(_, let cooldown, _) = self { return cooldown }
        return nil
    }

    var flatShooterRange: Double? {
        if case .shooter(_, _, let range) = self { return range }
        return nil
    }

    var flatMeleeRange: Double? {
        switch self {
        case .sword(let range, _, _), .punch(let range, _, _):
            return range
        default:
            return nil
        }
    }

    var flatMeleeCooldown: Double? {
        switch self {
        case .sword(_, let cooldown, _), .punch(_, let cooldown, _):
            return cooldown
        default:
            return nil
        }
    }

    var flatMeleeKnockback: Double? {
        switch self {
        case .sword(_, _, let knock), .punch(_, _, let knock):
            return knock
        default:
            return nil
        }
    }
}

extension EnemyBlueprint {
    var behaviorLabelPrefix: String {
        switch behavior {
        case .passive: return "P"
        case .chase: return "C"
        case .flee: return "F"
        case .strafe: return "R"
        }
    }
}

#Preview {
    MapEditorView()
        .frame(minWidth: 900, minHeight: 600)
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
