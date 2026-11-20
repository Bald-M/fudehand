import AppKit
import FudehandCore
import SwiftUI

/// What the rows of the chat transcript can ask the panel to do.
struct ChatRowActions {
    let regenerate: () -> Void
    let edit: () -> Void
    /// Answers the waiting question; `nil` skips it.
    let answer: (String?) -> Void
    /// A layer's current name by id, for tool card titles.
    let layerName: (String) -> String?
}

/// One group of the transcript: a message, a notice, a tool card, or a run of tool cards folded into "N steps".
struct ChatGroupRow: View {
    let group: ChatGroup
    /// The reply is still running and this is the newest group.
    let active: Bool
    /// Whether the message can be regenerated (the last assistant message) or edited (the last user message).
    let actionable: Bool
    let actions: ChatRowActions
    @Environment(\.locale) private var locale

    var body: some View {
        let _ = locale // Re-render when the UI language changes.
        if group.isSteps {
            ToolSteps(entries: group.entries, active: active, layerName: actions.layerName)
        } else {
            let entry = group.entries[0]
            switch entry.kind {
            case .user: UserMessage(entry: entry, editable: actionable, edit: actions.edit)
            case .assistant: AssistantMessage(entry: entry, streaming: active, regenerable: actionable, regenerate: actions.regenerate)
            case .tool: ToolCard(entry: entry, layerName: actions.layerName)
            case .question: QuestionCard(entry: entry, answer: actions.answer)
            case .error:
                Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            case .notice:
                Text(entry.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            case .summary: CompactedSummary(entry: entry)
            }
        }
    }
}

/// Where the conversation was compacted: the Agent continues from the summary, which can be opened here; the messages above stay for reading.
private struct CompactedSummary: View {
    let entry: ChatEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                    Text(L("Context compacted"))
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold))
                }
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(expanded ? L("Hide summary") : L("Show summary"))
            if expanded {
                Text(entry.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

private struct UserMessage: View {
    let entry: ChatEntry
    let editable: Bool
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            if editable { MessageButton(title: L("Edit and resend"), symbol: "pencil", action: edit) }
            VStack(alignment: .leading, spacing: 6) {
                if !entry.context.isEmpty {
                    Text(entry.context.map(\.name).joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .accessibilityLabel(L("Selected layers: %@", entry.context.map(\.name).joined(separator: ", ")))
                }
                Text(entry.text).textSelection(.enabled)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
        }
        .frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 16)
    }
}

private struct AssistantMessage: View {
    let entry: ChatEntry
    let streaming: Bool
    let regenerable: Bool
    let regenerate: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MarkdownText(text: entry.text, language: L10n.language).equatable()
            if !streaming {
                HStack(spacing: 2) {
                    CopyButton(text: entry.text, title: L("Copy message"))
                    if regenerable { MessageButton(title: L("Regenerate"), symbol: "arrow.clockwise", action: regenerate) }
                    if let usage = entry.usage {
                        Text(L("%@ tokens", ChatUsage.compact(usage.total)))
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary).padding(.leading, 4)
                            .help(L("Input %@ (%@ cached) · Output %@", ChatUsage.compact(usage.input), ChatUsage.compact(usage.cached), ChatUsage.compact(usage.output)))
                    }
                }
                // The newest reply always shows its actions; earlier ones show them under the pointer.
                .opacity(hovering || regenerable ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle()).onHover { hovering = $0 }
    }
}

private struct MessageButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.caption).frame(width: 22, height: 20) }
            .buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
}

/// Copies `text` to the clipboard, and shows a checkmark briefly to confirm.
private struct CopyButton: View {
    let text: String
    let title: String
    @State private var copied = false

