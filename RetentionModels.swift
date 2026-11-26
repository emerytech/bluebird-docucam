import Foundation

/// Local-only onboarding progress. Nothing is uploaded or attached to a purchase.
struct LessonProgress: Codable, Equatable {
    var sawCamera = false
    var presented = false
    var savedWork = false
    var complete: Bool { sawCamera && presented && savedWork }
}

/// Normalized pan survives a change in window size. Capture/recording settings are deliberately
/// excluded: applying a classroom preset must never start a recording or change its destination.
struct ClassroomPreset: Codable, Equatable {
    var name: String
    var cameraID: String?
    var rotation: Int
    var flipH: Bool
    var flipV: Bool
    var fill: Bool
    var zoom: Double
    var panX: Double
    var panY: Double

    var safeZoom: Double { zoom.isFinite ? min(8, max(1, zoom)) : 1 }
    func safePan(_ value: Double) -> Double {
        value.isFinite ? min((safeZoom - 1) / 2, max(-(safeZoom - 1) / 2, value)) : 0
    }
}

enum TrialReminderPolicy {
    /// Remind two days before the verified trial ends. If enabled late, remind in one minute,
    /// only when at least an hour remains. Never schedule a reminder after expiry.
    static func fireDate(end: Date, now: Date = Date()) -> Date? {
        guard end.timeIntervalSince(now) > 3600 else { return nil }
        return max(end.addingTimeInterval(-2 * 86400), now.addingTimeInterval(60))
    }
}
