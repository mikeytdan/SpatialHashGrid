//
//  InputController.swift
//  SpatialHashGrid
//
//  Created by Michael Daniels on 9/29/25.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

enum KeyboardInputPhase {
    case down
    case up
}

struct KeyboardModifiers: OptionSet {
    let rawValue: Int

    static let shift    = KeyboardModifiers(rawValue: 1 << 0)
    static let command  = KeyboardModifiers(rawValue: 1 << 1)
    static let option   = KeyboardModifiers(rawValue: 1 << 2)
    static let control  = KeyboardModifiers(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

extension KeyboardModifiers {
    init(_ modifiers: EventModifiers) {
        var value: KeyboardModifiers = []
        if modifiers.contains(.shift) { value.insert(.shift) }
        if modifiers.contains(.command) { value.insert(.command) }
        if modifiers.contains(.option) { value.insert(.option) }
        if modifiers.contains(.control) { value.insert(.control) }
        self = value
    }
}

#if os(macOS)
extension KeyboardModifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        var value: KeyboardModifiers = []
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.control) { value.insert(.control) }
        self = value
    }
}
#endif

#if canImport(UIKit)
extension KeyboardModifiers {
    init(_ flags: UIKeyModifierFlags) {
        var value: KeyboardModifiers = []
        if flags.contains(.shift) { value.insert(.shift) }
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.alternate) { value.insert(.option) }
        if flags.contains(.control) { value.insert(.control) }
        self = value
    }
}
#endif

enum KeyboardKey: Equatable {
    case leftArrow
    case rightArrow
    case upArrow
    case downArrow
    case escape
    case other
}

#if os(macOS)
extension KeyboardKey {
    init?(event: NSEvent) {
        switch Int(event.keyCode) {
        case 123: self = .leftArrow
        case 124: self = .rightArrow
        case 125: self = .downArrow
        case 126: self = .upArrow
        case 53:  self = .escape
        default:
            return nil
        }
    }
}
#endif

struct KeyboardInput {
    var key: KeyboardKey?
    var characters: String
    var modifiers: KeyboardModifiers

    init(key: KeyboardKey?, characters: String, modifiers: KeyboardModifiers) {
        self.key = key
        self.characters = characters
        self.modifiers = modifiers
    }
}

extension KeyboardInput {
    init(_ keyPress: KeyPress) {
        let key: KeyboardKey?
        switch keyPress.key {
        case .leftArrow:
            key = .leftArrow
        case .rightArrow:
            key = .rightArrow
        case .upArrow:
            key = .upArrow
        case .downArrow:
            key = .downArrow
        case .escape:
            key = .escape
        default:
            key = nil
        }

        self.init(
            key: key,
            characters: keyPress.characters,
            modifiers: KeyboardModifiers(keyPress.modifiers)
        )
    }
}

#if os(macOS)
extension KeyboardInput {
    init(event: NSEvent) {
        let key = KeyboardKey(event: event)
        let characters = event.charactersIgnoringModifiers ?? ""
        self.init(key: key, characters: characters, modifiers: KeyboardModifiers(event.modifierFlags))
    }
}
#endif

#if canImport(UIKit)
extension KeyboardInput {
    // Map UIPress data into the normalized keyboard payload we share across platforms.
    init(_ press: UIPress) {
        let key: KeyboardKey?
        if let usage = press.key?.keyCode {
            switch usage {
            case .keyboardLeftArrow:
                key = .leftArrow
            case .keyboardRightArrow:
                key = .rightArrow
            case .keyboardUpArrow:
                key = .upArrow
            case .keyboardDownArrow:
                key = .downArrow
            case .keyboardEscape:
                key = .escape
            default:
                key = nil
            }
        } else {
            key = nil
        }

        let characters = press.key?.charactersIgnoringModifiers ?? press.key?.characters ?? ""
        let modifiers = KeyboardModifiers(press.key?.modifierFlags ?? [])
        self.init(key: key, characters: characters, modifiers: modifiers)
    }
}
#endif

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

/// Pure key-state accumulator (no @Published, so safe to use on the key event path).
final class InputController {
    private var held: GameCommand = []
    private var pendingPressed: GameCommand = []

    func handleKeyDown(_ input: KeyboardInput) {
        apply(commands(for: input), isDown: true)
    }

    func handleKeyUp(_ input: KeyboardInput) {
        apply(commands(for: input), isDown: false)
    }

    func handleKeyDown(_ keyPress: KeyPress) {
        handleKeyDown(KeyboardInput(keyPress))
    }

    func handleKeyUp(_ keyPress: KeyPress) {
        handleKeyUp(KeyboardInput(keyPress))
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

    private func commands(for input: KeyboardInput) -> GameCommand {
        var commands: GameCommand = []

        if let key = input.key {
            switch key {
            case .leftArrow:
                commands.insert(.moveLeft)
            case .rightArrow:
                commands.insert(.moveRight)
            case .upArrow:
                commands.insert(.jump)
            case .escape:
                commands.insert(.stop)
            default:
                break
            }
        }

        let normalizedCharacters = input.characters.lowercased()
        if normalizedCharacters.contains("a") { commands.insert(.moveLeft) }
        if normalizedCharacters.contains("d") { commands.insert(.moveRight) }
        if normalizedCharacters.contains("w") || normalizedCharacters.contains(" ") {
            commands.insert(.jump)
        }

        if input.modifiers.contains(.command) {
            if normalizedCharacters.contains("z") {
                if input.modifiers.contains(.shift) {
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
