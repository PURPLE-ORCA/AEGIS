import SwiftUI

enum NotchMotion {
    static let sessionCardDuration: TimeInterval = 0.20
    static let reducedMotionDuration: TimeInterval = 0.12

    static var sessionCard: Animation {
        .timingCurve(0.23, 1, 0.32, 1, duration: sessionCardDuration)
    }

    static var reducedSessionCard: Animation {
        .easeOut(duration: reducedMotionDuration)
    }
}
