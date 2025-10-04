// CharacterController.swift
// Kinematic side-scroller controller with wall grab/slide/jump using PhysicsWorld

import Foundation
import simd

final class CharacterController {
    let world: PhysicsWorld
    let id: ColliderID

    enum MovementPhase {
        case idle
        case run
        case jump
        case fall
        case wallSlide
        case land
    }

    // Physical tuning
    var width: Double = 28
    var height: Double = 60
    var moveSpeed: Double = 380
    var airControl: Double = 0.55
    var jumpImpulse: Double = 820
    var wallJumpImpulse: Vec2 = Vec2(560, -820)
    var maxFallSpeed: Double = 1500
    var wallSlideSpeed: Double = 240
    var groundFriction: Double = 12.0
    var coyoteTime: Double = 0.12
    var extraJumps: Int = 1
    private(set) var coyoteTimer: Double = 0
    private(set) var jumpsRemaining: Int = 0

    // State
    var body: PhysicsWorld.BodyState
    var collisions = CollisionState()
    private var lastPlatformID: ColliderID? = nil
    private var suppressPlatformCarry: Bool = false
    var wasGroundedLastFrame: Bool = false
    var facing: Int = 1 // 1 right, -1 left
    private(set) var movementPhase: MovementPhase = .idle
    private var landStateTimer: Double = 0

    init(world: PhysicsWorld, spawn: Vec2) {
        self.world = world
        let radius = width * 0.5
        let half = Vec2(width * 0.5, height * 0.5)
        let aabb = AABB(
            min: Vec2(spawn.x - half.x, spawn.y - half.y),
            max: Vec2(spawn.x + half.x, spawn.y + half.y)
        )
        let capsuleHeight = max(0, height - 2.0 * radius)
        let shape = Shape.capsule(CapsuleData(radius: radius, height: capsuleHeight))
        self.id = world.addDynamicEntity(aabb: aabb, material: Material(), shape: shape)
        self.body = PhysicsWorld.BodyState(position: spawn, velocity: Vec2(0, 0), size: half, capsuleRadius: radius)
    }

    func setPosition(_ p: Vec2) {
        body.position = p
        let aabb = AABB(
            min: Vec2(p.x - body.size.x, p.y - body.size.y),
            max: Vec2(p.x + body.size.x, p.y + body.size.y)
        )
        world.updateColliderAABB(id: id, newAABB: aabb)
    }

