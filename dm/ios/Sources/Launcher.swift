// Launcher: the settings screen shown before the game starts (front_ios.m dm_show_launcher). Its settings come from the app's dm/launcher.json (an app of several programs: dm/p<N>/launcher.json), which build_ipa.sh writes for this game
// from dm/games/settings.tsv (dm/games/settings.py): each sets an environment variable the host reads when the game starts. A variable an env file set (Documents/env.txt, the bundle's
// dm/env.txt; main.m lists them in DM_ENV_FILE_KEYS) is shown but kept. All settings share one screen, grouped by section (rows: LauncherRow.swift). Choices that differ from the game's default are kept
// in UserDefaults; Reset to tested defaults shows the defaults, and Play then forgets them. DM_LAUNCHER=0 in Documents/env.txt starts the game at once with the saved choices; DM_SAVED_CHOICES=0 ignores them (and keeps them)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }


/// Cloud saves: an iCloud Drive folder shared with the Mac app (chosen in its settings window's
/// Cloud saves too). The host brings the save in from there when the game starts and
/// sends it there after each save (dm/host/save_sync.h); the folder is a bookmark (CloudSaves.m).
private struct CloudSavesSection: View {
    @State private var folder: String = ""
    @State private var note: String = ""
    @State private var picking = false

    var body: some View {
        Section {
            HStack {
                Text("Cloud saves")
                Spacer()
                Text(folder.isEmpty ? "Off" : (folder as NSString).lastPathComponent)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Button(folder.isEmpty ? "Choose a folder in iCloud Drive…" : "Choose a different folder…") { picking = true }
                // The sheet sits on the button, not on the Section: SwiftUI hands a Section's modifiers to every row, so one tap presented a picker per row and they invalidated each other (LNPANDY/NX2Apple#315).
                .sheet(isPresented: $picking) {
                    DocumentPicker(types: [.folder]) { url in
                        picking = false
                        if dm_store_cloud_saves(url) {
                            note = "Saved. The game uses this folder when you press Play."
                            refresh()
                        } else {
                            note = "That folder could not be remembered — try a different one."
                        }
                    } onCancel: { picking = false }
                }
            if !folder.isEmpty {
                Button("Turn off cloud saves", role: .destructive) {
                    dm_clear_cloud_saves(); refresh(); note = ""
                }
            }
        } footer: {
            Text(note.isEmpty
                 ? "Choose a folder in iCloud Drive, and the same one in the Mac app's Cloud saves. The save comes in when the game starts and goes out after each save; a save that is replaced is kept in save-backups."
                 : note)
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        var stale: ObjCBool = false
        folder = dm_cloud_saves_path(&stale) ?? ""
        if stale.boolValue && folder.isEmpty {
            note = "The folder you chose before is no longer readable (the app was signed differently). Please choose it again."
        }
    }
}

/// UIDocumentPickerViewController for a folder, in the two callbacks a SwiftUI sheet wants.
private struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType] = [.folder]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // .open (not .import): the folder stays where it is and the bookmark keeps pointing at it.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onCancel: onCancel) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}

// HookLink's launcher: three tabs, Settings, Play (in the middle, shown first) and Extras, laid out as a title bar, a list on the left and a detail panel on the right.
// Play keeps the first launcher's column (the app's icon, its name, its version, Play) on the left and shows how the game will run on the right. Settings lists every
// setting by section; the panel explains the chosen one and holds its control. Extras: saves and the game log through the share sheet, cloud saves, cheat files, reset, credits.
private enum HL {
    static let ground = Color(red: 0.106, green: 0.078, blue: 0.047), bar = Color(red: 0.145, green: 0.106, blue: 0.063), panel = Color(red: 0.055, green: 0.039, blue: 0.024)
    static let line = Color(red: 0.365, green: 0.290, blue: 0.173), trim = Color(red: 0.541, green: 0.439, blue: 0.251), gold = Color(red: 0.788, green: 0.659, blue: 0.353)
    static let text = Color(red: 0.937, green: 0.894, blue: 0.784), dim = Color(red: 0.788, green: 0.722, blue: 0.561), tabOn = Color(red: 0.247, green: 0.192, blue: 0.118)
    // HookLink X1's polish: a cream for names, two quieter golds for notes and labels, the line under quiet rows and the well a slider runs in
    static let cream = Color(red: 1.0, green: 0.965, blue: 0.871), muted = Color(red: 0.659, green: 0.592, blue: 0.478), faint = Color(red: 0.494, green: 0.439, blue: 0.353)
    static let soft = Color(red: 0.725, green: 0.663, blue: 0.537), edge = Color(red: 0.227, green: 0.180, blue: 0.106), well = Color(red: 0.165, green: 0.125, blue: 0.078)
    static func serif(_ size: CGFloat) -> Font { .system(size: size, weight: .bold, design: .serif) }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .rounded) }
}
private enum HLTab: Int, CaseIterable { case settings, play, extras
    var title: String { ["Settings", "Play", "Extras"][rawValue] } }

