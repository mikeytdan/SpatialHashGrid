//
//  GameControllerManagerTests.swift
//  SpatialHashGridTests
//
//  Created by AI Assistant on 10/7/24.
//

import Foundation
import simd
import Testing
@testable import SpatialHashGrid

@Suite
struct GameControllerManagerTests {

    @Test
    func deadZoneAndSmoothing() {
        let manager = GameControllerManager(userDefaults: .ephemeral)
        manager.deadZoneLeft = 0.2
        manager.analogSmoothing = 0.5

        let sim = GameControllerManager.SimulatedController(name: "Sim")
        let ref = manager.attachSimulatedController(sim)
        #expect(manager.assignedPlayer(for: ref) == 1)

        // Small input inside dead zone should zero out.
        sim.sendSnapshot(move: SIMD2<Float>(0.1, 0.1), aim: .zero, buttons: [], timestamp: 0)
        manager.update(frameTime: 1 / 60)
        let state0 = manager.state(for: 1)
        #expect(state0?.move == .zero)

        // Large input should be smoothed (EMA with alpha=0.5 from previous zero).
        sim.sendSnapshot(move: SIMD2<Float>(1, 0), aim: .zero, buttons: [], timestamp: 1 / 60)
        manager.update(frameTime: 1 / 60)
        let state1 = manager.state(for: 1)
        #expect(state1?.move.x ?? 0, accuracy: 0.001, == 0.5)
    }

    @Test
    func buttonEdgesAndRelease() {
        let manager = GameControllerManager(userDefaults: .ephemeral)
        let sim = GameControllerManager.SimulatedController(name: "Sim")
        _ = manager.attachSimulatedController(sim)

        sim.sendSnapshot(move: .zero, aim: .zero, buttons: [.south], timestamp: 0)
        manager.update(frameTime: 1 / 120)
        let pressed = manager.state(for: 1)
        #expect(pressed?.justPressed.contains(.south) == true)
        #expect(pressed?.justReleased.isEmpty == true)

        // Release
        sim.sendSnapshot(move: .zero, aim: .zero, buttons: [], timestamp: 1 / 60)
        manager.update(frameTime: 1 / 120)
        let released = manager.state(for: 1)
        #expect(released?.justReleased.contains(.south) == true)
    }

    @Test
    func repeatAndLongPress() {
        let manager = GameControllerManager(userDefaults: .ephemeral)
        manager.repeatDelay = 0.2
        manager.repeatRate = 0.1
        manager.longPressThreshold = 0.15

        var downEvents: [(GameControllerManager.PlayerID, GameControllerManager.GameButton)] = []
        var repeatEvents: [(GameControllerManager.PlayerID, GameControllerManager.GameButton)] = []
        manager.onButtonDown = { downEvents.append(($0, $1)) }
        manager.onRepeat = { repeatEvents.append(($0, $1)) }

        let sim = GameControllerManager.SimulatedController(name: "Sim")
        _ = manager.attachSimulatedController(sim)

        sim.sendSnapshot(move: .zero, aim: .zero, buttons: [.south], timestamp: 0)
        manager.update(frameTime: 0)
        #expect(downEvents.count == 1)

        // Advance past long-press threshold and first repeat interval.
        manager.update(frameTime: 0.2)
        let state = manager.state(for: 1)
        #expect(state?.longPressing.contains(.south) == true)
        #expect(repeatEvents.count == 1)
    }

    @Test
    func assignmentSwapAndCycle() {
        let manager = GameControllerManager(userDefaults: .ephemeral)
        manager.maxPlayers = 2

        let simA = GameControllerManager.SimulatedController(name: "A")
        let simB = GameControllerManager.SimulatedController(name: "B")
        let refA = manager.attachSimulatedController(simA)
        let refB = manager.attachSimulatedController(simB)

        #expect(manager.assignedPlayer(for: refA) == 1)
        #expect(manager.assignedPlayer(for: refB) == 2)

        manager.cycleAssignment(for: refA)
        #expect(manager.assignedPlayer(for: refA) == 2)
        #expect(manager.assignedPlayer(for: refB) == 1)
    }

    @Test
    func restoreAssignmentAfterReconnect() {
        let manager = GameControllerManager(userDefaults: .ephemeral)
        let sim = GameControllerManager.SimulatedController(name: "Sim")
        let ref = manager.attachSimulatedController(sim)
        #expect(manager.assignedPlayer(for: ref) == 1)

        manager.detachSimulatedController(id: ref.id)
        let newRef = manager.attachSimulatedController(sim)
        #expect(newRef.id == ref.id)
        #expect(manager.assignedPlayer(for: newRef) == 1)
    }

    @Test
    func autoPauseOnDisconnect() {
        let manager = GameControllerManager(userDefaults: .ephemeral)
        manager.autoPauseOnDisconnect = true
        var events: [(GameControllerManager.PlayerID, GameControllerManager.GameButton)] = []
        manager.onButtonDown = { events.append(($0, $1)) }

        let sim = GameControllerManager.SimulatedController(name: "Sim")
        let ref = manager.attachSimulatedController(sim)
        #expect(manager.assignedPlayer(for: ref) == 1)

        manager.detachSimulatedController(id: ref.id)
        #expect(events.contains(where: { $0.0 == 1 && $0.1 == .pause }))
    }
}

private extension UserDefaults {
    static var ephemeral: UserDefaults {
        let suite = "GameControllerManagerTests.ephemeral"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
