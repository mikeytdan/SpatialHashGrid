// MapDocumentTests.swift
// Coverage Notes:
// - 2025-10-07: Added JSON round-trip coverage for LevelBlueprint persistence.

import Foundation
import Testing
@testable import SpatialHashGrid

@Suite
struct MapDocumentTests {

    @Test
    func roundTripPreservesBlueprintState() throws {
        var blueprint = LevelBlueprint(rows: 12, columns: 18, tileSize: 32)
        blueprint.setTile(.stone, at: GridPoint(row: 0, column: 0))
        blueprint.setTile(.rampUpLeft, at: GridPoint(row: 2, column: 3))
        blueprint.setTile(.amber, at: GridPoint(row: 5, column: 6))

        #expect(blueprint.addSpawnPoint(named: "Start", at: GridPoint(row: 8, column: 2)) != nil)

        let platformOrigin = GridPoint(row: 9, column: 1)
        let platformTarget = GridPoint(row: 9, column: 6)
        #expect(
            blueprint.addMovingPlatform(
                origin: platformOrigin,
                size: GridSize(rows: 1, columns: 3),
                target: platformTarget,
                speed: 2.5,
                initialProgress: 0.35
            ) != nil
        )

        if let sentry = blueprint.addSentry(at: GridPoint(row: 4, column: 10)) {
            blueprint.updateSentry(id: sentry.id) { sentry in
                sentry.scanArcDegrees = 120
                sentry.projectileKind = .laser
                sentry.projectileBurstCount = 3
                sentry.fireCooldown = 0.9
            }
        } else {
            Issue.record("Failed to add sentry for round-trip test")
        }

        if let enemy = blueprint.addEnemy(at: GridPoint(row: 6, column: 12)) {
            blueprint.updateEnemy(id: enemy.id) { enemy in
                enemy.movement = .perimeter(width: 80, height: 60, speed: 140, clockwise: false)
                enemy.behavior = .chase(range: 420, speedMultiplier: 1.7, verticalTolerance: 36)
                enemy.attack = .shooter(speed: 520, cooldown: 0.8, range: 280)
                enemy.size = Vec2(40, 52)
            }
        } else {
            Issue.record("Failed to add enemy for round-trip test")
        }

        let document = MapDocument(
            blueprint: blueprint,
            metadata: MapDocumentMetadata(name: "Regression Map")
        )

        let encoded = try document.encodedData(prettyPrinted: false)
        let decoded = try MapDocument.decode(from: encoded)
        let restored = decoded.blueprint

        #expect(decoded.version == MapDocument.latestVersion)
        #expect(decoded.metadata?.name == "Regression Map")
        #expect(restored.rows == blueprint.rows)
        #expect(restored.columns == blueprint.columns)
        #expect(restored.tileSize == blueprint.tileSize)

        let originalTiles = Set(blueprint.tileEntries().map { ($0.0.row, $0.0.column, $0.1) })
        let restoredTiles = Set(restored.tileEntries().map { ($0.0.row, $0.0.column, $0.1) })
        #expect(restoredTiles == originalTiles)

        #expect(Set(restored.spawnPoints) == Set(blueprint.spawnPoints))
        #expect(Set(restored.movingPlatforms) == Set(blueprint.movingPlatforms))
        #expect(Set(restored.sentries) == Set(blueprint.sentries))
        #expect(Set(restored.enemies) == Set(blueprint.enemies))
    }

    @Test
    func tileEncodingGroupsByKind() throws {
        var blueprint = LevelBlueprint(rows: 4, columns: 4, tileSize: 32)
        blueprint.setTile(.stone, at: GridPoint(row: 0, column: 0))
        blueprint.setTile(.stone, at: GridPoint(row: 0, column: 1))
        blueprint.setTile(.amber, at: GridPoint(row: 2, column: 3))

        let document = MapDocument(blueprint: blueprint)
        let encoded = try document.encodedData(prettyPrinted: false)
        let json = try JSONSerialization.jsonObject(with: encoded, options: []) as? [String: Any]
        let map = json?["map"] as? [String: Any]
        let tileGroups = map?["tileGroups"] as? [[String: Any]]

        #expect(tileGroups?.count == 2)

        if
            let stone = tileGroups?.first(where: { ($0["kind"] as? String) == "stone" }),
            let coordinates = stone["coordinates"] as? [[Any]]
        {
            #expect(coordinates.count == 2)
        } else {
            Issue.record("Stone group missing or malformed")
        }

        if
            let amber = tileGroups?.first(where: { ($0["kind"] as? String) == "amber" }),
            let coordinates = amber["coordinates"] as? [[Any]],
            let coordinate = coordinates.first,
            coordinate.count == 2,
            let rowNumber = coordinate[0] as? NSNumber,
            let columnNumber = coordinate[1] as? NSNumber
        {
            #expect(rowNumber.intValue == 2)
            #expect(columnNumber.intValue == 3)
        } else {
            Issue.record("Amber group missing or malformed")
        }
    }

    @Test
    func unsupportedVersionYieldsError() {
        let payload = Data("{\"version\": 999}".utf8)

        do {
            _ = try MapDocument.decode(from: payload)
            Issue.record("Decoding should have thrown an unsupportedVersion error")
        } catch let error as MapDocumentError {
            #expect(error == .unsupportedVersion(999))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func exportFilenameStripsIllegalCharacters() {
        let vm = MapEditorViewModel()
        vm.levelName = "  My:/Fancy*Map?  "
        let filename = vm.makeExportFilename()
        #expect(filename == "My Fancy Map")
    }

    @Test
    func decodesLegacyTileArray() throws {
        let json = """
        {
          "version": 1,
          "map": {
            "rows": 3,
            "columns": 3,
            "tileSize": 32,
            "tiles": [
              {"point": {"row": 1, "column": 2}, "kind": "stone"},
              {"point": {"row": 2, "column": 2}, "kind": "amber"}
            ],
            "spawnPoints": [],
            "movingPlatforms": [],
            "sentries": [],
            "enemies": []
          }
        }
        """.data(using: .utf8)!

        let document = try MapDocument.decode(from: json)
        let blueprint = document.blueprint
        #expect(blueprint.tile(at: GridPoint(row: 1, column: 2)) == .stone)
        #expect(blueprint.tile(at: GridPoint(row: 2, column: 2)) == .amber)
    }

    @Test
    func persistenceIgnoresInvalidAutosavePayload() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        let controller = MapPersistenceController(baseDirectoryOverride: base)
        let autosaveURL = base
            .appendingPathComponent("SpatialHashGridMaps", isDirectory: true)
            .appendingPathComponent("Autosave.map.json", isDirectory: false)

        try Data("not a map".utf8).write(to: autosaveURL)

        #expect(controller.loadAutosave() == nil)
    }
}
