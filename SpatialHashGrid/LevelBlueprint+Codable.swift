import Foundation

private struct Vector2Representation: Codable {
    var x: Double
    var y: Double

    init(_ vector: Vec2) {
        self.x = vector.x
        self.y = vector.y
    }

    var vector: Vec2 {
        Vec2(x, y)
    }
}

extension GridPoint: Codable {
    private enum CodingKeys: String, CodingKey { case row, column }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let row = try container.decode(Int.self, forKey: .row)
        let column = try container.decode(Int.self, forKey: .column)
        self.init(row: row, column: column)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(row, forKey: .row)
        try container.encode(column, forKey: .column)
    }
}

extension LevelTileKind: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let kind = LevelTileKind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown tile kind: \(raw)")
        }
        self = kind
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension PlayerSpawnPoint: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, coordinate }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let coordinate = try container.decode(GridPoint.self, forKey: .coordinate)
        self.init(id: id, name: name, coordinate: coordinate)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(coordinate, forKey: .coordinate)
    }
}

extension GridSize: Codable {
    private enum CodingKeys: String, CodingKey { case rows, columns }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try container.decode(Int.self, forKey: .rows)
        let columns = try container.decode(Int.self, forKey: .columns)
        self.init(rows: rows, columns: columns)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rows, forKey: .rows)
        try container.encode(columns, forKey: .columns)
    }
}

extension MovingPlatformBlueprint: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, origin, size, target, speed, initialProgress
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = MovingPlatformBlueprint(
            id: try container.decode(UUID.self, forKey: .id),
            origin: try container.decode(GridPoint.self, forKey: .origin),
            size: try container.decode(GridSize.self, forKey: .size),
            target: try container.decode(GridPoint.self, forKey: .target),
            speed: try container.decode(Double.self, forKey: .speed),
            initialProgress: try container.decode(Double.self, forKey: .initialProgress)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(origin, forKey: .origin)
        try container.encode(size, forKey: .size)
        try container.encode(target, forKey: .target)
        try container.encode(speed, forKey: .speed)
        try container.encode(initialProgress, forKey: .initialProgress)
    }
}

extension SentryBlueprint: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case coordinate
        case scanRange
        case scanCenterDegrees
        case scanArcDegrees
        case sweepSpeedDegreesPerSecond
        case fireCooldown
        case projectileSpeed
        case projectileSize
        case projectileLifetime
        case projectileBurstCount
        case projectileSpreadDegrees
        case aimToleranceDegrees
        case initialFacingDegrees
        case projectileKind
        case heatSeekingTurnRateDegreesPerSecond
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = SentryBlueprint(
            id: try container.decode(UUID.self, forKey: .id),
            coordinate: try container.decode(GridPoint.self, forKey: .coordinate),
            scanRange: try container.decode(Double.self, forKey: .scanRange),
            scanCenterDegrees: try container.decode(Double.self, forKey: .scanCenterDegrees),
            scanArcDegrees: try container.decode(Double.self, forKey: .scanArcDegrees),
            sweepSpeedDegreesPerSecond: try container.decode(Double.self, forKey: .sweepSpeedDegreesPerSecond),
            fireCooldown: try container.decode(Double.self, forKey: .fireCooldown),
            projectileSpeed: try container.decode(Double.self, forKey: .projectileSpeed),
            projectileSize: try container.decode(Double.self, forKey: .projectileSize),
            projectileLifetime: try container.decode(Double.self, forKey: .projectileLifetime),
            projectileBurstCount: try container.decode(Int.self, forKey: .projectileBurstCount),
            projectileSpreadDegrees: try container.decode(Double.self, forKey: .projectileSpreadDegrees),
            aimToleranceDegrees: try container.decode(Double.self, forKey: .aimToleranceDegrees),
            initialFacingDegrees: try container.decode(Double.self, forKey: .initialFacingDegrees),
            projectileKind: try container.decode(ProjectileKind.self, forKey: .projectileKind),
            heatSeekingTurnRateDegreesPerSecond: try container.decode(Double.self, forKey: .heatSeekingTurnRateDegreesPerSecond)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(coordinate, forKey: .coordinate)
        try container.encode(scanRange, forKey: .scanRange)
        try container.encode(scanCenterDegrees, forKey: .scanCenterDegrees)
        try container.encode(scanArcDegrees, forKey: .scanArcDegrees)
        try container.encode(sweepSpeedDegreesPerSecond, forKey: .sweepSpeedDegreesPerSecond)
        try container.encode(fireCooldown, forKey: .fireCooldown)
        try container.encode(projectileSpeed, forKey: .projectileSpeed)
        try container.encode(projectileSize, forKey: .projectileSize)
        try container.encode(projectileLifetime, forKey: .projectileLifetime)
        try container.encode(projectileBurstCount, forKey: .projectileBurstCount)
        try container.encode(projectileSpreadDegrees, forKey: .projectileSpreadDegrees)
        try container.encode(aimToleranceDegrees, forKey: .aimToleranceDegrees)
        try container.encode(initialFacingDegrees, forKey: .initialFacingDegrees)
        try container.encode(projectileKind, forKey: .projectileKind)
        try container.encode(heatSeekingTurnRateDegreesPerSecond, forKey: .heatSeekingTurnRateDegreesPerSecond)
    }
}

