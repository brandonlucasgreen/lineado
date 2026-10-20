import AppKit
import SwiftUI

/// The menu bar panel: filter chips, the list, a footer, and the pickers.
///
/// Also the keyboard hub. Keys arrive from a local `NSEvent` monitor — SwiftUI's
/// `onKeyPress` alone does not reliably see them inside a `MenuBarExtra` window
/// — and are routed through `KeyMap`, so the panel and the window agree on what
/// every key does because they ask the same function.
struct PanelView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow
    @Environment(\.menuBarController) private var menuBar

    @State private var activePicker: ActivePicker?
    @State private var keyMonitor: Any?
    @State private var showsAllShortcuts = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 0) {
            header
            Divider()

            if !app.isConfigured {
                UnconfiguredView()
            } else if app.orderedIssues.isEmpty {
                EmptyStateView(hasAnyIssues: !app.issues.isEmpty)
            } else {
                IssueListView()
            }

            Divider()
            if app.isConfigured {
                KeyboardHintBar()
                Divider()
            }
            FooterView()
        }
        // Size and background belong to the hosting `NSPanel` now
        // (`MenuBarController.makePanel`), which sets an opaque
        // `windowBackgroundColor`. The old thin material let the desktop's own
        // text show through behind these rows.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .center) { pickerOverlay }
        .sheet(isPresented: $showsAllShortcuts) {
            VStack(spacing: 0) {
                AllShortcutsView()
                Divider()
                Button("Done") { showsAllShortcuts = false }
                    .keyboardShortcut(.escape, modifiers: [])
                    .padding(8)
            }
        }
        .onAppear(perform: startKeyMonitor)
        .onDisappear(perform: stopKeyMonitor)
        // Refresh on open, but do NOT start or stop the poll loop here. The
        // loop belongs to the app, not to this view: `MenuBarExtra(.window)`
        // builds its content only when the panel is first clicked and tears it
        // down when it closes, so a loop owned here would never run while the
        // panel is shut — which is most of the time, and exactly when the menu
        // bar count needs to stay honest.
        // Refresh whenever the panel opens. The poll loop itself is started
        // once by `AppDelegate` and runs for the app's whole life, so the
        // count beside the icon stays honest while the panel is closed.
        .task { await app.refresh() }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var app = app

        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("Filter…", text: $app.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
                    .onChange(of: searchFocused) { _, focused in
                        app.isSearchFocused = focused
                    }

                if !app.searchText.isEmpty {
                    Button {
                        app.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                Menu {
                    GroupSortMenuItems()
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Grouping and sorting")

                Button {
                    Task { await app.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(app.isSyncing)
                .help("Refresh (⌘R)")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            TeamChips()
        }
        .padding(.bottom, 6)
    }

    // MARK: Pickers

    @ViewBuilder
    private var pickerOverlay: some View {
        if let activePicker, let issue = app.selectedIssue {
            ZStack {
                // A scrim that also catches the click that dismisses, so the
                // list underneath cannot change selection behind the picker.
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture { self.activePicker = nil }

                switch activePicker {
                case .status: statusPicker(for: issue)
                case .priority: priorityPicker(for: issue)
                case .dueDate: duePicker(for: issue)
                case .hideUntil: hidePicker(for: issue)
                }
            }
            .transition(.opacity)
        }
    }

    private func statusPicker(for issue: Issue) -> some View {
        let states = app.availableStates(for: issue)
        return PickerOverlay(
            title: "\(issue.identifier) — status in \(issue.team.key)",
            options: states.map {
                PickerOption(id: $0.id, title: $0.name, subtitle: nil,
                             tint: Color(linearHex: $0.color), value: $0)
            },
            hint: states.isEmpty ? "Statuses still loading…" : nil,
            onPick: { state in
                app.setState(issue, to: state)
                activePicker = nil
            },
            onCancel: { activePicker = nil })
    }

    private func priorityPicker(for issue: Issue) -> some View {
        PickerOverlay(
            title: "\(issue.identifier) — priority",
            options: Priority.allCases
                .sorted { $0.sortRank < $1.sortRank }
                .map {
                    PickerOption(id: String($0.rawValue), title: $0.fallbackLabel,
                                 subtitle: String($0.rawValue),
                                 symbolName: $0.symbolName, tint: $0.tint, value: $0)
                },
            hint: "Type 0–4 to jump",
            parseFreeform: { text in
                guard let raw = Int(text), let priority = Priority(rawValue: raw) else { return nil }
                return (priority.fallbackLabel, priority)
            },
            onPick: { priority in
                app.setPriority(issue, to: priority)
                activePicker = nil
            },
            onCancel: { activePicker = nil })
    }

    private func duePicker(for issue: Issue) -> some View {
        let today = CalendarDate.today()
        var options: [PickerOption<CalendarDate?>] = []
        if let tomorrow = today.adding(days: 1) {
            options = [
                PickerOption(id: "today", title: "Today", subtitle: today.wireValue, value: today),
                PickerOption(id: "tomorrow", title: "Tomorrow", subtitle: tomorrow.wireValue, value: tomorrow),
            ]
        }
        if let week = today.adding(days: 7) {
            options.append(PickerOption(id: "week", title: "Next week", subtitle: week.wireValue, value: week))
        }
        if issue.dueDate != nil {
            options.append(PickerOption(id: "clear", title: "Clear due date",
                                        symbolName: "xmark", value: nil))
        }

        return PickerOverlay<CalendarDate?>(
            title: "\(issue.identifier) — due date",
            options: options,
            hint: "today · fri · +3d · 2026-11-05 · none",
            parseFreeform: { text in
                switch DateParsing.parse(text) {
                case .date(let date): return (date.wireValue, date)
                case .clear: return ("Clear due date", nil)
                case nil: return nil
                }
            },
            onPick: { date in
                app.setDueDate(issue, to: date)
                activePicker = nil
            },
            onCancel: { activePicker = nil })
    }

    private func hidePicker(for issue: Issue) -> some View {
        let now = Date()
        let options: [PickerOption<Date>] = [
            PickerOption(id: "3h", title: "In 3 hours", symbolName: "clock",
                         value: now.addingTimeInterval(3 * 3600)),
            PickerOption(id: "tomorrow", title: "Tomorrow morning", symbolName: "sunrise",
                         value: Self.tomorrowMorning(from: now)),
            PickerOption(id: "week", title: "Next week", symbolName: "calendar",
                         value: now.addingTimeInterval(7 * 86400)),
            PickerOption(id: "month", title: "In a month", symbolName: "calendar",
                         value: now.addingTimeInterval(30 * 86400)),
        ]
        return PickerOverlay(
            title: "\(issue.identifier) — hide locally, Linear unchanged",
            options: options,
            hint: "Hidden issues come back on their own. ⌘Z to undo.",
            onPick: { date in
                app.hide(issue, until: date)
                activePicker = nil
            },
            onCancel: { activePicker = nil })
    }

    private static func tomorrowMorning(from now: Date) -> Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    // MARK: Keyboard

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // A picker owns the keyboard while it is up: it has its own field
            // and its own ↑/↓, and letting the list also act on those keys is
            // how a picker ends up moving the selection behind itself.
            guard activePicker == nil else { return event }
            guard !isEditingText else { return event }
            guard let key = KeyInput(event) else { return event }
            let modifiers = KeyModifiers(event.modifierFlags)
            guard let action = KeyMap.action(
                for: key, modifiers: modifiers, isSearching: app.isSearchFocused)
            else { return event }
            handle(action)
            return nil
        }
    }

    private func stopKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Whether a text field is currently taking keystrokes.
    ///
    /// The monitor below sees **every** key the app receives, so without this
    /// check it swallows typing: the comment composer was completely unusable
    /// (every letter routed to a verb — "e" completed the task you were
    /// commenting on) and the filter field only worked by accident.
    ///
    /// When text has focus the panel keeps its hands off entirely, including
    /// `⌘C` and `⌘Z`, which must mean copy-text and undo-typing there.
    private var isEditingText: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isFieldEditor || textView.isEditable }
        return responder is NSTextField
    }

    private func handle(_ action: PanelAction) {
        let issue = app.selectedIssue

        switch action {
        case .moveSelection(let offset):
            app.moveSelection(by: offset)
        case .moveGroup(let offset):
            app.moveSelectionByGroup(offset)
        case .open:
            if let issue, let url = URL(string: issue.url) { openURL(url) }
        case .toggleDetail:
            guard let issue else { break }
            app.expandedID = app.expandedID == issue.id ? nil : issue.id
        case .showStatusPicker:
            if issue != nil { activePicker = .status }
        case .showPriorityPicker:
            if issue != nil { activePicker = .priority }
        case .showDuePicker:
            if issue != nil { activePicker = .dueDate }
        case .showHidePicker:
            if issue != nil { activePicker = .hideUntil }
        case .showCommentComposer:
            guard let issue else { break }
            app.expandedID = issue.id
        case .complete:
            if let issue { app.complete(issue) }
        case .undo:
            app.undoLastChange()
        case .copyLink:
            if let issue { IssuePasteboard.copy(issue) }
        case .copyBranchName:
            if let issue { IssuePasteboard.copyBranchName(issue) }
        case .refresh:
            Task { await app.refresh() }
        case .cycleGrouping:
            app.preferences.groupBy = GroupBy.allCases.next(after: app.preferences.groupBy)
        case .cycleSort:
            app.preferences.sortBy = SortBy.allCases.next(after: app.preferences.sortBy)
        case .toggleBacklog:
            app.preferences.showsBacklog.toggle()
        case .cycleTeam(let offset):
            cycleTeam(by: offset)
        case .selectTeamIndex(let index):
            let chips = app.teamChips
            app.preferences.teamID = chips.indices.contains(index) ? chips[index].team.id : nil
        case .focusSearch:
            searchFocused = true
        case .showAllShortcuts:
            showsAllShortcuts = true
        case .appendSearch(let character):
            app.searchText.append(character)
        case .deleteSearchCharacter:
            if !app.searchText.isEmpty { app.searchText.removeLast() }
        case .escape:
            // Escape unwinds one layer at a time, outermost last — the Mac
            // convention, and the reason it never surprises.
            if activePicker != nil {
                activePicker = nil
            } else if !app.searchText.isEmpty {
                app.searchText = ""
            } else if app.expandedID != nil {
                app.expandedID = nil
            } else {
                // Esc on the bare panel hides it **and hands the keyboard back
                // to whatever app you came from** (Brandon, 2026-10-20).
                // Dismissing without that leaves an accessory app holding
                // focus and nothing on screen to type into.
                menuBar?.close(restoringFocus: true)
            }
        case .openWindow:
            // `NSApp.sendAction(Selector(("openMainWindow:")))` was a guess and
            // no such selector exists, so ⌘0 silently did nothing. The scene's
            // own id is the supported route.
            menuBar?.close()
            openWindow(id: "main")
        }
    }

    /// `←`/`→` walk "All" plus each team, wrapping at both ends.
    private func cycleTeam(by offset: Int) {
        let ids: [String?] = [nil] + app.teamChips.map { $0.team.id }
        guard ids.count > 1 else { return }
        let current = ids.firstIndex(of: app.preferences.teamID) ?? 0
        let next = (current + offset + ids.count) % ids.count
        app.preferences.teamID = ids[next]
    }
}

extension Array where Element: Equatable {
    /// The next element after `current`, wrapping. Used by `G` and `O`.
    func next(after current: Element) -> Element {
        guard let index = firstIndex(of: current), !isEmpty else { return self[0] }
        return self[(index + 1) % count]
    }
}
