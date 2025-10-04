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

struct MapEditorView: View {
    private typealias EnemyMovementChoice = MapEditorViewModel.EnemyMovementChoice
    private typealias EnemyBehaviorChoice = MapEditorViewModel.EnemyBehaviorChoice
    private typealias EnemyAttackChoice = MapEditorViewModel.EnemyAttackChoice

    @StateObject private var viewModel = MapEditorViewModel()
    @State private var isPreviewing = false
    @State private var spawnNameDraft: String = ""
    @State private var input = InputController()
    @FocusState private var focused: Bool

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
            adapter.makePreview(for: viewModel.blueprint, input: input) {
                isPreviewing = false
                focusEditor()
            }
            .ignoresSafeArea()
        }
        .onChange(of: viewModel.selectedSpawnID) {
            spawnNameDraft = viewModel.selectedSpawn?.name ?? ""
        }
        .onChange(of: viewModel.blueprint.spawnPoints) {
            spawnNameDraft = viewModel.selectedSpawn?.name ?? ""
        }
        .focusable()
        .focused($focused)
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
        .onKeyPress(phases: [.down, .up]) { kp in
            switch kp.phase {
            case .down:
                input.handleKeyDown(kp)
                if handleEditorCommand(for: kp) { return .handled }
                if !isPreviewing { input.drainPressedCommands() }
                return isHandledKey(kp) ? .handled : .ignored
            case .up:
                input.handleKeyUp(kp)
                if !isPreviewing { input.drainPressedCommands() }
                return isHandledKey(kp) ? .handled : .ignored
            default:
                return .ignored
            }
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
            selectedSentryID: viewModel.selectedSentryID,
            selectedEnemyID: viewModel.selectedEnemyID,
            previewColor: viewModel.paintTileKind.fillColor,
            hoveredPoint: viewModel.hoveredPoint,
            onHover: viewModel.updateHover,
            onDragBegan: viewModel.handleDragBegan,
            onDragChanged: viewModel.handleDragChanged,
            onDragEnded: viewModel.handleDragEnded,
            onFocusRequested: focusEditorIfNeeded
        )
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 20) {
            levelNameSection
            tilePaletteSection
            toolsSection
            drawModeSection
            canvasControls
            enemySection
            sentrySection
            platformSection
            spawnSection
            quickActions
            Spacer(minLength: 24)
        }
    }

    private var enemySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Enemies")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.tool = .enemy
                } label: {
                    Label("Enemy Tool", systemImage: "figure.walk")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.addEnemyAtCenter()
                } label: {
                    Label("Add Enemy", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
            }

            let enemies = viewModel.blueprint.enemies
            if enemies.isEmpty {
                Text("Use the Enemy tool to place configurable AI actors with patrols, chase/flee logic, and melee or ranged attacks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                let columns = Array(repeating: GridItem(.flexible(minimum: 32, maximum: 50), spacing: 6), count: 4)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(enemies.enumerated()), id: \.element.id) { index, enemy in
                        Button {
                            viewModel.selectEnemy(enemy)
                        } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(viewModel.enemyColor(for: index).opacity(0.75))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(viewModel.selectedEnemyID == enemy.id ? Color.white : Color.clear, lineWidth: 2)
                                )
                                .overlay(
                                    Text("\(index + 1)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Enemy #\(index + 1)")
                    }
                }
            }

            if let enemy = viewModel.selectedEnemy {
                enemyDetailPanel(enemy: enemy)
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
                HStack(spacing: 8) {
                    Button {
                        viewModel.toggleSelectedRampOrientation()
                    } label: {
                        Label("Flip Ramp", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)

                    Text("Ramp tiles paint with the shown slope; flip to match your layout.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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

    private var sentrySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sentries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.tool = .sentry
                } label: {
                    Label("Sentry Tool", systemImage: "dot.radiowaves.right")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
            }

            let sentries = viewModel.blueprint.sentries
            if sentries.isEmpty {
                Text("Use the Sentry tool to place automated turrets that sweep for players.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                let columns = Array(repeating: GridItem(.flexible(minimum: 32, maximum: 50), spacing: 8), count: 4)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(sentries.enumerated()), id: \.element.id) { index, sentry in
                        Button {
                            viewModel.selectSentry(sentry)
                        } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(viewModel.sentryColor(for: index).opacity(0.75))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(viewModel.selectedSentryID == sentry.id ? Color.white : Color.clear, lineWidth: 2)
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

            if let sentry = viewModel.selectedSentry {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Selected Sentry")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("Coordinate: r\(sentry.coordinate.row) c\(sentry.coordinate.column)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    let rangeBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.scanRange ?? sentry.scanRange },
                        set: { viewModel.updateSelectedSentryRange($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: rangeBinding, in: 1.0...32.0, step: 0.5)
                        Text(String(format: "Scan Range: %.1f tiles", rangeBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    let centerBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.scanCenterDegrees ?? sentry.scanCenterDegrees },
                        set: { viewModel.updateSelectedSentryCenter($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: centerBinding, in: -180...180, step: 1)
                        Text(String(format: "Scan Center: %.0f°", centerBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    let arcBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.scanArcDegrees ?? sentry.scanArcDegrees },
                        set: { viewModel.updateSelectedSentryArc($0) }
                    )
                    let angleRange = viewModel.sentryInitialAngleRange(sentry)
                    let initialAngleBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.initialFacingDegrees ?? sentry.initialFacingDegrees },
                        set: { viewModel.updateSelectedSentryInitialAngle($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: arcBinding, in: 10...240, step: 1)
                        Text(String(format: "Sweep Arc: %.0f°", arcBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: initialAngleBinding, in: angleRange, step: 1)
                        Text(String(format: "Initial Angle: %.0f°", initialAngleBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    let sweepBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.sweepSpeedDegreesPerSecond ?? sentry.sweepSpeedDegreesPerSecond },
                        set: { viewModel.updateSelectedSentrySweepSpeed($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: sweepBinding, in: 10...360, step: 5)
                        Text(String(format: "Sweep Speed: %.0f°/s", sweepBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    let kindBinding = Binding<SentryBlueprint.ProjectileKind>(
                        get: { viewModel.selectedSentry?.projectileKind ?? sentry.projectileKind },
                        set: { viewModel.updateSelectedSentryProjectileKind($0) }
                    )
                    Picker("Projectile Type", selection: kindBinding) {
                        ForEach(SentryBlueprint.ProjectileKind.allCases, id: \.self) { kind in
                            Text(kind.displayLabel).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    let currentKind = viewModel.selectedSentry?.projectileKind ?? sentry.projectileKind

                    let projectileBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.projectileSpeed ?? sentry.projectileSpeed },
                        set: { viewModel.updateSelectedSentryProjectileSpeed($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: projectileBinding, in: 50...2000, step: 25)
                        Text(String(format: currentKind == .laser ? "Beam Intensity: %.0f" : "Projectile Speed: %.0f", projectileBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(currentKind == .laser)

                    let sizeBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.projectileSize ?? sentry.projectileSize },
                        set: { viewModel.updateSelectedSentryProjectileSize($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: sizeBinding, in: 0.05...2.0, step: 0.05)
                        Text(String(format: "Projectile Size: %.2f tiles", sizeBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    let lifetimeBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.projectileLifetime ?? sentry.projectileLifetime },
                        set: { viewModel.updateSelectedSentryProjectileLifetime($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: lifetimeBinding, in: 0.1...12.0, step: 0.1)
                        let label = currentKind == .laser ? "Beam Duration" : "Lifetime"
                        Text(String(format: "%@: %.1fs", label, lifetimeBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    let burstBinding = Binding<Int>(
                        get: { viewModel.selectedSentry?.projectileBurstCount ?? sentry.projectileBurstCount },
                        set: { viewModel.updateSelectedSentryProjectileBurstCount($0) }
                    )
                    Stepper(value: burstBinding, in: 1...12) {
                        Text("Burst Count: \(burstBinding.wrappedValue)")
                    }

                    let spreadBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.projectileSpreadDegrees ?? sentry.projectileSpreadDegrees },
                        set: { viewModel.updateSelectedSentryProjectileSpread($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: spreadBinding, in: 0...90, step: 1)
                        Text(String(format: "Spread: %.0f°", spreadBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(burstBinding.wrappedValue <= 1)

                    if currentKind == .heatSeeking {
                        let turnBinding = Binding<Double>(
                            get: { viewModel.selectedSentry?.heatSeekingTurnRateDegreesPerSecond ?? sentry.heatSeekingTurnRateDegreesPerSecond },
                            set: { viewModel.updateSelectedSentryHeatTurnRate($0) }
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Slider(value: turnBinding, in: 30...720, step: 10)
                            Text(String(format: "Turn Rate: %.0f°/s", turnBinding.wrappedValue))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    let cooldownBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.fireCooldown ?? sentry.fireCooldown },
                        set: { viewModel.updateSelectedSentryCooldown($0) }
                    )
                    Stepper(value: cooldownBinding, in: 0.2...5.0, step: 0.1) {
                        Text(String(format: "Cooldown: %.1fs", cooldownBinding.wrappedValue))
                    }

                    let toleranceBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.aimToleranceDegrees ?? sentry.aimToleranceDegrees },
                        set: { viewModel.updateSelectedSentryAimTolerance($0) }
                    )
                    Stepper(value: toleranceBinding, in: 2...45, step: 1) {
                        Text(String(format: "Aim Tolerance: %.0f°", toleranceBinding.wrappedValue))
                    }

                    Button {
                        viewModel.duplicateSelectedSentry()
                    } label: {
                        Label("Duplicate Sentry", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        viewModel.removeSentry(sentry)
                    } label: {
                        Label("Remove Sentry", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
    
    private func isHandledKey(_ kp: KeyPress) -> Bool {
        // Any key we map in InputController should return handled.
        // This avoids arrow keys accidentally scrolling a parent scroll view.
        switch kp.key {
        case .leftArrow, .rightArrow, .upArrow, .escape:
            return true
        default:
            break
        }
        let ch = kp.characters.lowercased()
        if ch == "a" || ch == "d" || ch == "w" || ch == " " { return true }
        if kp.modifiers.contains(.command), (ch == "z" || ch == "y" || ch == "r") { return true }
        return false
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
                        get: { viewModel.selectedPlatform?.target.row ?? platform.target.row },
                        set: { viewModel.updateSelectedPlatformTarget(row: $0) }
                    )
                    let colBinding = Binding<Int>(
                        get: { viewModel.selectedPlatform?.target.column ?? platform.target.column },
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

                    let progressBinding = Binding<Double>(
                        get: { viewModel.selectedPlatform?.initialProgress ?? platform.initialProgress },
                        set: { viewModel.updateSelectedPlatformInitialProgress($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: progressBinding, in: 0...1, step: 0.01)
                        Text(String(format: "Start Position: %.0f%%", progressBinding.wrappedValue * 100))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        viewModel.duplicateSelectedPlatform()
                    } label: {
                        Label("Duplicate Platform", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(.bordered)

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

    private func focusEditor() {
        focused = true
    }

    private func focusEditorIfNeeded() {
        if !focused {
            focusEditor()
        }
    }

private func handleEditorCommand(for keyPress: KeyPress) -> Bool {
        let normalized = keyPress.characters.lowercased()
        let hasCommand = keyPress.modifiers.contains(.command)
        let hasShift = keyPress.modifiers.contains(.shift)

        var action: (() -> Void)?

        if keyPress.key == .escape {
            action = {
                if isPreviewing {
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
            }
        }

        guard let action else { return false }

        DispatchQueue.main.async {
            action()
        }

        return true
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

            Button(action: openPreviewIfPossible) {
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

    private func openPreviewIfPossible() {
        guard !isPreviewing else { return }
        guard !viewModel.blueprint.spawnPoints.isEmpty else { return }
        isPreviewing = true
    }
}

private extension SentryBlueprint.ProjectileKind {
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

private extension EnemyBlueprint.Attack {
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

private extension EnemyBlueprint {
    var behaviorLabelPrefix: String {
        switch behavior {
        case .passive: return "P"
        case .chase: return "C"
        case .flee: return "F"
        case .strafe: return "R"
        }
    }
}

private struct MapCanvasView: View {
    let blueprint: LevelBlueprint
    let previewTiles: Set<GridPoint>
    let showGrid: Bool
    let zoom: Double
    let selectedSpawnID: PlayerSpawnPoint.ID?
    let selectedPlatformID: MovingPlatformBlueprint.ID?
    let selectedSentryID: SentryBlueprint.ID?
    let selectedEnemyID: EnemyBlueprint.ID?
    let previewColor: Color
    let hoveredPoint: GridPoint?
    let onHover: (GridPoint?) -> Void
    let onDragBegan: (GridPoint) -> Void
    let onDragChanged: (GridPoint) -> Void
    let onDragEnded: (GridPoint?) -> Void
    let onFocusRequested: () -> Void

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

                    let path: Path
                    if let rampKind = kind.rampKind {
                        var rampPath = Path()
                        let minX = tileRect.minX
                        let maxX = tileRect.maxX
                        let minY = tileRect.minY
                        let maxY = tileRect.maxY
                        switch rampKind {
                        case .upRight:
                            rampPath.move(to: CGPoint(x: minX, y: maxY))
                            rampPath.addLine(to: CGPoint(x: maxX, y: maxY))
                            rampPath.addLine(to: CGPoint(x: maxX, y: minY))
                        case .upLeft:
                            rampPath.move(to: CGPoint(x: minX, y: minY))
                            rampPath.addLine(to: CGPoint(x: minX, y: maxY))
                            rampPath.addLine(to: CGPoint(x: maxX, y: maxY))
                        }
                        rampPath.closeSubpath()
                        path = rampPath
                    } else {
                        path = Path(tileRect)
                    }

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

                for (index, enemy) in blueprint.enemies.enumerated() {
                    drawEnemy(enemy, index: index, origin: origin, tileSize: tileSize, context: &context)
                }

                for (index, sentry) in blueprint.sentries.enumerated() {
                    drawSentry(
                        sentry,
                        index: index,
                        origin: origin,
                        tileSize: tileSize,
                        context: &context
                    )
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
            .contentShape(Rectangle())
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
                onFocusRequested()
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
                onFocusRequested()
                let location = CGPoint(x: value.location.x - origin.x, y: value.location.y - origin.y)
                let point = pointForLocation(location, tileSize: tileSize, mapSize: mapSize)
                if !isDragging, let point {
                    onDragBegan(point)
                }
                isDragging = false
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

    private func drawSentry(
        _ sentry: SentryBlueprint,
        index: Int,
        origin: CGPoint,
        tileSize: CGFloat,
        context: inout GraphicsContext
    ) {
        let color = SentryPalette.color(for: index)
        let center = CGPoint(
            x: origin.x + (CGFloat(sentry.coordinate.column) + 0.5) * tileSize,
            y: origin.y + (CGFloat(sentry.coordinate.row) + 0.5) * tileSize
        )
        let baseRadius = tileSize * 0.35
        let circle = Path(ellipseIn: CGRect(x: center.x - baseRadius, y: center.y - baseRadius, width: baseRadius * 2, height: baseRadius * 2))
        context.fill(circle, with: .color(color.opacity(0.85)))

        if sentry.id == selectedSentryID {
            context.stroke(circle, with: .color(.white), lineWidth: 2)
        }

        let rangePixels = CGFloat(sentry.scanRange) * tileSize
        if rangePixels > 4 {
            let centerAngle = sentry.scanCenterDegrees * .pi / 180.0
            let halfArc = max(5.0, sentry.scanArcDegrees * 0.5) * .pi / 180.0
            let startAngle = centerAngle - halfArc
            let endAngle = centerAngle + halfArc
            var wedge = Path()
            wedge.move(to: center)
            let segments = max(12, Int(sentry.scanArcDegrees / 10.0))
            for i in 0...segments {
                let t = Double(i) / Double(segments)
                let angle = startAngle + (endAngle - startAngle) * t
                let point = CGPoint(
                    x: center.x + CGFloat(cos(angle)) * rangePixels,
                    y: center.y + CGFloat(sin(angle)) * rangePixels
                )
                wedge.addLine(to: point)
            }
            wedge.closeSubpath()
            context.fill(wedge, with: .color(color.opacity(0.15)))

            var line = Path()
            let tip = CGPoint(
                x: center.x + CGFloat(cos(centerAngle)) * rangePixels,
                y: center.y + CGFloat(sin(centerAngle)) * rangePixels
            )
            line.move(to: center)
            line.addLine(to: tip)
            context.stroke(line, with: .color(color.opacity(0.5)), lineWidth: 2)
        }
    }

    private func drawEnemy(
        _ enemy: EnemyBlueprint,
        index: Int,
        origin: CGPoint,
        tileSize: CGFloat,
        context: inout GraphicsContext
    ) {
        let color = EnemyPalette.color(for: index)
        let center = CGPoint(
            x: origin.x + (CGFloat(enemy.coordinate.column) + 0.5) * tileSize,
            y: origin.y + (CGFloat(enemy.coordinate.row) + 0.5) * tileSize
        )
        let tileSizeValue = max(Double(tileSize), 1.0)
        let widthScale = min(max(enemy.size.x / tileSizeValue, 0.4), 1.8)
        let heightScale = min(max(enemy.size.y / tileSizeValue, 0.6), 2.1)
        let drawWidth = tileSize * CGFloat(widthScale)
        let drawHeight = tileSize * CGFloat(heightScale)
        let rect = CGRect(
            x: center.x - drawWidth * 0.5,
            y: center.y - drawHeight * 0.5,
            width: drawWidth,
            height: drawHeight
        )
        let path = Path(roundedRect: rect, cornerRadius: min(drawWidth, drawHeight) * 0.2)
        context.fill(path, with: .color(color.opacity(0.85)))
        if enemy.id == selectedEnemyID {
            context.stroke(path, with: .color(.white), lineWidth: 2)
        } else {
            context.stroke(path, with: .color(color.opacity(0.6)), lineWidth: 1)
        }

        let attackLabel: String
        switch enemy.attack {
        case .none: attackLabel = enemy.behaviorLabelPrefix
        case .shooter: attackLabel = "R"
        case .sword: attackLabel = "S"
        case .punch: attackLabel = "P"
        }

        context.draw(
            Text(attackLabel)
                .font(.system(size: max(10, tileSize * 0.4), weight: .bold, design: .rounded))
                .foregroundStyle(.white),
            at: center,
            anchor: .center
        )

        if case .wallBounce(let axis, _) = enemy.movement {
            var indicator = Path()
            switch axis {
            case .horizontal:
                indicator.move(to: CGPoint(x: rect.minX, y: center.y))
                indicator.addLine(to: CGPoint(x: rect.maxX, y: center.y))
            case .vertical:
                indicator.move(to: CGPoint(x: center.x, y: rect.minY))
                indicator.addLine(to: CGPoint(x: center.x, y: rect.maxY))
            }
            context.stroke(indicator, with: .color(Color.white.opacity(0.7)), lineWidth: 1.5)
        }
    }
}

#Preview {
    MapEditorView()
        .frame(minWidth: 900, minHeight: 600)
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

private struct TileSwatch: View {
    let tile: LevelTileKind
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemBackground))

            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)

                if let ramp = tile.rampKind {
                    var path = Path()
                    switch ramp {
                    case .upRight:
                        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                    case .upLeft:
                        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                    }
                    path.closeSubpath()
                    context.fill(path, with: .color(tile.fillColor))
                    context.stroke(path, with: .color(tile.borderColor), lineWidth: 2)
                } else {
                    let shape = Path(roundedRect: rect, cornerRadius: 6)
                    context.fill(shape, with: .color(tile.fillColor))
                    context.stroke(shape, with: .color(tile.borderColor), lineWidth: 2)
                }
            }
            .allowsHitTesting(false)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .frame(width: 48, height: 48)
    }
}