/// The curled trim under the title bar: two lines that end in a curl at the middle
private struct Trim: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); let m = r.midX, y = r.minY + 2
        p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: m - 86, y: y))
        p.addQuadCurve(to: CGPoint(x: m - 64, y: y + 9), control: CGPoint(x: m - 68, y: y)); p.addQuadCurve(to: CGPoint(x: m - 82, y: y + 11), control: CGPoint(x: m - 74, y: y + 5))
        p.move(to: CGPoint(x: r.maxX, y: y)); p.addLine(to: CGPoint(x: m + 86, y: y))
        p.addQuadCurve(to: CGPoint(x: m + 64, y: y + 9), control: CGPoint(x: m + 68, y: y)); p.addQuadCurve(to: CGPoint(x: m + 82, y: y + 11), control: CGPoint(x: m + 74, y: y + 5))
        return p
    }
}
private struct Divider2: View {
    var body: some View {
        HStack(spacing: 10) { Rectangle().fill(HL.trim).frame(height: 1); Rectangle().fill(HL.gold).frame(width: 7, height: 7).rotationEffect(.degrees(45)); Rectangle().fill(HL.trim).frame(height: 1) }
    }
}
/// Resolution: one dial over the render scale and Cool mode, from kid-with-sword-remake's FF11 Resolution Scale dial, in HookLink's look. Its steps: Coolest (Cool mode: the 3D picture
/// at 50 % and smaller in-between frames), Cool (50 %), Balanced (66.7 %, 1280 × 720 handheld, the default), Sharp (80 %), Sharpest (100 %); a render scale between steps shows at the
/// nearest. Locked while Potato mode or an env file sets the render scale. Without Cool mode in the list it starts at Cool; without a render scale it is not drawn
private struct HLResolutionDial: View {
    @ObservedObject var m: LauncherModel
    let scale: Setting
    private static let steps: [(String, Double)] = [("Coolest", 0.5), ("Cool", 0.5), ("Balanced", 0.667), ("Sharp", 0.8), ("Sharpest", 1.0)]
    private var cool: Setting? { m.settings.first { $0.env == "DM_COOL" } }
    private var dyn: Setting? { m.settings.first { $0.env == "DM_DYNAMIC_RESOLUTION" } }
    // Dynamic resolution on: the game picks the size (loader.c leaves the scale to it), so the dial reads Auto; moving it fixes a size and turns dynamic resolution off
    private var auto: Bool { guard let d = dyn else { return false }; return (m.values[d.env] ?? d.def) == d.onValue && level != 0 }
    private var lo: Int { cool == nil ? 1 : 0 }
    private var locked: Bool { m.fixed.contains(scale.env) || m.presetLocked(scale) }
    private var level: Int {
        if let c = cool, (m.values[c.env] ?? c.def) == c.onValue { return 0 }
        let v = Double(m.values[scale.env] ?? scale.def) ?? 0.667
        return (1...4).min { abs(Self.steps[$0].1 - v) < abs(Self.steps[$1].1 - v) } ?? 2
    }
    private func set(_ l: Int) {
        let l = max(lo, min(4, l)); guard !locked, l != level else { return }
        if let c = cool { m.values[c.env] = l == 0 ? c.onValue : c.offValue }
        if let d = dyn, l != 0 { m.values[d.env] = d.offValue }
        let v = min(max(Self.steps[l].1, scale.min ?? 0), scale.max ?? 1)
        m.values[scale.env] = String(format: "%.2f", v)
        UISelectionFeedbackGenerator().selectionChanged()
    }
    var body: some View {
        VStack(spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("RESOLUTION").font(HL.body(12, .heavy)).tracking(0.7).foregroundStyle(HL.muted)
                Spacer()
                Text(locked ? "Set by Potato mode" : auto ? "Auto" : Self.steps[level].0).font(HL.body(14, .heavy)).foregroundStyle(locked ? HL.gold : HL.cream)
            }
            GeometryReader { g in
                let f = CGFloat(level - lo) / CGFloat(4 - lo), w = g.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(HL.well).frame(height: 6)
                    Capsule().fill(LinearGradient(colors: [Color(red: 0.50, green: 0.71, blue: 0.92), HL.gold], startPoint: .leading, endPoint: .trailing)).frame(width: max(6, w * f), height: 6)
                    ForEach(lo...4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1).fill(HL.line).frame(width: 2, height: 10).offset(x: (w - 2) * CGFloat(i - lo) / CGFloat(4 - lo))
                    }
                    Circle().fill(HL.cream).frame(width: 20, height: 20).overlay(Circle().stroke(HL.gold, lineWidth: 2))
                        .shadow(color: .black.opacity(0.5), radius: 3, y: 2).offset(x: (w - 20) * f)
                }
                .frame(maxHeight: .infinity).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in set(lo + Int((v.location.x / max(w, 1) * CGFloat(4 - lo)).rounded())) })
            }
            .frame(height: 22)
            HStack { ForEach(lo...4, id: \.self) { i in Text(Self.steps[i].0).font(HL.body(10.5, .bold)).foregroundStyle(i == level && !auto ? HL.cream : HL.faint); if i < 4 { Spacer(minLength: 0) } } }
            Text(auto ? "Dynamic resolution picks the size. Move the dial to fix one." : m.rangeLabel(scale, Double(m.values[scale.env] ?? scale.def) ?? 0.667))
                .font(HL.body(11.5, .semibold)).foregroundStyle(HL.muted).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(HL.panel.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HL.line, lineWidth: 1))
        .opacity(locked ? 0.6 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Resolution")
        .accessibilityValue(locked ? "Set by Potato mode" : auto ? "Auto, dynamic resolution" : Self.steps[level].0)
        .accessibilityAdjustableAction { d in set(level + (d == .increment ? 1 : -1)) }
    }
}

/// One row of a list: its name on the left, its value on the right, outlined in gold when chosen
private struct HLRow: View {
    let title: String, value: String, chosen: Bool, action: () -> Void
    var valueColor: Color? = nil
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title).font(HL.body(14, .bold)).foregroundStyle(HL.cream).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Text(value).font(HL.body(12.5, .bold)).foregroundStyle(valueColor ?? (chosen ? HL.gold : HL.muted)).lineLimit(1)
            }
            .padding(.horizontal, 14).frame(minHeight: 44)
            .background(chosen ? AnyShapeStyle(LinearGradient(colors: [HL.tabOn, HL.well], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(HL.ground.opacity(0.6)), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(chosen ? HL.gold : HL.edge, lineWidth: chosen ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
}

/// A quick setting on the Play tab: its name, its state and what it does; lit in gold when on. A setting an env file or Potato mode sets is dimmed and says so
private struct HLTile: View {
    let title: String, state: String, what: String, on: Bool, locked: String?, action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(HL.body(13.5, .heavy)).foregroundStyle(HL.cream).lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 4)
                    Text(locked ?? state).font(HL.body(10.5, .heavy)).foregroundStyle(on ? HL.gold : HL.faint).lineLimit(1)
                }
                Text(what).font(HL.body(11, .medium)).foregroundStyle(HL.soft).lineLimit(3).minimumScaleFactor(0.85).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 9).frame(maxWidth: .infinity, minHeight: 88, maxHeight: 96, alignment: .topLeading)
            .background(on ? AnyShapeStyle(LinearGradient(colors: [HL.tabOn, Color(red: 0.173, green: 0.133, blue: 0.078)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(HL.panel.opacity(0.72)), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? HL.gold : HL.edge, lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .opacity(locked == nil ? 1 : 0.6)
        }.buttonStyle(.plain).disabled(locked != nil)
        .accessibilityElement(children: .combine).accessibilityAddTraits(on ? .isSelected : [])
    }
}
/// A small fact under the quick settings (Light movies on, the touch style, free space)
private struct HLChip: View {
    let text: String
    var body: some View {
        Text(text).font(HL.body(11.5, .bold)).foregroundStyle(HL.dim).padding(.horizontal, 10).padding(.vertical, 5)
            .background(HL.ground, in: Capsule()).overlay(Capsule().stroke(HL.edge, lineWidth: 1))
    }
}
/// A note on the Play tab (the phone is warm, Low Power Mode, little free space)
private struct HLBanner: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 16, weight: .semibold)).foregroundStyle(HL.gold).accessibilityHidden(true)
            Text(text).font(HL.body(12, .semibold)).foregroundStyle(HL.text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(HL.gold.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(HL.gold.opacity(0.35), lineWidth: 1))
    }
}
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
private struct ShareItems: Identifiable { let id = UUID(); let urls: [URL] }
private struct ExtraSheet: Identifiable { let id: String; let title: String }

