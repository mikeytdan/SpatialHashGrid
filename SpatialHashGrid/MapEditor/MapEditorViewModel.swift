// MapEditorView.swift
// SwiftUI editor for building tile maps and player spawns

import Combine
import SwiftUI

struct MapEditorSelectionOffset: Equatable {
    var row: Int
    var column: Int

    static let zero = MapEditorSelectionOffset(row: 0, column: 0)

    func adding(row deltaRow: Int, column deltaColumn: Int) -> MapEditorSelectionOffset {
        MapEditorSelectionOffset(row: row + deltaRow, column: column + deltaColumn)
    }
}

struct MapEditorSelectionBounds: Equatable {
    var minRow: Int
    var maxRow: Int
    var minColumn: Int
    var maxColumn: Int

    var width: Int { max(0, maxColumn - minColumn + 1) }
    var height: Int { max(0, maxRow - minRow + 1) }

    var isValid: Bool { minRow <= maxRow && minColumn <= maxColumn }

    func contains(_ point: GridPoint) -> Bool {
        guard isValid else { return false }
        return point.row >= minRow && point.row <= maxRow && point.column >= minColumn && point.column <= maxColumn
    }

    func offsetting(by offset: MapEditorSelectionOffset) -> MapEditorSelectionBounds {
        MapEditorSelectionBounds(
            minRow: minRow + offset.row,
            maxRow: maxRow + offset.row,
            minColumn: minColumn + offset.column,
            maxColumn: maxColumn + offset.column
        )
    }
}

struct MapEditorSelectionRenderState {
    let bounds: MapEditorSelectionBounds
    let offset: MapEditorSelectionOffset
    let tiles: [GridPoint: LevelTileKind]
    let spawns: [PlayerSpawnPoint]
    let platforms: [MovingPlatformBlueprint]
    let sentries: [SentryBlueprint]
    let enemies: [EnemyBlueprint]
    let mask: MapEditorViewModel.SelectionMask
    let source: MapEditorViewModel.MultiSelection.Source

    var hasContent: Bool {
        !tiles.isEmpty || !spawns.isEmpty || !platforms.isEmpty || !sentries.isEmpty || !enemies.isEmpty
    }
}

