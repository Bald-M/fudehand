import AppKit
import AtlasCore
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

    private static let bottom = "bottom"

    private var busy: Bool { chat.transcript.busy }
    private var context: [ChatContext] { selection.filter { !dismissed.contains($0.id) } }

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
        // The message being edited is gone: another conversation was opened, or something was sent.
        .onChange(of: chat.transcript.lastUserID) { editing = false }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(chat.transcript.title.isEmpty ? L("New conversation") : chat.transcript.title).font(.headline).lineLimit(1)
            Spacer()
            Button { chat.newConversation(); inputFocused = true } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless).help(L("New conversation")).accessibilityLabel(L("New conversation"))
                .disabled(chat.transcript.entries.isEmpty || busy)
            Menu {
                ForEach(chat.conversations) { conversation in
                    Button { chat.open(conversation.id) } label: {
                        if conversation.id == chat.conversationID { Label(conversation.title, systemImage: "checkmark") } else { Text(conversation.title) }
                    }
                }
                if chat.conversations.isEmpty { Text(L("No saved conversations")) }
                Divider()
                Button(L("Delete This Conversation"), role: .destructive) { chat.deleteConversation() }
                    .disabled(chat.transcript.entries.isEmpty)
            } label: {
                Label(L("Conversation history"), systemImage: "clock.arrow.circlepath").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("Conversation history")).disabled(busy)
            Button { settingsFor = SettingsTarget(provider: nil) } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help(L("Model settings")).accessibilityLabel(L("Model settings"))
        }.padding(.horizontal, 16).padding(.vertical, 12)
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
        let actions = ChatRowActions(regenerate: { chat.regenerate(root: root, runtime: runtime) }, edit: edit, layerName: layerName)
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
                        if busy {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("Replying…")).font(.caption).foregroundStyle(.secondary) }
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
            if editing {
                HStack(spacing: 4) {
                    Image(systemName: "pencil")
                    Text(L("Editing the last message"))
                    Spacer()
                    Button { editing = false } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.plain).help(L("Cancel editing")).accessibilityLabel(L("Cancel editing"))
                }.font(.caption).foregroundStyle(.secondary)
            }
            // Return sends and Shift-Return starts a new line; a draft can be typed while a reply is still running.
            TextField(L("Message"), text: $draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...8).focused($inputFocused)
                .onSubmit(submit)
                .modifier(ShiftReturnLineBreak(text: $draft, active: inputFocused))
                .accessibilityLabel(L("Chat input"))
            HStack(spacing: 8) {
                modelMenu
                Spacer()
                if busy {
                    Button { chat.stopReply() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                        .buttonStyle(.borderless).help(L("Stop replying")).accessibilityLabel(L("Stop replying"))
                } else {
                    Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.borderless).help(L("Send (Return)")).accessibilityLabel(L("Send"))
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(inputFocused ? AnyShapeStyle(Color.accentColor.opacity(0.7)) : AnyShapeStyle(.quaternary)))
        .padding(12)
    }

    /// The selected layers as removable tags; with many selected, the row scrolls sideways.
    private var contextTags: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(context, id: \.id) { layer in
                    HStack(spacing: 4) {
                        Image(systemName: NodeType(rawValue: layer.type)?.symbol ?? "square").font(.caption2)
                        Text(layer.name).font(.caption).lineLimit(1)
                        Button { dismissed.insert(layer.id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help(L("Remove from context")).accessibilityLabel(L("Remove %@ from context", layer.name))
                    }
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.quaternary.opacity(0.6), in: Capsule())
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(L("Context"))
    }

    private var modelMenu: some View {
        let providers = ChatSettings.providers.map {
            ModelMenuProvider(id: $0.id, title: $0.title, hasKey: chat.savedKey(for: $0.id), models: chat.models(for: $0.id), defaultModel: chat.defaultModel(for: $0.id))
        }
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

    private func submit() {
        guard !busy, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Sending always returns to the newest message.
        scroll.follow = ChatScrollFollow()
        following = true
        if editing { _ = chat.editLast() }
        chat.send(draft, context: context, root: root, runtime: runtime)
        draft = ""
    }

    /// Copies the last user message into the input to be changed; the conversation is only rewound once the new text is sent.
    private func edit() {
        guard let last = chat.transcript.entries.last(where: { $0.kind == .user }) else { return }
        draft = last.text
        editing = true
        inputFocused = true
    }
}

private final class ScrollTracker {
    var follow = ChatScrollFollow()
}

/// Makes Shift-Return insert a line break in the focused text field instead of submitting it; the field itself only does that for Option-Return.
private struct ShiftReturnLineBreak: ViewModifier {
    @Binding var text: String
    /// Whether the field has keyboard focus; keys are only watched while it does.
    let active: Bool
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { _, active in
                stop()
                guard active else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    // Left alone while an input method is composing, where Return confirms the candidate.
                    guard event.keyCode == 36, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift,
                          let editor = event.window?.firstResponder as? NSTextView, editor.isFieldEditor, editor.string == text,
                          !editor.hasMarkedText() else { return event }
                    // Change the bound text rather than the field editor, so SwiftUI does not put the old text back.
                    let range = editor.selectedRange()
                    text = (text as NSString).replacingCharacters(in: NSIntersectionRange(range, NSRange(location: 0, length: text.utf16.count)), with: "\n")
                    DispatchQueue.main.async { editor.setSelectedRange(NSRange(location: range.location + 1, length: 0)) }
                    return nil
                }
            }
            .onDisappear(perform: stop)
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
        guard let root else { draft.finishTest(id, token: token, result: .failed(L("Cannot find the ui-atlas source directory, so the model list is unavailable"))); return }
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
            if case .success(let list) = result, draft != before { chat.cacheModels(list.models, defaultModel: list.defaultModel, provider: id) }
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
