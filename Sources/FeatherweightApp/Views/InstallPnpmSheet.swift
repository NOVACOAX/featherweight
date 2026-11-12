import FeatherweightCore
import SwiftUI

/// Shown when pnpm is missing or older than 10. Says exactly what it will run, and runs it only on click.
struct InstallPnpmSheet: View {
    let session: ConversionSession
    let model: AppModel

    private var installing: Bool {
        if case .installingPnpm = session.phase { return true }
        return false
    }

    private var found: String? {
        if case .needsPnpm(let found) = session.phase { return found }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(found == nil ? "pnpm isn't installed" : "pnpm \(found ?? "") is too old")
                .font(.system(size: 15, weight: .semibold))
            Text(found == nil
                 ? "Converting \(session.name) needs pnpm \(PnpmToolchain.minimumMajor) or later. Featherweight can install it with Corepack, which comes with Node.js."
                 : "Converting \(session.name) needs pnpm \(PnpmToolchain.minimumMajor) or later. Featherweight can install a newer one with Corepack, which comes with Node.js.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Featherweight will run").sectionLabel()
                Text(PnpmToolchain.installCommands[0].joined(separator: " "))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                Text("If Corepack isn't available, it runs \(PnpmToolchain.installCommands[1].joined(separator: " ")) instead.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            if let error = session.installError {
                Label("pnpm wasn't installed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                DisclosureGroup("Command output") { CommandOutputBox(text: error, height: 120) }
                    .font(.system(size: 12))
            }

            HStack {
                if installing {
                    ProgressView().controlSize(.small)
                    Text("Installing pnpm…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.closeConversion() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(installing)
                Button("Install pnpm") { Task { await model.installPnpm(session) } }
                    .buttonStyle(AmberButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(installing)
            }
        }
    }
}
