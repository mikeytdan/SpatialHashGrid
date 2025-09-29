// MapEditorView.swift
// SwiftUI editor for building tile maps and player spawns

import Combine
import SwiftUI

final class MapEditorViewModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case pencil
        case line
        case rectangle
        case eraser
        case rectErase
        case circle
        case spawn
        case platform

        var id: Tool { self }

        var label: String {
            switch self {
            case .pencil: return "Pencil"
            case .line: return "Line"
            case .rectangle: return "Rectangle"
            case .eraser: return "Eraser"
            case .rectErase: return "Rect Erase"
            case .circle: return "Circle"
            case .spawn: return "Spawn"
            case .platform: return "Platform"
            }
        }

        var systemImage: String {
            switch self {
            case .pencil: return "pencil"
            case .line: return "line.diagonal"
            case .rectangle: return "square.dashed"
            case .eraser: return "eraser"
            case .rectErase: return "square.dashed.inset.filled"
            case .circle: return "circle.dotted"
            case .spawn: return "figure.walk"
            case .platform: return "rectangle.3.group"
            }
        }
    }

    enum ShapeDrawMode: String, CaseIterable, Identifiable {
        case fill
        case stroke

        var id: ShapeDrawMode { self }

        var label: String {
            switch self {
            case .fill: return "Fill"
            case .stroke: return "Stroke"
            }
        }
    }

    @Published var blueprint: LevelBlueprint
    @Published var showGrid: Bool = true
    @Published var tool: Tool = .pencil
    @Published var drawMode: ShapeDrawMode = .fill
    @Published var levelName: String = "Untitled"
    @Published var selectedSpawnID: PlayerSpawnPoint.ID?
    @Published var selectedPlatformID: MovingPlatformBlueprint.ID?
    @Published var hoveredPoint: GridPoint?
    @Published var shapePreview: Set<GridPoint> = []
    @Published var zoom: Double = 1.0
    @Published var selectedTileKind: LevelTileKind = .stone

    private var lastPaintedPoint: GridPoint?
    private var dragStartPoint: GridPoint?
    private var undoStack: [LevelBlueprint] = []
    private var redoStack: [LevelBlueprint] = []
    private var platformDragContext: PlatformDragContext?

    private struct PlatformMoveContext {
        let platformID: MovingPlatformBlueprint.ID
        let size: GridSize
        let startOrigin: GridPoint
        let startTarget: GridPoint
        let startPoint: GridPoint
    }

    private enum PlatformDragContext {
        case create
        case move(PlatformMoveContext)
    }

    init() {
        var defaultBlueprint = LevelBlueprint(rows: 24, columns: 40, tileSize: 32)
        let groundRow = defaultBlueprint.rows - 1
        for column in 0..<defaultBlueprint.columns {
            defaultBlueprint.setTile(.stone, at: GridPoint(row: groundRow, column: column))
        }
        let spawn = defaultBlueprint.addSpawnPoint(at: GridPoint(row: groundRow - 2, column: 2))
        self.blueprint = defaultBlueprint
        self.selectedSpawnID = spawn?.id
        self.levelName = "Demo Level"
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var selectedSpawn: PlayerSpawnPoint? {
        guard let id = selectedSpawnID else { return nil }
        return blueprint.spawnPoint(id: id)
    }

    var selectedPlatform: MovingPlatformBlueprint? {
        guard let id = selectedPlatformID else { return nil }
        return blueprint.movingPlatform(id: id)
    }

    var tilePalette: [LevelTileKind] { LevelTileKind.palette }

    var paintTileKind: LevelTileKind {
        selectedTileKind == .empty ? .stone : selectedTileKind
    }

    func updateHover(_ point: GridPoint?) {
        hoveredPoint = point
    }

    func zoomIn() { zoom = min(zoom + 0.2, 3.0) }
    func zoomOut() { zoom = max(zoom - 0.2, 0.4) }

    func toggleGrid() { showGrid.toggle() }

    func clearLevel() {
        captureSnapshot()
        blueprint = LevelBlueprint(rows: blueprint.rows, columns: blueprint.columns, tileSize: blueprint.tileSize)
        shapePreview.removeAll()
        lastPaintedPoint = nil
        dragStartPoint = nil
        syncSelectedSpawn()
        syncSelectedPlatform()
        platformDragContext = nil
    }

    func fillGround() {
        captureSnapshot()
        let groundRow = blueprint.rows - 1
        for column in 0..<blueprint.columns {
            blueprint.setTile(paintTileKind, at: GridPoint(row: groundRow, column: column))
        }
    }

    func addSpawnAtCenter() {
        let point = GridPoint(row: max(0, blueprint.rows / 2), column: max(0, blueprint.columns / 2))
        if let spawn = addSpawn(at: point) {
            selectedSpawnID = spawn.id
            tool = .spawn
        }
    }

    func addSpawn(at point: GridPoint) -> PlayerSpawnPoint? {
        captureSnapshot()
        return insertSpawn(at: point)
    }

    func selectSpawn(_ spawn: PlayerSpawnPoint) {
        selectedSpawnID = spawn.id
        tool = .spawn
    }

    func renameSelectedSpawn(to name: String) {
        guard let selected = selectedSpawn else { return }
        guard selected.name != name else { return }
        captureSnapshot()
        blueprint.renameSpawn(id: selected.id, to: name)
    }

    func selectPlatform(_ platform: MovingPlatformBlueprint) {
        selectedPlatformID = platform.id
        tool = .platform
    }

    func removeSelectedSpawn() {
        guard let selected = selectedSpawn else { return }
        removeSpawn(selected)
    }

    func removeSpawn(_ spawn: PlayerSpawnPoint) {
        captureSnapshot()
        blueprint.removeSpawn(spawn)
        syncSelectedSpawn()
    }

    func removePlatform(_ platform: MovingPlatformBlueprint) {
        captureSnapshot()
        blueprint.removeMovingPlatform(id: platform.id)
        syncSelectedPlatform()
    }

    func updateSelectedPlatformTarget(row: Int? = nil, column: Int? = nil) {
        guard let platform = selectedPlatform else { return }
        let newRow = row ?? platform.target.row
        let newCol = column ?? platform.target.column
        let clampedRow = clampTargetRow(newRow, for: platform)
        let clampedCol = clampTargetColumn(newCol, for: platform)
        guard clampedRow != platform.target.row || clampedCol != platform.target.column else { return }
        captureSnapshot()
        blueprint.updateMovingPlatform(id: platform.id) { ref in
            ref.target = GridPoint(row: clampedRow, column: clampedCol)
        }
        syncSelectedPlatform()
    }

    func updateSelectedPlatformSpeed(_ speed: Double) {
        guard let platform = selectedPlatform else { return }
        let clamped = max(0.1, min(speed, 10.0))
        guard abs(platform.speed - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateMovingPlatform(id: platform.id) { ref in
            ref.speed = clamped
        }
        syncSelectedPlatform()
    }

    func handleDragBegan(at point: GridPoint) {
        guard blueprint.contains(point) else { return }
        captureSnapshot()
        dragStartPoint = point
        lastPaintedPoint = nil

        if tool == .platform {
            if let platform = platform(at: point) {
                selectedPlatformID = platform.id
                platformDragContext = .move(
                    PlatformMoveContext(
                        platformID: platform.id,
                        size: platform.size,
                        startOrigin: platform.origin,
                        startTarget: platform.target,
                        startPoint: point
                    )
                )
                shapePreview = pointsForRectangle(
                    from: platform.origin,
                    to: GridPoint(row: platform.origin.row + platform.size.rows - 1, column: platform.origin.column + platform.size.columns - 1),
                    mode: .stroke
                )
            } else {
                platformDragContext = .create
            }
        } else {
            platformDragContext = nil
        }

        applyDrag(at: point, isInitial: true)
    }

    func handleDragChanged(to point: GridPoint) {
        guard blueprint.contains(point) else { return }
        applyDrag(at: point, isInitial: false)
    }

    func handleDragEnded(at point: GridPoint?) {
        defer {
            lastPaintedPoint = nil
            dragStartPoint = nil
            shapePreview.removeAll()
            hoveredPoint = nil
            syncSelectedSpawn()
            syncSelectedPlatform()
        }

        guard let point else { return }
        guard blueprint.contains(point) else { return }

        let start = dragStartPoint ?? point

        let currentPlatformContext = platformDragContext
        switch tool {
        case .line:
            applyShape(pointsForLine(from: start, to: point), kind: paintTileKind)
        case .rectangle:
            applyShape(pointsForRectangle(from: start, to: point, mode: drawMode), kind: paintTileKind)
        case .rectErase:
            clearShape(pointsForRectangle(from: start, to: point, mode: drawMode))
        case .circle:
            applyShape(pointsForCircle(from: start, to: point, mode: drawMode), kind: paintTileKind)
        case .platform:
            if case .create = currentPlatformContext ?? .create {
                finalizePlatform(from: start, to: point)
            }
        default:
            break
        }

        platformDragContext = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(blueprint)
        blueprint = previous
        syncSelectedSpawn()
        syncSelectedPlatform()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(blueprint)
        blueprint = next
        syncSelectedSpawn()
        syncSelectedPlatform()
    }

    func spawnColor(for index: Int) -> Color {
        SpawnPalette.color(for: index)
    }

    func platformColor(for index: Int) -> Color {
        PlatformPalette.color(for: index)
    }

    private func applyDrag(at point: GridPoint, isInitial: Bool) {
        switch tool {
        case .pencil:
            paintSolid(at: point)
        case .line:
            shapePreview = pointsForLine(from: dragStartPoint ?? point, to: point)
        case .eraser:
            eraseTile(at: point)
        case .rectangle:
            shapePreview = pointsForRectangle(from: dragStartPoint ?? point, to: point, mode: drawMode)
        case .rectErase:
            shapePreview = pointsForRectangle(from: dragStartPoint ?? point, to: point, mode: drawMode)
        case .circle:
            shapePreview = pointsForCircle(from: dragStartPoint ?? point, to: point, mode: drawMode)
        case .spawn:
            moveSpawn(to: point, isInitial: isInitial)
        case .platform:
            switch platformDragContext {
            case .move(let context):
                movePlatform(context: context, to: point)
            default:
                shapePreview = pointsForRectangle(from: dragStartPoint ?? point, to: point, mode: .fill)
            }
        }
    }

    private func paintSolid(at point: GridPoint) {
        guard lastPaintedPoint != point else { return }
        lastPaintedPoint = point
        blueprint.setTile(paintTileKind, at: point)
    }

    private func eraseTile(at point: GridPoint) {
        guard lastPaintedPoint != point else { return }
        lastPaintedPoint = point
        blueprint.setTile(.empty, at: point)
    }

    private func moveSpawn(to point: GridPoint, isInitial: Bool) {
        if let id = selectedSpawnID, blueprint.spawnPoint(id: id) != nil {
            blueprint.updateSpawn(id: id, to: point)
        } else if isInitial, let newSpawn = insertSpawn(at: point) {
            selectedSpawnID = newSpawn.id
        }
    }

    private func applyShape(_ points: Set<GridPoint>, kind: LevelTileKind) {
        guard !points.isEmpty else { return }
        for point in points where blueprint.contains(point) {
            if kind.isSolid {
                blueprint.setTile(kind, at: point)
            } else {
                blueprint.setTile(.empty, at: point)
            }
        }
    }

    private func clearShape(_ points: Set<GridPoint>) {
        guard !points.isEmpty else { return }
        for point in points where blueprint.contains(point) {
            blueprint.setTile(.empty, at: point)
        }
    }

    private func finalizePlatform(from start: GridPoint, to end: GridPoint) {
        let minRow = min(start.row, end.row)
        let minCol = min(start.column, end.column)
        let maxRow = max(start.row, end.row)
        let maxCol = max(start.column, end.column)
        let size = GridSize(rows: maxRow - minRow + 1, columns: maxCol - minCol + 1)
        guard size.rows > 0, size.columns > 0 else { return }
        let origin = GridPoint(row: minRow, column: minCol)
        if let platform = insertPlatform(origin: origin, size: size, target: origin) {
            selectedPlatformID = platform.id
        }
    }

    private func movePlatform(context: PlatformMoveContext, to point: GridPoint) {
        guard blueprint.contains(point) else { return }
        var deltaRow = point.row - context.startPoint.row
        var deltaCol = point.column - context.startPoint.column

        let maxRow = blueprint.rows - context.size.rows
        let maxCol = blueprint.columns - context.size.columns

        var newOriginRow = min(max(context.startOrigin.row + deltaRow, 0), maxRow)
        var newOriginCol = min(max(context.startOrigin.column + deltaCol, 0), maxCol)

        deltaRow = newOriginRow - context.startOrigin.row
        deltaCol = newOriginCol - context.startOrigin.column

        var newTargetRow = min(max(context.startTarget.row + deltaRow, 0), maxRow)
        var newTargetCol = min(max(context.startTarget.column + deltaCol, 0), maxCol)

        let newOrigin = GridPoint(row: newOriginRow, column: newOriginCol)
        let newTarget = GridPoint(row: newTargetRow, column: newTargetCol)

        blueprint.updateMovingPlatform(id: context.platformID) { ref in
            ref.origin = newOrigin
            ref.target = newTarget
        }

        selectedPlatformID = context.platformID
        shapePreview = pointsForRectangle(
            from: newOrigin,
            to: GridPoint(row: newOrigin.row + context.size.rows - 1, column: newOrigin.column + context.size.columns - 1),
            mode: .stroke
        )
    }

    private func isPoint(_ point: GridPoint, inside platform: MovingPlatformBlueprint) -> Bool {
        let rowRange = platform.origin.row..<(platform.origin.row + platform.size.rows)
        let colRange = platform.origin.column..<(platform.origin.column + platform.size.columns)
        return rowRange.contains(point.row) && colRange.contains(point.column)
    }

    private func platform(at point: GridPoint) -> MovingPlatformBlueprint? {
        blueprint.movingPlatforms.first(where: { isPoint(point, inside: $0) })
    }

    private func pointsForRectangle(from start: GridPoint, to end: GridPoint, mode: ShapeDrawMode) -> Set<GridPoint> {
        var points: Set<GridPoint> = []
        let minRow = min(start.row, end.row)
        let maxRow = max(start.row, end.row)
        let minCol = min(start.column, end.column)
        let maxCol = max(start.column, end.column)

        for row in minRow...maxRow {
            for col in minCol...maxCol {
                let point = GridPoint(row: row, column: col)
                switch mode {
                case .fill:
                    points.insert(point)
                case .stroke:
                    if row == minRow || row == maxRow || col == minCol || col == maxCol {
                        points.insert(point)
                    }
                }
            }
        }
        return points
    }

    private func pointsForLine(from start: GridPoint, to end: GridPoint) -> Set<GridPoint> {
        var points: Set<GridPoint> = []
        let dx = abs(end.column - start.column)
        let sx = start.column < end.column ? 1 : -1
        let dy = -abs(end.row - start.row)
        let sy = start.row < end.row ? 1 : -1
        var err = dx + dy
        var x = start.column
        var y = start.row

        while true {
            points.insert(GridPoint(row: y, column: x))
            if x == end.column && y == end.row { break }
            let e2 = 2 * err
            if e2 >= dy {
                err += dy
                x += sx
            }
            if e2 <= dx {
                err += dx
                y += sy
            }
        }
        return points
    }

    private func pointsForCircle(from start: GridPoint, to end: GridPoint, mode: ShapeDrawMode) -> Set<GridPoint> {
        let minRow = min(start.row, end.row)
        let maxRow = max(start.row, end.row)
        let minCol = min(start.column, end.column)
        let maxCol = max(start.column, end.column)

        let diameterRows = maxRow - minRow + 1
        let diameterCols = maxCol - minCol + 1
        let radius = max(Double(max(diameterRows, diameterCols)) / 2.0, 0)
        let centerRow = Double(minRow) + Double(diameterRows) / 2.0 - 0.5
        let centerCol = Double(minCol) + Double(diameterCols) / 2.0 - 0.5

        switch mode {
        case .fill:
            return filledCirclePoints(centerRow: centerRow, centerCol: centerCol, radius: radius, rowRange: minRow...maxRow, colRange: minCol...maxCol)
        case .stroke:
            let outer = filledCirclePoints(centerRow: centerRow, centerCol: centerCol, radius: radius, rowRange: minRow...maxRow, colRange: minCol...maxCol)
            let inner = filledCirclePoints(centerRow: centerRow, centerCol: centerCol, radius: max(0, radius - 1.0), rowRange: minRow...maxRow, colRange: minCol...maxCol)
            return outer.subtracting(inner)
        }
    }

    private func filledCirclePoints(centerRow: Double, centerCol: Double, radius: Double, rowRange: ClosedRange<Int>, colRange: ClosedRange<Int>) -> Set<GridPoint> {
        guard radius >= 0 else { return [] }
        var points: Set<GridPoint> = []
        let radiusSquared = radius * radius
        for row in rowRange {
            let dy = (Double(row) + 0.5) - centerRow
            let dySquared = dy * dy
            if dySquared > radiusSquared { continue }
            for col in colRange {
                let dx = (Double(col) + 0.5) - centerCol
                if dx * dx + dySquared <= radiusSquared {
                    points.insert(GridPoint(row: row, column: col))
                }
            }
        }
        return points
    }

    private func captureSnapshot() {
        undoStack.append(blueprint)
        if undoStack.count > 200 {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    private func syncSelectedSpawn() {
        if let id = selectedSpawnID, blueprint.spawnPoint(id: id) != nil {
            return
        }
        selectedSpawnID = blueprint.spawnPoints.first?.id
    }

    @discardableResult
    private func insertSpawn(at point: GridPoint) -> PlayerSpawnPoint? {
        let spawn = blueprint.addSpawnPoint(at: point)
        syncSelectedSpawn()
        return spawn
    }

    @discardableResult
    private func insertPlatform(origin: GridPoint, size: GridSize, target: GridPoint, speed: Double = 1.0) -> MovingPlatformBlueprint? {
        guard let platform = blueprint.addMovingPlatform(origin: origin, size: size, target: target, speed: speed) else {
            return nil
        }
        syncSelectedPlatform()
        return platform
    }

    func platformTargetRowRange(_ platform: MovingPlatformBlueprint) -> ClosedRange<Int> {
        let maxRow = max(0, blueprint.rows - platform.size.rows)
        return 0...maxRow
    }

    func platformTargetColumnRange(_ platform: MovingPlatformBlueprint) -> ClosedRange<Int> {
        let maxCol = max(0, blueprint.columns - platform.size.columns)
        return 0...maxCol
    }

    private func clampTargetRow(_ row: Int, for platform: MovingPlatformBlueprint) -> Int {
        let range = platformTargetRowRange(platform)
        return min(max(row, range.lowerBound), range.upperBound)
    }

    private func clampTargetColumn(_ column: Int, for platform: MovingPlatformBlueprint) -> Int {
        let range = platformTargetColumnRange(platform)
        return min(max(column, range.lowerBound), range.upperBound)
    }

    private func syncSelectedPlatform() {
        if let id = selectedPlatformID, blueprint.movingPlatform(id: id) != nil {
            return
        }
        selectedPlatformID = blueprint.movingPlatforms.first?.id
    }
}

struct MapEditorView: View {
    @StateObject private var viewModel = MapEditorViewModel()
    @State private var isPreviewing = false
    @State private var spawnNameDraft: String = ""

    private let adapter = SpriteKitLevelPreviewAdapter()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(alignment: .top, spacing: 16) {
                ScrollView(.vertical, showsIndicators: true) {
                    controls
                        .padding(.vertical, 16)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .top)
                }
                .frame(minWidth: 300, maxHeight: .infinity)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                mapStage
                    .frame(minWidth: 520, minHeight: 520)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            floatingControls
                .padding(20)
        }
        .sheet(isPresented: $isPreviewing) {
            adapter.makePreview(for: viewModel.blueprint) {
                isPreviewing = false
            }
            .ignoresSafeArea()
        }
        .onChange(of: viewModel.selectedSpawnID) { _ in
            spawnNameDraft = viewModel.selectedSpawn?.name ?? ""
        }
        .onChange(of: viewModel.blueprint.spawnPoints) { _ in
            spawnNameDraft = viewModel.selectedSpawn?.name ?? ""
        }
        .onChange(of: viewModel.blueprint.movingPlatforms) { _ in
            guard !viewModel.blueprint.movingPlatforms.isEmpty else {
                viewModel.selectedPlatformID = nil
                return
            }
            if let selectedID = viewModel.selectedPlatformID,
               viewModel.blueprint.movingPlatforms.contains(where: { $0.id == selectedID }) {
                return
            }
            viewModel.selectedPlatformID = viewModel.blueprint.movingPlatforms.first?.id
        }
    }

    private var mapStage: some View {
        MapCanvasView(
            blueprint: viewModel.blueprint,
            previewTiles: viewModel.shapePreview,
            showGrid: viewModel.showGrid,
            zoom: viewModel.zoom,
            selectedSpawnID: viewModel.selectedSpawnID,
            selectedPlatformID: viewModel.selectedPlatformID,
            previewColor: viewModel.paintTileKind.fillColor,
            hoveredPoint: viewModel.hoveredPoint,
            onHover: viewModel.updateHover,
            onDragBegan: viewModel.handleDragBegan,
            onDragChanged: viewModel.handleDragChanged,
            onDragEnded: viewModel.handleDragEnded
        )
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 20) {
            levelNameSection
            tilePaletteSection
            toolsSection
            drawModeSection
            canvasControls
            platformSection
            spawnSection
            quickActions
            Spacer(minLength: 24)
        }
    }

    private var levelNameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Level Name")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $viewModel.levelName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var tilePaletteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tiles")
                .font(.caption)
                .foregroundStyle(.secondary)

            let columns = [GridItem(.adaptive(minimum: 52, maximum: 80), spacing: 8)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(viewModel.tilePalette, id: \.self) { tile in
                    Button {
                        viewModel.selectedTileKind = tile
                    } label: {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(tile.fillColor)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(tile.borderColor, lineWidth: 2)
                            )
                            .overlay(alignment: .topTrailing) {
                                if viewModel.selectedTileKind == tile {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.white)
                                        .shadow(radius: 2)
                                        .padding(4)
                                }
                            }
                            .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tile.displayName)
                }
            }

            Text("Selected: \(viewModel.selectedTileKind.displayName)")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                        .background(viewModel.tool == tool ? Color.accentColor.opacity(0.2) : Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var drawModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shape Mode")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Draw Mode", selection: $viewModel.drawMode) {
                ForEach(MapEditorViewModel.ShapeDrawMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var canvasControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Canvas")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(action: viewModel.zoomOut) { Image(systemName: "minus.magnifyingglass") }
                Button(action: viewModel.zoomIn) { Image(systemName: "plus.magnifyingglass") }
            }
            .buttonStyle(.bordered)
            .labelStyle(.iconOnly)

            HStack(spacing: 8) {
                Button(action: viewModel.undo) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!viewModel.canUndo)

                Button(action: viewModel.redo) {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!viewModel.canRedo)
            }
            .buttonStyle(.bordered)
        }
    }

    private var platformSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Platforms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.tool = .platform
                } label: {
                    Label("Platform Tool", systemImage: "hand.point.up.left.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
            }

            let platforms = viewModel.blueprint.movingPlatforms
            if platforms.isEmpty {
                Text("Use the Platform tool to drag out a platform, then adjust its path here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                let columns = Array(repeating: GridItem(.flexible(minimum: 32, maximum: 50), spacing: 8), count: 4)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(platforms.enumerated()), id: \.element.id) { index, platform in
                        Button {
                            viewModel.selectPlatform(platform)
                        } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(viewModel.platformColor(for: index).opacity(0.75))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(viewModel.selectedPlatformID == platform.id ? Color.white : Color.clear, lineWidth: 2)
                                )
                                .overlay(
                                    Text("\(index + 1)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let platform = viewModel.selectedPlatform {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Selected Platform")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("Origin: r\(platform.origin.row) c\(platform.origin.column)  •  Size: \(platform.size.columns)×\(platform.size.rows)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    let rowBinding = Binding<Int>(
                        get: { platform.target.row },
                        set: { viewModel.updateSelectedPlatformTarget(row: $0) }
                    )
                    let colBinding = Binding<Int>(
                        get: { platform.target.column },
                        set: { viewModel.updateSelectedPlatformTarget(column: $0) }
                    )

                    Stepper(value: rowBinding, in: viewModel.platformTargetRowRange(platform)) {
                        Text("Target Row: \(rowBinding.wrappedValue)")
                    }

                    Stepper(value: colBinding, in: viewModel.platformTargetColumnRange(platform)) {
                        Text("Target Column: \(colBinding.wrappedValue)")
                    }

                    let speedBinding = Binding<Double>(
                        get: { platform.speed },
                        set: { viewModel.updateSelectedPlatformSpeed($0) }
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: speedBinding, in: 0.1...5.0, step: 0.1)
                        Text(String(format: "Speed: %.1f tiles/s", speedBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Button(role: .destructive) {
                        viewModel.removePlatform(platform)
                    } label: {
                        Label("Remove Platform", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var spawnSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spawn Points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: addSpawn) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }

            if viewModel.blueprint.spawnPoints.isEmpty {
                Text("No spawns yet. Paint with the Spawn tool or tap + to add one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                let spawns = viewModel.blueprint.spawnPoints
                let columns = Array(repeating: GridItem(.flexible(minimum: 32, maximum: 50), spacing: 8), count: 4)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(spawns.indices), id: \.self) { index in
                        let spawn = spawns[index]
                        Button {
                            viewModel.selectSpawn(spawn)
                            spawnNameDraft = spawn.name
                        } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(viewModel.spawnColor(for: index).opacity(0.85))
                                .frame(width: 40, height: 40)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(viewModel.selectedSpawnID == spawn.id ? Color.white : Color.clear, lineWidth: 2)
                                )
                                .overlay(
                                    Text("\(index + 1)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if viewModel.selectedSpawn != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Selected Spawn")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    TextField("Name", text: $spawnNameDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { viewModel.renameSelectedSpawn(to: spawnNameDraft) }

                    HStack(spacing: 8) {
                        Button(action: { viewModel.renameSelectedSpawn(to: spawnNameDraft) }) {
                            Label("Save Name", systemImage: "checkmark.circle")
                        }
                        Button(role: .destructive, action: viewModel.removeSelectedSpawn) {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.bordered)
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
            Button(role: .destructive, action: viewModel.clearLevel) {
                Label("Clear Map", systemImage: "trash")
            }
        }
    }

    private func addSpawn() {
        viewModel.addSpawnAtCenter()
    }

    private var floatingControls: some View {
        HStack(spacing: 12) {
            Button(action: viewModel.toggleGrid) {
                Image(systemName: viewModel.showGrid ? "square.grid.3x3.fill" : "square.grid.3x3")
                    .font(.title3)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.showGrid ? "Hide Grid" : "Show Grid")

            Button(action: { isPreviewing = true }) {
                Image(systemName: "play.circle")
                    .font(.title3)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.blueprint.spawnPoints.isEmpty)
            .opacity(viewModel.blueprint.spawnPoints.isEmpty ? 0.4 : 1.0)
            .accessibilityLabel("Playtest Level")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .clipShape(Capsule())
        .shadow(radius: 6, y: 2)
    }
}

private struct MapCanvasView: View {
    let blueprint: LevelBlueprint
    let previewTiles: Set<GridPoint>
    let showGrid: Bool
    let zoom: Double
    let selectedSpawnID: PlayerSpawnPoint.ID?
    let selectedPlatformID: MovingPlatformBlueprint.ID?
    let previewColor: Color
    let hoveredPoint: GridPoint?
    let onHover: (GridPoint?) -> Void
    let onDragBegan: (GridPoint) -> Void
    let onDragChanged: (GridPoint) -> Void
    let onDragEnded: (GridPoint?) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let tileSize = tilePixelSize(in: geo.size)
            let mapSize = CGSize(width: tileSize * CGFloat(blueprint.columns), height: tileSize * CGFloat(blueprint.rows))
            let origin = CGPoint(x: (geo.size.width - mapSize.width) * 0.5, y: (geo.size.height - mapSize.height) * 0.5)

            Canvas { context, _ in
                let rect = CGRect(origin: origin, size: mapSize)
                context.fill(Path(rect), with: .color(Color.black.opacity(0.85)))

                for (point, kind) in blueprint.tileEntries() where kind.isSolid {
                    let tileRect = CGRect(
                        x: origin.x + CGFloat(point.column) * tileSize,
                        y: origin.y + CGFloat(point.row) * tileSize,
                        width: tileSize,
                        height: tileSize
                    )
                    let path = Path(tileRect)
                    context.fill(path, with: .color(kind.fillColor))
                    context.stroke(path, with: .color(kind.borderColor), lineWidth: 1)
                }

                for (index, platform) in blueprint.movingPlatforms.enumerated() {
                    let color = PlatformPalette.color(for: index)
                    let originRect = rectForPlatform(origin: platform.origin, size: platform.size, originPoint: origin, tileSize: tileSize)
                    context.fill(Path(originRect), with: .color(color.opacity(0.6)))
                    if platform.id == selectedPlatformID {
                        context.stroke(Path(originRect), with: .color(.white), lineWidth: 2)
                    }

                    let targetRect = rectForPlatform(origin: platform.target, size: platform.size, originPoint: origin, tileSize: tileSize)
                    if platform.target != platform.origin {
                        var path = Path()
                        path.move(to: originRect.center)
                        path.addLine(to: targetRect.center)
                        context.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 2)
                    }
                    context.stroke(Path(targetRect), with: .color(color.opacity(platform.id == selectedPlatformID ? 0.9 : 0.5)), lineWidth: platform.id == selectedPlatformID ? 2 : 1)
                }

                for (index, spawn) in blueprint.spawnPoints.enumerated() {
                    let tileRect = CGRect(
                        x: origin.x + CGFloat(spawn.coordinate.column) * tileSize,
                        y: origin.y + CGFloat(spawn.coordinate.row) * tileSize,
                        width: tileSize,
                        height: tileSize
                    )
                    let path = Path(ellipseIn: tileRect.insetBy(dx: tileSize * 0.25, dy: tileSize * 0.25))
                    let fill = SpawnPalette.color(for: index)
                    context.fill(path, with: .color(fill.opacity(0.85)))
                    if spawn.id == selectedSpawnID {
                        context.stroke(path, with: .color(Color.white), lineWidth: 2)
                    }
                }

                if !previewTiles.isEmpty {
                    for point in previewTiles where blueprint.contains(point) {
                        let tileRect = CGRect(
                            x: origin.x + CGFloat(point.column) * tileSize,
                            y: origin.y + CGFloat(point.row) * tileSize,
                            width: tileSize,
                            height: tileSize
                        )
                        context.fill(Path(tileRect), with: .color(previewColor.opacity(0.35)))
                    }
                }

                if showGrid {
                    drawGrid(context: &context, origin: origin, tileSize: tileSize, mapSize: mapSize)
                }

                if let hovered = hoveredPoint, blueprint.contains(hovered) {
                    let highlight = CGRect(
                        x: origin.x + CGFloat(hovered.column) * tileSize,
                        y: origin.y + CGFloat(hovered.row) * tileSize,
                        width: tileSize,
                        height: tileSize
                    )
                    context.stroke(Path(highlight), with: .color(Color.yellow), lineWidth: 2)
                }
            }
            .gesture(dragGesture(origin: origin, tileSize: tileSize, mapSize: mapSize))
            .onHover { hovering in
#if os(macOS)
                if !hovering {
                    onHover(nil)
                }
#endif
            }
        }
    }

    private func tilePixelSize(in size: CGSize) -> CGFloat {
        let base = min(size.width / CGFloat(blueprint.columns), size.height / CGFloat(blueprint.rows))
        return base * CGFloat(zoom)
    }

    private func dragGesture(origin: CGPoint, tileSize: CGFloat, mapSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let location = CGPoint(x: value.location.x - origin.x, y: value.location.y - origin.y)
                guard let point = pointForLocation(location, tileSize: tileSize, mapSize: mapSize) else {
                    onHover(nil)
                    return
                }
                onHover(point)
                if !isDragging {
                    isDragging = true
                    onDragBegan(point)
                } else {
                    onDragChanged(point)
                }
            }
            .onEnded { value in
                isDragging = false
                let location = CGPoint(x: value.location.x - origin.x, y: value.location.y - origin.y)
                let point = pointForLocation(location, tileSize: tileSize, mapSize: mapSize)
                onDragEnded(point)
                onHover(nil)
            }
    }

    private func pointForLocation(_ location: CGPoint, tileSize: CGFloat, mapSize: CGSize) -> GridPoint? {
        guard location.x >= 0, location.y >= 0, location.x < mapSize.width, location.y < mapSize.height else {
            return nil
        }
        let column = Int(location.x / tileSize)
        let row = Int(location.y / tileSize)
        return GridPoint(row: row, column: column)
    }

    private func rectForPlatform(origin platformOrigin: GridPoint, size: GridSize, originPoint: CGPoint, tileSize: CGFloat) -> CGRect {
        let x = originPoint.x + CGFloat(platformOrigin.column) * tileSize
        let y = originPoint.y + CGFloat(platformOrigin.row) * tileSize
        let width = CGFloat(size.columns) * tileSize
        let height = CGFloat(size.rows) * tileSize
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func drawGrid(context: inout GraphicsContext, origin: CGPoint, tileSize: CGFloat, mapSize: CGSize) {
        let gridColor = Color.white.opacity(0.15)
        var path = Path()
        for column in 0...blueprint.columns {
            let x = origin.x + CGFloat(column) * tileSize
            path.move(to: CGPoint(x: x, y: origin.y))
            path.addLine(to: CGPoint(x: x, y: origin.y + mapSize.height))
        }
        for row in 0...blueprint.rows {
            let y = origin.y + CGFloat(row) * tileSize
            path.move(to: CGPoint(x: origin.x, y: y))
            path.addLine(to: CGPoint(x: origin.x + mapSize.width, y: y))
        }
        context.stroke(path, with: .color(gridColor), lineWidth: 1)
    }
}

#Preview {
    MapEditorView()
        .frame(minWidth: 900, minHeight: 600)
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
