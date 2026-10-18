import AppKit
import SwiftUI
import OpenWhispererKit

// Shared branded ("OW") controls used by the Settings tabs.
// Extracted verbatim from MenuBarView.swift (2026-07-20) so the tabbed
// Settings window and any other view share one copy. Design tokens
// (OWColor, OWFont, OWWindowBackground) live in Theme.swift.

// MARK: - OWCard (rounded card container)

struct OWCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OWColor.cardBackground)
                    .shadow(color: Color(red: 0.18, green: 0.14, blue: 0.08).opacity(0.08), radius: 5, x: 0, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(OWColor.line, lineWidth: 0.6)
            )
    }
}

// MARK: - OWCollapsibleCard

struct OWCollapsibleCard<Trailing: View, Expanded: View>: View {
    let title: String
    let icon: String
    let help: String?
    @Binding var expanded: Bool
    let trailing: Trailing
    let expandedContent: Expanded

    init(
        title: String,
        icon: String,
        help: String? = nil,
        expanded: Binding<Bool>,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder expandedContent: () -> Expanded
    ) {
        self.title = title
        self.icon = icon
        self.help = help
        self._expanded = expanded
        self.trailing = trailing()
        self.expandedContent = expandedContent()
    }

    var body: some View {
        OWCard {
            VStack(alignment: .leading, spacing: 0) {
                // Header row — always visible
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(OWColor.inkFaint)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .animation(.easeInOut(duration: 0.18), value: expanded)

                        Image(systemName: icon)
                            .font(.system(size: 11))
                            .foregroundColor(OWColor.accent.opacity(0.75))

                        Text(title)
                            .font(OWFont.sectionLabel(11))
                            .foregroundColor(OWColor.inkSoft)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { expanded.toggle() } }

                    if let help {
                        OWInfoTip(text: help)
                            .padding(.leading, 6)
                    }

                    Spacer()
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { expanded.toggle() } }

                    trailing
                }

                // Expanded content
                if expanded {
                    OWInternalDivider()
                        .padding(.top, 10)
                    expandedContent
                        .padding(.top, 8)
                }
            }
        }
    }
}

// MARK: - OWCardHeader

struct OWCardHeader: View {
    let title: String
    let icon: String
    var help: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(OWColor.accent)
                .frame(width: 2, height: 13)
            Image(systemName: icon)
                // accentDeep at full opacity: bright accent at 0.75 on white is ~1.9:1.
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(OWColor.accentDeep)
            // The brand serif, at the top of the type scale, in full ink — headers were
            // 11pt inkSoft, i.e. lighter than the content beneath them.
            Text(title)
                .font(OWFont.serif(13))
                .foregroundColor(OWColor.ink)
            if let help {
                OWInfoTip(text: help)
            }
        }
    }
}

// MARK: - OWInfoTip (visible ⓘ that reveals a help bubble on hover)

/// A small info icon next to a label; hovering it shows a styled help bubble.
/// Uses a popover (not `.help()`, which is unreliable inside a MenuBarExtra popover)
/// so the bubble is always visible and never clipped by the card bounds.
struct OWInfoTip: View {
    let text: String
    @State private var show = false

    var body: some View {
        Image(systemName: "info.circle")
            .font(.system(size: 11))
            .foregroundColor(OWColor.accent.opacity(0.7))
            .contentShape(Rectangle())
            .onHover { show = $0 }
            .popover(isPresented: $show, arrowEdge: .bottom) {
                Text(text)
                    .font(OWFont.body(11))
                    .foregroundColor(OWColor.ink)
                    .frame(width: 232, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(OWColor.page)
            }
    }
}

// MARK: - OWPickerRow

struct OWPickerRow<Content: View>: View {
    let label: String
    let labelWidth: CGFloat
    let content: Content

    init(label: String, labelWidth: CGFloat = 60, @ViewBuilder content: () -> Content) {
        self.label = label
        self.labelWidth = labelWidth
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(OWFont.body(11))
                .foregroundColor(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            content
        }
    }
}

// MARK: - OWInternalDivider

struct OWInternalDivider: View {
    var body: some View {
        Rectangle()
            .fill(OWColor.line)
            .frame(height: 0.5)
    }
}

// MARK: - OWMenuPicker (custom SwiftUI dropdown — avoids dark AppKit NSPopUpButton)

struct OWMenuPicker<T: Hashable>: View {
    @Binding var selection: T
    let options: [(id: T, label: String)]

