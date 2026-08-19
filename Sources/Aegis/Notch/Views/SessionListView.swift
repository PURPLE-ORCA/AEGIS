import SwiftUI

struct SessionListView: View {
    @ObservedObject var sessionStore: SessionStore
    @ObservedObject var rateLimitStore: RateLimitStore
    @ObservedObject var settingsStore: SettingsStore
    let onCollapse: () -> Void
    let onOpenSettings: () -> Void
    let onContentHeightChange: (CGFloat) -> Void

    @Environment(\.notchTheme) private var theme

    /// nil = "ALL"; otherwise filter to a single provider.
    @State private var selectedProvider: AIProvider? = nil
    @State private var selectedRateLimitProvider: AIProvider? = nil
    /// Provider ids that the user has collapsed — their cards are hidden
    /// behind the section header until expanded again.
    @State private var collapsedProviders: Set<String> = []
    @State private var measuredChromeHeight: CGFloat = 44
    @State private var measuredListHeight: CGFloat = 60

    /// Tapping the rate limit bar cycles selectedProvider through every
    /// provider that actually has data to show, skipping ones that would
    /// just render as "—" (no auth / no data). If no provider has data we
    /// fall through to the default cycle so the user can still flip away
    /// from a stale state.
    private func cycleRateLimitProvider(current: AIProvider) {
        let providers = AIProvider.all
        let withData = providers.filter { p in
            let snap = rateLimitStore.snapshot(for: p)
            return snap.fiveHour != nil || snap.sevenDay != nil
        }
        let cycleList = withData.isEmpty ? providers : withData
        guard let idx = cycleList.firstIndex(of: current) else {
            selectedRateLimitProvider = cycleList.first
            return
        }
        selectedRateLimitProvider = cycleList[(idx + 1) % cycleList.count]
    }

