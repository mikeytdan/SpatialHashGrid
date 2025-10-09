//
//  MapCanvasView.swift
//  SpatialHashGrid
//
//  Created by Michael Daniels on 10/3/25.
//

import SwiftUI

struct MapCanvasView: View {
    let blueprint: LevelBlueprint
    let previewTiles: Set<GridPoint>
    let showGrid: Bool
    let zoom: Double
    let selectedSpawnID: PlayerSpawnPoint.ID?
    let selectedPlatformID: MovingPlatformBlueprint.ID?
    let selectedSentryID: SentryBlueprint.ID?
    let selectedEnemyID: EnemyBlueprint.ID?
    let previewColor: Color
    let hoveredPoint: GridPoint?
    let selectionState: MapEditorSelectionRenderState?
    let onHover: (GridPoint?) -> Void
    let onDragBegan: (GridPoint) -> Void
    let onDragChanged: (GridPoint) -> Void
    let onDragEnded: (GridPoint?) -> Void
    let onFocusRequested: () -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let tileSize = tilePixelSize(in: geo.size)
            let mapSize = CGSize(width: tileSize * CGFloat(blueprint.columns), height: tileSize * CGFloat(blueprint.rows))
            let origin = CGPoint(x: (geo.size.width - mapSize.width) * 0.5, y: (geo.size.height - mapSize.height) * 0.5)

            Canvas { context, _ in
                let rect = CGRect(origin: origin, size: mapSize)
                context.fill(Path(rect), with: .color(PlatformColors.secondaryBackground))
                context.stroke(Path(rect), with: .color(Color.black.opacity(0.1)), lineWidth: 1)

                let selection = selectionState
                let suppressOriginalSelection: Bool
                if let selection {
                    suppressOriginalSelection = selection.source == .existing && (selection.offset.row != 0 || selection.offset.column != 0)
                } else {
                    suppressOriginalSelection = false
                }

                let selectedTiles = selection?.tiles ?? [:]
                let selectedTilePoints = Set(selectedTiles.keys)
                let selectedSpawnIDs = Set(selection?.spawns.map(\.id) ?? [])
                let selectedPlatformIDs = Set(selection?.platforms.map(\.id) ?? [])
                let selectedSentryIDs = Set(selection?.sentries.map(\.id) ?? [])
                let selectedEnemyIDs = Set(selection?.enemies.map(\.id) ?? [])

                let spawnIndexMap = Dictionary(uniqueKeysWithValues: blueprint.spawnPoints.enumerated().map { ($1.id, $0) })
                let platformIndexMap = Dictionary(uniqueKeysWithValues: blueprint.movingPlatforms.enumerated().map { ($1.id, $0) })
                let sentryIndexMap = Dictionary(uniqueKeysWithValues: blueprint.sentries.enumerated().map { ($1.id, $0) })
                let enemyIndexMap = Dictionary(uniqueKeysWithValues: blueprint.enemies.enumerated().map { ($1.id, $0) })

                for (point, kind) in blueprint.tileEntries() where kind.isSolid {
                    if suppressOriginalSelection && selectedTilePoints.contains(point) { continue }
                    let tileRect = CGRect(
                        x: origin.x + CGFloat(point.column) * tileSize,
                        y: origin.y + CGFloat(point.row) * tileSize,
                        width: tileSize,
                        height: tileSize
                    )

                    let path: Path
                    if let rampKind = kind.rampKind {
                        var rampPath = Path()
                        let minX = tileRect.minX
                        let maxX = tileRect.maxX
                        let minY = tileRect.minY
                        let maxY = tileRect.maxY
                        switch rampKind {
                        case .upRight:
                            rampPath.move(to: CGPoint(x: minX, y: maxY))
                            rampPath.addLine(to: CGPoint(x: maxX, y: maxY))
                            rampPath.addLine(to: CGPoint(x: maxX, y: minY))
                        case .upLeft:
                            rampPath.move(to: CGPoint(x: minX, y: minY))
                            rampPath.addLine(to: CGPoint(x: minX, y: maxY))
                            rampPath.addLine(to: CGPoint(x: maxX, y: maxY))
                        }
                        rampPath.closeSubpath()
                        path = rampPath
                    } else {
                        path = Path(tileRect)
                    }

                    context.fill(path, with: .color(kind.fillColor))
                    context.stroke(path, with: .color(kind.borderColor), lineWidth: 1)
                }

                for (index, platform) in blueprint.movingPlatforms.enumerated() {
                    if suppressOriginalSelection && selectedPlatformIDs.contains(platform.id) { continue }
                    let color = PlatformPalette.color(for: index)
                    let originRect = rectForPlatform(origin: platform.origin, size: platform.size, originPoint: origin, tileSize: tileSize)
                    context.fill(Path(originRect), with: .color(color.opacity(0.6)))
                    if platform.id == selectedPlatformID {
                        context.stroke(Path(originRect), with: .color(.white), lineWidth: 2)
                    }

                    let targetRect = rectForPlatform(origin: platform.target, size: platform.size, originPoint: origin, tileSize: tileSize)
                    if platform.target != platform.origin {
                        var path = Path()
                        path.move(to: originRect.center)
                        path.addLine(to: targetRect.center)
                        context.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 2)
                    }
                    context.stroke(Path(targetRect), with: .color(color.opacity(platform.id == selectedPlatformID ? 0.9 : 0.5)), lineWidth: platform.id == selectedPlatformID ? 2 : 1)
                }

