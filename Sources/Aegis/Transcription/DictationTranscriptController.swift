import AppKit
import SwiftUI

@MainActor
final class DictationTranscriptController: ObservableObject {
    static let shared = DictationTranscriptController()
    @Published private(set) var text = ""
    @Published private(set) var detail = ""
    private var panel: NSPanel?

    func append(_ transcript: String, reason: String) {
        text += text.isEmpty ? transcript : "\n\n" + transcript
        detail = reason
    }

    func copy() {
        let board = NSPasteboard.general
        board.clearContents()
        detail = board.setString(text, forType: .string) ? "Copied to clipboard" : "Could not copy. Select the text and copy it manually."
    }

    func clear() {
        text = ""
        detail = ""
        panel?.close()
    }

    func show() {
        guard !text.isEmpty else { return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
                styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "Dictation transcript"
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.level = .floating
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 320))
            let host = NSHostingView(rootView: DictationTranscriptView(transcript: self))
            host.sizingOptions = []
            host.frame = container.bounds
            host.autoresizingMask = [.width, .height]
            container.addSubview(host)
            panel.contentView = container
            panel.center()
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }
}

private struct DictationTranscriptView: View {
    @ObservedObject var transcript: DictationTranscriptController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your transcript is ready").font(.title3.weight(.semibold))
            Text(transcript.detail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            ScrollView {
                Text(transcript.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Clear") { transcript.clear() }
                Spacer()
                Button("Copy text") { transcript.copy() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 440, height: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
