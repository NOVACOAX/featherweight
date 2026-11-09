import FeatherweightCore
import SwiftUI

struct ActivityView: View {
    let model: AppModel

    var body: some View {
        Group {
            if model.history.isEmpty {
                ContentUnavailableView(
                    "No activity yet", systemImage: "clock",
                    description: Text("Jobs show up here after they run."))
            } else {
                List(model.history) { record in
                    ActivityRow(record: record, showsErrors: true)
                        .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Activity")
    }
}

/// One finished job: icon, summary, amount freed and when. With `showsErrors`, any problems the
/// job hit are listed under the summary.
struct ActivityRow: View {
    let record: RunRecord
    var showsErrors = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: record.kind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(record.kind == .convert || record.kind == .revert ? Theme.green : Theme.amberText)
                .frame(width: 24, height: 24)
                .background(record.kind.tint.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(record.summary).font(.system(size: 12.5)).frame(minHeight: 24, alignment: .leading)
                if showsErrors {
                    ForEach(Array(record.errors.enumerated()), id: \.offset) { _, error in
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 8)
            if record.bytesFreed > 0 {
                Text("+" + ByteFormat.string(record.bytesFreed))
                    .frame(height: 24)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.amberText)
                    .monospacedDigit()
            }
            Text(DateText.activity(record.finishedAt))
                .frame(height: 24)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
                .help(record.finishedAt.formatted(date: .abbreviated, time: .shortened))
        }
        .accessibilityElement(children: .combine)
    }
}
