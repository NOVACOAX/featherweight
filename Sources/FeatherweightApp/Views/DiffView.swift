import SwiftUI

/// A unified diff with added lines in green and removed lines in red. Very long diffs (an added
/// pnpm-lock.yaml) show their first lines only.
struct DiffView: View {
    let diff: String
    var maxLines = 1_500

    var body: some View {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let shown = lines.prefix(maxLines)
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(color(for: line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                        .background(background(for: line))
                }
                if lines.count > maxLines {
                    Text("… \(lines.count - maxLines) more lines")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
            }
            .textSelection(.enabled)
            .padding(.vertical, 4)
        }
        .frame(height: 200)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("@@") { return .secondary }
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("+") { return Theme.green }
        if line.hasPrefix("-") { return .red }
        return .primary
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return Theme.green.opacity(0.08) }
        if line.hasPrefix("-") { return Color.red.opacity(0.08) }
        return .clear
    }
}
