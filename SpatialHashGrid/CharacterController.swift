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
    private(set) var capsuleRadius: Double = 12
    var moveSpeed: Double = 380
    var airControl: Double = 0.55
    var jumpImpulse: Double = 820
    var wallJumpImpulse: Vec2 = Vec2(560, -820)
    var maxFallSpeed: Double = 1500
    var wallSlideSpeed: Double = 240
    var allowSlopeSlide: Bool = false
    var rampUphillSpeedMultiplier: Double = 1.0
    var rampDownhillSpeedMultiplier: Double = 1.0
    var groundFriction: Double = 12.0
    var coyoteTime: Double = 0.12
    var extraJumps: Int = 1
    private(set) var coyoteTimer: Double = 0
    private(set) var jumpsRemaining: Int = 0

    // State
    var body: PhysicsWorld.BodyState
    var collisions = CollisionState()
    private(set) var supportContact: SurfaceContact? = nil
    private var lastPlatformID: ColliderID? = nil
    private var suppressPlatformCarry: Bool = false
    var wasGroundedLastFrame: Bool = false
    var facing: Int = 1 // 1 right, -1 left
    private(set) var movementPhase: MovementPhase = .idle
    private var landStateTimer: Double = 0
    private var desiredGroundVelocityX: Double = 0

    var isSuppressingPlatformCarry: Bool { suppressPlatformCarry }

    init(world: PhysicsWorld, spawn: Vec2) {
        self.world = world
        let baseRadius = width * 0.5
        let capsuleRadius = max(6.0, baseRadius - 3.0)
        let half = Vec2(capsuleRadius, height * 0.5)
        let capsuleHeight = max(0, height - 2.0 * capsuleRadius)
        self.capsuleRadius = capsuleRadius
        self.width = capsuleRadius * 2.0
        let aabb = AABB(
            min: Vec2(spawn.x - half.x, spawn.y - half.y),
            max: Vec2(spawn.x + half.x, spawn.y + half.y)
        )
        let shape = Shape.capsule(CapsuleData(radius: capsuleRadius, height: capsuleHeight))
        self.id = world.addDynamicEntity(aabb: aabb, material: Material(), shape: shape)
        self.body = PhysicsWorld.BodyState(position: spawn, velocity: Vec2(0, 0), size: half, capsuleRadius: capsuleRadius)
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
        supportContact = nil

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
        let desiredWorldVx = desiredRelativeVx + platformVelocity.x
        body.velocity.x = relativeVx + platformVelocity.x
        desiredGroundVelocityX = hasInput ? desiredWorldVx : body.velocity.x
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

            // Ramp & tile resolution share the same absorption; we project velocity off every contact normal
            // here so both blue (up-right) and green (up-left) ramps cancel only the component pushing into them.
            let normal = normalized(c.normal)
            let vn = simd_dot(body.velocity, normal)
            if vn < 0 {
                body.velocity -= normal * vn
            }
        }

        supportContact = selectSupportContact()
        let grounded = supportContact != nil

        if !allowSlopeSlide,
           !hasInput,
           let support = supportContact,
           abs(support.normal.x) > 0.05 {
            // Friction when idle on ramps; applies equally to both mirrored slopes.
            let normal = support.normal
            let tangent = Vec2(-normal.y, normal.x)
            let tangentialSpeed = simd_dot(body.velocity, tangent)
            if abs(tangentialSpeed) > 1 {
                body.velocity -= tangent * tangentialSpeed
            }
        }

        if let support = supportContact,
           let collider = world.collider(for: support.other),
           case .ramp(let rampData) = collider.shape,
           abs(support.normal.y) < 0.99 {
            let foot = footParameters()
            let clampedX = min(max(foot.center.x, collider.aabb.min.x), collider.aabb.max.x)
            let surfaceY = world.rampSurfaceY(ramp: collider.aabb, kind: rampData.kind, x: clampedX)
            let targetFootCenterY = surfaceY - foot.radius
            let deltaY = targetFootCenterY - foot.center.y
            if !input.jumpPressed, abs(deltaY) > 0.001 {
                body.position.y += deltaY
            }

            var tangent = Vec2(-support.normal.y, support.normal.x)
            let tangentLen = simd_length(tangent)
            if tangentLen > 1e-5 {
                tangent /= tangentLen

                let uphill = tangent.y < 0
                let multiplier = max(0.0, uphill ? rampUphillSpeedMultiplier : rampDownhillSpeedMultiplier)
                let horizontalTarget = desiredGroundVelocityX * multiplier
                let drive = hasInput ? horizontalTarget : body.velocity.x
                if drive * tangent.x < 0 {
                    tangent = -tangent
                }

                if !input.jumpPressed {
                    let axis = max(abs(tangent.x), 0.05)
                    let desiredAlong: Double
                    if hasInput {
                        desiredAlong = horizontalTarget / axis
                    } else if abs(horizontalTarget) > 1 {
                        desiredAlong = horizontalTarget / axis
                    } else {
                        desiredAlong = 0
                    }
                    let currentAlong = simd_dot(body.velocity, tangent)
                    let blend = hasInput ? 1.0 : 0.25
                    let newAlong = currentAlong + (desiredAlong - currentAlong) * blend
                    body.velocity += tangent * (newAlong - currentAlong)
                }
            }
        }

        if grounded, !hasInput {
            body.velocity.x *= 0.2
            if abs(body.velocity.x) < 1 { body.velocity.x = 0 }
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
        if grounded {
            coyoteTimer = coyoteTime
            jumpsRemaining = extraJumps
        } else {
            coyoteTimer = max(0, coyoteTimer - dt)
        }

        var performedJump = false

        // Jump handling
        if input.jumpPressed {
            var didJump = false
            if grounded || coyoteTimer > 0 {
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

        let justLanded = grounded && !wasGroundedLastFrame

        if performedJump {
            wasGroundedLastFrame = false
        } else {
            wasGroundedLastFrame = grounded
        }

        if grounded {
            if !performedJump { suppressPlatformCarry = false }
            if let support = supportContact, support.type == .movingPlatform {
                lastPlatformID = support.other
            } else if let pid = collisions.onPlatform {
                lastPlatformID = pid
            }
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
        let newRadius = max(6.0, clampedWidth * 0.5 - 3.0)
        self.width = newRadius * 2.0
        self.height = clampedHeight
        capsuleRadius = newRadius
        let previousHalf = body.size
        let previousBottom = body.position.y + previousHalf.y
        let half = Vec2(newRadius, clampedHeight * 0.5)
        body.size = half
        body.capsuleRadius = newRadius
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
            grounded: supportContact != nil,
            facing: facing,
            phase: movementPhase
        )
    }
}

private extension CharacterController {
    func normalized(_ v: Vec2) -> Vec2 {
        let len = simd_length(v)
        if len <= 1e-8 { return Vec2(0, 0) }
        return v / len
    }

    func footParameters() -> (center: Vec2, radius: Double) {
        let radius = body.capsuleRadius
        let offset = max(0, body.size.y - radius)
        let center = Vec2(body.position.x, body.position.y + offset)
        return (center, radius)
    }

    func selectSupportContact() -> SurfaceContact? {
        var best: SurfaceContact?
        for contact in collisions.ground {
            guard let collider = world.collider(for: contact.other) else { continue }
            if !isSupportCandidate(contact, collider: collider) { continue }
            if let current = best {
                if contact.depth > current.depth { best = contact }
            } else {
                best = contact
            }
        }
        return best
    }

    func isSupportCandidate(_ contact: SurfaceContact, collider: Collider) -> Bool {
        let verticalThreshold = -0.2
        if contact.normal.y > verticalThreshold { return false }

        switch collider.shape {
        case .ramp:
            return true
        default:
            let footX = body.position.x
            let radius = body.capsuleRadius
            let width = collider.aabb.max.x - collider.aabb.min.x
            let inset = max(0.5, min(width * 0.45, radius * 0.6))
            if footX < collider.aabb.min.x - radius * 0.25 { return false }
            if footX > collider.aabb.max.x + radius * 0.25 { return false }
            let x = contact.point.x
            if x <= collider.aabb.min.x + inset { return false }
            if x >= collider.aabb.max.x - inset { return false }
            return true
        }
    }
}
