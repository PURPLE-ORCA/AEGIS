import Foundation
import Combine
import ServiceManagement

final class SettingsStore: ObservableObject {
    @Published var companionEnabled: Bool {
        didSet { UserDefaults.standard.set(companionEnabled, forKey: "companionEnabled") }
    }
    @Published var companionScale: Double {
        didSet {
            let clamped = min(max(companionScale, 0.75), 1.50)
            UserDefaults.standard.set(clamped, forKey: "companionScale")
        }
    }
    @Published var companionFollowsActiveWorkspace: Bool {
        didSet {
            UserDefaults.standard.set(
                companionFollowsActiveWorkspace,
                forKey: "companionFollowsActiveWorkspace"
            )
        }
    }
    @Published var hermesVoiceHandoffEnabled: Bool {
        didSet { UserDefaults.standard.set(hermesVoiceHandoffEnabled, forKey: "hermesVoiceHandoffEnabled") }
    }
    @Published var hermesVoiceWorkingDirectory: String {
        didSet { UserDefaults.standard.set(hermesVoiceWorkingDirectory, forKey: "hermesVoiceWorkingDirectory") }
    }
    @Published var hermesVoiceTarget: HermesHandoffTarget {
        didSet { UserDefaults.standard.set(hermesVoiceTarget.rawValue, forKey: "hermesVoiceTarget") }
    }
    @Published var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }
    @Published var soundVolume: Float {
        didSet { UserDefaults.standard.set(soundVolume, forKey: "soundVolume") }
    }
    @Published var soundProfile: SoundProfile {
        didSet { UserDefaults.standard.set(soundProfile.rawValue, forKey: "soundProfile") }
    }
    @Published var autoExpandOnPermission: Bool {
        didSet { UserDefaults.standard.set(autoExpandOnPermission, forKey: "autoExpandOnPermission") }
    }
    @Published var expandOnHover: Bool {
        didSet { UserDefaults.standard.set(expandOnHover, forKey: "expandOnHover") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            updateLoginItem()
        }
    }
    @Published var hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }

    /// Whether the user has seen the redesigned (themed, full-screen) onboarding.
    /// Separate from `hasCompletedOnboarding` so existing users — who already
    /// completed the OLD onboarding — get shown the new one once on update, then
    /// never again. Fresh installs see it via this flag being false too.
    @Published var hasSeenThemeOnboarding: Bool {
        didSet { UserDefaults.standard.set(hasSeenThemeOnboarding, forKey: "hasSeenThemeOnboarding") }
    }

    /// Selected visual theme for the notch windows. Persisted by raw value.
    @Published var notchThemeID: NotchThemeID {
        didSet { UserDefaults.standard.set(notchThemeID.rawValue, forKey: "notchThemeID") }
    }

    /// Last app version for which we showed the "What's New" card. Shown once
    /// per version bump (returning users on update); fresh installs get
    /// onboarding instead and have this stamped to the current version.
    @Published var lastWhatsNewVersion: String {
        didSet { UserDefaults.standard.set(lastWhatsNewVersion, forKey: "lastWhatsNewVersion") }
    }

    /// Providers whose hooks are blanket "before every tool" gates (no native
    /// selective permission event). Strict-approval mode turns those into
    /// blocking in-notch approve/deny prompts — opt-in, per provider.
    static let strictApprovalProviders = ["antigravity", "hermes"]

    /// Per-provider "review every action" flags (default off). Persisted to
    /// UserDefaults AND mirrored to ~/.aegis/config.json so the bridge
    /// (a separate process) can decide whether to block a `before*` hook.
    @Published var strictApproval: [String: Bool] {
        didSet { persistStrictApproval() }
    }

    /// Per-event sound assignment: `SoundEvent.rawValue` → "default" | "off" |
    /// "<library filename>". Missing key = "default". Persisted as JSON.
    @Published var soundAssignments: [String: String] {
        didSet {
            if let data = try? JSONEncoder().encode(soundAssignments) {
                UserDefaults.standard.set(data, forKey: "soundAssignments")
            }
        }
    }
    func soundChoice(for eventRaw: String) -> String { soundAssignments[eventRaw] ?? "default" }
    func setSoundChoice(_ choice: String, for eventRaw: String) { soundAssignments[eventRaw] = choice }

    /// Per-event gain applied after the selected built-in or custom sound.
    @Published var soundEventVolumes: [String: Float] {
        didSet {
            if let data = try? JSONEncoder().encode(soundEventVolumes) {
                UserDefaults.standard.set(data, forKey: "soundEventVolumes")
            }
        }
    }
    func soundEventVolume(for eventRaw: String) -> Float { soundEventVolumes[eventRaw] ?? 1 }
    func setSoundEventVolume(_ volume: Float, for eventRaw: String) {
        soundEventVolumes[eventRaw] = max(0, min(1, volume))
    }

    static let supportedAudioExts = ["wav", "mp3", "m4a", "aiff", "caf"]

    /// The sound library = audio files the user has imported (and any legacy
    /// event-named files), living in `~/.aegis/sound-packs/`.
    func soundLibraryDirectory() -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aegis/sound-packs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func soundLibraryFiles() -> [String] {
        let dir = soundLibraryDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files
            .filter { Self.supportedAudioExts.contains(($0 as NSString).pathExtension.lowercased()) }
            .sorted()
    }
    /// Copy an imported file into the library (de-duping the name). Returns the stored filename.
    @discardableResult
    func importSound(from url: URL) -> String? {
        let dir = soundLibraryDirectory()
        let base = (url.lastPathComponent as NSString).deletingPathExtension
        let ext = (url.lastPathComponent as NSString).pathExtension
        var name = url.lastPathComponent
        var dest = dir.appendingPathComponent(name)
        var i = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            name = "\(base)-\(i).\(ext)"; dest = dir.appendingPathComponent(name); i += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            objectWillChange.send()
            return name
        } catch { return nil }
    }
    func deleteSound(_ filename: String) {
        try? FileManager.default.removeItem(at: soundLibraryDirectory().appendingPathComponent(filename))
        for (k, v) in soundAssignments where v == filename { soundAssignments[k] = "default" }
        objectWillChange.send()
    }

    init() {
        Self.migrateLegacyInstallationIfNeeded()
        let defaults = UserDefaults.standard
        let preferredHermesDirectory = HermesHandoffConfiguration.preferredWorkingDirectory(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        ).path

        // Register defaults
        defaults.register(defaults: [
            "companionEnabled": false,
            "companionScale": 1.0,
            "companionFollowsActiveWorkspace": true,
            "hermesVoiceHandoffEnabled": true,
            "hermesVoiceWorkingDirectory": preferredHermesDirectory,
            "hermesVoiceTarget": HermesHandoffTarget.newSession.rawValue,
            "soundEnabled": true,
            "soundVolume": Float(0.7),
            "soundProfile": SoundProfile.quietGlass.rawValue,
            "autoExpandOnPermission": true,
            "expandOnHover": true,
            "launchAtLogin": false,
            "hasCompletedOnboarding": false,
            "soundSessionStart": false,
            "soundCompletion": true,
            "soundToolUse": false,
            "soundError": true,
            "soundPermission": true,
            "notchThemeID": NotchThemeID.aegis.rawValue,
            "hasSeenThemeOnboarding": false,
        ])

        self.companionEnabled = defaults.bool(forKey: "companionEnabled")
        self.companionScale = min(max(defaults.double(forKey: "companionScale"), 0.75), 1.50)
        self.companionFollowsActiveWorkspace = defaults.bool(forKey: "companionFollowsActiveWorkspace")
        self.hermesVoiceHandoffEnabled = defaults.bool(forKey: "hermesVoiceHandoffEnabled")
        self.hermesVoiceWorkingDirectory = defaults.string(forKey: "hermesVoiceWorkingDirectory")
            ?? preferredHermesDirectory
        self.hermesVoiceTarget = HermesHandoffTarget(
            rawValue: defaults.string(forKey: "hermesVoiceTarget") ?? ""
        ) ?? .newSession
        self.soundEnabled = defaults.bool(forKey: "soundEnabled")
        self.soundVolume = defaults.float(forKey: "soundVolume")
        let storedSoundProfile = defaults.string(forKey: "soundProfile")
        self.soundProfile = Self.resolveSoundProfile(rawValue: storedSoundProfile)
        if storedSoundProfile == "yamete-kudasai" {
            defaults.set(SoundProfile.meme.rawValue, forKey: "soundProfile")
        }
        self.autoExpandOnPermission = defaults.bool(forKey: "autoExpandOnPermission")
        self.expandOnHover = defaults.bool(forKey: "expandOnHover")
        self.launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        self.hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
        // Load per-event assignments, or migrate once from the old toggles
        // (a `false` toggle → "off"). The old keys stay registered above so
        // this read returns correct defaults for fresh installs too.
        var assignments: [String: String]
        if let data = defaults.data(forKey: "soundAssignments"),
           let map = try? JSONDecoder().decode([String: String].self, from: data) {
            assignments = map
        } else {
            var m: [String: String] = [:]
            if !defaults.bool(forKey: "soundSessionStart") { m["session-start"] = "off"; m["session-end"] = "off" }
            if !defaults.bool(forKey: "soundCompletion") { m["completion"] = "off" }
            if !defaults.bool(forKey: "soundToolUse") { m["tool-use"] = "off" }
            if !defaults.bool(forKey: "soundError") { m["error"] = "off" }
            if !defaults.bool(forKey: "soundPermission") {
                m["approval-needed"] = "off"; m["approval-granted"] = "off"; m["approval-denied"] = "off"
            }
            assignments = m
        }
        // Calm palette defaults to meaningful notifications only. Preserve
        // custom files and explicit Off choices while silencing legacy default
        // start/end chatter once for existing installs.
        if defaults.integer(forKey: "builtInSoundVersion") < 2 {
            for key in ["session-start", "session-end"] where assignments[key] == nil || assignments[key] == "default" {
                assignments[key] = "off"
            }
            defaults.set(2, forKey: "builtInSoundVersion")
        }
        self.soundAssignments = assignments
        if let data = defaults.data(forKey: "soundEventVolumes"),
           let map = try? JSONDecoder().decode([String: Float].self, from: data) {
            self.soundEventVolumes = map.mapValues { max(0, min(1, $0)) }
        } else {
            self.soundEventVolumes = [:]
        }
        var selectedTheme = NotchThemeID(rawValue: defaults.string(forKey: "notchThemeID") ?? "") ?? .aegis
        if defaults.integer(forKey: "appearanceVersion") < 2 {
            selectedTheme = .aegis
            defaults.set(NotchThemeID.aegis.rawValue, forKey: "notchThemeID")
            defaults.set(2, forKey: "appearanceVersion")
        }
        self.notchThemeID = selectedTheme
        self.hasSeenThemeOnboarding = defaults.bool(forKey: "hasSeenThemeOnboarding")
        self.lastWhatsNewVersion = defaults.string(forKey: "lastWhatsNewVersion") ?? ""

        if let data = defaults.data(forKey: "strictApproval"),
           let map = try? JSONDecoder().decode([String: Bool].self, from: data) {
            self.strictApproval = map
        } else {
            self.strictApproval = [:]
        }
        // Mirror to the bridge config on launch so it reflects the saved state.
        writeBridgeConfig()
        if launchAtLogin { updateLoginItem() }
    }

    static func resolveSoundProfile(rawValue: String?) -> SoundProfile {
        if rawValue == "yamete-kudasai" { return .meme }
        return SoundProfile(rawValue: rawValue ?? "") ?? .quietGlass
    }

    private static func migrateLegacyInstallationIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "aegisLegacyIdentityMigrationCompleted"
        guard !defaults.bool(forKey: migrationKey) else { return }

        if let legacyDomain = defaults.persistentDomain(forName: "dev.caesura.island") {
            for (key, value) in legacyDomain where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let legacySounds = home.appendingPathComponent(".caesura-island/sound-packs", isDirectory: true)
        let currentSounds = home.appendingPathComponent(".aegis/sound-packs", isDirectory: true)
        if let filenames = try? fileManager.contentsOfDirectory(atPath: legacySounds.path) {
            try? fileManager.createDirectory(at: currentSounds, withIntermediateDirectories: true)
            for filename in filenames {
                let source = legacySounds.appendingPathComponent(filename)
                let destination = currentSounds.appendingPathComponent(filename)
                guard !fileManager.fileExists(atPath: destination.path) else { continue }
                try? fileManager.copyItem(at: source, to: destination)
            }
        }

        defaults.set(true, forKey: migrationKey)
    }

    /// Convenience accessor/mutator for the per-provider toggle.
    func isStrict(_ provider: String) -> Bool { strictApproval[provider] == true }
    func setStrict(_ provider: String, _ on: Bool) { strictApproval[provider] = on }

    private func persistStrictApproval() {
        if let data = try? JSONEncoder().encode(strictApproval) {
            UserDefaults.standard.set(data, forKey: "strictApproval")
        }
        writeBridgeConfig()
    }

    /// Writes ~/.aegis/config.json — the bridge reads this each run to
    /// decide whether to block a provider's `before*` hook for approval.
    private func writeBridgeConfig() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".aegis")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        let payload: [String: Any] = ["strictApproval": strictApproval]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func updateLoginItem() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            print("[Aegis] Login item error: \(error)")
        }
    }
}
