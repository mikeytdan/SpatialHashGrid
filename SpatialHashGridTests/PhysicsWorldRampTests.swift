//
//  PhysicsWorldRampTests.swift
//  SpatialHashGridTests
//

import Foundation
import simd
import Testing
@testable import SpatialHashGrid

@Suite
struct PhysicsWorldRampTests {

    @Test
    func landingOnUpRightRampAlignsWithSurface() {
        let tileSize = 32.0
        let world = PhysicsWorld(cellSize: tileSize)
        let rampAABB = AABB(min: Vec2(0, tileSize), max: Vec2(tileSize, tileSize * 2))
        _ = world.addStaticRamp(aabb: rampAABB, kind: .upRight)

        let halfSize = Vec2(8, 12)
        var state = PhysicsWorld.BodyState(position: Vec2(10, 18), velocity: Vec2(160, 0), size: halfSize, capsuleRadius: halfSize.x)
        let entityAABB = aabb(for: state)
        let capsuleShape = Shape.capsule(CapsuleData(radius: halfSize.x, height: max(0, (halfSize.y * 2) - 2 * halfSize.x)))
        let id = world.addDynamicEntity(aabb: entityAABB, shape: capsuleShape)

        var contacts: [Contact] = []
        world.integrateKinematic(id: id, state: &state, dt: 1.0 / 60.0, outContacts: &contacts)

        #expect(!contacts.isEmpty)
        let rampContact = contacts.first(where: { abs($0.normal.x) > 0.1 && $0.normal.y < -0.5 })
        #expect(rampContact != nil)
        if let normal = rampContact?.normal {
            #expect(normal.x < 0)
            #expect(abs(simd_length(normal) - 1.0) < 1e-6)
        }

        let planePoint = Vec2(rampAABB.min.x, rampAABB.max.y)
        let normal = rampNormal(ramp: rampAABB, kind: .upRight)
        let footCenter = Vec2(state.position.x, state.position.y + (halfSize.y - halfSize.x))
        #expect(abs(simd_dot(footCenter - planePoint, normal) - halfSize.x) < 0.1)

        #expect(state.velocity.x > 0)
        #expect(state.velocity.y <= 1e-3)
    }

    @Test
    func landingOnUpLeftRampAlignsWithSurface() {
        let tileSize = 32.0
        let world = PhysicsWorld(cellSize: tileSize)
        let rampAABB = AABB(min: Vec2(0, tileSize), max: Vec2(tileSize, tileSize * 2))
        _ = world.addStaticRamp(aabb: rampAABB, kind: .upLeft)

        let halfSize = Vec2(8, 12)
        var state = PhysicsWorld.BodyState(position: Vec2(tileSize - 10, 18), velocity: Vec2(-160, 0), size: halfSize, capsuleRadius: halfSize.x)
        let entityAABB = aabb(for: state)
        let capsuleShape = Shape.capsule(CapsuleData(radius: halfSize.x, height: max(0, (halfSize.y * 2) - 2 * halfSize.x)))
        let id = world.addDynamicEntity(aabb: entityAABB, shape: capsuleShape)

        var contacts: [Contact] = []
        world.integrateKinematic(id: id, state: &state, dt: 1.0 / 60.0, outContacts: &contacts)

        #expect(!contacts.isEmpty)
        let rampContact = contacts.first(where: { abs($0.normal.x) > 0.1 && $0.normal.y < -0.5 })
        #expect(rampContact != nil)
        if let normal = rampContact?.normal {
            #expect(normal.x > 0)
            #expect(abs(simd_length(normal) - 1.0) < 1e-6)
        }

        let planePoint = Vec2(rampAABB.max.x, rampAABB.max.y)
        let normal = rampNormal(ramp: rampAABB, kind: .upLeft)
        let footCenter = Vec2(state.position.x, state.position.y + (halfSize.y - halfSize.x))
        #expect(abs(simd_dot(footCenter - planePoint, normal) - halfSize.x) < 0.1)

        #expect(state.velocity.x < 0)
        #expect(state.velocity.y <= 1e-3)
    }

