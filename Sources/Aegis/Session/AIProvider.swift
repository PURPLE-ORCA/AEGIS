import SwiftUI

/// An AI coding agent supported by Aegis.
struct AIProvider: Identifiable, Hashable {
    enum QuestionResponseMode: Hashable {
        case inline
        case providerApp
    }

    let id: String
    let displayName: String
    let accentColor: Color
    let mascotPalette: PixelMascot.MascotPalette
    let activeMascotPalette: PixelMascot.MascotPalette
    let mascotShape: PixelMascot.MascotShape
    let questionResponseMode: QuestionResponseMode

    static let codex = AIProvider(
        id: "codex",
        displayName: "Codex",
        accentColor: Color(red: 0.92, green: 0.92, blue: 0.92),
        mascotPalette: .codex,
        activeMascotPalette: .codexActive,
        mascotShape: .box,
        questionResponseMode: .providerApp
    )

    static let hermes = AIProvider(
        id: "hermes",
        displayName: "Hermes",
        accentColor: Color(red: 0.953, green: 0.722, blue: 0.196),
        mascotPalette: .hermes,
        activeMascotPalette: .hermesActive,
        mascotShape: .hermesWing,
        questionResponseMode: .providerApp
    )

    static let opencode = AIProvider(
        id: "opencode",
        displayName: "OpenCode",
        accentColor: Color(red: 0.62, green: 0.62, blue: 0.64),
        mascotPalette: .opencode,
        activeMascotPalette: .opencodeActive,
        mascotShape: .openCodeMark,
        questionResponseMode: .inline
    )

    static let antigravity = AIProvider(
        id: "antigravity",
        displayName: "AntiGravity",
        accentColor: Color(red: 0.259, green: 0.522, blue: 0.957),
        mascotPalette: .antigravity,
        activeMascotPalette: .antigravityActive,
        mascotShape: .antigravityOrbit,
        questionResponseMode: .inline
    )

    static let all: [AIProvider] = [.codex, .hermes, .opencode, .antigravity]

    static func from(_ source: String?) -> AIProvider {
        guard let source, let provider = all.first(where: { $0.id == source }) else {
            return .codex
        }
        return provider
    }

    var permissionActions: [PermissionAction] {
        switch id {
        case "codex": return [.deny, .allowOnce, .allowAll, .bypass]
        case "opencode": return [.deny, .allowOnce, .allowAll]
        default: return [.deny, .allowOnce]
        }
    }
}
