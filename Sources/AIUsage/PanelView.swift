import SwiftUI

struct PanelView: View {
    @EnvironmentObject var state: AppState

    /// Transparent margin around the glass. Glass casts a soft glow past its edges; if the
    /// window is tight, that glow is cut off in a straight line and reads as a backing plate.
    static let margin: CGFloat = 32

    // Like Control Center: no panel behind the content, every block is its own piece of glass.
    var body: some View {
        VStack(spacing: 10) {
            if state.showingSettings {
                SettingsView().frame(width: 320).fixedSize(horizontal: false, vertical: true)
            } else {
                header
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 10) {
                        PlanTile(title: "Claude", theme: .claude, data: state.claude)
                        PlanTile(title: "Codex", theme: .codex, data: state.codex)
                    }
                    .frame(width: 350)
                    APITile()
                        .frame(width: 140)
                        .frame(maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                footer
            }
        }
        .padding(Self.margin)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 5) {
                Image(systemName: isNight ? "moon.stars.fill" : "sun.max.fill")
                    .foregroundStyle(isNight ? Color(hex: 0x8E9BFF) : Color(hex: 0xF5A524))
                Text(greeting)
            }
            .font(.system(size: 13, weight: .medium))
            Spacer()
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(updatedText).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(Capsule(), tint: nil, clear: state.clearGlass)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button { state.showingSettings = true } label: { chip(Text(L("设置", "Settings"))) }
            Spacer()
            Button {
                Task { await state.refresh() }
            } label: {
                chip(Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(state.isRefreshing ? 360 : 0))
                    .animation(state.isRefreshing ? .linear(duration: 0.8).repeatForever(autoreverses: false) : .default,
                               value: state.isRefreshing))
            }
            .help(L("立即刷新", "Refresh now"))
            Button { NSApp.terminate(nil) } label: { chip(Text(L("退出", "Quit"))) }
        }
        .buttonStyle(.plain)
    }

    /// Small glass capsule, like Control Center's "编辑控制".
    private func chip(_ content: some View) -> some View {
        content
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Capsule())
            .glassSurface(Capsule(), tint: nil, clear: state.clearGlass)
    }

    private var isNight: Bool {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 5 || h >= 19
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let hello = h < 5 ? L("夜深了", "Up late") : h < 11 ? L("早上好", "Good morning")
            : h < 13 ? L("中午好", "Good noon") : h < 19 ? L("下午好", "Good afternoon") : L("晚上好", "Good evening")
        let p = state.highestPercent
        let mood = p >= 90 ? L("额度快用完了", "almost out of quota")
            : p >= 70 ? L("额度用得差不多了", "quota is running low") : L("额度还很充足", "plenty of quota left")
        return L("\(hello)，\(mood)", "\(hello), \(mood)")
    }

    private var updatedText: String {
        guard let d = state.lastUpdated else { return L("正在读取…", "Loading…") }
        if Date().timeIntervalSince(d) < 60 { return L("刚刚更新", "Just updated") }
        let f = RelativeDateTimeFormatter()
        f.locale = Language.locale
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}

// MARK: - Tiles

struct Tile<Content: View>: View {
    @EnvironmentObject var state: AppState
    var theme: SectionTheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .glassSurface(RoundedRectangle(cornerRadius: 28, style: .continuous),
                          tint: theme.glassTint, clear: state.clearGlass)
    }
}

struct TileHeader: View {
    var title: String
    var plan: String?
    var theme: SectionTheme

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(theme.shade(0).gradient, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            Spacer()
            if let plan {
                Text(plan)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.plan)
            }
        }
    }
}

struct PlanTile: View {
    var title: String
    var theme: SectionTheme
    var data: Loadable<PlanUsage>

    var body: some View {
        Tile(theme: theme) {
            TileHeader(title: title, plan: data.value?.plan, theme: theme)
            switch data {
            case .loaded(let usage) where !usage.windows.isEmpty:
                HStack(spacing: 18) {
                    Rings(values: usage.windows.map(\.remaining), theme: theme)
                    VStack(spacing: 9) {
                        ForEach(Array(usage.windows.enumerated()), id: \.element.id) { i, w in
                            UsageRow(window: w, shade: theme.shade(i))
                        }
                    }
                }
            case .idle:
                StatusLine(text: L("正在读取…", "Loading…"))
            case .missing(let m), .failed(let m):
                StatusLine(text: m)
            case .loaded:
                StatusLine(text: L("暂时没有额度数据", "No limit data yet"))
            }
        }
    }
}

