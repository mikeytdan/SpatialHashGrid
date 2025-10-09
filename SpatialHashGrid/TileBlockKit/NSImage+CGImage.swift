// File: TileBlockKit/NSImage+CGImage.swift
import Foundation
#if os(macOS)
import AppKit
extension NSImage {
    var cgImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
#endif
