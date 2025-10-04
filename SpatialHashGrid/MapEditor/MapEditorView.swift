import SwiftUI

struct MapEditorView: View {
    private typealias EnemyMovementChoice = MapEditorViewModel.EnemyMovementChoice
    private typealias EnemyBehaviorChoice = MapEditorViewModel.EnemyBehaviorChoice
    private typealias EnemyAttackChoice = MapEditorViewModel.EnemyAttackChoice

    @StateObject private var viewModel = MapEditorViewModel()
    @State private var isPreviewing = false
    @State private var spawnNameDraft: String = ""
    @State private var input = InputController()
    @FocusState private var focused: Bool

    private let adapter = MetalLevelPreviewAdapter()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if isPreviewing {
                adapter.makePreview(for: viewModel.blueprint, input: input) {
                    isPreviewing = false
                    focusEditor()
                }
                .ignoresSafeArea()
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView(.vertical, showsIndicators: true) {
                        controls
                            .padding(.vertical, 16)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .frame(minWidth: 300, maxHeight: .infinity)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    
                    mapStage
                        .frame(minWidth: 520, minHeight: 520)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(PlatformColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                
                floatingControls
                    .padding(20)
            }
        }
//        .sheet(isPresented: $isPreviewing) {
//            adapter.makePreview(for: viewModel.blueprint, input: input) {
//                isPreviewing = false
//                focusEditor()
//            }
//            .ignoresSafeArea()
//        }
        .onChange(of: viewModel.selectedSpawnID) {
            spawnNameDraft = viewModel.selectedSpawn?.name ?? ""
        }
        .onChange(of: viewModel.blueprint.spawnPoints) {
            spawnNameDraft = viewModel.selectedSpawn?.name ?? ""
        }
        .focusable()
        .focused($focused)
        .onAppear {
            focusEditor()
        }
        .onChange(of: isPreviewing) { _, previewing in
            DispatchQueue.main.async {
                if previewing {
                    input.reset()
                } else {
                    focusEditor()
                }
            }
        }
        .onKeyPress(phases: [.down, .up]) { kp in
            switch kp.phase {
            case .down:
                input.handleKeyDown(kp)
                if handleEditorCommand(for: kp) { return .handled }
                if !isPreviewing { input.drainPressedCommands() }
                return isHandledKey(kp) ? .handled : .ignored
            case .up:
                input.handleKeyUp(kp)
                if !isPreviewing { input.drainPressedCommands() }
                return isHandledKey(kp) ? .handled : .ignored
            default:
                return .ignored
            }
        }
    }

