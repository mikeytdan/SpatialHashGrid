import SwiftUI
import QuartzCore
import MetalKit

#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Cross-platform palette helpers so UI code can share colors without sprinkling #if checks.
enum PlatformColors {
    /// Background color for secondary surfaces like panels or swatches.
    static var secondaryBackground: Color {
        #if canImport(UIKit)
        Color(.secondarySystemBackground)
        #elseif canImport(AppKit)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.gray.opacity(0.15)
        #endif
    }
}

/// Lightweight bridge around platform-specific image types that exposes a common CGImage.
struct PlatformImage {
    #if canImport(UIKit)
    typealias NativeImage = UIImage
    #elseif canImport(AppKit)
    typealias NativeImage = NSImage
    #endif

    let cgImage: CGImage

    init(cgImage: CGImage) {
        self.cgImage = cgImage
    }

    #if canImport(UIKit)
    init?(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return nil }
        self.init(cgImage: cgImage)
    }
    #elseif canImport(AppKit)
    init?(_ image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        self.init(cgImage: cgImage)
    }
    #endif

    init?(named name: String, in bundle: Bundle = .main) {
        #if canImport(UIKit)
        guard let image = UIImage(named: name, in: bundle, compatibleWith: nil) else { return nil }
        self.init(image)
        #elseif canImport(AppKit)
        guard let url = bundle.url(forResource: name, withExtension: nil), let image = NSImage(contentsOf: url) else { return nil }
        self.init(image)
        #else
        return nil
        #endif
    }
}

/// Schedules frame callbacks using the best-available display link for the active platform.
final class PlatformDisplayLink {
    private let preferredFramesPerSecond: Int
    private let handler: (CFTimeInterval) -> Void

    #if canImport(UIKit)
    private var link: CADisplayLink?
    private var proxy: DisplayLinkProxy?
    #elseif os(macOS)
    private var timer: DispatchSourceTimer?
    #endif

    init(preferredFramesPerSecond: Int = 60, handler: @escaping (CFTimeInterval) -> Void) {
        self.preferredFramesPerSecond = max(1, preferredFramesPerSecond)
        self.handler = handler
    }

    func start() {
        #if canImport(UIKit)
        guard link == nil else { return }
        let proxy = DisplayLinkProxy(handler: handler)
        let displayLink = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        displayLink.preferredFramesPerSecond = preferredFramesPerSecond
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
        self.proxy = proxy
        #elseif os(macOS)
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let nanoseconds = max(1, 1_000_000_000 / preferredFramesPerSecond)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(nanoseconds), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            handler(CACurrentMediaTime())
        }
        timer.resume()
        self.timer = timer
    #endif
    }

    func stop() {
        #if canImport(UIKit)
        link?.invalidate()
        link = nil
        proxy = nil
        #elseif os(macOS)
        if let timer {
            timer.setEventHandler {}
            timer.cancel()
            self.timer = nil
        }
        #endif
    }

    deinit {
        stop()
    }

    #if canImport(UIKit)
    private final class DisplayLinkProxy {
        let handler: (CFTimeInterval) -> Void

        init(handler: @escaping (CFTimeInterval) -> Void) {
            self.handler = handler
        }

        @objc func tick(_ link: CADisplayLink) {
            handler(link.timestamp)
        }
    }
    #endif

}

/// Helper utilities for aligning Metal view frame timing across platforms.
enum PlatformDisplayUtilities {
    static func configureFrameRate(for view: MTKView, preferredFramesPerSecond fps: Int) {
        #if canImport(UIKit)
        view.preferredFramesPerSecond = fps
        #elseif os(macOS)
        // macOS `MTKView` automatically synchronizes to the display refresh rate.
        _ = fps
        #endif
    }
}

extension View {
    func keyboardInput(
        focused: Binding<Bool>,
        onEvent: @escaping (KeyboardInputPhase, KeyboardInput) -> Bool
    ) -> some View {
        modifier(KeyboardInputModifier(focused: focused, onEvent: onEvent))
    }
}

private struct KeyboardInputModifier: ViewModifier {
    @Binding var focused: Bool
    let onEvent: (KeyboardInputPhase, KeyboardInput) -> Bool

    func body(content: Content) -> some View {
        #if os(macOS)
        content.background(
            KeyboardCaptureRepresentable(focused: $focused, onEvent: onEvent)
                .frame(width: 0, height: 0)
        )
        #elseif canImport(UIKit)
        content.background(
            KeyboardCaptureRepresentable(focused: $focused, onEvent: onEvent)
                .frame(width: 0, height: 0)
        )
        #else
        content
        #endif
    }
}

