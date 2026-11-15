// Launcher settings, validation and persistence. Shared by the iOS UI, the Mac app's settings window (dm/mac/Launcher.swift) and the native storage regression test.
import Foundation
import Combine

struct Setting: Decodable, Identifiable {
    let env, kind, label: String
    var note, def: String   // var: this phone's own starting values and notes (Launcher.swift deviceAdjusted)
    let section: String?   // heading on the settings screen; absent in older bundles
    let needs: String?     // "<VAR>=<value>": a sub-setting, drawn only while that setting has that value
    let level: String?     // "basic": shown first (the Mac window's Basic settings); any other or none: Advanced settings. The iPhone keeps one list
    let base: Base?        // render scale: the 3D views' size at 1.0, docked and handheld, for the size in pixels (the Mac window)
    struct Base: Decodable { let docked, handheld: [Int] }
    var options: [[String]]?   // choice: [value, label]; var: a choice this phone cannot make leaves (deviceAdjusted)
    let min, max, step: Double?   // range
    let on, off: String?   // toggle: the values the variable takes (1 / 0 when not given)
    let sets: [String]?    // Potato mode (DM_PRESET): the rows it sets when the game starts, locked while it is on (settings.py)
    var id: String { env }
    var sectionTitle: String { section ?? "Game" }
    var basic: Bool { level == "basic" }
    var onValue: String { on ?? "1" }
    var offValue: String { off ?? "0" }
    func isDefault(_ v: String) -> Bool {   // a range compares as numbers (a slider writes 1.00 for 1.0)
        kind == "range" ? abs((Double(v) ?? .nan) - (Double(def) ?? .nan)) < 1e-6 : v == def
    }
    func accepts(_ v: String) -> Bool {   // a saved choice the game still offers
        switch kind {
        case "choice": return options?.contains { $0[0] == v } ?? false
        case "range":
            guard !v.contains(where: { $0 == "x" || $0 == "X" }), let n = Double(v), n.isFinite, let lo = min, let hi = max else { return false }   // no hex: launcher.c's check agrees
            return n >= lo && n <= hi
        case "toggle": return v == onValue || v == offValue
        default: return true
        }
    }
    enum CodingKeys: String, CodingKey { case env, kind, label, note, def = "default", section, needs, level, base, options, min, max, step, on, off, sets }
}
struct SettingsFile: Decodable { let settings: [Setting] }

final class LauncherModel: ObservableObject {
    let settings: [Setting]
    let fixed: Set<String>      // set by an env file or by the launch environment: shown, not changed
    let fromLaunch: Set<String>   // of those, the ones the launch environment set (a front end's launch overrides, Xcode; DM_ENV_LAUNCH_KEYS from launcher.c or main.m)
    let ignoreSaved: Bool   // DM_SAVED_CHOICES=0: start from the defaults, and leave the saved choices as they are
    @Published var values: [String: String] = [:] { didSet { linkFrameGeneration(oldValue) } }
    private var linking = false
    // HookLink X1: frame generation and the frame rate mode are one choice (DM_FRAME_MODE 0 = 60, 1 = steady 30, 2 = 30 + frame generation, 3 = 60 + frame generation). Turning frame
    // generation on or off moves the mode between 60 and 60 + frame generation, or steady 30 and 30 + frame generation; picking a mode sets frame generation to match. Only after init:
    // property observers do not run there, so the saved choices load as they were
    private func linkFrameGeneration(_ old: [String: String]) {
        guard !linking, let fm = settings.first(where: { $0.env == "DM_FRAME_MODE" }), let fg = settings.first(where: { $0.env == "DM_FRAMEGEN" }) else { return }
        linking = true; defer { linking = false }
        let mode = values[fm.env] ?? fm.def, gen = values[fg.env] ?? fg.def
        if gen != (old[fg.env] ?? fg.def) {
            let on = gen == fg.onValue
            let want = on ? (mode == "0" ? "3" : mode == "1" ? "2" : mode) : (mode == "3" ? "0" : mode == "2" ? "1" : mode)
            if want != mode, fm.options?.contains(where: { $0[0] == want }) ?? false { values[fm.env] = want }
        } else if mode != (old[fm.env] ?? fm.def) {
            let want = mode == "2" || mode == "3" ? fg.onValue : fg.offValue
            if gen != want { values[fg.env] = want }
        }
    }

    private let defaults: UserDefaults

    init(_ settings: [Setting], defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.settings = settings
        let env = ProcessInfo.processInfo.environment
        fromLaunch = Set((env["DM_ENV_LAUNCH_KEYS"] ?? "").split(separator: " ").map(String.init))
        fixed = fromLaunch.union((env["DM_ENV_FILE_KEYS"] ?? "").split(separator: " ").map(String.init))
        ignoreSaved = env["DM_SAVED_CHOICES"] == "0"
        if ignoreSaved { fputs("launcher: saved choices ignored (DM_SAVED_CHOICES=0)\n", stderr) }
        for s in settings {
            if fixed.contains(s.env), let v = env[s.env] { values[s.env] = v; continue }
            let saved = ignoreSaved ? nil : defaults.object(forKey: "launcher." + s.env) as? String   // a string, as launcher.c reads it: not string(forKey:), which turns a number into one
            values[s.env] = saved.flatMap { s.accepts($0) ? $0 : nil } ?? s.def   // a saved choice the game no longer offers: its default
        }
        // Frame generation follows the frame rate mode from the start (the mode decides the game's frame generation, main.c dm_frame_mode_apply)
        if let fm = settings.first(where: { $0.env == "DM_FRAME_MODE" }), let fg = settings.first(where: { $0.env == "DM_FRAMEGEN" }), !fixed.contains(fg.env) {
            let mode = values[fm.env] ?? fm.def; values[fg.env] = mode == "2" || mode == "3" ? fg.onValue : fg.offValue
        }
    }

