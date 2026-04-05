//
//  PixelSettingsIcon.swift
//  VibeHub
//
//  Pixel-art icons for settings sidebar, matching ClaudeCrabIcon style
//

import SwiftUI

enum SettingsIconType: CaseIterable {
    case appearance
    case notifications
    case system
    case license
    case remote
}

struct PixelSettingsIcon: View {
    let type: SettingsIconType
    let size: CGFloat
    var color: Color = .white

    var body: some View {
        Canvas { context, canvasSize in
            let grid = Self.grids[type]!
            let rows = grid.count
            let cols = grid[0].count
            let px = min(canvasSize.width / CGFloat(cols), canvasSize.height / CGFloat(rows))
            let xOff = (canvasSize.width - px * CGFloat(cols)) / 2
            let yOff = (canvasSize.height - px * CGFloat(rows)) / 2

            for (r, row) in grid.enumerated() {
                for (c, on) in row.enumerated() where on {
                    let rect = CGRect(
                        x: xOff + CGFloat(c) * px,
                        y: yOff + CGFloat(r) * px,
                        width: px,
                        height: px
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Pattern Data

    private static let grids: [SettingsIconType: [[Bool]]] = [
        // Monitor/display
        .appearance: parse("""
        #######
        #.....#
        #.....#
        #.....#
        #######
        ..###..
        .#####.
        """),
        // Bell with clapper
        .notifications: parse("""
        ...#...
        ..###..
        ..###..
        .#####.
        #######
        .......
        ...#...
        """),
        // Gear
        .system: parse("""
        ..#.#..
        .#####.
        ##...##
        .#...#.
        ##...##
        .#####.
        ..#.#..
        """),
        // Key
        .license: parse("""
        ..###..
        .#...#.
        ..###..
        ...#...
        ..###..
        ...#...
        ...#...
        """),
        // Globe with grid lines
        .remote: parse("""
        .#####.
        #..#..#
        #######
        #..#..#
        #######
        #..#..#
        .#####.
        """),
    ]

    private static func parse(_ pattern: String) -> [[Bool]] {
        pattern
            .split(separator: "\n")
            .map { line in
                line.trimmingCharacters(in: .whitespaces).map { $0 == "#" }
            }
            .filter { !$0.isEmpty }
    }
}