#if os(macOS)
private struct KeyboardCaptureRepresentable: NSViewRepresentable {
    @Binding var focused: Bool
    let onEvent: (KeyboardInputPhase, KeyboardInput) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(focused: $focused, onEvent: onEvent)
    }

    func makeNSView(context: Context) -> KeyboardCaptureView {
        let view = KeyboardCaptureView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onKeyEvent = context.coordinator.handle
        view.onFocusChange = context.coordinator.focusChanged
        return view
    }

    func updateNSView(_ nsView: KeyboardCaptureView, context: Context) {
        context.coordinator.onEvent = onEvent
        nsView.onKeyEvent = context.coordinator.handle
        nsView.onFocusChange = context.coordinator.focusChanged

        if focused {
            DispatchQueue.main.async {
                nsView.ensureFocus()
            }
        } else if nsView.window?.firstResponder === nsView {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nil)
            }
        }
    }

    final class Coordinator {
        var focused: Binding<Bool>
        var onEvent: (KeyboardInputPhase, KeyboardInput) -> Bool

        init(
            focused: Binding<Bool>,
            onEvent: @escaping (KeyboardInputPhase, KeyboardInput) -> Bool
        ) {
            self.focused = focused
            self.onEvent = onEvent
        }

        func handle(phase: KeyboardInputPhase, event: KeyboardInput) -> Bool {
            onEvent(phase, event)
        }

        func focusChanged(_ isFocused: Bool) {
            if focused.wrappedValue != isFocused {
                focused.wrappedValue = isFocused
            }
        }
    }
}

private final class KeyboardCaptureView: NSView {
    var onKeyEvent: ((KeyboardInputPhase, KeyboardInput) -> Bool)?
    var onFocusChange: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override var focusRingType: NSFocusRingType {
        get { .none }
        set { }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func becomeFirstResponder() -> Bool {
        onFocusChange?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        onFocusChange?(false)
        return true
    }

    func ensureFocus() {
        guard window?.firstResponder !== self else { return }
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard let handler = onKeyEvent else {
            super.keyDown(with: event)
            return
        }

        if !handler(.down, KeyboardInput(event: event)) {
            if let next = nextResponder {
                next.keyDown(with: event)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        guard let handler = onKeyEvent else {
            super.keyUp(with: event)
            return
        }

        if !handler(.up, KeyboardInput(event: event)) {
            if let next = nextResponder {
                next.keyUp(with: event)
            } else {
                super.keyUp(with: event)
            }
        }
    }
}
#endif

#if canImport(UIKit) && !os(macOS)
// UIView wrapper that captures hardware keyboard events on iPadOS and keeps
// SwiftUI focus state in sync with the engine input bridge.
private struct KeyboardCaptureRepresentable: UIViewRepresentable {
    @Binding var focused: Bool
    let onEvent: (KeyboardInputPhase, KeyboardInput) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(focused: $focused, onEvent: onEvent)
    }

    func makeUIView(context: Context) -> KeyboardCaptureView {
        let view = KeyboardCaptureView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.onKeyEvent = context.coordinator.handle
        view.onFocusChange = context.coordinator.focusChanged
        return view
    }

    func updateUIView(_ uiView: KeyboardCaptureView, context: Context) {
        context.coordinator.onEvent = onEvent
        uiView.onKeyEvent = context.coordinator.handle
        uiView.onFocusChange = context.coordinator.focusChanged

        if focused {
            DispatchQueue.main.async {
                uiView.ensureFocus()
            }
        } else if uiView.isFirstResponder {
            DispatchQueue.main.async {
                _ = uiView.resignFirstResponder()
            }
        }
    }

    final class Coordinator {
        var focused: Binding<Bool>
        var onEvent: (KeyboardInputPhase, KeyboardInput) -> Bool

        init(
            focused: Binding<Bool>,
            onEvent: @escaping (KeyboardInputPhase, KeyboardInput) -> Bool
        ) {
            self.focused = focused
            self.onEvent = onEvent
        }

        func handle(phase: KeyboardInputPhase, event: KeyboardInput) -> Bool {
            onEvent(phase, event)
        }

        func focusChanged(_ isFocused: Bool) {
            if focused.wrappedValue != isFocused {
                focused.wrappedValue = isFocused
            }
        }
    }
}

private final class KeyboardCaptureView: UIView {
    var onKeyEvent: ((KeyboardInputPhase, KeyboardInput) -> Bool)?
    var onFocusChange: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            onFocusChange?(false)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            onFocusChange?(true)
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            onFocusChange?(false)
        }
        return resigned
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        false
    }

    func ensureFocus() {
        guard window != nil else { return }
        if !isFirstResponder {
            _ = becomeFirstResponder()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let handler = onKeyEvent else {
            super.pressesBegan(presses, with: event)
            return
        }

        var handled = false
        for press in presses {
            guard press.key != nil else { continue }
            let input = KeyboardInput(press)
            if handler(.down, input) { handled = true }
        }

        if !handled {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let handler = onKeyEvent else {
            super.pressesEnded(presses, with: event)
            return
        }

        var handled = false
        for press in presses {
            guard press.key != nil else { continue }
            let input = KeyboardInput(press)
            if handler(.up, input) { handled = true }
        }

        if !handled {
            super.pressesEnded(presses, with: event)
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let handler = onKeyEvent else {
            super.pressesCancelled(presses, with: event)
            return
        }

        for press in presses {
            guard press.key != nil else { continue }
            _ = handler(.up, KeyboardInput(press))
        }
        super.pressesCancelled(presses, with: event)
    }
}
#endif
