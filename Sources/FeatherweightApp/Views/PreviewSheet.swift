import FeatherweightCore
import SwiftUI

/// What a dry run found: nothing has been changed.
struct PreviewSheet: View {
    let result: PreviewResult
    let activityWindowHours: Int
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch result {
            case .dedupe(let report): DedupePreview(report: report)
            case .clean(let report): CleanPreview(report: report, activityWindowHours: activityWindowHours)
            }
            HStack {
                Text("Nothing has been changed.").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
        .frame(minHeight: 260)
    }
}

private func projectName(_ root: String) -> String {
    URL(fileURLWithPath: root).lastPathComponent
}

private struct DedupePreview: View {
    let report: DedupeReport

    var body: some View {
        let rows = report.perProject.sorted { $0.value > $1.value }
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview: Share duplicates").font(.system(size: 15, weight: .semibold))
            if rows.isEmpty {
                Text("No duplicate files to share right now.").foregroundStyle(.secondary)
            } else {
                Text("\(report.filesReplaced) \(report.filesReplaced == 1 ? "file" : "files") in \(rows.count) \(rows.count == 1 ? "project" : "projects") would be shared, saving \(ByteFormat.string(report.bytesFreed)).")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                PreviewList(count: rows.count) {
                    ForEach(rows, id: \.key) { root, bytes in
                        PreviewRow(title: projectName(root), detail: (root as NSString).abbreviatingWithTildeInPath, trailing: ByteFormat.string(bytes))
                    }
                }
            }
            ErrorLines(errors: report.errors)
        }
    }
}

private struct CleanPreview: View {
    let report: CleanReport
    let activityWindowHours: Int

    var body: some View {
        let cleared = report.cleared.sorted { $0.allocatedBytes > $1.allocatedBytes }
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview: Clear build caches").font(.system(size: 15, weight: .semibold))
            if cleared.isEmpty {
                Text("No cache folders would be cleared right now.").foregroundStyle(.secondary)
            } else {
                Text("\(cleared.count) \(cleared.count == 1 ? "folder" : "folders") would be cleared, freeing \(ByteFormat.string(report.bytesFreed)).")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                PreviewList(count: cleared.count) {
                    ForEach(cleared, id: \.folder) { candidate in
                        PreviewRow(
                            title: "\(projectName(candidate.projectRoot))/\(candidate.relativePath)",
                            detail: nil, trailing: ByteFormat.string(candidate.allocatedBytes))
                    }
                }
            }
            if !report.skipped.isEmpty {
                Text("Skipped").sectionLabel()
                PreviewList(count: report.skipped.count) {
                    ForEach(report.skipped, id: \.folder) { candidate in
                        PreviewRow(
                            title: "\(projectName(candidate.projectRoot))/\(candidate.relativePath)",
                            detail: nil,
                            trailing: candidate.skip?.displayText(activityWindowHours: activityWindowHours) ?? "Skipped")
                    }
                }
            }
            ErrorLines(errors: report.errors)
        }
    }
}

private struct PreviewList<Content: View>: View {
    let count: Int
    @ViewBuilder var content: Content

    var body: some View {
        Group {
            if count > 5 {
                ScrollView { LazyVStack(spacing: 0) { content } }.frame(height: 210)
            } else {
                VStack(spacing: 0) { content }
            }
        }
        .padding(.horizontal, 10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

private struct PreviewRow: View {
    let title: String
    let detail: String?
    let trailing: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                    if let detail {
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 12)
                Text(trailing).font(.system(size: 12.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.vertical, 6)
            Divider()
        }
    }
}

private struct ErrorLines: View {
    let errors: [String]

    var body: some View {
        ForEach(Array(errors.prefix(5).enumerated()), id: \.offset) { _, error in
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11.5))
                .foregroundStyle(.orange)
        }
    }
}
