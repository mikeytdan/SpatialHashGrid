import Foundation

enum MapDocumentError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case missingPayload

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Map version \(version) is not supported."
        case .missingPayload:
            return "The map file is missing required data."
        }
    }
}

struct MapDocumentMetadata: Codable, Equatable {
    var name: String

    init(name: String) {
        self.name = name
    }
}

struct MapDocument: Codable {
    static let latestVersion = 1

    var version: Int
    var metadata: MapDocumentMetadata?
    var blueprint: LevelBlueprint

    private enum CodingKeys: String, CodingKey {
        case version
        case metadata
        case map
    }

    init(blueprint: LevelBlueprint, metadata: MapDocumentMetadata? = nil) {
        self.version = Self.latestVersion
        self.metadata = metadata
        self.blueprint = blueprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .version)
        self.metadata = try container.decodeIfPresent(MapDocumentMetadata.self, forKey: .metadata)

        switch decodedVersion {
        case 1:
            guard container.contains(.map) else { throw MapDocumentError.missingPayload }
            let snapshot = try container.decode(MapDocumentV1.self, forKey: .map)
            self.blueprint = snapshot.makeBlueprint()
            self.version = decodedVersion
        default:
            throw MapDocumentError.unsupportedVersion(decodedVersion)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(MapDocument.latestVersion, forKey: .version)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encode(MapDocumentV1(blueprint: blueprint), forKey: .map)
    }

    func encodedData(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        } else {
            encoder.outputFormatting = [.sortedKeys]
        }
        return try encoder.encode(self)
    }

    static func decode(from data: Data) throws -> MapDocument {
        let decoder = JSONDecoder()
        return try decoder.decode(MapDocument.self, from: data)
    }
}

private struct MapDocumentV1: Codable, Equatable {
    struct TileCoordinate: Codable, Equatable {
        var row: Int
        var column: Int

        init(row: Int, column: Int) {
            self.row = row
            self.column = column
        }

        init(point: GridPoint) {
            self.init(row: point.row, column: point.column)
        }

        var point: GridPoint { GridPoint(row: row, column: column) }

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            guard !container.isAtEnd else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Tile coordinate missing row value.")
            }
            let row = try container.decode(Int.self)
            guard !container.isAtEnd else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Tile coordinate missing column value.")
            }
            let column = try container.decode(Int.self)
            self.row = row
            self.column = column
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(row)
            try container.encode(column)
        }
    }

    struct TileGroup: Codable, Equatable {
        var kind: LevelTileKind
        var coordinates: [TileCoordinate]
    }

    struct TileRecord: Codable, Equatable {
        var point: GridPoint
        var kind: LevelTileKind
    }

    var rows: Int
    var columns: Int
    var tileSize: Double
    var tileGroups: [TileGroup]
    var spawnPoints: [PlayerSpawnPoint]
    var movingPlatforms: [MovingPlatformBlueprint]
    var sentries: [SentryBlueprint]
    var enemies: [EnemyBlueprint]

    init(blueprint: LevelBlueprint) {
        self.rows = blueprint.rows
        self.columns = blueprint.columns
        self.tileSize = blueprint.tileSize
        let entries = blueprint.tileEntries()
        self.tileGroups = MapDocumentV1.makeTileGroups(from: entries)
        self.spawnPoints = blueprint.spawnPoints
        self.movingPlatforms = blueprint.movingPlatforms
        self.sentries = blueprint.sentries
        self.enemies = blueprint.enemies
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.rows = try container.decode(Int.self, forKey: .rows)
        self.columns = try container.decode(Int.self, forKey: .columns)
        self.tileSize = try container.decode(Double.self, forKey: .tileSize)
        if let groups = try container.decodeIfPresent([TileGroup].self, forKey: .tileGroups) {
            self.tileGroups = MapDocumentV1.sorted(groups: groups)
        } else {
            let legacyTiles = try container.decodeIfPresent([TileRecord].self, forKey: .tiles) ?? []
            let entries = legacyTiles.map { ($0.point, $0.kind) }
            self.tileGroups = MapDocumentV1.makeTileGroups(from: entries)
        }
        self.spawnPoints = try container.decodeIfPresent([PlayerSpawnPoint].self, forKey: .spawnPoints) ?? []
        self.movingPlatforms = try container.decodeIfPresent([MovingPlatformBlueprint].self, forKey: .movingPlatforms) ?? []
        self.sentries = try container.decodeIfPresent([SentryBlueprint].self, forKey: .sentries) ?? []
        self.enemies = try container.decodeIfPresent([EnemyBlueprint].self, forKey: .enemies) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rows, forKey: .rows)
        try container.encode(columns, forKey: .columns)
        try container.encode(tileSize, forKey: .tileSize)
        try container.encode(tileGroups, forKey: .tileGroups)
        try container.encode(spawnPoints, forKey: .spawnPoints)
        try container.encode(movingPlatforms, forKey: .movingPlatforms)
        try container.encode(sentries, forKey: .sentries)
        try container.encode(enemies, forKey: .enemies)
    }

    func makeBlueprint() -> LevelBlueprint {
        var tiles: [GridPoint: LevelTileKind] = [:]
        for group in tileGroups {
            for coordinate in group.coordinates {
                tiles[coordinate.point] = group.kind
            }
        }
        return LevelBlueprint(
            rows: rows,
            columns: columns,
            tileSize: tileSize,
            tiles: tiles,
            spawnPoints: spawnPoints,
            movingPlatforms: movingPlatforms,
            sentries: sentries,
            enemies: enemies
        )
    }

    private static func makeTileGroups(
        from entries: [(GridPoint, LevelTileKind)]
    ) -> [TileGroup] {
        guard !entries.isEmpty else { return [] }
        let grouped = Dictionary(grouping: entries, by: { $0.1 })
        let sortedKinds = grouped.keys.sorted { $0.rawValue < $1.rawValue }
        return sortedKinds.map { kind in
            let points = grouped[kind]?.map { $0.0 } ?? []
            let sortedPoints = points.sorted { lhs, rhs in
                if lhs.row == rhs.row { return lhs.column < rhs.column }
                return lhs.row < rhs.row
            }
            let coordinates = sortedPoints.map { TileCoordinate(point: $0) }
            return TileGroup(kind: kind, coordinates: coordinates)
        }
    }

    private static func sorted(groups: [TileGroup]) -> [TileGroup] {
        let normalized = groups.map { group -> TileGroup in
            let sortedCoordinates = group.coordinates.sorted { lhs, rhs in
                if lhs.row == rhs.row { return lhs.column < rhs.column }
                return lhs.row < rhs.row
            }
            return TileGroup(kind: group.kind, coordinates: sortedCoordinates)
        }

        return normalized.sorted { lhs, rhs in
            if lhs.kind == rhs.kind {
                guard let firstL = lhs.coordinates.first, let firstR = rhs.coordinates.first else { return false }
                if firstL.row == firstR.row { return firstL.column < firstR.column }
                return firstL.row < firstR.row
            }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }
    }

    private enum CodingKeys: String, CodingKey {
        case rows
        case columns
        case tileSize
        case tileGroups
        case tiles
        case spawnPoints
        case movingPlatforms
        case sentries
        case enemies
    }
}
