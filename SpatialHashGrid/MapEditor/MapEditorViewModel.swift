// MapEditorView.swift
// SwiftUI editor for building tile maps and player spawns

import Combine
import SwiftUI

final class MapEditorViewModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
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

    @Published var blueprint: LevelBlueprint
    @Published var showGrid: Bool = true
    @Published var tool: Tool = .pencil
    @Published var drawMode: ShapeDrawMode = .fill
    @Published var levelName: String = "Untitled"
    @Published var selectedSpawnID: PlayerSpawnPoint.ID?
    @Published var selectedPlatformID: MovingPlatformBlueprint.ID?
    @Published var selectedSentryID: SentryBlueprint.ID?
    @Published var selectedEnemyID: EnemyBlueprint.ID?
    @Published var hoveredPoint: GridPoint?
    @Published var shapePreview: Set<GridPoint> = []
    @Published var zoom: Double = 1.0
    @Published var selectedTileKind: LevelTileKind = .stone

    private var lastPaintedPoint: GridPoint?
    private var dragStartPoint: GridPoint?
    private var undoStack: [LevelBlueprint] = []
    private var redoStack: [LevelBlueprint] = []
    private var platformDragContext: PlatformDragContext?
    private var sentryDragID: SentryBlueprint.ID?
    private var enemyDragID: EnemyBlueprint.ID?

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

    func toggleSelectedRampOrientation() {
        guard let flipped = selectedTileKind.flippedRamp else { return }
        selectedTileKind = flipped
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
        syncSelectedSentry()
        syncSelectedEnemy()
        platformDragContext = nil
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

    func sentryColor(for index: Int) -> Color {
        SentryPalette.color(for: index)
    }

    func selectSentry(_ sentry: SentryBlueprint) {
        selectedSentryID = sentry.id
        tool = .sentry
    }

    func removeSelectedSentry() {
        guard let sentry = selectedSentry else { return }
        removeSentry(sentry)
    }

    func removeSentry(_ sentry: SentryBlueprint) {
        captureSnapshot()
        blueprint.removeSentry(id: sentry.id)
        syncSelectedSentry()
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
            syncSelectedSentry()
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
        syncSelectedSentry()
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
        syncSelectedSentry()
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
        syncSelectedSentry()
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
        syncSelectedSentry()
    }

    func selectEnemy(_ enemy: EnemyBlueprint) {
        selectedEnemyID = enemy.id
        tool = .enemy
    }

    func addEnemyAtCenter() {
        let point = GridPoint(row: blueprint.rows / 2, column: blueprint.columns / 2)
        if let created = insertEnemy(at: point) {
            selectedEnemyID = created.id
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
        syncSelectedEnemy()
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
            syncSelectedEnemy()
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
        syncSelectedSentry()
    }

    func updateSelectedSentryCooldown(_ cooldown: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(0.2, min(cooldown, 5.0))
        guard abs(sentry.fireCooldown - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.fireCooldown = clamped
        }
        syncSelectedSentry()
    }

    func updateSelectedSentryProjectileSpeed(_ speed: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(50.0, min(speed, 2000.0))
        guard abs(sentry.projectileSpeed - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.projectileSpeed = clamped
        }
        syncSelectedSentry()
    }

    func updateSelectedSentryProjectileSize(_ size: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(0.05, min(size, 2.0))
        guard abs(sentry.projectileSize - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.projectileSize = clamped
        }
        syncSelectedSentry()
    }

    func updateSelectedSentryProjectileLifetime(_ lifetime: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(0.1, min(lifetime, 12.0))
        guard abs(sentry.projectileLifetime - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.projectileLifetime = clamped
        }
        syncSelectedSentry()
    }

    func updateSelectedSentryProjectileBurstCount(_ count: Int) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(1, min(count, 12))
        guard sentry.projectileBurstCount != clamped else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.projectileBurstCount = clamped
        }
        syncSelectedSentry()
    }

    func updateSelectedSentryProjectileSpread(_ degrees: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(0.0, min(degrees, 90.0))
        guard abs(sentry.projectileSpreadDegrees - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.projectileSpreadDegrees = clamped
        }
        syncSelectedSentry()
    }

    func updateSelectedSentryHeatTurnRate(_ degreesPerSecond: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(30.0, min(degreesPerSecond, 720.0))
        guard abs(sentry.heatSeekingTurnRateDegreesPerSecond - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.heatSeekingTurnRateDegreesPerSecond = clamped
        }
        syncSelectedSentry()
    }

    func updateSelectedSentryProjectileKind(_ kind: SentryBlueprint.ProjectileKind) {
        guard let sentry = selectedSentry else { return }
        guard sentry.projectileKind != kind else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.projectileKind = kind
        }
        syncSelectedSentry()
    }

    func updateSelectedSentryAimTolerance(_ degrees: Double) {
        guard let sentry = selectedSentry else { return }
        let clamped = max(2.0, min(degrees, 45.0))
        guard abs(sentry.aimToleranceDegrees - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateSentry(id: sentry.id) { ref in
            ref.aimToleranceDegrees = clamped
        }
        syncSelectedSentry()
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

    func updateSelectedPlatformInitialProgress(_ progress: Double) {
        guard let platform = selectedPlatform else { return }
        let clamped = max(0.0, min(progress, 1.0))
        guard abs(platform.initialProgress - clamped) > 0.0001 else { return }
        captureSnapshot()
        blueprint.updateMovingPlatform(id: platform.id) { ref in
            ref.initialProgress = clamped
        }
        syncSelectedPlatform()
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
            syncSelectedPlatform()
        }
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

        if tool == .sentry {
            if let existing = sentry(at: point) {
                selectedSentryID = existing.id
                sentryDragID = existing.id
            } else if let newSentry = insertSentry(at: point) {
                selectedSentryID = newSentry.id
                sentryDragID = newSentry.id
            }
        } else {
            sentryDragID = nil
        }

        if tool == .enemy {
            if let existing = enemy(at: point) {
                selectedEnemyID = existing.id
                enemyDragID = existing.id
            } else if let newEnemy = insertEnemy(at: point) {
                selectedEnemyID = newEnemy.id
                enemyDragID = newEnemy.id
            }
        } else {
            enemyDragID = nil
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
            syncSelectedSentry()
            syncSelectedEnemy()
            sentryDragID = nil
            enemyDragID = nil
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
            model.syncSelectedSpawn()
            model.syncSelectedPlatform()
            model.syncSelectedSentry()
            model.syncSelectedEnemy()
        }
    }

    func redo() {
        scheduleMutation { model in
            guard let next = model.redoStack.popLast() else { return }
            model.undoStack.append(model.blueprint)
            model.blueprint = next
            model.syncSelectedSpawn()
            model.syncSelectedPlatform()
            model.syncSelectedSentry()
            model.syncSelectedEnemy()
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
                movePlatform(context: context, to: point)
            default:
                shapePreview = pointsForRectangle(from: dragStartPoint ?? point, to: point, mode: .fill)
            }
        case .sentry:
            moveSentry(to: point, isInitial: isInitial)
        case .enemy:
            moveEnemy(to: point, isInitial: isInitial)
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
        if let id = selectedSpawnID, blueprint.spawnPoint(id: id) != nil {
            blueprint.updateSpawn(id: id, to: point)
        } else if isInitial, let newSpawn = insertSpawn(at: point) {
            selectedSpawnID = newSpawn.id
        }
    }

    private func moveSentry(to point: GridPoint, isInitial: Bool) {
        guard blueprint.contains(point) else { return }
        if let dragID = sentryDragID, blueprint.sentry(id: dragID) != nil {
            blueprint.updateSentry(id: dragID) { ref in
                ref.coordinate = point
            }
        } else if isInitial {
            if let newSentry = insertSentry(at: point) {
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
            if let newEnemy = insertEnemy(at: point) {
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
    }

    private func syncSelectedSpawn() {
        if let id = selectedSpawnID, blueprint.spawnPoint(id: id) != nil {
            return
        }
        selectedSpawnID = blueprint.spawnPoints.first?.id
    }

    private func syncSelectedPlatform() {
        if let id = selectedPlatformID, blueprint.movingPlatform(id: id) != nil {
            return
        }
        selectedPlatformID = blueprint.movingPlatforms.first?.id
    }

    private func syncSelectedSentry() {
        if let id = selectedSentryID, blueprint.sentry(id: id) != nil {
            return
        }
        selectedSentryID = blueprint.sentries.first?.id
    }

    private func syncSelectedEnemy() {
        if let id = selectedEnemyID, blueprint.enemy(id: id) != nil {
            return
        }
        selectedEnemyID = blueprint.enemies.first?.id
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

    @discardableResult
    private func insertSentry(at point: GridPoint) -> SentryBlueprint? {
        guard let sentry = blueprint.addSentry(at: point) else { return nil }
        syncSelectedSentry()
        return sentry
    }

    @discardableResult
    private func insertEnemy(at point: GridPoint) -> EnemyBlueprint? {
        guard let enemy = blueprint.addEnemy(at: point) else { return nil }
        syncSelectedEnemy()
        return enemy
    }

    private func mutateSelectedEnemy(_ mutate: (inout EnemyBlueprint) -> Void) {
        guard let enemy = selectedEnemy else { return }
        captureSnapshot()
        blueprint.updateEnemy(id: enemy.id, mutate: mutate)
        syncSelectedEnemy()
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

    private func scheduleMutation(_ mutation: @escaping (MapEditorViewModel) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            mutation(self)
        }
    }
}

