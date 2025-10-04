// PhysicsWorld.swift
// Side-scroller physics world using SpatialHashGrid

import Foundation
import simd

final class PhysicsWorld {
    // Spatial layers
    private let staticGrid: SpatialHashGrid<ColliderID>
    private let dynamicGrid: SpatialHashGrid<ColliderID>

    // Backing stores for colliders
    private var colliders: [ColliderID: Collider] = [:]

    // Simple ID allocator
    private var nextID: ColliderID = 1

    // Global forces
    public var gravity: Vec2 = Vec2(0, 2000) // units/s^2 downward (+y down)

    // Cached scratch
    private var scratchIDs: [ColliderID] = []
    private var scratchSet = Set<ColliderID>()
    private var scratchKeys: [UInt64] = []
    private var candidateBuffer: [ColliderID] = []
    private var candidateSet = Set<ColliderID>()

    // Platform state
    private var platformVelocities: [ColliderID: Vec2] = [:]
    private var platformDisplacements: [ColliderID: Vec2] = [:]

    init(cellSize: Double = 64.0, reserve: Int = 1024, estimateCells: Int = 2048) {
        self.staticGrid = SpatialHashGrid<ColliderID>(cellSize: cellSize, reserve: reserve, estimateCells: estimateCells)
        self.dynamicGrid = SpatialHashGrid<ColliderID>(cellSize: cellSize, reserve: reserve, estimateCells: estimateCells)
        colliders.reserveCapacity(reserve)
    }

    // MARK: Collider Management

    @discardableResult
    func addStaticTile(aabb: AABB, material: Material = .init()) -> ColliderID {
        let id = allocID()
        let col = Collider(id: id, aabb: aabb, shape: .aabb, type: .staticTile, material: material)
        colliders[id] = col
        staticGrid.insert(id: id, aabb: aabb)
        return id
    }

    @discardableResult
    func addStaticRamp(aabb: AABB, kind: RampData.Kind, material: Material = .init()) -> ColliderID {
        let id = allocID()
        let shape = Shape.ramp(RampData(kind: kind))
        let col = Collider(id: id, aabb: aabb, shape: shape, type: .staticTile, material: material)
        colliders[id] = col
        staticGrid.insert(id: id, aabb: aabb)
        return id
    }

    @discardableResult
    func addTrigger(aabb: AABB, material: Material) -> ColliderID {
        let id = allocID()
        let col = Collider(id: id, aabb: aabb, shape: .aabb, type: .trigger, material: material)
        colliders[id] = col
        staticGrid.insert(id: id, aabb: aabb)
        return id
    }

    @discardableResult
    func addMovingPlatform(
        aabb: AABB,
        material: Material = .init(),
        initialVelocity: Vec2 = .init(0, 0),
        tag: Int32 = 0
    ) -> ColliderID {
        let id = allocID()
        let col = Collider(id: id, aabb: aabb, shape: .aabb, type: .movingPlatform, material: material, tag: tag)
        colliders[id] = col
        dynamicGrid.insert(id: id, aabb: aabb)
        platformVelocities[id] = initialVelocity
        platformDisplacements[id] = Vec2(0, 0)
        return id
    }

    @discardableResult
    func addDynamicEntity(
        aabb: AABB,
        material: Material = .init(),
        shape: Shape = .aabb,
        tag: Int32 = 0
    ) -> ColliderID {
        let id = allocID()
        let col = Collider(id: id, aabb: aabb, shape: shape, type: .dynamicEntity, material: material, tag: tag)
        colliders[id] = col
        dynamicGrid.insert(id: id, aabb: aabb)
        return id
    }

    func removeCollider(id: ColliderID) {
        guard let col = colliders.removeValue(forKey: id) else { return }
        switch col.type {
        case .staticTile, .trigger:
            staticGrid.remove(id: id)
        case .dynamicEntity, .movingPlatform:
            dynamicGrid.remove(id: id)
            platformVelocities.removeValue(forKey: id)
            platformDisplacements.removeValue(forKey: id)
        }
    }

