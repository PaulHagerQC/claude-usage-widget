// ClaudeUsage — a small floating macOS widget that shows your Claude usage bars
// (current session, weekly, weekly per-model limits such as Fable).
//
// Build:  bash build.sh      Run: open ClaudeUsage.app
// Drag it anywhere; right-click for options. Position is remembered.
// Reads usage through your Claude Code login (run `claude` and /login once).

import Cocoa
import SwiftUI
import Security

// MARK: - Model

struct Bucket: Identifiable {
    let id: String          // key in the API response, e.g. "five_hour", "seven_day_fable"
    let label: String
    let percent: Double
    let resetsAt: Date?
    var detail: String? = nil   // shown instead of a reset time, e.g. "$217 of $5,000 this month"
}

struct HTTPStatusError: Error { let code: Int }

struct WidgetError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

final class UsageStore: ObservableObject, @unchecked Sendable {
    @Published var buckets: [Bucket] = []
    @Published var status: String = "Loading…"
    @Published var source: String = "—"
    @Published var lastUpdated: Date?

    private var timer: Timer?
    private var cached: Credentials?   // in memory only; re-read from the keychain when expired/rejected

    func start() {
        refresh()
        restartTimer()
    }

    func restartTimer() {
        timer?.invalidate()
        let secs = max(15, UserDefaults.standard.integer(forKey: Pref.refreshSeconds))
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(secs), repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        Task { await self.load() }
    }

    private func load() async {
        do {
            if let c = cached, let exp = c.expiresAt, exp < Date() { cached = nil }
            if cached == nil { cached = Self.claudeCodeCredentials() }
            guard let creds = cached else {
                await MainActor.run {
                    self.buckets = []
                    self.source = "none"
                    self.status = "No Claude login found. In Terminal run `claude`, type /login and pick your Claude account, then right-click → Refresh now."
                }
                return
            }
            if let exp = creds.expiresAt, exp < Date() {
                throw WidgetError("Claude login expired. Run `claude` in Terminal for a moment to renew it, then right-click → Refresh now.")
            }
            let json: [String: Any]
            do {
                json = try await fetchUsage(token: creds.token)
            } catch let e as HTTPStatusError where e.code == 401 {
                cached = nil   // Claude Code may have renewed the login — read it again next time
                throw WidgetError("Not authorized (401). Run `claude` in Terminal and /login again, then right-click → Refresh now.")
            }
            let src = "Claude Code login"
            let parsed = Self.parse(json)
            await MainActor.run {
                self.buckets = parsed
                self.source = src
                self.lastUpdated = Date()
                self.status = parsed.isEmpty ? "No usage bars in response" : ""
            }
        } catch {
            await MainActor.run { self.status = error.localizedDescription }
        }
    }