    @Test
    func movingUpRightRampTracksSurface() {
        let tileSize = 32.0
        let world = PhysicsWorld(cellSize: tileSize)
        let rampAABB = AABB(min: Vec2(0, tileSize), max: Vec2(tileSize, tileSize * 2))
        _ = world.addStaticRamp(aabb: rampAABB, kind: .upRight)

        let halfSize = Vec2(8, 12)
        var state = PhysicsWorld.BodyState(
            position: Vec2(rampAABB.min.x + halfSize.x,
                            rampAABB.max.y - halfSize.y - 0.5),
            velocity: Vec2(180, 0),
            size: halfSize,
            capsuleRadius: halfSize.x
        )
        let capsuleShape = Shape.capsule(CapsuleData(radius: halfSize.x, height: max(0, (halfSize.y * 2) - 2 * halfSize.x)))
        let id = world.addDynamicEntity(aabb: aabb(for: state), shape: capsuleShape)

        var contacts: [Contact] = []
        let dt = 1.0 / 60.0
        let initialY = state.position.y
        for _ in 0..<10 {
            world.integrateKinematic(id: id, state: &state, dt: dt, outContacts: &contacts)
        }

        let finalAABB = aabb(for: state)
        let planePoint = Vec2(rampAABB.min.x, rampAABB.max.y)
        let normal = rampNormal(ramp: rampAABB, kind: .upRight)
        let footCenter = Vec2(state.position.x, state.position.y + (halfSize.y - halfSize.x))
        #expect(abs(simd_dot(footCenter - planePoint, normal) - halfSize.x) < 0.2)
        #expect(state.position.x > rampAABB.min.x + halfSize.x)
        #expect(state.position.y < initialY)
        #expect(state.velocity.x > 0)
        #expect(state.velocity.y <= 1e-3)
    }

    @Test
    func movingDownUpLeftRampTracksSurface() {
        let tileSize = 32.0
        let world = PhysicsWorld(cellSize: tileSize)
        let rampAABB = AABB(min: Vec2(0, tileSize), max: Vec2(tileSize, tileSize * 2))
        _ = world.addStaticRamp(aabb: rampAABB, kind: .upLeft)

        let halfSize = Vec2(8, 12)
        var state = PhysicsWorld.BodyState(
            position: Vec2(rampAABB.min.x + halfSize.x,
                            rampAABB.min.y + halfSize.y + 0.5),
            velocity: Vec2(140, 0),
            size: halfSize,
            capsuleRadius: halfSize.x
        )
        let capsuleShape = Shape.capsule(CapsuleData(radius: halfSize.x, height: max(0, (halfSize.y * 2) - 2 * halfSize.x)))
        let id = world.addDynamicEntity(aabb: aabb(for: state), shape: capsuleShape)

        var contacts: [Contact] = []
        let dt = 1.0 / 60.0
        let initialY = state.position.y
        for _ in 0..<10 {
            world.integrateKinematic(id: id, state: &state, dt: dt, outContacts: &contacts)
        }

        let finalAABB = aabb(for: state)
        let planePoint = Vec2(rampAABB.max.x, rampAABB.max.y)
        let normal = rampNormal(ramp: rampAABB, kind: .upLeft)
        let footCenter = Vec2(state.position.x, state.position.y + (halfSize.y - halfSize.x))
        #expect(abs(simd_dot(footCenter - planePoint, normal) - halfSize.x) < 0.2)
        #expect(state.position.x > rampAABB.min.x + halfSize.x)
        #expect(state.position.y > initialY)
        #expect(state.velocity.x > 0)
        #expect(state.velocity.y <= 1e-3)
    }

    private func aabb(for state: PhysicsWorld.BodyState) -> AABB {
        let half = state.size
        return AABB(
            min: Vec2(state.position.x - half.x, state.position.y - half.y),
            max: Vec2(state.position.x + half.x, state.position.y + half.y)
        )
    }

    private func rampSurfaceY(ramp: AABB, kind: RampData.Kind, x: Double) -> Double {
        let bx0 = ramp.min.x
        let bx1 = ramp.max.x
        let by1 = ramp.max.y
        let w = max(bx1 - bx0, 0.0001)
        let h = max(ramp.max.y - ramp.min.y, 0.0001)
        let slope = h / w
        let clampedX = min(max(x, bx0), bx1)
        switch kind {
        case .upRight:
            return by1 - (clampedX - bx0) * slope
        case .upLeft:
            return by1 - (bx1 - clampedX) * slope
        }
    }

    private func rampNormal(ramp: AABB, kind: RampData.Kind) -> Vec2 {
        let w = max(ramp.max.x - ramp.min.x, 0.0001)
        let h = max(ramp.max.y - ramp.min.y, 0.0001)
        switch kind {
        case .upRight:
            return simd_normalize(Vec2(-h, -w))
        case .upLeft:
            return simd_normalize(Vec2(h, -w))
        }
    }
}
