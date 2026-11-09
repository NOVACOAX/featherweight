import FeatherweightCore
import SwiftUI

struct OverviewView: View {
    let model: AppModel
    @State private var showsCaveat = false

    private static let caveat = "Finder's Get Info still shows each node_modules at full size, because it adds up every file without knowing they share space. Saving now is the real figure."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                jobCards
                recentActivity
            }
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Overview")
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 32) {
            // Top-aligned, so the two labels share a line whatever size the numbers are.
            HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text("Saving now").sectionLabel()
                    Button { showsCaveat.toggle() } label: {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Why Finder shows a bigger number")
                    .accessibilityLabel("About this number")
                    .popover(isPresented: $showsCaveat, arrowEdge: .bottom) {
                        Text(Self.caveat)
                            .font(.system(size: 12))
                            .frame(width: 260, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                    }
                }
                .frame(height: 18)
                BigBytes(bytes: model.savings?.sharedBytes ?? 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Caches cleared this month").sectionLabel().frame(height: 18)
                BigBytes(bytes: model.cachesClearedThisMonth, size: 28)
            }
            }
            Spacer(minLength: 0)
            DriveSummary(disk: model.disk, name: model.volumeName)
        }
    }

    // MARK: Jobs

    private var jobCards: some View {
        let now = Date()
        let calendar = Calendar.current
        let paused = model.settings.paused
        func last(_ kind: JobKind) -> String {
            guard let record = model.history.first(where: { $0.kind == kind }) else { return "Never" }
            return "\(DateText.past(record.finishedAt, now: now)) · freed \(ByteFormat.string(record.bytesFreed))"
        }
        func next(_ schedule: Schedule) -> String {
            DateText.future(schedule.nextRun(after: now, calendar: calendar), now: now)
        }
        // A grid, so both cards take the height of the taller one.
        return Grid(horizontalSpacing: 14) {
            GridRow {
            JobCard(
                title: "Share duplicates",
                blurb: "Identical files across node_modules share one copy on disk.",
                lastRun: last(.dedupe),
                nextRun: paused ? "Paused" : "After your next install · \(next(model.settings.dedupeSchedule))",
                primaryTitle: "Run now",
                isRunning: model.runningJob == .dedupe, isBusy: model.runningJob != nil,
                isWaiting: model.waitingForLock,
                onPrimary: { Task { await model.runDedupe(preview: false) } },
                onPreview: { Task { await model.runDedupe(preview: true) } })
            JobCard(
                title: "Clear build caches",
                blurb: "Deletes .next, .vite, .turbo and the other cache folders you've chosen.",
                lastRun: last(.clean),
                nextRun: paused ? "Paused" : next(model.settings.cleanSchedule),
                primaryTitle: "Clear now",
                isRunning: model.runningJob == .clean, isBusy: model.runningJob != nil,
                isWaiting: model.waitingForLock,
                onPrimary: { Task { await model.runClean(preview: false) } },
                onPreview: { Task { await model.runClean(preview: true) } })
            }
        }
    }

    // MARK: Recent activity

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent activity").sectionLabel().padding(.top, 4)
            if model.history.isEmpty {
                Text("Nothing has run yet.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 9)
            } else {
                let recent = Array(model.history.prefix(5))
                ForEach(recent) { record in
                    ActivityRow(record: record).padding(.vertical, 9)
                    if record.id != recent.last?.id { Divider() }
                }
            }
        }
    }
}

private struct DriveSummary: View {
    let disk: (free: Int64, total: Int64)?
    let name: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(name ?? "Drive").sectionLabel()
            if let disk {
                let used = disk.total > 0 ? 1 - Double(disk.free) / Double(disk.total) : 0
                Text("\(ByteFormat.string(disk.free)) free")
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .padding(.top, 2)
                Capsule().fill(.quaternary)
                    .frame(width: 200, height: 6)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(used > 0.9
                                ? LinearGradient(colors: [.orange, .red], startPoint: .leading, endPoint: .trailing)
                                : LinearGradient(colors: [Theme.amber, Theme.amber], startPoint: .leading, endPoint: .trailing))
                            .frame(width: 200 * min(max(used, 0), 1))
                    }
                    .padding(.vertical, 2)
                Text("of \(ByteFormat.string(disk.total))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("Not available").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct NoticeBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 12)).textSelection(.enabled)
            Spacer(minLength: 8)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.35)))
    }
}
