// LevelBlueprint.swift
// Generic level description and engine adapters

import Foundation
import CoreGraphics
import SwiftUI

/// Grid-based coordinate used for map editing.
struct GridPoint: nonisolated Hashable, Identifiable {
    let row: Int
    let column: Int

    var id: String { "\(row)_\(column)" }

    init(row: Int, column: Int) {
        self.row = row
        self.column = column
    }

    func offsetting(rowDelta: Int = 0, columnDelta: Int = 0) -> GridPoint {
        GridPoint(row: row + rowDelta, column: column + columnDelta)
    }
}

/// Base tile definitions understood by the editor and adapters.
enum LevelTileKind: String, CaseIterable, Identifiable {
    case empty
    case stone
    case crimson
    case amber
    case sand
    case moss
    case teal
    case cobalt
    case obsidian
    case rampUpRight
    case rampUpLeft

    var id: String { rawValue }

    var isSolid: Bool {
        self != .empty
    }

    var displayName: String {
        switch self {
        case .empty: "Empty"
        case .stone: "Stone"
        case .crimson: "Crimson"
        case .amber: "Amber"
        case .sand: "Sand"
        case .moss: "Moss"
        case .teal: "Teal"
        case .cobalt: "Cobalt"
        case .obsidian: "Obsidian"
        case .rampUpRight: "Ramp Up Right"
        case .rampUpLeft: "Ramp Up Left"
        }
    }

    var fillColor: Color {
        switch self {
        case .empty: .clear
        case .stone: Color(red: 0.72, green: 0.72, blue: 0.75)
        case .crimson: Color(red: 0.78, green: 0.23, blue: 0.28)
        case .amber: Color(red: 0.95, green: 0.63, blue: 0.26)
        case .sand: Color(red: 0.89, green: 0.78, blue: 0.54)
        case .moss: Color(red: 0.40, green: 0.63, blue: 0.33)
        case .teal: Color(red: 0.27, green: 0.66, blue: 0.70)
        case .cobalt: Color(red: 0.29, green: 0.43, blue: 0.82)
        case .obsidian: Color(red: 0.18, green: 0.20, blue: 0.26)
        case .rampUpRight: Color(red: 0.47, green: 0.62, blue: 0.90)
        case .rampUpLeft: Color(red: 0.52, green: 0.76, blue: 0.58)
        }
    }

    var borderColor: Color {
        switch self {
        case .empty: .clear
        case .stone: Color(red: 0.47, green: 0.47, blue: 0.50)
        case .crimson: Color(red: 0.52, green: 0.15, blue: 0.19)
        case .amber: Color(red: 0.72, green: 0.44, blue: 0.14)
        case .sand: Color(red: 0.67, green: 0.58, blue: 0.37)
        case .moss: Color(red: 0.29, green: 0.46, blue: 0.25)
        case .teal: Color(red: 0.17, green: 0.49, blue: 0.52)
        case .cobalt: Color(red: 0.19, green: 0.30, blue: 0.58)
        case .obsidian: Color(red: 0.10, green: 0.12, blue: 0.17)
        case .rampUpRight: Color(red: 0.28, green: 0.43, blue: 0.70)
        case .rampUpLeft: Color(red: 0.30, green: 0.54, blue: 0.34)
        }
    }

    static var palette: [LevelTileKind] {
        allCases.filter { $0 != .empty }
    }

    var rampKind: RampData.Kind? {
        switch self {
        case .rampUpRight: return .upRight
        case .rampUpLeft: return .upLeft
        default: return nil
        }
    }

    var isRamp: Bool { rampKind != nil }

    var isRectangularSolid: Bool { isSolid && !isRamp }

    var flippedRamp: LevelTileKind? {
        switch self {
        case .rampUpRight: return .rampUpLeft
        case .rampUpLeft: return .rampUpRight
        default: return nil
        }
    }
}