    var body: some View {
        let projection = SessionListProjection(
            sessions: Array(sessionStore.activeSessions.values),
            selectedProvider: selectedProvider
        )
        let displayedRateLimitProvider = selectedRateLimitProvider ?? projection.rateLimitProvider

        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // Top row: rate limits + sound + gear
                HStack(spacing: 8) {
                    RateLimitBar(
                        rateLimitStore: rateLimitStore,
                        provider: displayedRateLimitProvider,
                        onTap: { cycleRateLimitProvider(current: displayedRateLimitProvider) }
                    )
                    Spacer()
                    Button(action: { settingsStore.soundEnabled.toggle() }) {
                        Image(systemName: settingsStore.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(settingsStore.soundEnabled ? 0.6 : 0.3))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(settingsStore.soundEnabled ? "Mute sounds" : "Unmute sounds")
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open settings")
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

                // Filter chips — only show when there are >=2 providers active.
                // Horizontally scrollable so many providers (we support a dozen+)
                // keep their natural width instead of compressing into slivers.
                if projection.presentProviders.count >= 2 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            filterChip(provider: nil, label: "ALL", count: sessionStore.activeSessions.count, color: .white)
                            ForEach(projection.presentProviders) { p in
                                filterChip(provider: p, label: p.displayName.uppercased(), count: projection.sessions(for: p).count, color: p.accentColor)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                }
            }
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SessionListChromeHeightKey.self,
                        value: geometry.size.height
                    )
                }
            }

            if sessionStore.activeSessions.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 28))
                        .foregroundColor(.white.opacity(0.3))
                    Text("No active sessions")
                        .font(theme.font(size: 12))
                        .foregroundColor(.white.opacity(0.4))
                    Text("Start any coding agent to begin")
                        .font(theme.font(size: 11))
                        .foregroundColor(.white.opacity(0.3))
                }
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        ForEach(projection.visibleProviders) { provider in
                            let cards = projection.sessions(for: provider)
                            if !cards.isEmpty {
                                let isCollapsed = collapsedProviders.contains(provider.id)
                                VStack(alignment: .leading, spacing: 6) {
                                    // Section header — also the collapse toggle.
                                    // Shown when we're displaying more than one
                                    // provider OR a filter is active.
                                    if projection.visibleProviders.count >= 2 || selectedProvider != nil {
                                        Button {
                                            withAnimation(.easeInOut(duration: 0.18)) {
                                                if isCollapsed {
                                                    collapsedProviders.remove(provider.id)
                                                } else {
                                                    collapsedProviders.insert(provider.id)
                                                }
                                            }
                                        } label: {
                                            sectionHeader(
                                                provider: provider,
                                                count: cards.count,
                                                collapsed: isCollapsed
                                            )
                                            .padding(.horizontal, 4)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("\(provider.displayName), \(cards.count) sessions")
                                        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
                                    }
                                    if !isCollapsed {
                                        VStack(spacing: 6) {
                                            ForEach(cards, id: \.id) { session in
                                                SessionCardView(session: session)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: SessionListContentHeightKey.self,
                                value: geometry.size.height
                            )
                        }
                    }
                }
                .frame(height: SessionListWindowLayout.viewportHeight(
                    chromeHeight: measuredChromeHeight,
                    contentHeight: measuredListHeight
                ))
            }
        }
        .frame(maxWidth: .infinity)
        .onPreferenceChange(SessionListChromeHeightKey.self) { height in
            guard height > 0 else { return }
            measuredChromeHeight = height
            reportContentHeight(chromeHeight: height, listHeight: measuredListHeight)
        }
        .onPreferenceChange(SessionListContentHeightKey.self) { height in
            guard height > 0 else { return }
            measuredListHeight = height
            reportContentHeight(chromeHeight: measuredChromeHeight, listHeight: height)
        }
        .onAppear {
            reportContentHeight(chromeHeight: measuredChromeHeight, listHeight: measuredListHeight)
        }
        .onChange(of: projection.presentProviderIDs) { _, ids in
            guard let selectedProvider, !ids.contains(selectedProvider.id) else { return }
            self.selectedProvider = nil
        }
    }

    private func reportContentHeight(chromeHeight: CGFloat, listHeight: CGFloat) {
        onContentHeightChange(
            SessionListWindowLayout.fittedHeight(
                chromeHeight: chromeHeight,
                contentHeight: listHeight
            )
        )
    }

    @ViewBuilder
    private func filterChip(provider: AIProvider?, label: String, count: Int, color: Color) -> some View {
        let isSelected = selectedProvider?.id == provider?.id
        Button(action: { selectedProvider = provider }) {
            HStack(spacing: 5) {
                if let p = provider {
                    ProviderIcon(provider: p, size: 13)
                }
                Text(label)
                    .font(theme.font(size: 10, weight: .heavy))
                    .foregroundColor(isSelected ? color : color.opacity(0.55))
                    .kerning(0.8)
                    .lineLimit(1)
                    .fixedSize()
                Text("\(count)")
                    .font(theme.font(size: 9, weight: .bold))
                    .foregroundColor(isSelected ? color.opacity(0.85) : color.opacity(0.4))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .notchPill(theme, fill: isSelected ? color.opacity(0.14) : color.opacity(0.05), stroke: isSelected ? color.opacity(0.4) : nil, base: 6)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sectionHeader(provider: AIProvider, count: Int, collapsed: Bool) -> some View {
        HStack(spacing: 8) {
            ProviderIcon(provider: provider, size: 14)
            Text(provider.displayName.uppercased())
                .font(theme.font(size: 9, weight: .heavy))
                .foregroundColor(provider.accentColor.opacity(0.85))
                .kerning(1.2)
            Text("(\(count))")
                .font(theme.font(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.4))
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(height: 1)
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white.opacity(0.4))
                .rotationEffect(.degrees(collapsed ? 0 : 90))
        }
    }
}

enum SessionListWindowLayout {
    static let minimumHeight: CGFloat = 104
    static let maximumHeight: CGFloat = 320

    static func fittedHeight(chromeHeight: CGFloat, contentHeight: CGFloat) -> CGFloat {
        min(max(chromeHeight + contentHeight, minimumHeight), maximumHeight)
    }

    static func viewportHeight(chromeHeight: CGFloat, contentHeight: CGFloat) -> CGFloat {
        max(1, fittedHeight(chromeHeight: chromeHeight, contentHeight: contentHeight) - chromeHeight)
    }
}

private struct SessionListChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct SessionListContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A single snapshot of the active-session list. Keeping grouping, sorting and
/// filter recovery out of the view avoids repeating the same dictionary scan
/// throughout a SwiftUI body update.
struct SessionListProjection {
    let sessions: [Session]
    let presentProviders: [AIProvider]
    let visibleProviders: [AIProvider]
    let rateLimitProvider: AIProvider

    private let sessionsByProvider: [String: [Session]]

    init(sessions: [Session], selectedProvider: AIProvider?) {
        self.sessions = sessions

        let grouped = Dictionary(grouping: sessions, by: \.source)
            .mapValues { providerSessions in
                providerSessions.sorted(by: Self.isHigherPriority)
            }
        sessionsByProvider = grouped

        presentProviders = AIProvider.all.filter { grouped[$0.id]?.isEmpty == false }

        if let selectedProvider, grouped[selectedProvider.id]?.isEmpty == false {
            visibleProviders = [selectedProvider]
            rateLimitProvider = selectedProvider
        } else {
            visibleProviders = presentProviders
            rateLimitProvider = sessions.max(by: {
                $0.lastActivityAt < $1.lastActivityAt
            })?.provider ?? .codex
        }
    }

    var presentProviderIDs: [String] {
        presentProviders.map(\.id)
    }

    func sessions(for provider: AIProvider) -> [Session] {
        sessionsByProvider[provider.id] ?? []
    }

    private static func isHigherPriority(_ lhs: Session, _ rhs: Session) -> Bool {
        let lhsPriority = priority(of: lhs.status)
        let rhsPriority = priority(of: rhs.status)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        if lhs.lastActivityAt != rhs.lastActivityAt {
            return lhs.lastActivityAt > rhs.lastActivityAt
        }
        return lhs.startedAt > rhs.startedAt
    }

    private static func priority(of status: SessionStatus) -> Int {
        switch status {
        case .waitingPermission: return 0
        case .error: return 1
        case .toolUse, .thinking: return 2
        case .idle, .completed: return 3
        }
    }
}

/// Renders the provider's CLI icon from `Resources/cli-icons/<id>.png`, with a
/// monochrome circle fallback so it always renders even if the asset is missing.
struct ProviderIcon: View {
    let provider: AIProvider
    var size: CGFloat = 14

    var body: some View {
        if let image = Self.loadIcon(for: provider) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Circle()
                .fill(provider.accentColor)
                .frame(width: size, height: size)
        }
    }

    /// Look up `cli-icons/<id>.png` from the main bundle (SPM copies the directory in).
    /// We avoid `Bundle.module` (executable targets don't get it auto-generated)
    /// and just scan the main bundle's resource locations.
    private static let iconCache = IconCache()

    private static func loadIcon(for provider: AIProvider) -> NSImage? {
        iconCache.image(for: provider.id)
    }
}

/// In-memory icon cache backed by the main bundle's `cli-icons` directory.
final class IconCache {
    private var cache: [String: NSImage] = [:]
    private let lock = NSLock()

    func image(for id: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[id] { return cached }
        let bundle = Bundle.main
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates: [URL?] = [
            bundle.url(forResource: id, withExtension: "png", subdirectory: "cli-icons"),
            bundle.resourceURL?.appendingPathComponent("cli-icons/\(id).png"),
            bundle.bundleURL.appendingPathComponent("Contents/Resources/cli-icons/\(id).png"),
            // Dev fallback: project root Resources dir when running .build/debug/Aegis
            URL(fileURLWithPath: "\(home)/Documents/DEV/DESKTOP/AEGIS/Resources/cli-icons/\(id).png"),
        ]
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url) {
                cache[id] = image
                return image
            }
        }
        return nil
    }
}
