import FeatherweightCore
import SwiftUI

/// The "Convert to pnpm…" sheet: shows whichever step of the flow the session is in.
struct ConversionSheet: View {
    let session: ConversionSession
    let model: AppModel

    var body: some View {
        Group {
            switch session.phase {
            case .checkingPnpm:
                ConversionWaiting(text: "Looking for pnpm…")
            case .needsPnpm, .installingPnpm:
                InstallPnpmSheet(session: session, model: model)
            case .confirm:
                ConvertConfirmSheet(session: session, model: model)
            case .running(let step):
                ConversionProgressSheet(session: session, current: step)
            case .failed(let failure):
                ConversionFailedView(
                    title: "Conversion failed at \(failure.step.displayText)",
                    message: failure.reverted
                        ? "Everything was put back the way it was."
                        : "Some files could not be put back. Featherweight kept the backup, so you can try Revert from the project later.",
                    failure: failure
                ) { model.closeConversion() }
            case .done(let result):
                ConversionDoneSheet(session: session, result: result, model: model)
            case .reverting:
                ConversionWaiting(text: "Putting \(session.name) back on \(session.summary.packageManager.rawValue)…")
            case .revertFailed(let failure):
                ConversionFailedView(
                    title: "Revert failed",
                    message: failure.reverted
                        ? "The files were restored, but reinstalling node_modules failed. Run the install yourself to finish."
                        : "Some files could not be put back. The backup is still there, so you can try again from the project.",
                    failure: failure
                ) { model.closeConversion() }
            }
        }
        .padding(22)
        .frame(width: 560)
        .interactiveDismissDisabled()
    }
}

/// A spinner with one line of text.
struct ConversionWaiting: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }
}

/// Monospaced command output in a scrolling box.
struct CommandOutputBox: View {
    let text: String
    var height: CGFloat = 160

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text.isEmpty ? "No output." : text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(height: height)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}