struct PlayerSpawnPoint: Identifiable, Hashable {
    let id: UUID
    var name: String
    var coordinate: GridPoint

    init(id: UUID = UUID(), name: String, coordinate: GridPoint) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
    }
}

/// Immutable description of a grid-aligned level.
struct GridSize: Hashable {
    var rows: Int
    var columns: Int
}

struct MovingPlatformBlueprint: Identifiable, Hashable {
    let id: UUID
    var origin: GridPoint
    var size: GridSize
    var target: GridPoint
    var speed: Double
    var initialProgress: Double

    init(
        id: UUID = UUID(),
        origin: GridPoint,
        size: GridSize,
        target: GridPoint,
        speed: Double = 1.0,
        initialProgress: Double = 0.0
    ) {
        self.id = id
        self.origin = origin
        self.size = size
        self.target = target
        self.speed = speed
        self.initialProgress = initialProgress
        clampInitialProgress()
    }

    mutating func clampInitialProgress() {
        initialProgress = max(0.0, min(initialProgress, 1.0))
    }
}

struct SentryBlueprint: Identifiable, Hashable {
    enum ProjectileKind: String, CaseIterable, Hashable, Codable {
        case bolt
        case heatSeeking
        case laser
    }

    let id: UUID
    var coordinate: GridPoint
    var scanRange: Double
    var scanCenterDegrees: Double
    var scanArcDegrees: Double
    var sweepSpeedDegreesPerSecond: Double
    var fireCooldown: Double
    var projectileSpeed: Double
    var projectileSize: Double
    var projectileLifetime: Double
    var projectileBurstCount: Int
    var projectileSpreadDegrees: Double
    var aimToleranceDegrees: Double
    var initialFacingDegrees: Double
    var projectileKind: ProjectileKind
    var heatSeekingTurnRateDegreesPerSecond: Double

    init(
        id: UUID = UUID(),
        coordinate: GridPoint,
        scanRange: Double = 8.0,
        scanCenterDegrees: Double = 0.0,
        scanArcDegrees: Double = 90.0,
        sweepSpeedDegreesPerSecond: Double = 60.0,
        fireCooldown: Double = 1.2,
        projectileSpeed: Double = 900.0,
        projectileSize: Double = 0.18,
        projectileLifetime: Double = 5.0,
        projectileBurstCount: Int = 1,
        projectileSpreadDegrees: Double = 6.0,
        aimToleranceDegrees: Double = 6.0,
        initialFacingDegrees: Double? = nil,
        projectileKind: ProjectileKind = .bolt,
        heatSeekingTurnRateDegreesPerSecond: Double = 240.0
    ) {
        self.id = id
        self.coordinate = coordinate
        self.scanRange = scanRange
        self.scanCenterDegrees = scanCenterDegrees
        self.scanArcDegrees = scanArcDegrees
        self.sweepSpeedDegreesPerSecond = sweepSpeedDegreesPerSecond
        self.fireCooldown = fireCooldown
        self.projectileSpeed = projectileSpeed
        self.projectileSize = projectileSize
        self.projectileLifetime = projectileLifetime
        self.projectileBurstCount = projectileBurstCount
        self.projectileSpreadDegrees = projectileSpreadDegrees
        self.aimToleranceDegrees = aimToleranceDegrees
        let halfArc = max(5.0, scanArcDegrees * 0.5)
        let defaultFacing = scanCenterDegrees - halfArc
        let desired = initialFacingDegrees ?? defaultFacing
        self.initialFacingDegrees = desired
        self.projectileKind = projectileKind
        self.heatSeekingTurnRateDegreesPerSecond = heatSeekingTurnRateDegreesPerSecond
        clampInitialFacing()
        clampProjectileSettings()
    }

    mutating func clampInitialFacing() {
        let halfArc = max(5.0, scanArcDegrees * 0.5)
        let minAngle = scanCenterDegrees - halfArc
        let maxAngle = scanCenterDegrees + halfArc
        if initialFacingDegrees < minAngle {
            initialFacingDegrees = minAngle
        } else if initialFacingDegrees > maxAngle {
            initialFacingDegrees = maxAngle
        }
    }

