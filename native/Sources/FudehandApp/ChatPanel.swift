import AppKit
import FudehandCore
import SwiftUI

/// The chat panel: conversations with the in-App Agent, which reads and edits the design document through the same tools as MCP.
struct ChatPanel: View {
    @ObservedObject var chat: ChatSession
    let root: URL?
    let runtime: WorkspaceLocation?
    /// The layers selected on the canvas, offered as context for the next message.
    let selection: [ChatContext]
    /// A layer's current name by id, for tool card titles.
    let layerName: (String) -> String?
    @State private var draft = ""
    /// Set to show the model settings sheet; `provider` picks the provider it opens on (nil = the one in use).
    @State private var settingsFor: SettingsTarget?
    /// Selected layers whose context tag the user removed; forgotten once the layer is no longer selected.
    @State private var dismissed: Set<String> = []
    /// The last user message is in the input to be changed; sending replaces it and its reply.
    @State private var editing = false
    /// The row of the command menu that Return would choose.
    @State private var highlight = 0
    /// The input text for which Esc closed the command menu; the menu opens again once the text changes.
    @State private var menuClosedFor: String?
    /// The menu row the arrow keys last moved to, to scroll a long list to it; hovering highlights without scrolling.
    @State private var menuScrollTarget: String?
    /// Why the command in the input was not run; shown until the input changes.
    @State private var commandError: String?
    /// Scroll position bookkeeping, kept out of view state so scrolling does not re-render the panel every frame.
    @State private var scroll = ScrollTracker()
    @State private var following = true
    @State private var atBottom = true
    @FocusState private var inputFocused: Bool
    @Environment(\.locale) private var locale

    private struct SettingsTarget: Identifiable {
        let id = UUID()
        var provider: String?
    }

    /// The menu above the input while a slash command is being typed: the commands, or the models once `/model` is chosen.
    private struct CommandMenu {
        var title: String
        /// Shown when nothing matches what was typed.
        var empty: String
        /// Whether the rows are commands, whose names line up in a column.
        var commands: Bool
        var items: [Item]

        struct Item: Identifiable {
            let id: String
            var name: String
            var detail: String
            var checked = false
            var run: () -> Void
        }
    }

    private static let bottom = "bottom"

    private var busy: Bool { chat.transcript.busy }
    /// The Agent asked a question and the reply is paused until it is answered.
    private var waiting: Bool { chat.transcript.waiting }
    private var context: [ChatContext] { selection.filter { !dismissed.contains($0.id) } }
    /// The predicted next message to offer in the empty input. Not while the last message is being edited: sending would replace that message with it.
    /// Not offered in plan or goal mode, where the placeholder says what the mode expects.
    private var suggestion: String? { editing || waiting || chat.mode != nil ? nil : chat.transcript.suggestion }

    var body: some View {
        let _ = locale // Re-render when the UI language changes.
        VStack(spacing: 0) {
            header
            Divider()
            if !chat.hasKey { missingKey }
            messages
            composer
        }
        .frame(minWidth: 300)
        .sheet(item: $settingsFor) { target in ChatSettingsSheet(chat: chat, root: root, runtime: runtime, provider: target.provider) }
        .onChange(of: selection.map(\.id)) { _, ids in dismissed.formIntersection(ids) }
        .onChange(of: draft) {
            highlight = 0
            commandError = nil
            menuClosedFor = nil
        }
        // The message being edited is gone: something was sent, or another conversation is shown.
        .onChange(of: chat.transcript.lastUserID) { editing = false }
        .onChange(of: chat.conversationID) {
            // A message taken back for editing belongs to the conversation that was left; it is not carried into this one.
            if editing { draft = "" }
            editing = false
            // The conversation shown starts at its newest message.
            scroll.follow = ChatScrollFollow()
            following = true
            atBottom = true
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            tabStrip
            Button { chat.newConversation(); inputFocused = true } label: { Image(systemName: "plus").iconHitTarget() }
                .buttonStyle(.borderless).help(L("New conversation")).accessibilityLabel(L("New conversation"))
                .disabled(chat.transcript.entries.isEmpty)
            Menu {
                ForEach(chat.conversations) { conversation in
                    Button { chat.open(conversation.id) } label: {
                        if conversation.id == chat.conversationID { Label(conversation.title, systemImage: "checkmark") } else { Text(conversation.title) }
                    }
                }
                if chat.conversations.isEmpty { Text(L("No saved conversations")) }
                Divider()
                Button(L("Delete This Conversation"), role: .destructive) { chat.deleteConversation() }
                    .disabled(chat.transcript.entries.isEmpty || busy)
            } label: {
                Label(L("Conversation history"), systemImage: "clock.arrow.circlepath").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("Conversation history"))
            Button { settingsFor = SettingsTarget(provider: nil) } label: { Image(systemName: "gearshape").iconHitTarget() }
                .buttonStyle(.borderless).help(L("Model settings")).accessibilityLabel(L("Model settings"))
        }.padding(.leading, 12).padding(.trailing, 16).padding(.vertical, 8)
    }

