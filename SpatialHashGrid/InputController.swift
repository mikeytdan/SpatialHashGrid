//
//  InputController.swift
//  SpatialHashGrid
//
//  Created by Michael Daniels on 9/29/25.
//

import SwiftUI

/// High-level game commands (both continuous and edge-triggered).
struct GameCommand: OptionSet {
    let rawValue: Int
    static let moveLeft   = GameCommand(rawValue: 1 << 0)
    static let moveRight  = GameCommand(rawValue: 1 << 1)
    static let jump       = GameCommand(rawValue: 1 << 2) // edge-triggered
    static let stop       = GameCommand(rawValue: 1 << 3) // edge-triggered (Esc)
    static let undo       = GameCommand(rawValue: 1 << 4) // edge-triggered
    static let redo       = GameCommand(rawValue: 1 << 5) // edge-triggered
}

/// Snapshot of input for this frame.
struct InputSample {
    /// All keys currently held down.
    let held: GameCommand
    /// Keys that went from up→down this frame (edge-trigger).
    let pressed: GameCommand
    /// Convenience axis from held state.
    var axisX: Double {
        switch (held.contains(.moveLeft), held.contains(.moveRight)) {
        case (true, false):  return -1
        case (false, true):  return  1
        default:             return  0
        }
    }
    /// True only on the first frame jump was pressed.
    var jumpPressedEdge: Bool { pressed.contains(.jump) }
}

/// Pure key-state accumulator (no @Published, so safe in .onKeyPress).
final class InputController {
    private var held: GameCommand = []
    private var pendingPressed: GameCommand = []

    func handleKeyDown(_ kp: KeyPress) {
        apply(commandsForKeyPress(kp), isDown: true)
    }

    func handleKeyUp(_ kp: KeyPress) {
        apply(commandsForKeyPress(kp), isDown: false)
    }

    /// Called once per frame from SKScene.update.
    /// Returns the current held state plus edge-triggered commands since the last sample.
    func sample() -> InputSample {
        let sample = InputSample(held: held, pressed: pendingPressed)
        pendingPressed = []
        return sample
    }

    /// Clears the current state. Useful when switching between input consumers.
    func reset() {
        held = []
        pendingPressed = []
    }

    /// Returns the commands that were edge-triggered since the last drain without
    /// affecting the held state. Helpful for callers that only need discrete actions.
    @discardableResult
    func drainPressedCommands() -> GameCommand {
        let pressed = pendingPressed
        pendingPressed = []
        return pressed
    }

    // MARK: - Mapping

    private func apply(_ commands: GameCommand, isDown: Bool) {
        guard !commands.isEmpty else { return }

        if isDown {
            let newlyPressed = commands.subtracting(held)
            if !newlyPressed.isEmpty {
                pendingPressed.formUnion(newlyPressed)
            }
            held.formUnion(commands)
        } else {
            held.subtract(commands)
        }
    }

    private func commandsForKeyPress(_ kp: KeyPress) -> GameCommand {
        var commands: GameCommand = []

        // Movement (arrows & WASD)
        switch kp.key {
        case .leftArrow: commands.insert(.moveLeft)
        case .rightArrow: commands.insert(.moveRight)
        case .upArrow: commands.insert(.jump)
        default: break
        }

        let normalizedCharacters = kp.characters.lowercased()
        if normalizedCharacters.contains("a") { commands.insert(.moveLeft) }
        if normalizedCharacters.contains("d") { commands.insert(.moveRight) }
        if normalizedCharacters.contains("w") || normalizedCharacters.contains(" ") {
            commands.insert(.jump)
        }

        // Escape → stop
        if kp.key == .escape {
            commands.insert(.stop)
        }

        // Undo / Redo (Cmd-Z, Shift-Cmd-Z or Cmd-Y)
        if kp.modifiers.contains(.command) {
            if normalizedCharacters.contains("z") {
                if kp.modifiers.contains(.shift) {
                    commands.insert(.redo)
                } else {
                    commands.insert(.undo)
                }
            }
            if normalizedCharacters.contains("y") {
                commands.insert(.redo)
            }
        }

        return commands
    }
}
