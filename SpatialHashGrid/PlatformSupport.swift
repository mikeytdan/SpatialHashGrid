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