struct StatusLine: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    }
}

struct UsageRow: View {
    var window: UsageWindow
    var shade: Shade

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(shade.gradient).frame(width: 6, height: 6)
                Text(L(window.label + "剩余", window.label + " left"))
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(Int(window.remaining.rounded()))%")
                .font(.system(size: 19, weight: .semibold).monospacedDigit())
                .tracking(-0.5)
                .foregroundStyle(shade.gradient)
                .frame(width: 54, alignment: .trailing)

            TimelineView(.everyMinute) { context in
                Text(resetText(now: context.date))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(width: 58, alignment: .trailing)
        }
    }

    /// Reset moments in California time, 24-hour clock: the 5-hour window and any reset
    /// happening today show the time ("16:18"), later ones show the date ("10/27").
    /// Time left until the window resets, always five characters ("0h28m", "4h05m", "5d03h")
    /// so the monospaced column lines up row to row.
    private func resetText(now: Date) -> String {
        guard let r = window.resetsAt else { return "  —  " }
        // Rounded so Claude's hh:mm:59.9 resets don't read a minute short.
        let mins = max(0, Int((r.timeIntervalSince(now) / 60).rounded()))
        let d = mins / 1440, h = mins % 1440 / 60, m = mins % 60
        if d > 0 { return String(format: "%dd%02dh", d, h) }
        return String(format: "%dh%02dm", h, m)
    }
}

/// Concentric activity-style rings, outermost first.
struct Rings: View {
    var values: [Double]
    var theme: SectionTheme
    private let diameters: [CGFloat] = [71, 52, 33]

    var body: some View {
        ZStack {
            ForEach(Array(values.prefix(3).enumerated()), id: \.offset) { i, v in
                let shade = theme.shade(i)
                Circle()
                    .stroke(shade.track, lineWidth: 8)
                    .frame(width: diameters[i], height: diameters[i])
                Circle()
                    .trim(from: 0, to: max(0.001, min(v, 100) / 100))
                    .stroke(shade.gradient, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: diameters[i], height: diameters[i])
                    .animation(.easeOut(duration: 0.6), value: v)
            }
        }
        .frame(width: 88, height: 88)
    }
}

struct APITile: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Tile(theme: .api) {
            TileHeader(title: "API", plan: monthLabel, theme: .api)
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 4)
                cell(state.anthropic, "Anthropic", 0)
                Spacer(minLength: 12)
                cell(state.openAI, "OpenAI", 1)
                Spacer(minLength: 12)
                cell(state.deepSeek, L("DeepSeek 余额", "DeepSeek balance"), 2)
                Spacer(minLength: 4)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var monthLabel: String {
        let f = DateFormatter()
        f.locale = Language.locale
        f.dateFormat = Language.isChinese ? "M 月" : "MMM"
        return f.string(from: Date())
    }

    private func cell(_ data: Loadable<Money>, _ caption: String, _ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(data.value?.formatted ?? "—")
                .font(.system(size: 19, weight: .semibold).monospacedDigit())
                .tracking(-0.5)
                .foregroundStyle(SectionTheme.api.shade(i).gradient)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(caption).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            if case .failed(let m) = data {
                Text(m).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            } else if case .missing = data {
                Text(L("在设置里填写", "Add in Settings")).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Glass

extension View {
    /// Native Liquid Glass on macOS 26; frosted material with a light rim on older systems.
    @ViewBuilder
    func glassSurface<S: Shape>(_ shape: S, tint: Color?, clear: Bool) -> some View {
        if #available(macOS 26.0, *) {
            let base: Glass = clear ? .clear : .regular
            self.glassEffect(tint.map { base.tint($0) } ?? base, in: shape)
        } else {
            self
                .background(tint ?? .clear, in: shape)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.4), lineWidth: 1))
        }
    }
}