private let hlCredits = """
HookLink builds on other people's work. Thank you to:

nxnative, the engine: seedds and its contributors.

kid-with-sword and its fork: cheemu21 (the touch controls' inspiration, steady 30 fps, frame generation, the 8 GB memory layout), ednofedulo, ChiefSZ13 (the game's profile and bring-up), Pedro Nascimento (lunks), Xipzer, nanotchec, Adrian Smith, Romen Adama Caetano Ramírez, Travis (travislikestocode), uncraftablexd, mmkzer0, Nimesh Ambepitiya, MetaIX, TheGoldfish11, David Padron-Harris, zatteogit, tut, and the author of the oot2 branch.

Pull requests used: PromethOps (#1455, memory), LeonardoBai12 (#1543, real game speed), vladbondarenko97 (#1460, Wide view).

Fixes and testing: oliverames (game speed below 60 fps, iPhone Duo), Tyuv97G (iPhone 17 Pro), cshess, gunvalk (the frame step finding).

HookShot by NotRexed: the name, and the idea of frame generation.

OOT SW2SE by Traiver and contributors: the save rules behind the Inventory manager (MIT).

Ivan0xFF, via NX2navi: the Wide view HUD and movie sites (MIT).

HookLink is an unofficial fan project, not affiliated with Nintendo. You build the game from your own copy.
"""

private struct LauncherView: View {
    @ObservedObject var m: LauncherModel
    let play: () -> Void
    @State private var memory = os_proc_available_memory()
    @State private var tab: HLTab = .play
    @State private var chosen: String = "DM_FRAME_MODE"
    @State private var extra: String = "saves"
    @State private var section: String = ""   // the Settings tab's section (Game, Controls, Performance)
    @State private var detail: ExtraSheet?     // an Extras card's page (saves, cloud saves, cheats, reset, credits)
    @State private var share: ShareItems?
    @State private var picking = false
    @State private var editing = false   // the Inventory manager (InventoryManager.swift)
    @State private var autoBackupOn = UserDefaults.standard.object(forKey: "hooklink.autobackup") as? Bool ?? true
    @State private var note = ""
    @State private var checking = false
    @State private var check = 0   // which Play the running cloud check is for: one the player went on from without it is dropped
    @State private var report: SaveSyncReport?
    @State private var asking: SaveSyncReport.Step?
    @State private var cheatsOn: Set<String> = Set((UserDefaults.standard.string(forKey: "hooklink.cheats") ?? "").split(separator: "\n").map(String.init))