    mutating func clampProjectileSettings() {
        projectileSpeed = max(50.0, min(projectileSpeed, 2000.0))
        projectileSize = max(0.05, min(projectileSize, 2.0))
        projectileLifetime = max(0.1, min(projectileLifetime, 12.0))
        projectileBurstCount = max(1, min(projectileBurstCount, 12))
        projectileSpreadDegrees = max(0.0, min(projectileSpreadDegrees, 90.0))
        heatSeekingTurnRateDegreesPerSecond = max(30.0, min(heatSeekingTurnRateDegreesPerSecond, 720.0))
    }
}

struct LevelBlueprint {
    var rows: Int
    var columns: Int
    var tileSize: Double
    private var tiles: [GridPoint: LevelTileKind]
    private(set) var spawnPoints: [PlayerSpawnPoint]
    private(set) var movingPlatforms: [MovingPlatformBlueprint]
    private(set) var sentries: [SentryBlueprint]

    init(
        rows: Int,
        columns: Int,
        tileSize: Double,
        tiles: [GridPoint: LevelTileKind] = [:],
        spawnPoints: [PlayerSpawnPoint] = [],
        movingPlatforms: [MovingPlatformBlueprint] = [],
        sentries: [SentryBlueprint] = []
    ) {
        self.rows = rows
        self.columns = columns
        self.tileSize = tileSize
        self.tiles = tiles
        self.spawnPoints = spawnPoints
        self.movingPlatforms = movingPlatforms
        self.sentries = sentries
    }

    func tile(at point: GridPoint) -> LevelTileKind {
        tiles[point] ?? .empty
    }

    func contains(_ point: GridPoint) -> Bool {
        point.row >= 0 && point.column >= 0 && point.row < rows && point.column < columns
    }

    func worldRect(for point: GridPoint) -> CGRect {
        let origin = CGPoint(x: Double(point.column) * tileSize, y: Double(point.row) * tileSize)
        let size = CGSize(width: tileSize, height: tileSize)
        return CGRect(origin: origin, size: size)
    }

    func updatingTile(_ kind: LevelTileKind, at point: GridPoint) -> LevelBlueprint {
        var copy = self
        copy.setTile(kind, at: point)
        return copy
    }

    mutating func setTile(_ kind: LevelTileKind, at point: GridPoint) {
        guard contains(point) else { return }
        if kind == .empty {
            tiles.removeValue(forKey: point)
        } else {
            tiles[point] = kind
        }
    }

    mutating func toggleSolid(at point: GridPoint) {
        let kind: LevelTileKind = tile(at: point).isSolid ? .empty : .stone
        setTile(kind, at: point)
    }

    @discardableResult
    mutating func addSpawnPoint(named name: String? = nil, at point: GridPoint) -> PlayerSpawnPoint? {
        guard contains(point) else { return nil }
        let ordinal = spawnPoints.count + 1
        let spawn = PlayerSpawnPoint(name: name ?? "Spawn \(ordinal)", coordinate: point)
        spawnPoints.append(spawn)
        return spawn
    }

    mutating func updateSpawn(id: PlayerSpawnPoint.ID, to point: GridPoint) {
        guard contains(point) else { return }
        guard let index = spawnPoints.firstIndex(where: { $0.id == id }) else { return }
        spawnPoints[index].coordinate = point
    }

    mutating func removeSpawn(_ spawn: PlayerSpawnPoint) {
        spawnPoints.removeAll { $0.id == spawn.id }
    }

    func spawnPoint(id: PlayerSpawnPoint.ID) -> PlayerSpawnPoint? {
        spawnPoints.first(where: { $0.id == id })
    }