    func updateColliderAABB(id: ColliderID, newAABB: AABB) {
        guard var col = colliders[id] else { return }
        let oldAABB = col.aabb
        col.aabb = newAABB
        colliders[id] = col
        switch col.type {
        case .staticTile, .trigger:
            staticGrid.update(id: id, newAABB: newAABB)
        case .dynamicEntity:
            dynamicGrid.update(id: id, newAABB: newAABB)
        case .movingPlatform:
            dynamicGrid.update(id: id, newAABB: newAABB)
            let delta = Vec2(newAABB.center.x - oldAABB.center.x, newAABB.center.y - oldAABB.center.y)
            platformDisplacements[id] = delta
        }
    }

    // MARK: Platforms state

    func setPlatformVelocity(id: ColliderID, velocity: Vec2) {
        platformVelocities[id] = velocity
    }

    func platformVelocity(id: ColliderID) -> Vec2 { platformVelocities[id] ?? Vec2(0, 0) }

    func platformDisplacement(id: ColliderID) -> Vec2 { platformDisplacements[id] ?? Vec2(0, 0) }

    // MARK: Queries

    func queryBroadphase(aabb: AABB, excluding exclude: ColliderID? = nil) -> [ColliderID] {
        candidateBuffer.removeAll(keepingCapacity: true)
        candidateSet.removeAll(keepingCapacity: true)

        staticGrid.query(aabb: aabb, into: &scratchIDs, scratch: &scratchSet, cellKeys: &scratchKeys)
        for id in scratchIDs where id != exclude {
            candidateBuffer.append(id)
            candidateSet.insert(id)
        }

        dynamicGrid.query(aabb: aabb, into: &scratchIDs, scratch: &scratchSet, cellKeys: &scratchKeys)
        for id in scratchIDs where id != exclude {
            if candidateSet.insert(id).inserted {
                candidateBuffer.append(id)
            }
        }

        return candidateBuffer
    }

    func collider(for id: ColliderID) -> Collider? { colliders[id] }

    /// Debug utility: returns a snapshot array of all colliders.
    /// Intended for rendering / inspection in demos.
    func debugAllColliders() -> [Collider] {
        Array(colliders.values)
    }

    // MARK: Simulation Step

    struct BodyState {
        var position: Vec2
        var velocity: Vec2
        var size: Vec2 // half-extent
        var capsuleRadius: Double = 0
    }

    func integrateKinematic(
        id: ColliderID,
        state: inout BodyState,
        dt: Double,
        extraDisplacement: Vec2 = Vec2(0, 0),
        allowOneWay: Bool = true,
        outContacts: inout [Contact],
        gravityScale: Double = 1.0
    ) {
        outContacts.removeAll(keepingCapacity: true)

        var position = state.position + extraDisplacement
        var velocity = state.velocity
        let halfSize = state.size

        velocity += gravity * gravityScale * dt

        resolvePenetrations(
            id: id,
            position: &position,
            velocity: &velocity,
            halfSize: halfSize,
            capsuleRadius: state.capsuleRadius,
            allowOneWay: allowOneWay,
            outContacts: &outContacts
        )

        let (moveX, contactX) = sweepAxis(
            id: id,
            position: position,
            halfSize: halfSize,
            axis: .x,
            desiredMove: velocity.x * dt,
            capsuleRadius: state.capsuleRadius,
            allowOneWay: allowOneWay
        )
        position.x += moveX
        if let c = contactX {
            outContacts.append(c)
            if c.normal.x > 0 {
                velocity.x = max(velocity.x, 0)
            } else {
                velocity.x = min(velocity.x, 0)
            }
            resolvePenetrations(
                id: id,
                position: &position,
                velocity: &velocity,
                halfSize: halfSize,
                capsuleRadius: state.capsuleRadius,
                allowOneWay: allowOneWay,
                outContacts: &outContacts
            )
        }

        let (moveY, contactY) = sweepAxis(
            id: id,
            position: position,
            halfSize: halfSize,
            axis: .y,
            desiredMove: velocity.y * dt,
            capsuleRadius: state.capsuleRadius,
            allowOneWay: allowOneWay
        )
        position.y += moveY
        if let c = contactY {
            outContacts.append(c)
            if c.normal.y > 0 {
                velocity.y = max(velocity.y, 0)
            } else {
                velocity.y = min(velocity.y, 0)
            }
        }

        resolvePenetrations(
            id: id,
            position: &position,
            velocity: &velocity,
            halfSize: halfSize,
            capsuleRadius: state.capsuleRadius,
            allowOneWay: allowOneWay,
            outContacts: &outContacts
        )

        if !outContacts.isEmpty {
            for contact in outContacts {
                guard contact.normal.y < -0.3 && abs(contact.normal.x) > 0.1,
                      let collider = colliders[contact.other],
                      case .ramp = collider.shape else { continue }
                let friction = min(max(collider.material.friction, 0.0), 1.0)
                if friction >= 0.999 { continue }
                let tangent = normalized(Vec2(-contact.normal.y, contact.normal.x))
                let gravityAlong = simd_dot(gravity, tangent)
                if abs(gravityAlong) < 1e-6 { continue }
                let slip = 1.0 - friction
                velocity += tangent * (gravityAlong * dt * slip)
            }
        }

        state.position = position
        state.velocity = velocity
    }