    // MARK: Network — one fixed HTTPS endpoint, nothing stored, no redirects

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// No cookies, no response cache, no credential storage on disk.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        cfg.urlCredentialStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// Never follow a redirect: the request carries your token, so it must only ever go to usageURL.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private func fetchUsage(token: String) async throws -> [String: Any] {
        var r = URLRequest(url: Self.usageURL)
        r.httpShouldHandleCookies = false
        r.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        guard r.url?.scheme == "https", r.url?.host == "api.anthropic.com" else {
            throw WidgetError("Refusing to send the login to \(r.url?.host ?? "?")")
        }
        let (data, resp) = try await Self.session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            if code == 401 { throw HTTPStatusError(code: code) }
            if code == 429 { throw WidgetError("Rate limited by the usage server — will retry at the next refresh.") }
            throw WidgetError("HTTP \(code) from api.anthropic.com")
        }
        guard let u = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WidgetError("Unexpected usage response")
        }
        return u
    }

    // MARK: Claude Code login — read directly from the macOS keychain
    //
    // Reads exactly one keychain item ("Claude Code-credentials", which Claude Code creates
    // when you /login) and keeps only the access token and its expiry. The refresh token and
    // anything else in that item are ignored, and nothing is written back.

    struct Credentials { let token: String; let expiresAt: Date? }

    static func claudeCodeCredentials() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let tok = oauth["accessToken"] as? String else { return nil }
        var exp: Date?
        if let ms = (oauth["expiresAt"] as? NSNumber)?.doubleValue { exp = Date(timeIntervalSince1970: ms / 1000) }
        return Credentials(token: tok, expiresAt: exp)
    }

    // MARK: Parsing
    // 1. Any top-level object with a numeric "utilization" becomes a bar (five_hour, seven_day, …).
    // 2. The "limits" list adds limits that only appear there — e.g. a per-model weekly limit
    //    such as Fable ({"kind": "weekly_scoped", "scope": {"model": {"display_name": "Fable"}}}).

    static func parse(_ json: [String: Any]) -> [Bucket] {
        var out: [Bucket] = []
        for (k, v) in json {
            guard let d = v as? [String: Any],
                  let u = (d["utilization"] as? NSNumber)?.doubleValue else { continue }
            var b = Bucket(id: k, label: label(for: k), percent: u,
                           resetsAt: parseDate(d["resets_at"] as? String))
            if k == "extra_usage" { b.detail = creditsText(d) }
            out.append(b)
        }
        for l in (json["limits"] as? [[String: Any]]) ?? [] {
            guard let pct = (l["percent"] as? NSNumber)?.doubleValue else { continue }
            let kind = l["kind"] as? String ?? ""
            let scope = l["scope"] as? [String: Any]
            let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
            let surface = (scope?["surface"] as? [String: Any])?["display_name"] as? String
                ?? scope?["surface"] as? String
            let id: String, name: String
            switch kind {
            case "session": id = "five_hour"; name = label(for: id)
            case "weekly_all": id = "seven_day"; name = label(for: id)
            default:
                guard let what = model ?? surface else { continue }
                let slug = what.lowercased().replacingOccurrences(of: " ", with: "_")
                id = (l["group"] as? String == "weekly" ? "seven_day_" : kind + "_") + slug
                name = (l["group"] as? String == "weekly" ? "Weekly · " : "") + what
            }
            if out.contains(where: { $0.id == id }) { continue }
            out.append(Bucket(id: id, label: name, percent: pct,
                              resetsAt: parseDate(l["resets_at"] as? String)))
        }
        return out.sorted {
            let a = order($0.id), b = order($1.id)
            return a != b ? a < b : $0.id < $1.id
        }
    }

    /// "$217 of $5,000 this month" from the extra_usage object (amounts are in cents).
    static func creditsText(_ d: [String: Any]) -> String? {
        guard let used = (d["used_credits"] as? NSNumber)?.doubleValue,
              let limit = (d["monthly_limit"] as? NSNumber)?.doubleValue else { return nil }
        let places = (d["decimal_places"] as? NSNumber)?.intValue ?? 2
        let div = pow(10, Double(places))
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = d["currency"] as? String ?? "USD"
        f.maximumFractionDigits = 0
        guard let u = f.string(from: NSNumber(value: used / div)),
              let l = f.string(from: NSNumber(value: limit / div)) else { return nil }
        return "\(u) of \(l) this month"
    }

    static func order(_ k: String) -> Int {
        switch k {
        case "five_hour": return 0
        case "seven_day": return 1
        case "extra_usage": return 9
        default: return k.hasPrefix("seven_day_") ? 2 : 3
        }
    }

    static func label(for k: String) -> String {
        switch k {
        case "five_hour": return "Current session"
        case "seven_day": return "Weekly · all models"
        case "extra_usage": return "Extra usage (credits)"
        default: break
        }
        let pretty: (Substring) -> String = { s in
            s.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        if k.hasPrefix("seven_day_") { return "Weekly · " + pretty(k.dropFirst("seven_day_".count)) }
        return pretty(Substring(k))
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: s) { return d }
        if let r = s.range(of: #"\.\d+"#, options: .regularExpression) {
            var t = s
            t.removeSubrange(r)
            return f2.date(from: t)
        }
        return nil
    }
}