    mutating func renameSpawn(id: PlayerSpawnPoint.ID, to name: String) {
        guard let index = spawnPoints.firstIndex(where: { $0.id == id }) else { return }
        spawnPoints[index].name = name
    }

    func solidTiles() -> [GridPoint] {
        tiles.compactMap { element in
            element.value.isSolid ? element.key : nil
        }
    }

    func tileEntries() -> [(GridPoint, LevelTileKind)] {
        Array(tiles)
    }

    // MARK: - Moving Platforms

    @discardableResult
    mutating func addMovingPlatform(
        origin: GridPoint,
        size: GridSize,
        target: GridPoint,
        speed: Double = 1.0,
        initialProgress: Double = 0.0
    ) -> MovingPlatformBlueprint? {
        guard contains(origin) else { return nil }
        guard contains(GridPoint(row: origin.row + size.rows - 1, column: origin.column + size.columns - 1)) else { return nil }
        guard contains(target) else { return nil }
        guard contains(GridPoint(row: target.row + size.rows - 1, column: target.column + size.columns - 1)) else { return nil }
        let platform = MovingPlatformBlueprint(
            origin: origin,
            size: size,
            target: target,
            speed: speed,
            initialProgress: initialProgress
        )
        movingPlatforms.append(platform)
        return platform
    }

    mutating func updateMovingPlatform(id: MovingPlatformBlueprint.ID, mutate: (inout MovingPlatformBlueprint) -> Void) {
        guard let index = movingPlatforms.firstIndex(where: { $0.id == id }) else { return }
        mutate(&movingPlatforms[index])
        movingPlatforms[index].clampInitialProgress()
    }

    mutating func removeMovingPlatform(id: MovingPlatformBlueprint.ID) {
        movingPlatforms.removeAll { $0.id == id }
    }

    func movingPlatform(id: MovingPlatformBlueprint.ID) -> MovingPlatformBlueprint? {
        movingPlatforms.first(where: { $0.id == id })
    }

    // MARK: - Sentries

    @discardableResult
    mutating func addSentry(at point: GridPoint) -> SentryBlueprint? {
        guard contains(point) else { return nil }
        let sentry = SentryBlueprint(coordinate: point)
        sentries.append(sentry)
        return sentry
    }

    @discardableResult
    mutating func addSentry(_ sentry: SentryBlueprint) -> SentryBlueprint? {
        guard contains(sentry.coordinate) else { return nil }
        guard self.sentry(at: sentry.coordinate) == nil else { return nil }
        var copy = sentry
        copy.clampInitialFacing()
        copy.clampProjectileSettings()
        sentries.append(copy)
        return copy
    }

    mutating func removeSentry(id: SentryBlueprint.ID) {
        sentries.removeAll { $0.id == id }
    }

    mutating func updateSentry(id: SentryBlueprint.ID, mutate: (inout SentryBlueprint) -> Void) {
        guard let index = sentries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&sentries[index])
        sentries[index].clampInitialFacing()
        sentries[index].clampProjectileSettings()
    }

    func sentry(id: SentryBlueprint.ID) -> SentryBlueprint? {
        sentries.first(where: { $0.id == id })
    }

    func sentry(at point: GridPoint) -> SentryBlueprint? {
        sentries.first(where: { $0.coordinate.row == point.row && $0.coordinate.column == point.column })
    }
}

/// Adapters translate a blueprint into runtime-ready data for a rendering / simulation engine.
protocol LevelRuntimeAdapter {
    associatedtype PreviewView: View
    /// Human-readable engine name for UI toggles.
    static var engineName: String { get }
    /// Builds a play-preview view. The adapter is responsible for starting/stopping underlying runtime.
    func makePreview(for blueprint: LevelBlueprint, input: InputController, onStop: @escaping () -> Void) -> PreviewView
}

/// Engines that need to receive callbacks when the preview becomes active/inactive can conform to this protocol.
protocol LevelPreviewLifecycle {
    func start()
    func stop()
}