    // Utility
    private func allocID() -> ColliderID { defer { nextID += 1 }; return nextID }
}

// MARK: - Helpers

enum Axis { case x, y }

extension PhysicsWorld {
    func makeAABB(position: Vec2, halfSize: Vec2) -> AABB {
        AABB(
            min: Vec2(position.x - halfSize.x, position.y - halfSize.y),
            max: Vec2(position.x + halfSize.x, position.y + halfSize.y)
        )
    }

    func expandedAABB(_ base: AABB, axis: Axis, move: Double) -> AABB {
        guard move != 0 else { return base }
        switch axis {
        case .x:
            if move > 0 {
                return AABB(min: base.min, max: Vec2(base.max.x + move, base.max.y))
            } else {
                return AABB(min: Vec2(base.min.x + move, base.min.y), max: base.max)
            }
        case .y:
            if move > 0 {
                return AABB(min: base.min, max: Vec2(base.max.x, base.max.y + move))
            } else {
                return AABB(min: Vec2(base.min.x, base.min.y + move), max: base.max)
            }
        }
    }

    func resolvePenetrations(
        id: ColliderID,
        position: inout Vec2,
        velocity: inout Vec2,
        halfSize: Vec2,
        capsuleRadius: Double?,
        allowOneWay: Bool,
        outContacts: inout [Contact]
    ) {
        let separationEpsilon: Double = 0.001
        let maxIterations = 6
        var iterations = 0

        while iterations < maxIterations {
            iterations += 1
            let aabb = makeAABB(position: position, halfSize: halfSize)
            let candidates = queryBroadphase(aabb: aabb, excluding: id)

            var resolvedAny = false
            for cid in candidates {
                guard let other = colliders[cid] else { continue }
                if other.type == .trigger || other.type == .dynamicEntity { continue }

                let b = other.aabb
                let overlapX = min(aabb.max.x, b.max.x) - max(aabb.min.x, b.min.x)
                let overlapY = min(aabb.max.y, b.max.y) - max(aabb.min.y, b.min.y)
                if overlapX <= 0 || overlapY <= 0 { continue }

                if case .ramp(let rampData) = other.shape {
                    guard let info = rampContactInfo(moving: aabb, ramp: b, kind: rampData.kind) else { continue }

                    let (footCenter, footRadius) = footParameters(position: position, halfSize: halfSize, capsuleRadius: capsuleRadius)
                    let requiredDistance = footRadius + separationEpsilon
                    let currentDistance = simd_dot(footCenter - info.planePoint, info.normal)

                    if currentDistance < requiredDistance {
                        let delta = requiredDistance - currentDistance
                        position += info.normal * delta
                        let vn = simd_dot(velocity, info.normal)
                        if vn < 0 {
                            velocity -= info.normal * vn
                        }

                        let contactPoint = rampContactPoint(position: position, halfSize: halfSize, normal: info.normal, capsuleRadius: capsuleRadius)
                        outContacts.append(Contact(
                            other: cid,
                            normal: info.normal,
                            depth: delta,
                            point: contactPoint
                        ))

                        resolvedAny = true
                        break
                    } else if currentDistance - footRadius <= separationEpsilon * 4 {
                        let contactPoint = rampContactPoint(position: position, halfSize: halfSize, normal: info.normal, capsuleRadius: capsuleRadius)
                        outContacts.append(Contact(other: cid, normal: info.normal, depth: max(0, requiredDistance - currentDistance), point: contactPoint))
                    }

                    continue
                }

                var normal = Vec2(0, 0)
                var depth: Double = 0

                let centerB = Vec2(
                    (b.min.x + b.max.x) * 0.5,
                    (b.min.y + b.max.y) * 0.5
                )
                let delta = Vec2(position.x - centerB.x, position.y - centerB.y)
                let horizontalBias: Double = 4.0
                let chooseHorizontal = overlapX < overlapY && abs(delta.x) >= abs(delta.y) + horizontalBias

                if chooseHorizontal {
                    let centerA = position.x
                    normal = centerA < centerB.x ? Vec2(-1, 0) : Vec2(1, 0)
                    depth = overlapX
                } else {
                    let centerA = position.y
                    normal = centerA < centerB.y ? Vec2(0, -1) : Vec2(0, 1)
                    depth = overlapY
                }

                if allowOneWay && other.material.oneWay {
                    // One-way platforms only push upward (normal.y == -1)
                    if normal.y >= 0 { continue }
                }

                position += normal * (depth + separationEpsilon)

                if normal.x > 0 {
                    velocity.x = max(velocity.x, 0)
                } else if normal.x < 0 {
                    velocity.x = min(velocity.x, 0)
                }

                if normal.y > 0 {
                    velocity.y = max(velocity.y, 0)
                } else if normal.y < 0 {
                    velocity.y = min(velocity.y, 0)
                }

                let contactPoint = contactPoint(position: position, halfSize: halfSize, normal: normal)
                outContacts.append(Contact(other: cid, normal: normal, depth: depth, point: contactPoint))

                resolvedAny = true
                break
            }

            if !resolvedAny { break }
        }
    }

