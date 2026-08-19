import SwiftUI
import Combine

/// One shared animation source for every visible mascot. Idle mascots do not
/// subscribe, so a quiet notch has no mascot timer or main-run-loop wakeups.
let mascotAnimationClock = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()

/// Pixel-art mascot view. Each supported provider has its own silhouette.
struct PixelMascot: View {
    var size: CGFloat = 16
    var palette: MascotPalette = .codex
    var shape: MascotShape = .box
    var animate: Bool = false
    /// Pulls the Web-Slinger mask over the Codex mascot.
    var masked: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animPhase: Int = 0

    enum MascotShape {
        case box         // Codex — chunky cube with head bump + 1 eye + 2 stubby feet
        case openCodeMark // OpenCode — dark terminal box w/ "-O-" face + feet
        case antigravityOrbit // AntiGravity — blue planet floating in an orbit ring
        case hermesWing  // Hermes — gold winged messenger helmet
    }

    enum MascotPalette {
        case codex, opencode, antigravity, hermes
        case codexActive, opencodeActive
        case antigravityActive, hermesActive
        case error
        case waiting

        var body: Color {
            switch self {
            case .codex:            return Color(red: 0.92, green: 0.92, blue: 0.92)
            case .codexActive:      return Color(red: 0.60, green: 0.85, blue: 1.00)  // bright sky blue
            case .opencode:         return Color(red: 0.220, green: 0.220, blue: 0.240)  // #383838 dark gray
            case .opencodeActive:   return Color(red: 0.345, green: 0.345, blue: 0.365)  // lighter when active
            case .antigravity:      return Color(red: 0.259, green: 0.522, blue: 0.957)
            case .antigravityActive: return Color(red: 0.451, green: 0.667, blue: 1.000)
            case .hermes:           return Color(red: 0.953, green: 0.722, blue: 0.196)
            case .hermesActive:     return Color(red: 1.000, green: 0.831, blue: 0.353)
            case .error:            return Color(red: 0.90, green: 0.35, blue: 0.30)
            case .waiting:          return Color(red: 1.00, green: 0.72, blue: 0.30)
            }
        }

        var eyes: Color { .black }
    }

    @ViewBuilder
    var body: some View {
        if animate && !reduceMotion {
            mascot
                .onReceive(mascotAnimationClock) { _ in
                    animPhase = (animPhase + 1) % 4
                }
        } else {
            mascot
        }
    }

    private var mascot: some View {
        Canvas { context, canvasSize in
            switch shape {
            case .box:
                drawBox(context: context, canvasSize: canvasSize)
                if masked { drawBoxMask(context: context, canvasSize: canvasSize) }
            case .openCodeMark: drawShape(context, canvasSize, 50, drawOpenCodeMark)
            case .antigravityOrbit: drawShape(context, canvasSize, 52, drawAntigravityOrbit)
            case .hermesWing:  drawShape(context, canvasSize, 58, drawHermesWing)
            }
        }
        .frame(width: aspectAdjustedWidth, height: size)
    }

    private var aspectAdjustedWidth: CGFloat {
        switch shape {
        case .box:         return size * (58.0 / 52.0)
        case .openCodeMark: return size * (50.0 / 52.0)
        case .antigravityOrbit: return size
        case .hermesWing:  return size * (58.0 / 52.0)
        }
    }