    var body: some View {
        Menu {
            ForEach(options, id: \.id) { option in
                Button {
                    selection = option.id
                } label: {
                    if option.id == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(currentLabel)
                    .font(OWFont.body(11))
                    .foregroundColor(OWColor.ink)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(OWColor.accent.opacity(0.6))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(OWColor.pickerBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(OWColor.checkboxBorder, lineWidth: 1)
                    )
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var currentLabel: String {
        options.first(where: { $0.id == selection })?.label ?? ""
    }
}

// MARK: - OWSearchablePicker (sectioned, searchable, captioned popover picker)

/// One row in an `OWSearchablePicker`.
struct OWPickerOption: Identifiable, Equatable {
    let id: String
    /// Shown when the list is browsed by section.
    let label: String
    /// Shown instead of `label` while a search is active, when the section header is no
    /// longer next to the row to give it context (`Greek · F1 · Female`). Defaults to `label`.
    var searchLabel: String?
    /// Small trailing annotation (`~40% errors`). Nil for most rows — a badge every row
    /// carries is noise that belongs in the section caption instead.
    var badge: String?
    /// Extra terms the search should match beyond the labels — ISO codes, mainly.
    var keywords: [String] = []

    var resolvedSearchLabel: String { searchLabel ?? label }
}

/// A group of options with an optional explanatory caption.
struct OWPickerSection: Identifiable {
    let id: String
    /// Uppercased header. Empty for a leading section that needs no title (a pinned row).
    let title: String
    /// One line explaining what the section means. This is the point of the control:
    /// a category should never have to be inferred from its name.
    var caption: String?
    /// A convenience shortcut whose rows also appear in a full section below. Hidden while
    /// searching so a match isn't listed twice.
    var isShortcut: Bool = false
    let options: [OWPickerOption]
}

/// `OWMenuPicker`'s collapsed control over a searchable popover list.
///
/// Replaces `OWGroupedMenuPicker` (nested submenus), which stopped scaling once Dictate
/// grew to 100 languages and Voice to 33 language groups: submenus have no search, and
/// finding "Malayalam" meant knowing which submenu it lived in.
///
/// Sections carry captions and rows carry badges so both pickers can explain themselves
/// inline rather than in a help tooltip nobody opens.
struct OWSearchablePicker: View {
    @Binding var selection: String
    let sections: [OWPickerSection]
    var placeholder: String = "Search…"
    /// Shown collapsed when `selection` matches nothing — a stale pref, mainly.
    var emptyLabel: String = "Select…"
    /// Fully-qualified text for the collapsed control (`Greek · F1 (Female)`). The row
    /// label alone is often ambiguous once section headers are out of view.
    var currentLabelOverride: String?

    @State private var showPopover = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(currentLabel)
                    .font(OWFont.body(11))
                    .foregroundColor(OWColor.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(OWColor.accent.opacity(0.6))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(OWColor.pickerBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(OWColor.checkboxBorder, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                TextField(placeholder, text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(OWFont.body(11))
                    .focused($searchFocused)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredSections) { section in
                            if !section.title.isEmpty {
                                header(section.title)
                            }
                            // Captions are hidden while searching: the result list is a
                            // flat set of matches, so a section's explanation no longer
                            // describes what sits under it.
                            if let caption = section.caption, isSearching == false {
                                Text(caption)
                                    .font(OWFont.body(9))
                                    .foregroundColor(OWColor.inkSoft)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 18)
                                    .padding(.bottom, 2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            ForEach(section.options) { option in
                                row(option)
                            }
                        }
                        if filteredSections.isEmpty {
                            Text("No matches")
                                .font(OWFont.body(11))
                                .foregroundColor(OWColor.inkSoft)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 8)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(width: 268, height: 280)
            }
            .padding(8)
            .background(OWColor.page)
            // A 100-row list is unusable without typing, so land the caret in the field.
            .onAppear { searchFocused = true }
        }
        // Selecting a row clears `query`, but dismissing by click-outside or Escape does
        // not — without this, reopening shows a stale filtered list with its captions
        // suppressed and no hint why.
        .onChange(of: showPopover) { _, shown in
            if !shown { query = "" }
        }
    }

    private var isSearching: Bool { PickerSearch.isActive(query) }

    private var filteredSections: [OWPickerSection] {
        guard isSearching else { return sections }
        // Shortcut sections repeat rows that also live in a full section below (Dictate's
        // "Common" duplicates 17 languages). Browsing wants both — the caption says so —
        // but under a query the captions are hidden and the repeat just looks like the
        // same language listed twice, so shortcuts drop out of results.
        var seen = Set<String>()
        return sections.filter { !$0.isShortcut }.compactMap { section in
            let hits = section.options.filter { option in
                guard !seen.contains(option.id) else { return false }
                let hit = PickerSearch.matches(
                    query: query, label: option.label,
                    searchLabel: option.resolvedSearchLabel, keywords: option.keywords)
                if hit { seen.insert(option.id) }
                return hit
            }
            guard !hits.isEmpty else { return nil }
            return OWPickerSection(id: section.id, title: section.title,
                                   caption: section.caption, isShortcut: section.isShortcut,
                                   options: hits)
        }
    }

    private var currentLabel: String {
        if let override = currentLabelOverride, !override.isEmpty { return override }
        for section in sections {
            if let hit = section.options.first(where: { $0.id == selection }) { return hit.label }
        }
        return emptyLabel
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(OWFont.body(9))
            .foregroundColor(OWColor.ink.opacity(0.5))
            .padding(.top, 6)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ option: OWPickerOption) -> some View {
        Button {
            selection = option.id
            query = ""
            showPopover = false
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 12)
                    .foregroundColor(OWColor.accent)
                    .opacity(option.id == selection ? 1 : 0)
                Text(isSearching ? option.resolvedSearchLabel : option.label)
                    .font(OWFont.body(11))
                    .foregroundColor(OWColor.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge = option.badge {
                    Text(badge)
                        .font(OWFont.body(9))
                        .foregroundColor(OWColor.inkSoft)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - OWAppPicker (searchable picker: favorites + every installed app)

/// Like `OWMenuPicker`, but backs a long, searchable list. The collapsed control
/// shows the current selection; tapping it opens a popover with a search field,
/// a "Favorites" section (the curated dev/terminal apps), an "Installed apps"
/// section (everything found on disk, type-to-filter), and a "Custom…" escape.
///
/// `selection` carries: a favorite id (its name), an installed app's bundle id,
/// or `"CUSTOM"`. `onSelect` fires with that id after a pick.
struct OWAppPicker: View {
    @Binding var selection: String
    let favorites: [AppEntry]   // bundleID holds the favorite's id (a display name)
    let installed: [AppEntry]
    let onSelect: (String) -> Void

    @State private var showPopover = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(currentLabel)
                    .font(OWFont.body(11))
                    .foregroundColor(OWColor.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(OWColor.accent.opacity(0.6))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(OWColor.pickerBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(OWColor.checkboxBorder, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Search apps…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .font(OWFont.body(11))
                    .focused($searchFocused)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !filteredFavorites.isEmpty {
                            header("Favorites")
                            ForEach(filteredFavorites, id: \.bundleID) { fav in
                                row(id: fav.bundleID, label: fav.name)
                            }
                        }
                        if !filteredApps.isEmpty {
                            header("Installed apps")
                            ForEach(filteredApps, id: \.bundleID) { app in
                                row(id: app.bundleID, label: app.name)
                            }
                        }
                        Divider().padding(.vertical, 3)
                        row(id: "CUSTOM", label: "Custom…")
                    }
                    .padding(.vertical, 2)
                }
                .frame(width: 240, height: 250)
            }
            .padding(8)
            .background(OWColor.page)
            // Every installed app is in this list, so it is unusable without typing.
            .onAppear { searchFocused = true }
        }
        // Picking a row clears `query`, but dismissing by click-outside or Escape does not,
        // so reopening would show a stale filtered list with no hint why. Same fix as
        // `OWSearchablePicker`; this control predates it and had the bug independently.
        .onChange(of: showPopover) { _, shown in
            if !shown { query = "" }
        }
    }

    private var filteredApps: [AppEntry] {
        AppFilter.match(installed, query: query)
    }

    private var filteredFavorites: [AppEntry] {
        AppFilter.match(favorites, query: query)
    }

    private var currentLabel: String {
        if selection == "CUSTOM" { return "Custom…" }
        if let fav = favorites.first(where: { $0.bundleID == selection }) { return fav.name }
        if let app = installed.first(where: { $0.bundleID == selection }) { return app.name }
        return selection.isEmpty ? "Select app…" : selection
    }

    private func header(_ title: String) -> some View {
        Text(title.uppercased())
            .font(OWFont.body(9))
            .foregroundColor(OWColor.ink.opacity(0.5))
            .padding(.top, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(id: String, label: String) -> some View {
        Button {
            selection = id
            onSelect(id)
            query = ""
            showPopover = false
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 12)
                    .foregroundColor(OWColor.accent)
                    .opacity(id == selection ? 1 : 0)
                Text(label)
                    .font(OWFont.body(11))
                    .foregroundColor(OWColor.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - OWCheckbox (custom SwiftUI checkbox — avoids dark AppKit NSButton)

struct OWCheckbox: View {
    let label: String
    @Binding var isOn: Bool
    var tint: Color = OWColor.accent

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? tint : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(
                                    isOn ? tint : OWColor.checkboxBorder,
                                    lineWidth: 1
                                )
                        )
                        .frame(width: 13, height: 13)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(OWColor.onAccent)
                    }
                }
                .animation(.easeInOut(duration: 0.12), value: isOn)
                Text(label)
                    .font(OWFont.body(11))
                    .foregroundColor(OWColor.ink)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - InlineBadge

struct InlineBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(OWFont.caption())
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.10))
            )
    }
}

// MARK: - ModernStatusRow

struct ModernStatusRow: View {
    let label: String
    let subtitle: String
    let port: String
    let status: ServerManager.ServerStatus

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(dotColor.opacity(0.18))
                    .frame(width: 18, height: 18)
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(OWFont.body(11))
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(OWFont.caption(10))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(":\(port)")
                .font(OWFont.mono(10))
                .foregroundColor(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(OWColor.pillFill)
                )
        }
        .padding(.vertical, 4)
    }

    private var dotColor: Color {
        switch status {
        case .running: return OWColor.live
        case .starting: return OWColor.warn
        case .error: return OWColor.recording
        case .stopped: return OWColor.inkFaint
        }
    }
}

// MARK: - ModernDiagnosticRow

// MARK: - OWSlider (branded slider — the system knob is drawn by AppKit and can't be tinted)

struct OWSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05
    /// Called when a drag finishes, so callers can persist once instead of on every step.
    var onCommit: (() -> Void)? = nil

    private static let knob: CGFloat = 13
    private static let track: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - Self.knob, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let x = usable * CGFloat(min(max(fraction, 0), 1))

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(OWColor.pillFill)
                    .frame(height: Self.track)
                Capsule()
                    .fill(OWColor.accent)
                    .frame(width: x + Self.knob / 2, height: Self.track)
                Circle()
                    .fill(OWColor.surface)
                    .overlay(Circle().stroke(OWColor.accentDeep, lineWidth: 1.5))
                    .frame(width: Self.knob, height: Self.knob)
                    .offset(x: x)
            }
            .frame(height: Self.knob)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let raw = Double((g.location.x - Self.knob / 2) / usable)
                        let span = range.upperBound - range.lowerBound
                        let stepped = (raw * span / step).rounded() * step + range.lowerBound
                        value = min(max(stepped, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in onCommit?() }
            )
            .accessibilityElement()
            .accessibilityValue(String(format: "%.2f", value))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: value = min(value + step, range.upperBound)
                case .decrement: value = max(value - step, range.lowerBound)
                default: break
                }
                onCommit?()
            }
        }
        .frame(height: Self.knob)
    }
}

