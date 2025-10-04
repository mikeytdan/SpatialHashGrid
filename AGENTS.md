# Repository Guidelines

## Project Structure & Module Organization
`SpatialHashGrid/` hosts both the SwiftUI shell and the reusable grid engine. Core types and algorithms live in `SpatialHashGrid.swift`; authoring flows sit in `MapEditorView.swift` and the SpriteKit preview runtime. Keep engine changes isolated from UI tweaks whenever possible. `SpatialHashGridTests/` carries the logic suite built with the Swift Testing package (`import Testing`). Group related checks inside a single `@Suite` and share fixtures through private helpers at the top of the file. `SpatialHashGridUITests/` retains the generated XCTest smoke tests; prune or extend them depending on how much UI coverage you need. Long-form writeups belong in `Docs/`; link to them from headers instead of expanding inline comments.

## Build, Test, and Development Commands
Open `SpatialHashGrid.xcodeproj` in Xcode 16+ targeting the iOS simulator. From the CLI, a full debug build runs via:
```bash
xcodebuild -project SpatialHashGrid.xcodeproj -scheme SpatialHashGrid -destination 'platform=iOS Simulator,name=iPhone 17' -configuration Debug build
```
Run the logic test suite (no UI boots) with:
```bash
xcodebuild test -project SpatialHashGrid.xcodeproj -scheme SpatialHashGrid -destination 'platform=iOS Simulator,name=iPhone 17'
```
Leave heavy profiling in the Performance Tests section gated by `#if DEBUG` if you add new timers.

## Coding Style & Naming Conventions
Use four-space indentation and follow Swift API Design Guidelines: `UpperCamelCase` for types and protocols, `lowerCamelCase` for functions, properties, and test names. Prefer expressive parameter labels (`query(aabb:)` over ambiguous overloads) and keep generic names (`ID`, `Vec2`) short but capitalized. Maintain existing `// MARK:` separators, and keep inlinable helpers adjacent to the public API they support. No repo-level formatter is committed; align multi-line argument lists one parameter per line and wrap at roughly 100 columns.

## Testing Guidelines
Logic tests rely on the Swift Testing DSL (`@Test`, `#expect`). Name each `@Test` after the behavior under scrutiny (`insertAndQuery`, `updateMovesCells`). Keep assertions deterministic; do not rely on random data without seeding or bounding ranges. UI tests remain XCTest based; mark long-running flows with `@MainActor` and reset app state in `setUpWithError`. Add coverage notes to `SpatialHashGridTests.swift` header comments when introducing new scenarios.

## Commit & Pull Request Guidelines
Recent history favors concise, sentence-case summaries with optional feature prefixes (`Spatial hash demo: ...`). Write commit titles in the imperative mood and keep bodies focused on rationale or performance notes. Pull requests should call out affected modules, simulator targets used for validation, and attach GIFs or screenshots when UI behavior changes. Link issue numbers with `Fixes #123` so automation can close threads.
