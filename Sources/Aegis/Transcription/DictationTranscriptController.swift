import AppKit
import Combine

@MainActor
final class DictationTranscriptController: ObservableObject {
    static let shared = DictationTranscriptController()
    @Published private(set) var text = ""

    func append(_ transcript: String, clipboard: NSPasteboard = .general) throws {
        text += text.isEmpty ? transcript : "\n\n" + transcript
        try copy(transcript, to: clipboard)
    }

    func copy() throws {
        try copy(text, to: .general)
    }

    private func copy(_ transcript: String, to clipboard: NSPasteboard) throws {
        clipboard.clearContents()
        guard clipboard.setString(transcript, forType: .string) else {
            throw DictationFailure(message: "Could not copy your transcript. Your text is saved in Transcription settings.")
        }
    }

    func clear() {
        text = ""
    }
}
