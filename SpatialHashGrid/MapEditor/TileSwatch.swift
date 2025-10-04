//
//  TileSwatch.swift
//  SpatialHashGrid
//
//  Created by Michael Daniels on 10/3/25.
//

import SwiftUI

struct TileSwatch: View {
    let tile: LevelTileKind
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(PlatformColors.secondaryBackground)

            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 6, dy: 6)

                if let ramp = tile.rampKind {
                    var path = Path()
                    switch ramp {
                    case .upRight:
                        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                    case .upLeft:
                        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
                    }
                    path.closeSubpath()
                    context.fill(path, with: .color(tile.fillColor))
                    context.stroke(path, with: .color(tile.borderColor), lineWidth: 2)
                } else {
                    let shape = Path(roundedRect: rect, cornerRadius: 6)
                    context.fill(shape, with: .color(tile.fillColor))
                    context.stroke(shape, with: .color(tile.borderColor), lineWidth: 2)
                }
            }
            .allowsHitTesting(false)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .frame(width: 48, height: 48)
    }
}
