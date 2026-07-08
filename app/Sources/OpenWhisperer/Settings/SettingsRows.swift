import SwiftUI

/// Permission status row: green check when granted, an "Open Settings…" affordance otherwise.
struct PermissionRow: View {
    let label: String
    let granted: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        LabeledContent {
            if granted {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Open Settings…", action: action)
            }
        } label: {
            Text(label)
        }
        .help(help)
    }
}

/// Port editor with the legacy validity rules: accepts 1024–65535, red text while
/// out of range, and only ever writes a valid value back to the binding.
struct SettingsPortField: View {
    @Binding var port: Int
    var disabled: Bool
    @State private var text: String = ""

    private var isValid: Bool {
        guard let p = Int(text) else { return false }
        return p >= 1024 && p <= 65535
    }

    var body: some View {
        TextField("", text: $text)
            .frame(width: 70)
            .multilineTextAlignment(.trailing)
            .disabled(disabled)
            .foregroundStyle(isValid || text.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
            .onAppear { text = "\(port)" }
            .onChange(of: text) { _, newValue in
                if let p = Int(newValue), p >= 1024, p <= 65535 { port = p }
            }
            .onChange(of: port) { _, newPort in
                let s = "\(newPort)"
                if text != s { text = s }
            }
    }
}