// MARK: - OWTextField (branded field — .roundedBorder draws a system bezel on cream)

struct OWTextField: View {
    let placeholder: String
    @Binding var text: String
    var isError: Bool = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(OWFont.body(11))
            .foregroundColor(OWColor.ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(OWColor.pickerBg))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isError ? OWColor.danger : OWColor.pickerBorder, lineWidth: 1)
            )
    }
}

/// A permission row that *looks* clickable — the plain status row gave no hint that
/// tapping opens System Settings, so nobody discovered it.
struct OWPermissionRow: View {
    let label: String
    let granted: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(granted ? OWColor.live : OWColor.warn)
                Text(label)
                    .font(OWFont.body(11))
                    .foregroundColor(granted ? OWColor.inkSoft : OWColor.ink)
                Spacer(minLength: 6)
                if !granted {
                    Text("Grant")
                        .font(OWFont.body(11))
                        .foregroundColor(OWColor.accentDeep)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(OWColor.inkFaint)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(!granted ? OWColor.warn.opacity(0.10)
                                   : (isHovered ? OWColor.pillFill.opacity(0.6) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) { isHovered = hovering }
            if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .accessibilityLabel("\(label): \(granted ? "granted" : "not granted"). Opens System Settings.")
    }
}

struct ModernDiagnosticRow: View {
    let label: String
    let ok: Bool
    var notInstalled: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundColor(iconColor)

