import Foundation
import Testing

@testable import Lineado

// MARK: - The variables-type divergence

@Suite("GraphQL variable encoding")
struct JSONValueTests {

    /// **The reason `JSONValue` exists at all.**
    ///
    /// Inbox & Chill types GraphQL variables `[String: String]`. On that map,
    /// "clear the due date" and "do nothing" are the same request, because the
    /// only way to express absence is to omit the key — and an omitted key in
    /// `issueUpdate` means "leave unchanged". This test is what stops someone
    /// simplifying the type back.
    @Test("A nil due date encodes as explicit JSON null, not an absent key")
    func nilEncodesAsNull() throws {
        let body = GraphQLRequestBody(
            query: "mutation {}",
            variables: ["id": .string("abc"), "dueDate": JSONValue(nil)])
        let json = try String(decoding: JSONEncoder().encode(body), as: UTF8.self)
        #expect(json.contains("\"dueDate\":null"))
    }

    @Test("A date encodes as its bare wire string")
    func dateEncodesAsString() throws {
        let date = CalendarDate(year: 2026, month: 11, day: 5)
        let body = GraphQLRequestBody(query: "m", variables: ["dueDate": JSONValue(date.wireValue)])
        let json = try String(decoding: JSONEncoder().encode(body), as: UTF8.self)
        #expect(json.contains("\"dueDate\":\"2026-11-05\""))
    }

    /// `issueUpdate(input: { priority: })` takes an Int. A quoted "2" is a type
    /// error on Linear's side, not a coercion.
    @Test("Priority encodes as a number, never a quoted string")
    func priorityEncodesAsInt() throws {
        let body = GraphQLRequestBody(query: "m", variables: ["priority": .int(2)])
        let json = try String(decoding: JSONEncoder().encode(body), as: UTF8.self)
        #expect(json.contains("\"priority\":2"))
        #expect(!json.contains("\"priority\":\"2\""))
    }
}

// MARK: - State types

@Suite("Workflow state types")
struct StateTypeTests {

    /// Verified against the live workspace on 2026-10-20: Core UX has a
    /// "Duplicate" state typed `duplicate`. Assuming the six documented types
    /// would leave every duplicate on the task list forever.
    @Test("duplicate is a real type, distinct from canceled")
    func duplicateIsDistinct() {
        #expect(StateType(wireValue: "duplicate") == .duplicate)
        #expect(StateType.duplicate != StateType.canceled)
        #expect(StateType.terminal.contains(.duplicate))
        #expect(StateType.terminal.count == 3)
    }

    /// Linear adds state types. An enum that failed to decode a new one would
    /// take the whole poll — and so the whole list — down with it.
    @Test("An unknown type decodes rather than throwing")
    func unknownTypeIsTolerated() throws {
        let json = #"{"id":"s","name":"Weird","type":"somethingNew","position":1}"#
        let node = try JSONDecoder.linear.decode(IssueNode.StateNode.self, from: Data(json.utf8))
        let state = LinearMapper.workflowState(from: node)
        #expect(state.type == .unknown)
        #expect(state.name == "Weird")
    }

    @Test("Only backlog hides under the Backlog toggle")
    func onlyBacklogIsBacklog() {
        #expect(StateType.backlog.isBacklog)
        for type in StateType.allCases where type != .backlog {
            #expect(!type.isBacklog, "\(type) should not hide with Backlog")
        }
    }

    @Test("Lifecycle ranks are unique and ordered")
    func lifecycleRanks() {
        #expect(StateType.triage.lifecycleRank < StateType.backlog.lifecycleRank)
        #expect(StateType.backlog.lifecycleRank < StateType.unstarted.lifecycleRank)
        #expect(StateType.unstarted.lifecycleRank < StateType.started.lifecycleRank)
    }
}

// MARK: - Mapping

@Suite("Wire to domain mapping")
struct MapperTests {

    /// Linear sends fractional seconds. A plain `.iso8601` strategy rejects
    /// them, and the failure is the whole poll, not one field.
    @Test("Timestamps with fractional seconds decode")
    func fractionalSecondsDecode() throws {
        let json = #"{"id":"i","createdAt":"2026-10-20T13:50:52.039Z","updatedAt":"2026-10-20T13:50:52Z"}"#
        let node = try JSONDecoder.linear.decode(IssueNode.self, from: Data(json.utf8))
        #expect((node.createdAt ?? .distantPast) > Date(timeIntervalSince1970: 1_700_000_000))
        #expect((node.updatedAt ?? .distantPast) > Date(timeIntervalSince1970: 1_700_000_000))
    }

    /// Swift's synthesised `Decodable` does **not** fall back to a property's
    /// default value for a missing key — it throws `keyNotFound`, and one
    /// missing key fails the whole decode, which here is the whole poll and so
    /// the whole list. Optional properties are what make absence survivable.
    /// This test is what stops someone "tidying" the wire types back to
    /// non-optionals with defaults.
    @Test("A payload missing most fields still decodes")
    func missingFieldsSurvive() throws {
        let json = #"{"id":"i"}"#
        let node = try JSONDecoder.linear.decode(IssueNode.self, from: Data(json.utf8))
        #expect(node.id == "i")
        #expect(node.identifier == nil)
        // It maps to nothing, because a row needs a team — but it did not throw.
        #expect(LinearMapper.issue(from: node) == nil)
    }

