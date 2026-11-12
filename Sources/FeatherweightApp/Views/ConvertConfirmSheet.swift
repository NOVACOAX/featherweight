import FeatherweightCore
import SwiftUI

/// "Convert <name> to pnpm?": the steps, the warning about collaborators and the build check option.
struct ConvertConfirmSheet: View {
    @Bindable var session: ConversionSession
    let model: AppModel

    private var steps: [String] {
        var steps = [
            "Back up \(session.oldLockfile) and every file it changes, so you can revert",
            "Create pnpm-lock.yaml from it (pnpm import)",
            "Reinstall node_modules with pnpm",
        ]
        steps.append(session.runBuildCheck && session.hasBuildScript
                     ? "Run the build script to check it still works"
                     : "Check that the project's install succeeded")
        steps.append("Update CI, Docker and deploy configs that mention \(session.summary.packageManager.rawValue)")
        return steps
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Convert \(session.name) to pnpm?").font(.system(size: 15, weight: .semibold))
            Text("Your installed versions stay exactly the same. pnpm keeps one shared copy of each package, so this project will use less space.")
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(Theme.amber.opacity(0.18), in: Circle())
                            .foregroundStyle(Theme.amberText)
                        Text(step).font(.system(size: 12.5))
                    }
                }
            }

            Label("Anyone who clones this project from GitHub will need pnpm to install it.", systemImage: "person.2.fill")
                .font(.system(size: 12))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            if session.hasBuildScript {
                Toggle("Run the build script to check it still works", isOn: $session.runBuildCheck)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5))
            }

            HStack {
                Spacer()
                Button("Cancel") { model.closeConversion() }.keyboardShortcut(.cancelAction)
                Button("Convert") { Task { await model.convert(session) } }
                    .buttonStyle(AmberButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