// MARK: - Views

func resetText(_ d: Date?) -> String? {
    guard let d = d else { return nil }
    let s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return "resetting…" }
    let days = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if days > 0 {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return "resets \(f.string(from: d)) (in \(days)d \(h)h)"
    }
    if h > 0 { return "resets in \(h)h \(m)m" }
    return "resets in \(max(m, 1))m"
}

/// Shortest possible time-to-reset for compact rows: "45m", "2h", "3d".
func shortResetText(_ d: Date?) -> String? {
    guard let d = d else { return nil }
    let s = d.timeIntervalSinceNow
    if s <= 0 { return "now" }
    if s < 3600 { return "\(max(1, Int((s / 60).rounded())))m" }
    if s < 86400 { return "\(Int((s / 3600).rounded()))h" }
    return "\(Int((s / 86400).rounded()))d"
}

struct Blur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Settings (stored in UserDefaults, changed from the right-click menu)

enum Pref {
    static let scale = "scale"               // text size the widget keeps when its content changes
    static let compact = "compact"           // one line per bar
    static let showPercent = "showPercent"
    static let showResets = "showResets"
    static let showUpdated = "showUpdated"
    static let opacity = "opacity"           // 0.4 … 1.0
    static let refreshSeconds = "refreshSeconds"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            scale: 1.0, compact: true, showPercent: true, showResets: true,
            showUpdated: true, opacity: 1.0, refreshSeconds: 60,
        ])
    }

}

/// How the content fits the window. The window is resized freely (like any macOS window);
/// text grows/shrinks to fit the height, and bars stretch to fill the width.
enum Layout {
    static func baseWidth(compact: Bool) -> CGFloat { compact ? 300 : 250 }
    /// Narrowest the content may get (at 100 % text size) before text has to shrink.
    static func minWidth(compact: Bool) -> CGFloat { compact ? 245 : 185 }

    /// Text scale for a window of this size, given the content's height at 100 %.
    static func scale(width: CGFloat, height: CGFloat, natural: CGFloat, compact: Bool) -> CGFloat {
        guard natural > 0, width > 0, height > 0 else { return 1 }
        return min(3, max(0.5, min(height / natural, width / minWidth(compact: compact))))
    }
}

struct BarRow: View {
    let bucket: Bucket
    let scale: CGFloat
    let compact: Bool
    let showPercent: Bool
    let showResets: Bool

    var color: Color {
        bucket.percent >= 90 ? .red : bucket.percent >= 70 ? .orange : .accentColor
    }

