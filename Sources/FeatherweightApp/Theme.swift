import FeatherweightCore
import SwiftUI

enum Theme {
    /// The logo's amber, #F59E0B.
    static let amber = Color(red: 0.961, green: 0.620, blue: 0.043)
    /// Lighter amber for text on dark backgrounds.
    static let amberText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.988, green: 0.827, blue: 0.302, alpha: 1)
            : NSColor(red: 0.706, green: 0.325, blue: 0.035, alpha: 1)
    })
    static let green = Color(red: 0.188, green: 0.820, blue: 0.345)
    static let cardRadius: CGFloat = 10

    /// A colour that is `light` in the light appearance and `dark` in the dark one.
    static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

extension JobKind {
    var symbol: String {
        switch self {
        case .dedupe: "square.on.square"
        case .clean: "sparkles"
        case .convert: "checkmark"
        case .revert: "arrow.uturn.backward"
        }
    }

    var tint: Color {
        switch self {
        case .dedupe, .clean: Theme.amber
        case .convert, .revert: Theme.green
        }
    }
}

/// The primary action on a card: amber with dark text, as in the logo.
struct AmberButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color(red: 0.11, green: 0.075, blue: 0))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Theme.amber.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 6))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A bordered panel, used for the job cards and the drive card.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(.separator))
    }
}

extension Text {
    /// Small uppercase caption, like "SAVING NOW".
    func sectionLabel() -> some View {
        font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// Splits "2.8 GB" into "2.8" and "GB" so the unit can be set smaller.
struct BigBytes: View {
    let bytes: Int64
    var size: CGFloat = 44

    var body: some View {
        let parts = ByteFormat.string(bytes).split(separator: " ", maxSplits: 1).map(String.init)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(parts.first ?? "0")
                .font(.system(size: size, weight: .bold))
                .tracking(-0.02 * size)
            if parts.count > 1 {
                Text(parts[1])
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ByteFormat.string(bytes))
    }
}

// MARK: - Dates

enum DateText {
    private static func formatter(_ template: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    private static func time(_ date: Date, _ calendar: Calendar) -> String {
        formatter("jmm", calendar).string(from: date)
    }

    /// A moment in the past: "Today, 3:00 AM", "Yesterday, 3:00 AM", "Sun, 3:00 AM", "15 Nov, 3:00 AM".
    static func past(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            day = "Yesterday"
        } else if now.timeIntervalSince(date) < 6 * 86_400 {
            day = formatter("EEE", calendar).string(from: date)
        } else {
            day = formatter("dMMM", calendar).string(from: date)
        }
        return "\(day), \(time(date, calendar))"
    }

    /// A moment in the future: "Today, 3:00 AM", "Tomorrow, 3:00 AM", "Sun 15 Nov, 3:00 AM".
    static func future(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            day = "Tomorrow"
        } else {
            day = formatter("EEEdMMM", calendar).string(from: date)
        }
        return "\(day), \(time(date, calendar))"
    }

    /// Short form for lists: "2 hr. ago", "Yesterday", "Sun", "15 Nov".
    static func activity(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let age = now.timeIntervalSince(date)
        if age < 12 * 3_600 {
            if age < 60 { return "Just now" }
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .short
            return relative.localizedString(for: date, relativeTo: now)
        }
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if age < 6 * 86_400 { return formatter("EEE", calendar).string(from: date) }
        return formatter("dMMM", calendar).string(from: date)
    }

    /// For tables: "2 hours ago", "5 days ago", "1 month ago".
    static func ago(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        let relative = RelativeDateTimeFormatter()
        relative.unitsStyle = .full
        relative.dateTimeStyle = .numeric
        return relative.localizedString(for: date, relativeTo: now)
    }

    /// "daily at 3:00 AM", "Sundays at 3:00 AM".
    static func schedule(_ schedule: Schedule, calendar: Calendar = .current) -> String {
        let moment = calendar.date(from: DateComponents(hour: schedule.hour, minute: schedule.minute)) ?? Date()
        let at = time(moment, calendar)
        switch schedule.frequency {
        case .daily:
            return "daily at \(at)"
        case .weekly:
            let names = calendar.weekdaySymbols
            let name = names[min(max(schedule.weekday, 1), names.count) - 1]
            return "\(name)s at \(at)"
        }
    }
}

// MARK: - Logo

/// The Featherweight mark, drawn from the same shapes as `featherweight-logo.svg`.
struct FeatherweightLogo: View {
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 200
            func polygon(_ points: [(Double, Double)]) -> Path {
                var path = Path()
                for (index, point) in points.enumerated() {
                    let p = CGPoint(x: point.0 * scale, y: point.1 * scale)
                    index == 0 ? path.move(to: p) : path.addLine(to: p)
                }
                path.closeSubpath()
                return path
            }
            func color(_ hex: UInt32, _ alpha: Double = 1) -> Color {
                Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                      blue: Double(hex & 0xFF) / 255, opacity: alpha)
            }

            let tile = Path(roundedRect: CGRect(x: 4 * scale, y: 4 * scale, width: 192 * scale, height: 192 * scale),
                            cornerRadius: 44 * scale)
            context.fill(tile, with: .linearGradient(
                Gradient(colors: [color(0x334155), color(0x0F172A)]),
                startPoint: CGPoint(x: 0, y: 4 * scale), endPoint: CGPoint(x: 0, y: 196 * scale)))

            let dashed = StrokeStyle(lineWidth: 5 * scale, dash: [10 * scale, 8 * scale])
            let ghost = color(0xFBBF24, 0.45)
            context.stroke(polygon([(76, 52), (117.6, 76), (117.6, 124), (76, 148), (34.4, 124), (34.4, 76)]),
                           with: .color(ghost), style: dashed)
            context.stroke(polygon([(124, 52), (165.6, 76), (165.6, 124), (124, 148), (82.4, 124), (82.4, 76)]),
                           with: .color(ghost), style: dashed)

            let hexagon = [(100.0, 56.0), (138, 78), (138, 122), (100, 144), (62, 122), (62, 78)]
            context.fill(polygon(hexagon), with: .linearGradient(
                Gradient(colors: [color(0xFDE68A), color(0xF59E0B)]),
                startPoint: CGPoint(x: 62 * scale, y: 56 * scale), endPoint: CGPoint(x: 138 * scale, y: 144 * scale)))
            context.fill(polygon([(100, 56), (138, 78), (100, 100), (62, 78)]), with: .color(.white.opacity(0.35)))
            context.fill(polygon([(100, 100), (138, 78), (138, 122), (100, 144)]), with: .color(color(0x92400E, 0.35)))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
