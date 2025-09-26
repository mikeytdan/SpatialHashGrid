# Swift Spatial Hash Grid (Physics-Optimized) + SwiftUI Demo

This package contains:
- `SpatialHashGrid.swift` — a generic, high-performance spatial hash grid for broad‑phase collision in physics engines.
- `SpatialHashGridDemoView.swift` — a SwiftUI `View` rendering thousands of moving units; orange "specials" recolor neighbors (blue) within an influence radius using fast grid queries.
- `SpatialHashGridTests.swift` — XCTest unit tests including speed tests using `measure {}`.

## Integration

1. Add `SpatialHashGrid.swift` and `SpatialHashGridDemoView.swift` to your app target.
2. Replace `YourModuleNameHere` in `SpatialHashGridTests.swift` with your target name, then add the test file to your test target.
3. Present the demo anywhere:
   ```swift
   import SwiftUI

   struct ContentView: View {
       var body: some View {
           SpatialHashGridDemoView()
       }
   }
