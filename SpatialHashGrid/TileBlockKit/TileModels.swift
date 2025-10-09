// File: TileBlockKit/TileModels.swift
import Foundation
import SwiftUI
import Metal
import MetalKit
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public enum BlockShapeKind: UInt32, CaseIterable, Identifiable {
    case flat = 0, bevel = 1, inset = 2, pillow = 3, slopeTL = 4, slopeTR = 5, slopeBL = 6, slopeBR = 7
    public var id: UInt32 { rawValue }
    public var label: String {
        switch self {
        case .flat: return "Flat"
        case .bevel: return "Bevel"
        case .inset: return "Inset"
        case .pillow: return "Pillow"
        case .slopeTL: return "Slope TL"
        case .slopeTR: return "Slope TR"
        case .slopeBL: return "Slope BL"
        case .slopeBR: return "Slope BR"
        }
    }
}

public enum TileFilterMode: UInt32, CaseIterable, Identifiable {
    case linear = 0
    case nearest = 1
    public var id: UInt32 { rawValue }
    public var label: String {
        switch self {
        case .linear: return "Smooth"
        case .nearest: return "Nearest"
        }
    }
}

public enum TileLightingMode: UInt32, CaseIterable, Identifiable {
    case standard = 0
    case edgeHighlights = 1
    case glow = 2

    public var id: UInt32 { rawValue }
    public var label: String {
        switch self {
        case .standard: return "Standard"
        case .edgeHighlights: return "Edge Highlights"
        case .glow: return "Glow"
        }
    }
}

public struct TileEdgeMask: OptionSet, Hashable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let top    = TileEdgeMask(rawValue: 1 << 0)
    public static let right  = TileEdgeMask(rawValue: 1 << 1)
    public static let bottom = TileEdgeMask(rawValue: 1 << 2)
    public static let left   = TileEdgeMask(rawValue: 1 << 3)
    public static let all: TileEdgeMask = [.top, .right, .bottom, .left]
}

public struct TileBlockConfig: Equatable {
    public var tileSize: CGSize = .init(width: 32, height: 32)
    public var margin: CGSize = .zero
    public var spacing: CGSize = .zero
    public var displayScale: CGFloat = 4.0
    public var showGrid: Bool = true
    public var shape: BlockShapeKind = .bevel
    public var bevelWidth: Float = 0.12
    public var cornerRadius: Float = 0.08
    public var outlineWidth: Float = 0.04
    public var outlineIntensity: Float = 0.7
    public var shadowSize: Float = 0.15
    public var hazardStripes: Bool = false
    public var stripeAngle: Float = .pi / 4
    public var stripeWidth: Float = 0.12
    public var stripeColorA: SIMD4<Float> = .init(0.9, 0.1, 0.1, 0.75)
    public var stripeColorB: SIMD4<Float> = .init(1.0, 1.0, 1.0, 0.75)
    public var filterMode: TileFilterMode = .nearest
    public var lightingMode: TileLightingMode = .edgeHighlights
    public var highlightEdges: TileEdgeMask = [.top, .left]
    public var shadowEdges: TileEdgeMask = [.bottom, .right]
    public var highlightIntensity: Float = 0.35
    public var shadowIntensity: Float = 0.35
    public var edgeFalloff: Float = 0.18
    public var highlightColor: SIMD3<Float> = .init(1.0, 1.0, 1.0)
    public var shadowColor: SIMD3<Float> = .init(0.0, 0.0, 0.0)
    public var hueShiftDegrees: Float = 0.0
    public var saturation: Float = 1.0
    public var brightness: Float = 0.0
    public var contrast: Float = 1.0
    public init() {}
}

public struct Tile: Identifiable {
    public let id: Int
    public let column: Int
    public let row: Int
    public let uvRect: CGRect
}

final class TileAtlas {
    let id = UUID()
    let cgImage: CGImage
    let texture: MTLTexture
    let size: CGSize
    let columns: Int
    let rows: Int
    let tiles: [Tile]

    var tileCount: Int { tiles.count }