    func update(input: InputState, dt: Double) {
        collisions.reset()

        // Track platform velocity from the previous grounded frame so we can work in platform space.
        let platformSample: (delta: Vec2, velocity: Vec2) = {
            guard wasGroundedLastFrame,
                  !suppressPlatformCarry,
                  let pid = lastPlatformID,
                  let collider = world.collider(for: pid),
                  collider.type == .movingPlatform else {
                return (Vec2(0, 0), Vec2(0, 0))
            }
            let delta = world.platformDisplacement(id: pid)
            let invDt = dt > 0 ? 1.0 / dt : 0
            return (delta, delta * invDt)
        }()
        let platformVelocity = platformSample.velocity

        // Horizontal acceleration (input + platform velocity)
        let hasInput = abs(input.moveX) > 1e-3
        let desiredRelativeVx = hasInput ? input.moveX * moveSpeed : 0
        var relativeVx = body.velocity.x - platformVelocity.x
        let accel = ((wasGroundedLastFrame ? 1.0 : airControl)) * 10.0
        relativeVx += (desiredRelativeVx - relativeVx) * min(1.0, accel * dt)
        if !hasInput && wasGroundedLastFrame {
            let k = min(1.0, groundFriction * dt)
            relativeVx += (-relativeVx) * k
        }
        if abs(relativeVx) < 1e-4 { relativeVx = 0 }
        body.velocity.x = relativeVx + platformVelocity.x
        if hasInput { facing = input.moveX > 0 ? 1 : -1 }

        // Clamp fall speed prior to integration; final clamp happens post integration as well.
        if body.velocity.y > maxFallSpeed { body.velocity.y = maxFallSpeed }

        // Carry motion from moving platforms (position delta per frame)
        let prePosition = body.position
        let preAABB = AABB(
            min: Vec2(prePosition.x - body.size.x, prePosition.y - body.size.y),
            max: Vec2(prePosition.x + body.size.x, prePosition.y + body.size.y)
        )

        var carriedDisplacement = Vec2(0, 0)
        if wasGroundedLastFrame,
           !suppressPlatformCarry,
           !input.jumpPressed,
           let platformID = lastPlatformID,
           let platform = world.collider(for: platformID) {
            let delta = platformID == lastPlatformID ? platformSample.delta : world.platformDisplacement(id: platformID)
            if delta.x != 0 || delta.y != 0 {
                let platformTop = platform.aabb.min.y
                let horizontalOverlap = preAABB.max.x > platform.aabb.min.x && preAABB.min.x < platform.aabb.max.x
                let verticalGap = platformTop - preAABB.max.y
                // Allow a small tolerance so we keep riding during frame boundary jitter
                let tolerance = max(2.0, abs(delta.y) + 1.0)
                if horizontalOverlap && verticalGap >= -tolerance && verticalGap <= tolerance {
                    carriedDisplacement = Vec2(0, delta.y)
                } else if verticalGap < -tolerance {
                    // Player dropped below the platform — stop carrying
                    lastPlatformID = nil
                }
            }
        }

        // Integrate with CCD-style axis solver and collect contacts
        var contacts: [Contact] = []
        world.integrateKinematic(
            id: id,
            state: &body,
            dt: dt,
            extraDisplacement: carriedDisplacement,
            outContacts: &contacts
        )

        // Classify contacts and build side-aware manifold
        for c in contacts {
            guard let other = world.collider(for: c.other) else { continue }
            collisions.absorb(contact: c, with: other)

            if c.normal.y < -0.5 { body.velocity.y = min(0, body.velocity.y) }
            else if c.normal.y > 0.5 { body.velocity.y = max(0, body.velocity.y) }
            else if c.normal.x > 0.5 { body.velocity.x = max(0, body.velocity.x) }
            else if c.normal.x < -0.5 { body.velocity.x = min(0, body.velocity.x) }
        }

        // Wall grab/slide
        var grabbingWall = false
        if input.grabHeld {
            if collisions.wallLeft && input.moveX < 0 { grabbingWall = true }
            if collisions.wallRight && input.moveX > 0 { grabbingWall = true }
        }
        if grabbingWall {
            body.velocity.x = 0
            if body.velocity.y > wallSlideSpeed { body.velocity.y = wallSlideSpeed }
        }

        // Coyote time & multi-jump reset
        if collisions.grounded {
            coyoteTimer = coyoteTime
            jumpsRemaining = extraJumps
        } else {
            coyoteTimer = max(0, coyoteTimer - dt)
        }

        var performedJump = false

        // Jump handling
        if input.jumpPressed {
            var didJump = false
            if collisions.grounded || coyoteTimer > 0 {
                body.velocity.y = platformVelocity.y - jumpImpulse
                didJump = true
            } else if grabbingWall {
                let dir = collisions.wallLeft ? 1.0 : -1.0
                body.velocity.x = platformVelocity.x + wallJumpImpulse.x * dir
                body.velocity.y = wallJumpImpulse.y
                didJump = true
                jumpsRemaining = extraJumps
            } else if jumpsRemaining > 0 {
                body.velocity.y = -jumpImpulse
                jumpsRemaining -= 1
                didJump = true
            }
            if didJump {
                coyoteTimer = 0
                performedJump = true
                suppressPlatformCarry = true
                lastPlatformID = nil
            }
        }

        // Clamp post-integration fall speed
        if body.velocity.y > maxFallSpeed { body.velocity.y = maxFallSpeed }

        let grounded = collisions.grounded
        let justLanded = grounded && !wasGroundedLastFrame

        if performedJump {
            wasGroundedLastFrame = false
        } else {
            wasGroundedLastFrame = grounded
        }

        if grounded, let pid = collisions.onPlatform {
            if !performedJump { suppressPlatformCarry = false }
            lastPlatformID = pid
        } else if !performedJump {
            lastPlatformID = nil
        }

        if performedJump {
            landStateTimer = 0
        } else if justLanded {
            landStateTimer = 0.16
        } else {
            landStateTimer = max(0, landStateTimer - dt)
        }

        movementPhase = resolveMovementPhase(
            grounded: grounded,
            performedJump: performedJump
        )

        // Push world collider to dynamic grid
        pushColliderState()
    }

    func setBodyDimensions(width: Double, height: Double) {
        let clampedWidth = max(4.0, width)
        let clampedHeight = max(4.0, height)
        self.width = clampedWidth
        self.height = clampedHeight
        let previousHalf = body.size
        let previousBottom = body.position.y + previousHalf.y
        let half = Vec2(clampedWidth * 0.5, clampedHeight * 0.5)
        body.size = half
        body.capsuleRadius = min(half.x, half.y)
        body.position.y = previousBottom - half.y
        pushColliderState()
    }

    private func pushColliderState() {
        let half = body.size
        let aabb = AABB(
            min: Vec2(body.position.x - half.x, body.position.y - half.y),
            max: Vec2(body.position.x + half.x, body.position.y + half.y)
        )
        world.updateColliderAABB(id: id, newAABB: aabb)
    }

    private func resolveMovementPhase(grounded: Bool, performedJump: Bool) -> MovementPhase {
        if performedJump {
            return .jump
        }
        if landStateTimer > 0 && grounded {
            return .land
        }

        if grounded {
            let horizontalSpeed = abs(body.velocity.x)
            let runThreshold = moveSpeed * 0.1
            return horizontalSpeed > runThreshold ? .run : .idle
        }

        let vy = body.velocity.y
        if (collisions.wallLeft || collisions.wallRight) && vy > 0 {
            return .wallSlide
        }
        if vy < -80 {
            return .jump
        }
        return .fall
    }
}

extension CharacterController {
    struct MovementSnapshot {
        let position: Vec2
        let velocity: Vec2
        let grounded: Bool
        let facing: Int
        let phase: MovementPhase
    }

    func movementSnapshot() -> MovementSnapshot {
        MovementSnapshot(
            position: body.position,
            velocity: body.velocity,
            grounded: collisions.grounded,
            facing: facing,
            phase: movementPhase
        )
    }
}
