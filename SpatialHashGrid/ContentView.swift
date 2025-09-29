//
//  ContentView.swift
//  SpatialHashGrid
//
//  Created by Michael Daniels on 9/25/25.
//

import SwiftUI

struct ContentView: View {
    private enum Demo: String, CaseIterable, Identifiable {
        case editor = "Editor"
        case swiftUI = "SwiftUI"
        case spriteKit = "SpriteKit"

        var id: Demo { self }
    }

    @State private var selection: Demo = .editor

    var body: some View {
        VStack(spacing: 0) {
            Picker("Demo", selection: $selection) {
                ForEach(Demo.allCases) { demo in
                    Text(demo.rawValue).tag(demo)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            Group {
                switch selection {
                case .editor:
                    MapEditorView()
                case .swiftUI:
                    GameDemoView()
                case .spriteKit:
                    SpriteKitGameDemoView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    ContentView()
}