    private var docs: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    private var version: String { (info("HookLinkVersion") as? String) ?? "X2" }   // no build sets HookLinkVersion: this is the version shown (HookLink X2, the VX2 line); raise it with each HookLink release
    private var playRows: [Setting] {
        let want = ["DM_FRAME_MODE", "DM_RENDER_SCALE", "DM_DYNAMIC_RESOLUTION", "DM_WIDE_VIEW", "DM_PAD_THEME"]
        return want.compactMap { e in m.settings.first { $0.env == e } }
    }
    private func value(_ s: Setting) -> String {
        let v = m.values[s.env] ?? s.def
        switch s.kind {
        case "choice": return s.options?.first { $0[0] == v }?[1] ?? v
        case "range": return m.rangeLabel(s, Double(v) ?? 1)
        default: return v == s.onValue ? "On" : "Off"
        }
    }
    private var storage: String {
        let free = (try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? 0
        return ByteCountFormatter.string(fromByteCount: free, countStyle: .file) + " free"
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Group {
                switch tab {
                case .play: playTab
                case .settings: settingsTab
                case .extras: extrasTab
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(RadialGradient(colors: [Color(red: 0.165, green: 0.122, blue: 0.071), HL.ground, Color(red: 0.071, green: 0.051, blue: 0.027)], center: .init(x: 0.3, y: 0.4), startRadius: 20, endRadius: 700).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(item: $share) { ShareSheet(items: $0.urls) }
        .sheet(item: $detail) { d in
            VStack(spacing: 12) {
                HStack {
                    Text(d.title).font(HL.serif(22)).foregroundStyle(.white)
                    Spacer()
                    Button("Done") { detail = nil }.font(HL.body(15, .heavy)).foregroundStyle(HL.gold)
                }
                Divider2()
                ScrollView { extraDetail }
            }
            .padding(20).background(HL.ground.ignoresSafeArea()).preferredColorScheme(.dark)
        }
        .fullScreenCover(isPresented: $editing) { InventoryManagerView { editing = false } }
        .confirmationDialog(SaveSyncReport.chooseTitle, isPresented: isAsking(.choose), titleVisibility: .visible, presenting: report) { r in
            Button(r.localLabel(here: "iPhone")) { go(r.localChoice) }
            Button(r.cloudLabel) { go(r.cloudChoice) }
            Button("Cancel", role: .cancel) {}
        } message: { r in Text(r.chooseMessage(here: "iPhone")) }
        .confirmationDialog(SaveSyncReport.unreadableTitle, isPresented: isAsking(.unreadable), titleVisibility: .visible, presenting: report) { r in
            Button("Play This iPhone's Save") { go("offline") }
            Button("Try Again") { DispatchQueue.main.async { start() } }
            Button("Cancel", role: .cancel) {}
        } message: { r in Text(r.unreadableMessage(here: "iPhone")) }
        // SwiftUI's own importer: the folder picker as a sheet of the full-screen launcher came up blank on the phone
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder, .zip], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let u = urls.first { importSave(u) }
            case .failure(let e): note = "The picker could not open that: \(e.localizedDescription)"
            }
        }
        .task {
            while !Task.isCancelled { memory = os_proc_available_memory(); try? await Task.sleep(for: .seconds(2)) }
        }
    }

    // The title bar: HookLink's name, the three tabs (the chosen one raised, a gold line on top) and the free memory. Its colour runs to the screen's edges; what it holds stays
    // inside the safe area, clear of the Dynamic Island on either side
    private var titleBar: some View {
        ZStack {
            HStack {
                Text("HookLink \(version)").font(HL.serif(14)).tracking(0.5).foregroundStyle(HL.gold)
                Spacer()
                Text(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory) + " free").font(HL.body(12.5, .bold)).foregroundStyle(HL.muted).monospacedDigit()
            }.padding(.horizontal, 6)
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(HLTab.allCases, id: \.rawValue) { t in
                    Button { tab = t } label: {
                        Text(t.title).font(HL.body(15, .heavy)).foregroundStyle(tab == t ? HL.cream : HL.muted)
                            .padding(.horizontal, tab == t ? 28 : 24).frame(height: 40)
                            .background(tab == t ? AnyShapeStyle(HL.ground) : AnyShapeStyle(Color.clear), in: UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10))
                            .overlay(alignment: .top) { if tab == t { Rectangle().fill(HL.gold).frame(height: 2).padding(.horizontal, 6) } }
                            .overlay(UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10).stroke(tab == t ? HL.trim : Color.clear, lineWidth: 1))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(tab == t ? .isSelected : [])
                }
            }.frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 44)
        .background(LinearGradient(colors: [Color(red: 0.169, green: 0.125, blue: 0.075), Color(red: 0.129, green: 0.094, blue: 0.063)], startPoint: .top, endPoint: .bottom).ignoresSafeArea(edges: [.horizontal, .top]))
        .overlay(Rectangle().fill(HL.line).frame(height: 1).ignoresSafeArea(edges: .horizontal), alignment: .bottom)
    }
    private func panel<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(HL.serif(22)).foregroundStyle(.white)
            content()
        }
        .padding(.horizontal, 20).padding(.vertical, 14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HL.panel.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(HL.line, lineWidth: 1))
    }
    private func label(_ t: String) -> some View { Text(t).font(HL.body(12, .heavy)).tracking(0.7).foregroundStyle(HL.muted) }

    // Play: the game, Play and the Resolution dial in the middle of the left side; on the right, the quick settings, each saying what it does, and the notes
    private var playTab: some View {
        GeometryReader { g in
            HStack(spacing: 18) {
                VStack(spacing: 12) {
                    VStack(spacing: 7) {
                        if let icon = appIcon() {
                            Image(uiImage: icon).resizable().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 17))
                                .overlay(RoundedRectangle(cornerRadius: 17).stroke(HL.gold, lineWidth: 1.5)).shadow(color: .black.opacity(0.55), radius: 7, y: 6).accessibilityHidden(true)
                        }
                        Text((info("CFBundleDisplayName") as? String) ?? "Game").font(HL.serif(19)).foregroundStyle(.white).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.7)
                        Text("Version \((info("CFBundleShortVersionString") as? String) ?? "") · Ready to play").font(HL.body(12, .semibold)).foregroundStyle(HL.muted)
                    }
                    Button(action: { UserDefaults.standard.removeObject(forKey: "dm.stopped.storage"); applyCheats(); autoBackup(); start() }) {
                        HStack(spacing: 10) { Image(systemName: "play.fill").font(.system(size: 17, weight: .heavy)); Text("Play").font(HL.body(22, .heavy)) }
                            .foregroundStyle(HL.ground).frame(maxWidth: .infinity).frame(height: 52)
                            .background(LinearGradient(colors: [Color(red: 0.945, green: 0.824, blue: 0.494), Color(red: 0.851, green: 0.690, blue: 0.310), Color(red: 0.725, green: 0.549, blue: 0.173)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(red: 1, green: 0.945, blue: 0.78), lineWidth: 1))
                            .shadow(color: HL.gold.opacity(0.3), radius: 9, y: 6)
                    }.buttonStyle(.plain).disabled(checking)
                    if checking {
                        HStack(spacing: 6) { ProgressView(); Text("Checking the cloud save…").font(HL.body(13, .medium)).foregroundStyle(HL.dim) }
                        Button("Play without it") { checking = false; go("offline") }.font(HL.body(13, .bold)).foregroundStyle(HL.gold)
                    }
                    if let rs = m.settings.first(where: { $0.env == "DM_RENDER_SCALE" }) { HLResolutionDial(m: m, scale: rs) }
                }
                .frame(width: min(330, g.size.width * 0.38)).frame(maxHeight: .infinity)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) { label("QUICK SETTINGS"); Spacer(); Text("Tap to change").font(HL.body(11, .semibold)).foregroundStyle(HL.faint) }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(quickTiles, id: \.title) { t in t }
                    }
                    ForEach(playNotes, id: \.self) { HLBanner(text: $0) }
                    Spacer(minLength: 0)
                    HStack(spacing: 8) { ForEach(playChips, id: \.self) { HLChip(text: $0) } }.lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.top, 12).padding(.bottom, 10)
        }
    }
    // The quick settings: those this game has, in this order. The frame rate tile switches 60 and 30 and keeps frame generation as it is; frame generation moves the
    // frame rate mode (LauncherModel.linkFrameGeneration)
    private var quickTiles: [HLTile] {
        var out: [HLTile] = []
        func lock(_ s: Setting) -> String? { m.fixed.contains(s.env) ? "Env file" : m.presetLocked(s) ? "Potato" : nil }
        func toggle(_ env: String, _ title: String, _ what: String) {
            guard let s = m.settings.first(where: { $0.env == env }) else { return }
            let on = (m.values[s.env] ?? s.def) == s.onValue
            out.append(HLTile(title: title, state: on ? "ON" : "OFF", what: what, on: on, locked: lock(s)) { m.values[s.env] = on ? s.offValue : s.onValue; UIImpactFeedbackGenerator(style: .light).impactOccurred() })
        }
        if let fm = m.settings.first(where: { $0.env == "DM_FRAME_MODE" }) {
            let v = m.values[fm.env] ?? fm.def
            let state = ["0": "60 fps", "1": "30 steady", "2": "30 + FG", "3": "60 + FG"][v] ?? v
            let what = ["0": "The game at 60, as drawn. Sharp motion, more heat.", "1": "A steady 30 fps. The coolest and most even.",
                        "2": "A steady 30, shown at 60 with in-between frames. Cool and very stable.", "3": "The game at 60, shown at 120 with in-between frames. Smoothest; needs a cool phone."][v] ?? ""
            let next = ["0": "1", "1": "0", "2": "3", "3": "2"][v] ?? v
            out.append(HLTile(title: "Frame rate", state: state, what: what, on: true, locked: lock(fm)) {
                if fm.options?.contains(where: { $0[0] == next }) ?? false { m.values[fm.env] = next; UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            })
        }
        toggle("DM_FRAMEGEN", "Frame generation", "Makes in-between frames, so the picture moves twice as smoothly. Turning it on or off changes the frame rate mode.")
        toggle("DM_COOL", "Cool mode", "Half the 3D resolution and smaller in-between frames: less heat, longer battery.")
        toggle("DM_PRESET", "Potato mode", "The lightest it can run: 25 % resolution and memory savers, for older iPhones.")
        toggle("DM_WIDE_VIEW", "Wide view", "Fills the whole screen with more of the world; the HUD stays in the middle.")
        toggle("DM_MIC", "Ocarina mic", "Play the ocarina by humming or whistling the notes.")
        return out
    }
    private var playNotes: [String] {
        var n: [String] = []
        // The disk guard stopped the last game (hle_svc.c guest_file_thread, exit 87), which looks like a crash to the player: why, until the next Play. Space iOS can purge does
        // not count there, so lowDisk (which counts it) can stay quiet on a phone the guard stops
        if let gb = UserDefaults.standard.object(forKey: "dm.stopped.storage") as? Double {
            n.append(String(format: "The game closed last time because the iPhone had only %.1f GB really free. It keeps up to about 10 GB of its memory on the phone. Settings can show more free space than that, as it counts caches iOS clears only later: restarting the iPhone clears them, or delete or offload something big, then play.", gb))
        } else if lowDisk { n.append("Less than 25 GB free: the game keeps up to about 10 GB of memory on the disk, and it stops when space runs out. Free some space first.") }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { n.append("Low Power Mode is on: iOS slows the phone, and the game will drop frames. Turn it off in Settings \u{2192} Battery.") }
        switch ProcessInfo.processInfo.thermalState.rawValue {
        case 2...: n.append("The phone is hot: the game will run slower until it cools. A short break helps.")
        case 1: n.append("The phone is warm. 30 fps + frame generation runs steadier until it cools.")
        default: break
        }
        return n
    }
    private var playChips: [String] {
        var c: [String] = []
        if let s = m.settings.first(where: { $0.env == "DM_NDVE_LITE" }) { c.append("Light movies " + ((m.values[s.env] ?? s.def) == s.onValue ? "on" : "off")) }
        if let s = m.settings.first(where: { $0.env == "DM_PAD_THEME" }) { c.append("Touch: " + value(s)) }
        c.append(storage + " on the phone")
        return c
    }

    // Settings: the sections as tabs over the list on the left; the chosen setting's explanation and control on the right
    private var settingsTab: some View {
        let current = m.sections.contains(section) ? section : (m.sections.first ?? "")
        return GeometryReader { g in
            HStack(spacing: 16) {
                VStack(spacing: 8) {
                    HStack(spacing: 0) {
                        ForEach(m.sections, id: \.self) { sec in
                            Button { section = sec; if let f = m.rows(in: sec).first { chosen = f.env } } label: {
                                Text(sec).font(HL.body(13, .heavy)).foregroundStyle(sec == current ? HL.ground : HL.muted).frame(maxWidth: .infinity).frame(height: 32)
                                    .background(sec == current ? AnyShapeStyle(LinearGradient(colors: [Color(red: 0.914, green: 0.776, blue: 0.416), Color(red: 0.773, green: 0.604, blue: 0.204)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 7))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityAddTraits(sec == current ? .isSelected : [])
                        }
                    }
                    .padding(3).background(HL.panel, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(HL.edge, lineWidth: 1))
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(m.rows(in: current)) { s in
                                HLRow(title: s.label, value: m.presetLocked(s) ? "Potato mode" : value(s), chosen: chosen == s.env, action: { chosen = s.env }, valueColor: m.presetLocked(s) ? HL.gold : nil)
                            }
                        }
                    }
                }
                .frame(width: min(370, g.size.width * 0.44))
                if let s = m.settings.first(where: { $0.env == chosen }) ?? m.settings.first {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) { Text(s.label).font(HL.serif(22)).foregroundStyle(.white); Spacer(); label(s.sectionTitle.uppercased()) }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                let byPreset = m.presetLocked(s), locked = m.fixed.contains(s.env) || byPreset
                                if !s.note.isEmpty { Text(s.note).font(HL.body(13, .medium)).foregroundStyle(HL.text).lineSpacing(2).fixedSize(horizontal: false, vertical: true) }
                                if locked { Text(byPreset && !m.fixed.contains(s.env) ? "Set by Potato mode" : m.fromLaunch.contains(s.env) ? "Set at launch" : "Set by an env file").font(HL.body(13, .bold)).foregroundStyle(HL.gold) }
                                control(s).disabled(locked).opacity(locked ? 0.5 : 1)
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(HL.panel.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(HL.line, lineWidth: 1))
                }
            }
            .padding(.top, 12).padding(.bottom, 10)
        }
    }
    @ViewBuilder private func control(_ s: Setting) -> some View {
        switch s.kind {
        case "choice":
            VStack(spacing: 5) {
                ForEach(s.options ?? [], id: \.[0]) { o in
                    HLRow(title: o[1], value: (m.values[s.env] ?? s.def) == o[0] ? "Selected" : "", chosen: (m.values[s.env] ?? s.def) == o[0]) { m.values[s.env] = o[0] }
                }
            }
        case "range":
            let b = Binding<Double>(get: { Double(m.values[s.env] ?? s.def) ?? s.max ?? 1 }, set: { m.values[s.env] = String(format: "%.2f", $0) })
            VStack(alignment: .leading, spacing: 6) {
                Text(m.rangeLabel(s, b.wrappedValue)).font(HL.body(19, .heavy)).foregroundStyle(HL.cream).monospacedDigit()
                Slider(value: b, in: (s.min ?? 0)...(s.max ?? 1), step: s.step ?? 0.05).tint(HL.gold).accessibilityLabel(s.label)
                HStack { Text(m.rangeLabel(s, s.min ?? 0)).lineLimit(1); Spacer(); Text(m.rangeLabel(s, s.max ?? 1)).lineLimit(1) }.font(HL.body(10.5, .bold)).foregroundStyle(HL.faint).minimumScaleFactor(0.7)
            }
            .padding(14).background(HL.ground, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(HL.edge, lineWidth: 1))
        default:
            let on = Binding<Bool>(get: { (m.values[s.env] ?? s.def) == s.onValue }, set: { m.values[s.env] = $0 ? s.onValue : s.offValue })
            Toggle(isOn: on) { Text(on.wrappedValue ? "On" : "Off").font(HL.body(15, .heavy)).foregroundStyle(on.wrappedValue ? HL.gold : HL.muted) }
                .tint(HL.gold).padding(.horizontal, 14).frame(minHeight: 48)
                .background(HL.ground, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(HL.edge, lineWidth: 1))
                .accessibilityLabel(s.label)
        }
    }

    // Extras: cards that say what each does. Inventory manager, Import and the game log act at once; the others open their page
    private var extrasTab: some View {
        let cheats = cheatNames()
        let saves: [(String, String, String, String)] = [("editor", "Inventory manager", "Rupees, hearts, items, bottles and more, by OOT SW2SE. A backup is made first.", ""),
                                                         ("saves", "Export saves", "Share your save folder, and back saves up at each start.", autoBackupOn ? "Backups on" : ""),
                                                         ("import", "Import a save", "Replace the saves with a folder. Yours move to save-backups first.", ""),
                                                         ("cloud", "Cloud saves", "Keep the save in step with the Mac app through iCloud Drive.", "")]
        let more: [(String, String, String, String)] = [("log", "Export game log", "The last session's log, to share when reporting a problem.", ""),
                                                        ("cheats", "Cheats", "Turn on cheats from the files in the cheats folder.", cheats.isEmpty ? "No file" : "\(cheatsOn.intersection(cheats).count) on"),
                                                        ("reset", "Reset to tested defaults", "Every setting back to how HookLink \(version) was tested.", m.changed ? "" : "Nothing changed"),
                                                        ("credits", "Credits", "Everyone whose work is in this build.", "")]
        func card(_ c: (String, String, String, String)) -> some View {
            Button { openExtra(c.0, c.1) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) { Text(c.1).font(HL.body(13.5, .heavy)).foregroundStyle(HL.cream).lineLimit(1).minimumScaleFactor(0.8); Spacer(minLength: 4); Text(c.3).font(HL.body(10.5, .heavy)).foregroundStyle(HL.faint).lineLimit(1) }
                    Text(c.2).font(HL.body(11, .medium)).foregroundStyle(HL.soft).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, minHeight: 88, maxHeight: 96, alignment: .topLeading)
                .background(c.0 == "editor" ? AnyShapeStyle(LinearGradient(colors: [HL.tabOn, Color(red: 0.173, green: 0.133, blue: 0.078)], startPoint: .top, endPoint: .bottom)) : AnyShapeStyle(HL.panel.opacity(0.72)), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(c.0 == "editor" ? HL.gold : HL.edge, lineWidth: c.0 == "editor" ? 1.5 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
        }
        let cols = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return VStack(alignment: .leading, spacing: 10) {
            label("SAVES")
            LazyVGrid(columns: cols, spacing: 8) { ForEach(saves, id: \.0) { card($0) } }
            label("MORE").padding(.top, 4)
            LazyVGrid(columns: cols, spacing: 8) { ForEach(more, id: \.0) { card($0) } }
            if !note.isEmpty { Text(note).font(HL.body(13, .bold)).foregroundStyle(HL.gold) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.vertical, 10)
    }
    private func openExtra(_ id: String, _ title: String) {
        note = ""; extra = id
        switch id {
        case "editor": editing = true
        case "import": picking = true
        case "log": exportLog()
        default: detail = ExtraSheet(id: id, title: title)
        }
    }
    private func words(_ t: String) -> some View { Text(t).font(HL.body(13, .medium)).foregroundStyle(HL.text).multilineTextAlignment(.center).frame(maxWidth: .infinity) }
    @ViewBuilder private var extraDetail: some View {
        VStack(spacing: 8) {
            switch extra {
            case "saves":
                words("Sends a copy of your save folder to Files, AirDrop or another app. Your saves stay on the phone.")
                HLRow(title: "Export saves", value: "", chosen: true) { exportSaves() }
                words("HookLink can also copy your saves to save-backups each time you press Play, when they changed. The five newest copies are kept.")
                HLRow(title: "Back up saves at each start", value: autoBackupOn ? "On" : "Off", chosen: autoBackupOn) { autoBackupOn.toggle(); UserDefaults.standard.set(autoBackupOn, forKey: "hooklink.autobackup") }
            case "import":
                words("Replaces the game's saves with a save folder you choose (one with account.sav and slot folders, or a folder holding a \"save\" folder). The saves you have now are copied to save-backups first.")
                HLRow(title: "Choose a save folder", value: "", chosen: true) { picking = true }
            case "log":
                words("Sends the log of your last game session (HookLink-last-game-session.txt), and of this launch. Share both when something looked or ran wrong in the game.")
                HLRow(title: "Export game log", value: "", chosen: true) { exportLog() }
            case "cloud":
                List { CloudSavesSection() }.listStyle(.insetGrouped).scrollContentBackground(.hidden).frame(height: 230)
            case "editor":
                words("Change rupees, hearts, magic, ammo, bag sizes, small keys, bottles and items in your saves. Your saves are copied to save-backups before every change. The save rules are OOT SW2SE's, by Traiver.")
                HLRow(title: "Open the inventory manager", value: "", chosen: true) { editing = true }
            case "cheats":
                let names = cheatNames()
                if names.isEmpty {
                    words("No cheat file found. Put an Atmosphère cheat file for this game (a .txt of [Name] entries) in the app's cheats folder in Files, then come back. HookLink ships none.")
                } else {
                    words("Cheats from your file. They change the running game and can break a save: export your saves first.")
                    ForEach(names, id: \.self) { n in
                        HLRow(title: n, value: cheatsOn.contains(n) ? "On" : "Off", chosen: cheatsOn.contains(n)) {
                            if cheatsOn.contains(n) { cheatsOn.remove(n) } else { cheatsOn.insert(n) }
                            UserDefaults.standard.set(cheatsOn.sorted().joined(separator: "\n"), forKey: "hooklink.cheats")
                        }
                    }
                }
            case "reset":
                words("Brings back all settings this game was tested with.")
                HLRow(title: "Reset to tested defaults", value: "", chosen: m.changed) { m.reset(); note = "Settings are back to the tested defaults." }.disabled(!m.changed)
            default:
                Text(hlCredits).font(HL.body(13, .medium)).foregroundStyle(HL.text).frame(maxWidth: .infinity, alignment: .leading)
            }
            if !note.isEmpty { Text(note).font(HL.body(13, .bold)).foregroundStyle(HL.gold).multilineTextAlignment(.center) }
        }
    }

    private func exportSaves() {
        let save = docs.appendingPathComponent("save")
        guard let n = try? FileManager.default.contentsOfDirectory(atPath: save.path), !n.isEmpty else { note = "There are no saves yet."; return }
        share = ShareItems(urls: [save])
    }
    // The launcher runs before the game: log.txt is this launch, which has not played yet, and the session played last is log.prev.txt. Bug reports on the Discord
    // attached log.txt alone, a few lines that stop at the launcher. The two go out as copies whose names say which is which, the played session first
    private func exportLog() {
        let fm = FileManager.default, out = fm.temporaryDirectory.appendingPathComponent("hooklink-logs", isDirectory: true)
        try? fm.removeItem(at: out); try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (name, copy) in [("log.prev.txt", "HookLink-last-game-session.txt"), ("log.txt", "HookLink-this-launch.txt")] {
            let src = docs.appendingPathComponent(name), dst = out.appendingPathComponent(copy)
            if fm.fileExists(atPath: src.path), (try? fm.copyItem(at: src, to: dst)) != nil { urls.append(dst) }
        }
        if urls.isEmpty { note = "There is no log yet. Play once first." } else { share = ShareItems(urls: urls) }
    }
    // The chosen folder becomes Documents/save: it must hold a save (account.sav or a slot folder), and the saves there now go to save-backups first
    private func importSave(_ url: URL) {
        let fm = FileManager.default, scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "zip" { note = "Unzip it in Files first (tap the .zip), then choose the folder it makes."; return }
        // the folder itself, or a save folder inside it (an exported "save" folder, or a backup folder that holds one)
        var src = url
        if let names = try? fm.contentsOfDirectory(atPath: url.path), !names.contains(where: { $0 == "account.sav" || $0.hasPrefix("slot_") }),
           let inner = ["save", "save.work"].map({ url.appendingPathComponent($0) }).first(where: { (try? fm.contentsOfDirectory(atPath: $0.path))?.contains(where: { $0 == "account.sav" || $0.hasPrefix("slot_") }) == true }) { src = inner }
        guard let names = try? fm.contentsOfDirectory(atPath: src.path), names.contains(where: { $0 == "account.sav" || $0.hasPrefix("slot_") }) else { note = "That folder has no save in it (no account.sav or slot folder)."; return }
        let save = docs.appendingPathComponent("save"), f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        do {
            if let old = try? fm.contentsOfDirectory(atPath: save.path), !old.isEmpty {
                let back = docs.appendingPathComponent("save-backups"); try fm.createDirectory(at: back, withIntermediateDirectories: true)
                try fm.moveItem(at: save, to: back.appendingPathComponent(f.string(from: Date()) + " before import"))
            } else { try? fm.removeItem(at: save) }
            try fm.copyItem(at: src, to: save)
            try? fm.removeItem(at: docs.appendingPathComponent("save.work"))
            note = "Imported. The saves you had are in save-backups."
        } catch { note = "The import failed: \(error.localizedDescription)" }
    }
    // The [Name] entries of the cheat files in Documents/cheats (the engine's cheats folder, main.m DM_CHEATS)
    private func cheatNames() -> [String] {
        let dir = docs.appendingPathComponent("cheats"); var out: [String] = []
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        for case let f as URL in e where f.pathExtension == "txt" {
            guard let t = try? String(contentsOf: f, encoding: .utf8) else { continue }
            for l in t.split(separator: "\n") { let s = l.trimmingCharacters(in: .whitespaces); if s.hasPrefix("[") && s.hasSuffix("]") && s.count > 2 { let n = String(s.dropFirst().dropLast()); if !out.contains(n) { out.append(n) } } }
        }
        return out
    }
    /// The cheats turned on here, for the engine (DM_CHEATS_ON, hle_cheats.c): called by Play
    func applyCheats() {
        let on = cheatsOn.intersection(cheatNames()).sorted()
        if !on.isEmpty { setenv("DM_CHEATS_ON", on.joined(separator: ","), 1); fputs("launcher: cheats on: \(on.joined(separator: ", "))\n", stderr) }
    }

    private func appIcon() -> UIImage? {
        if let i = UIImage(named: "AppIcon") { return i }
        guard let icons = info("CFBundleIcons") as? [String: Any], let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String], let last = files.last else { return nil }
        return UIImage(named: last)
    }
    /// Under 25 GB free: the guest's memory files grow to about 10 GB and the disk guard stops the game near the end (Tyuv97G, HookLink issue 3)
    private var lowDisk: Bool {
        let free = (try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? Int64.max
        return free < 25_000_000_000
    }

    // Play, once the cloud's save is compared with this iPhone's (upstream's save_sync_report, SaveSyncReport): a save that changed on both sides is the player's pick
    private func isAsking(_ step: SaveSyncReport.Step) -> Binding<Bool> {
        Binding(get: { asking == step }, set: { if !$0 && asking == step { asking = nil } })
    }
    // A copy of the save folder in save-backups/auto-<time> before the game starts, when a save changed since the newest such copy; the five newest are kept
    private func autoBackup() {
        guard autoBackupOn else { return }
        let fm = FileManager.default, save = docs.appendingPathComponent("save"), dir = docs.appendingPathComponent("save-backups")
        func newest(_ u: URL) -> Date {
            var d = Date.distantPast
            if let e = fm.enumerator(at: u, includingPropertiesForKeys: [.contentModificationDateKey]) { for case let f as URL in e { if let m = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, m > d { d = m } } }
            return d
        }
        guard let n = try? fm.contentsOfDirectory(atPath: save.path), !n.isEmpty else { return }
        let autos = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("auto-") }.sorted()
        if let last = autos.last, newest(dir.appendingPathComponent(last)) >= newest(save) { return }   // nothing saved since
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
        let name = "auto-" + f.string(from: Date())
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: save, to: dir.appendingPathComponent(name))
            for old in (autos + [name]).sorted().dropLast(5) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
            fputs("launcher: saves copied to save-backups/\(name)\n", stderr)
        } catch { fputs("launcher: save backup failed: \(error.localizedDescription)\n", stderr) }
    }
    private func start() {
        check += 1; checking = true; asking = nil
        let mine = check
        dm_cloud_saves_env()
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.compare()
            DispatchQueue.main.async {
                guard checking, check == mine else { return }
                checking = false
                switch SaveSyncReport.step(r) {
                case .play(let choice): go(choice)
                case let step: report = r; asking = step
                }
            }
        }
    }
    private static func compare() -> SaveSyncReport? {
        guard let save = getenv("DM_SAVE") else { fputs("launcher: save sync: no DM_SAVE\n", stderr); return nil }
        var buf = [CChar](repeating: 0, count: 1024)
        guard save_sync_report(save, dm_save_title(), nil, SaveSyncReport.waitMs, &buf, buf.count) == 0 else {
            fputs("launcher: save sync: no report on \(String(cString: save))\n", stderr); return nil
        }
        let line = String(cString: buf)
        fputs("launcher: save sync: \(line)\n", stderr)
        return SaveSyncReport(line: line)
    }
    private func go(_ choice: String?) {
        asking = nil
        if let choice { setenv("DM_SAVE_SYNC_CHOICE", choice, 1); fputs("launcher: DM_SAVE_SYNC_CHOICE=\(choice)\n", stderr) }
        play()
    }
}