    var bar: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(color)
                    .frame(width: bucket.percent > 0
                           ? max(4, g.size.width * min(bucket.percent, 100) / 100) : 0)
            }
        }
        .frame(height: 6 * scale)
    }

    var percentText: some View {
        Text("\(Int(bucket.percent.rounded()))%")
            .font(.system(size: 11 * scale, weight: .semibold).monospacedDigit())
    }

    var body: some View {
        if compact {
            HStack(spacing: 8 * scale) {
                Text(bucket.label).font(.system(size: 10.5 * scale, weight: .medium))
                    .lineLimit(1)
                    .frame(width: 118 * scale, alignment: .leading)
                bar
                if showPercent { percentText.frame(width: 34 * scale, alignment: .trailing) }
                if showResets {
                    Text(shortResetText(bucket.resetsAt) ?? "")
                        .font(.system(size: 9.5 * scale).monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 24 * scale, alignment: .trailing)
                }
            }
            .help(resetText(bucket.resetsAt) ?? bucket.detail ?? "")
        } else {
            VStack(alignment: .leading, spacing: 3 * scale) {
                HStack {
                    Text(bucket.label).font(.system(size: 11 * scale, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 4 * scale)
                    if showPercent { percentText }
                }
                bar
                if showResets, let r = resetText(bucket.resetsAt) ?? bucket.detail {
                    Text(r).font(.system(size: 9.5 * scale)).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct NaturalHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct UsageView: View {
    @ObservedObject var store: UsageStore
    var onNaturalHeight: (CGFloat) -> Void = { _ in }
    @AppStorage("hiddenBuckets") var hiddenRaw: String = ""
    @AppStorage(Pref.compact) var compact: Bool = true
    @AppStorage(Pref.showPercent) var showPercent: Bool = true
    @AppStorage(Pref.showResets) var showResets: Bool = true
    @AppStorage(Pref.showUpdated) var showUpdated: Bool = true
    @State private var natural: CGFloat = 0

    var visible: [Bucket] {
        let hidden = Set(hiddenRaw.split(separator: ",").map(String.init))
        return store.buckets.filter { !hidden.contains($0.id) }
    }

    func content(_ k: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: (compact ? 6 : 9) * k) {
            ForEach(visible) { b in
                BarRow(bucket: b, scale: k, compact: compact,
                       showPercent: showPercent, showResets: showResets)
            }
            if !store.status.isEmpty {
                Text(store.status)
                    .font(.system(size: 10 * k))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if showUpdated, let t = store.lastUpdated {
                Text("updated \(t, style: .time)")
                    .font(.system(size: 9 * k))
                    .foregroundColor(.secondary.opacity(0.7))
            } else if visible.isEmpty {
                Text("All bars hidden — right-click → Show bars")
                    .font(.system(size: 10 * k))
                    .foregroundColor(.secondary)
            }
        }
        .padding((compact ? 9 : 12) * k)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        GeometryReader { g in
            let k = Layout.scale(width: g.size.width, height: g.size.height,
                                 natural: natural, compact: compact)
            content(k).frame(width: g.size.width, height: g.size.height, alignment: .center)
        }
        // Invisible copy at 100 % size, only to measure how tall the content wants to be.
        .background(alignment: .topLeading) {
            content(1)
                .frame(width: Layout.baseWidth(compact: compact))
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { c in
                    Color.clear.preference(key: NaturalHeightKey.self, value: c.size.height)
                })
                .hidden()
        }
        .onPreferenceChange(NaturalHeightKey.self) { h in
            natural = h
            onNaturalHeight(h)
        }
        .background(Blur().clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .ignoresSafeArea()      // use the invisible title-bar strip too
    }
}

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    // NSHostingView swallows right-clicks for SwiftUI, so `menu` is never shown
    // automatically — pop it up ourselves.
    override func rightMouseDown(with event: NSEvent) { showMenu(event) }

    func showMenu(_ event: NSEvent) {
        guard let menu = menu else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// A frameless-looking window that still uses macOS's own edge/corner resizing.
/// (It's technically "titled" with an invisible title bar — borderless windows can't
/// be resized from their edges.)
final class WidgetPanel: NSPanel {
    var onContextClick: ((NSEvent) -> Void)?

    override func sendEvent(_ event: NSEvent) {
        // Right-click / Ctrl-click anywhere — including the invisible title-bar strip — opens our menu.
        if event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            onContextClick?(event)
            return
        }
        super.sendEvent(event)
    }
    // Double-clicking the invisible title bar must not zoom or minimize the widget.
    override func zoom(_ sender: Any?) {}
    override func performZoom(_ sender: Any?) {}
    override func miniaturize(_ sender: Any?) {}
    override func performMiniaturize(_ sender: Any?) {}
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let store = UsageStore()
    var panel: WidgetPanel!
    var hosting: DraggableHostingView<UsageView>!
    var natural: CGFloat = 0              // content height at 100 % text size
    let defaults = UserDefaults.standard

    var keepOnTop: Bool {
        get { defaults.object(forKey: "keepOnTop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepOnTop") }
    }
    var compact: Bool { defaults.bool(forKey: Pref.compact) }

    // A background (no Dock icon) app has no menu bar, and ⌘C/⌘V/⌘X/⌘A are routed
    // through the Edit menu's key equivalents — without one, paste does nothing in text fields.
    func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.registerDefaults()
        installEditMenu()
        panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 270, height: 90),
                            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(b)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = keepOnTop ? .floating : .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.alphaValue = CGFloat(defaults.double(forKey: Pref.opacity))
        panel.minSize = NSSize(width: 150, height: 50)
        panel.maxSize = NSSize(width: 1200, height: 900)
        panel.delegate = self

        hosting = DraggableHostingView(rootView: UsageView(store: store) { [weak self] h in
            self?.naturalHeightChanged(h)
        })
        let menu = NSMenu()
        menu.delegate = self
        hosting.menu = menu
        panel.contentView = hosting
        panel.onContextClick = { [weak self] e in self?.hosting.showMenu(e) }

        if !panel.setFrameUsingName("ClaudeUsageWidget"), let screen = NSScreen.main {
            let v = screen.visibleFrame
            let w = Layout.baseWidth(compact: compact)
            panel.setFrame(NSRect(x: v.maxX - w - 20, y: v.maxY - 110, width: w, height: 90), display: false)
        }
        panel.setFrameAutosaveName("ClaudeUsageWidget")
        panel.orderFrontRegardless()
        #if !SNAPSHOT   // test builds don't call the usage server
        store.start()
        #endif
    }

    // MARK: Sizing

    /// The content changed (bars shown/hidden, data loaded, layout toggled): keep the current
    /// text size and adjust only the height, keeping the top edge where it is.
    func naturalHeightChanged(_ h: CGFloat) {
        natural = h
        guard h > 0, let panel = panel, !panel.inLiveResize else { return }
        let f = panel.frame
        let k = min(CGFloat(defaults.double(forKey: Pref.scale)),
                    f.width / Layout.minWidth(compact: compact))
        setSize(NSSize(width: f.width, height: (h * k).rounded()))
    }

    /// You finished dragging an edge: remember the text size that resulted.
    func windowDidEndLiveResize(_ notification: Notification) {
        let f = panel.frame
        let k = Layout.scale(width: f.width, height: f.height, natural: natural, compact: compact)
        defaults.set(Double(k), forKey: Pref.scale)
    }

    func setSize(_ size: NSSize) {
        let old = panel.frame
        guard abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 else { return }
        panel.setFrame(NSRect(x: old.minX, y: old.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    // MARK: Right-click menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        add(menu, "Refresh now", #selector(refreshNow))
        menu.addItem(.separator())

        if !store.buckets.isEmpty {
            let header = NSMenuItem(title: "Show bars", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            let hidden = hiddenSet()
            for b in store.buckets {
                let it = add(menu, "   " + b.label, #selector(toggleBucket(_:)))
                it.representedObject = b.id
                it.state = hidden.contains(b.id) ? .off : .on
            }
            menu.addItem(.separator())
        }

        // Appearance
        let layout = add(menu, "Compact layout", #selector(togglePref(_:)))
        layout.representedObject = Pref.compact
        layout.state = compact ? .on : .off
        menu.addItem(opacitySliderItem())
        menu.addItem(.separator())

        // What to show
        let header2 = NSMenuItem(title: "Show details", action: nil, keyEquivalent: "")
        header2.isEnabled = false
        menu.addItem(header2)
        for (title, key) in [("Percentages", Pref.showPercent),
                             ("Reset times", Pref.showResets),
                             ("Last updated", Pref.showUpdated)] {
            let it = add(menu, "   " + title, #selector(togglePref(_:)))
            it.representedObject = key
            it.state = defaults.bool(forKey: key) ? .on : .off
        }
        menu.addItem(.separator())

        submenu(menu, "Refresh every",
                [("30 seconds", 30), ("1 minute", 60), ("2 minutes", 120), ("5 minutes", 300)],
                selected: defaults.integer(forKey: Pref.refreshSeconds),
                action: #selector(setRefresh(_:)))
        add(menu, "Keep on top", #selector(toggleOnTop)).state = keepOnTop ? .on : .off
        add(menu, "Reset settings", #selector(resetSettings))
        menu.addItem(.separator())
        let src = NSMenuItem(title: "Source: \(store.source)", action: nil, keyEquivalent: "")
        src.isEnabled = false
        menu.addItem(src)
        menu.addItem(.separator())
        add(menu, "Quit", #selector(quit))
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        menu.addItem(it)
        return it
    }

    func submenu<T: Equatable>(_ menu: NSMenu, _ title: String, _ options: [(String, T)],
                               selected: T, action: Selector) {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (label, value) in options {
            let it = NSMenuItem(title: label, action: action, keyEquivalent: "")
            it.target = self
            it.representedObject = value
            it.state = value == selected ? .on : .off
            sub.addItem(it)
        }
        parent.submenu = sub
        menu.addItem(parent)
    }

    func hiddenSet() -> Set<String> {
        Set((defaults.string(forKey: "hiddenBuckets") ?? "").split(separator: ",").map(String.init))
    }

    @objc func refreshNow() { store.refresh() }

    @objc func toggleBucket(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var h = hiddenSet()
        if h.contains(id) { h.remove(id) } else { h.insert(id) }
        defaults.set(h.sorted().joined(separator: ","), forKey: "hiddenBuckets")
    }

    @objc func toggleOnTop() {
        keepOnTop.toggle()
        panel.level = keepOnTop ? .floating : .normal
    }

    /// Resize to the standard width for the layout at text size k (height fits the content).
    func fitDefaultSize(_ k: Double) {
        defaults.set(k, forKey: Pref.scale)
        let k = CGFloat(k)
        setSize(NSSize(width: (Layout.baseWidth(compact: compact) * k).rounded(),
                       height: (natural * k).rounded()))
    }

    @objc func togglePref(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        defaults.set(!defaults.bool(forKey: key), forKey: key)
        // Switching layout changes the natural width; resize to match at the current text size.
        if key == Pref.compact { fitDefaultSize(defaults.double(forKey: Pref.scale)) }
    }

    var opacityLabel: NSTextField?

    /// A menu row with a live slider: drag it and the widget fades immediately.
    func opacitySliderItem() -> NSMenuItem {
        let pct = Int((defaults.double(forKey: Pref.opacity) * 100).rounded())
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 46))
        let label = NSTextField(labelWithString: "Opacity: \(pct)%")
        label.font = .menuFont(ofSize: 0)
        label.frame = NSRect(x: 20, y: 24, width: 200, height: 17)
        let slider = NSSlider(value: Double(pct), minValue: 20, maxValue: 100,
                              target: self, action: #selector(opacityChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 20, y: 4, width: 205, height: 18)
        view.addSubview(label)
        view.addSubview(slider)
        opacityLabel = label
        let item = NSMenuItem()
        item.view = view
        return item
    }

    @objc func opacityChanged(_ sender: NSSlider) {
        let pct = Int(sender.doubleValue.rounded())
        defaults.set(Double(pct) / 100, forKey: Pref.opacity)
        panel.alphaValue = CGFloat(pct) / 100
        opacityLabel?.stringValue = "Opacity: \(pct)%"
    }

    @objc func setRefresh(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Int else { return }
        defaults.set(v, forKey: Pref.refreshSeconds)
        store.restartTimer()
    }

    @objc func resetSettings() {
        for k in [Pref.scale, "size", Pref.compact, Pref.showPercent, Pref.showResets, Pref.showUpdated,
                  Pref.opacity, Pref.refreshSeconds, "hiddenBuckets", "keepOnTop"] {
            defaults.removeObject(forKey: k)
        }
        panel.alphaValue = 1
        panel.level = .floating
        store.restartTimer()
        fitDefaultSize(1.0)
    }

    @objc func quit() { NSApp.terminate(nil) }
}

#if !SNAPSHOT
@main
enum ClaudeUsageMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
