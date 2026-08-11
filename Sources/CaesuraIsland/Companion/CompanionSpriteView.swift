import AppKit
import SwiftUI

struct CompanionSpriteView: View {
    @ObservedObject var model: CompanionModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frameIndex = 0

    private var animationEnabled: Bool {
        model.isWindowVisible && !model.isLowPowerModeEnabled && !reduceMotion && model.state != .idle
    }

    private var animationKey: AnimationKey {
        AnimationKey(state: model.state, enabled: animationEnabled)
    }

    var body: some View {
        GeometryReader { proxy in
            Group {
                if let atlas = CompanionAtlas.shared.image {
                    atlasCell(atlas)
                } else {
                    MysaFallbackView(state: model.state)
                }
            }
            .frame(
                width: proxy.size.width * (92.0 / 116.0),
                height: proxy.size.height * (100.0 / 124.0)
            )
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.state.accessibilityLabel)
        .task(id: animationKey) {
            frameIndex = 0
            guard animationEnabled else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: model.state.frameInterval)
                guard !Task.isCancelled else { return }
                frameIndex = (frameIndex + 1) % model.state.frameCount
            }
        }
    }

    private func atlasCell(_ atlas: NSImage) -> some View {
        GeometryReader { proxy in
            let cellWidth = proxy.size.width
            let cellHeight = proxy.size.height
            Image(nsImage: atlas)
                .resizable()
                .interpolation(.none)
                .frame(width: cellWidth * 8, height: cellHeight * 11)
                .position(
                    x: cellWidth * 4 - CGFloat(frameIndex) * cellWidth,
                    y: cellHeight * 5.5 - CGFloat(model.state.atlasRow) * cellHeight
                )
        }
        .clipped()
    }

    private struct AnimationKey: Hashable {
        let state: CompanionState
        let enabled: Bool
    }
}

final class CompanionAtlas {
    static let shared = CompanionAtlas()
    let image: NSImage?

    private init() {
        let bundle = Bundle.main
        let candidates: [URL?] = [
            bundle.url(forResource: "spritesheet", withExtension: "webp", subdirectory: "companion/mysa"),
            bundle.resourceURL?.appendingPathComponent("companion/mysa/spritesheet.webp"),
            bundle.bundleURL.appendingPathComponent("Contents/Resources/companion/mysa/spritesheet.webp"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/companion/mysa/spritesheet.webp"),
        ]
        image = candidates
            .compactMap { $0 }
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
            .flatMap(NSImage.init(contentsOf:))
    }
}

/// Keeps development builds usable before packaged resources are assembled.
/// The shipped bundle includes Mysa's validated sprite atlas.
struct MysaFallbackView: View {
    let state: CompanionState

    var body: some View {
        Canvas { context, size in
            let unit = min(size.width / 46, size.height / 50)
            let x = (size.width - 46 * unit) / 2
            let y = (size.height - 50 * unit) / 2
            func fill(_ rect: CGRect, _ color: Color) {
                let scaled = CGRect(
                    x: x + rect.minX * unit,
                    y: y + rect.minY * unit,
                    width: rect.width * unit,
                    height: rect.height * unit
                )
                context.fill(Path(scaled), with: .color(color))
            }

            let shell = Color(red: 0.075, green: 0.060, blue: 0.095)
            let edge = Color(red: 0.25, green: 0.18, blue: 0.36)
            let violet = Color(red: 0.58, green: 0.31, blue: 0.92)
            let signal: Color = switch state {
            case .attention: .orange
            case .success: .green
            case .failure: .red
            default: violet
            }

            fill(CGRect(x: 8, y: 5, width: 30, height: 4), edge)
            fill(CGRect(x: 4, y: 9, width: 38, height: 30), shell)
            fill(CGRect(x: 8, y: 39, width: 12, height: 7), shell)
            fill(CGRect(x: 26, y: 39, width: 12, height: 7), shell)
            fill(CGRect(x: 21, y: 5, width: 4, height: 34), signal)
            fill(CGRect(x: 11, y: 19, width: 8, height: 5), signal)
            fill(CGRect(x: 27, y: 19, width: 8, height: 5), signal)
        }
        .drawingGroup(opaque: false, colorMode: .linear)
    }
}

struct MysaCompanionPreview: View {
    var body: some View {
        Group {
            if let atlas = CompanionAtlas.shared.image {
                GeometryReader { proxy in
                    Image(nsImage: atlas)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: proxy.size.width * 8, height: proxy.size.height * 11)
                        .position(x: proxy.size.width * 4, y: proxy.size.height * 5.5)
                }
                .clipped()
            } else {
                MysaFallbackView(state: .idle)
            }
        }
        .aspectRatio(192.0 / 208.0, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
