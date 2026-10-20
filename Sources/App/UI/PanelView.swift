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

    @State private var activePicker: ActivePicker?
    @State private var keyMonitor: Any?

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
            FooterView()
        }
        .frame(width: 460, height: 560)
        .overlay(alignment: .center) { pickerOverlay }
        .onAppear(perform: startKeyMonitor)
        .onDisappear(perform: stopKeyMonitor)
        .task {
            app.start()
            await app.refresh()
        }
    }

    // MARK: Header

    private var header: some View {
        @Bindable var app = app

        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("Filter…", text: $app.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)

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
        app.stop()
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
            app.isSearchFocused = true
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
                PanelToggler.close()
            }
        case .openWindow:
            PanelToggler.close()
            NSApp.sendAction(Selector(("openMainWindow:")), to: nil, from: nil)
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