    private var mapStage: some View {
        MapCanvasView(
            blueprint: viewModel.blueprint,
            previewTiles: viewModel.shapePreview,
            showGrid: viewModel.showGrid,
            zoom: viewModel.zoom,
            selectedSpawnID: viewModel.selectedSpawnID,
            selectedPlatformID: viewModel.selectedPlatformID,
            selectedSentryID: viewModel.selectedSentryID,
            selectedEnemyID: viewModel.selectedEnemyID,
            previewColor: viewModel.paintTileKind.fillColor,
            hoveredPoint: viewModel.hoveredPoint,
            onHover: viewModel.updateHover,
            onDragBegan: viewModel.handleDragBegan,
            onDragChanged: viewModel.handleDragChanged,
            onDragEnded: viewModel.handleDragEnded,
            onFocusRequested: focusEditorIfNeeded
        )
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 20) {
            levelNameSection
            tilePaletteSection
            toolsSection
            drawModeSection
            canvasControls
            enemySection
            sentrySection
            platformSection
            spawnSection
            quickActions
            Spacer(minLength: 24)
        }
    }

    private var enemySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Enemies")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.tool = .enemy
                } label: {
                    Label("Enemy Tool", systemImage: "figure.walk")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.addEnemyAtCenter()
                } label: {
                    Label("Add Enemy", systemImage: "plus")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
            }

            let enemies = viewModel.blueprint.enemies
            if enemies.isEmpty {
                Text("Use the Enemy tool to place configurable AI actors with patrols, chase/flee logic, and melee or ranged attacks.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                let columns = Array(repeating: GridItem(.flexible(minimum: 32, maximum: 50), spacing: 6), count: 4)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(enemies.enumerated()), id: \.element.id) { index, enemy in
                        Button {
                            viewModel.selectEnemy(enemy)
                        } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(viewModel.enemyColor(for: index).opacity(0.75))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(viewModel.selectedEnemyID == enemy.id ? Color.white : Color.clear, lineWidth: 2)
                                )
                                .overlay(
                                    Text("\(index + 1)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Enemy #\(index + 1)")
                    }
                }
            }

            if let enemy = viewModel.selectedEnemy {
                enemyDetailPanel(enemy: enemy)
            }
        }
    }

    @ViewBuilder
    private func enemyDetailPanel(enemy: EnemyBlueprint) -> some View {
        let current = viewModel.selectedEnemy ?? enemy
        VStack(alignment: .leading, spacing: 14) {
            Text("Selected Enemy")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text("Coordinate: r\(current.coordinate.row) c\(current.coordinate.column)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Group {
                let widthBinding = Binding<Double>(
                    get: {
                        viewModel.selectedEnemy?.size.x ?? current.size.x
                    },
                    set: { viewModel.updateSelectedEnemySizeWidth($0) }
                )
                Slider(value: widthBinding, in: 20...160, step: 2)
                Text(String(format: "Width: %.0f", widthBinding.wrappedValue))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                let heightBinding = Binding<Double>(
                    get: { viewModel.selectedEnemy?.size.y ?? current.size.y },
                    set: { viewModel.updateSelectedEnemySizeHeight($0) }
                )
                Slider(value: heightBinding, in: 20...220, step: 2)
                Text(String(format: "Height: %.0f", heightBinding.wrappedValue))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Group {
                let movementBinding = Binding<EnemyMovementChoice>(
                    get: { viewModel.selectedEnemyMovementChoice },
                    set: { viewModel.setSelectedEnemyMovementChoice($0) }
                )
                Picker("Movement", selection: movementBinding) {
                    ForEach(EnemyMovementChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.menu)

                switch current.movement {
                case .patrolHorizontal(let span, let speed):
                    let spanBinding = Binding<Double>(
                        get: {
                            if case .patrolHorizontal(let value, _) = viewModel.selectedEnemy?.movement { return value }
                            return span
                        },
                        set: { viewModel.updateSelectedEnemyHorizontalSpan($0) }
                    )
                    Slider(value: spanBinding, in: 16...800, step: 4)
                    Text(String(format: "Span: %.0f", spanBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    let speedBinding = Binding<Double>(
                        get: {
                            if case .patrolHorizontal(_, let value) = viewModel.selectedEnemy?.movement { return value }
                            return speed
                        },
                        set: { viewModel.updateSelectedEnemyHorizontalSpeed($0) }
                    )
                    Slider(value: speedBinding, in: 20...400, step: 5)
                    Text(String(format: "Speed: %.0f", speedBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                case .patrolVertical(let span, let speed):
                    let spanBinding = Binding<Double>(
                        get: {
                            if case .patrolVertical(let value, _) = viewModel.selectedEnemy?.movement { return value }
                            return span
                        },
                        set: { viewModel.updateSelectedEnemyVerticalSpan($0) }
                    )
                    Slider(value: spanBinding, in: 16...800, step: 4)
                    Text(String(format: "Span: %.0f", spanBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    let speedBinding = Binding<Double>(
                        get: {
                            if case .patrolVertical(_, let value) = viewModel.selectedEnemy?.movement { return value }
                            return speed
                        },
                        set: { viewModel.updateSelectedEnemyVerticalSpeed($0) }
                    )
                    Slider(value: speedBinding, in: 20...400, step: 5)
                    Text(String(format: "Speed: %.0f", speedBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                case .perimeter(let width, let height, let speed, let clockwise):
                    let widthBinding = Binding<Double>(
                        get: {
                            if case .perimeter(let value, _, _, _) = viewModel.selectedEnemy?.movement { return value }
                            return width
                        },
                        set: { viewModel.updateSelectedEnemyPerimeterWidth($0) }
                    )
                    Slider(value: widthBinding, in: 16...800, step: 4)
                    Text(String(format: "Width: %.0f", widthBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    let heightBinding = Binding<Double>(
                        get: {
                            if case .perimeter(_, let value, _, _) = viewModel.selectedEnemy?.movement { return value }
                            return height
                        },
                        set: { viewModel.updateSelectedEnemyPerimeterHeight($0) }
                    )
                    Slider(value: heightBinding, in: 16...800, step: 4)
                    Text(String(format: "Height: %.0f", heightBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    let speedBinding = Binding<Double>(
                        get: {
                            if case .perimeter(_, _, let value, _) = viewModel.selectedEnemy?.movement { return value }
                            return speed
                        },
                        set: { viewModel.updateSelectedEnemyPerimeterSpeed($0) }
                    )
                    Slider(value: speedBinding, in: 20...400, step: 5)
                    Text(String(format: "Speed: %.0f", speedBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Toggle("Clockwise", isOn: Binding<Bool>(
                        get: {
                            if case .perimeter(_, _, _, let value) = viewModel.selectedEnemy?.movement { return value }
                            return clockwise
                        },
                        set: { viewModel.updateSelectedEnemyPerimeterClockwise($0) }
                    ))

                case .wallBounce(let axis, let speed):
                    Picker("Axis", selection: Binding<EnemyController.MovementPattern.Axis>(
                        get: {
                            if case .wallBounce(let value, _) = viewModel.selectedEnemy?.movement { return value }
                            return axis
                        },
                        set: { viewModel.updateSelectedEnemyWallBounceAxis($0) }
                    )) {
                        Text("Horizontal").tag(EnemyController.MovementPattern.Axis.horizontal)
                        Text("Vertical").tag(EnemyController.MovementPattern.Axis.vertical)
                    }
                    .pickerStyle(.segmented)

                    let speedBinding = Binding<Double>(
                        get: {
                            if case .wallBounce(_, let value) = viewModel.selectedEnemy?.movement { return value }
                            return speed
                        },
                        set: { viewModel.updateSelectedEnemyWallBounceSpeed($0) }
                    )
                    Slider(value: speedBinding, in: 40...400, step: 5)
                    Text(String(format: "Speed: %.0f", speedBinding.wrappedValue))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                case .waypoints:
                    Text("Waypoint movement editing is not yet available in the editor.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .idle:
                    EmptyView()
                }
            }

            Group {
                let behaviorBinding = Binding<EnemyBehaviorChoice>(
                    get: { viewModel.selectedEnemyBehaviorChoice },
                    set: { viewModel.setSelectedEnemyBehaviorChoice($0) }
                )
                Picker("Behaviour", selection: behaviorBinding) {
                    ForEach(EnemyBehaviorChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.menu)

                switch current.behavior {
                case .passive:
                    EmptyView()
                case .chase(let range, let multiplier, let tolerance):
                    Slider(value: Binding<Double>(
                        get: { if case .chase(let value, _, _) = viewModel.selectedEnemy?.behavior { return value }; return range },
                        set: { viewModel.updateSelectedEnemyChaseRange($0) }
                    ), in: 32...1200, step: 10)
                    let displayedRange = viewModel.selectedEnemy.flatMap { $0.behavior.flatChaseRange } ?? range
                    Text(String(format: "Sight Range: %.0f", displayedRange))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .chase(_, let value, _) = viewModel.selectedEnemy?.behavior { return value }; return multiplier },
                        set: { viewModel.updateSelectedEnemyChaseMultiplier($0) }
                    ), in: 0.5...3.0, step: 0.05)
                    let displayedMultiplier = viewModel.selectedEnemy.flatMap { $0.behavior.flatChaseMultiplier } ?? multiplier
                    Text(String(format: "Speed Multiplier: %.2f", displayedMultiplier))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .chase(_, _, let value) = viewModel.selectedEnemy?.behavior { return value }; return tolerance },
                        set: { viewModel.updateSelectedEnemyChaseTolerance($0) }
                    ), in: 0...400, step: 5)
                    let displayedTolerance = viewModel.selectedEnemy.flatMap { $0.behavior.flatChaseTolerance } ?? tolerance
                    Text(String(format: "Vertical Tolerance: %.0f", displayedTolerance))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                case .flee(let range, let safe, let run):
                    Slider(value: Binding<Double>(
                        get: { if case .flee(let value, _, _) = viewModel.selectedEnemy?.behavior { return value }; return range },
                        set: { viewModel.updateSelectedEnemyFleeRange($0) }
                    ), in: 32...1200, step: 10)
                    let fleeRange = viewModel.selectedEnemy.flatMap { $0.behavior.flatFleeRange } ?? range
                    Text(String(format: "Sight Range: %.0f", fleeRange))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .flee(_, let value, _) = viewModel.selectedEnemy?.behavior { return value }; return safe },
                        set: { viewModel.updateSelectedEnemyFleeSafeDistance($0) }
                    ), in: 32...1200, step: 10)
                    let safeDistance = viewModel.selectedEnemy.flatMap { $0.behavior.flatFleeSafe } ?? safe
                    Text(String(format: "Safe Distance: %.0f", safeDistance))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .flee(_, _, let value) = viewModel.selectedEnemy?.behavior { return value }; return run },
                        set: { viewModel.updateSelectedEnemyFleeRunMultiplier($0) }
                    ), in: 0.5...3.0, step: 0.05)
                    let fleeMultiplier = viewModel.selectedEnemy.flatMap { $0.behavior.flatFleeRun } ?? run
                    Text(String(format: "Run Multiplier: %.2f", fleeMultiplier))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                case .strafe(let range, let preferred, let speed):
                    Slider(value: Binding<Double>(
                        get: { if case .strafe(let value, _, _) = viewModel.selectedEnemy?.behavior { return value }; return range },
                        set: { viewModel.updateSelectedEnemyStrafeRange($0) }
                    ), in: 60...1600, step: 10)
                    let strafeRange = viewModel.selectedEnemy.flatMap { $0.behavior.flatStrafeRange } ?? range
                    Text(String(format: "Sight Range: %.0f", strafeRange))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .strafe(_, let value, _) = viewModel.selectedEnemy?.behavior { return value.lowerBound }; return preferred.lowerBound },
                        set: { viewModel.updateSelectedEnemyStrafeNearDistance($0) }
                    ), in: 40...max(60, preferred.upperBound - 8), step: 5)
                    let strafeNear = viewModel.selectedEnemy.flatMap { $0.behavior.flatStrafeNear } ?? preferred.lowerBound
                    Text(String(format: "Preferred Near: %.0f", strafeNear))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .strafe(_, let value, _) = viewModel.selectedEnemy?.behavior { return value.upperBound }; return preferred.upperBound },
                        set: { viewModel.updateSelectedEnemyStrafeFarDistance($0) }
                    ), in: preferred.lowerBound + 8...1600, step: 5)
                    let strafeFar = viewModel.selectedEnemy.flatMap { $0.behavior.flatStrafeFar } ?? preferred.upperBound
                    Text(String(format: "Preferred Far: %.0f", strafeFar))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .strafe(_, _, let value) = viewModel.selectedEnemy?.behavior { return value }; return speed },
                        set: { viewModel.updateSelectedEnemyStrafeSpeed($0) }
                    ), in: 30...320, step: 5)
                    let strafeSpeed = viewModel.selectedEnemy.flatMap { $0.behavior.flatStrafeSpeed } ?? speed
                    Text(String(format: "Strafe Speed: %.0f", strafeSpeed))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                let attackBinding = Binding<EnemyAttackChoice>(
                    get: { viewModel.selectedEnemyAttackChoice },
                    set: { viewModel.setSelectedEnemyAttackChoice($0) }
                )
                Picker("Attack", selection: attackBinding) {
                    ForEach(EnemyAttackChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.menu)

                switch current.attack {
                case .none:
                    EmptyView()
                case .shooter(let speed, let cooldown, let range):
                    Slider(value: Binding<Double>(
                        get: { if case .shooter(let value, _, _) = viewModel.selectedEnemy?.attack { return value }; return speed },
                        set: { viewModel.updateSelectedEnemyShooterSpeed($0) }
                    ), in: 80...900, step: 10)
                    let bulletSpeed = viewModel.selectedEnemy.flatMap { $0.attack.flatShooterSpeed } ?? speed
                    Text(String(format: "Bullet Speed: %.0f", bulletSpeed))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .shooter(_, let value, _) = viewModel.selectedEnemy?.attack { return value }; return cooldown },
                        set: { viewModel.updateSelectedEnemyShooterCooldown($0) }
                    ), in: 0.1...4, step: 0.05)
                    let bulletCooldown = viewModel.selectedEnemy.flatMap { $0.attack.flatShooterCooldown } ?? cooldown
                    Text(String(format: "Cooldown: %.2fs", bulletCooldown))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .shooter(_, _, let value) = viewModel.selectedEnemy?.attack { return value }; return range },
                        set: { viewModel.updateSelectedEnemyShooterRange($0) }
                    ), in: 80...1600, step: 10)
                    let bulletRange = viewModel.selectedEnemy.flatMap { $0.attack.flatShooterRange } ?? range
                    Text(String(format: "Range: %.0f", bulletRange))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                case .sword(let range, let cooldown, let knock):
                    Slider(value: Binding<Double>(
                        get: { if case .sword(let value, _, _) = viewModel.selectedEnemy?.attack { return value }; return range },
                        set: { viewModel.updateSelectedEnemySwordRange($0) }
                    ), in: 16...160, step: 2)
                    let meleeRange = viewModel.selectedEnemy.flatMap { $0.attack.flatMeleeRange } ?? range
                    Text(String(format: "Range: %.0f", meleeRange))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .sword(_, let value, _) = viewModel.selectedEnemy?.attack { return value }; return cooldown },
                        set: { viewModel.updateSelectedEnemySwordCooldown($0) }
                    ), in: 0.2...4, step: 0.05)
                    let meleeCooldown = viewModel.selectedEnemy.flatMap { $0.attack.flatMeleeCooldown } ?? cooldown
                    Text(String(format: "Cooldown: %.2fs", meleeCooldown))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .sword(_, _, let value) = viewModel.selectedEnemy?.attack { return value }; return knock },
                        set: { viewModel.updateSelectedEnemySwordKnockback($0) }
                    ), in: 0...600, step: 10)
                    let meleeKnock = viewModel.selectedEnemy.flatMap { $0.attack.flatMeleeKnockback } ?? knock
                    Text(String(format: "Knockback: %.0f", meleeKnock))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                case .punch(let range, let cooldown, let knock):
                    Slider(value: Binding<Double>(
                        get: { if case .punch(let value, _, _) = viewModel.selectedEnemy?.attack { return value }; return range },
                        set: { viewModel.updateSelectedEnemyPunchRange($0) }
                    ), in: 8...120, step: 2)
                    let meleeRange = viewModel.selectedEnemy.flatMap { $0.attack.flatMeleeRange } ?? range
                    Text(String(format: "Range: %.0f", meleeRange))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .punch(_, let value, _) = viewModel.selectedEnemy?.attack { return value }; return cooldown },
                        set: { viewModel.updateSelectedEnemyPunchCooldown($0) }
                    ), in: 0.2...4, step: 0.05)
                    let meleeCooldown = viewModel.selectedEnemy.flatMap { $0.attack.flatMeleeCooldown } ?? cooldown
                    Text(String(format: "Cooldown: %.2fs", meleeCooldown))
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Slider(value: Binding<Double>(
                        get: { if case .punch(_, _, let value) = viewModel.selectedEnemy?.attack { return value }; return knock },
                        set: { viewModel.updateSelectedEnemyPunchKnockback($0) }
                    ), in: 0...600, step: 10)
                    let meleeKnock = viewModel.selectedEnemy.flatMap { $0.attack.flatMeleeKnockback } ?? knock
                    Text(String(format: "Knockback: %.0f", meleeKnock))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Group {
                Slider(value: Binding<Double>(
                    get: { viewModel.selectedEnemy?.acceleration ?? current.acceleration },
                    set: { viewModel.updateSelectedEnemyAcceleration($0) }
                ), in: 2...30, step: 0.5)
                Text(String(format: "Acceleration: %.1f", viewModel.selectedEnemy?.acceleration ?? current.acceleration))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Slider(value: Binding<Double>(
                    get: { viewModel.selectedEnemy?.maxSpeed ?? current.maxSpeed },
                    set: { viewModel.updateSelectedEnemyMaxSpeed($0) }
                ), in: 60...600, step: 5)
                Text(String(format: "Max Speed: %.0f", viewModel.selectedEnemy?.maxSpeed ?? current.maxSpeed))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Toggle("Affected by Gravity", isOn: Binding<Bool>(
                    get: { viewModel.selectedEnemy?.affectedByGravity ?? current.affectedByGravity },
                    set: { viewModel.updateSelectedEnemyGravityEnabled($0) }
                ))

                let gravityBinding = Binding<Double>(
                    get: { viewModel.selectedEnemy?.gravityScale ?? current.gravityScale },
                    set: { viewModel.updateSelectedEnemyGravityScale($0) }
                )
                Slider(value: gravityBinding, in: 0...2.0, step: 0.05)
                    .disabled(!(viewModel.selectedEnemy?.affectedByGravity ?? current.affectedByGravity))
                Text(String(format: "Gravity Scale: %.2f", gravityBinding.wrappedValue))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button {
                    viewModel.duplicateSelectedEnemy()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                        .font(.caption)
                }

                Spacer()

                Button(role: .destructive) {
                    viewModel.removeSelectedEnemy()
                } label: {
                    Label("Remove", systemImage: "trash")
                        .font(.caption)
                }
            }
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var levelNameSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Level Name")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name", text: $viewModel.levelName)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var tilePaletteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tiles")
                .font(.caption)
                .foregroundStyle(.secondary)

            let columns = [GridItem(.adaptive(minimum: 52, maximum: 80), spacing: 8)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(viewModel.tilePalette, id: \.self) { tile in
                    Button {
                        viewModel.selectedTileKind = tile
                    } label: {
                        TileSwatch(tile: tile, isSelected: viewModel.selectedTileKind == tile)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tile.displayName)
                }
            }

            Text("Selected: \(viewModel.selectedTileKind.displayName)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if viewModel.selectedTileKind.isRamp {
                HStack(spacing: 8) {
                    Button {
                        viewModel.toggleSelectedRampOrientation()
                    } label: {
                        Label("Flip Ramp", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.bordered)

                    Text("Ramp tiles paint with the shown slope; flip to match your layout.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tools")
                .font(.caption)
                .foregroundStyle(.secondary)

            let columns = [GridItem(.adaptive(minimum: 72, maximum: 120), spacing: 8)]
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(MapEditorViewModel.Tool.allCases) { tool in
                    Button {
                        viewModel.tool = tool
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: tool.systemImage)
                                .font(.title3)
                            Text(tool.label)
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(viewModel.tool == tool ? Color.accentColor.opacity(0.2) : PlatformColors.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var drawModeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shape Mode")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Draw Mode", selection: $viewModel.drawMode) {
                ForEach(MapEditorViewModel.ShapeDrawMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var canvasControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Canvas")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button(action: viewModel.zoomOut) { Image(systemName: "minus.magnifyingglass") }
                Button(action: viewModel.zoomIn) { Image(systemName: "plus.magnifyingglass") }
            }
            .buttonStyle(.bordered)
            .labelStyle(.iconOnly)

            HStack(spacing: 8) {
                Button(action: viewModel.undo) {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(!viewModel.canUndo)

                Button(action: viewModel.redo) {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(!viewModel.canRedo)
            }
            .buttonStyle(.bordered)
        }
    }

    private var sentrySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Sentries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.tool = .sentry
                } label: {
                    Label("Sentry Tool", systemImage: "dot.radiowaves.right")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
            }

            let sentries = viewModel.blueprint.sentries
            if sentries.isEmpty {
                Text("Use the Sentry tool to place automated turrets that sweep for players.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                let columns = Array(repeating: GridItem(.flexible(minimum: 32, maximum: 50), spacing: 8), count: 4)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(sentries.enumerated()), id: \.element.id) { index, sentry in
                        Button {
                            viewModel.selectSentry(sentry)
                        } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(viewModel.sentryColor(for: index).opacity(0.75))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(viewModel.selectedSentryID == sentry.id ? Color.white : Color.clear, lineWidth: 2)
                                )
                                .overlay(
                                    Text("\(index + 1)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let sentry = viewModel.selectedSentry {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Selected Sentry")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("Coordinate: r\(sentry.coordinate.row) c\(sentry.coordinate.column)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    let rangeBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.scanRange ?? sentry.scanRange },
                        set: { viewModel.updateSelectedSentryRange($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: rangeBinding, in: 1.0...32.0, step: 0.5)
                        Text(String(format: "Scan Range: %.1f tiles", rangeBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    let centerBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.scanCenterDegrees ?? sentry.scanCenterDegrees },
                        set: { viewModel.updateSelectedSentryCenter($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: centerBinding, in: -180...180, step: 1)
                        Text(String(format: "Scan Center: %.0f°", centerBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    let arcBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.scanArcDegrees ?? sentry.scanArcDegrees },
                        set: { viewModel.updateSelectedSentryArc($0) }
                    )
                    let angleRange = viewModel.sentryInitialAngleRange(sentry)
                    let initialAngleBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.initialFacingDegrees ?? sentry.initialFacingDegrees },
                        set: { viewModel.updateSelectedSentryInitialAngle($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: arcBinding, in: 10...240, step: 1)
                        Text(String(format: "Sweep Arc: %.0f°", arcBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: initialAngleBinding, in: angleRange, step: 1)
                        Text(String(format: "Initial Angle: %.0f°", initialAngleBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    let sweepBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.sweepSpeedDegreesPerSecond ?? sentry.sweepSpeedDegreesPerSecond },
                        set: { viewModel.updateSelectedSentrySweepSpeed($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: sweepBinding, in: 10...360, step: 5)
                        Text(String(format: "Sweep Speed: %.0f°/s", sweepBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    let kindBinding = Binding<SentryBlueprint.ProjectileKind>(
                        get: { viewModel.selectedSentry?.projectileKind ?? sentry.projectileKind },
                        set: { viewModel.updateSelectedSentryProjectileKind($0) }
                    )
                    Picker("Projectile Type", selection: kindBinding) {
                        ForEach(SentryBlueprint.ProjectileKind.allCases, id: \.self) { kind in
                            Text(kind.displayLabel).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    let currentKind = viewModel.selectedSentry?.projectileKind ?? sentry.projectileKind

                    let projectileBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.projectileSpeed ?? sentry.projectileSpeed },
                        set: { viewModel.updateSelectedSentryProjectileSpeed($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: projectileBinding, in: 50...2000, step: 25)
                        Text(String(format: currentKind == .laser ? "Beam Intensity: %.0f" : "Projectile Speed: %.0f", projectileBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(currentKind == .laser)

                    let sizeBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.projectileSize ?? sentry.projectileSize },
                        set: { viewModel.updateSelectedSentryProjectileSize($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: sizeBinding, in: 0.05...2.0, step: 0.05)
                        Text(String(format: "Projectile Size: %.2f tiles", sizeBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    let lifetimeBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.projectileLifetime ?? sentry.projectileLifetime },
                        set: { viewModel.updateSelectedSentryProjectileLifetime($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: lifetimeBinding, in: 0.1...12.0, step: 0.1)
                        let label = currentKind == .laser ? "Beam Duration" : "Lifetime"
                        Text(String(format: "%@: %.1fs", label, lifetimeBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    let burstBinding = Binding<Int>(
                        get: { viewModel.selectedSentry?.projectileBurstCount ?? sentry.projectileBurstCount },
                        set: { viewModel.updateSelectedSentryProjectileBurstCount($0) }
                    )
                    Stepper(value: burstBinding, in: 1...12) {
                        Text("Burst Count: \(burstBinding.wrappedValue)")
                    }

                    let spreadBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.projectileSpreadDegrees ?? sentry.projectileSpreadDegrees },
                        set: { viewModel.updateSelectedSentryProjectileSpread($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: spreadBinding, in: 0...90, step: 1)
                        Text(String(format: "Spread: %.0f°", spreadBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(burstBinding.wrappedValue <= 1)

                    if currentKind == .heatSeeking {
                        let turnBinding = Binding<Double>(
                            get: { viewModel.selectedSentry?.heatSeekingTurnRateDegreesPerSecond ?? sentry.heatSeekingTurnRateDegreesPerSecond },
                            set: { viewModel.updateSelectedSentryHeatTurnRate($0) }
                        )
                        VStack(alignment: .leading, spacing: 4) {
                            Slider(value: turnBinding, in: 30...720, step: 10)
                            Text(String(format: "Turn Rate: %.0f°/s", turnBinding.wrappedValue))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    let cooldownBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.fireCooldown ?? sentry.fireCooldown },
                        set: { viewModel.updateSelectedSentryCooldown($0) }
                    )
                    Stepper(value: cooldownBinding, in: 0.2...5.0, step: 0.1) {
                        Text(String(format: "Cooldown: %.1fs", cooldownBinding.wrappedValue))
                    }

                    let toleranceBinding = Binding<Double>(
                        get: { viewModel.selectedSentry?.aimToleranceDegrees ?? sentry.aimToleranceDegrees },
                        set: { viewModel.updateSelectedSentryAimTolerance($0) }
                    )
                    Stepper(value: toleranceBinding, in: 2...45, step: 1) {
                        Text(String(format: "Aim Tolerance: %.0f°", toleranceBinding.wrappedValue))
                    }

                    Button {
                        viewModel.duplicateSelectedSentry()
                    } label: {
                        Label("Duplicate Sentry", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        viewModel.removeSentry(sentry)
                    } label: {
                        Label("Remove Sentry", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
    
    private func isHandledKey(_ kp: KeyPress) -> Bool {
        // Any key we map in InputController should return handled.
        // This avoids arrow keys accidentally scrolling a parent scroll view.
        switch kp.key {
        case .leftArrow, .rightArrow, .upArrow, .escape:
            return true
        default:
            break
        }
        let ch = kp.characters.lowercased()
        if ch == "a" || ch == "d" || ch == "w" || ch == " " { return true }
        if kp.modifiers.contains(.command), (ch == "z" || ch == "y" || ch == "r") { return true }
        return false
    }

    private var platformSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Platforms")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.tool = .platform
                } label: {
                    Label("Platform Tool", systemImage: "hand.point.up.left.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
            }

            let platforms = viewModel.blueprint.movingPlatforms
            if platforms.isEmpty {
                Text("Use the Platform tool to drag out a platform, then adjust its path here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                let columns = Array(repeating: GridItem(.flexible(minimum: 32, maximum: 50), spacing: 8), count: 4)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(platforms.enumerated()), id: \.element.id) { index, platform in
                        Button {
                            viewModel.selectPlatform(platform)
                        } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(viewModel.platformColor(for: index).opacity(0.75))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(viewModel.selectedPlatformID == platform.id ? Color.white : Color.clear, lineWidth: 2)
                                )
                                .overlay(
                                    Text("\(index + 1)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let platform = viewModel.selectedPlatform {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Selected Platform")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text("Origin: r\(platform.origin.row) c\(platform.origin.column)  •  Size: \(platform.size.columns)×\(platform.size.rows)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    let rowBinding = Binding<Int>(
                        get: { viewModel.selectedPlatform?.target.row ?? platform.target.row },
                        set: { viewModel.updateSelectedPlatformTarget(row: $0) }
                    )
                    let colBinding = Binding<Int>(
                        get: { viewModel.selectedPlatform?.target.column ?? platform.target.column },
                        set: { viewModel.updateSelectedPlatformTarget(column: $0) }
                    )

                    Stepper(value: rowBinding, in: viewModel.platformTargetRowRange(platform)) {
                        Text("Target Row: \(rowBinding.wrappedValue)")
                    }

                    Stepper(value: colBinding, in: viewModel.platformTargetColumnRange(platform)) {
                        Text("Target Column: \(colBinding.wrappedValue)")
                    }

                    let speedBinding = Binding<Double>(
                        get: { platform.speed },
                        set: { viewModel.updateSelectedPlatformSpeed($0) }
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: speedBinding, in: 0.1...5.0, step: 0.1)
                        Text(String(format: "Speed: %.1f tiles/s", speedBinding.wrappedValue))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    let progressBinding = Binding<Double>(
                        get: { viewModel.selectedPlatform?.initialProgress ?? platform.initialProgress },
                        set: { viewModel.updateSelectedPlatformInitialProgress($0) }
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Slider(value: progressBinding, in: 0...1, step: 0.01)
                        Text(String(format: "Start Position: %.0f%%", progressBinding.wrappedValue * 100))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Button {
                        viewModel.duplicateSelectedPlatform()
                    } label: {
                        Label("Duplicate Platform", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        viewModel.removePlatform(platform)
                    } label: {
                        Label("Remove Platform", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var spawnSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Spawn Points")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: addSpawn) {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }

            if viewModel.blueprint.spawnPoints.isEmpty {
                Text("No spawns yet. Paint with the Spawn tool or tap + to add one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                let spawns = viewModel.blueprint.spawnPoints
                let columns = Array(repeating: GridItem(.flexible(minimum: 32, maximum: 50), spacing: 8), count: 4)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(spawns.indices), id: \.self) { index in
                        let spawn = spawns[index]
                        Button {
                            viewModel.selectSpawn(spawn)
                            spawnNameDraft = spawn.name
                        } label: {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(viewModel.spawnColor(for: index).opacity(0.85))
                                .frame(width: 40, height: 40)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(viewModel.selectedSpawnID == spawn.id ? Color.white : Color.clear, lineWidth: 2)
                                )
                                .overlay(
                                    Text("\(index + 1)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if viewModel.selectedSpawn != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Selected Spawn")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    TextField("Name", text: $spawnNameDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { viewModel.renameSelectedSpawn(to: spawnNameDraft) }

                    HStack(spacing: 8) {
                        Button(action: { viewModel.renameSelectedSpawn(to: spawnNameDraft) }) {
                            Label("Save Name", systemImage: "checkmark.circle")
                        }
                        Button(role: .destructive, action: viewModel.removeSelectedSpawn) {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Actions")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(action: viewModel.fillGround) {
                Label("Fill Ground", systemImage: "square.stack.3d.up.fill")
            }
            Button(role: .destructive, action: viewModel.clearLevel) {
                Label("Clear Map", systemImage: "trash")
            }
        }
    }

    private func addSpawn() {
        viewModel.addSpawnAtCenter()
    }

    private func focusEditor() {
        focused = true
    }

    private func focusEditorIfNeeded() {
        if !focused {
            focusEditor()
        }
    }

    private func handleEditorCommand(for keyPress: KeyPress) -> Bool {
        let normalized = keyPress.characters.lowercased()
        let hasCommand = keyPress.modifiers.contains(.command)
        let hasShift = keyPress.modifiers.contains(.shift)

        var action: (() -> Void)?

        if keyPress.key == .escape {
            action = {
                if isPreviewing {
                    isPreviewing = false
                }
                focusEditor()
            }
        } else if hasCommand {
            if normalized.contains("z") {
                action = {
                    if hasShift {
                        if viewModel.canRedo { viewModel.redo() }
                    } else {
                        if viewModel.canUndo { viewModel.undo() }
                    }
                }
            } else if normalized.contains("y") {
                action = {
                    if viewModel.canRedo { viewModel.redo() }
                }
            } else if normalized.contains("r") {
                action = openPreviewIfPossible
            }
        }

        guard let action else { return false }

        DispatchQueue.main.async {
            action()
        }

        return true
    }

    private var floatingControls: some View {
        HStack(spacing: 12) {
            Button(action: viewModel.toggleGrid) {
                Image(systemName: viewModel.showGrid ? "square.grid.3x3.fill" : "square.grid.3x3")
                    .font(.title3)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(viewModel.showGrid ? "Hide Grid" : "Show Grid")

            Button(action: openPreviewIfPossible) {
                Image(systemName: "play.circle")
                    .font(.title3)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .disabled(viewModel.blueprint.spawnPoints.isEmpty)
            .opacity(viewModel.blueprint.spawnPoints.isEmpty ? 0.4 : 1.0)
            .accessibilityLabel("Playtest Level")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial)
        .clipShape(Capsule())
        .shadow(radius: 6, y: 2)
    }

    private func openPreviewIfPossible() {
        guard !isPreviewing else { return }
        guard !viewModel.blueprint.spawnPoints.isEmpty else { return }
        isPreviewing = true
    }
}

extension SentryBlueprint.ProjectileKind {
    var displayLabel: String {
        switch self {
        case .bolt: return "Bolt"
        case .heatSeeking: return "Heat"
        case .laser: return "Laser"
        }
    }
}

private extension EnemyBlueprint.Behavior {
    var flatChaseRange: Double? {
        if case .chase(let range, _, _) = self { return range }
        return nil
    }

    var flatChaseMultiplier: Double? {
        if case .chase(_, let multiplier, _) = self { return multiplier }
        return nil
    }

    var flatChaseTolerance: Double? {
        if case .chase(_, _, let tolerance) = self { return tolerance }
        return nil
    }

    var flatFleeRange: Double? {
        if case .flee(let range, _, _) = self { return range }
        return nil
    }

    var flatFleeSafe: Double? {
        if case .flee(_, let safe, _) = self { return safe }
        return nil
    }

    var flatFleeRun: Double? {
        if case .flee(_, _, let run) = self { return run }
        return nil
    }

    var flatStrafeRange: Double? {
        if case .strafe(let range, _, _) = self { return range }
        return nil
    }

    var flatStrafeNear: Double? {
        if case .strafe(_, let preferred, _) = self { return preferred.lowerBound }
        return nil
    }

    var flatStrafeFar: Double? {
        if case .strafe(_, let preferred, _) = self { return preferred.upperBound }
        return nil
    }

    var flatStrafeSpeed: Double? {
        if case .strafe(_, _, let speed) = self { return speed }
        return nil
    }
}

extension EnemyBlueprint.Attack {
    var flatShooterSpeed: Double? {
        if case .shooter(let speed, _, _) = self { return speed }
        return nil
    }

    var flatShooterCooldown: Double? {
        if case .shooter(_, let cooldown, _) = self { return cooldown }
        return nil
    }

    var flatShooterRange: Double? {
        if case .shooter(_, _, let range) = self { return range }
        return nil
    }

    var flatMeleeRange: Double? {
        switch self {
        case .sword(let range, _, _), .punch(let range, _, _):
            return range
        default:
            return nil
        }
    }

    var flatMeleeCooldown: Double? {
        switch self {
        case .sword(_, let cooldown, _), .punch(_, let cooldown, _):
            return cooldown
        default:
            return nil
        }
    }

    var flatMeleeKnockback: Double? {
        switch self {
        case .sword(_, _, let knock), .punch(_, _, let knock):
            return knock
        default:
            return nil
        }
    }
}

extension EnemyBlueprint {
    var behaviorLabelPrefix: String {
        switch behavior {
        case .passive: return "P"
        case .chase: return "C"
        case .flee: return "F"
        case .strafe: return "R"
        }
    }
}

#Preview {
    MapEditorView()
        .frame(minWidth: 900, minHeight: 600)
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