    /// The open conversations as tabs. They share the header's width, shortening their names; once even the shortest
    /// names do not fit, the row scrolls sideways and keeps the selected tab in view.
    private var tabStrip: some View {
        // A tab at its narrowest: the shortest name, the progress dot, the close button, and the padding around them.
        let narrowest = CGFloat(chat.tabs.count) * (Self.shortestTabName + 44) + CGFloat(chat.tabs.count - 1) * 4
        return GeometryReader { header in
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(chat.tabs) { tab in conversationTab(tab) }
                    }
                    .frame(width: max(header.size.width, narrowest), alignment: .leading)
                }
                .onChange(of: chat.conversationID, initial: true) { _, id in proxy.scrollTo(id, anchor: .center) }
            }
        }
        .frame(height: 24)
    }

    private static let shortestTabName: CGFloat = 44

    private func conversationTab(_ tab: ChatSession.Tab) -> some View {
        let selected = tab.id == chat.conversationID
        let title = tab.transcript.title.isEmpty ? L("New conversation") : tab.transcript.title
        return HStack(spacing: 4) {
            if tab.transcript.waiting {
                Circle().strokeBorder(.orange, lineWidth: 2).frame(width: 8, height: 8).accessibilityLabel(L("Waiting for your answer"))
            } else if tab.transcript.busy {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityLabel(L("Replying…"))
            }
            Button { chat.select(tab.id) } label: {
                Text(title).font(.callout.weight(selected ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                    .frame(minWidth: Self.shortestTabName, maxWidth: 120, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(title).accessibilityAddTraits(selected ? .isSelected : [])
            Button { chat.close(tab.id) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).iconHitTarget()
            }
            .buttonStyle(.plain).help(L("Close conversation")).accessibilityLabel(L("Close conversation"))
        }
        .foregroundStyle(selected ? .primary : .secondary)
        .padding(.leading, 10).padding(.trailing, 2).padding(.vertical, 2)
        .background(selected ? AnyShapeStyle(Color(nsColor: .textBackgroundColor)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)))
        .id(tab.id)
    }

    private var missingKey: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "key").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("No API key set for %@", chat.settings.providerTitle)).font(.callout)
                Button(L("Set API Key…")) { settingsFor = SettingsTarget(provider: nil) }.controlSize(.small)
            }
            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }

    private var messages: some View {
        let transcript = chat.transcript
        let groups = transcript.groups
        let lastReply = transcript.lastReplyID
        let actions = ChatRowActions(regenerate: { chat.regenerate(root: root, runtime: runtime) }, edit: edit, answer: answer, layerName: layerName)
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: a lazy stack only estimates its height, and following the newest text needs the real one.
                    VStack(alignment: .leading, spacing: 12) {
                        if groups.isEmpty { emptyState }
                        ForEach(groups) { group in
                            ChatGroupRow(group: group, active: busy && group.id == groups.last?.id,
                                         actionable: !busy && group.id == (group.entries[0].kind == .user ? transcript.lastUserID : lastReply),
                                         actions: actions)
                        }
                        if waiting {
                            HStack(spacing: 6) {
                                Circle().strokeBorder(.orange, lineWidth: 2).frame(width: 8, height: 8)
                                Text(L("Waiting for your answer")).font(.caption).foregroundStyle(.secondary)
                            }
                        } else if busy {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(transcript.compacting ? L("Compacting context…") : L("Replying…")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(16)
                    .background(GeometryReader { content in
                        // Where the content sits in the scroll view: scrolled distance and total height.
                        Color.clear.onChange(of: content.frame(in: .named("chat")), initial: true) { _, frame in
                            scroll.follow.update(offset: -frame.minY, contentHeight: frame.height, viewportHeight: viewport.size.height)
                            if following != scroll.follow.following { following = scroll.follow.following }
                            if atBottom != scroll.follow.atBottom { atBottom = scroll.follow.atBottom }
                        }
                    })
                }
                .coordinateSpace(name: "chat")
                .defaultScrollAnchor(.bottom)
                // Follow new text only while the user is at the bottom.
                .onChange(of: [transcript.entries.count, transcript.entries.last?.text.count ?? 0, busy ? 1 : 0]) {
                    if scroll.follow.following { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    // Also offered when the view is merely left behind, for example after a tool card above was opened.
                    if !following || (!busy && !atBottom) {
                        Button { scroll.follow = ChatScrollFollow(); following = true; proxy.scrollTo(Self.bottom, anchor: .bottom) } label: {
                            Image(systemName: "arrow.down").font(.callout.weight(.semibold)).frame(width: 28, height: 28)
                                .background(.regularMaterial, in: Circle()).overlay(Circle().strokeBorder(.quaternary))
                                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain).help(L("Scroll to bottom")).accessibilityLabel(L("Scroll to bottom")).padding(.bottom, 8)
                    }
                }
            }
        }
        // A different conversation starts over at its newest message, with nothing expanded.
        .id(chat.conversationID)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Let AI build and edit the interface for you.")).font(.callout).foregroundStyle(.secondary)
            ForEach([L("Create a 390×844 mobile home screen with a navigation bar, a card list, and a button"), L("Give every button a corner radius of 12"), L("Take a screenshot to check the current frame")], id: \.self) { example in
                Button { draft = example; inputFocused = true } label: {
                    Text(example).font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }.buttonStyle(.plain)
            }
        }.padding(.vertical, 8)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !context.isEmpty { contextTags }
            if let mode = chat.mode { modeTag(mode) }
            if chat.planReady && !busy {
                HStack(spacing: 8) {
                    Button(L("Run Plan"), action: runPlan).buttonStyle(.borderedProminent).controlSize(.small)
                    Text(L("Or reply to change the plan")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if editing {
                HStack(spacing: 4) {
                    Image(systemName: "pencil")
                    Text(L("Editing the last message"))
                    Spacer()
                    Button { editing = false } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).iconHitTarget() }
                        .buttonStyle(.plain).help(L("Cancel editing")).accessibilityLabel(L("Cancel editing"))
                }.font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Return sends and Shift-Return starts a new line; a draft can be typed while a reply is still running.
                // The placeholder is the predicted next message when there is one, and Tab puts it in the input.
                TextField(L("Message"), text: $draft, prompt: Text(verbatim: placeholder), axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...8).focused($inputFocused)
                    .onSubmit(submit)
                    .modifier(ComposerKeys(text: $draft, suggestion: suggestion, active: inputFocused))
                    .modifier(CommandMenuKeys(text: draft, active: inputFocused && commandMenu != nil, move: moveHighlight, close: { menuClosedFor = draft }))
                    .accessibilityLabel(L("Chat input"))
                if draft.isEmpty, suggestion != nil {
                    Text(L("Tab")).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.tertiary))
                        .help(L("Press Tab to use the predicted message")).accessibilityLabel(L("Press Tab to use the predicted message"))
                }
            }
            if let commandError { Text(commandError).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                modelMenu
                Spacer()
                ContextRing(usage: chat.contextUsage)
                if busy {
                    let stop = waiting ? L("Stop and cancel the question") : chat.transcript.compacting ? L("Stop compacting") : L("Stop replying")
                    Button { chat.stopReply() } label: { Image(systemName: "stop.circle.fill").font(.title2).iconHitTarget() }
                        .buttonStyle(.borderless).help(stop).accessibilityLabel(stop)
                } else {
                    Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2).iconHitTarget() }
                        .buttonStyle(.borderless).help(L("Send (Return)")).accessibilityLabel(L("Send"))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(inputFocused ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(.quaternary)))
        .padding(12)
        // The command menu sits above the input, over the transcript.
        .overlay(alignment: .top) {
            // Anchored to a line along the input's top edge, so the menu takes its own height and grows upward.
            Color.clear.frame(height: 0).overlay(alignment: .bottom) {
                if let menu = commandMenu { commandMenuView(menu).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12) }
            }
        }
        .zIndex(1)
    }

    private var placeholder: String {
        if waiting { return L("Answer the question above, or add details here") }
        switch chat.mode {
        case .plan: return L("Describe what to do; AI plans first")
        case .goal: return L("Describe the goal to reach")
        case nil: return suggestion ?? L("Message")
        }
    }

    private func modeTitle(_ mode: ChatMode) -> String {
        switch mode {
        case .plan: L("Plan mode")
        case .goal: L("Goal mode")
        }
    }

    /// The conversation's mode, with a button to leave it.
    private func modeTag(_ mode: ChatMode) -> some View {
        HStack(spacing: 6) {
            Text(modeTitle(mode)).font(.caption.weight(.semibold))
            Button { chat.mode = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).iconHitTarget()
            }
            .buttonStyle(.plain).help(L("Leave %@", modeTitle(mode))).accessibilityLabel(L("Leave %@", modeTitle(mode)))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.leading, 8).padding(.trailing, 2)
        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
    }

    private func commandSummary(_ command: ChatCommand) -> String {
        switch command {
        case .plan: L("Plan mode: list the steps, edit after you confirm")
        case .goal: L("Goal mode: keep working until the goal is done")
        case .new: L("Start a new conversation")
        case .clear: L("Clear this conversation")
        case .compact: L("Summarize earlier messages to free up context")
        case .model: L("Switch model")
        }
    }

    /// The menu for what is in the input, whether or not Esc closed it; nil when the input is not a command being chosen.
    private var commandChoices: CommandMenu? {
        switch ChatCommandInput(draft) {
        case .typing(let commands):
            return CommandMenu(title: L("Commands"), empty: L("No matching commands"), commands: true, items: commands.map { command in
                CommandMenu.Item(id: command.name, name: command.name, detail: commandSummary(command)) { run(command, argument: "") }
            })
        case .command(.model, let argument):
            let current = chat.settings
            let choices = ModelMenu.choices(providers: modelProviders, provider: current.provider, model: current.model, matching: argument)
            var items = choices.map { choice in
                let name = choice.title.map { choice.isDefault ? "\($0) — \(L("Default"))" : $0 } ?? L("Default model")
                return CommandMenu.Item(id: "\(choice.provider)/\(choice.model)", name: name, detail: choice.providerTitle, checked: choice.selected) { choose(choice) }
            }
            // As in the model menu, the settings come last; they are also the way on when no provider has a key yet.
            if argument.isEmpty {
                items.append(CommandMenu.Item(id: "settings", name: L("Model Settings…"), detail: "") {
                    draft = ""
                    settingsFor = SettingsTarget(provider: nil)
                })
            }
            return CommandMenu(title: L("Models"), empty: L("No matching models"), commands: false, items: items)
        case .message, .command, .unknown:
            return nil
        }
    }

    private var commandMenu: CommandMenu? { menuClosedFor == draft ? nil : commandChoices }

    private func highlighted(in menu: CommandMenu) -> Int { min(max(highlight, 0), menu.items.count - 1) }

    private func moveHighlight(_ step: Int) {
        guard let menu = commandMenu, !menu.items.isEmpty else { return }
        highlight = (highlighted(in: menu) + step + menu.items.count) % menu.items.count
        menuScrollTarget = menu.items[highlight].id
    }

    private func commandMenuView(_ menu: CommandMenu) -> some View {
        let current = highlighted(in: menu)
        let rows = VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(menu.items.enumerated()), id: \.element.id) { index, item in
                Button(action: item.run) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.name).font(.system(.caption, design: .monospaced).weight(.semibold)).foregroundStyle(Color.accentColor)
                            .lineLimit(1).frame(width: menu.commands ? 56 : nil, alignment: .leading)
                        Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(menu.commands ? 2 : 1)
                        Spacer(minLength: 0)
                        if item.checked { Image(systemName: "checkmark").font(.caption2.weight(.bold)).accessibilityHidden(true) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(index == current ? AnyShapeStyle(Color.accentColor.opacity(0.14)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).onHover { if $0 { highlight = index } }
                .accessibilityAddTraits(item.checked ? .isSelected : []).id(item.id)
            }
        }
        return VStack(alignment: .leading, spacing: 1) {
            Text(menu.title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 2)
            if menu.items.isEmpty {
                Text(menu.empty).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 6)
            } else if menu.items.count > 7 {
                // A long model list scrolls, following the arrow keys.
                ScrollViewReader { proxy in
                    ScrollView { rows }.frame(height: 200)
                        .onChange(of: menuScrollTarget) { _, id in if let id { proxy.scrollTo(id) } }
                }
            } else {
                rows
            }
            Divider().padding(.vertical, 4)
            Text(L("↑↓ to choose · Return to confirm · Esc to close")).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
        }
        .padding(6)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
        .accessibilityElement(children: .contain).accessibilityLabel(menu.title)
    }

    /// The selected layers as removable tags; with many selected, the row scrolls sideways.
    private var contextTags: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(context, id: \.id) { layer in
                    HStack(spacing: 4) {
                        Image(systemName: NodeType(rawValue: layer.type)?.symbol ?? "square").font(.caption2)
                        Text(layer.name).font(.caption).lineLimit(1)
                        Button { dismissed.insert(layer.id) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).iconHitTarget() }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(L("Remove from context")).accessibilityLabel(L("Remove %@ from context", layer.name))
                    }
                    .padding(.leading, 7).padding(.trailing, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(L("Context"))
    }

    private var modelProviders: [ModelMenuProvider] {
        ChatSettings.providers.map {
            ModelMenuProvider(id: $0.id, title: $0.title, hasKey: chat.savedKey(for: $0.id), models: chat.models(for: $0.id), defaultModel: chat.defaultModel(for: $0.id))
        }
    }

    private var modelMenu: some View {
        let providers = modelProviders
        let current = chat.settings
        return Menu {
            ForEach(ModelMenu.sections(providers: providers, provider: current.provider, model: current.model), id: \.provider) { section in
                Section(section.title) {
                    ForEach(section.entries, id: \.model) { entry in modelButton(entry, section: section) }
                    if !section.all.isEmpty {
                        Menu(L("All %d Models", section.all.count)) {
                            ForEach(section.all, id: \.model) { entry in modelButton(entry, section: section) }
                        }
                    }
                    if section.needsKey {
                        Button(L("Add API Key…")) { settingsFor = SettingsTarget(provider: section.provider) }
                    }
                }
            }
            Divider()
            Button(L("Reload Model List")) { Task { await chat.reloadModels(root: root, runtime: runtime) } }.disabled(!chat.hasKey)
            Button(L("Model Settings…")) { settingsFor = SettingsTarget(provider: nil) }
        } label: {
            Text("\(current.providerTitle) · \(ModelMenu.currentModel(providers: providers, provider: current.provider, model: current.model) ?? L("Default model"))")
                .font(.caption).lineLimit(1)
        }
        .menuStyle(.borderlessButton).fixedSize()
        // Changing the provider or model restarts the harness, which would cut a running reply short.
        .help(L("Choose model")).accessibilityLabel(L("Choose model")).disabled(busy)
    }

    /// Choosing an entry sets the provider and model in one step, keeping that provider's stored base URL.
    private func modelButton(_ entry: ModelMenuEntry, section: ModelMenuSection) -> some View {
        let title: String
        if let id = entry.title { title = entry.isDefault ? "\(id) — \(L("Default"))" : id } else { title = L("Default model") }
        // A Toggle is drawn as a native checkable menu item; a Label's checkmark image is not shown in this menu.
        return Toggle(title, isOn: Binding(get: { entry.selected }, set: { _ in
            chat.settings = ChatSettings(provider: section.provider, model: entry.model, baseUrl: chat.stored(section.provider).baseUrl)
        }))
    }

    /// Return in the input: runs the slash command in it, or sends it as a message. A command is never sent to the model.
    private func submit() {
        switch ChatCommandInput(draft) {
        case .message:
            send()
        case .typing(let commands) where commands.isEmpty:
            commandError = L("Unknown command %@. Type / to see the commands.", draft)
        case .typing, .command(.model, _):
            // Return chooses only from a menu that is showing: after Esc it shows the menu again.
            if let menu = commandMenu { if !menu.items.isEmpty { menu.items[highlighted(in: menu)].run() } }
            else { menuClosedFor = nil }
        case .command(let command, let argument):
            run(command, argument: argument)
        case .unknown(let name):
            commandError = L("Unknown command %@. Type / to see the commands.", name)
        }
    }

    private func send() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // While a question waits, what is typed here answers it; editing the last message instead replaces the turn that asked.
        if waiting && !editing {
            answer(draft)
            draft = ""
            return
        }
        guard !busy else { return }
        // Sending always returns to the newest message.
        scroll.follow = ChatScrollFollow()
        following = true
        if editing { _ = chat.editLast() }
        chat.send(draft, context: context, root: root, runtime: runtime)
        draft = ""
    }

    private func answer(_ text: String?) {
        scroll.follow = ChatScrollFollow()
        following = true
        chat.answer(text, root: root, runtime: runtime)
    }

    /// `argument` is the text typed after the command: for `/plan` and `/goal` it is sent as the first message in that mode.
    private func run(_ command: ChatCommand, argument: String) {
        switch command {
        case .plan, .goal:
            chat.mode = command.mode
            draft = argument
            send()
        case .new:
            draft = ""
            chat.newConversation()
        case .clear:
            draft = ""
            editing = false
            chat.clearConversation()
        case .compact:
            guard !busy else { commandError = L("The context cannot be compacted while a reply is running"); return }
            draft = ""
            editing = false
            scroll.follow = ChatScrollFollow()
            following = true
            chat.compact(root: root, runtime: runtime)
        case .model:
            // The menu now lists the models; typing narrows them.
            draft = "\(command.name) "
        }
        inputFocused = true
    }

    /// The same change as choosing the model in the model menu, which is likewise unavailable during a reply.
    private func choose(_ choice: ModelChoice) {
        guard !busy else { commandError = L("The model cannot be changed while a reply is running"); return }
        chat.settings = ChatSettings(provider: choice.provider, model: choice.model, baseUrl: chat.stored(choice.provider).baseUrl)
        draft = ""
        inputFocused = true
    }

    private func runPlan() {
        editing = false
        scroll.follow = ChatScrollFollow()
        following = true
        chat.runPlan(context: context, root: root, runtime: runtime)
    }

    /// Copies the last user message into the input to be changed; the conversation is only rewound once the new text is sent.
    private func edit() {
        guard let last = chat.transcript.entries.last(where: { $0.kind == .user }) else { return }
        draft = last.text
        editing = true
        inputFocused = true
    }
}

