import AppKit
import FeatherweightCore
import SwiftUI

/// A small coloured tag naming a project's package manager ("npm", "pnpm", "yarn", "bun").
struct PackageManagerBadge: View {
    let manager: PackageManager

    var body: some View {
        if manager == .none {
            Text("–")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("No package manager")
        } else {
            Text(manager.rawValue)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(text)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(fill, in: RoundedRectangle(cornerRadius: 4))
        }
    }

    private var text: Color {
        switch manager {
        case .npm: Theme.adaptive(light: NSColor(red: 0.70, green: 0.16, blue: 0.16, alpha: 1),
                                  dark: NSColor(red: 1.00, green: 0.54, blue: 0.50, alpha: 1))
        case .pnpm: Theme.amberText
        case .yarn: Theme.adaptive(light: NSColor(red: 0.12, green: 0.36, blue: 0.70, alpha: 1),
                                   dark: NSColor(red: 0.54, green: 0.74, blue: 1.00, alpha: 1))
        case .bun: Theme.adaptive(light: NSColor(red: 0.42, green: 0.30, blue: 0.14, alpha: 1),
                                  dark: NSColor(red: 0.96, green: 0.89, blue: 0.76, alpha: 1))
        case .none: .secondary
        }
    }

    private var fill: Color {
        switch manager {
        case .npm: .red.opacity(0.16)
        case .pnpm: Theme.amber.opacity(0.18)
        case .yarn: .blue.opacity(0.16)
        case .bun: .brown.opacity(0.22)
        case .none: .clear
        }
    }
}
