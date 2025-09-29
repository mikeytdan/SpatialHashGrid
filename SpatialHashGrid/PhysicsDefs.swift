// PhysicsDefs.swift
// Core physics types used by the side-scroller engine.

import Foundation
import simd

// Reuse Vec2 from SpatialHashGrid.swift (public typealias)
// If building standalone, uncomment the following line:
// public typealias Vec2 = SIMD2<Double>

public typealias ColliderID = Int

public enum ColliderType {
    case staticTile
    case dynamicEntity
    case trigger
    case movingPlatform
}

public struct Material: Sendable {
    public var friction: Double        // 0..1 typical
    public var restitution: Double     // 0 = no bounce, >1 bouncy
    public var sticky: Double          // 0 = none, 0.5 medium, 1 strong
    public var conveyor: Vec2?         // adds velocity to grounded entities
    public var ladder: Bool            // climbable volume (trigger)
    public var oneWay: Bool            // one-way platforms (collide when moving downward)
    public var ceilingGrab: Bool       // allows hanging

    public init(
        friction: Double = 0.0,
        restitution: Double = 0.0,
        sticky: Double = 0.0,
        conveyor: Vec2? = nil,
        ladder: Bool = false,
        oneWay: Bool = false,
        ceilingGrab: Bool = false
    ) {
        self.friction = friction
        self.restitution = restitution
        self.sticky = sticky
        self.conveyor = conveyor
        self.ladder = ladder
        self.oneWay = oneWay
        self.ceilingGrab = ceilingGrab
    }
}

public enum Shape {
    case aabb
    // Extend later: .ramp, .circle, .capsule
}

public struct Collider {
    public let id: ColliderID
    public var aabb: AABB
    public var shape: Shape
    public var type: ColliderType
    public var material: Material
    public var tag: Int32 // free-form category or group

    public init(id: ColliderID, aabb: AABB, shape: Shape = .aabb, type: ColliderType, material: Material = .init(), tag: Int32 = 0) {
        self.id = id
        self.aabb = aabb
        self.shape = shape
        self.type = type
        self.material = material
        self.tag = tag
    }
}

public struct Contact {
    public let other: ColliderID
    public let normal: Vec2   // Points from other -> self (direction to move self out)
    public let depth: Double  // penetration depth (for overlap cases)
    public let point: Vec2    // contact point (approx)
}

public enum CollisionSide: Sendable {
    case ground
    case ceiling
    case left
    case right
}

public struct SurfaceContact: Sendable {
    public let other: ColliderID
    public let normal: Vec2
    public let depth: Double
    public let point: Vec2
    public let type: ColliderType
    public let material: Material
    public let side: CollisionSide
}

public struct CollisionState: Sendable {
    // Full contact manifold for this frame
    public private(set) var all: [SurfaceContact] = []
    public private(set) var ground: [SurfaceContact] = []
    public private(set) var ceiling: [SurfaceContact] = []
    public private(set) var left: [SurfaceContact] = []
    public private(set) var right: [SurfaceContact] = []

    // Backwards-compatible convenience flags/IDs
    public var grounded: Bool { !ground.isEmpty }
    public var wallLeft: Bool { !left.isEmpty }
    public var wallRight: Bool { !right.isEmpty }
    public var ceilingFlag: Bool { !ceiling.isEmpty }

    // Primary ground/platform convenience (first match this frame)
    public var groundID: ColliderID? { ground.first?.other }
    public var onPlatform: ColliderID? { ground.first(where: { $0.type == .movingPlatform })?.other }

    public init() {}

    public mutating func reset() {
        all.removeAll(keepingCapacity: true)
        ground.removeAll(keepingCapacity: true)
        ceiling.removeAll(keepingCapacity: true)
        left.removeAll(keepingCapacity: true)
        right.removeAll(keepingCapacity: true)
    }

    // Ingest a narrow-phase contact and categorize by side
    public mutating func absorb(contact: Contact, with collider: Collider) {
        let side: CollisionSide
        if contact.normal.y < -0.5 {
            side = .ground
        } else if contact.normal.y > 0.5 {
            side = .ceiling
        } else if contact.normal.x > 0.5 {
            side = .left
        } else {
            side = .right
        }
        let sc = SurfaceContact(
            other: collider.id,
            normal: contact.normal,
            depth: contact.depth,
            point: contact.point,
            type: collider.type,
            material: collider.material,
            side: side
        )
        all.append(sc)
        switch side {
        case .ground: ground.append(sc)
        case .ceiling: ceiling.append(sc)
        case .left: left.append(sc)
        case .right: right.append(sc)
        }
    }
}

public struct InputState {
    public var moveX: Double = 0       // -1..1
    public var jumpPressed: Bool = false
    public var grabHeld: Bool = false
    public var climbHeld: Bool = false

    public init(moveX: Double = 0, jumpPressed: Bool = false, grabHeld: Bool = false, climbHeld: Bool = false) {
        self.moveX = moveX
        self.jumpPressed = jumpPressed
        self.grabHeld = grabHeld
        self.climbHeld = climbHeld
    }
}
