import Foundation

/// Localized strings that contain placeholders.
///
/// The key is looked up in Localizable.xcstrings and then filled with `String(format:)`,
/// e.g. `L10n.format("Since %@", time)`.
enum L10n {
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: NSLocalizedString(key, comment: ""), locale: Locale.current, arguments: arguments)
    }
}

/// Date and time formats used across the app, following the user's locale.
enum Formatting {
    /// "08:12" (or "8:12 AM", depending on the region settings).
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "Thursday, 15 October"
    static func dayTitle(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// "Thu, 15 Oct"
    static func shortDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "October 2026"
    static func monthTitle(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide).year())
    }

    /// "15 Oct 2026"
    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .omitted)
    }

    /// "08:12 – 08:40" or "08:12 – now". Times on another day than `day` get a weekday prefix.
    static func range(start: Date, end: Date?, on day: Date, calendar: Calendar = .current) -> String {
        func label(_ date: Date) -> String {
            if calendar.isDate(date, inSameDayAs: day) {
                return time(date)
            }
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time(date))"
        }
        let endText = end.map(label) ?? String(localized: "now")
        return "\(label(start)) – \(endText)"
    }

    static func range(of segment: Segment, on day: Date) -> String {
        range(start: segment.start, end: segment.end, on: day)
    }
}
