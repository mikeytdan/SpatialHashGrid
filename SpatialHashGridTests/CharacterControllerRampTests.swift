//
//  CharacterControllerRampTests.swift
//  SpatialHashGridTests
//

import Foundation
import simd
import Testing
@testable import SpatialHashGrid

@Suite
struct CharacterControllerRampTests {

    @Test
    func jumpingFromRampLaunchesUpward() {
        let setup = makeWorldWithRamp()
        let controller = CharacterController(world: setup.world, spawn: Vec2(setup.ground.min.x, setup.ground.min.y - 40))
        let half = controller.body.size
        controller.setPosition(Vec2(setup.ground.max.x - half.x - 4.0, setup.ground.min.y - half.y))

        let dt = 1.0 / 60.0
        var input = InputState()
        for _ in 0..<20 {
            controller.update(input: input, dt: dt)
        }

        input.moveX = 1
        for _ in 0..<8 {
            controller.update(input: input, dt: dt)
        }

        let preJump = controller.movementSnapshot()
        #expect(preJump.phase == .run)
        #expect(preJump.velocity.x > controller.moveSpeed * 0.6)

        input.jumpPressed = true
        controller.update(input: input, dt: dt)
        input.jumpPressed = false

        let postJump = controller.movementSnapshot()
        #expect(postJump.phase == .jump)
        #expect(postJump.velocity.y < -controller.jumpImpulse * 0.8)
    }

    @Test
    func rampSpeedMultiplierAdjustsTangentialSpeed() {
        let defaultSpeed = measureRampSpeed(multiplier: 1.0)
        let boostedSpeed = measureRampSpeed(multiplier: 1.4)
        #expect(boostedSpeed > defaultSpeed + 40)
    }

    @Test
    func runsUpRampWithDefaultMultipliers() {
        let setup = makeWorldWithRamp()
        let controller = CharacterController(world: setup.world, spawn: Vec2(setup.ramp.min.x, setup.ramp.max.y))
        let half = controller.body.size
        let start = Vec2(setup.ramp.min.x + half.x + 2.0,
                         setup.ramp.max.y - half.y - 1.0)
        controller.setPosition(start)

        let dt = 1.0 / 60.0
        var input = InputState(moveX: 1)
        for _ in 0..<45 {
            controller.update(input: input, dt: dt)
        }

        let end = controller.body.position
        #expect(end.x > start.x + 20)
        #expect(end.y < start.y - 6)
    }

    private func makeWorldWithRamp(tileSize: Double = 32.0) -> (world: PhysicsWorld, ramp: AABB, ground: AABB) {
        let world = PhysicsWorld(cellSize: tileSize)
        let ground = AABB(min: Vec2(-tileSize * 2, tileSize * 2), max: Vec2(0, tileSize * 3))
        _ = world.addStaticTile(aabb: ground)
        let ramp = AABB(min: Vec2(0, tileSize * 2), max: Vec2(tileSize, tileSize * 3))
        _ = world.addStaticRamp(aabb: ramp, kind: .upRight)
        return (world, ramp, ground)
    }

    private func measureRampSpeed(multiplier: Double) -> Double {
        let setup = makeWorldWithRamp()
        let controller = CharacterController(world: setup.world, spawn: Vec2(setup.ground.min.x, setup.ground.min.y - 40))
        controller.rampUphillSpeedMultiplier = multiplier
        let half = controller.body.size
        controller.setPosition(Vec2(setup.ground.max.x - half.x - 4.0, setup.ground.min.y - half.y))

        let dt = 1.0 / 60.0
        var input = InputState()
        for _ in 0..<20 {
            controller.update(input: input, dt: dt)
        }

        input.moveX = 1
        var recordedSpeed = 0.0
        for step in 0..<8 {
            controller.update(input: input, dt: dt)
            if step >= 4 {
                recordedSpeed = abs(controller.body.velocity.x)
            }
        }
        return recordedSpeed
    }
}