    func sweepAxis(
        id: ColliderID,
        position: Vec2,
        halfSize: Vec2,
        axis: Axis,
        desiredMove: Double,
        capsuleRadius: Double?,
        allowOneWay: Bool
    ) -> (Double, Contact?) {
        guard desiredMove != 0 else { return (0, nil) }
        let startAABB = makeAABB(position: position, halfSize: halfSize)
        let broad = expandedAABB(startAABB, axis: axis, move: desiredMove)
        let candidates = queryBroadphase(aabb: broad, excluding: id)
        let separationEpsilon: Double = 0.001

        var permitted = desiredMove
        var bestContact: Contact? = nil

        for cid in candidates {
            guard let other = colliders[cid] else { continue }
            if other.type == .trigger || other.type == .dynamicEntity { continue }
            let b = other.aabb

            switch axis {
            case .x:
                let overlapY = min(startAABB.max.y, b.max.y) - max(startAABB.min.y, b.min.y)
                if overlapY <= 0 { continue }

                if case .ramp = other.shape {
                    continue
                }

                if desiredMove > 0 {
                    let gap = b.min.x - startAABB.max.x
                    if desiredMove > gap {
                        let newMove = max(0, gap - separationEpsilon)
                        if newMove < permitted {
                            permitted = newMove
                            let point = contactPoint(
                                position: Vec2(position.x + permitted, position.y),
                                halfSize: halfSize,
                                normal: Vec2(-1, 0)
                            )
                            let depth = abs(desiredMove - permitted)
                            bestContact = Contact(other: cid, normal: Vec2(-1, 0), depth: depth, point: point)
                        }
                    }
                } else {
                    let gap = b.max.x - startAABB.min.x
                    if desiredMove < gap {
                        let newMove = min(0, gap + separationEpsilon)
                        if newMove > permitted {
                            permitted = newMove
                            let point = contactPoint(
                                position: Vec2(position.x + permitted, position.y),
                                halfSize: halfSize,
                                normal: Vec2(1, 0)
                            )
                            let depth = abs(desiredMove - permitted)
                            bestContact = Contact(other: cid, normal: Vec2(1, 0), depth: depth, point: point)
                        }
                    }
                }

            case .y:
                let overlapX = min(startAABB.max.x, b.max.x) - max(startAABB.min.x, b.min.x)
                if overlapX <= 0 { continue }

                if case .ramp(let rampData) = other.shape {
                    if desiredMove > 0 { // downward sweep only
                        guard let rampInfo = rampContactInfo(
                            moving: startAABB,
                            ramp: b,
                            kind: rampData.kind
                        ) else { continue }

                        if allowOneWay && other.material.oneWay {
                            let startBottom = startAABB.max.y
                            let surfaceTop = rampInfo.ySurface
                            if startBottom - surfaceTop > 4 { continue }
                        }

                        let (footCenter, footRadius) = footParameters(position: position, halfSize: halfSize, capsuleRadius: capsuleRadius)
                        let planePoint = rampInfo.planePoint
                        let currentDistance = simd_dot(footCenter - planePoint, rampInfo.normal)
                        let requiredDistance = footRadius + separationEpsilon
                        let deltaNormal = simd_dot(Vec2(0, desiredMove), rampInfo.normal)
                        if deltaNormal < 0 {
                            let maxAllowedNormalDecrease = currentDistance - requiredDistance
                            if maxAllowedNormalDecrease <= 0 {
                                if 0 < permitted {
                                    permitted = 0
                                    let normal = rampInfo.normal
                                    let finalPos = Vec2(position.x, position.y)
                                    let point = rampContactPoint(position: finalPos, halfSize: halfSize, normal: normal, capsuleRadius: capsuleRadius)
                                    bestContact = Contact(other: cid, normal: normal, depth: 0, point: point)
                                }
                                continue
                            }
                            let ratio = maxAllowedNormalDecrease / -deltaNormal
                            let newMove = max(0, min(desiredMove, desiredMove * ratio))
                            if newMove < permitted {
                                permitted = newMove
                                let normal = rampInfo.normal
                                let finalPos = Vec2(position.x, position.y + permitted)
                                let depth = abs(desiredMove - permitted)
                                let point = rampContactPoint(position: finalPos, halfSize: halfSize, normal: normal, capsuleRadius: capsuleRadius)
                                bestContact = Contact(other: cid, normal: normal, depth: depth, point: point)
                            }
                        }
                    }
                    continue
                }

                if desiredMove > 0 { // moving downward (y+)
                    let forwardThreshold = startAABB.max.y - separationEpsilon * 4
                    if b.min.y < forwardThreshold { continue }
                    if allowOneWay && other.material.oneWay {
                        let startBottom = startAABB.max.y
                        let platformTop = b.min.y
                        // Only collide if we started above the platform
                        if startBottom - platformTop > 4 { continue }
                    }
                    let gap = b.min.y - startAABB.max.y
                    if desiredMove > gap {
                        let newMove = max(0, gap - separationEpsilon)
                        if newMove < permitted {
                            permitted = newMove
                            let normal = Vec2(0, -1)
                            let finalPos = Vec2(position.x, position.y + permitted)
                            let point = contactPoint(position: finalPos, halfSize: halfSize, normal: normal)
                            let depth = abs(desiredMove - permitted)
                            bestContact = Contact(other: cid, normal: normal, depth: depth, point: point)
                        }
                    }
                } else { // moving upward
                    let forwardThreshold = startAABB.min.y + separationEpsilon * 4
                    if b.max.y > forwardThreshold { continue }
                    let gap = b.max.y - startAABB.min.y
                    if desiredMove < gap {
                        let newMove = min(0, gap + separationEpsilon)
                        if newMove > permitted {
                            permitted = newMove
                            let normal = Vec2(0, 1)
                            let finalPos = Vec2(position.x, position.y + permitted)
                            let point = contactPoint(position: finalPos, halfSize: halfSize, normal: normal)
                            let depth = abs(desiredMove - permitted)
                            bestContact = Contact(other: cid, normal: normal, depth: depth, point: point)
                        }
                    }
                }
            }
        }

        // Clamp to desired range when no hit found
        if bestContact == nil {
            return (desiredMove, nil)
        }
        return (permitted, bestContact)
    }

