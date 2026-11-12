import FeatherweightCore
import SwiftUI

/// The conversion running: each step with its state, and a live log of the commands.
struct ConversionProgressSheet: View {
    let session: ConversionSession
    let current: ConversionStep

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Converting \(session.name) to pnpm").font(.system(size: 15, weight: .semibold))
            if session.waitingForLock {
                Label("Waiting for another Featherweight job to finish…", systemImage: "hourglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                let steps = session.steps
                let currentIndex = steps.firstIndex(of: current) ?? 0
                ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                    HStack(spacing: 8) {
                        Group {
                            if index < currentIndex {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                            } else if index == currentIndex && !session.waitingForLock {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "circle").foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 16)
                        Text(step.displayText.prefix(1).uppercased() + step.displayText.dropFirst())
                            .font(.system(size: 12.5))
                            .foregroundStyle(index <= currentIndex ? .primary : .secondary)
                    }
                }
            }
            LiveLog(lines: session.log)
            Text("Don't edit the project until this finishes.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
        }
    }
}

/// The command log, kept scrolled to the newest line.
private struct LiveLog: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("$ ") ? .primary : .secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(8)
            }
            .frame(height: 170)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .onChange(of: lines.count) { _, count in
                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
            }
        }
    }
}

/// A conversion or revert that failed, with the failing command's output behind a disclosure.
struct ConversionFailedView: View {
    let title: String
    let message: String
    let failure: ConversionFailure
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.orange)
            Text(message).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Command output") {
                CommandOutputBox(text: (failure.command.isEmpty ? "" : "$ \(failure.command)\n") + failure.output)
            }
            .font(.system(size: 12))
            HStack {
                Spacer()
                Button("Close", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
    }
}
