import Foundation
import Combine
import OpenWhispererKit

/// Session-only transcription history feeding the menubar dropdown. Wraps the pure
/// `TranscriptHistoryBuffer`; nothing is written to disk. All mutations land on the
/// main queue (the sink receives on main; `clear()` is called from the menu).
final class TranscriptionHistory: ObservableObject {
    @Published private(set) var items: [String] = []

    private var buffer = TranscriptHistoryBuffer()
    private var cancellable: AnyCancellable?

    /// Subscribe to the dictation pipeline's transcription feed — the same
    /// `$lastTranscription` publisher the overlay's status wiring consumes.
    func wire(to dictation: DictationManager) {
        cancellable = dictation.$lastTranscription
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                guard let self else { return }
                self.buffer.append(text)
                self.items = self.buffer.items
            }
    }

    func clear() {
        buffer.clear()
        items = []
    }
}
