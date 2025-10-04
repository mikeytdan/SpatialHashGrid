// SpawnPalette.swift
// Shared color palette for player spawn markers across editor and previews

import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

enum SpawnPalette {
    private static let colors: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink
    ]

    static func color(for index: Int) -> Color {
        guard !colors.isEmpty else { return .accentColor }
        return colors[index % colors.count]
    }

    #if canImport(UIKit)
    static func uiColor(for index: Int) -> UIColor {
        UIColor(color(for: index))
    }
    #endif

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    static func nsColor(for index: Int) -> NSColor {
        NSColor(color(for: index))
    }
    #endif
}

enum PlatformPalette {
    private static let colors: [Color] = [
        .purple, .pink, .indigo, .blue, .teal, .mint, .green, .orange
    ]

    static func color(for index: Int) -> Color {
        guard !colors.isEmpty else { return .accentColor }
        return colors[index % colors.count]
    }

    #if canImport(UIKit)
    static func uiColor(for index: Int) -> UIColor {
        UIColor(color(for: index))
    }
    #endif

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    static func nsColor(for index: Int) -> NSColor {
        NSColor(color(for: index))
    }
    #endif
}

enum SentryPalette {
    private static let colors: [Color] = [
        .red, .orange, .yellow, .green, .teal, .cyan, .blue, .purple
    ]

    static func color(for index: Int) -> Color {
        guard !colors.isEmpty else { return .accentColor }
        return colors[index % colors.count]
    }

    #if canImport(UIKit)
    static func uiColor(for index: Int) -> UIColor {
        UIColor(color(for: index))
    }
    #endif

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    static func nsColor(for index: Int) -> NSColor {
        NSColor(color(for: index))
    }
    #endif
}

enum EnemyPalette {
    private static let colors: [Color] = [
        .green, .teal, .blue, .indigo, .purple, .pink, .orange, .yellow
    ]

    static func color(for index: Int) -> Color {
        guard !colors.isEmpty else { return .accentColor }
        return colors[index % colors.count]
    }

    #if canImport(UIKit)
    static func uiColor(for index: Int) -> UIColor {
        UIColor(color(for: index))
    }
    #endif

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    static func nsColor(for index: Int) -> NSColor {
        NSColor(color(for: index))
    }
    #endif
}
