import SwiftUI

/// The expanded row: description, recent comments, and a composer.
///
/// The thread is shown rather than a bare composer because nearly every comment
/// written from a list is a *reply*. A fire-and-forget box would send you to
/// Linear to read what you are answering, which is the trip the app exists to
/// prevent (PLAN §6.5).
struct IssueDetailView: View {
    let issue: Issue
    let detail: IssueDetail?

    @Environment(AppState.self) private var app
    @State private var draft = ""
    @State private var isPosting = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let parent = issue.parent {
                Label("\(parent.identifier) \(parent.title)", systemImage: "arrow.turn.up.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !issue.labels.isEmpty {
                labelChips
            }

            if let detail {
                if let description = detail.description, !description.isEmpty {
                    MarkdownText(raw: description, lineLimitPerBlock: 6)
                }

                if detail.comments.isEmpty {
                    Text("No comments yet.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    comments(detail.comments)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Loading…").font(.caption).foregroundStyle(.tertiary)
                }
            }

            composer
        }
        .task(id: issue.id) {
            app.loadDetailIfNeeded(for: issue)
        }
    }

    private var labelChips: some View {
        HStack(spacing: 6) {
            ForEach(issue.labels) { label in
                HStack(spacing: 3) {
                    Circle()
                        .fill(Color(linearHex: label.color) ?? .secondary)
                        .frame(width: 6, height: 6)
                    Text(label.name).font(.caption2)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
            }
        }
        .foregroundStyle(.secondary)
    }

    private func comments(_ comments: [IssueComment]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Newest last, so reading top to bottom follows the conversation.
            ForEach(comments.suffix(6)) { comment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(comment.authorName)
                            .font(.caption)
                            .fontWeight(.medium)
                        Text(comment.createdAt.shortRelative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    MarkdownText(raw: comment.body, lineLimitPerBlock: 6)
                }
            }
            if comments.count > 6 {
                Text("\(comments.count - 6) earlier comment\(comments.count - 6 == 1 ? "" : "s") — press ⏎ to open in Linear")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 2)
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Comment…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($composerFocused)
                .disabled(isPosting)
                .onSubmit(post)

            HStack(spacing: 8) {
                Text("⌘⏎ to post")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if isPosting { ProgressView().controlSize(.mini) }
                Button("Post", action: post)
                    .controlSize(.small)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPosting)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func post() {
        let body = draft
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isPosting = true
        Task {
            let posted = await app.postComment(on: issue, body: body)
            isPosting = false
            // The draft survives a failure on purpose — losing typed text
            // because the network blipped is the worst possible response.
            if posted { draft = "" }
        }
    }
}
