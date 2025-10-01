//
//  GameControllerManager.swift
//  SpatialHashGrid
//
//  Created by AI Assistant on 10/7/24.
//

import Foundation
import simd
#if canImport(QuartzCore)
import QuartzCore
#endif
#if canImport(GameController)
import GameController
#endif
#if canImport(CoreHaptics)
import CoreHaptics
#endif

/// Manages GameController devices, normalizing their input into per-player snapshots
/// and providing optional event callbacks for button edges, repeats, and connect lifecycle.
final class GameControllerManager {

    // MARK: Public Support Types

    struct ControllerRef: Hashable {
        let id: String
        let name: String
    }

    typealias PlayerID = Int

    struct InputState {
        var move: SIMD2<Float> = .zero
        var aim: SIMD2<Float> = .zero
        var buttons: ButtonFlags = []
        var justPressed: ButtonFlags = []
        var justReleased: ButtonFlags = []
        var longPressing: ButtonFlags = []
        var leftTrigger: Float = 0
        var rightTrigger: Float = 0
        var timestamp: TimeInterval = 0
    }

    enum GameButton: Int, CaseIterable {
        case south
        case east
        case west
        case north
        case leftBumper
        case rightBumper
        case menu
        case select
        case leftStickPress
        case rightStickPress
        case dpadUp
        case dpadDown
        case dpadLeft
        case dpadRight
        case pause
    }

    struct ButtonFlags: OptionSet {
        let rawValue: UInt32

        init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        static func flag(_ button: GameButton) -> ButtonFlags {
            ButtonFlags(rawValue: 1 << button.rawValue)
        }

        func contains(_ button: GameButton) -> Bool {
            contains(ButtonFlags.flag(button))
        }

        mutating func insert(_ button: GameButton) {
            insert(ButtonFlags.flag(button))
        }

        static let south = flag(.south)
        static let east = flag(.east)
        static let west = flag(.west)
        static let north = flag(.north)
        static let leftBumper = flag(.leftBumper)
        static let rightBumper = flag(.rightBumper)
        static let menu = flag(.menu)
        static let select = flag(.select)
        static let leftStickPress = flag(.leftStickPress)
        static let rightStickPress = flag(.rightStickPress)
        static let dpadUp = flag(.dpadUp)
        static let dpadDown = flag(.dpadDown)
        static let dpadLeft = flag(.dpadLeft)
        static let dpadRight = flag(.dpadRight)
        static let pause = flag(.pause)
    }

    // MARK: Public Configuration & Events

    var deadZoneLeft: Float = 0.15
    var deadZoneRight: Float = 0.15
    var analogSmoothing: Float = 0.25
    var longPressThreshold: TimeInterval = 0.4
    var repeatDelay: TimeInterval = 0.45
    var repeatRate: TimeInterval = 0.08
    var autoPauseOnDisconnect: Bool = true

    var maxPlayers: Int {
        get { maxPlayersValue }
        set {
            let clamped = max(1, newValue)
            maxPlayersValue = clamped
            maxPlayersAuto = false
            trimAssignmentsBeyondMax()
        }
    }

    var connectedControllers: [ControllerRef] {
        connectionOrder.compactMap { controllersByID[$0]?.ref }
    }

    var onControllerConnected: ((ControllerRef) -> Void)?
    var onControllerDisconnected: ((ControllerRef) -> Void)?
    var onPlayerAssignmentChanged: ((ControllerRef, PlayerID?) -> Void)?
    var onButtonDown: ((PlayerID, GameButton) -> Void)?
    var onButtonUp: ((PlayerID, GameButton) -> Void)?
    var onRepeat: ((PlayerID, GameButton) -> Void)?

    // MARK: Lifecycle