// This phone's own starting values and the choices it cannot make (from kid-with-sword-remake's FF11 deviceSetup, HookLink VX1):
// - under 10 GB of memory, Cool mode starts on (a phone with less memory is the one that heats and runs out first)
// - on a GPU without Metal 4 MetalFX frame interpolation, as the game found it at its last start (nvn_mtl.m fg_on keeps dm.framegen.unsupported), the frame generation rows leave and the
//   frame rate mode offers no frame generation. The launcher can't ask the GPU itself: a Metal device made here comes before MTL_HUD_ENABLED and kept the Performance HUD off (GitHub issue #840)
func deviceAdjusted(_ list: [Setting]) -> [Setting] {
    let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    let noFG = UserDefaults.standard.bool(forKey: "dm.framegen.unsupported")
    if noFG { fputs("launcher: frame generation unavailable (the last start found no Metal 4 MetalFX frame interpolator)\n", stderr) }
    var out: [Setting] = []
    for var s in list {
        if noFG && ["DM_FRAMEGEN", "DM_FRAMEGEN_SCALE", "DM_FRAMEGEN_MV"].contains(s.env) { continue }
        if noFG && s.env == "DM_FRAME_MODE", let o = s.options {
            s.options = o.filter { !$0[1].localizedCaseInsensitiveContains("frame generation") }
            if !(s.options ?? []).contains(where: { $0[0] == s.def }) { s.def = s.options?.first?[0] ?? s.def }
        }
        if gb < 10 && s.env == "DM_COOL" {
            s.def = s.onValue; s.note += (s.note.isEmpty ? "" : " ") + "On by default on this iPhone (\(String(format: "%.0f", gb)) GB of memory)."
            fputs(String(format: "launcher: this phone has %.1f GB of memory: Cool mode on by default\n", gb), stderr)
        }
        out.append(s)
    }
    return out
}