    init(cgImage: CGImage, texture: MTLTexture, config: TileBlockConfig) {
        self.cgImage = cgImage
        self.texture = texture
        self.size = CGSize(width: cgImage.width, height: cgImage.height)

        let tileW = max(1, Int(config.tileSize.width.rounded(.towardZero)))
        let tileH = max(1, Int(config.tileSize.height.rounded(.towardZero)))
        let marginX = Int(config.margin.width)
        let marginY = Int(config.margin.height)
        let spacingX = Int(config.spacing.width)
        let spacingY = Int(config.spacing.height)

        let usableW = max(0, cgImage.width - marginX * 2)
        let usableH = max(0, cgImage.height - marginY * 2)
        let computedColumns = tileW + spacingX > 0 ? (usableW + spacingX) / max(1, tileW + spacingX) : 0
        let computedRows = tileH + spacingY > 0 ? (usableH + spacingY) / max(1, tileH + spacingY) : 0
        var columns = max(0, computedColumns)
        var rows = max(0, computedRows)

        var tmp: [Tile] = []
        var idx = 0
        if columns > 0 && rows > 0 {
            for r in 0..<rows {
                for c in 0..<columns {
                    let x = marginX + c * (tileW + spacingX)
                    let y = marginY + r * (tileH + spacingY)
                    let uvx = CGFloat(x) / CGFloat(cgImage.width)
                    let uvy = CGFloat(y) / CGFloat(cgImage.height)
                    let widthPixels = max(0, min(tileW, cgImage.width - x))
                    let heightPixels = max(0, min(tileH, cgImage.height - y))
                    if widthPixels > 0 && heightPixels > 0 {
                        let uvw = CGFloat(widthPixels) / CGFloat(cgImage.width)
                        let uvh = CGFloat(heightPixels) / CGFloat(cgImage.height)
                        tmp.append(Tile(id: idx, column: c, row: r, uvRect: CGRect(x: uvx, y: uvy, width: uvw, height: uvh)))
                        idx += 1
                    }
                }
            }
            if tmp.isEmpty {
                columns = 1
                rows = 1
                tmp.append(Tile(id: 0, column: 0, row: 0, uvRect: CGRect(x: 0, y: 0, width: 1, height: 1)))
            }
        } else {
            columns = 1
            rows = 1
            tmp.append(Tile(id: 0, column: 0, row: 0, uvRect: CGRect(x: 0, y: 0, width: 1, height: 1)))
        }
        self.columns = columns
        self.rows = rows
        self.tiles = tmp
        TileBlockDiagnostics.shared.log("TileAtlas built: size=\(cgImage.width)x\(cgImage.height) columns=\(columns) rows=\(rows) tiles=\(tmp.count)")
        if TileBlockDiagnostics.shared.isEnabled,
           let firstTile = tmp.first {
            let sample = texture.samplePixel(at: firstTile, originalSize: cgImage.width, cgHeight: cgImage.height)
            TileBlockDiagnostics.shared.log("First tile sample rgba=\(sample.r),\(sample.g),\(sample.b),\(sample.a)")
        }
    }

    func sourceRect(for tile: Tile) -> CGRect {
        let width = size.width
        let height = size.height
        var pxWidth = tile.uvRect.size.width * width
        var pxHeight = tile.uvRect.size.height * height
        var pxX = tile.uvRect.origin.x * width
        let pxYTop = tile.uvRect.origin.y * height
        var pxY = height - pxYTop - pxHeight

        pxX = pxX.rounded(.towardZero)
        pxY = pxY.rounded(.towardZero)
        pxWidth = max(1, pxWidth.rounded(.up))
        pxHeight = max(1, pxHeight.rounded(.up))

        return CGRect(x: pxX, y: pxY, width: pxWidth, height: pxHeight)
    }

    func cgImage(for tile: Tile) -> CGImage? {
        let rect = sourceRect(for: tile).integral
        return cgImage.cropping(to: rect)
    }
}

extension MTLTexture {
    func toCGImage() -> CGImage? {
        let w = width, h = height
        let bytesPerPixel = 4
        let bytesPerRow = w * bytesPerPixel
        var data = [UInt8](repeating: 0, count: Int(bytesPerRow * h))
        let region = MTLRegionMake2D(0, 0, w, h)
        data.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            getBytes(baseAddress, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        return data.withUnsafeMutableBytes { ptr -> CGImage? in
            guard let baseAddress = ptr.baseAddress else { return nil }
            guard let ctx = CGContext(data: baseAddress,
                                      width: w,
                                      height: h,
                                      bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow,
                                      space: cs,
                                      bitmapInfo: bitmapInfo)
            else { return nil }
            return ctx.makeImage()
        }
    }
}

struct PixelSample { let r: Float; let g: Float; let b: Float; let a: Float }
extension MTLTexture {
    fileprivate func samplePixel(at tile: Tile, originalSize width: Int, cgHeight height: Int) -> PixelSample {
        let x = Int(tile.uvRect.origin.x * CGFloat(width))
        let y = Int(tile.uvRect.origin.y * CGFloat(height))
        var rgba = [UInt8](repeating: 0, count: 4)
        let region = MTLRegionMake2D(x, y, 1, 1)
        getBytes(&rgba, bytesPerRow: 4, from: region, mipmapLevel: 0)
        return PixelSample(
            r: Float(rgba[0]) / 255.0,
            g: Float(rgba[1]) / 255.0,
            b: Float(rgba[2]) / 255.0,
            a: Float(rgba[3]) / 255.0
        )
    }
}
