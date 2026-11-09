import SwiftUI

/// One of the two jobs on the Overview: what it does, when it last ran, when it runs next.
struct JobCard: View {
    let title: String
    let blurb: String
    let lastRun: String
    let nextRun: String
    let primaryTitle: String
    /// This card's job is the one running.
    let isRunning: Bool
    /// Some job is running, so no button on any card can start another.
    let isBusy: Bool
    let isWaiting: Bool
    let onPrimary: () -> Void
    let onPreview: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(blurb)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                    .fixedSize(horizontal: false, vertical: true)

                Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 4) {
                    GridRow {
                        Text("Last run").foregroundStyle(.secondary)
                        Text(lastRun)
                    }
                    GridRow {
                        Text("Next").foregroundStyle(.secondary)
                        Text(nextRun).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.system(size: 12))
                .padding(.bottom, 14)

                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Button(action: onPrimary) {
                        HStack(spacing: 6) {
                            if isRunning { ProgressView().controlSize(.mini) }
                            Text(primaryTitle)
                        }
                    }
                    .buttonStyle(AmberButtonStyle())
                    Button("Preview", action: onPreview)
                    if isRunning {
                        Text(isWaiting ? "Waiting for another job to finish…" : "Working…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(isBusy)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