    init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
        loadPersistedAssignments()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        registerForNotifications()
        updateAutoMaxPlayers()
        #if canImport(GameController)
        GCController.controllers().forEach { handleConnect(controller: $0) }
        #endif
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        unregisterNotifications()
        let handles = controllersByID
        controllersByID.removeAll()
        connectionOrder.removeAll()
        fingerprintByID.removeAll()
        handles.values.forEach { $0.source.shutdown() }
    }

    // MARK: Polling

    func update(frameTime: TimeInterval) {
        guard frameTime.isFinite else { return }
        globalTime += max(0, frameTime)
        processPendingSnapshots()
        serviceAssignments()
    }

    func state(for player: PlayerID) -> InputState? {
        guard let controllerID = playerToControllerID[player],
              controllersByID[controllerID] != nil else {
            return nil
        }
        return inputByPlayer[player]?.state
    }

    // MARK: Assignment API

    func assignedPlayer(for controller: ControllerRef) -> PlayerID? {
        controllerIDToPlayer[controller.id]
    }

    func assign(controller: ControllerRef, to player: PlayerID?) {
        guard let handle = controllersByID[controller.id] else { return }
        setAssignment(for: handle, to: player)
    }

    func cycleAssignment(for controller: ControllerRef) {
        guard let handle = controllersByID[controller.id] else { return }
        let current = handle.assignment ?? controllerIDToPlayer[controller.id]
        let target: PlayerID
        if let current {
            var next = current + 1
            if next > maxPlayersValue { next = 1 }
            target = next
        } else {
            target = 1
        }
        setAssignment(for: handle, to: target)
    }

    func rumble(player: PlayerID, intensity: Float, duration: TimeInterval) {
        guard let controllerID = playerToControllerID[player],
              let handle = controllersByID[controllerID] else {
            return
        }
        handle.source.rumble(intensity: max(0, min(1, intensity)), duration: max(0, duration))
    }

    // MARK: Internal Types

    struct RawControllerSnapshot {
        var move: SIMD2<Float>
        var aim: SIMD2<Float>
        var leftTrigger: Float
        var rightTrigger: Float
        var buttons: ButtonFlags
        var timestamp: TimeInterval

        static let zero = RawControllerSnapshot(
            move: .zero,
            aim: .zero,
            leftTrigger: 0,
            rightTrigger: 0,
            buttons: [],
            timestamp: 0
        )
    }

    private struct ButtonPressState {
        var isHeld = false
        var pressStart: TimeInterval = 0
        var nextRepeat: TimeInterval = 0
        var longPressFired = false
    }

    private struct MutablePlayerState {
        var state = InputState()
        var smoothedMove: SIMD2<Float> = .zero
        var smoothedAim: SIMD2<Float> = .zero
        var previousButtons: ButtonFlags = []
        var buttonStates: [GameButton: ButtonPressState] = [:]
    }

    private final class ControllerHandle {
        let ref: ControllerRef
        let source: ControllerInputSource
        var assignment: PlayerID?
        var lastSnapshot: RawControllerSnapshot
        var pendingSnapshot: RawControllerSnapshot?
        let fingerprint: String

        init(ref: ControllerRef, source: ControllerInputSource, fingerprint: String) {
            self.ref = ref
            self.source = source
            self.fingerprint = fingerprint
            self.lastSnapshot = .zero
        }
    }

    // MARK: Storage

    private var controllersByID: [String: ControllerHandle] = [:]
    private var connectionOrder: [String] = []
    private var playerToControllerID: [PlayerID: String] = [:]
    private var controllerIDToPlayer: [String: PlayerID] = [:]
    private var inputByPlayer: [PlayerID: MutablePlayerState] = [:]
    private var persistedAssignments: [String: PlayerID] = [:]
    private var fingerprintCounts: [String: Int] = [:]
    private var fingerprintRecyclePool: [String: [String]] = [:]
    private var fingerprintByID: [String: String] = [:]
    private var isRunning = false
    private var maxPlayersValue: Int = 1
    private var maxPlayersAuto = true
    private var globalTime: TimeInterval = 0
    private var defaults: UserDefaults
    private var connectObserver: Any?
    private var disconnectObserver: Any?
    private var lastTransitionStamp: [ObjectIdentifier: TimeInterval] = [:]
    private let debounceInterval: TimeInterval = 0.3

    private let persistenceKey = "GameControllerManager.controllerAssignments"

    // MARK: Snapshot Flow

    private func processPendingSnapshots() {
        for handle in controllersByID.values {
            if let snapshot = handle.pendingSnapshot {
                handle.lastSnapshot = snapshot
                handle.pendingSnapshot = nil
            } else {
                handle.lastSnapshot = handle.source.captureSnapshot()
            }
        }
    }

    private func serviceAssignments() {
        guard maxPlayersValue > 0 else { return }
        for player in 1...maxPlayersValue {
            guard let controllerID = playerToControllerID[player],
                  let handle = controllersByID[controllerID] else {
                // Clear justPressed for dormant slots
                if var mutable = inputByPlayer[player] {
                    mutable.state.justPressed = []
                    mutable.state.justReleased = []
                    mutable.state.longPressing = []
                    inputByPlayer[player] = mutable
                }
                continue
            }
            var mutable = inputByPlayer[player] ?? MutablePlayerState()
            let snapshot = handle.lastSnapshot
            mutable.state = updatePlayer(player, snapshot: snapshot, mutable: &mutable)
            inputByPlayer[player] = mutable
        }
    }

    private func updatePlayer(_ player: PlayerID, snapshot: RawControllerSnapshot, mutable: inout MutablePlayerState) -> InputState {
        let move = applyDeadZone(snapshot.move, limit: deadZoneLeft)
        let aim = applyDeadZone(snapshot.aim, limit: deadZoneRight)
        mutable.smoothedMove = blend(previous: mutable.smoothedMove, next: move, alpha: analogSmoothing)
        mutable.smoothedAim = blend(previous: mutable.smoothedAim, next: aim, alpha: analogSmoothing)

        let buttons = snapshot.buttons
        let prevButtons = mutable.previousButtons
        let justPressed = buttons.subtracting(prevButtons)
        let justReleased = prevButtons.subtracting(buttons)

        var state = mutable.state
        state.move = mutable.smoothedMove
        state.aim = mutable.smoothedAim
        state.leftTrigger = snapshot.leftTrigger
        state.rightTrigger = snapshot.rightTrigger
        state.buttons = buttons
        state.justPressed = justPressed
        state.justReleased = justReleased
        state.timestamp = snapshot.timestamp

        var longPressFlags: ButtonFlags = []

        for button in GameButton.allCases {
            let flag = ButtonFlags.flag(button)
            let isDown = buttons.contains(flag)
            var pressState = mutable.buttonStates[button] ?? ButtonPressState()
            if isDown {
                if !pressState.isHeld {
                    pressState.isHeld = true
                    pressState.pressStart = globalTime
                    pressState.nextRepeat = globalTime + repeatDelay
                    pressState.longPressFired = false
                    emitButtonDown(player: player, button: button)
                } else {
                    let held = globalTime - pressState.pressStart
                    if !pressState.longPressFired && held >= longPressThreshold {
                        pressState.longPressFired = true
                    }
                    if repeatRate > 0 {
                        while globalTime >= pressState.nextRepeat {
                            pressState.nextRepeat += repeatRate
                            emitRepeat(player: player, button: button)
                        }
                    }
                }
                if pressState.longPressFired {
                    longPressFlags.insert(button)
                }
            } else if pressState.isHeld {
                pressState.isHeld = false
                pressState.longPressFired = false
                pressState.nextRepeat = 0
                emitButtonUp(player: player, button: button)
            }
            if !isDown {
                pressState.longPressFired = false
            }
            mutable.buttonStates[button] = pressState
        }

        state.longPressing = longPressFlags
        mutable.previousButtons = buttons
        return state
    }

    // MARK: Assignment Helpers

    private func setAssignment(for handle: ControllerHandle, to player: PlayerID?, callCallback: Bool = true) {
        let controllerID = handle.ref.id
        let previousPlayer = controllerIDToPlayer[controllerID]
        if previousPlayer == player { return }

        if let previousPlayer {
            playerToControllerID.removeValue(forKey: previousPlayer)
        }
        controllerIDToPlayer.removeValue(forKey: controllerID)
        handle.assignment = nil

        if let player {
            if player > maxPlayersValue { maxPlayersValue = player }
            if let occupyingID = playerToControllerID[player], occupyingID != controllerID {
                playerToControllerID[player] = controllerID
                controllerIDToPlayer[controllerID] = player
                handle.assignment = player

                if let otherHandle = controllersByID[occupyingID] {
                    if let previousPlayer {
                        playerToControllerID[previousPlayer] = occupyingID
                        controllerIDToPlayer[occupyingID] = previousPlayer
                        otherHandle.assignment = previousPlayer
                        if callCallback {
                            onPlayerAssignmentChanged?(otherHandle.ref, previousPlayer)
                        }
                    } else {
                        controllerIDToPlayer.removeValue(forKey: occupyingID)
                        otherHandle.assignment = nil
                        if callCallback {
                            onPlayerAssignmentChanged?(otherHandle.ref, nil)
                        }
                    }
                } else {
                    controllerIDToPlayer.removeValue(forKey: occupyingID)
                }
            } else {
                playerToControllerID[player] = controllerID
                controllerIDToPlayer[controllerID] = player
                handle.assignment = player
            }
        }

        if callCallback {
            onPlayerAssignmentChanged?(handle.ref, handle.assignment)
        }
        saveAssignments()
    }

    private func attemptAssignmentRestore(for handle: ControllerHandle) {
        let id = handle.ref.id
        if let inMemory = controllerIDToPlayer[id] {
            setAssignment(for: handle, to: inMemory, callCallback: false)
        } else if let persisted = persistedAssignments[id] {
            setAssignment(for: handle, to: persisted, callCallback: false)
        } else if let fallback = firstAvailablePlayer() {
            setAssignment(for: handle, to: fallback, callCallback: false)
        }
    }

    private func firstAvailablePlayer() -> PlayerID? {
        for player in 1...maxPlayersValue {
            if playerToControllerID[player] == nil {
                return player
            }
        }
        return nil
    }

    private func trimAssignmentsBeyondMax() {
        for (player, controllerID) in playerToControllerID where player > maxPlayersValue {
            playerToControllerID.removeValue(forKey: player)
            if let handle = controllersByID[controllerID] {
                handle.assignment = nil
            }
            controllerIDToPlayer.removeValue(forKey: controllerID)
        }
    }

    private func updateAutoMaxPlayers() {
        guard maxPlayersAuto else { return }
        maxPlayersValue = max(1, controllersByID.count)
    }

    // MARK: Identifier Management

    private func makeIdentifier(for source: ControllerInputSource) -> String {
        if let persistent = source.persistentIdentifier, !persistent.isEmpty {
            return persistent
        }
        let fingerprint = source.fingerprint
        if let reused = pickPersistedIdentifier(for: fingerprint) {
            return reused
        }
        if var pool = fingerprintRecyclePool[fingerprint], !pool.isEmpty {
            let id = pool.removeFirst()
            fingerprintRecyclePool[fingerprint] = pool
            return id
        }
        let next = (fingerprintCounts[fingerprint] ?? 0) + 1
        fingerprintCounts[fingerprint] = next
        return "\(fingerprint)#\(next)"
    }

    private func pickPersistedIdentifier(for fingerprint: String) -> String? {
        for key in persistedAssignments.keys.sorted() {
            guard controllersByID[key] == nil else { continue }
            if key == fingerprint || key.hasPrefix("\(fingerprint)#") {
                return key
            }
        }
        return nil
    }

    private func recycleIdentifier(_ id: String, fingerprint: String) {
        var pool = fingerprintRecyclePool[fingerprint] ?? []
        if !pool.contains(id) {
            pool.append(id)
        }
        fingerprintRecyclePool[fingerprint] = pool
    }

    // MARK: Persistence

    private func loadPersistedAssignments() {
        guard let stored = defaults.dictionary(forKey: persistenceKey) as? [String: Int] else { return }
        persistedAssignments = stored
    }

    private func saveAssignments() {
        defaults.setValue(controllerIDToPlayer, forKey: persistenceKey)
        persistedAssignments = controllerIDToPlayer
    }

    // MARK: Controller Registration

    private func register(handle: ControllerHandle) {
        controllersByID[handle.ref.id] = handle
        fingerprintByID[handle.ref.id] = handle.fingerprint
        if !connectionOrder.contains(handle.ref.id) {
            connectionOrder.append(handle.ref.id)
        }
        handle.source.setSnapshotHandler { [weak handle] snapshot in
            handle?.pendingSnapshot = snapshot
        }
        handle.source.prepare()
        handle.lastSnapshot = handle.source.captureSnapshot()
        updateAutoMaxPlayers()
        attemptAssignmentRestore(for: handle)
        let ref = handle.ref
        if Thread.isMainThread {
            onControllerConnected?(ref)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onControllerConnected?(ref) }
        }
    }

    private func removeHandle(_ handle: ControllerHandle) {
        let id = handle.ref.id
        let fingerprint = handle.fingerprint
        controllersByID.removeValue(forKey: id)
        connectionOrder.removeAll(where: { $0 == id })
        fingerprintByID.removeValue(forKey: id)
        handle.source.shutdown()
        recycleIdentifier(id, fingerprint: fingerprint)
        updateAutoMaxPlayers()
    }

    // MARK: Notification Handling

    private func registerForNotifications() {
        let center = NotificationCenter.default
        #if canImport(GameController)
        connectObserver = center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.handleConnect(controller: controller)
        }
        disconnectObserver = center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.handleDisconnect(controller: controller)
        }
        #endif
    }

    private func unregisterNotifications() {
        let center = NotificationCenter.default
        if let connectObserver {
            center.removeObserver(connectObserver)
            self.connectObserver = nil
        }
        if let disconnectObserver {
            center.removeObserver(disconnectObserver)
            self.disconnectObserver = nil
        }
    }

    #if canImport(GameController)
    private func handleConnect(controller: GCController) {
        let pointer = ObjectIdentifier(controller)
        let now = currentTimestamp()
        if let last = lastTransitionStamp[pointer], now - last < debounceInterval { return }
        lastTransitionStamp[pointer] = now

        let source = PhysicalControllerSource(controller: controller)
        let identifier = makeIdentifier(for: source)
        let ref = ControllerRef(id: identifier, name: source.displayName)
        let handle = ControllerHandle(ref: ref, source: source, fingerprint: source.fingerprint)
        register(handle: handle)
    }

    private func handleDisconnect(controller: GCController) {
        let pointer = ObjectIdentifier(controller)
        let now = currentTimestamp()
        if let last = lastTransitionStamp[pointer], now - last < debounceInterval { return }
        lastTransitionStamp[pointer] = now

        guard let entry = controllersByID.first(where: { $0.value.source.matches(controller: controller) }) else { return }
        let handle = entry.value
        let assignedPlayer = handle.assignment ?? controllerIDToPlayer[handle.ref.id]
        removeHandle(handle)
        if Thread.isMainThread {
            onControllerDisconnected?(handle.ref)
            if autoPauseOnDisconnect, let player = assignedPlayer {
                emitButtonDown(player: player, button: .pause)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onControllerDisconnected?(handle.ref)
                if self?.autoPauseOnDisconnect == true, let player = assignedPlayer {
                    self?.emitButtonDown(player: player, button: .pause)
                }
            }
        }
    }
    #endif

    // MARK: Emission Helpers

    private func emitButtonDown(player: PlayerID, button: GameButton) {
        emit(callback: onButtonDown, player: player, button: button)
    }

    private func emitButtonUp(player: PlayerID, button: GameButton) {
        emit(callback: onButtonUp, player: player, button: button)
    }

    private func emitRepeat(player: PlayerID, button: GameButton) {
        emit(callback: onRepeat, player: player, button: button)
    }

    private func emit(callback: ((PlayerID, GameButton) -> Void)?, player: PlayerID, button: GameButton) {
        guard let callback else { return }
        if Thread.isMainThread {
            callback(player, button)
        } else {
            DispatchQueue.main.async { callback(player, button) }
        }
    }

    // MARK: Math Helpers

    private func blend(previous: SIMD2<Float>, next: SIMD2<Float>, alpha: Float) -> SIMD2<Float> {
        let a = max(0, min(1, alpha))
        return a * next + (1 - a) * previous
    }

    private func applyDeadZone(_ v: SIMD2<Float>, limit: Float) -> SIMD2<Float> {
        let length = simd_length(v)
        guard length > 0 else { return .zero }
        if length <= limit { return .zero }
        let scale = min(1, (length - limit) / (1 - limit))
        let normalized = v / max(length, 0.0001)
        return normalized * max(0, scale)
    }

    private func currentTimestamp() -> TimeInterval {
        #if canImport(QuartzCore)
        return CACurrentMediaTime()
        #else
        return CFAbsoluteTimeGetCurrent()
        #endif
    }

    // MARK: Controller Source Protocol

    private protocol ControllerInputSource: AnyObject {
        var persistentIdentifier: String? { get }
        var fingerprint: String { get }
        var displayName: String { get }
        func prepare()
        func captureSnapshot() -> RawControllerSnapshot
        func setSnapshotHandler(_ handler: @escaping (RawControllerSnapshot) -> Void)
        func matches(controller: GCController) -> Bool
        func shutdown()
        func rumble(intensity: Float, duration: TimeInterval)
    }

    #if canImport(GameController)
    private final class PhysicalControllerSource: ControllerInputSource {
        private weak var controller: GCController?
        private var handler: ((RawControllerSnapshot) -> Void)?

        init(controller: GCController) {
            self.controller = controller
        }

        var persistentIdentifier: String? {
            nil // Framework does not provide reliable cross-run identifiers yet.
        }

        var fingerprint: String {
            let vendor = controller?.vendorName ?? "UnknownVendor"
            let product = controller?.productCategory ?? "UnknownProduct"
            return "\(vendor)|\(product)"
        }

        var displayName: String {
            controller?.vendorName ?? "Controller"
        }

        func prepare() {
            guard let controller else { return }
            controller.extendedGamepad?.valueChangedHandler = { [weak self] _, _ in
                self?.relaySnapshot(buttonOverride: nil)
            }
            if let micro = controller.microGamepad {
                micro.reportsAbsoluteDpadValues = true
                micro.allowsRotation = false
                micro.valueChangedHandler = { [weak self] _, _ in
                    self?.relaySnapshot(buttonOverride: nil)
                }
            }
//            controller.controllerPausedHandler = { [weak self] _ in
//                self?.relaySnapshot(buttonOverride: .pause)
//            }
        }

        func captureSnapshot() -> RawControllerSnapshot {
            collectSnapshot(buttonOverride: nil)
        }

        private func relaySnapshot(buttonOverride: GameButton?) {
            guard let handler else { return }
            let snapshot = collectSnapshot(buttonOverride: buttonOverride)
            if Thread.isMainThread {
                handler(snapshot)
            } else {
                DispatchQueue.main.async { handler(snapshot) }
            }
        }

        private func collectSnapshot(buttonOverride: GameButton?) -> RawControllerSnapshot {
            var move = SIMD2<Float>(repeating: 0)
            var aim = SIMD2<Float>(repeating: 0)
            var buttons: ButtonFlags = []
            var leftTrigger: Float = 0
            var rightTrigger: Float = 0

            if let ext = controller?.extendedGamepad {
                move = SIMD2(Float(ext.leftThumbstick.xAxis.value), Float(ext.leftThumbstick.yAxis.value))
                aim = SIMD2(Float(ext.rightThumbstick.xAxis.value), Float(ext.rightThumbstick.yAxis.value))
                let dpadVector = SIMD2(Float(ext.dpad.xAxis.value), Float(ext.dpad.yAxis.value))
                if simd_length(move) < 0.001 {
                    move = dpadVector
                }
                leftTrigger = Float(ext.leftTrigger.value)
                rightTrigger = Float(ext.rightTrigger.value)
                if ext.buttonA.isPressed { buttons.insert(.south) }
                if ext.buttonB.isPressed { buttons.insert(.east) }
                if ext.buttonX.isPressed { buttons.insert(.west) }
                if ext.buttonY.isPressed { buttons.insert(.north) }
                if ext.leftShoulder.isPressed { buttons.insert(.leftBumper) }
                if ext.rightShoulder.isPressed { buttons.insert(.rightBumper) }
                if #available(iOS 14.0, tvOS 14.0, macOS 11.0, *) {
                    if ext.buttonMenu.isPressed { buttons.insert(.menu) }
                    if let options = ext.buttonOptions, options.isPressed { buttons.insert(.select) }
                }
                if ext.leftThumbstickButton?.isPressed ?? false { buttons.insert(.leftStickPress) }
                if ext.rightThumbstickButton?.isPressed ?? false { buttons.insert(.rightStickPress) }
                if ext.dpad.up.isPressed { buttons.insert(.dpadUp) }
                if ext.dpad.down.isPressed { buttons.insert(.dpadDown) }
                if ext.dpad.left.isPressed { buttons.insert(.dpadLeft) }
                if ext.dpad.right.isPressed { buttons.insert(.dpadRight) }
            } else if let micro = controller?.microGamepad {
                let dpad = micro.dpad
                move = SIMD2(Float(dpad.xAxis.value), Float(dpad.yAxis.value))
                if dpad.up.isPressed { buttons.insert(.dpadUp) }
                if dpad.down.isPressed { buttons.insert(.dpadDown) }
                if dpad.left.isPressed { buttons.insert(.dpadLeft) }
                if dpad.right.isPressed { buttons.insert(.dpadRight) }
                if micro.buttonA.isPressed { buttons.insert(.south) }
                let x = micro.buttonX
                if x.isPressed { buttons.insert(.east) }
            }

            if let override = buttonOverride {
                buttons.insert(override)
            }

            let timestamp = CACurrentMediaTime()
            return RawControllerSnapshot(
                move: move,
                aim: aim,
                leftTrigger: leftTrigger,
                rightTrigger: rightTrigger,
                buttons: buttons,
                timestamp: timestamp
            )
        }

        func setSnapshotHandler(_ handler: @escaping (RawControllerSnapshot) -> Void) {
            self.handler = handler
        }

        func matches(controller: GCController) -> Bool {
            self.controller === controller
        }

        func shutdown() {
            controller?.extendedGamepad?.valueChangedHandler = nil
            controller?.microGamepad?.valueChangedHandler = nil
//            controller?.controllerPausedHandler = nil
        }

        func rumble(intensity: Float, duration: TimeInterval) {
            #if canImport(CoreHaptics)
            guard intensity > 0, duration > 0 else { return }
            if #available(iOS 16.0, tvOS 16.0, macOS 13.0, *),
               let haptics = controller?.haptics,
               let engine = haptics.createEngine(withLocality: .default) {
                do {
                    try engine.start()
                    let event = CHHapticEvent(
                        eventType: .hapticContinuous,
                        parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                        ],
                        relativeTime: 0,
                        duration: duration
                    )
                    let pattern = try CHHapticPattern(events: [event], parameters: [])
                    let player = try engine.makePlayer(with: pattern)
                    try player.start(atTime: 0)
                } catch {
                    // Ignore haptic failures; devices without support will throw here.
                }
            }
            #endif
        }
    }
    #endif

    final class SimulatedController: ControllerInputSource {
        var persistentIdentifier: String?
        var fingerprint: String
        var displayName: String
        private var handler: ((RawControllerSnapshot) -> Void)?
        private var snapshot: RawControllerSnapshot = .zero

        init(name: String, fingerprint: String = "Simulated") {
            self.displayName = name
            self.fingerprint = fingerprint
        }

        func prepare() {}

        func captureSnapshot() -> RawControllerSnapshot {
            snapshot
        }

        func setSnapshotHandler(_ handler: @escaping (RawControllerSnapshot) -> Void) {
            self.handler = handler
        }

        func matches(controller: GCController) -> Bool { false }

        func shutdown() {}

        func rumble(intensity: Float, duration: TimeInterval) {}

        func sendSnapshot(move: SIMD2<Float>, aim: SIMD2<Float>, buttons: ButtonFlags, leftTrigger: Float = 0, rightTrigger: Float = 0, timestamp: TimeInterval) {
            let snap = RawControllerSnapshot(move: move, aim: aim, leftTrigger: leftTrigger, rightTrigger: rightTrigger, buttons: buttons, timestamp: timestamp)
            snapshot = snap
            handler?(snap)
        }
    }

    // MARK: Testing Hooks

    @discardableResult
    func attachSimulatedController(_ simulated: SimulatedController) -> ControllerRef {
        let identifier = makeIdentifier(for: simulated)
        let ref = ControllerRef(id: identifier, name: simulated.displayName)
        let handle = ControllerHandle(ref: ref, source: simulated, fingerprint: simulated.fingerprint)
        register(handle: handle)
        return ref
    }

    func detachSimulatedController(id: String) {
        guard let handle = controllersByID[id], handle.source is SimulatedController else { return }
        let assignedPlayer = handle.assignment ?? controllerIDToPlayer[id]
        removeHandle(handle)
        let ref = handle.ref
        if Thread.isMainThread {
            onControllerDisconnected?(ref)
            if autoPauseOnDisconnect, let player = assignedPlayer {
                emitButtonDown(player: player, button: .pause)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onControllerDisconnected?(ref)
                if self?.autoPauseOnDisconnect == true, let player = assignedPlayer {
                    self?.emitButtonDown(player: player, button: .pause)
                }
            }
        }
    }
}