    var body: some View {
        MessageButton(title: copied ? L("Copied") : title, symbol: copied ? "checkmark" : "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
    }
}

/// An assistant reply drawn as Markdown. Equatable, so a streaming reply only re-renders its own text.
private struct MarkdownText: View, Equatable {
    let text: String
    /// Not drawn; makes the code block labels follow a change of the UI language.
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(ChatMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text): prose(text)
                case .heading(let level, let text):
                    prose(text).font(level == 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold()).padding(.top, 2)
                case .item(let marker, let indent, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary).monospacedDigit()
                        prose(text)
                    }.padding(.leading, CGFloat(indent) * 16)
                case .code(let language, let text): CodeBlock(language: language, text: text)
                case .quote(let text):
                    prose(text).foregroundStyle(.secondary).padding(.leading, 10)
                        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(.quaternary).frame(width: 3) }
                case .rule: Divider()
                }
            }
        }
    }

    /// Inline Markdown: bold, italic, inline code, and links.
    private func prose(_ text: String) -> some View {
        let styled = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        return Text(styled).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CodeBlock: View {
    let language: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? L("Code") : language).font(.caption).foregroundStyle(.secondary)
                Spacer()
                CopyButton(text: text, title: L("Copy code"))
            }.padding(.leading, 10).padding(.trailing, 4).padding(.top, 2)
            // Long lines scroll sideways instead of wrapping.
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text).font(.callout.monospaced()).textSelection(.enabled)
                    .fixedSize().padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 2)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A question the Agent paused to ask. While it waits: the options (the Agent's recommendation first), a field for another answer,
/// and a way to skip. Afterwards it folds down to the question and its answer.
private struct QuestionCard: View {
    let entry: ChatEntry
    let answer: (String?) -> Void
    @State private var custom = ""

    var body: some View {
        if let question = entry.question {
            Group {
                switch question.state {
                case .pending: pending(question)
                case .answered(let text): settled(text)
                case .skipped: settled(L("Skipped, AI decides"))
                case .cancelled: settled(L("Question canceled")).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        }
    }

    private func pending(_ question: ChatQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("A quick question"), systemImage: "questionmark.circle").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            Text(entry.text).fontWeight(.semibold).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let detail = question.detail {
                Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                Button { answer(option.label) } label: { optionLabel(option, recommended: index == 0) }.buttonStyle(.plain)
            }
            HStack(spacing: 6) {
                TextField(L("Your answer"), text: $custom, prompt: Text(L("Other: write your own answer")))
                    .textFieldStyle(.roundedBorder).labelsHidden().onSubmit(sendCustom)
                Button(L("Answer"), action: sendCustom).buttonStyle(.borderedProminent)
                    .disabled(custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .controlSize(.small)
            Button(L("Skip, let AI decide")) { answer(nil) }.buttonStyle(.link).font(.callout)
        }
        .padding(12)
    }

    private func optionLabel(_ option: ChatQuestion.Option, recommended: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let label = Text(option.label).fontWeight(.semibold)
            if recommended {
                let tag = Text(L("Recommended")).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                // The tag sits beside a label that fits on one line, and under one that wraps.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { label.lineLimit(1); tag }
                    VStack(alignment: .leading, spacing: 3) { label; tag }
                }
            } else {
                label
            }
            if let description = option.description {
                Text(description).font(.callout).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(recommended ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.clear)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private func settled(_ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.text).font(.callout).foregroundStyle(.secondary)
            Text(answer).fontWeight(.semibold)
        }
        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func sendCustom() {
        let text = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { answer(text) }
    }
}

/// A run of consecutive tool calls, folded into one line once the Agent has moved on.
private struct ToolSteps: View {
    let entries: [ChatEntry]
    let active: Bool
    let layerName: (String) -> String?
    /// The user's choice; until they make one, the steps are open only while they are the newest thing happening.
    @State private var expanded: Bool?

    var body: some View {
        let open = expanded ?? active
        let failed = entries.filter { $0.status == .failed }.count
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded = !open } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2).frame(width: 10)
                    Text(failed == 0 ? L("Ran %d steps", entries.count) : L("Ran %d steps, %d failed", entries.count, failed)).font(.callout)
                    Spacer()
                }.foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if open { ForEach(entries) { ToolCard(entry: $0, layerName: layerName) } }
        }
    }
}

/// One tool call: what it did and whether it worked, opening to show the arguments and the result.
private struct ToolCard: View {
    let entry: ChatEntry
    let layerName: (String) -> String?
    @State private var expanded = false

    var body: some View {
        let title = [Self.action(entry.text), ChatEntry.toolSubject(arguments: entry.detail, layerName: layerName)].compactMap { $0 }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    status.frame(width: 14, height: 14)
                    Text(title).font(.callout).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }.padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(statusName)
            if expanded {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    section(L("Arguments"), entry.detail)
                    section(L("Result"), entry.result)
                    Text(entry.text).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }.padding(10)
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    @ViewBuilder private var status: some View {
        switch entry.status {
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        default: ProgressView().controlSize(.small).scaleEffect(0.7)
        }
    }

    private var statusName: String {
        switch entry.status {
        case .succeeded: L("Succeeded")
        case .failed: L("Failed")
        default: L("Running")
        }
    }

    @ViewBuilder private func section(_ title: String, _ text: String?) -> some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(text).font(.caption.monospaced()).textSelection(.enabled).lineLimit(30)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// What a tool does, in the UI language; an unknown tool shows its name.
    private static func action(_ tool: String) -> String {
        switch tool {
        case "design_get_state": L("Read document overview")
        case "design_get_document": L("Read layer tree")
        case "design_get_node": L("Read layer")
        case "design_create_node": L("Create layer")
        case "design_update_node": L("Update layer")
        case "design_delete_nodes": L("Delete layers")
        case "design_move_node": L("Move layer")
        case "design_select": L("Select layers")
        case "design_undo": L("Undo")
        case "design_redo": L("Redo")
        case "design_new_document": L("Create document")
        case "design_open_document": L("Open document")
        case "design_save_document": L("Save document")
        case "design_snapshot": L("Take snapshot")
        case "canvas_focus_node": L("Focus layer")
        case "canvas_fit_all": L("Fit All")
        case "canvas_zoom": L("Zoom canvas")
        case "prototype_play": L("Play Prototype")
        case "prototype_get_playback": L("Read prototype window")
        case "prototype_close": L("Close prototype window")
        case "canvas_set_view": L("Change view")
        default: tool
        }
    }
}