    var sections: [String] {
        settings.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    // A row with "needs" is a sub-setting of the row it names: drawn only while that setting has that value, so a
    // setting that cannot do anything is not offered (an upscaler's detail with the upscaler off, rumble strength
    // with rumble off). A row naming a setting this game does not have stays drawn, as it has nothing to hide behind
    func visible(_ s: Setting) -> Bool {
        guard let n = s.needs, let eq = n.firstIndex(of: "=") else { return true }
        let key = String(n[n.startIndex..<eq]), want = String(n[n.index(after: eq)...])
        guard let v = values[key] else { return true }
        return v == want
    }
    // A row Potato mode sets (its list in the profile, game.tsv potato): locked while Potato mode is on, as the game takes the list's value whatever the row says (loader.c dm_preset_apply)
    func presetLocked(_ s: Setting) -> Bool {
        guard let p = settings.first(where: { $0.env == "DM_PRESET" }), let sets = p.sets, (values[p.env] ?? p.def) == p.onValue else { return false }
        return sets.contains(s.env)
    }
    func rows(in section: String) -> [Setting] { settings.filter { $0.sectionTitle == section && visible($0) } }
    // The Mac window: Basic settings first, then Advanced settings, each in the list's sections and order
    func sections(basic: Bool) -> [String] {
        settings.filter { $0.basic == basic }.reduce(into: []) { if !$0.contains($1.sectionTitle) { $0.append($1.sectionTitle) } }
    }
    func rows(in section: String, basic: Bool) -> [Setting] { rows(in: section).filter { $0.basic == basic } }
    // A range's label: its percentage, with the size in pixels for the chosen console mode when the list has the base size (the render scale)
    func rangeLabel(_ s: Setting, _ v: Double) -> String {
        let p = "\(Int((v * 100).rounded())) %"
        guard let b = s.base else { return p }
        let size = (values["DM_OPMODE"] ?? "1") == "0" ? b.handheld : b.docked
        guard size.count == 2 else { return p }
        return "\(Int((Double(size[0]) * v).rounded())) × \(Int((Double(size[1]) * v).rounded())) (\(p))"
    }
    var changed: Bool { settings.contains { !fixed.contains($0.env) && !$0.isDefault(values[$0.env] ?? $0.def) } }

    // Reset every launcher choice to the game's defaults on the screen; values fixed by an env file or at launch stay. The saved choices are forgotten when Play applies
    // the defaults (apply() keeps no default), so Quit after Reset keeps them, and a choice a launch override hides is kept
    func reset() {
        for s in settings where !fixed.contains(s.env) { values[s.env] = s.def }
        fputs("launcher: settings reset to the game's defaults\n", stderr)
    }

    // Before the game starts: every setting not set by an env file goes into the environment (DM_LANG replaces the packed language main.m set as a default). Only a choice that
    // differs from the game's default is stored: a setting the player left at its default follows the defaults of a later build (the settings it was tested with)
    func apply() {
        for s in settings {
            let v = values[s.env] ?? s.def
            if fixed.contains(s.env) { fputs("launcher: \(s.env) kept at \(v) (\(fromLaunch.contains(s.env) ? "launch environment" : "env file"))\n", stderr); continue }
            store(s, v)
            setenv(s.env, v, 1); fputs("launcher: \(s.env)=\(v)\(s.isDefault(v) ? "" : " (changed)")\n", stderr)
        }
    }
    private func store(_ s: Setting, _ v: String) {
        if !ignoreSaved { if s.isDefault(v) { defaults.removeObject(forKey: "launcher." + s.env) } else { defaults.set(v, forKey: "launcher." + s.env) } }
    }

    // A choice made while the game runs (the iOS in-game menu, GameMenu.swift): saved as Play saves it, so the settings screen shows it at the next start, and put in the environment.
    // A value an env file or the launch fixed stays
    func choose(_ s: Setting, _ v: String) {
        guard !fixed.contains(s.env), s.accepts(v) else { return }
        let before = values
        values[s.env] = v; store(s, v); setenv(s.env, v, 1)
        fputs("launcher: \(s.env)=\(v) (in-game menu)\n", stderr)
        for o in settings where o.env != s.env && !fixed.contains(o.env) {   // what the choice moved with it (frame generation and the frame rate mode: linkFrameGeneration)
            guard let nv = values[o.env], nv != before[o.env] else { continue }
            store(o, nv); setenv(o.env, nv, 1); fputs("launcher: \(o.env)=\(nv) (follows \(s.env))\n", stderr)
        }
    }

    // DM_LAUNCHER=0: no screen, but the saved choices still apply (only DM_SAVED_CHOICES=0 ignores them); nothing is written
    func applySaved() {
        if ignoreSaved { return }   // DM_SAVED_CHOICES=0: nothing of the launcher's goes into the environment, the per-device defaults included (the host's own defaults run)
        for s in settings where !fixed.contains(s.env) {
            let v = values[s.env] ?? s.def
            setenv(s.env, v, 1)   // defaults too: a row's default can differ from the host's own (HookLink's per-device and preset defaults)
            if !s.isDefault(v) { fputs("launcher: \(s.env)=\(v) (saved choice)\n", stderr) }
        }
    }
}
