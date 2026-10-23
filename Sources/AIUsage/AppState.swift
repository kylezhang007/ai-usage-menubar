import Foundation
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    @Published var claude: Loadable<PlanUsage> = .idle
    @Published var codex: Loadable<PlanUsage> = .idle
    @Published var anthropic: Loadable<Money> = .idle
    @Published var openAI: Loadable<Money> = .idle
    @Published var deepSeek: Loadable<Money> = .idle
    @Published var lastUpdated: Date?
    @Published var isRefreshing = false
    @Published var showingSettings = false

    @Published var refreshMinutes: Int {
        didSet { UserDefaults.standard.set(refreshMinutes, forKey: "refreshMinutes"); scheduleTimer() }
    }
    @Published var clearGlass: Bool {
        didSet { UserDefaults.standard.set(clearGlass, forKey: "clearGlass") }
    }

    @Published var language: Language {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "language") }
    }

    private var timer: Timer?
    // Claude's usage endpoint rate-limits hard, so it's polled at most every few minutes
    // and backs off when told to; the last good numbers stay on screen meanwhile.
    private var claudeLastFetch: Date?
    private var claudeBackoffUntil: Date?
    private static let claudeMinInterval: TimeInterval = 4 * 60

    init() {
        let saved = UserDefaults.standard.integer(forKey: "refreshMinutes")
        refreshMinutes = saved > 0 ? saved : 3
        language = Language.current
        clearGlass = UserDefaults.standard.object(forKey: "clearGlass") as? Bool ?? true
        Keychain.migrateLegacyItems()
        scheduleTimer()
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let sessionKey = Keychain.get(.claudeSessionKey)
        let anthropicKey = Keychain.get(.anthropicAdmin)
        let openAIKey = Keychain.get(.openAIAdmin)
        let deepSeekKey = Keychain.get(.deepSeek)

        let now = Date()
        let claudeDue = (claudeBackoffUntil.map { now >= $0 } ?? true)
            && (claudeLastFetch.map { now.timeIntervalSince($0) >= Self.claudeMinInterval } ?? true)
        if claudeDue { claudeLastFetch = now }
        async let c: ClaudeProvider.Result? = claudeDue ? ClaudeProvider.fetch(sessionKey: sessionKey) : nil
        async let x = CodexProvider.fetch()
        async let a = SpendProvider.anthropic(key: anthropicKey)
        async let o = SpendProvider.openAI(key: openAIKey)
        async let d = SpendProvider.deepSeekBalance(key: deepSeekKey)

        if let result = await c {
            claudeBackoffUntil = result.retryAfter.map { now.addingTimeInterval($0) }
            // When rate limited, keep showing the last numbers we had rather than an error.
            if result.retryAfter == nil || claude.value == nil {
                claude = result.usage
            }
        }
        codex = await x
        anthropic = await a
        openAI = await o
        deepSeek = await d
        lastUpdated = Date()
    }

    private func scheduleTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(refreshMinutes * 60), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    /// What's left of each 5-hour window, for the menu bar.
    var claudeShortRemaining: Double? { Self.shortRemaining(claude) }
    var codexShortRemaining: Double? { Self.shortRemaining(codex) }

    private static func shortRemaining(_ data: Loadable<PlanUsage>) -> Double? {
        guard let w = data.value?.windows.first(where: \.isShort) else { return nil }
        return w.remaining
    }

    var highestPercent: Double {
        let all = (claude.value?.windows ?? []) + (codex.value?.windows ?? [])
        return all.map(\.percent).max() ?? 0
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }
}
