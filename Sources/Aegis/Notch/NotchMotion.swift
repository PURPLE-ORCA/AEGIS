import SwiftUI

enum NotchMotion {
    static let sessionCardHoverDelay: TimeInterval = 0.08
    static let sessionCardDuration: TimeInterval = 0.20
    static let sessionCardCollapseDuration: TimeInterval = 0.16
    static let reducedMotionDuration: TimeInterval = 0.12

    static var sessionCard: Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: sessionCardDuration)
    }

    static var sessionCardCollapse: Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: sessionCardCollapseDuration)
    }

    static var reducedSessionCard: Animation {
        .easeOut(duration: reducedMotionDuration)
    }
}