    func contactPoint(position: Vec2, halfSize: Vec2, normal: Vec2) -> Vec2 {
        var point = position
        if abs(normal.x) > 0.5 {
            point.x += normal.x * halfSize.x
        }
        if abs(normal.y) > 0.5 {
            point.y += normal.y * halfSize.y
        }
        return point
    }

    struct RampContactInfo {
        let normal: Vec2
        let ySurface: Double
        let xSurface: Double
        let planePoint: Vec2
    }

    func rampContactInfo(moving: AABB, ramp: AABB, kind: RampData.Kind) -> RampContactInfo? {
        let xmin = max(moving.min.x, ramp.min.x)
        let xmax = min(moving.max.x, ramp.max.x)
        if xmin >= xmax { return nil }

        let contactX: Double
        switch kind {
        case .upRight:
            contactX = xmin
        case .upLeft:
            contactX = xmax
        }

        let ySurf = rampSurfaceY(ramp: ramp, kind: kind, x: contactX)
        let normal = rampNormal(ramp: ramp, kind: kind)
        let planePoint = rampPlanePoint(ramp: ramp, kind: kind)
        return RampContactInfo(normal: normal, ySurface: ySurf, xSurface: contactX, planePoint: planePoint)
    }

    func rampSurfaceY(ramp: AABB, kind: RampData.Kind, x: Double) -> Double {
        let bx0 = ramp.min.x
        let bx1 = ramp.max.x
        let by0 = ramp.min.y
        let by1 = ramp.max.y
        let w = max(bx1 - bx0, 0.0001)
        let h = max(by1 - by0, 0.0001)
        let clampedX = min(max(x, bx0), bx1)
        let slope = h / w

        switch kind {
        case .upRight:
            let dx = clampedX - bx0
            return by1 - dx * slope
        case .upLeft:
            let dx = bx1 - clampedX
            return by1 - dx * slope
        }
    }