            Text(notInstalled ? "\(label) (not installed)" : label)
                .font(OWFont.body(11))
                // Granted is the calm state; missing is the loud one.
                .foregroundColor(notInstalled ? OWColor.inkFaint : (ok ? OWColor.inkSoft : OWColor.ink))
        }
    }

    private var iconName: String {
        if notInstalled { return "minus.circle" }
        // A missing grant blocks the app — it must not be the quietest thing on screen.
        return ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var iconColor: Color {
        if notInstalled { return OWColor.inkFaint }
        return ok ? OWColor.live : OWColor.warn
    }
}

// MARK: - SectionHeader (kept for backward compatibility)

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Text(title)
                .font(OWFont.sectionLabel())
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - CollapsibleHeader (kept for backward compatibility)

struct CollapsibleHeader<Trailing: View>: View {
    let title: String
    let icon: String
    @Binding var expanded: Bool
    let trailing: Trailing

    init(title: String, icon: String, expanded: Binding<Bool>, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.icon = icon
        self._expanded = expanded
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: expanded)
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Text(title)
                    .font(OWFont.sectionLabel())
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { expanded.toggle() }
            Spacer()
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }
            trailing
        }
    }
}

extension CollapsibleHeader where Trailing == EmptyView {
    init(title: String, icon: String, expanded: Binding<Bool>) {
        self.title = title
        self.icon = icon
        self._expanded = expanded
        self.trailing = EmptyView()
    }
}