final class MapEditorViewModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case select
        case pencil
        case flood
        case line
        case rectangle
        case eraser
        case rectErase
        case circle
        case spawn
        case platform
        case sentry
        case enemy

        var id: Tool { self }

        var label: String {
            switch self {
            case .select: return "Select"
            case .pencil: return "Pencil"
            case .flood: return "Flood Fill"
            case .line: return "Line"
            case .rectangle: return "Rectangle"
            case .eraser: return "Eraser"
            case .rectErase: return "Rect Erase"
            case .circle: return "Circle"
            case .spawn: return "Spawn"
            case .platform: return "Platform"
            case .sentry: return "Sentry"
            case .enemy: return "Enemy"
            }
        }

        var systemImage: String {
            switch self {
            case .select: return "cursorarrow.rays"
            case .pencil: return "pencil"
            case .flood: return "paintbrush.pointed.fill"
            case .line: return "line.diagonal"
            case .rectangle: return "square.dashed"
            case .eraser: return "eraser"
            case .rectErase: return "square.dashed.inset.filled"
            case .circle: return "circle.dotted"
            case .spawn: return "figure.walk"
            case .platform: return "rectangle.3.group"
            case .sentry: return "dot.radiowaves.right"
            case .enemy: return "figure.walk"
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

    enum EnemyMovementChoice: String, CaseIterable, Identifiable {
        case idle
        case patrolHorizontal
        case patrolVertical
        case perimeter
        case wallBounce

        var id: String { rawValue }

        var label: String {
            switch self {
            case .idle: return "Idle"
            case .patrolHorizontal: return "Patrol Horizontal"
            case .patrolVertical: return "Patrol Vertical"
            case .perimeter: return "Perimeter"
            case .wallBounce: return "Wall Bounce"
            }
        }
    }

    enum EnemyBehaviorChoice: String, CaseIterable, Identifiable {
        case passive
        case chase
        case flee
        case strafe

        var id: String { rawValue }

        var label: String {
            switch self {
            case .passive: return "Passive"
            case .chase: return "Chase"
            case .flee: return "Flee"
            case .strafe: return "Strafe & Shoot"
            }
        }
    }

    enum EnemyAttackChoice: String, CaseIterable, Identifiable {
        case none
        case shooter
        case sword
        case punch

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: return "None"
            case .shooter: return "Shooter"
            case .sword: return "Sword"
            case .punch: return "Punch"
            }
        }
    }

    enum Selection: Equatable {
        case spawn(PlayerSpawnPoint.ID)
        case platform(MovingPlatformBlueprint.ID)
        case sentry(SentryBlueprint.ID)
        case enemy(EnemyBlueprint.ID)
        case none

        var spawnID: PlayerSpawnPoint.ID? {
            if case let .spawn(id) = self { return id }
            return nil
        }

        var platformID: MovingPlatformBlueprint.ID? {
            if case let .platform(id) = self { return id }
            return nil
        }

        var sentryID: SentryBlueprint.ID? {
            if case let .sentry(id) = self { return id }
            return nil
        }

        var enemyID: EnemyBlueprint.ID? {
            if case let .enemy(id) = self { return id }
            return nil
        }
    }

    struct SelectionMask: OptionSet {
        let rawValue: Int

        static let tiles = SelectionMask(rawValue: 1 << 0)
        static let spawns = SelectionMask(rawValue: 1 << 1)
        static let platforms = SelectionMask(rawValue: 1 << 2)
        static let sentries = SelectionMask(rawValue: 1 << 3)
        static let enemies = SelectionMask(rawValue: 1 << 4)

        static let entities: SelectionMask = [.spawns, .platforms, .sentries, .enemies]
        static let everything: SelectionMask = [.tiles, .entities]

        var includesTiles: Bool { contains(.tiles) }
        var includesEntities: Bool { !intersection(.entities).isEmpty }
    }

    struct MultiSelection: Equatable {
        enum Source: Equatable {
            case existing
            case clipboard
        }

        var bounds: MapEditorSelectionBounds
        var tiles: [GridPoint: LevelTileKind]
        var spawns: [PlayerSpawnPoint]
        var platforms: [MovingPlatformBlueprint]
        var sentries: [SentryBlueprint]
        var enemies: [EnemyBlueprint]
        var mask: SelectionMask
        var offset: MapEditorSelectionOffset = .zero
        var source: Source = .existing

        var isEmpty: Bool {
            tiles.isEmpty && spawns.isEmpty && platforms.isEmpty && sentries.isEmpty && enemies.isEmpty
        }

        func contains(_ point: GridPoint) -> Bool {
            bounds.offsetting(by: offset).contains(point)
        }

        func offsetting(by offset: MapEditorSelectionOffset) -> MultiSelection {
            var copy = self
            copy.offset = copy.offset.adding(row: offset.row, column: offset.column)
            return copy
        }
    }

    @Published var blueprint: LevelBlueprint {
        didSet {
            guard !isApplyingLoadedDocument else { return }
            scheduleAutosave()
        }
    }
    @Published var showGrid: Bool = true
    @Published var tool: Tool = .pencil {
        didSet {
            guard tool != oldValue else { return }
            handleToolChanged(from: oldValue, to: tool)
        }
    }
    @Published var drawMode: ShapeDrawMode = .fill
    @Published var levelName: String = "Untitled" {
        didSet {
            guard !isApplyingLoadedDocument else { return }
            scheduleAutosave()
        }
    }
    @Published var hoveredPoint: GridPoint?
    @Published var shapePreview: Set<GridPoint> = []
    @Published var zoom: Double = 1.0
    @Published var selectedTileKind: LevelTileKind = .stone
    @Published private(set) var selection: Selection = .none
    @Published var selectionMask: SelectionMask = .everything {
        didSet {
            guard selectionMask != oldValue else { return }
            if let selection = multiSelection {
                let currentBounds = selection.bounds
                let currentOffset = selection.offset
                applySelection(bounds: currentBounds, mask: selectionMask)
                if currentOffset != .zero {
                    updateSelectionOffset(currentOffset)
                }
            }
        }
    }
    @Published private(set) var multiSelection: MultiSelection?
    @Published private(set) var selectionRenderState: MapEditorSelectionRenderState?

    private var lastPaintedPoint: GridPoint?
    private var dragStartPoint: GridPoint?
    private var undoStack: [LevelBlueprint] = []
    private var redoStack: [LevelBlueprint] = []
    private var platformDragContext: PlatformDragContext?
    private var spawnDragID: PlayerSpawnPoint.ID?
    private var sentryDragID: SentryBlueprint.ID?
    private var enemyDragID: EnemyBlueprint.ID?
    private var spawnDragCaptured = false
    private var platformDragCaptured = false
    private var sentryDragCaptured = false
    private var enemyDragCaptured = false
    private let persistence = MapPersistenceController.shared
    private var autosaveWorkItem: DispatchWorkItem?
    private var isApplyingLoadedDocument = false
    private var selectionClipboard: MultiSelection?
    private var selectionDragContext: SelectionDragContext?
    private var toolBeforeDragOverride: Tool?

    private enum SelectionDragContext {
        case marquee(start: GridPoint)
        case move(start: GridPoint, initialOffset: MapEditorSelectionOffset)
    }

    var selectedSpawnID: PlayerSpawnPoint.ID? {
        get { selection.spawnID }
        set {
            if let id = newValue {
                selection = .spawn(id)
            } else if case .spawn = selection {
                selection = .none
            }
        }
    }

    var selectedPlatformID: MovingPlatformBlueprint.ID? {
        get { selection.platformID }
        set {
            if let id = newValue {
                selection = .platform(id)
            } else if case .platform = selection {
                selection = .none
            }
        }
    }

    var selectedSentryID: SentryBlueprint.ID? {
        get { selection.sentryID }
        set {
            if let id = newValue {
                selection = .sentry(id)
            } else if case .sentry = selection {
                selection = .none
            }
        }
    }

    var selectedEnemyID: EnemyBlueprint.ID? {
        get { selection.enemyID }
        set {
            if let id = newValue {
                selection = .enemy(id)
            } else if case .enemy = selection {
                selection = .none
            }
        }
    }

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

    private static func makeDefaultBlueprint() -> LevelBlueprint {
        var blueprint = LevelBlueprint(rows: 24, columns: 40, tileSize: 32)
        let groundRow = blueprint.rows - 1
        for column in 0..<blueprint.columns {
            blueprint.setTile(.stone, at: GridPoint(row: groundRow, column: column))
        }
        _ = blueprint.addSpawnPoint(at: GridPoint(row: groundRow - 2, column: 2))
        return blueprint
    }

    init() {
        let defaultBlueprint = MapEditorViewModel.makeDefaultBlueprint()
        self.blueprint = defaultBlueprint
        self.levelName = "Demo Level"
        if let first = defaultBlueprint.spawnPoints.first?.id {
            self.selection = .spawn(first)
        } else {
            self.selection = .none
        }
        var didLoadAutosave = false
        if let document = persistence.loadAutosave() {
            isApplyingLoadedDocument = true
            blueprint = document.blueprint
            if let name = document.metadata?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                levelName = name
            }
            selection = .none
            syncSelectionState()
            isApplyingLoadedDocument = false
            didLoadAutosave = true
        }

        if !didLoadAutosave {
            scheduleAutosave()
        }

        syncSelectionState()
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

    var selectedSentry: SentryBlueprint? {
        guard let id = selectedSentryID else { return nil }
        return blueprint.sentry(id: id)
    }

    var selectedEnemy: EnemyBlueprint? {
        guard let id = selectedEnemyID else { return nil }
        return blueprint.enemy(id: id)
    }

    var tilePalette: [LevelTileKind] { LevelTileKind.palette }

    var paintTileKind: LevelTileKind {
        selectedTileKind == .empty ? .stone : selectedTileKind
    }

    var hasSelection: Bool { multiSelection != nil }
    var canCommitSelectionMove: Bool { hasPendingSelectionMove }
    var canPasteSelection: Bool { selectionClipboard != nil }

    func toggleSelectedRampOrientation() {
        guard let flipped = selectedTileKind.flippedRamp else { return }
        selectedTileKind = flipped
    }

    func updateHover(_ point: GridPoint?) {
        hoveredPoint = point
    }

    func zoomIn() { zoom = min(zoom + 0.2, 3.0) }
    func zoomOut() { zoom = max(zoom - 0.2, 0.4) }
    func resetZoom() { zoom = 1.0 }

    func toggleGrid() { showGrid.toggle() }

    func clearLevel() {
        captureSnapshot()
        blueprint = LevelBlueprint(rows: blueprint.rows, columns: blueprint.columns, tileSize: blueprint.tileSize)
        shapePreview.removeAll()
        lastPaintedPoint = nil
        dragStartPoint = nil
        syncSelectionState()
        platformDragContext = nil
        spawnDragID = nil
        spawnDragCaptured = false
        platformDragCaptured = false
        sentryDragCaptured = false
        enemyDragCaptured = false
        sentryDragID = nil
        enemyDragID = nil
    }

    func fillGround() {
        captureSnapshot()
        let groundRow = blueprint.rows - 1
        for column in 0..<blueprint.columns {
            blueprint.setTile(paintTileKind, at: GridPoint(row: groundRow, column: column))
        }
    }

    func buildRampTestLayouts() {
        captureSnapshot()

        let baseRow = max(2, blueprint.rows - 2)
        let startColumn = max(1, blueprint.columns / 4)
        let width = min(14, blueprint.columns - startColumn)
//        let height = 6

//        for row in max(0, baseRow - height)...min(blueprint.rows - 1, baseRow + 1) {
//            for column in startColumn..<min(blueprint.columns, startColumn + width) {
//                blueprint.setTile(.empty, at: GridPoint(row: row, column: column))
//            }
//        }

        let scenarios: [(offset: Int, includeExtra: Bool)] = [
            (offset: 0, includeExtra: false),
            (offset: 8, includeExtra: true),
            (offset: 15, includeExtra: false)
        ]

        for scenario in scenarios {
            let col0 = startColumn + scenario.offset
            guard col0 + 2 < blueprint.columns else { continue }
            placeUpRightRampPair(baseRow: baseRow, column: col0, includeExtraTile: scenario.includeExtra)
        }

        let mirrorColumn = startColumn + min(3, max(0, width - 4))
        if mirrorColumn + 1 < blueprint.columns {
            placeUpLeftRampPair(baseRow: baseRow, column: mirrorColumn, includeExtraTile: true)
        }
    }

    private func placeUpRightRampPair(baseRow: Int, column: Int, includeExtraTile: Bool) {
        let lower = GridPoint(row: baseRow, column: column)
        let upper = GridPoint(row: max(0, baseRow - 1), column: column + 1)
        let under = GridPoint(row: baseRow, column: column + 1)

        blueprint.setTile(.rampUpRight, at: lower)
        blueprint.setTile(.rampUpRight, at: upper)
        blueprint.setTile(.stone, at: under)

        if includeExtraTile {
            let extra = GridPoint(row: baseRow, column: column + 2)
            blueprint.setTile(.stone, at: extra)
        }
    }

    private func placeUpLeftRampPair(baseRow: Int, column: Int, includeExtraTile: Bool) {
        let lower = GridPoint(row: baseRow, column: min(blueprint.columns - 1, column + 1))
        let upper = GridPoint(row: max(0, baseRow - 1), column: column)
        let under = GridPoint(row: baseRow, column: column)

        blueprint.setTile(.rampUpLeft, at: lower)
        blueprint.setTile(.rampUpLeft, at: upper)
        blueprint.setTile(.stone, at: under)

        if includeExtraTile {
            let extra = GridPoint(row: baseRow, column: max(0, column - 1))
            blueprint.setTile(.stone, at: extra)
        }
    }

    func addSpawnAtCenter() {
        let point = GridPoint(row: max(0, blueprint.rows / 2), column: max(0, blueprint.columns / 2))
        if addSpawn(at: point) != nil {
            tool = .spawn
        }
    }

    func addPlatformAtCenter() {
        guard blueprint.rows > 0, blueprint.columns > 0 else { return }
        let size = GridSize(rows: 1, columns: min(3, blueprint.columns))
        let originRow = max(0, min(blueprint.rows - size.rows, blueprint.rows / 2))
        let originColumn = max(0, min(blueprint.columns - size.columns, blueprint.columns / 2 - size.columns / 2))
        let origin = GridPoint(row: originRow, column: originColumn)
        let maxTargetColumn = blueprint.columns - size.columns
        let desiredTargetColumn = min(maxTargetColumn, origin.column + max(2, size.columns + 1))
        let target = GridPoint(row: origin.row, column: desiredTargetColumn)

        captureSnapshot()
        if insertPlatform(
            origin: origin,
            size: size,
            target: target,
            speed: 1.0
        ) != nil {
            tool = .platform
        } else {
            _ = undoStack.popLast()
        }
    }

    func addSpawn(at point: GridPoint) -> PlayerSpawnPoint? {
        captureSnapshot()
        return insertSpawn(at: point)
    }

    func selectSpawn(_ spawn: PlayerSpawnPoint) {
        selection = .spawn(spawn.id)
        tool = .spawn
    }

    func renameSelectedSpawn(to name: String) {
        guard let selected = selectedSpawn else { return }
        guard selected.name != name else { return }
        captureSnapshot()
        blueprint.renameSpawn(id: selected.id, to: name)
    }

    func selectPlatform(_ platform: MovingPlatformBlueprint) {
        selection = .platform(platform.id)
        tool = .platform
    }

    func removeSelectedSpawn() {
        guard let selected = selectedSpawn else { return }
        removeSpawn(selected)
    }

    func removeSpawn(_ spawn: PlayerSpawnPoint) {
        captureSnapshot()
        blueprint.removeSpawn(spawn)
        syncSelectionState()
    }

    func sentryColor(for index: Int) -> Color {
        SentryPalette.color(for: index)
    }

    func selectSentry(_ sentry: SentryBlueprint) {
        selection = .sentry(sentry.id)
        tool = .sentry
    }

    func addSentryAtCenter() {
        let center = GridPoint(row: blueprint.rows / 2, column: blueprint.columns / 2)
        let target = blueprint.contains(center) ? center : nil
        let placement = target ?? findVacantSentryCoordinate(near: GridPoint(row: blueprint.rows / 2, column: blueprint.columns / 2))
        guard let coordinate = placement else { return }
        captureSnapshot()
        if insertSentry(at: coordinate) != nil {
            tool = .sentry
        } else {
            _ = undoStack.popLast()
        }
    }

    func removeSelectedSentry() {
        guard let sentry = selectedSentry else { return }
        removeSentry(sentry)
    }

    func removeSentry(_ sentry: SentryBlueprint) {
        captureSnapshot()
        blueprint.removeSentry(id: sentry.id)
        syncSelectionState()
    }

    func duplicateSelectedSentry() {
        guard let sentry = selectedSentry else { return }
        guard let destination = findVacantSentryCoordinate(near: sentry.coordinate) else { return }
        let duplicate = SentryBlueprint(
            coordinate: destination,
            scanRange: sentry.scanRange,
            scanCenterDegrees: sentry.scanCenterDegrees,
            scanArcDegrees: sentry.scanArcDegrees,
            sweepSpeedDegreesPerSecond: sentry.sweepSpeedDegreesPerSecond,
            fireCooldown: sentry.fireCooldown,
            projectileSpeed: sentry.projectileSpeed,
            projectileSize: sentry.projectileSize,
            projectileLifetime: sentry.projectileLifetime,
            projectileBurstCount: sentry.projectileBurstCount,
            projectileSpreadDegrees: sentry.projectileSpreadDegrees,
            aimToleranceDegrees: sentry.aimToleranceDegrees,
            initialFacingDegrees: sentry.initialFacingDegrees,
            projectileKind: sentry.projectileKind,
            heatSeekingTurnRateDegreesPerSecond: sentry.heatSeekingTurnRateDegreesPerSecond
        )
        captureSnapshot()
        if let created = blueprint.addSentry(duplicate) {
            selectedSentryID = created.id
            syncSelectionState()
        }
    }

    func updateSelectedSentryRange(_ range: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(1.0, min(range, 32.0))
        guard abs(sentry.scanRange - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.scanRange = clamped
        }
        syncSelectionState()
    }

    func updateSelectedSentryCenter(_ degrees: Double) {
        guard let sentry = selectedSentry else { return }
        let normalized = max(-180.0, min(degrees, 180.0))
        guard abs(sentry.scanCenterDegrees - normalized) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.scanCenterDegrees = normalized
            ref.initialFacingDegrees = clampSentryInitialAngle(
                center: normalized,
                arc: ref.scanArcDegrees,
                desired: ref.initialFacingDegrees
            )
        }
        syncSelectionState()
    }

    func updateSelectedSentryArc(_ degrees: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(10.0, min(degrees, 240.0))
        guard abs(sentry.scanArcDegrees - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.scanArcDegrees = clamped
            ref.initialFacingDegrees = clampSentryInitialAngle(
                center: ref.scanCenterDegrees,
                arc: clamped,
                desired: ref.initialFacingDegrees
            )
        }
        syncSelectionState()
    }

    func updateSelectedSentryInitialAngle(_ degrees: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = clampSentryInitialAngle(
            center: sentry.scanCenterDegrees,
            arc: sentry.scanArcDegrees,
            desired: degrees
        )
        guard abs(sentry.initialFacingDegrees - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.initialFacingDegrees = clamped
        }
        syncSelectionState()
    }

    func selectEnemy(_ enemy: EnemyBlueprint) {
        selection = .enemy(enemy.id)
        tool = .enemy
    }

    func addEnemyAtCenter() {
        let point = GridPoint(row: blueprint.rows / 2, column: blueprint.columns / 2)
        if let created = insertEnemy(at: point) {
            selection = .enemy(created.id)
            tool = .enemy
        }
    }

    func removeSelectedEnemy() {
        guard let enemy = selectedEnemy else { return }
        removeEnemy(enemy)
    }

    func removeEnemy(_ enemy: EnemyBlueprint) {
        captureSnapshot()
        blueprint.removeEnemy(id: enemy.id)
        syncSelectionState()
    }

    func duplicateSelectedEnemy() {
        guard let enemy = selectedEnemy else { return }
        guard let destination = findVacantEnemyCoordinate(near: enemy.coordinate) else { return }
        var duplicate = enemy
        duplicate.coordinate = destination
        duplicate.id = UUID()
        captureSnapshot()
        if let created = blueprint.addEnemy(duplicate) {
            selectedEnemyID = created.id
            syncSelectionState()
        }
    }

    var selectedEnemyMovementChoice: EnemyMovementChoice {
        guard let enemy = selectedEnemy else { return .idle }
        switch enemy.movement {
        case .idle: return .idle
        case .patrolHorizontal: return .patrolHorizontal
        case .patrolVertical: return .patrolVertical
        case .perimeter: return .perimeter
        case .waypoints: return .patrolHorizontal
        case .wallBounce: return .wallBounce
        }
    }

    func setSelectedEnemyMovementChoice(_ choice: EnemyMovementChoice) {
        mutateSelectedEnemy { ref in
            switch choice {
            case .idle:
                ref.movement = .idle
            case .patrolHorizontal:
                ref.movement = .patrolHorizontal(span: 120, speed: 100)
            case .patrolVertical:
                ref.movement = .patrolVertical(span: 120, speed: 100)
            case .perimeter:
                ref.movement = .perimeter(width: 160, height: 120, speed: 110, clockwise: true)
            case .wallBounce:
                ref.movement = .wallBounce(axis: .horizontal, speed: 160)
            }
        }
    }

    var selectedEnemyBehaviorChoice: EnemyBehaviorChoice {
        guard let enemy = selectedEnemy else { return .passive }
        switch enemy.behavior {
        case .passive: return .passive
        case .chase: return .chase
        case .flee: return .flee
        case .strafe: return .strafe
        }
    }

    func setSelectedEnemyBehaviorChoice(_ choice: EnemyBehaviorChoice) {
        mutateSelectedEnemy { ref in
            switch choice {
            case .passive:
                ref.behavior = .passive
            case .chase:
                ref.behavior = .chase(range: 320, speedMultiplier: 1.35, verticalTolerance: 180)
            case .flee:
                ref.behavior = .flee(range: 280, safeDistance: 220, runMultiplier: 1.8)
            case .strafe:
                ref.behavior = .strafe(range: 360, preferred: 140...260, strafeSpeed: 140)
            }
        }
    }

    var selectedEnemyAttackChoice: EnemyAttackChoice {
        guard let enemy = selectedEnemy else { return .none }
        switch enemy.attack {
        case .none: return .none
        case .shooter: return .shooter
        case .sword: return .sword
        case .punch: return .punch
        }
    }

    func setSelectedEnemyAttackChoice(_ choice: EnemyAttackChoice) {
        mutateSelectedEnemy { ref in
            switch choice {
            case .none:
                ref.attack = .none
            case .shooter:
                ref.attack = .shooter(speed: 420, cooldown: 1.1, range: 420)
            case .sword:
                ref.attack = .sword(range: 36, cooldown: 1.0, knockback: 220)
            case .punch:
                ref.attack = .punch(range: 32, cooldown: 1.1, knockback: 180)
            }
        }
    }

    func updateSelectedEnemySizeWidth(_ width: Double) {
        guard let enemy = selectedEnemy else { return }
        let clamped = max(20, min(width, 160))
        guard abs(enemy.size.x - clamped) > 0.001 else { return }
        mutateSelectedEnemy { ref in
            ref.size.x = clamped
        }
    }

    func updateSelectedEnemySizeHeight(_ height: Double) {
        guard let enemy = selectedEnemy else { return }
        let clamped = max(20, min(height, 220))
        guard abs(enemy.size.y - clamped) > 0.001 else { return }
        mutateSelectedEnemy { ref in
            ref.size.y = clamped
        }
    }

    func updateSelectedEnemyAcceleration(_ acceleration: Double) {
        guard let enemy = selectedEnemy else { return }
        let clamped = max(2, min(acceleration, 40))
        guard abs(enemy.acceleration - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.acceleration = clamped
        }
    }

    func updateSelectedEnemyMaxSpeed(_ speed: Double) {
        guard let enemy = selectedEnemy else { return }
        let clamped = max(60, min(speed, 600))
        guard abs(enemy.maxSpeed - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.maxSpeed = clamped
        }
    }

    func updateSelectedEnemyGravityEnabled(_ enabled: Bool) {
        guard let enemy = selectedEnemy else { return }
        guard enemy.affectedByGravity != enabled else { return }
        mutateSelectedEnemy { ref in
            ref.affectedByGravity = enabled
        }
    }

    func updateSelectedEnemyGravityScale(_ scale: Double) {
        guard let enemy = selectedEnemy else { return }
        let clamped = max(0, min(scale, 2.0))
        guard abs(enemy.gravityScale - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.gravityScale = clamped
        }
    }

    func updateSelectedEnemyHorizontalSpan(_ span: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .patrolHorizontal(let current, let speed) = enemy.movement else { return }
        let clamped = max(8, min(span, 800))
        guard abs(current - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.movement = .patrolHorizontal(span: clamped, speed: speed)
        }
    }

    func updateSelectedEnemyHorizontalSpeed(_ speed: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .patrolHorizontal(let span, let current) = enemy.movement else { return }
        let clamped = max(10, min(speed, 600))
        guard abs(current - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.movement = .patrolHorizontal(span: span, speed: clamped)
        }
    }

    func updateSelectedEnemyVerticalSpan(_ span: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .patrolVertical(let current, let speed) = enemy.movement else { return }
        let clamped = max(8, min(span, 800))
        guard abs(current - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.movement = .patrolVertical(span: clamped, speed: speed)
        }
    }

    func updateSelectedEnemyVerticalSpeed(_ speed: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .patrolVertical(let span, let current) = enemy.movement else { return }
        let clamped = max(10, min(speed, 600))
        guard abs(current - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.movement = .patrolVertical(span: span, speed: clamped)
        }
    }

    func updateSelectedEnemyPerimeterWidth(_ width: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .perimeter(let current, let height, let speed, let clockwise) = enemy.movement else { return }
        let clamped = max(8, min(width, 800))
        guard abs(current - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.movement = .perimeter(width: clamped, height: height, speed: speed, clockwise: clockwise)
        }
    }

    func updateSelectedEnemyPerimeterHeight(_ height: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .perimeter(let width, let current, let speed, let clockwise) = enemy.movement else { return }
        let clamped = max(8, min(height, 800))
        guard abs(current - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.movement = .perimeter(width: width, height: clamped, speed: speed, clockwise: clockwise)
        }
    }

    func updateSelectedEnemyPerimeterSpeed(_ speed: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .perimeter(let width, let height, let current, let clockwise) = enemy.movement else { return }
        let clamped = max(10, min(speed, 600))
        guard abs(current - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.movement = .perimeter(width: width, height: height, speed: clamped, clockwise: clockwise)
        }
    }

    func updateSelectedEnemyPerimeterClockwise(_ clockwise: Bool) {
        guard let enemy = selectedEnemy else { return }
        guard case .perimeter(let width, let height, let speed, let currentClockwise) = enemy.movement else { return }
        guard currentClockwise != clockwise else { return }
        mutateSelectedEnemy { ref in
            ref.movement = .perimeter(width: width, height: height, speed: speed, clockwise: clockwise)
        }
    }

    func updateSelectedEnemyWallBounceAxis(_ axis: EnemyController.MovementPattern.Axis) {
        guard let enemy = selectedEnemy else { return }
        guard case .wallBounce(let currentAxis, let speed) = enemy.movement else { return }
        guard currentAxis != axis else { return }
        mutateSelectedEnemy { ref in
            ref.movement = .wallBounce(axis: axis, speed: speed)
        }
    }

    func updateSelectedEnemyWallBounceSpeed(_ speed: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .wallBounce(let axis, let currentSpeed) = enemy.movement else { return }
        let clamped = max(10, min(speed, 600))
        guard abs(currentSpeed - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.movement = .wallBounce(axis: axis, speed: clamped)
        }
    }

    func updateSelectedEnemyChaseRange(_ range: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .chase(let currentRange, let multiplier, let tolerance) = enemy.behavior else { return }
        let clamped = max(32, min(range, 1600))
        guard abs(currentRange - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.behavior = .chase(range: clamped, speedMultiplier: multiplier, verticalTolerance: tolerance)
        }
    }

    func updateSelectedEnemyChaseMultiplier(_ multiplier: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .chase(let range, let currentMultiplier, let tolerance) = enemy.behavior else { return }
        let clamped = max(0.5, min(multiplier, 3.0))
        guard abs(currentMultiplier - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.behavior = .chase(range: range, speedMultiplier: clamped, verticalTolerance: tolerance)
        }
    }

    func updateSelectedEnemyChaseTolerance(_ tolerance: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .chase(let range, let multiplier, let currentTolerance) = enemy.behavior else { return }
        let clamped = max(0, min(tolerance, 500))
        guard abs(currentTolerance - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.behavior = .chase(range: range, speedMultiplier: multiplier, verticalTolerance: clamped)
        }
    }

    func updateSelectedEnemyFleeRange(_ range: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .flee(let currentRange, let safe, let run) = enemy.behavior else { return }
        let clamped = max(32, min(range, 1600))
        guard abs(currentRange - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.behavior = .flee(range: clamped, safeDistance: safe, runMultiplier: run)
        }
    }

    func updateSelectedEnemyFleeSafeDistance(_ distance: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .flee(let range, let currentSafe, let run) = enemy.behavior else { return }
        let clamped = max(16, min(distance, 1600))
        guard abs(currentSafe - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.behavior = .flee(range: range, safeDistance: clamped, runMultiplier: run)
        }
    }

    func updateSelectedEnemyFleeRunMultiplier(_ multiplier: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .flee(let range, let safe, let currentRun) = enemy.behavior else { return }
        let clamped = max(0.5, min(multiplier, 3.0))
        guard abs(currentRun - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.behavior = .flee(range: range, safeDistance: safe, runMultiplier: clamped)
        }
    }

    func updateSelectedEnemyStrafeRange(_ range: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .strafe(let currentRange, let preferred, let speed) = enemy.behavior else { return }
        let clamped = max(32, min(range, 1600))
        guard abs(currentRange - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.behavior = .strafe(range: clamped, preferred: preferred, strafeSpeed: speed)
        }
    }

    func updateSelectedEnemyStrafeNearDistance(_ near: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .strafe(let range, let preferred, let speed) = enemy.behavior else { return }
        let lower = max(16, min(near, preferred.upperBound - 8))
        guard abs(preferred.lowerBound - lower) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.behavior = .strafe(range: range, preferred: lower...max(lower + 8, preferred.upperBound), strafeSpeed: speed)
        }
    }

    func updateSelectedEnemyStrafeFarDistance(_ far: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .strafe(let range, let preferred, let speed) = enemy.behavior else { return }
        let upper = max(preferred.lowerBound + 8, min(far, 1600))
        guard abs(preferred.upperBound - upper) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.behavior = .strafe(range: range, preferred: preferred.lowerBound...upper, strafeSpeed: speed)
        }
    }

    func updateSelectedEnemyStrafeSpeed(_ speed: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .strafe(let range, let preferred, let currentSpeed) = enemy.behavior else { return }
        let clamped = max(10, min(speed, 400))
        guard abs(currentSpeed - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.behavior = .strafe(range: range, preferred: preferred, strafeSpeed: clamped)
        }
    }

    func updateSelectedEnemyShooterSpeed(_ speed: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .shooter(let currentSpeed, let cooldown, let range) = enemy.attack else { return }
        let clamped = max(40, min(speed, 900))
        guard abs(currentSpeed - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.attack = .shooter(speed: clamped, cooldown: cooldown, range: range)
        }
    }

    func updateSelectedEnemyShooterCooldown(_ cooldown: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .shooter(let speed, let currentCooldown, let range) = enemy.attack else { return }
        let clamped = max(0.1, min(cooldown, 10))
        guard abs(currentCooldown - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.attack = .shooter(speed: speed, cooldown: clamped, range: range)
        }
    }

    func updateSelectedEnemyShooterRange(_ range: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .shooter(let speed, let cooldown, let currentRange) = enemy.attack else { return }
        let clamped = max(32, min(range, 1600))
        guard abs(currentRange - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.attack = .shooter(speed: speed, cooldown: cooldown, range: clamped)
        }
    }

    func updateSelectedEnemySwordRange(_ range: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .sword(let currentRange, let cooldown, let knock) = enemy.attack else { return }
        let clamped = max(8, min(range, 200))
        guard abs(currentRange - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.attack = .sword(range: clamped, cooldown: cooldown, knockback: knock)
        }
    }

    func updateSelectedEnemySwordCooldown(_ cooldown: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .sword(let range, let currentCooldown, let knock) = enemy.attack else { return }
        let clamped = max(0.1, min(cooldown, 10))
        guard abs(currentCooldown - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.attack = .sword(range: range, cooldown: clamped, knockback: knock)
        }
    }

    func updateSelectedEnemySwordKnockback(_ knockback: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .sword(let range, let cooldown, let currentKnock) = enemy.attack else { return }
        let clamped = max(0, min(knockback, 800))
        guard abs(currentKnock - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.attack = .sword(range: range, cooldown: cooldown, knockback: clamped)
        }
    }

    func updateSelectedEnemyPunchRange(_ range: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .punch(let currentRange, let cooldown, let knock) = enemy.attack else { return }
        let clamped = max(8, min(range, 200))
        guard abs(currentRange - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.attack = .punch(range: clamped, cooldown: cooldown, knockback: knock)
        }
    }

    func updateSelectedEnemyPunchCooldown(_ cooldown: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .punch(let range, let currentCooldown, let knock) = enemy.attack else { return }
        let clamped = max(0.1, min(cooldown, 10))
        guard abs(currentCooldown - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.attack = .punch(range: range, cooldown: clamped, knockback: knock)
        }
    }

    func updateSelectedEnemyPunchKnockback(_ knockback: Double) {
        guard let enemy = selectedEnemy else { return }
        guard case .punch(let range, let cooldown, let currentKnock) = enemy.attack else { return }
        let clamped = max(0, min(knockback, 800))
        guard abs(currentKnock - clamped) > 0.0001 else { return }
        mutateSelectedEnemy { ref in
            ref.attack = .punch(range: range, cooldown: cooldown, knockback: clamped)
        }
    }

    func updateSelectedSentrySweepSpeed(_ degreesPerSecond: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(10.0, min(degreesPerSecond, 360.0))
        guard abs(sentry.sweepSpeedDegreesPerSecond - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.sweepSpeedDegreesPerSecond = clamped
        }
        syncSelectionState()
    }

    func updateSelectedSentryCooldown(_ cooldown: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(0.2, min(cooldown, 5.0))
        guard abs(sentry.fireCooldown - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.fireCooldown = clamped
        }
        syncSelectionState()
    }

    func updateSelectedSentryProjectileSpeed(_ speed: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(50.0, min(speed, 2000.0))
        guard abs(sentry.projectileSpeed - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.projectileSpeed = clamped
        }
        syncSelectionState()
    }

    func updateSelectedSentryProjectileSize(_ size: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(0.05, min(size, 2.0))
        guard abs(sentry.projectileSize - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.projectileSize = clamped
        }
        syncSelectionState()
    }

    func updateSelectedSentryProjectileLifetime(_ lifetime: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(0.1, min(lifetime, 12.0))
        guard abs(sentry.projectileLifetime - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.projectileLifetime = clamped
        }
        syncSelectionState()
    }

    func updateSelectedSentryProjectileBurstCount(_ count: Int) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(1, min(count, 12))
        guard sentry.projectileBurstCount != clamped else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.projectileBurstCount = clamped
        }
        syncSelectionState()
    }

    func updateSelectedSentryProjectileSpread(_ degrees: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(0.0, min(degrees, 90.0))
        guard abs(sentry.projectileSpreadDegrees - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.projectileSpreadDegrees = clamped
        }
        syncSelectionState()
    }

    func updateSelectedSentryHeatTurnRate(_ degreesPerSecond: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(30.0, min(degreesPerSecond, 720.0))
        guard abs(sentry.heatSeekingTurnRateDegreesPerSecond - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.heatSeekingTurnRateDegreesPerSecond = clamped
        }
        syncSelectionState()
    }

    func updateSelectedSentryProjectileKind(_ kind: SentryBlueprint.ProjectileKind) {
        guard let sentry = selectedSentry else { return }
        guard sentry.projectileKind != kind else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.projectileKind = kind
        }
        syncSelectionState()
    }

    func updateSelectedSentryAimTolerance(_ degrees: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(2.0, min(degrees, 45.0))
        guard abs(sentry.aimToleranceDegrees - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.aimToleranceDegrees = clamped
        }
        syncSelectionState()
    }

    func removePlatform(_ platform: MovingPlatformBlueprint) {
        captureSnapshot()
        blueprint.removeMovingPlatform(id: platform.id)
        syncSelectionState()
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
        syncSelectionState()
    }

    func updateSelectedPlatformSpeed(_ speed: Double) {
        guard let platform = selectedPlatform else { return }
        let clamped = max(0.1, min(speed, 10.0))
        guard abs(platform.speed - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateMovingPlatform(id: platform.id) { ref in
            ref.speed = clamped
        }
        syncSelectionState()
    }

    func updateSelectedPlatformInitialProgress(_ progress: Double) {
        guard let platform = selectedPlatform else { return }
        let clamped = max(0.0, min(progress, 1.0))
        guard abs(platform.initialProgress - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateMovingPlatform(id: platform.id) { ref in
            ref.initialProgress = clamped
        }
        syncSelectionState()
    }

    func duplicateSelectedPlatform() {
        guard let platform = selectedPlatform else { return }
        let placement = placementForDuplicate(of: platform)
        captureSnapshot()
        if let duplicate = blueprint.addMovingPlatform(
            origin: placement.origin,
            size: platform.size,
            target: placement.target,
            speed: platform.speed,
            initialProgress: platform.initialProgress
        ) {
            selectedPlatformID = duplicate.id
            syncSelectionState()
        }
    }

    // MARK: - Selection Handling

    private var hasPendingSelectionMove: Bool {
        guard let selection = multiSelection else { return false }
        switch selection.source {
        case .existing:
            return selection.offset != .zero
        case .clipboard:
            return true
        }
    }

    private func handleSelectToolDragBegan(at point: GridPoint) {
        if hasPendingSelectionMove, !(multiSelection?.contains(point) ?? false) {
            commitPendingSelectionMoveIfNeeded()
        }

        dragStartPoint = point
        lastPaintedPoint = nil

        if let selection = multiSelection, selection.contains(point) {
            selectionDragContext = .move(start: point, initialOffset: selection.offset)
        } else {
            selectionDragContext = .marquee(start: point)
            shapePreview = pointsForRectangle(from: point, to: point, mode: .stroke)
        }
    }

    private func handleSelectToolDragChanged(to point: GridPoint) {
        guard let context = selectionDragContext else { return }

        switch context {
        case .move(let start, let initialOffset):
            let delta = MapEditorSelectionOffset(
                row: point.row - start.row,
                column: point.column - start.column
            )
            let desired = initialOffset.adding(row: delta.row, column: delta.column)
            updateSelectionOffset(desired)
        case .marquee(let start):
            shapePreview = pointsForRectangle(from: start, to: point, mode: .stroke)
        }
    }

    private func handleSelectToolDragEnded(at point: GridPoint?) {
        guard let context = selectionDragContext else {
            shapePreview.removeAll()
            dragStartPoint = nil
            return
        }

        selectionDragContext = nil

        switch context {
        case .move:
            break
        case .marquee(let start):
            let endPoint = point ?? start
            let bounds = makeSelectionBounds(from: start, to: endPoint)
            applySelection(bounds: bounds, mask: selectionMask)
        }

        shapePreview.removeAll()
        dragStartPoint = nil
        lastPaintedPoint = nil
    }

    private func makeSelectionBounds(from start: GridPoint, to end: GridPoint) -> MapEditorSelectionBounds {
        MapEditorSelectionBounds(
            minRow: min(start.row, end.row),
            maxRow: max(start.row, end.row),
            minColumn: min(start.column, end.column),
            maxColumn: max(start.column, end.column)
        )
    }

    private func applySelection(bounds: MapEditorSelectionBounds, mask: SelectionMask) {
        guard let newSelection = buildSelection(in: bounds, mask: mask) else {
            multiSelection = nil
            refreshSelectionRenderState(using: nil)
            self.selection = .none
            return
        }
        multiSelection = newSelection
        refreshSelectionRenderState(using: newSelection)
        self.selection = .none
    }

    private func buildSelection(in bounds: MapEditorSelectionBounds, mask: SelectionMask) -> MultiSelection? {
        guard bounds.isValid else { return nil }

        var tiles: [GridPoint: LevelTileKind] = [:]
        var spawns: [PlayerSpawnPoint] = []
        var platforms: [MovingPlatformBlueprint] = []
        var sentries: [SentryBlueprint] = []
        var enemies: [EnemyBlueprint] = []

        if mask.includesTiles {
            for row in max(0, bounds.minRow)...min(blueprint.rows - 1, bounds.maxRow) {
                for column in max(0, bounds.minColumn)...min(blueprint.columns - 1, bounds.maxColumn) {
                    let point = GridPoint(row: row, column: column)
                    let tile = blueprint.tile(at: point)
                    if tile != .empty {
                        tiles[point] = tile
                    }
                }
            }
        }

        if mask.contains(.spawns) {
            spawns = blueprint.spawnPoints.filter { bounds.contains($0.coordinate) }
        }

        if mask.contains(.platforms) {
            for platform in blueprint.movingPlatforms {
                if boundsIntersectsPlatform(bounds, platform: platform) {
                    platforms.append(platform)
                }
            }
        }

        if mask.contains(.sentries) {
            sentries = blueprint.sentries.filter { bounds.contains($0.coordinate) }
        }

        if mask.contains(.enemies) {
            for enemy in blueprint.enemies {
                if boundsIntersectsEnemy(bounds, enemy: enemy) {
                    enemies.append(enemy)
                }
            }
        }

        var selection = MultiSelection(
            bounds: clamp(bounds: bounds),
            tiles: tiles,
            spawns: spawns,
            platforms: platforms,
            sentries: sentries,
            enemies: enemies,
            mask: mask,
            offset: .zero,
            source: .existing
        )

        if selection.isEmpty {
            return nil
        }

        selection.bounds = clamp(bounds: selection.bounds)
        return selection
    }

    private func clamp(bounds: MapEditorSelectionBounds) -> MapEditorSelectionBounds {
        MapEditorSelectionBounds(
            minRow: max(0, min(bounds.minRow, blueprint.rows - 1)),
            maxRow: max(0, min(bounds.maxRow, blueprint.rows - 1)),
            minColumn: max(0, min(bounds.minColumn, blueprint.columns - 1)),
            maxColumn: max(0, min(bounds.maxColumn, blueprint.columns - 1))
        )
    }

    private func boundsIntersectsPlatform(_ bounds: MapEditorSelectionBounds, platform: MovingPlatformBlueprint) -> Bool {
        let originBounds = MapEditorSelectionBounds(
            minRow: platform.origin.row,
            maxRow: platform.origin.row + platform.size.rows - 1,
            minColumn: platform.origin.column,
            maxColumn: platform.origin.column + platform.size.columns - 1
        )

        if boundsOverlap(bounds, originBounds) { return true }

        let targetBounds = MapEditorSelectionBounds(
            minRow: platform.target.row,
            maxRow: platform.target.row + platform.size.rows - 1,
            minColumn: platform.target.column,
            maxColumn: platform.target.column + platform.size.columns - 1
        )

        return boundsOverlap(bounds, targetBounds)
    }

    private func boundsOverlap(_ lhs: MapEditorSelectionBounds, _ rhs: MapEditorSelectionBounds) -> Bool {
        lhs.maxRow >= rhs.minRow && rhs.maxRow >= lhs.minRow && lhs.maxColumn >= rhs.minColumn && rhs.maxColumn >= lhs.minColumn
    }

    private func boundsIntersectsEnemy(_ bounds: MapEditorSelectionBounds, enemy: EnemyBlueprint) -> Bool {
        let tileSize = max(1.0, blueprint.tileSize)
        let centerColumn = Double(enemy.coordinate.column) + 0.5
        let centerRow = Double(enemy.coordinate.row) + 0.5
        let widthTiles = max(0.4, min(enemy.size.x / tileSize, 1.8))
        let heightTiles = max(0.6, min(enemy.size.y / tileSize, 2.1))
        let halfWidth = widthTiles * 0.5
        let halfHeight = heightTiles * 0.5

        let enemyMinColumn = centerColumn - halfWidth
        let enemyMaxColumn = centerColumn + halfWidth
        let enemyMinRow = centerRow - halfHeight
        let enemyMaxRow = centerRow + halfHeight

        let selectionMinColumn = Double(bounds.minColumn)
        let selectionMaxColumn = Double(bounds.maxColumn + 1)
        let selectionMinRow = Double(bounds.minRow)
        let selectionMaxRow = Double(bounds.maxRow + 1)

        let horizontalOverlap = selectionMaxColumn > enemyMinColumn && enemyMaxColumn > selectionMinColumn
        let verticalOverlap = selectionMaxRow > enemyMinRow && enemyMaxRow > selectionMinRow

        return horizontalOverlap && verticalOverlap
    }

    private func hitTestEnemy(at point: GridPoint) -> EnemyBlueprint? {
        let tileSize = max(1.0, blueprint.tileSize)
        let tileCenterColumn = Double(point.column) + 0.5
        let tileCenterRow = Double(point.row) + 0.5

        return blueprint.enemies.first { enemy in
            let centerColumn = Double(enemy.coordinate.column) + 0.5
            let centerRow = Double(enemy.coordinate.row) + 0.5
            let widthTiles = max(0.4, min(enemy.size.x / tileSize, 1.8))
            let heightTiles = max(0.6, min(enemy.size.y / tileSize, 2.1))
            let halfWidth = widthTiles * 0.5
            let halfHeight = heightTiles * 0.5

            return abs(tileCenterColumn - centerColumn) <= halfWidth && abs(tileCenterRow - centerRow) <= halfHeight
        }
    }

    private func updateSelectionOffset(_ desiredOffset: MapEditorSelectionOffset) {
        guard var selection = multiSelection else { return }
        let clamped = clamp(offset: desiredOffset, for: selection)
        guard selection.offset != clamped else { return }
        selection.offset = clamped
        multiSelection = selection
        refreshSelectionRenderState(using: selection)
    }

    private func clamp(offset: MapEditorSelectionOffset, for selection: MultiSelection) -> MapEditorSelectionOffset {
        let minRowOffset = -selection.bounds.minRow
        let maxRowOffset = max(0, blueprint.rows - 1 - selection.bounds.maxRow)
        let minColumnOffset = -selection.bounds.minColumn
        let maxColumnOffset = max(0, blueprint.columns - 1 - selection.bounds.maxColumn)

        let clampedRow = min(max(offset.row, minRowOffset), maxRowOffset)
        let clampedColumn = min(max(offset.column, minColumnOffset), maxColumnOffset)
        return MapEditorSelectionOffset(row: clampedRow, column: clampedColumn)
    }

    private func refreshSelectionRenderState(using selection: MultiSelection?) {
        guard let selection else {
            selectionRenderState = nil
            return
        }

        selectionRenderState = MapEditorSelectionRenderState(
            bounds: selection.bounds,
            offset: selection.offset,
            tiles: selection.tiles,
            spawns: selection.spawns,
            platforms: selection.platforms,
            sentries: selection.sentries,
            enemies: selection.enemies,
            mask: selection.mask,
            source: selection.source
        )
    }

    func commitSelectionMove() {
        commitPendingSelectionMoveIfNeeded()
    }

    func cancelSelectionMove() {
        guard var selection = multiSelection else { return }
        switch selection.source {
        case .existing:
            guard selection.offset != .zero else { return }
            selection.offset = .zero
            multiSelection = selection
            refreshSelectionRenderState(using: selection)
        case .clipboard:
            multiSelection = nil
            refreshSelectionRenderState(using: nil)
        }
    }

    func copySelection() {
        guard multiSelection != nil else { return }
        if multiSelection?.source == .existing, multiSelection?.offset != .zero {
            commitPendingSelectionMoveIfNeeded()
        }
        guard let selection = multiSelection else { return }
        selectionClipboard = makeClipboardSnapshot(from: selection)
    }

    func cutSelection() {
        guard let selection = multiSelection else { return }

        switch selection.source {
        case .existing:
            if selection.offset != .zero {
                commitPendingSelectionMoveIfNeeded()
            }
            guard var current = multiSelection else { return }
            selectionClipboard = makeClipboardSnapshot(from: current)
            current.offset = .zero
            removeSelectionContents(current)
            multiSelection = nil
            refreshSelectionRenderState(using: nil)
        case .clipboard:
            selectionClipboard = makeClipboardSnapshot(from: selection)
            multiSelection = nil
            refreshSelectionRenderState(using: nil)
        }
    }

    func pasteSelection(at origin: GridPoint? = nil) {
        guard let clipboard = selectionClipboard else { return }
        let target = origin ?? hoveredPoint ?? GridPoint(row: clipboard.bounds.minRow, column: clipboard.bounds.minColumn)
        let offset = MapEditorSelectionOffset(
            row: target.row - clipboard.bounds.minRow,
            column: target.column - clipboard.bounds.minColumn
        )

        var selection = clipboard
        selection.offset = clamp(offset: offset, for: selection)
        selection.source = .clipboard
        commitPendingSelectionMoveIfNeeded()
        applyPastedSelection(selection)
    }

    private func applyPastedSelection(_ selection: MultiSelection) {
        multiSelection = selection
        refreshSelectionRenderState(using: selection)
    }

    @discardableResult
    private func applySelectionTiles(_ tiles: [GridPoint: LevelTileKind], offset: MapEditorSelectionOffset) -> [GridPoint: LevelTileKind] {
        var inserted: [GridPoint: LevelTileKind] = [:]
        for (point, kind) in tiles {
            let destination = GridPoint(row: point.row + offset.row, column: point.column + offset.column)
            guard blueprint.contains(destination) else { continue }
            blueprint.setTile(kind, at: destination)
            inserted[destination] = kind
        }
        return inserted
    }

    @discardableResult
    private func applySelectionSpawns(_ spawns: [PlayerSpawnPoint], offset: MapEditorSelectionOffset) -> [PlayerSpawnPoint] {
        var inserted: [PlayerSpawnPoint] = []
        for spawn in spawns {
            let coordinate = GridPoint(row: spawn.coordinate.row + offset.row, column: spawn.coordinate.column + offset.column)
            guard blueprint.contains(coordinate) else { continue }
            if let newSpawn = blueprint.addSpawnPoint(named: spawn.name, at: coordinate) {
                inserted.append(newSpawn)
            }
        }
        return inserted
    }

    @discardableResult
    private func applySelectionPlatforms(_ platforms: [MovingPlatformBlueprint], offset: MapEditorSelectionOffset) -> [MovingPlatformBlueprint] {
        var inserted: [MovingPlatformBlueprint] = []
        for platform in platforms {
            let origin = platform.origin.offsetting(rowDelta: offset.row, columnDelta: offset.column)
            let target = platform.target.offsetting(rowDelta: offset.row, columnDelta: offset.column)
            guard isValidPlatformPlacement(origin: origin, size: platform.size, target: target) else { continue }
            if let newPlatform = blueprint.addMovingPlatform(
                origin: origin,
                size: platform.size,
                target: target,
                speed: platform.speed,
                initialProgress: platform.initialProgress
            ) {
                inserted.append(newPlatform)
            }
        }
        return inserted
    }

    @discardableResult
    private func applySelectionSentries(_ sentries: [SentryBlueprint], offset: MapEditorSelectionOffset) -> [SentryBlueprint] {
        var inserted: [SentryBlueprint] = []
        for sentry in sentries {
            let coordinate = sentry.coordinate.offsetting(rowDelta: offset.row, columnDelta: offset.column)
            guard blueprint.contains(coordinate), blueprint.sentry(at: coordinate) == nil else { continue }
            let newSentry = SentryBlueprint(
                coordinate: coordinate,
                scanRange: sentry.scanRange,
                scanCenterDegrees: sentry.scanCenterDegrees,
                scanArcDegrees: sentry.scanArcDegrees,
                sweepSpeedDegreesPerSecond: sentry.sweepSpeedDegreesPerSecond,
                fireCooldown: sentry.fireCooldown,
                projectileSpeed: sentry.projectileSpeed,
                projectileSize: sentry.projectileSize,
                projectileLifetime: sentry.projectileLifetime,
                projectileBurstCount: sentry.projectileBurstCount,
                projectileSpreadDegrees: sentry.projectileSpreadDegrees,
                aimToleranceDegrees: sentry.aimToleranceDegrees,
                initialFacingDegrees: sentry.initialFacingDegrees,
                projectileKind: sentry.projectileKind,
                heatSeekingTurnRateDegreesPerSecond: sentry.heatSeekingTurnRateDegreesPerSecond
            )
            if let added = blueprint.addSentry(newSentry) {
                inserted.append(added)
            }
        }
        return inserted
    }

    @discardableResult
    private func applySelectionEnemies(_ enemies: [EnemyBlueprint], offset: MapEditorSelectionOffset) -> [EnemyBlueprint] {
        var inserted: [EnemyBlueprint] = []
        for enemy in enemies {
            let coordinate = enemy.coordinate.offsetting(rowDelta: offset.row, columnDelta: offset.column)
            guard blueprint.contains(coordinate), enemyFits(at: coordinate) else { continue }
            var copy = enemy
            copy.coordinate = coordinate
            copy.id = UUID()
            if let newEnemy = blueprint.addEnemy(copy) {
                inserted.append(newEnemy)
            }
        }
        return inserted
    }

    private func makeSelectionBounds(
        tiles: Dictionary<GridPoint, LevelTileKind>.Keys,
        spawns: [PlayerSpawnPoint],
        platforms: [MovingPlatformBlueprint],
        sentries: [SentryBlueprint],
        enemies: [EnemyBlueprint]
    ) -> MapEditorSelectionBounds? {
        guard blueprint.rows > 0, blueprint.columns > 0 else { return nil }

        var minRow = Int.max
        var maxRow = Int.min
        var minColumn = Int.max
        var maxColumn = Int.min

        func update(row: Int, column: Int) {
            let clampedRow = min(max(row, 0), blueprint.rows - 1)
            let clampedColumn = min(max(column, 0), blueprint.columns - 1)
            minRow = min(minRow, clampedRow)
            maxRow = max(maxRow, clampedRow)
            minColumn = min(minColumn, clampedColumn)
            maxColumn = max(maxColumn, clampedColumn)
        }

        for point in tiles {
            update(row: point.row, column: point.column)
        }

        for spawn in spawns {
            update(row: spawn.coordinate.row, column: spawn.coordinate.column)
        }

        for platform in platforms {
            update(row: platform.origin.row, column: platform.origin.column)
            update(
                row: platform.origin.row + platform.size.rows - 1,
                column: platform.origin.column + platform.size.columns - 1
            )
            update(row: platform.target.row, column: platform.target.column)
            update(
                row: platform.target.row + platform.size.rows - 1,
                column: platform.target.column + platform.size.columns - 1
            )
        }

        for sentry in sentries {
            update(row: sentry.coordinate.row, column: sentry.coordinate.column)
        }

        for enemy in enemies {
            update(row: enemy.coordinate.row, column: enemy.coordinate.column)
        }

        guard minRow != Int.max, minColumn != Int.max else { return nil }

        return MapEditorSelectionBounds(
            minRow: minRow,
            maxRow: maxRow,
            minColumn: minColumn,
            maxColumn: maxColumn
        )
    }

    private func makeClipboardSnapshot(from selection: MultiSelection) -> MultiSelection {
        if selection.offset == .zero {
            var copy = selection
            copy.source = .clipboard
            return copy
        }

        let offset = selection.offset
        func transformed(_ point: GridPoint) -> GridPoint {
            GridPoint(row: point.row + offset.row, column: point.column + offset.column)
        }

        var tiles: [GridPoint: LevelTileKind] = [:]
        for (point, kind) in selection.tiles {
            tiles[transformed(point)] = kind
        }

        let spawns = selection.spawns.map { spawn -> PlayerSpawnPoint in
            var copy = spawn
            copy.coordinate = transformed(spawn.coordinate)
            return copy
        }

        let platforms = selection.platforms.map { platform -> MovingPlatformBlueprint in
            var copy = platform
            copy.origin = transformed(platform.origin)
            copy.target = transformed(platform.target)
            return copy
        }

        let sentries = selection.sentries.map { sentry -> SentryBlueprint in
            var copy = sentry
            copy.coordinate = transformed(sentry.coordinate)
            return copy
        }

        let enemies = selection.enemies.map { enemy -> EnemyBlueprint in
            var copy = enemy
            copy.coordinate = transformed(enemy.coordinate)
            return copy
        }

        let newBounds = clamp(bounds: selection.bounds.offsetting(by: offset))

        return MultiSelection(
            bounds: newBounds,
            tiles: tiles,
            spawns: spawns,
            platforms: platforms,
            sentries: sentries,
            enemies: enemies,
            mask: selection.mask,
            offset: .zero,
            source: .clipboard
        )
    }

    private func enemyFits(at coordinate: GridPoint) -> Bool {
        blueprint.contains(coordinate) && blueprint.enemy(at: coordinate) == nil
    }

    private func removeSelectionContents(_ selection: MultiSelection) {
        captureSnapshot()

        for (point, _) in selection.tiles {
            blueprint.setTile(.empty, at: point)
        }

        for spawn in selection.spawns {
            blueprint.removeSpawn(spawn)
        }

        for platform in selection.platforms {
            blueprint.removeMovingPlatform(id: platform.id)
        }

        for sentry in selection.sentries {
            blueprint.removeSentry(id: sentry.id)
        }

        for enemy in selection.enemies {
            blueprint.removeEnemy(id: enemy.id)
        }

        syncSelectionState()
    }

    private func commitPendingSelectionMoveIfNeeded() {
        guard var selection = multiSelection else { return }

        switch selection.source {
        case .existing:
            guard selection.offset != .zero else { return }
            let offset = selection.offset
            captureSnapshot()

            for (point, _) in selection.tiles {
                blueprint.setTile(.empty, at: point)
            }
            _ = applySelectionTiles(selection.tiles, offset: offset)

            for spawn in selection.spawns {
                let destination = spawn.coordinate.offsetting(rowDelta: offset.row, columnDelta: offset.column)
                blueprint.updateSpawn(id: spawn.id, to: destination)
            }

            for platform in selection.platforms {
                let origin = platform.origin.offsetting(rowDelta: offset.row, columnDelta: offset.column)
                let target = platform.target.offsetting(rowDelta: offset.row, columnDelta: offset.column)
                blueprint.updateMovingPlatform(id: platform.id) { ref in
                    ref.origin = origin
                    ref.target = target
                }
            }

            for sentry in selection.sentries {
                let destination = sentry.coordinate.offsetting(rowDelta: offset.row, columnDelta: offset.column)
                blueprint.updateSentry(id: sentry.id) { ref in
                    ref.coordinate = destination
                }
            }

            for enemy in selection.enemies {
                let destination = enemy.coordinate.offsetting(rowDelta: offset.row, columnDelta: offset.column)
                blueprint.updateEnemy(id: enemy.id) { ref in
                    ref.coordinate = destination
                }
            }

            selection.bounds = selection.bounds.offsetting(by: offset)
            selection.offset = .zero
            multiSelection = selection
            refreshSelectionRenderState(using: selection)
            syncSelectionState()

        case .clipboard:
            let offset = selection.offset
            captureSnapshot()

            let insertedTiles = applySelectionTiles(selection.tiles, offset: offset)
            let insertedSpawns = applySelectionSpawns(selection.spawns, offset: offset)
            let insertedPlatforms = applySelectionPlatforms(selection.platforms, offset: offset)
            let insertedSentries = applySelectionSentries(selection.sentries, offset: offset)
            let insertedEnemies = applySelectionEnemies(selection.enemies, offset: offset)

            if let bounds = makeSelectionBounds(
                tiles: insertedTiles.keys,
                spawns: insertedSpawns,
                platforms: insertedPlatforms,
                sentries: insertedSentries,
                enemies: insertedEnemies
            ) {
                let committed = MultiSelection(
                    bounds: bounds,
                    tiles: insertedTiles,
                    spawns: insertedSpawns,
                    platforms: insertedPlatforms,
                    sentries: insertedSentries,
                    enemies: insertedEnemies,
                    mask: selection.mask,
                    offset: .zero,
                    source: .existing
                )
                multiSelection = committed
                refreshSelectionRenderState(using: committed)
            } else {
                multiSelection = nil
                refreshSelectionRenderState(using: nil)
            }

            syncSelectionState()
        }
    }

    func setSelectionMask(_ mask: SelectionMask) {
        guard selectionMask != mask else { return }
        selectionMask = mask

        guard var current = multiSelection else { return }
        current.mask = mask

        switch current.source {
        case .existing:
            if current.offset != .zero {
                commitPendingSelectionMoveIfNeeded()
                guard let updated = multiSelection else { return }
                applySelection(bounds: updated.bounds, mask: mask)
                return
            }
            applySelection(bounds: current.bounds, mask: mask)
        case .clipboard:
            multiSelection = current
            refreshSelectionRenderState(using: current)
        }
    }

    private func handleToolChanged(from oldValue: Tool, to newValue: Tool) {
        if oldValue == .select, newValue != .select {
            commitPendingSelectionMoveIfNeeded()
            selectionDragContext = nil
            shapePreview.removeAll()
            multiSelection = nil
            refreshSelectionRenderState(using: nil)
        }
    }

    // MARK: - Interaction Handling

    private func applyToolOverrideIfNeeded(for activeTool: Tool) {
        guard tool != activeTool else { return }
        if toolBeforeDragOverride == nil {
            toolBeforeDragOverride = tool
        }
        tool = activeTool
    }

    private func resetToolOverrideIfNeeded() {
        if let previous = toolBeforeDragOverride {
            toolBeforeDragOverride = nil
            tool = previous
        }
    }

    func handleDragBegan(at point: GridPoint) {
        guard blueprint.contains(point) else { return }

        hoveredPoint = point

        if tool == .select {
            handleSelectToolDragBegan(at: point)
            return
        }

        commitPendingSelectionMoveIfNeeded()

        spawnDragCaptured = false
        platformDragCaptured = false
        sentryDragCaptured = false
        enemyDragCaptured = false

        spawnDragID = nil
        sentryDragID = nil
        enemyDragID = nil

        var detectedTool: Tool?

        if let spawn = blueprint.spawn(at: point) {
            selection = .spawn(spawn.id)
            spawnDragID = spawn.id
            detectedTool = .spawn
        }

        if detectedTool == nil, let platform = platform(at: point) {
            selection = .platform(platform.id)
            platformDragContext = .move(
                PlatformMoveContext(
                    platformID: platform.id,
                    size: platform.size,
                    startOrigin: platform.origin,
                    startTarget: platform.target,
                    startPoint: point
                )
            )
            detectedTool = .platform
        } else {
            platformDragContext = tool == .platform ? .create : nil
        }

        if detectedTool == nil, let sentry = sentry(at: point) {
            selection = .sentry(sentry.id)
            sentryDragID = sentry.id
            detectedTool = .sentry
        }

        if detectedTool == nil, let enemy = hitTestEnemy(at: point) {
            selection = .enemy(enemy.id)
            enemyDragID = enemy.id
            detectedTool = .enemy
        }

        let activeTool = detectedTool ?? tool

        dragStartPoint = point
        lastPaintedPoint = nil

        if activeTool != .select {
            applyToolOverrideIfNeeded(for: activeTool)
        }

        switch activeTool {
        case .pencil, .flood, .line, .rectangle, .rectErase, .circle, .eraser:
            captureSnapshot()
            applyDrag(at: point, isInitial: true)
        case .spawn:
            applyDrag(at: point, isInitial: true)
        case .platform:
            if platformDragContext == nil {
                platformDragContext = .create
            }
            applyDrag(at: point, isInitial: true)
        case .sentry, .enemy:
            applyDrag(at: point, isInitial: true)
        case .select:
            break
        }
    }

    func handleDragChanged(to point: GridPoint) {
        guard blueprint.contains(point) else { return }
        hoveredPoint = point
        if tool == .select {
            handleSelectToolDragChanged(to: point)
        } else {
            applyDrag(at: point, isInitial: false)
        }
    }

    func handleDragEnded(at point: GridPoint?) {
        if tool == .select {
            handleSelectToolDragEnded(at: point)
            hoveredPoint = nil
            return
        }

        defer {
            lastPaintedPoint = nil
            dragStartPoint = nil
            shapePreview.removeAll()
            hoveredPoint = nil
            syncSelectionState()
            spawnDragID = nil
            sentryDragID = nil
            enemyDragID = nil
            resetToolOverrideIfNeeded()
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
        case .sentry:
            break
        case .enemy:
            break
        default:
            break
        }

        platformDragContext = nil
    }
    
    func undo() {
        scheduleMutation { model in
            guard let previous = model.undoStack.popLast() else { return }
            model.redoStack.append(model.blueprint)
            model.blueprint = previous
            model.syncSelectionState()
        }
    }

    func redo() {
        scheduleMutation { model in
            guard let next = model.redoStack.popLast() else { return }
            model.undoStack.append(model.blueprint)
            model.blueprint = next
            model.syncSelectionState()
        }
    }

    func spawnColor(for index: Int) -> Color {
        SpawnPalette.color(for: index)
    }

    func platformColor(for index: Int) -> Color {
        PlatformPalette.color(for: index)
    }

    func enemyColor(for index: Int) -> Color {
        EnemyPalette.color(for: index)
    }

    private func applyDrag(at point: GridPoint, isInitial: Bool) {
        switch tool {
        case .pencil:
            paintSolid(at: point)
        case .flood:
            if isInitial {
                shapePreview.removeAll()
                performFloodFill(at: point)
            }
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
                if isInitial {
                    let origin = context.startOrigin
                    shapePreview = pointsForRectangle(
                        from: origin,
                        to: GridPoint(row: origin.row + context.size.rows - 1, column: origin.column + context.size.columns - 1),
                        mode: .stroke
                    )
                } else {
                    movePlatform(context: context, to: point)
                }
            case .create:
                shapePreview = pointsForRectangle(from: dragStartPoint ?? point, to: point, mode: .fill)
            case .none:
                break
            }
        case .sentry:
            moveSentry(to: point, isInitial: isInitial)
        case .enemy:
            moveEnemy(to: point, isInitial: isInitial)
        case .select:
            break
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

    private func performFloodFill(at start: GridPoint) {
        guard blueprint.contains(start) else { return }
        guard lastPaintedPoint != start else { return }

        let targetKind = blueprint.tile(at: start)
        let replacement = paintTileKind
        if targetKind == replacement { return }

        var stack: [GridPoint] = [start]
        var visited: Set<GridPoint> = [start]

        while let current = stack.popLast() {
            blueprint.setTile(replacement, at: current)

            let neighbors = [
                current.offsetting(rowDelta: -1),
                current.offsetting(rowDelta: 1),
                current.offsetting(columnDelta: -1),
                current.offsetting(columnDelta: 1)
            ]

            for neighbor in neighbors where blueprint.contains(neighbor) && !visited.contains(neighbor) {
                if blueprint.tile(at: neighbor) == targetKind {
                    visited.insert(neighbor)
                    stack.append(neighbor)
                }
            }
        }

        lastPaintedPoint = start
    }

    private func moveSpawn(to point: GridPoint, isInitial: Bool) {
        guard blueprint.contains(point) else { return }
        if isInitial {
            if let existing = blueprint.spawn(at: point) {
                selection = .spawn(existing.id)
                _ = undoStack.popLast()
            } else {
                _ = insertSpawn(at: point)
            }
        } else if let spawn = selectedSpawn {
            blueprint.updateSpawn(id: spawn.id, to: point)
        }
    }

    private func moveSentry(to point: GridPoint, isInitial: Bool) {
        guard blueprint.contains(point) else { return }
        if let dragID = sentryDragID, blueprint.sentry(id: dragID) != nil {
            blueprint.updateSentry(id: dragID) { ref in
                ref.coordinate = point
            }
        } else if isInitial {
            if let existing = sentry(at: point) {
                selectedSentryID = existing.id
                sentryDragID = existing.id
                _ = undoStack.popLast()
            } else if let newSentry = insertSentry(at: point) {
                selectedSentryID = newSentry.id
                sentryDragID = newSentry.id
            }
        }
    }

    private func moveEnemy(to point: GridPoint, isInitial: Bool) {
        guard blueprint.contains(point) else { return }
        if let dragID = enemyDragID, blueprint.enemy(id: dragID) != nil {
            blueprint.updateEnemy(id: dragID) { ref in
                ref.coordinate = point
            }
        } else if isInitial {
            if let existing = enemy(at: point) {
                selectedEnemyID = existing.id
                enemyDragID = existing.id
                _ = undoStack.popLast()
            } else if let newEnemy = insertEnemy(at: point) {
                selectedEnemyID = newEnemy.id
                enemyDragID = newEnemy.id
            }
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

        let newOriginRow = min(max(context.startOrigin.row + deltaRow, 0), maxRow)
        let newOriginCol = min(max(context.startOrigin.column + deltaCol, 0), maxCol)

        deltaRow = newOriginRow - context.startOrigin.row
        deltaCol = newOriginCol - context.startOrigin.column

        let newTargetRow = min(max(context.startTarget.row + deltaRow, 0), maxRow)
        let newTargetCol = min(max(context.startTarget.column + deltaCol, 0), maxCol)

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
        scheduleAutosave()
    }

    private func syncSelectionState() {
        switch selection {
        case .spawn(let id):
            if blueprint.spawnPoint(id: id) != nil { return }
            if let first = blueprint.spawnPoints.first?.id {
                selection = .spawn(first)
            } else {
                selectFallbackEntity()
            }
        case .platform(let id):
            if blueprint.movingPlatform(id: id) != nil { return }
            if let first = blueprint.movingPlatforms.first?.id {
                selection = .platform(first)
            } else {
                selectFallbackEntity()
            }
        case .sentry(let id):
            if blueprint.sentry(id: id) != nil { return }
            if let first = blueprint.sentries.first?.id {
                selection = .sentry(first)
            } else {
                selectFallbackEntity()
            }
        case .enemy(let id):
            if blueprint.enemy(id: id) != nil { return }
            if let first = blueprint.enemies.first?.id {
                selection = .enemy(first)
            } else {
                selectFallbackEntity()
            }
        case .none:
            selectFallbackEntity()
        }
    }

    private func selectFallbackEntity() {
        if let spawn = blueprint.spawnPoints.first?.id {
            selection = .spawn(spawn)
        } else if let platform = blueprint.movingPlatforms.first?.id {
            selection = .platform(platform)
        } else if let sentry = blueprint.sentries.first?.id {
            selection = .sentry(sentry)
        } else if let enemy = blueprint.enemies.first?.id {
            selection = .enemy(enemy)
        } else {
            selection = .none
        }
    }

    @discardableResult
    private func insertSpawn(at point: GridPoint) -> PlayerSpawnPoint? {
        guard let spawn = blueprint.addSpawnPoint(at: point) else {
            return nil
        }
        selection = .spawn(spawn.id)
        return spawn
    }

    @discardableResult
    private func insertPlatform(origin: GridPoint, size: GridSize, target: GridPoint, speed: Double = 1.0) -> MovingPlatformBlueprint? {
        guard let platform = blueprint.addMovingPlatform(origin: origin, size: size, target: target, speed: speed) else {
            return nil
        }
        selection = .platform(platform.id)
        return platform
    }

    @discardableResult
    private func insertSentry(at point: GridPoint) -> SentryBlueprint? {
        guard let sentry = blueprint.addSentry(at: point) else { return nil }
        selection = .sentry(sentry.id)
        return sentry
    }

    @discardableResult
    private func insertEnemy(at point: GridPoint) -> EnemyBlueprint? {
        guard let enemy = blueprint.addEnemy(at: point) else { return nil }
        selection = .enemy(enemy.id)
        return enemy
    }

    private func mutateSelectedEnemy(_ mutate: (inout EnemyBlueprint) -> Void) {
        guard let enemy = selectedEnemy else { return }
        captureSnapshot()
        blueprint.updateEnemy(id: enemy.id, mutate: mutate)
        syncSelectionState()
    }

    func platformTargetRowRange(_ platform: MovingPlatformBlueprint) -> ClosedRange<Int> {
        let maxRow = max(0, blueprint.rows - platform.size.rows)
        return 0...maxRow
    }

    func platformTargetColumnRange(_ platform: MovingPlatformBlueprint) -> ClosedRange<Int> {
        let maxCol = max(0, blueprint.columns - platform.size.columns)
        return 0...maxCol
    }

    func sentryInitialAngleRange(_ sentry: SentryBlueprint) -> ClosedRange<Double> {
        let range = sentryAngleRange(center: sentry.scanCenterDegrees, arc: sentry.scanArcDegrees)
        return range.lowerBound...range.upperBound
    }

    func sentry(at point: GridPoint) -> SentryBlueprint? {
        blueprint.sentry(at: point)
    }

    func enemy(at point: GridPoint) -> EnemyBlueprint? {
        blueprint.enemy(at: point)
    }

    private func findVacantSentryCoordinate(near point: GridPoint) -> GridPoint? {
        let limit = max(1, max(blueprint.rows, blueprint.columns))
        for radius in 1...limit {
            for row in -radius...radius {
                for col in -radius...radius {
                    if max(abs(row), abs(col)) != radius { continue }
                    let candidate = point.offsetting(rowDelta: row, columnDelta: col)
                    guard blueprint.contains(candidate) else { continue }
                    if blueprint.sentry(at: candidate) == nil {
                        return candidate
                    }
                }
            }
        }
        return nil
    }

    private func findVacantEnemyCoordinate(near point: GridPoint) -> GridPoint? {
        let limit = max(1, max(blueprint.rows, blueprint.columns))
        for radius in 1...limit {
            for row in -radius...radius {
                for col in -radius...radius {
                    if max(abs(row), abs(col)) != radius { continue }
                    let candidate = point.offsetting(rowDelta: row, columnDelta: col)
                    guard blueprint.contains(candidate) else { continue }
                    if blueprint.enemy(at: candidate) == nil {
                        return candidate
                    }
                }
            }
        }
        return nil
    }

    private func clampTargetRow(_ row: Int, for platform: MovingPlatformBlueprint) -> Int {
        let range = platformTargetRowRange(platform)
        return min(max(row, range.lowerBound), range.upperBound)
    }

    private func clampTargetColumn(_ column: Int, for platform: MovingPlatformBlueprint) -> Int {
        let range = platformTargetColumnRange(platform)
        return min(max(column, range.lowerBound), range.upperBound)
    }

    private func placementForDuplicate(of platform: MovingPlatformBlueprint) -> (origin: GridPoint, target: GridPoint) {
        let horizontal = platform.size.columns + 1
        let vertical = platform.size.rows + 1
        let offsets: [(Int, Int)] = [
            (0, horizontal),
            (vertical, 0),
            (0, -horizontal),
            (-vertical, 0)
        ]

        for (dr, dc) in offsets {
            let originCandidate = platform.origin.offsetting(rowDelta: dr, columnDelta: dc)
            let targetCandidate = platform.target.offsetting(rowDelta: dr, columnDelta: dc)
            if isValidPlatformPlacement(origin: originCandidate, size: platform.size, target: targetCandidate) {
                return (originCandidate, targetCandidate)
            }
        }

        return (platform.origin, platform.target)
    }

    private func isValidPlatformPlacement(origin: GridPoint, size: GridSize, target: GridPoint) -> Bool {
        guard blueprint.contains(origin), blueprint.contains(target) else { return false }
        let originMax = GridPoint(row: origin.row + size.rows - 1, column: origin.column + size.columns - 1)
        let targetMax = GridPoint(row: target.row + size.rows - 1, column: target.column + size.columns - 1)
        return blueprint.contains(originMax) && blueprint.contains(targetMax)
    }

    private func sentryAngleRange(center: Double, arc: Double) -> (lowerBound: Double, upperBound: Double) {
        let halfArc = max(5.0, min(arc, 240.0) * 0.5)
        return (center - halfArc, center + halfArc)
    }

    private func clampSentryInitialAngle(center: Double, arc: Double, desired: Double) -> Double {
        let range = sentryAngleRange(center: center, arc: arc)
        return min(max(desired, range.lowerBound), range.upperBound)
    }

    // MARK: - Persistence

    func makeMapDocument() -> MapDocument {
        MapDocument(
            blueprint: blueprint,
            metadata: MapDocumentMetadata(name: levelName)
        )
    }

    func exportJSON(prettyPrinted: Bool = true) throws -> Data {
        try makeMapDocument().encodedData(prettyPrinted: prettyPrinted)
    }

    func importJSON(_ data: Data) throws {
        let document = try MapDocument.decode(from: data)
        applyLoadedDocument(document)
    }

    func applyLoadedDocument(_ document: MapDocument) {
        isApplyingLoadedDocument = true
        undoStack.removeAll()
        redoStack.removeAll()
        lastPaintedPoint = nil
        dragStartPoint = nil
        platformDragContext = nil
        sentryDragID = nil
        enemyDragID = nil
        shapePreview.removeAll()
        blueprint = document.blueprint
        if let name = document.metadata?.name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            levelName = name
        }
        zoom = 1.0
        selectedTileKind = .stone
        selection = .none
        syncSelectionState()
        isApplyingLoadedDocument = false
        scheduleAutosave()
    }

    func makeExportFilename() -> String {
        let trimmed = levelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Map" : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|#%&{}$!@`^=+\u{00A0}")
        let components = base.components(separatedBy: invalidCharacters)
        let sanitized = components.joined(separator: " ").replacingOccurrences(of: "  ", with: " ")
        let trimmedResult = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedResult.isEmpty ? "Map" : trimmedResult
    }

    func updateLevelRows(_ rows: Int) {
        let clamped = max(4, min(rows, 256))
        guard clamped != blueprint.rows else { return }
        captureSnapshot()
        blueprint.resize(rows: clamped, columns: blueprint.columns)
        syncSelectionState()
        scheduleAutosave()
    }

    func updateLevelColumns(_ columns: Int) {
        let clamped = max(4, min(columns, 256))
        guard clamped != blueprint.columns else { return }
        captureSnapshot()
        blueprint.resize(rows: blueprint.rows, columns: clamped)
        syncSelectionState()
        scheduleAutosave()
    }

    func updateTileSize(_ size: Double) {
        let clamped = max(8.0, min(size, 128.0))
        guard abs(blueprint.tileSize - clamped) > 0.001 else { return }
        captureSnapshot()
        blueprint.updateTileSize(clamped)
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let document = self.makeMapDocument()
            persistence.saveAutosave(document: document)
        }
        autosaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func scheduleMutation(_ mutation: @escaping (MapEditorViewModel) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            mutation(self)
        }
    }
}
