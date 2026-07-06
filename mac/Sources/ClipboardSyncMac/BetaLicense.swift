import Foundation

/// Hardcoded beta window: this build works for `durationDays` after `releaseDate`.
/// Bump `releaseDate` to today whenever a new build is cut for release.
enum BetaLicense {
    static let releaseDate = utcDate(year: 2026, month: 7, day: 3)
    static let durationDays = 30

    static var expiryDate: Date {
        Calendar(identifier: .gregorian).date(byAdding: .day, value: durationDays, to: releaseDate) ?? releaseDate
    }

    static var isExpired: Bool {
        Date() >= expiryDate
    }

    private static func utcDate(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components) ?? Date()
    }
}
