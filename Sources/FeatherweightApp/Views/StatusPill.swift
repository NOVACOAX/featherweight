import AppKit
import FeatherweightCore
import SwiftUI

extension ProjectSummary {
    /// How a status reads at a glance.
    enum StatusTone {
        /// Nothing to do, or work was done ("Up to date", "Cleared 4.0 GB", "Linked by pnpm").
        case good
        /// The cleaner left this project alone ("Skipped: active", "Tracked in git").
        case skipped
        /// A cache folder was kept on purpose (".output kept").
        case info
    }

    /// A pnpm project reads "Linked by pnpm" whatever else holds its caches back.
    var statusTone: StatusTone {
        if packageManager == .pnpm { return .good }
        if skipReason != nil { return .skipped }
        return status.hasSuffix(" kept") ? .info : .good
    }
}

/// A project's status as a rounded tag, coloured by what it means.
struct StatusPill: View {
    let text: String
    let tone: ProjectSummary.StatusTone

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch tone {
        case .good: Theme.adaptive(light: NSColor(red: 0.07, green: 0.45, blue: 0.20, alpha: 1),
                                   dark: NSColor(red: 0.29, green: 0.87, blue: 0.50, alpha: 1))
        case .skipped: Theme.adaptive(light: NSColor(red: 0.62, green: 0.34, blue: 0.00, alpha: 1),
                                      dark: NSColor(red: 1.00, green: 0.70, blue: 0.25, alpha: 1))
        case .info: .secondary
        }
    }

    private var background: Color {
        switch tone {
        case .good: Theme.green.opacity(0.16)
        case .skipped: .orange.opacity(0.17)
        case .info: .secondary.opacity(0.14)
        }
    }
}
