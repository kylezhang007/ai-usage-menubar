import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var anthropic = Keychain.get(.anthropicAdmin) ?? ""
    @State private var openAI = Keychain.get(.openAIAdmin) ?? ""
    @State private var deepSeek = Keychain.get(.deepSeek) ?? ""
    @State private var sessionKey = Keychain.get(.claudeSessionKey) ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("设置").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button("完成") { save() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SectionTheme.api.shade(0).gradient)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassSurface(Capsule(), tint: nil, clear: state.clearGlass)

            Tile(theme: .claude) {
                TileHeader(title: "Claude", plan: nil, theme: .claude)
                KeyField(title: "claude.ai sessionKey（可选）", placeholder: "sk-ant-sid01-…", text: $sessionKey)
                Hint("登录过 Claude Code 命令行的 Mac 会自动读取，不用填。没有的话，在浏览器打开 claude.ai，从 Cookie 里复制 sessionKey。")
            }

            Tile(theme: .api) {
                TileHeader(title: "API", plan: nil, theme: .api)
                KeyField(title: "Anthropic Admin Key", placeholder: "sk-ant-admin01-…", text: $anthropic)
                KeyField(title: "OpenAI Admin Key", placeholder: "sk-admin-…", text: $openAI)
                KeyField(title: "DeepSeek API Key", placeholder: "sk-…", text: $deepSeek)
                Hint("Key 只保存在这台 Mac 的钥匙串里。查花费需要 Admin Key，普通 Key 查不了。")
            }

            Tile(theme: .codex) {
                TileHeader(title: "通用", plan: nil, theme: .codex)
                Row("刷新间隔") {
                    Picker("", selection: $state.refreshMinutes) {
                        ForEach([1, 3, 5, 10, 30], id: \.self) { Text("\($0) 分钟").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                Row("玻璃效果") {
                    Picker("", selection: $state.clearGlass) {
                        Text("标准").tag(false)
                        Text("通透").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)
                }
                Row("开机自动启动") {
                    Toggle("", isOn: Binding(get: { state.launchAtLogin }, set: { state.launchAtLogin = $0 }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
            }
        }
    }

    private func save() {
        Keychain.set(.anthropicAdmin, anthropic)
        Keychain.set(.openAIAdmin, openAI)
        Keychain.set(.deepSeek, deepSeek)
        Keychain.set(.claudeSessionKey, sessionKey)
        state.showingSettings = false
        Task { await state.refresh() }
    }
}

private struct KeyField: View {
    var title: String
    var placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.6), lineWidth: 0.5))
        }
    }
}

private struct Row<Control: View>: View {
    var title: String
    @ViewBuilder var control: Control
    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }
    var body: some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            control
        }
    }
}

private struct Hint: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