    func rampNormal(ramp: AABB, kind: RampData.Kind) -> Vec2 {
        let w = max(ramp.max.x - ramp.min.x, 0.0001)
        let h = max(ramp.max.y - ramp.min.y, 0.0001)
        switch kind {
        case .upRight:
            return normalized(Vec2(-h, -w))
        case .upLeft:
            return normalized(Vec2(h, -w))
        }
    }

    func rampPlanePoint(ramp: AABB, kind: RampData.Kind) -> Vec2 {
        switch kind {
        case .upRight:
            return Vec2(ramp.min.x, ramp.max.y)
        case .upLeft:
            return Vec2(ramp.max.x, ramp.max.y)
        }
    }

    func footParameters(position: Vec2, halfSize: Vec2, capsuleRadius: Double?) -> (center: Vec2, radius: Double) {
        let radius = max(capsuleRadius ?? 0, 0)
        let offset = max(0, halfSize.y - radius)
        let center = Vec2(position.x, position.y + offset)
        return (center, radius)
    }

    func rampContactPoint(position: Vec2, halfSize: Vec2, normal: Vec2, capsuleRadius: Double?) -> Vec2 {
        let (center, radius) = footParameters(position: position, halfSize: halfSize, capsuleRadius: capsuleRadius)
        return center - normal * radius
    }

    func normalized(_ v: Vec2) -> Vec2 {
        let len = simd_length(v)
        if len <= 1e-8 { return Vec2(0, 0) }
        return v / len
    }
}