    /// Shared helper for the provider mascots: sets up the 52-tall logical
    /// transform + a `fill` closure and hands them to a per-shape draw block.
    private func drawShape(_ context: GraphicsContext, _ canvasSize: CGSize, _ logicalWidth: CGFloat,
                           _ draw: (GraphicsContext, (CGRect, Color) -> Void) -> Void) {
        let scale = size / 52.0
        let xOffset = (canvasSize.width - logicalWidth * scale) / 2
        // Thinking bounce: gently bob the whole body up and down.
        let bob: CGFloat = animate ? [0, -1.5, -3, -1.5][animPhase % 4] : 0
        let t = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: bob)
        func fill(_ rect: CGRect, _ color: Color) {
            context.fill(Path(rect).applying(t), with: .color(color))
        }
        draw(context, fill)
    }

    // MARK: - Box (Codex)
    // Chunky cube — head bump, wide body, ">" eye + "_" mouth, two stubby feet.
    // Logical space is 58×52 for a compact notch footprint.
    private func drawBox(context: GraphicsContext, canvasSize: CGSize) {
        let scale = size / 52.0
        let xOffset = (canvasSize.width - 58 * scale) / 2
        let t = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0)

        func fill(_ rect: CGRect, _ color: Color) {
            context.fill(Path(rect).applying(t), with: .color(color))
        }

        // Head bump (centered)
        fill(CGRect(x: 23, y: 0, width: 12, height: 7), palette.body)

        // Shoulders — narrower top of the body
        fill(CGRect(x: 6, y: 7, width: 46, height: 7), palette.body)

        // Wide main body fills the available canvas.
        fill(CGRect(x: 0, y: 14, width: 58, height: 28), palette.body)

        // Terminal-prompt face: ">" on the left, "_" on the right.
        // ">" — three 5×5 blocks forming a chevron
        fill(CGRect(x:  9, y: 19, width: 5, height: 5), palette.eyes)
        fill(CGRect(x: 14, y: 24, width: 5, height: 5), palette.eyes)
        fill(CGRect(x:  9, y: 29, width: 5, height: 5), palette.eyes)
        // "_" — horizontal bar
        fill(CGRect(x: 32, y: 31, width: 15, height: 4), palette.eyes)

        // Two stubby feet — walking animation bobs them up/down
        let baseY: CGFloat = 42
        let footHeight: CGFloat = 10
        let footOffsets: [[CGFloat]] = [[2, -2], [0, 0], [-2, 2], [0, 0]]
        let off = animate ? footOffsets[animPhase % 4] : [0, 0]
        fill(CGRect(x: 14, y: baseY, width: 10, height: footHeight + off[0]), palette.body)
        fill(CGRect(x: 34, y: baseY, width: 10, height: footHeight + off[1]), palette.body)
    }

    // MARK: - Web-Slinger mask

    // The one sanctioned exception to "themes never touch mascots". Drawn on top
    // of the finished mascot, so it covers the eyes the shape already painted.
    // Only the Codex box wears one; the other silhouettes do not have a face
    // shape that reads clearly beneath the overlay.

    private static let maskRed  = Color(red: 0.902, green: 0.141, blue: 0.161)
    private static let maskSeam = Color(red: 0.039, green: 0.047, blue: 0.086)
    private static let maskLens = Color(red: 0.957, green: 0.969, blue: 1.000)

    /// Box: same treatment, hemmed high enough that the terminal-prompt face
    /// still peeks out below like a mouth under the mask.
    private func drawBoxMask(context: GraphicsContext, canvasSize: CGSize) {
        let scale = size / 52.0
        let xOffset = (canvasSize.width - 58 * scale) / 2
        let t = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: xOffset / scale, y: 0)
        func fill(_ rect: CGRect, _ color: Color) {
            context.fill(Path(rect).applying(t), with: .color(color))
        }
        // Follows the box's own silhouette: head bump, shoulders, upper body.
        fill(CGRect(x: 23, y: 0,  width: 12, height: 7),  Self.maskRed)
        fill(CGRect(x: 6,  y: 7,  width: 46, height: 7),  Self.maskRed)
        fill(CGRect(x: 0,  y: 14, width: 58, height: 16), Self.maskRed)
        fill(CGRect(x: 0,  y: 30, width: 58, height: 2),  Self.maskSeam)
        fill(CGRect(x: 28, y: 0,  width: 2,  height: 30), Self.maskSeam)
        // Outlined lenses stay readable over the red mask.
        fill(CGRect(x: 5,  y: 15, width: 20, height: 12), Self.maskSeam)
        fill(CGRect(x: 33, y: 15, width: 20, height: 12), Self.maskSeam)
        fill(CGRect(x: 6,  y: 16, width: 18, height: 10), Self.maskLens)
        fill(CGRect(x: 34, y: 16, width: 18, height: 10), Self.maskLens)
    }

    private func drawOpenCodeMark(_ context: GraphicsContext, _ fill: (CGRect, Color) -> Void) {
        let frame = Color(red: 0.55, green: 0.55, blue: 0.57)  // light-gray bezel
        let face  = Color(red: 0.85, green: 0.85, blue: 0.87)  // light face wells
        let foot  = Color(red: 0.35, green: 0.35, blue: 0.37)  // darker legs

        // Light frame/bezel (body insets to leave a 2px edge)
        fill(CGRect(x: 1,  y: 4,  width: 48, height: 34), frame)
        // Dark monitor body
        fill(CGRect(x: 3,  y: 6,  width: 44, height: 30), palette.body)
        // Top bezel highlight strip
        fill(CGRect(x: 3,  y: 6,  width: 44, height: 3),  frame)

        // "-O-" terminal face
        fill(CGRect(x: 12, y: 16, width: 5,  height: 11), face)  // left bar eye
        fill(CGRect(x: 22, y: 18, width: 6,  height: 6),  face)  // center "O"
        fill(CGRect(x: 33, y: 16, width: 5,  height: 11), face)  // right bar eye
        fill(CGRect(x: 13, y: 19, width: 3,  height: 5),  palette.eyes)
        fill(CGRect(x: 34, y: 19, width: 3,  height: 5),  palette.eyes)

        // Two stubby feet
        fill(CGRect(x: 11, y: 38, width: 8,  height: 8),  foot)
        fill(CGRect(x: 31, y: 38, width: 8,  height: 8),  foot)
    }

    private func drawAntigravityOrbit(_ context: GraphicsContext, _ fill: (CGRect, Color) -> Void) {
        let body = palette.body
        let edge = Color(red: 0.55, green: 0.74, blue: 1.00)
        let ring = Color(red: 0.78, green: 0.82, blue: 0.90)
        let ringDk = Color(red: 0.50, green: 0.54, blue: 0.64)
        let face = Color(red: 0.92, green: 0.96, blue: 1.00)
        let spark = Color(red: 1.00, green: 0.96, blue: 0.70)
        fill(CGRect(x: 4,  y: 16, width: 6,  height: 4),  ringDk)
        fill(CGRect(x: 42, y: 16, width: 6,  height: 4),  ringDk)
        fill(CGRect(x: 10, y: 13, width: 32, height: 4),  ringDk)
        fill(CGRect(x: 18, y: 13, width: 16, height: 4),  body)
        fill(CGRect(x: 12, y: 17, width: 28, height: 5),  body)
        fill(CGRect(x: 9,  y: 22, width: 34, height: 12), body)
        fill(CGRect(x: 12, y: 34, width: 28, height: 5),  body)
        fill(CGRect(x: 18, y: 39, width: 16, height: 4),  body)
        fill(CGRect(x: 12, y: 17, width: 24, height: 2),  edge)
        fill(CGRect(x: 9,  y: 22, width: 3,  height: 8),  edge)
        fill(CGRect(x: 2,  y: 30, width: 8,  height: 4),  ring)
        fill(CGRect(x: 42, y: 30, width: 8,  height: 4),  ring)
        fill(CGRect(x: 6,  y: 33, width: 40, height: 4),  ring)
        fill(CGRect(x: 17, y: 23, width: 5,  height: 7),  face)
        fill(CGRect(x: 30, y: 23, width: 5,  height: 7),  face)
        fill(CGRect(x: 18, y: 24, width: 3,  height: 4),  palette.eyes)
        fill(CGRect(x: 31, y: 24, width: 3,  height: 4),  palette.eyes)
        fill(CGRect(x: 46, y: 4,  width: 2,  height: 6),  spark)
        fill(CGRect(x: 44, y: 6,  width: 6,  height: 2),  spark)
    }

    // MARK: - Hermes (winged helmet)
    private func drawHermesWing(_ context: GraphicsContext, _ fill: (CGRect, Color) -> Void) {
        let helm = palette.body
        let edge = Color(red: 1.00, green: 0.86, blue: 0.42)
        let dark = Color(red: 0.72, green: 0.50, blue: 0.10)
        let wing = Color(red: 0.96, green: 0.97, blue: 1.00)
        let wingDk = Color(red: 0.74, green: 0.80, blue: 0.90)
        let visor = Color(red: 0.20, green: 0.16, blue: 0.06)
        fill(CGRect(x: 0,  y: 14, width: 12, height: 4),  wing)
        fill(CGRect(x: 2,  y: 18, width: 12, height: 4),  wing)
        fill(CGRect(x: 5,  y: 22, width: 11, height: 4),  wing)
        fill(CGRect(x: 0,  y: 17, width: 12, height: 1),  wingDk)
        fill(CGRect(x: 2,  y: 21, width: 12, height: 1),  wingDk)
        fill(CGRect(x: 46, y: 14, width: 12, height: 4),  wing)
        fill(CGRect(x: 44, y: 18, width: 12, height: 4),  wing)
        fill(CGRect(x: 42, y: 22, width: 11, height: 4),  wing)
        fill(CGRect(x: 46, y: 17, width: 12, height: 1),  wingDk)
        fill(CGRect(x: 44, y: 21, width: 12, height: 1),  wingDk)
        fill(CGRect(x: 22, y: 2,  width: 14, height: 4),  helm)
        fill(CGRect(x: 18, y: 6,  width: 22, height: 5),  helm)
        fill(CGRect(x: 15, y: 11, width: 28, height: 16), helm)
        fill(CGRect(x: 22, y: 2,  width: 14, height: 2),  edge)
        fill(CGRect(x: 18, y: 6,  width: 4,  height: 5),  edge)
        fill(CGRect(x: 15, y: 27, width: 28, height: 4),  dark)
        fill(CGRect(x: 19, y: 16, width: 8,  height: 6),  visor)
        fill(CGRect(x: 31, y: 16, width: 8,  height: 6),  visor)
        fill(CGRect(x: 21, y: 18, width: 3,  height: 3),  edge)
        fill(CGRect(x: 33, y: 18, width: 3,  height: 3),  edge)
        fill(CGRect(x: 19, y: 31, width: 20, height: 9),  helm)
        fill(CGRect(x: 22, y: 40, width: 14, height: 4),  helm)
        fill(CGRect(x: 21, y: 44, width: 7,  height: 7),  dark)
        fill(CGRect(x: 30, y: 44, width: 7,  height: 7),  dark)
    }
}

/// Animated mascot that picks shape, palette, and animation based on session
/// status + provider. Transient statuses (thinking/error/waiting) override
/// the provider palette so the user can read the status at a glance.
struct SessionMascot: View {
    let status: SessionStatus
    var size: CGFloat = 16
    var animated: Bool = true
    var provider: AIProvider = .codex

    @Environment(\.notchTheme) private var theme

    var body: some View {
        PixelMascot(
            size: size,
            palette: paletteFor(status),
            shape: provider.mascotShape,
            animate: animated && isActive,
            masked: theme.masksMascots
        )
    }

    private var isActive: Bool {
        status == .thinking || status == .toolUse
    }

    private func paletteFor(_ status: SessionStatus) -> PixelMascot.MascotPalette {
        switch status {
        case .thinking, .toolUse: return provider.activeMascotPalette
        case .idle, .completed:   return provider.mascotPalette
        case .error:              return .error
        case .waitingPermission:  return .waiting
        }
    }
}