extension EnemyController.MovementPattern.Axis: Codable {
    private enum Representation: String, Codable {
        case horizontal
        case vertical
    }

    public init(from decoder: Decoder) throws {
        let representation = try Representation(from: decoder)
        switch representation {
        case .horizontal: self = .horizontal
        case .vertical: self = .vertical
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .horizontal:
            try Representation.horizontal.encode(to: encoder)
        case .vertical:
            try Representation.vertical.encode(to: encoder)
        }
    }
}

extension EnemyBlueprint.Movement: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case span
        case speed
        case width
        case height
        case clockwise
        case points
        case axis
    }

    private enum Kind: String, Codable {
        case idle
        case patrolHorizontal
        case patrolVertical
        case perimeter
        case waypoints
        case wallBounce
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .idle:
            self = .idle
        case .patrolHorizontal:
            self = .patrolHorizontal(
                span: try container.decode(Double.self, forKey: .span),
                speed: try container.decode(Double.self, forKey: .speed)
            )
        case .patrolVertical:
            self = .patrolVertical(
                span: try container.decode(Double.self, forKey: .span),
                speed: try container.decode(Double.self, forKey: .speed)
            )
        case .perimeter:
            self = .perimeter(
                width: try container.decode(Double.self, forKey: .width),
                height: try container.decode(Double.self, forKey: .height),
                speed: try container.decode(Double.self, forKey: .speed),
                clockwise: try container.decode(Bool.self, forKey: .clockwise)
            )
        case .waypoints:
            let representations = try container.decode([Vector2Representation].self, forKey: .points)
            self = .waypoints(
                points: representations.map { $0.vector },
                speed: try container.decode(Double.self, forKey: .speed)
            )
        case .wallBounce:
            self = .wallBounce(
                axis: try container.decode(EnemyController.MovementPattern.Axis.self, forKey: .axis),
                speed: try container.decode(Double.self, forKey: .speed)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try container.encode(Kind.idle, forKey: .kind)
        case let .patrolHorizontal(span, speed):
            try container.encode(Kind.patrolHorizontal, forKey: .kind)
            try container.encode(span, forKey: .span)
            try container.encode(speed, forKey: .speed)
        case let .patrolVertical(span, speed):
            try container.encode(Kind.patrolVertical, forKey: .kind)
            try container.encode(span, forKey: .span)
            try container.encode(speed, forKey: .speed)
        case let .perimeter(width, height, speed, clockwise):
            try container.encode(Kind.perimeter, forKey: .kind)
            try container.encode(width, forKey: .width)
            try container.encode(height, forKey: .height)
            try container.encode(speed, forKey: .speed)
            try container.encode(clockwise, forKey: .clockwise)
        case let .waypoints(points, speed):
            try container.encode(Kind.waypoints, forKey: .kind)
            let representations = points.map { point in Vector2Representation(point) }
            try container.encode(representations, forKey: .points)
            try container.encode(speed, forKey: .speed)
        case let .wallBounce(axis, speed):
            try container.encode(Kind.wallBounce, forKey: .kind)
            try container.encode(axis, forKey: .axis)
            try container.encode(speed, forKey: .speed)
        }
    }
}