/// The context ring: how much of the model's context window the conversation takes up. Hovering shows the numbers.
private struct ContextRing: View {
    let usage: ContextUsage

    private var color: Color {
        switch usage.level {
        case .normal: return .secondary
        case .high: return .orange
        case .critical: return .red
        }
    }

    private var summary: String {
        let used = ChatUsage.compact(usage.used)
        guard let window = usage.window, let percent = usage.percent else {
            return L("Context: %@ tokens used. The context window of this model is not known; reload the model list to look it up.", used)
        }
        let numbers = L("Context: %@ of %@ tokens (%d%%)", used, ChatUsage.compact(window), percent)
        switch usage.level {
        case .normal: return numbers
        case .high: return numbers + "\n" + L("The context is filling up. Send /compact to compact it.")
        case .critical: return numbers + "\n" + L("The context is almost full. Send /compact to compact it.")
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 2.5)
            Circle().trim(from: 0, to: usage.fraction ?? 0)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 14, height: 14).padding(3).contentShape(Rectangle())
        .help(summary)
        .accessibilityElement().accessibilityAddTraits(.isImage).accessibilityLabel(L("Context usage")).accessibilityValue(summary)
    }
}

private final class ScrollTracker {
    var follow = ChatScrollFollow()
}

/// The chat input's keys that the text field does not handle itself. Shift-Return inserts a line break instead of submitting
/// (the field only does that for Option-Return), and Tab in the empty field fills it with the suggested next message.
private struct ComposerKeys: ViewModifier {
    @Binding var text: String
    /// The predicted next message that Tab fills in, if any.
    let suggestion: String?
    /// Whether the field has keyboard focus; keys are only watched while it does.
    let active: Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { watch() }
            // The monitor holds the suggestion it was started with.
            .onChange(of: suggestion) { watch() }
            .onDisappear(perform: stop)
    }

    private func watch() {
        stop()
        guard active else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Left alone while an input method is composing, where Return confirms the candidate.
            guard let editor = event.window?.firstResponder as? NSTextView, editor.isFieldEditor, editor.string == text,
                  !editor.hasMarkedText() else { return event }
            if event.keyCode == 48, event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty, text.isEmpty, let suggestion {
                text = suggestion
                DispatchQueue.main.async { editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0)) }
                return nil
            }
            guard event.keyCode == 36, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift else { return event }
            // Change the bound text rather than the field editor, so SwiftUI does not put the old text back.
            let range = editor.selectedRange()
            text = (text as NSString).replacingCharacters(in: NSIntersectionRange(range, NSRange(location: 0, length: text.utf16.count)), with: "\n")
            DispatchQueue.main.async { editor.setSelectedRange(NSRange(location: range.location + 1, length: 0)) }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// While the command menu is open, the arrow keys move its highlight and Esc closes it, instead of acting on the text field.
