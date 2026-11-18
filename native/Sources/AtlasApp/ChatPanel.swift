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
    @State private var showingSettings = false
    /// Selected layers whose context tag the user removed; forgotten once the layer is no longer selected.
    @State private var dismissed: Set<String> = []
    @State private var follow = ChatScrollFollow()
    @FocusState private var inputFocused: Bool
    @Environment(\.locale) private var locale

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
        .sheet(isPresented: $showingSettings) { ChatSettingsSheet(chat: chat, root: root, runtime: runtime) }
        .onChange(of: selection.map(\.id)) { _, ids in dismissed.formIntersection(ids) }
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
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help(L("Model settings")).accessibilityLabel(L("Model settings"))
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var missingKey: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "key").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("No API key set for %@", chat.settings.providerTitle)).font(.callout)
                Button(L("Set API Key…")) { showingSettings = true }.controlSize(.small)
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
        let lastAssistant = transcript.entries.last { $0.kind == .assistant }?.id
        let actions = ChatRowActions(regenerate: { chat.regenerate(root: root, runtime: runtime) }, edit: edit, layerName: layerName)
        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    // Not lazy: a lazy stack only estimates its height, and following the newest text needs the real one.
                    VStack(alignment: .leading, spacing: 12) {
                        if groups.isEmpty { emptyState }
                        ForEach(groups) { group in
                            ChatGroupRow(group: group, active: busy && group.id == groups.last?.id,
                                         actionable: !busy && group.id == (group.entries[0].kind == .user ? transcript.lastUserID : lastAssistant),
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
                            follow.update(offset: -frame.minY, contentHeight: frame.height, viewportHeight: viewport.size.height)
                        }
                    })
                }
                .coordinateSpace(name: "chat")
                .defaultScrollAnchor(.bottom)
                // Follow new text only while the user is at the bottom.
                .onChange(of: [transcript.entries.count, transcript.entries.last?.text.count ?? 0, busy ? 1 : 0]) {
                    if follow.following { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
                .overlay(alignment: .bottom) {
                    // Also offered when the view is merely left behind, for example after a tool card above was opened.
                    if !follow.following || (!busy && !follow.atBottom) {
                        Button { follow = ChatScrollFollow(); proxy.scrollTo(Self.bottom, anchor: .bottom) } label: {
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

    /// The selected layers as removable tags; the first few by name, the rest as a count.
    private var contextTags: some View {
        HStack(spacing: 6) {
            ForEach(context.prefix(2), id: \.id) { layer in
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
            if context.count > 2 {
                Text(L("+%d more", context.count - 2)).font(.caption).foregroundStyle(.secondary).fixedSize()
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel(L("Context"))
    }

    private var modelMenu: some View {
        Menu {
            Button { chat.settings.model = "" } label: { menuLabel(L("Default model"), selected: chat.settings.model.isEmpty) }
            if !chat.models.isEmpty {
                Divider()
                ForEach(chat.models, id: \.self) { id in
                    Button { chat.settings.model = id } label: { menuLabel(id, selected: chat.settings.model == id) }
                }
            }
            Divider()
            Button(L("Reload Model List")) { Task { await chat.reloadModels(root: root, runtime: runtime) } }.disabled(!chat.hasKey)
            Button(L("Model Settings…")) { showingSettings = true }
        } label: {
            Text(chat.settings.model.isEmpty ? L("Default model") : chat.settings.model).font(.caption).lineLimit(1)
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("\(L("Choose model")) · \(chat.settings.providerTitle)").accessibilityLabel(L("Choose model"))
    }

    @ViewBuilder private func menuLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func submit() {
        guard !busy, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Sending always returns to the newest message.
        follow = ChatScrollFollow()
        chat.send(draft, context: context, root: root, runtime: runtime)
        draft = ""
    }

    /// Puts the last user message back into the input to be changed and sent again.
    private func edit() {
        guard let last = chat.editLast() else { return }
        draft = last.text
        inputFocused = true
    }
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
                          let editor = event.window?.firstResponder as? NSTextView, !editor.hasMarkedText() else { return event }
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
    @State private var provider = ""
    @State private var model = ""
    @State private var baseUrl = ""
    @State private var key = ""
    @State private var hasSavedKey = false
    @State private var editingKey = false
    @State private var error: String?
    @State private var models: [String] = []
    @State private var defaultModel: String?
    @State private var listing = false
    @State private var listError: String?
    @State private var listToken = UUID()
    @FocusState private var keyFocused: Bool
    @Environment(\.locale) private var locale

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let _ = locale // Re-render when the UI language changes.
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Model settings")).font(.title3.bold())
            Form {
                Picker(L("Model provider"), selection: $provider) {
                    ForEach(ChatSettings.providers, id: \.id) { Text($0.title).tag($0.id) }
                }
                LabeledContent(L("Model")) {
                    HStack(spacing: 4) {
                        TextField(L("Model"), text: $model, prompt: Text(defaultModel.map { L("Default: %@", $0) } ?? L("Leave empty to use the default model"))).labelsHidden()
                        modelMenu
                    }
                }
                TextField(L("Base URL"), text: $baseUrl, prompt: Text(L("Leave empty to use the official endpoint"))).onSubmit(refreshModels)
                LabeledContent(L("API key")) { keyField }
            }
            listStatus
            Text(L("The API key is stored only in this Mac’s keychain and passed to the chat process through an environment variable when it starts; it is never written to the repository or logs, and the UI shows only the first and last 4 characters. DeepSeek uses an OpenAI-compatible API, and OpenAI uses the Responses API."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if hasSavedKey {
                    Button(L("Delete Saved Key"), role: .destructive) {
                        Keychain.delete(provider)
                        chat.keyUpdated(provider: provider, saved: false)
                        key = ""; hasSavedKey = false; editingKey = false
                        // Discard requests still in progress that were sent with the old key.
                        listToken = UUID(); listing = false; models = []; listError = nil
                    }
                }
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save"), action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 460)
        .onAppear { load(chat.settings); refreshModels() }
        .onChange(of: provider) { previous, next in
            // On first load previous is empty, so keep the value read in onAppear; after that every switch replaces it with the settings saved for that provider.
            hasSavedKey = chat.savedKey(for: next)
            guard !previous.isEmpty else { return }
            let stored = ChatSession.stored(next, .standard)
            model = stored.model; baseUrl = stored.baseUrl; key = ""; editingKey = false
            models = []; defaultModel = nil
            refreshModels()
        }
        .onChange(of: keyFocused) { _, focused in
            // Keep the plain-text field while typing; after leaving the field, switch to the masked display and fetch the models again with the new key.
            if focused { editingKey = true; return }
            guard editingKey, !trimmedKey.isEmpty || hasSavedKey else { return }
            editingKey = false
            if !trimmedKey.isEmpty { refreshModels() }
        }
    }

    private var modelMenu: some View {
        Menu {
            Button { model = "" } label: { menuLabel(defaultModel.map { L("Default model (%@)", $0) } ?? L("Default model"), selected: model.isEmpty) }
            if !models.isEmpty {
                Divider()
                ForEach(models, id: \.self) { id in
                    Button { model = id } label: { menuLabel(id, selected: model == id) }
                }
            }
            Divider()
            Button(L("Reload Model List"), action: refreshModels).disabled(listing)
        } label: {
            Image(systemName: "chevron.up.chevron.down")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("Choose model")).accessibilityLabel(L("Choose model"))
    }

    @ViewBuilder private func menuLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    @ViewBuilder private var keyField: some View {
        if editingKey || (trimmedKey.isEmpty && !hasSavedKey) {
            SecureField(L("API key"), text: $key, prompt: Text(hasSavedKey ? L("Enter a new key, or leave empty to keep the current one") : L("Required")))
                .labelsHidden().focused($keyFocused).onSubmit { keyFocused = false }
        } else {
            HStack(spacing: 8) {
                Text(trimmedKey.isEmpty ? chat.keyHint(for: provider) ?? L("Saved") : ChatSettings.maskedKey(trimmedKey))
                    .font(.body.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel(trimmedKey.isEmpty ? L("Saved API key") : L("Newly entered API key"))
                Spacer()
                Button(L("Replace")) {
                    key = ""; editingKey = true
                    DispatchQueue.main.async { keyFocused = true }
                }.controlSize(.small)
            }
        }
    }

    @ViewBuilder private var listStatus: some View {
        HStack(spacing: 6) {
            if listing {
                ProgressView().controlSize(.small)
                Text(L("Loading available models…"))
            } else if let listError {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(L("Could not load the model list: %@. You can still enter a model manually.", listError))
            } else if !models.isEmpty {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text(L("Available models: %d. Choose one from the menu next to the model field.", models.count))
            } else if trimmedKey.isEmpty && !hasSavedKey {
                Text(L("Available models load automatically once you enter an API key."))
            }
        }
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func load(_ settings: ChatSettings) {
        provider = settings.provider; model = settings.model; baseUrl = settings.baseUrl
        hasSavedKey = chat.savedKey(for: settings.provider)
    }

    /// Reads the current provider's model list with the new key in the field (or the key in the Keychain when there is none); only the result of the last request is used.
    private func refreshModels() {
        let token = UUID()
        listToken = token
        listError = nil
        guard let root else { listing = false; listError = L("Cannot find the ui-atlas source directory, so the model list is unavailable"); return }
        let typed = trimmedKey
        guard !typed.isEmpty || hasSavedKey else { listing = false; models = []; return }
        let settings = ChatSettings(provider: provider, model: "", baseUrl: baseUrl.trimmingCharacters(in: .whitespaces))
        listing = true
        Task {
            let apiKey = typed.isEmpty ? chat.savedKeyValue(for: settings.provider) : typed
            // The read clears the saved flag when the Keychain no longer has the key.
            if provider == settings.provider { hasSavedKey = chat.savedKey(for: provider) }
            let result = await ChatSession.listModels(root: root, runtime: runtime, settings: settings, apiKey: apiKey)
            guard listToken == token else { return }
            listing = false
            switch result {
            case .success(let list):
                models = list.models; defaultModel = list.defaultModel.isEmpty ? nil : list.defaultModel
                chat.cacheModels(list.models, provider: settings.provider)
            case .failure(let failure): models = []; listError = failure.message
            }
        }
    }

    private func save() {
        do {
            if !trimmedKey.isEmpty { try Keychain.save(trimmedKey, account: provider) }
        } catch { self.error = error.localizedDescription; return }
        // ChatSession restarts itself when the settings change; notify only when a new key was actually saved.
        chat.settings = ChatSettings(provider: provider, model: model.trimmingCharacters(in: .whitespaces),
                                     baseUrl: baseUrl.trimmingCharacters(in: .whitespaces))
        if !trimmedKey.isEmpty { chat.keyUpdated(provider: provider, saved: true, key: trimmedKey) }
        dismiss()
    }
}