                for (index, spawn) in blueprint.spawnPoints.enumerated() {
                    if suppressOriginalSelection && selectedSpawnIDs.contains(spawn.id) { continue }
                    let tileRect = CGRect(
                        x: origin.x + CGFloat(spawn.coordinate.column) * tileSize,
                        y: origin.y + CGFloat(spawn.coordinate.row) * tileSize,
                        width: tileSize,
                        height: tileSize
                    )
                    let path = Path(ellipseIn: tileRect.insetBy(dx: tileSize * 0.25, dy: tileSize * 0.25))
                    let fill = SpawnPalette.color(for: index)
                    context.fill(path, with: .color(fill.opacity(0.85)))
                    if spawn.id == selectedSpawnID {
                        context.stroke(path, with: .color(Color.white), lineWidth: 2)
                    }
                }

                for (index, enemy) in blueprint.enemies.enumerated() {
                    if suppressOriginalSelection && selectedEnemyIDs.contains(enemy.id) { continue }
                    drawEnemy(enemy, index: index, origin: origin, tileSize: tileSize, context: &context)
                }

                for (index, sentry) in blueprint.sentries.enumerated() {
                    if suppressOriginalSelection && selectedSentryIDs.contains(sentry.id) { continue }
                    drawSentry(
                        sentry,
                        index: index,
                        origin: origin,
                        tileSize: tileSize,
                        context: &context
                    )
                }

                if !previewTiles.isEmpty {
                    for point in previewTiles where blueprint.contains(point) {
                        let tileRect = CGRect(
                            x: origin.x + CGFloat(point.column) * tileSize,
                            y: origin.y + CGFloat(point.row) * tileSize,
                            width: tileSize,
                            height: tileSize
                        )
                        context.fill(Path(tileRect), with: .color(previewColor.opacity(0.35)))
                    }
                }

                if let selection {
                    drawSelectionOverlay(
                        selection: selection,
                        origin: origin,
                        tileSize: tileSize,
                        spawnIndexMap: spawnIndexMap,
                        platformIndexMap: platformIndexMap,
                        sentryIndexMap: sentryIndexMap,
                        enemyIndexMap: enemyIndexMap,
                        context: &context
                    )
                }

                if showGrid {
                    drawGrid(context: &context, origin: origin, tileSize: tileSize, mapSize: mapSize)
                }

