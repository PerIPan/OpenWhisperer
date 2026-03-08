import Foundation
import SwiftUI

class TranscriptionOverlay: NSObject, NSWindowDelegate, ObservableObject {
    static let shared = TranscriptionOverlay()

    private var window: NSWindow?
    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    struct Line: Identifiable {
        let id: Int
        let text: String
    }

    @Published var lines: [Line] = []
    @Published var isVisible: Bool = false
    private var nextLineId = 0

    func show() {
        if let w = window, w.isVisible {
            w.orderFront(nil)
            return
        }

        let hostingView = NSHostingView(rootView: OverlayView(overlay: self))

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 160),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        w.title = "Transcriptions"
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = hostingView
        w.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92)

        // Position bottom-right of screen
        if let screen = NSScreen.main {
            let x = screen.visibleFrame.maxX - 360
            let y = screen.visibleFrame.minY + 20
            w.setFrameOrigin(NSPoint(x: x, y: y))
        }

        w.makeKeyAndOrderFront(nil)
        self.window = w
        isVisible = true
        startTailing()
    }

    func hide() {
        stopTailing()
        window?.close()
        window = nil
        isVisible = false
    }

    func windowWillClose(_ notification: Notification) {
        stopTailing()
        window = nil
        isVisible = false
    }

    private func startTailing() {
        stopTailing()

        let logPath = Paths.serverLog.path
        guard FileManager.default.fileExists(atPath: logPath) else { return }

        guard let fh = FileHandle(forReadingAtPath: logPath) else { return }
        fh.seekToEndOfFile()
        fileHandle = fh

        let fd = fh.fileDescriptor
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )

        src.setEventHandler { [weak self] in
            guard let self else { return }
            let data = fh.availableData
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else { return }

            let newLines = text.components(separatedBy: "\n")
                .filter { $0.contains("Transcribed:") }
                .compactMap { line -> String? in
                    guard let range = line.range(of: "Transcribed: ") else { return nil }
                    return String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }

            if !newLines.isEmpty {
                DispatchQueue.main.async {
                    let tagged = newLines.map { text -> Line in
                        self.nextLineId += 1
                        return Line(id: self.nextLineId, text: text)
                    }
                    self.lines.append(contentsOf: tagged)
                    if self.lines.count > 20 {
                        self.lines = Array(self.lines.suffix(20))
                    }
                }
            }
        }

        src.setCancelHandler {
            try? fh.close()
        }

        src.resume()
        source = src
    }

    private func stopTailing() {
        source?.cancel()
        source = nil
        fileHandle = nil
    }
}

struct OverlayView: View {
    @ObservedObject var overlay: TranscriptionOverlay

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if overlay.lines.isEmpty {
                Text("Listening for transcriptions...")
                    .font(.custom("Outfit", size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(overlay.lines) { line in
                                Text(line.text)
                                    .font(.custom("Outfit", size: 13))
                                    .textSelection(.enabled)
                                    .id(line.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    }
                    .onChange(of: overlay.lines.count) { _, _ in
                        if let last = overlay.lines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
