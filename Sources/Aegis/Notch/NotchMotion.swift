import SwiftUI

enum NotchMotion {
    static let panelResizeDuration: TimeInterval = 0.20
    static let finishedCardOpenDuration: TimeInterval = 0.12
    static let sessionCardHoverDelay: TimeInterval = 0.08
    static let sessionCardHoverExitGrace: TimeInterval = 0.06
    static let sessionCardMorphDuration: TimeInterval = 0.18
    static let reducedMotionDuration: TimeInterval = 0.12

    static var sessionCardMorph: Animation {
        .timingCurve(0.77, 0, 0.175, 1, duration: sessionCardMorphDuration)
    }

    static var reducedSessionCard: Animation {
        .easeOut(duration: reducedMotionDuration)
    }

    /// Smoothstep gives frequent island resizing a short, non-bouncy
    /// ease-in-out curve without creating a persistent physics simulation.
    static func panelResizeProgress(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}

struct SessionCardDetailPresentation: Equatable {
    let keepsContentMounted: Bool
    let height: CGFloat
    let opacity: Double

    static func resolve(
        measuredHeight: CGFloat,
        isExpanded: Bool
    ) -> SessionCardDetailPresentation {
        SessionCardDetailPresentation(
            keepsContentMounted: true,
            height: isExpanded ? measuredHeight : 0,
            opacity: isExpanded ? 1 : 0
        )
    }
}