private struct CommandMenuKeys: ViewModifier {
    /// The input's text, to tell its field editor from another field's.
    let text: String
    /// Whether the menu is open and the field has keyboard focus; keys are only watched while it is.
    let active: Bool
    let move: (Int) -> Void
    let close: () -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { watch() }
            // The monitor holds the text it was started with.
            .onChange(of: text) { watch() }
            .onDisappear(perform: stop)
    }

    private func watch() {
        stop()
        guard active else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Left alone while an input method is composing, where these keys work on the candidates.
            guard let editor = event.window?.firstResponder as? NSTextView, editor.isFieldEditor, editor.string == text, !editor.hasMarkedText(),
                  event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty else { return event }
            switch event.keyCode {
            case 125: move(1)
            case 126: move(-1)
            case 53: close()
            default: return event
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct ChatSettingsSheet: View {
    @ObservedObject var chat: ChatSession
    let root: URL?
    let runtime: WorkspaceLocation?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ModelSettingsDraft
    @State private var selected: String
    @State private var replacingKey: Set<String> = []
    @State private var error: String?
    @FocusState private var focusedKey: String?
    @Environment(\.locale) private var locale

    /// `provider` is selected when the sheet opens; nil selects the provider in use.
    init(chat: ChatSession, root: URL?, runtime: WorkspaceLocation?, provider: String? = nil) {
        self.chat = chat
        self.root = root
        self.runtime = runtime
        _draft = State(initialValue: chat.draft())
        _selected = State(initialValue: provider ?? chat.settings.provider)
    }

    var body: some View {
        let _ = locale // Re-render when the UI language changes.
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Model settings")).font(.title3.bold())
            HStack(alignment: .top, spacing: 16) {
                List(draft.order, id: \.self, selection: Binding(get: { selected }, set: { if let id = $0 { selected = id } })) { id in
                    providerRow(id)
                }
                .listStyle(.bordered).frame(width: 200, height: 260)
                if let provider = draft.providers[selected] { detail(selected, provider) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save"), action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 640)
        .onChange(of: focusedKey) { left, _ in
            // Leaving the key field after typing a new key tests it.
            guard let left, draft.providers[left]?.test == .untested, !trimmed(draft.providers[left]?.newKey ?? "").isEmpty else { return }
            runTest(left)
        }
    }

    private func title(_ id: String) -> String { ChatSettings.providers.first { $0.id == id }?.title ?? id }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func providerRow(_ id: String) -> some View {
        let hasKey = draft.hasKey(id)
        let model = trimmed(draft.providers[id]?.model ?? "")
        return HStack(spacing: 8) {
            Image(systemName: hasKey ? "circle.fill" : "circle").font(.caption2)
                .foregroundStyle(hasKey ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(id))
                Text(hasKey ? (model.isEmpty ? chat.defaultModel(for: id) ?? L("Default model") : model) : L("No API key"))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if id == draft.inUse { inUseTag }
        }
        .padding(.vertical, 2)
    }

    private var inUseTag: some View {
        Text(L("In use")).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
    }

    private func detail(_ id: String, _ provider: ProviderDraft) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title(id)).font(.headline)
                Spacer()
                if id == draft.inUse { inUseTag }
                else if draft.canUse(id) { Button(L("Use for Chat")) { draft.use(id) } }
                else if !draft.hasKey(id) { Text(L("Add an API key to use this provider")).font(.caption).foregroundStyle(.secondary) }
            }
            Form {
                LabeledContent(L("API key")) { keyRow(id, provider) }
                TextField(L("Base URL"), text: Binding(get: { provider.baseUrl }, set: { draft.setBaseUrl($0, for: id) }),
                          prompt: Text(L("Leave empty to use the official endpoint")))
                LabeledContent(L("Model")) {
                    HStack(spacing: 4) {
                        TextField(L("Model"), text: Binding(get: { provider.model }, set: { draft.setModel($0, for: id) }),
                                  prompt: Text(chat.defaultModel(for: id).map { L("Default: %@", $0) } ?? L("Leave empty to use the default model"))).labelsHidden()
                        modelMenu(id, model: provider.model)
                    }
                }
            }
            status(id, provider.test)
            Text(L("Each provider keeps its own key, base URL, and model. Keys are stored only in this Mac’s keychain and are passed to the chat process through an environment variable; the UI shows only the first and last 4 characters."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if id == "openai" {
                Text(L("ChatGPT needs an OpenAI API key; a ChatGPT subscription does not include one."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func keyRow(_ id: String, _ provider: ProviderDraft) -> some View {
        let showsSaved = provider.hasSavedKey && !provider.removesKey && !replacingKey.contains(id) && trimmed(provider.newKey).isEmpty
        HStack(spacing: 8) {
            if showsSaved {
                Text(chat.keyHint(for: id) ?? L("Saved")).font(.body.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel(L("Saved API key"))
                Spacer()
            } else {
                SecureField(L("API key"), text: Binding(get: { provider.newKey }, set: { draft.setKey($0, for: id) }),
                            prompt: Text(provider.hasSavedKey && !provider.removesKey ? L("Enter a new key, or leave empty to keep the current one") : L("Required")))
                    .labelsHidden().focused($focusedKey, equals: id).onSubmit { focusedKey = nil }
            }
            Button(provider.test == .testing ? L("Testing…") : L("Test")) { runTest(id) }.disabled(!draft.canTest(id))
            if showsSaved {
                Button(L("Replace")) {
                    replacingKey.insert(id)
                    DispatchQueue.main.async { focusedKey = id }
                }
                Button(L("Remove"), role: .destructive) { draft.removeKey(id) }
            }
        }
        .controlSize(.small)
    }

    private func modelMenu(_ id: String, model: String) -> some View {
        Menu {
            Toggle(chat.defaultModel(for: id).map { L("Default model (%@)", $0) } ?? L("Default model"),
                   isOn: Binding(get: { trimmed(model).isEmpty }, set: { _ in draft.setModel("", for: id) }))
            let models = chat.models(for: id)
            if !models.isEmpty {
                Divider()
                ForEach(models, id: \.self) { item in
                    Toggle(item, isOn: Binding(get: { trimmed(model) == item }, set: { _ in draft.setModel(item, for: id) }))
                }
            }
        } label: {
            Image(systemName: "chevron.up.chevron.down")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("Choose model")).accessibilityLabel(L("Choose model"))
    }

    @ViewBuilder private func status(_ id: String, _ test: KeyTest) -> some View {
        HStack(spacing: 6) {
            switch test {
            case .testing:
                ProgressView().controlSize(.small)
                Text(L("Testing…"))
            case .passed(let count):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L("The key works. %d models available.", count))
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                Text(L("The test failed: %@. You can still save.", message.hasSuffix(".") ? String(message.dropLast()) : message))
            case .untested:
                let cached = chat.models(for: id).count
                Text(!draft.hasKey(id) ? L("Add an API key, then test it.")
                     : cached > 0 ? L("%d models available.", cached) : L("Test the key to load the available models."))
            }
        }
        .font(.caption).foregroundStyle(test.isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)).fixedSize(horizontal: false, vertical: true)
    }

    /// Lists the provider's models with the draft key (or the saved key when none was typed) and the draft base URL; only the latest request counts.
    private func runTest(_ id: String) {
        guard let token = draft.beginTest(id), let provider = draft.providers[id] else { return }
        guard let root else { draft.finishTest(id, token: token, result: .failed(L("Cannot find the Fudehand source directory, so the model list is unavailable"))); return }
        let typed = trimmed(provider.newKey)
        let settings = ChatSettings(provider: id, model: "", baseUrl: trimmed(provider.baseUrl))
        Task {
            // The only Keychain read the sheet makes, and only when no new key was typed.
            let apiKey = typed.isEmpty ? chat.savedKeyValue(for: id) : typed
            let result = await ChatSession.listModels(root: root, runtime: runtime, settings: settings, apiKey: apiKey)
            let before = draft
            switch result {
            case .success(let list): draft.finishTest(id, token: token, result: .passed(models: list.models.count))
            case .failure(let failure): draft.finishTest(id, token: token, result: .failed(failure.message))
            }
            // A stale result leaves the draft unchanged and is not cached.
            if case .success(let list) = result, draft != before { chat.cacheModels(list.models, defaultModel: list.defaultModel, windows: list.windows, provider: id) }
        }
    }

    private func save() {
        do { try chat.apply(draft.changes()) } catch { self.error = error.localizedDescription; return }
        dismiss()
    }
}

private extension KeyTest {
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}
