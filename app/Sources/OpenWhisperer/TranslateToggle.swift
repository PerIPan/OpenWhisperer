import AppKit
import OpenWhispererKit

/// The one place "Translate to English" is turned on or off.
///
/// Two surfaces offer it — the menubar dropdown and Settings → Advanced — and both must ask
/// for the same consent before the same ~948 MB download, so the flow lives here rather than
/// being written twice.
///
/// Why consent at all: enabling translation **swaps the speech model**. The shipped turbo
/// checkpoint cannot translate (OpenAI excluded translation data from its fine-tune; it
/// returns the source language verbatim), so translating means downloading and ANE-compiling
/// a second, non-turbo checkpoint. Asking here — rather than letting the next dictation
/// trigger it lazily — is also what keeps that multi-minute cold load away from the
/// transcription watchdog, which would otherwise cancel the first translated sentence.
enum TranslateToggle {

    /// Apply a requested on/off change, prompting first when enabling would require a
    /// download. Returns the value actually applied, so a caller driving a checkbox can
    /// settle its own state (a cancelled prompt leaves translation off).
    @discardableResult
    @MainActor
    static func request(_ enable: Bool, on dictationManager: DictationManager) -> Bool {
        if enable, !SpeechTranscriber.isModelCached(.translating), !confirmDownload() {
            return dictationManager.translateToEnglish   // cancelled — nothing changes
        }
        dictationManager.setTranslate(enable)
        return enable
    }

    /// `NSAlert` rather than a SwiftUI `.alert`: it is what the rest of this app's confirms
    /// use, and it works identically from the menubar (which has no view to attach a sheet to).
    @MainActor
    private static func confirmDownload() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Download the translation model?"
        alert.informativeText = """
            Translating needs a different speech model — the fast one used by default cannot \
            translate at all.

            One-time download of \(STTModelChoice.translating.approximateDownloadDescription), \
            then a few minutes to compile it for the Neural Engine. Dictation is unavailable \
            while it prepares.
            """
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