// Shows the launcher over the root view controller and calls done once the settings are in the environment; false (done is not called) when there is no launcher
@_cdecl("dm_show_launcher")
public func dmShowLauncher(_ viewController: UnsafeMutableRawPointer, _ done: @convention(c) () -> Void) -> Bool {
    // a game of several programs (main.m): the running program's settings, in its dm/p<N>
    let dir = getenv("DM_APP_DM").map { URL(fileURLWithPath: String(cString: $0)) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm")
    guard let url = dir?.appendingPathComponent("launcher.json"), let data = try? Data(contentsOf: url) else { return false }
    guard let file = try? JSONDecoder().decode(SettingsFile.self, from: data), !file.settings.isEmpty else { fputs("[RED] launcher: dm/launcher.json cannot be read; starting the game\n", stderr); return false }
    let model = LauncherModel(deviceAdjusted(file.settings))
    gameMenuModel = model   // the in-game menu shows and saves the same choices (GameMenu.swift)
    if ProcessInfo.processInfo.environment["DM_LAUNCHER"] == "0" { fputs("launcher: off (DM_LAUNCHER=0)\n", stderr); model.applySaved(); return false }
    let parent = Unmanaged<UIViewController>.fromOpaque(viewController).takeUnretainedValue()
    var host: UIViewController?
    let view = LauncherView(m: model) {
        guard let h = host else { return }
        host = nil
        model.apply()
        h.dismiss(animated: false) { done() }
    }
    let h = DmHostingController(rootView: view)
    h.modalPresentationStyle = .fullScreen
    host = h
    parent.present(h, animated: false)
    fputs("launcher: \(file.settings.count) settings shown\n", stderr)
    return true
}