                if let hovered = hoveredPoint, blueprint.contains(hovered) {
                    let highlight = CGRect(
                        x: origin.x + CGFloat(hovered.column) * tileSize,
                        y: origin.y + CGFloat(hovered.row) * tileSize,
                        width: tileSize,
                        height: tileSize
                    )
                    context.stroke(Path(highlight), with: .color(Color.yellow), lineWidth: 2)
                }
            }
            .contentShape(Rectangle())
            .highPriorityGesture(dragGesture(origin: origin, tileSize: tileSize, mapSize: mapSize))
            .onHover { hovering in
#if os(macOS)
                if !hovering {
                    onHover(nil)
                }
#endif
            }
        }
    }

    private func tilePixelSize(in size: CGSize) -> CGFloat {
        _ = size
        return max(4.0, CGFloat(blueprint.tileSize) * CGFloat(zoom))
    }

    private func dragGesture(origin: CGPoint, tileSize: CGFloat, mapSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onFocusRequested()
                let location = CGPoint(x: value.location.x - origin.x, y: value.location.y - origin.y)
                guard let point = pointForLocation(location, tileSize: tileSize, mapSize: mapSize) else {
                    onHover(nil)
                    return
                }
                onHover(point)
                if !isDragging {
                    isDragging = true
                    onDragBegan(point)
                } else {
                    onDragChanged(point)
                }
            }
            .onEnded { value in
                onFocusRequested()
                let location = CGPoint(x: value.location.x - origin.x, y: value.location.y - origin.y)
                let point = pointForLocation(location, tileSize: tileSize, mapSize: mapSize)
                if !isDragging, let point {
                    onDragBegan(point)
                }
                isDragging = false
                onDragEnded(point)
                onHover(nil)
            }
    }

    private func pointForLocation(_ location: CGPoint, tileSize: CGFloat, mapSize: CGSize) -> GridPoint? {
        guard location.x >= 0, location.y >= 0, location.x < mapSize.width, location.y < mapSize.height else {
            return nil
        }
        let column = Int(location.x / tileSize)
        let row = Int(location.y / tileSize)
        return GridPoint(row: row, column: column)
    }

    private func rectForPlatform(origin platformOrigin: GridPoint, size: GridSize, originPoint: CGPoint, tileSize: CGFloat) -> CGRect {
        let x = originPoint.x + CGFloat(platformOrigin.column) * tileSize
        let y = originPoint.y + CGFloat(platformOrigin.row) * tileSize
        let width = CGFloat(size.columns) * tileSize
        let height = CGFloat(size.rows) * tileSize
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func drawGrid(context: inout GraphicsContext, origin: CGPoint, tileSize: CGFloat, mapSize: CGSize) {
        let gridColor = Color.white.opacity(0.15)
        var path = Path()
        for column in 0...blueprint.columns {
            let x = origin.x + CGFloat(column) * tileSize
            path.move(to: CGPoint(x: x, y: origin.y))
            path.addLine(to: CGPoint(x: x, y: origin.y + mapSize.height))
        }
        for row in 0...blueprint.rows {
            let y = origin.y + CGFloat(row) * tileSize
            path.move(to: CGPoint(x: origin.x, y: y))
            path.addLine(to: CGPoint(x: origin.x + mapSize.width, y: y))
        }
        context.stroke(path, with: .color(gridColor), lineWidth: 1)
    }

    private func drawSelectionOverlay(
        selection: MapEditorSelectionRenderState,
        origin: CGPoint,
        tileSize: CGFloat,
        spawnIndexMap: [PlayerSpawnPoint.ID: Int],
        platformIndexMap: [MovingPlatformBlueprint.ID: Int],
        sentryIndexMap: [SentryBlueprint.ID: Int],
        enemyIndexMap: [EnemyBlueprint.ID: Int],
        context: inout GraphicsContext
    ) {
        let offset = selection.offset
        let hasOffset = offset.row != 0 || offset.column != 0
        let accent = Color.accentColor.opacity(0.9)

        if !selection.tiles.isEmpty {
            let fillOpacity = hasOffset ? 0.6 : 0.28
            for (point, kind) in selection.tiles {
                let destination = GridPoint(row: point.row + offset.row, column: point.column + offset.column)
                guard blueprint.contains(destination) else { continue }
                let tileRect = CGRect(
                    x: origin.x + CGFloat(destination.column) * tileSize,
                    y: origin.y + CGFloat(destination.row) * tileSize,
                    width: tileSize,
                    height: tileSize
                )
                let path = Path(tileRect)
                context.fill(path, with: .color(kind.fillColor.opacity(fillOpacity)))
                context.stroke(path, with: .color(accent), lineWidth: 1.5)
            }
        }

        for spawn in selection.spawns {
            let destination = spawn.coordinate.offsetting(rowDelta: offset.row, columnDelta: offset.column)
            guard blueprint.contains(destination) else { continue }
            let index = spawnIndexMap[spawn.id] ?? 0
            let tileRect = CGRect(
                x: origin.x + CGFloat(destination.column) * tileSize,
                y: origin.y + CGFloat(destination.row) * tileSize,
                width: tileSize,
                height: tileSize
            )
            let inset = tileRect.insetBy(dx: tileSize * 0.25, dy: tileSize * 0.25)
            let path = Path(ellipseIn: inset)
            let fill = SpawnPalette.color(for: index).opacity(hasOffset ? 0.7 : 0.35)
            context.fill(path, with: .color(fill))
            context.stroke(path, with: .color(accent), lineWidth: 2)
        }

        for platform in selection.platforms {
            guard let index = platformIndexMap[platform.id] else { continue }
            let originPoint = platform.origin.offsetting(rowDelta: offset.row, columnDelta: offset.column)
            let targetPoint = platform.target.offsetting(rowDelta: offset.row, columnDelta: offset.column)
            let originMax = GridPoint(row: originPoint.row + platform.size.rows - 1, column: originPoint.column + platform.size.columns - 1)
            let targetMax = GridPoint(row: targetPoint.row + platform.size.rows - 1, column: targetPoint.column + platform.size.columns - 1)
            guard blueprint.contains(originPoint), blueprint.contains(originMax), blueprint.contains(targetPoint), blueprint.contains(targetMax) else { continue }

            let color = PlatformPalette.color(for: index)
            let originRect = rectForPlatform(origin: originPoint, size: platform.size, originPoint: origin, tileSize: tileSize)
            context.fill(Path(originRect), with: .color(color.opacity(hasOffset ? 0.55 : 0.28)))
            context.stroke(Path(originRect), with: .color(accent), lineWidth: 2)

            let targetRect = rectForPlatform(origin: targetPoint, size: platform.size, originPoint: origin, tileSize: tileSize)
            if targetPoint != originPoint {
                var path = Path()
                path.move(to: originRect.center)
                path.addLine(to: targetRect.center)
                context.stroke(path, with: .color(accent.opacity(0.7)), lineWidth: 2)
            }
            context.stroke(Path(targetRect), with: .color(accent.opacity(0.8)), lineWidth: 1.5)
        }

        for sentry in selection.sentries {
            let destination = sentry.coordinate.offsetting(rowDelta: offset.row, columnDelta: offset.column)
            guard blueprint.contains(destination) else { continue }
            let index = sentryIndexMap[sentry.id] ?? 0
            let center = CGPoint(
                x: origin.x + (CGFloat(destination.column) + 0.5) * tileSize,
                y: origin.y + (CGFloat(destination.row) + 0.5) * tileSize
            )
            let baseRadius = tileSize * 0.35
            let circle = CGRect(x: center.x - baseRadius, y: center.y - baseRadius, width: baseRadius * 2, height: baseRadius * 2)
            let path = Path(ellipseIn: circle)
            context.fill(path, with: .color(SentryPalette.color(for: index).opacity(hasOffset ? 0.65 : 0.32)))
            context.stroke(path, with: .color(accent), lineWidth: 2)
        }

        for enemy in selection.enemies {
            let destination = enemy.coordinate.offsetting(rowDelta: offset.row, columnDelta: offset.column)
            guard blueprint.contains(destination) else { continue }
            let index = enemyIndexMap[enemy.id] ?? 0
            let color = EnemyPalette.color(for: index)
            let tileSizeValue = max(Double(tileSize), 1.0)
            let widthScale = min(max(enemy.size.x / tileSizeValue, 0.4), 1.8)
            let heightScale = min(max(enemy.size.y / tileSizeValue, 0.6), 2.1)
            let drawWidth = tileSize * CGFloat(widthScale)
            let drawHeight = tileSize * CGFloat(heightScale)
            let center = CGPoint(
                x: origin.x + (CGFloat(destination.column) + 0.5) * tileSize,
                y: origin.y + (CGFloat(destination.row) + 0.5) * tileSize
            )
            let rect = CGRect(
                x: center.x - drawWidth * 0.5,
                y: center.y - drawHeight * 0.5,
                width: drawWidth,
                height: drawHeight
            )
            let path = Path(roundedRect: rect, cornerRadius: min(drawWidth, drawHeight) * 0.2)
            context.fill(path, with: .color(color.opacity(hasOffset ? 0.66 : 0.34)))
            context.stroke(path, with: .color(accent), lineWidth: 2)
        }

        let adjustedBounds = selection.bounds.offsetting(by: selection.offset)
        if adjustedBounds.isValid {
            let selectionRect = CGRect(
                x: origin.x + CGFloat(adjustedBounds.minColumn) * tileSize,
                y: origin.y + CGFloat(adjustedBounds.minRow) * tileSize,
                width: CGFloat(adjustedBounds.width) * tileSize,
                height: CGFloat(adjustedBounds.height) * tileSize
            )
            let outline = Path(selectionRect)
            let dashLength = max(2.0, tileSize * 0.35)
            context.stroke(
                outline,
                with: .color(accent),
                style: StrokeStyle(lineWidth: 2, dash: [dashLength, dashLength])
            )
        }
    }

    private func drawSentry(
        _ sentry: SentryBlueprint,
        index: Int,
        origin: CGPoint,
        tileSize: CGFloat,
        context: inout GraphicsContext
    ) {
        let color = SentryPalette.color(for: index)
        let center = CGPoint(
            x: origin.x + (CGFloat(sentry.coordinate.column) + 0.5) * tileSize,
            y: origin.y + (CGFloat(sentry.coordinate.row) + 0.5) * tileSize
        )
        let baseRadius = tileSize * 0.35
        let circle = Path(ellipseIn: CGRect(x: center.x - baseRadius, y: center.y - baseRadius, width: baseRadius * 2, height: baseRadius * 2))
        context.fill(circle, with: .color(color.opacity(0.85)))

        if sentry.id == selectedSentryID {
            context.stroke(circle, with: .color(.white), lineWidth: 2)
        }

        let rangePixels = CGFloat(sentry.scanRange) * tileSize
        if rangePixels > 4 {
            let centerAngle = sentry.scanCenterDegrees * .pi / 180.0
            let halfArc = max(5.0, sentry.scanArcDegrees * 0.5) * .pi / 180.0
            let startAngle = centerAngle - halfArc
            let endAngle = centerAngle + halfArc
            var wedge = Path()
            wedge.move(to: center)
            let segments = max(12, Int(sentry.scanArcDegrees / 10.0))
            for i in 0...segments {
                let t = Double(i) / Double(segments)
                let angle = startAngle + (endAngle - startAngle) * t
                let point = CGPoint(
                    x: center.x + CGFloat(cos(angle)) * rangePixels,
                    y: center.y + CGFloat(sin(angle)) * rangePixels
                )
                wedge.addLine(to: point)
            }
            wedge.closeSubpath()
            context.fill(wedge, with: .color(color.opacity(0.15)))

            var line = Path()
            let tip = CGPoint(
                x: center.x + CGFloat(cos(centerAngle)) * rangePixels,
                y: center.y + CGFloat(sin(centerAngle)) * rangePixels
            )
            line.move(to: center)
            line.addLine(to: tip)
            context.stroke(line, with: .color(color.opacity(0.5)), lineWidth: 2)
        }
    }

    private func drawEnemy(
        _ enemy: EnemyBlueprint,
        index: Int,
        origin: CGPoint,
        tileSize: CGFloat,
        context: inout GraphicsContext
    ) {
        let color = EnemyPalette.color(for: index)
        let center = CGPoint(
            x: origin.x + (CGFloat(enemy.coordinate.column) + 0.5) * tileSize,
            y: origin.y + (CGFloat(enemy.coordinate.row) + 0.5) * tileSize
        )
        let tileSizeValue = max(Double(tileSize), 1.0)
        let widthScale = min(max(enemy.size.x / tileSizeValue, 0.4), 1.8)
        let heightScale = min(max(enemy.size.y / tileSizeValue, 0.6), 2.1)
        let drawWidth = tileSize * CGFloat(widthScale)
        let drawHeight = tileSize * CGFloat(heightScale)
        let rect = CGRect(
            x: center.x - drawWidth * 0.5,
            y: center.y - drawHeight * 0.5,
            width: drawWidth,
            height: drawHeight
        )
        let path = Path(roundedRect: rect, cornerRadius: min(drawWidth, drawHeight) * 0.2)
        context.fill(path, with: .color(color.opacity(0.85)))
        if enemy.id == selectedEnemyID {
            context.stroke(path, with: .color(.white), lineWidth: 2)
        } else {
            context.stroke(path, with: .color(color.opacity(0.6)), lineWidth: 1)
        }

        let attackLabel: String
        switch enemy.attack {
        case .none: attackLabel = enemy.behaviorLabelPrefix
        case .shooter: attackLabel = "R"
        case .sword: attackLabel = "S"
        case .punch: attackLabel = "P"
        }

        context.draw(
            Text(attackLabel)
                .font(.system(size: max(10, tileSize * 0.4), weight: .bold, design: .rounded))
                .foregroundStyle(.white),
            at: center,
            anchor: .center
        )

        if case .wallBounce(let axis, _) = enemy.movement {
            var indicator = Path()
            switch axis {
            case .horizontal:
                indicator.move(to: CGPoint(x: rect.minX, y: center.y))
                indicator.addLine(to: CGPoint(x: rect.maxX, y: center.y))
            case .vertical:
                indicator.move(to: CGPoint(x: center.x, y: rect.minY))
                indicator.addLine(to: CGPoint(x: center.x, y: rect.maxY))
            }
            context.stroke(indicator, with: .color(Color.white.opacity(0.7)), lineWidth: 1.5)
        }
    }
}