    /// An issue with no team cannot have its status changed (statuses are
    /// per-team) and cannot be completed, so a row for it would have dead keys.
    @Test("Nodes with no team or no state are dropped and counted")
    func dropsUnusableNodes() {
        var usable = IssueNode()
        usable.id = "1"
        usable.identifier = "CORE-1"
        usable.state = .init(id: "s", name: "To Do", type: "unstarted", position: 1)
        usable.team = .init(id: "t", key: "CORE", name: "Core UX")

        var teamless = IssueNode()
        teamless.id = "2"
        teamless.state = usable.state

        let (issues, dropped) = LinearMapper.issues(from: [usable, teamless])
        #expect(issues.count == 1)
        #expect(dropped == 1)
        #expect(issues[0].identifier == "CORE-1")
    }

    /// Spelled `Priority.none`, not `.none`: against an `Optional<Priority>`
    /// the shorthand resolves to `Optional.none` — i.e. nil — and the test
    /// would pass for the wrong reason if the mapper started returning nil.
    @Test("An out-of-range priority falls back to No priority rather than failing")
    func unknownPriority() {
        var node = IssueNode()
        node.id = "1"
        node.priority = 99
        node.state = .init(id: "s", name: "To Do", type: "unstarted", position: 1)
        node.team = .init(id: "t", key: "CORE", name: "Core UX")
        let mapped = LinearMapper.issue(from: node)
        #expect(mapped != nil)
        #expect(mapped?.priority == Priority.none)
    }

    @Test("States with no team are left out of the picker cache")
    func statesByTeamSkipsTeamless() {
        let nodes: [IssueNode.StateNode] = [
            .init(id: "a", name: "To Do", type: "unstarted", position: 2,
                  team: .init(id: "core", key: "CORE", name: "Core UX")),
            .init(id: "b", name: "Orphan", type: "unstarted", position: 1, team: nil),
        ]
        let byTeam = LinearMapper.statesByTeam(from: nodes)
        #expect(byTeam.keys.sorted() == ["core"])
        #expect(byTeam["core"]?.count == 1)
    }

    @Test("Picker states come back in Linear's own lifecycle order")
    func statesSortedForPicker() {
        let team = IssueNode.TeamNode(id: "core", key: "CORE", name: "Core UX")
        let nodes: [IssueNode.StateNode] = [
            .init(id: "c", name: "In Progress", type: "started", position: 3, team: team),
            .init(id: "a", name: "Backlog", type: "backlog", position: 1, team: team),
            .init(id: "b", name: "To Do", type: "unstarted", position: 2, team: team),
        ]
        let states = LinearMapper.statesByTeam(from: nodes)["core"] ?? []
        #expect(states.map(\.name) == ["Backlog", "To Do", "In Progress"])
    }

    @Test("Comments come back oldest first, so the thread reads downward")
    func commentsSorted() {
        let nodes: [CommentNode] = [
            .init(id: "2", body: "second", createdAt: Date(timeIntervalSince1970: 200)),
            .init(id: "1", body: "first", createdAt: Date(timeIntervalSince1970: 100)),
        ]
        #expect(LinearMapper.comments(from: nodes).map(\.body) == ["first", "second"])
    }
}

// MARK: - The query itself

@Suite("Query shape")
struct QueryTests {

    /// Omitting any one of the three terminal types leaves those issues on the
    /// list permanently, which looks like a sync bug and is not.
    @Test("The assigned query excludes all three terminal state types")
    func excludesTerminalStates() {
        for type in StateType.terminal {
            #expect(LinearQueries.assignedIssues.contains("\"\(type.wireValue)\""),
                    "assignedIssues must exclude \(type.wireValue)")
        }
    }

    /// `isMe` is not in Linear's published filter documentation (checked
    /// 2026-10-20), so the query goes through `viewer` instead.
    @Test("The assigned query goes through viewer, not an isMe filter")
    func usesViewer() {
        #expect(LinearQueries.assignedIssues.contains("assignedIssues"))
        #expect(!LinearQueries.assignedIssues.contains("isMe"))
    }

    @Test("Mutations return the full issue so a row can reconcile without a poll")
    func mutationsReturnIssue() {
        for document in [LinearQueries.setState, LinearQueries.setPriority, LinearQueries.setDueDate] {
            #expect(document.contains("issue {"))
            #expect(document.contains("priorityLabel"))
        }
    }

    /// The scope boundary, as a test: Lineado is not a Linear client (PLAN §2).
    @Test("No mutation creates, deletes or reassigns anything")
    func scopeBoundary() {
        let documents = [
            LinearQueries.setState, LinearQueries.setPriority,
            LinearQueries.setDueDate, LinearQueries.addComment,
        ]
        for document in documents {
            #expect(!document.contains("issueCreate"))
            #expect(!document.contains("issueDelete"))
            #expect(!document.contains("issueArchive"))
            #expect(!document.contains("assigneeId"))
        }
    }
}