extension EnemyBlueprint.Behavior: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case range
        case speedMultiplier
        case verticalTolerance
        case safeDistance
        case runMultiplier
        case preferredLower
        case preferredUpper
        case strafeSpeed
    }

    private enum Kind: String, Codable {
        case passive
        case chase
        case flee
        case strafe
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .passive:
            self = .passive
        case .chase:
            self = .chase(
                range: try container.decode(Double.self, forKey: .range),
                speedMultiplier: try container.decode(Double.self, forKey: .speedMultiplier),
                verticalTolerance: try container.decode(Double.self, forKey: .verticalTolerance)
            )
        case .flee:
            self = .flee(
                range: try container.decode(Double.self, forKey: .range),
                safeDistance: try container.decode(Double.self, forKey: .safeDistance),
                runMultiplier: try container.decode(Double.self, forKey: .runMultiplier)
            )
        case .strafe:
            let lower = try container.decode(Double.self, forKey: .preferredLower)
            let upper = try container.decode(Double.self, forKey: .preferredUpper)
            self = .strafe(
                range: try container.decode(Double.self, forKey: .range),
                preferred: lower...upper,
                strafeSpeed: try container.decode(Double.self, forKey: .strafeSpeed)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .passive:
            try container.encode(Kind.passive, forKey: .kind)
        case let .chase(range, speedMultiplier, verticalTolerance):
            try container.encode(Kind.chase, forKey: .kind)
            try container.encode(range, forKey: .range)
            try container.encode(speedMultiplier, forKey: .speedMultiplier)
            try container.encode(verticalTolerance, forKey: .verticalTolerance)
        case let .flee(range, safeDistance, runMultiplier):
            try container.encode(Kind.flee, forKey: .kind)
            try container.encode(range, forKey: .range)
            try container.encode(safeDistance, forKey: .safeDistance)
            try container.encode(runMultiplier, forKey: .runMultiplier)
        case let .strafe(range, preferred, strafeSpeed):
            try container.encode(Kind.strafe, forKey: .kind)
            try container.encode(range, forKey: .range)
            try container.encode(preferred.lowerBound, forKey: .preferredLower)
            try container.encode(preferred.upperBound, forKey: .preferredUpper)
            try container.encode(strafeSpeed, forKey: .strafeSpeed)
        }
    }
}

extension EnemyBlueprint.Attack: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case speed
        case cooldown
        case range
        case knockback
    }

    private enum Kind: String, Codable {
        case none
        case shooter
        case sword
        case punch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .none:
            self = .none
        case .shooter:
            self = .shooter(
                speed: try container.decode(Double.self, forKey: .speed),
                cooldown: try container.decode(Double.self, forKey: .cooldown),
                range: try container.decode(Double.self, forKey: .range)
            )
        case .sword:
            self = .sword(
                range: try container.decode(Double.self, forKey: .range),
                cooldown: try container.decode(Double.self, forKey: .cooldown),
                knockback: try container.decode(Double.self, forKey: .knockback)
            )
        case .punch:
            self = .punch(
                range: try container.decode(Double.self, forKey: .range),
                cooldown: try container.decode(Double.self, forKey: .cooldown),
                knockback: try container.decode(Double.self, forKey: .knockback)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode(Kind.none, forKey: .kind)
        case let .shooter(speed, cooldown, range):
            try container.encode(Kind.shooter, forKey: .kind)
            try container.encode(speed, forKey: .speed)
            try container.encode(cooldown, forKey: .cooldown)
            try container.encode(range, forKey: .range)
        case let .sword(range, cooldown, knockback):
            try container.encode(Kind.sword, forKey: .kind)
            try container.encode(range, forKey: .range)
            try container.encode(cooldown, forKey: .cooldown)
            try container.encode(knockback, forKey: .knockback)
        case let .punch(range, cooldown, knockback):
            try container.encode(Kind.punch, forKey: .kind)
            try container.encode(range, forKey: .range)
            try container.encode(cooldown, forKey: .cooldown)
            try container.encode(knockback, forKey: .knockback)
        }
    }
}

extension EnemyBlueprint: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case coordinate
        case size
        case movement
        case behavior
        case attack
        case acceleration
        case maxSpeed
        case affectedByGravity
        case gravityScale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let vector = try container.decode(Vector2Representation.self, forKey: .size)
        self = EnemyBlueprint(
            id: try container.decode(UUID.self, forKey: .id),
            coordinate: try container.decode(GridPoint.self, forKey: .coordinate),
            size: vector.vector,
            movement: try container.decode(Movement.self, forKey: .movement),
            behavior: try container.decode(Behavior.self, forKey: .behavior),
            attack: try container.decode(Attack.self, forKey: .attack),
            acceleration: try container.decode(Double.self, forKey: .acceleration),
            maxSpeed: try container.decode(Double.self, forKey: .maxSpeed),
            affectedByGravity: try container.decode(Bool.self, forKey: .affectedByGravity),
            gravityScale: try container.decode(Double.self, forKey: .gravityScale)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(coordinate, forKey: .coordinate)
        try container.encode(Vector2Representation(size), forKey: .size)
        try container.encode(movement, forKey: .movement)
        try container.encode(behavior, forKey: .behavior)
        try container.encode(attack, forKey: .attack)
        try container.encode(acceleration, forKey: .acceleration)
        try container.encode(maxSpeed, forKey: .maxSpeed)
        try container.encode(affectedByGravity, forKey: .affectedByGravity)
        try container.encode(gravityScale, forKey: .gravityScale)
    }
}
