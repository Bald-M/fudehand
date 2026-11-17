import AtlasCore
import SwiftUI

/// 对话面板：与 App 内 Agent 对话，Agent 通过与 MCP 相同的工具读取和编辑设计文档。
struct ChatPanel: View {
    @ObservedObject var chat: ChatSession
    let root: URL?
    let runtime: WorkspaceLocation?
    let send: (String) -> Void
    @State private var draft = ""
    @State private var showingSettings = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !chat.hasKey { missingKey }
            messages
            Divider()
            composer
        }
        .frame(minWidth: 300)
        .sheet(isPresented: $showingSettings) { ChatSettingsSheet(chat: chat, root: root, runtime: runtime) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("对话").font(.headline)
                Text(modelLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { chat.clear() } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("清空会话").accessibilityLabel("清空会话")
                .disabled(chat.transcript.entries.isEmpty || chat.transcript.busy)
            Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("模型设置").accessibilityLabel("模型设置")
        }.padding(.horizontal, 16).padding(.vertical, 12)
    }

    private var modelLabel: String {
        let model = chat.settings.model.isEmpty ? "默认模型" : chat.settings.model
        return "\(chat.settings.providerTitle) · \(model)"
    }

    private var missingKey: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "key").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("尚未配置 \(chat.settings.providerTitle) 的 API key").font(.callout)
                Button("设置 API key…") { showingSettings = true }.controlSize(.small)
            }
            Spacer()
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.transcript.entries.isEmpty { emptyState }
                    ForEach(chat.transcript.entries) { entry in ChatEntryRow(entry: entry).id(entry.id) }
                    if chat.transcript.busy {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("正在回复…").font(.caption).foregroundStyle(.secondary) }
                            .id("progress")
                    }
                }.padding(16)
            }
            .onChange(of: chat.transcript.entries.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    if chat.transcript.busy { proxy.scrollTo("progress", anchor: .bottom) }
                    else if let last = chat.transcript.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("让 AI 帮你搭建和修改界面。").font(.callout).foregroundStyle(.secondary)
            ForEach(["新建一个 390×844 的移动端首页，含导航栏、卡片列表和按钮", "把所有按钮改成圆角 12", "截图核对当前画框"], id: \.self) { example in
                Button { draft = example; inputFocused = true } label: {
                    Text(example).font(.caption).padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }.buttonStyle(.plain)
            }
        }.padding(.vertical, 8)
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("输入消息", text: $draft, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...5).focused($inputFocused)
                .onSubmit(submit)
                .accessibilityLabel("对话输入")
            if chat.transcript.busy {
                Button { chat.stopReply() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.borderless).help("停止回复").accessibilityLabel("停止回复")
            } else {
                Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless).help("发送（Return）").accessibilityLabel("发送")
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(12)
    }

    private func submit() {
        guard !chat.transcript.busy, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        send(draft)
        draft = ""
    }
}

private struct ChatEntryRow: View {
    let entry: ChatEntry
    @State private var expanded = false

