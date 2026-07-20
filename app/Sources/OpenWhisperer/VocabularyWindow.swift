import AppKit
import SwiftUI

/// Standalone editor window for the custom STT vocabulary (`Paths.sttVocabulary`).
/// A pop-up so the Voice Settings card stays compact. SwiftUI sheets/popovers
/// misbehave inside `MenuBarExtra(.window)`, so this uses an AppKit window — the
/// same pattern as the log / instruction windows (see `InstructionWindow`).
final class VocabularyWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    // Keep alive until the window closes — all access on the main thread.
    private static var active: [VocabularyWindow] = []

    static func show() {
        DispatchQueue.main.async {
            // Re-front an already-open editor rather than stacking duplicates.
            if let existing = active.first, let w = existing.window {
                w.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                return
            }
            let owner = VocabularyWindow()
            active.append(owner)

            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Custom Vocabulary"
            w.center()
            w.isReleasedWhenClosed = false
            w.delegate = owner
            w.contentView = NSHostingView(rootView: VocabularyEditorView())
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            owner.window = w
        }
    }

    func windowWillClose(_ notification: Notification) {
        VocabularyWindow.active.removeAll { $0 === self }
    }
}

private struct VocabularyEditorView: View {
    @State private var text: String = (try? String(contentsOf: Paths.sttVocabulary, encoding: .utf8)) ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One term per line. Transcripts are fuzzy-corrected against these — handy for names, jargon, and product names the model mishears.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onChange(of: text) { _, newValue in save(newValue) }
        }
        .padding(16)
        .frame(minWidth: 380, minHeight: 300)
    }

    /// Save on every edit (atomic); empty clears the file, matching the old inline behavior.
    private func save(_ value: String) {
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: Paths.sttVocabulary)
        } else {
            try? value.write(to: Paths.sttVocabulary, atomically: true, encoding: .utf8)
        }
    }
}