// MARK: - Button Styles

struct OWPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OWFont.body(11).weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(OWColor.accent.opacity(configuration.isPressed ? 0.85 : 1.0))
            )
            .foregroundColor(OWColor.onAccent)
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct OWRowButtonStyle: ButtonStyle {
    var tinted: Bool = false
    var urgent: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let color: Color = tinted ? OWColor.success : (urgent ? OWColor.warn : OWColor.inkSoft)
        configuration.label
            .font(OWFont.body(11))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(tinted || urgent
                          ? color.opacity(configuration.isPressed ? 0.22 : 0.14)
                          : OWColor.pillFill.opacity(configuration.isPressed ? 1.0 : 0.7))
            )
            .foregroundColor(color)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Legacy alias so existing call sites that use MenuBarButtonStyle still compile.
typealias MenuBarButtonStyle = OWPrimaryButtonStyle

/// Legacy alias so existing call sites that use MenuBarRowButtonStyle still compile.
typealias MenuBarRowButtonStyle = OWRowButtonStyle

// MARK: - PortField

struct PortField: View {
    let label: String
    @Binding var port: Int
    var disabled: Bool = false
    @State private var text: String = ""

    private var isValid: Bool {
        guard let p = Int(text) else { return false }
        return TTSPort.validRange.contains(p)
    }

    var body: some View {
        HStack {
            if !label.isEmpty {
                Text(label)
                    .font(OWFont.body(11))
                    .frame(minWidth: 60, alignment: .leading)
            }
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
                .disabled(disabled)
                .opacity(disabled ? 0.45 : 1.0)
                .foregroundColor(isValid || text.isEmpty ? OWColor.ink : OWColor.danger)
                .onAppear { text = "\(port)" }
                .onChange(of: text) { _, newValue in
                    if let p = Int(newValue), TTSPort.validRange.contains(p) {
                        port = p
                    }
                }
                .onChange(of: port) { _, newPort in
                    let portStr = "\(newPort)"
                    if text != portStr { text = portStr }
                }
        }
    }
}

// MARK: - DiagnosticRow (legacy alias → ModernDiagnosticRow)

struct DiagnosticRow: View {
    let label: String
    let ok: Bool
    var notInstalled: Bool = false

    var body: some View {
        ModernDiagnosticRow(label: label, ok: ok, notInstalled: notInstalled)
    }
}

// MARK: - StatusRow (legacy alias → ModernStatusRow)

struct StatusRow: View {
    let label: String
    let subtitle: String
    let port: String
    let status: ServerManager.ServerStatus

    var body: some View {
        ModernStatusRow(label: label, subtitle: subtitle, port: port, status: status)
    }
}