    var body: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(entry.text).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
        case .assistant:
            Text(entry.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .toolCall, .toolResult:
            tool
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.red).textSelection(.enabled)
        case .notice:
            Text(entry.text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private var tool: some View {
        let (symbol, color, title): (String, Color, String) = switch entry.kind {
        case .toolResult(ok: true): ("checkmark.circle", .green, "结果 · \(entry.text)")
        case .toolResult(ok: false): ("xmark.circle", .red, "失败 · \(entry.text)")
        default: ("wrench.and.screwdriver", .secondary, "调用 · \(entry.text)")
        }
        return VStack(alignment: .leading, spacing: 4) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: symbol).foregroundStyle(color)
                    Text(title).font(.caption.monospaced())
                    if entry.detail?.isEmpty == false { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2) }
                }.foregroundStyle(.secondary)
            }.buttonStyle(.plain).accessibilityLabel(title)
            if expanded, let detail = entry.detail, !detail.isEmpty {
                Text(detail).font(.caption.monospaced()).textSelection(.enabled).lineLimit(30)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
        }
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

    private var trimmedKey: String { key.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("模型设置").font(.title3.bold())
            Form {
                Picker("模型提供方", selection: $provider) {
                    ForEach(ChatSettings.providers, id: \.id) { Text($0.title).tag($0.id) }
                }
                LabeledContent("模型") {
                    HStack(spacing: 4) {
                        TextField("模型", text: $model, prompt: Text(defaultModel.map { "默认：\($0)" } ?? "留空使用默认模型")).labelsHidden()
                        modelMenu
                    }
                }
                TextField("接口地址", text: $baseUrl, prompt: Text("留空使用官方地址")).onSubmit(refreshModels)
                LabeledContent("API key") { keyField }
            }
            listStatus
            Text("API key 只保存在本机钥匙串，启动对话程序时经环境变量传入，不写入仓库或日志；界面只显示首尾各 4 位。DeepSeek 使用 OpenAI 兼容接口，OpenAI 使用 Responses API。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if hasSavedKey {
                    Button("删除已保存的 key", role: .destructive) {
                        Keychain.delete(provider)
                        chat.keyUpdated(provider: provider, saved: false)
                        key = ""; hasSavedKey = false; editingKey = false
                        // 丢弃仍在进行、用旧 key 发出的请求。
                        listToken = UUID(); listing = false; models = []; listError = nil
                    }
                }
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 460)
        .onAppear { load(chat.settings); refreshModels() }
        .onChange(of: provider) { previous, next in
            // 首次载入时 previous 为空，保留 onAppear 读到的值；之后每次切换都换成该提供方保存的设置。
            hasSavedKey = chat.savedKey(for: next)
            guard !previous.isEmpty else { return }
            let stored = ChatSession.stored(next, .standard)
            model = stored.model; baseUrl = stored.baseUrl; key = ""; editingKey = false
            models = []; defaultModel = nil
            refreshModels()
        }
        .onChange(of: keyFocused) { _, focused in
            // 输入期间保持明文框；离开输入框后改为遮蔽显示，并用新 key 重新获取模型。
            if focused { editingKey = true; return }
            guard editingKey, !trimmedKey.isEmpty || hasSavedKey else { return }
            editingKey = false
            if !trimmedKey.isEmpty { refreshModels() }
        }
    }

    private var modelMenu: some View {
        Menu {
            Button { model = "" } label: { menuLabel(defaultModel.map { "默认模型（\($0)）" } ?? "默认模型", selected: model.isEmpty) }
            if !models.isEmpty {
                Divider()
                ForEach(models, id: \.self) { id in
                    Button { model = id } label: { menuLabel(id, selected: model == id) }
                }
            }
            Divider()
            Button("重新获取模型列表", action: refreshModels).disabled(listing)
        } label: {
            Image(systemName: "chevron.up.chevron.down")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("选择模型").accessibilityLabel("选择模型")
    }

    @ViewBuilder private func menuLabel(_ title: String, selected: Bool) -> some View {
        if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    @ViewBuilder private var keyField: some View {
        if editingKey || (trimmedKey.isEmpty && !hasSavedKey) {
            SecureField("API key", text: $key, prompt: Text(hasSavedKey ? "输入新的 key，留空不修改" : "必填"))
                .labelsHidden().focused($keyFocused).onSubmit { keyFocused = false }
        } else {
            HStack(spacing: 8) {
                Text(trimmedKey.isEmpty ? chat.keyHint(for: provider) ?? "已保存" : ChatSettings.maskedKey(trimmedKey))
                    .font(.body.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel(trimmedKey.isEmpty ? "已保存的 API key" : "新输入的 API key")
                Spacer()
                Button("更换") {
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
                Text("正在获取可用模型…")
            } else if let listError {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("获取模型列表失败：\(listError)。仍可手动填写模型。")
            } else if !models.isEmpty {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text("已获取 \(models.count) 个可用模型，可在模型右侧的菜单中选择。")
            } else if trimmedKey.isEmpty && !hasSavedKey {
                Text("填写 API key 后会自动获取可用模型。")
            }
        }
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func load(_ settings: ChatSettings) {
        provider = settings.provider; model = settings.model; baseUrl = settings.baseUrl
        hasSavedKey = chat.savedKey(for: settings.provider)
    }

    /// 用输入框里的新 key（没有时用钥匙串里的 key）读取当前提供方的模型列表；只采用最后一次请求的结果。
    private func refreshModels() {
        let token = UUID()
        listToken = token
        listError = nil
        guard let root else { listing = false; listError = "找不到 ui-atlas 源码目录，无法读取模型列表"; return }
        let typed = trimmedKey
        guard !typed.isEmpty || hasSavedKey else { listing = false; models = []; return }
        let settings = ChatSettings(provider: provider, model: "", baseUrl: baseUrl.trimmingCharacters(in: .whitespaces))
        listing = true
        Task {
            let apiKey = typed.isEmpty ? chat.savedKeyValue(for: settings.provider) : typed
            let result = await ChatSession.listModels(root: root, runtime: runtime, settings: settings, apiKey: apiKey)
            guard listToken == token else { return }
            listing = false
            switch result {
            case .success(let list): models = list.models; defaultModel = list.defaultModel.isEmpty ? nil : list.defaultModel
            case .failure(let failure): models = []; listError = failure.message
            }
        }
    }

    private func save() {
        do {
            if !trimmedKey.isEmpty { try Keychain.save(trimmedKey, account: provider) }
        } catch { self.error = error.localizedDescription; return }
        // 设置变化时 ChatSession 自己会重启；只有确实保存了新 key 才通知。
        chat.settings = ChatSettings(provider: provider, model: model.trimmingCharacters(in: .whitespaces),
                                     baseUrl: baseUrl.trimmingCharacters(in: .whitespaces))
        if !trimmedKey.isEmpty { chat.keyUpdated(provider: provider, saved: true, key: trimmedKey) }
        dismiss()
    }
}
