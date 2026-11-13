// The launcher's Inventory manager (Extras): a native editor for the game's saves. The save format's rules are OOT SW2SE's (Traiver and contributors, MIT): its core
// (readSlot, updateSlot and their tables, from Gen/dm/save-editor.html unchanged) runs in JavaScriptCore with no page, behind a small driver (inventory-driver.js:
// hlOpen describes a slot, hlApply makes the edited files). Every limit and consistency check is the core's own; this file is the screens and the file handling:
// the game's saves are read from Documents/save, and a change is written there only after the player confirms, with the whole save folder copied to save-backups first.
import SwiftUI
import JavaScriptCore

struct InvError: LocalizedError { let message: String; var errorDescription: String? { message } }

final class InventoryCore {
    private let ctx: JSContext
    private var thrown: String?
    init() throws {
        guard let c = JSContext() else { throw InvError(message: "JavaScriptCore is not available.") }
        ctx = c
        let dir = getenv("DM_APP_DM").map { URL(fileURLWithPath: String(cString: $0)) } ?? Bundle.main.resourceURL?.appendingPathComponent("dm")
        guard let d = dir, let html = try? String(contentsOf: d.appendingPathComponent("save-editor.html"), encoding: .utf8),
              let drv = try? String(contentsOf: d.appendingPathComponent("inventory-driver.js"), encoding: .utf8) else { throw InvError(message: "The inventory manager's files are missing from this build.") }
        func between(_ a: String, _ b: String, in s: String) -> String? {
            guard let r1 = s.range(of: a), let r2 = s.range(of: b, range: r1.upperBound..<s.endIndex) else { return nil }
            return String(s[r1.upperBound..<r2.lowerBound])
        }
        guard let catalog = between("<script id=\"catalog\" type=\"application/json\">", "</script>", in: html),
              let coreStart = html.range(of: "<script>", range: (html.range(of: "</script>")?.upperBound ?? html.startIndex)..<html.endIndex),
              let coreEnd = html.range(of: "</script>", range: coreStart.upperBound..<html.endIndex) else { throw InvError(message: "The save editor's core could not be read.") }
        let core = String(html[coreStart.upperBound..<coreEnd.lowerBound])
        let parts = drv.components(separatedBy: "//---DRIVER---")
        guard parts.count == 2 else { throw InvError(message: "The inventory driver could not be read.") }
        ctx.exceptionHandler = { [weak self] _, e in self?.thrown = e?.toString() ?? "unknown error" }
        ctx.evaluateScript(parts[0])
        ctx.setObject(catalog, forKeyedSubscript: "HL_CATALOG" as NSString)
        ctx.evaluateScript(core + "\n" + parts[1])
        if let t = thrown { throw InvError(message: "The save editor's core did not load: \(t)") }
    }
    private func call(_ name: String, _ args: [Any]) throws -> String {
        thrown = nil
        let v = ctx.objectForKeyedSubscript(name)?.call(withArguments: args)
        if let t = thrown { throw InvError(message: t.replacingOccurrences(of: "Error: ", with: "")) }
        guard let s = v?.toString(), v?.isString == true else { throw InvError(message: "The save editor gave no answer.") }
        return s
    }
    func open(progress: Data, caption: Data) throws -> [String: Any] {
        let s = try call("hlOpen", [progress.map { Int($0) }, caption.map { Int($0) }])
        guard let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] else { throw InvError(message: "The save could not be described.") }
        return o
    }
    func apply(_ changes: [String: Any]) throws -> (progress: Data, caption: Data) {
        let json = String(data: try JSONSerialization.data(withJSONObject: changes), encoding: .utf8) ?? "{}"
        let s = try call("hlApply", [json])
        guard let o = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any], let p = o["progress"] as? [Int], let c = o["caption"] as? [Int]
        else { throw InvError(message: "The edited save could not be read back.") }
        return (Data(p.map { UInt8(truncatingIfNeeded: $0) }), Data(c.map { UInt8(truncatingIfNeeded: $0) }))
    }
}

struct InvSupply: Identifiable { let id, label, group: String; let value, limit: Int; let key: Bool }
struct InvCapacity: Identifiable { let id, label: String; let value: Int; let tiers: [Int] }
struct InvItem: Identifiable { let hash: Int; let name, category, label: String; let owned, canAdd: Bool; let removeIssue: String; var id: Int { hash } }
struct InvWallet: Identifiable { let id, label: String; let limit: Int }
struct InvStage: Identifiable { let max: Int; let label: String; var id: Int { max } }

final class InventoryModel: ObservableObject {
    @Published var slots: [String] = []          // slot_00 ... that hold a save
    @Published var slot = ""
    @Published var loaded = false
    @Published var message = ""                  // the last result or the core's refusal
    @Published var failed = false
    // What the save holds (from hlOpen)
    @Published var wallets: [InvWallet] = []; @Published var stages: [InvStage] = []
    @Published var supplies: [InvSupply] = []; @Published var capacities: [InvCapacity] = []; @Published var items: [InvItem] = []
    @Published var bottleMax = 0; @Published var bottleContents: [String] = []
    private var was: [String: Any] = [:]
    // The player's choices
    @Published var wallet = ""; @Published var rupees = 0
    @Published var hearts = 3.0; @Published var maxHearts = 3; @Published var magic = 0.0; @Published var maxMagic = 0
    @Published var amounts: [String: Int] = [:]; @Published var upgrades: [String: Int] = [:]
    @Published var bottles = 0
    @Published var additions: Set<Int> = []; @Published var removals: Set<Int> = []

    private var core: InventoryCore?
    let saves: URL, backups: URL
    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        saves = docs.appendingPathComponent("save"); backups = docs.appendingPathComponent("save-backups")
        do { core = try InventoryCore() } catch { message = error.localizedDescription; failed = true }
        let fm = FileManager.default
        slots = (0..<6).map { String(format: "slot_%02d", $0) }.filter { fm.fileExists(atPath: saves.appendingPathComponent($0).appendingPathComponent("progress.sav").path) &&
                                                                         fm.fileExists(atPath: saves.appendingPathComponent($0).appendingPathComponent("caption.sav").path) }
        if let first = slots.first { load(first) } else if !failed { message = "There are no saves yet. Play once and save, then come back." }
    }
    static func title(_ slot: String) -> String { "File " + String((Int(slot.suffix(2)) ?? 0) + 1) }
    var walletLimit: Int { wallets.first { $0.id == wallet }?.limit ?? 200 }
    func limit(_ s: InvSupply) -> Int { if !s.group.isEmpty, let u = upgrades[s.group] { return u }; return s.limit }
    var changed: Bool {
        guard loaded else { return false }
        let v = was["vitals"] as? [String: Any] ?? [:]
        return wallet != was["wallet"] as? String || rupees != was["rupees"] as? Int || hearts != (v["hearts"] as? NSNumber)?.doubleValue || maxHearts != (v["maxHearts"] as? NSNumber)?.intValue ||
               magic != (v["magic"] as? NSNumber)?.doubleValue || maxMagic != (v["maxMagic"] as? NSNumber)?.intValue || bottles != was["bottles"] as? Int || !upgrades.isEmpty ||
               !additions.isEmpty || !removals.isEmpty || supplies.contains { amounts[$0.id] != $0.value }
    }

    func load(_ name: String) {
        guard let core else { return }
        loaded = false; slot = name
        do {
            let dir = saves.appendingPathComponent(name)
            let o = try core.open(progress: try Data(contentsOf: dir.appendingPathComponent("progress.sav")), caption: try Data(contentsOf: dir.appendingPathComponent("caption.sav")))
            was = o
            func i(_ a: Any?) -> Int { (a as? NSNumber)?.intValue ?? 0 }
            func s(_ a: Any?) -> String { a as? String ?? "" }
            wallets = (o["wallets"] as? [[String: Any]] ?? []).map { InvWallet(id: s($0["id"]), label: s($0["label"]), limit: i($0["limit"])) }
            stages = (o["magicStages"] as? [[String: Any]] ?? []).map { InvStage(max: i($0["max"]), label: s($0["label"])) }
            supplies = (o["supplies"] as? [[String: Any]] ?? []).map { InvSupply(id: s($0["id"]), label: s($0["label"]), group: s($0["group"]), value: i($0["value"]), limit: i($0["limit"]), key: ($0["key"] as? Bool) ?? false) }
            capacities = (o["capacities"] as? [[String: Any]] ?? []).map { InvCapacity(id: s($0["id"]), label: s($0["label"]), value: i($0["value"]), tiers: ($0["tiers"] as? [NSNumber] ?? []).map(\.intValue)) }
            items = (o["items"] as? [[String: Any]] ?? []).map { InvItem(hash: i($0["hash"]), name: s($0["name"]), category: s($0["category"]), label: s($0["label"]), owned: ($0["owned"] as? Bool) ?? false,
                                                                         canAdd: ($0["canAdd"] as? Bool) ?? false, removeIssue: s($0["removeIssue"])) }
            bottleMax = i(o["bottleMax"]); bottleContents = o["bottleContents"] as? [String] ?? []
            let v = o["vitals"] as? [String: Any] ?? [:]
            wallet = s(o["wallet"]); rupees = i(o["rupees"]); bottles = i(o["bottles"])
            hearts = (v["hearts"] as? NSNumber)?.doubleValue ?? 3; maxHearts = i(v["maxHearts"]); magic = (v["magic"] as? NSNumber)?.doubleValue ?? 0; maxMagic = i(v["maxMagic"])
            amounts = Dictionary(uniqueKeysWithValues: supplies.map { ($0.id, $0.value) }); upgrades = [:]; additions = []; removals = []
            loaded = true; failed = false
            if message.hasPrefix("Could not") || message.hasPrefix("There are") { message = "" }
        } catch { message = "Could not open \(Self.title(name)): \(error.localizedDescription)"; failed = true }
    }
    func revert() { let m = message; load(slot); message = m.hasPrefix("Saved") ? "" : "Changes undone." ; failed = false }

    // The edited files from the core, then the save folder copied to save-backups/inventory-<time>, then the two files written in place (atomically)
    func save() {
        guard let core, loaded else { return }
        do {
            let changes: [String: Any] = ["wallet": wallet, "rupees": rupees, "vitals": ["hearts": hearts, "maxHearts": maxHearts, "magic": magic, "maxMagic": maxMagic],
                                          "amounts": amounts, "upgrades": upgrades, "bottles": bottles, "additions": Array(additions), "removals": Array(removals)]
            let out = try core.apply(changes)
            let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; f.locale = Locale(identifier: "en_US_POSIX")
            let backup = backups.appendingPathComponent("inventory-" + f.string(from: Date()))
            try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: saves, to: backup)
            let dir = saves.appendingPathComponent(slot)
            try out.progress.write(to: dir.appendingPathComponent("progress.sav"), options: .atomic)
            try out.caption.write(to: dir.appendingPathComponent("caption.sav"), options: .atomic)
            fputs("launcher: inventory manager wrote \(slot); the saves before it are in save-backups/\(backup.lastPathComponent)\n", stderr)
            load(slot); message = "Saved to \(Self.title(slot)). The save as it was is in save-backups/\(backup.lastPathComponent)."; failed = false
        } catch { message = error.localizedDescription; failed = true }
    }
}

private enum IV {
    static let ground = Color(red: 0.106, green: 0.078, blue: 0.047), panel = Color(red: 0.055, green: 0.039, blue: 0.024), line = Color(red: 0.42, green: 0.34, blue: 0.2)
    static let text = Color(red: 0.937, green: 0.894, blue: 0.784), dim = Color(red: 0.788, green: 0.722, blue: 0.561), gold = Color(red: 0.86, green: 0.69, blue: 0.29)
    static func font(_ size: CGFloat, _ w: Font.Weight = .semibold) -> Font { .system(size: size, weight: w, design: .rounded) }
}
private struct IVButton: View {
    let title: String; var strong = false; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(IV.font(13, .bold)).foregroundStyle(strong ? Color.black : IV.text).padding(.horizontal, 12).frame(minWidth: 40, minHeight: 34)
                .background(strong ? IV.gold : Color.white.opacity(0.08)).overlay(RoundedRectangle(cornerRadius: 4).stroke(strong ? IV.gold : IV.line, lineWidth: 1)).clipShape(RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain)
    }
}
// A number with − and +, its limit beside it, and Max
private struct IVNumber: View {
    let label: String; let value: Int; let range: ClosedRange<Int>; var note = ""; let set: (Int) -> Void
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(IV.font(14, .bold)).foregroundStyle(IV.text).lineLimit(1)
                if !note.isEmpty { Text(note).font(IV.font(11, .medium)).foregroundStyle(IV.dim).lineLimit(1) }
            }
            Spacer(minLength: 6)
            IVButton(title: "−") { set(max(range.lowerBound, value - 1)) }.disabled(value <= range.lowerBound)
            Text("\(value) / \(range.upperBound)").font(IV.font(14, .bold)).monospacedDigit().foregroundStyle(IV.text).frame(minWidth: 84)
            IVButton(title: "+") { set(min(range.upperBound, value + 1)) }.disabled(value >= range.upperBound)
            IVButton(title: "Max") { set(range.upperBound) }.disabled(value >= range.upperBound)
        }.padding(.horizontal, 12).frame(minHeight: 46).background(Color.white.opacity(0.045)).overlay(RoundedRectangle(cornerRadius: 4).stroke(IV.line, lineWidth: 1))
    }
}

struct InventoryManagerView: View {
    @StateObject private var m = InventoryModel()
    @State private var tab = "Stats"
    @State private var confirming = false
    @State private var advanced = false
    @State private var filter = "Owned"
    let done: () -> Void
    private let tabs = ["Stats", "Supplies", "Upgrades", "Keys", "Bottles", "Items"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Inventory manager").font(IV.font(17, .heavy)).foregroundStyle(IV.text)
                if m.slots.count > 0 {
                    Menu {
                        ForEach(m.slots, id: \.self) { s in Button(InventoryModel.title(s)) { m.load(s) } }
                    } label: { Text(InventoryModel.title(m.slot) + " ▾").font(IV.font(14, .bold)).foregroundStyle(IV.gold).padding(.horizontal, 10).frame(minHeight: 34).overlay(RoundedRectangle(cornerRadius: 4).stroke(IV.line, lineWidth: 1)) }
                }
                Spacer()
                IVButton(title: "Undo changes") { m.revert() }.disabled(!m.changed)
                IVButton(title: "Save changes", strong: true) { confirming = true }.disabled(!m.changed).opacity(m.changed ? 1 : 0.45)
                IVButton(title: "Done", action: done)
            }.padding(.horizontal, 16).padding(.vertical, 8).background(IV.panel)
            if !m.message.isEmpty {
                Text(m.message).font(IV.font(12, .bold)).foregroundStyle(m.failed ? Color(red: 1, green: 0.55, blue: 0.45) : IV.gold).multilineTextAlignment(.center)
                    .padding(.horizontal, 16).padding(.vertical, 6).frame(maxWidth: .infinity).background(Color.black.opacity(0.35))
            }
            if m.loaded {
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(tabs, id: \.self) { t in
                                Button { tab = t } label: {
                                    Text(t).font(IV.font(14, .bold)).foregroundStyle(IV.text).frame(maxWidth: .infinity, minHeight: 42)
                                        .background(Color.white.opacity(tab == t ? 0.13 : 0.045)).overlay(RoundedRectangle(cornerRadius: 4).stroke(tab == t ? Color.white : IV.line, lineWidth: tab == t ? 2 : 1))
                                }.buttonStyle(.plain)
                            }
                            Button { advanced = true } label: { Text("Quest flags (advanced)").font(IV.font(12, .bold)).foregroundStyle(IV.dim).frame(maxWidth: .infinity, minHeight: 38) }.buttonStyle(.plain)
                        }.padding(10)
                    }.frame(width: 190)
                    ScrollView { VStack(spacing: 6) { page }.padding(12) }.frame(maxWidth: .infinity).background(IV.panel)
                }
            } else { Spacer() }
            Text("Save rules by OOT SW2SE (Traiver and contributors, MIT). Changes can break a save: your saves are copied to save-backups before every change.")
                .font(IV.font(10, .medium)).foregroundStyle(IV.dim).padding(5).frame(maxWidth: .infinity).background(IV.panel)
        }
        .background(IV.ground.ignoresSafeArea()).preferredColorScheme(.dark)
        .alert("Save these changes to \(InventoryModel.title(m.slot))?", isPresented: $confirming) {
            Button("Save", role: .destructive) { m.save() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your saves as they are now are copied to save-backups first.") }
        .fullScreenCover(isPresented: $advanced) { SaveEditorView { advanced = false; m.load(m.slot) } }
    }

    @ViewBuilder private var page: some View {
        switch tab {
        case "Stats":
            HStack(spacing: 8) {
                Text("Wallet").font(IV.font(14, .bold)).foregroundStyle(IV.text); Spacer()
                ForEach(m.wallets) { w in IVButton(title: "\(w.label) (\(w.limit))", strong: m.wallet == w.id) { m.wallet = w.id; m.rupees = min(m.rupees, w.limit) } }
            }.padding(.horizontal, 12).frame(minHeight: 46).background(Color.white.opacity(0.045)).overlay(RoundedRectangle(cornerRadius: 4).stroke(IV.line, lineWidth: 1))
            IVNumber(label: "Rupees", value: m.rupees, range: 0...m.walletLimit) { m.rupees = $0 }
            HStack { Spacer(); IVButton(title: "−10") { m.rupees = max(0, m.rupees - 10) }; IVButton(title: "+10") { m.rupees = min(m.walletLimit, m.rupees + 10) }; IVButton(title: "+100") { m.rupees = min(m.walletLimit, m.rupees + 100) } }
            IVNumber(label: "Heart containers", value: m.maxHearts, range: 3...20, note: "Lowering them also lowers your hearts") { m.maxHearts = $0; m.hearts = min(m.hearts, Double($0)) }
            IVNumber(label: "Hearts", value: Int(m.hearts.rounded(.down)), range: 0...m.maxHearts, note: m.hearts != m.hearts.rounded(.down) ? "Now \(m.hearts): whole hearts are set here" : "") { m.hearts = Double($0) }
            HStack(spacing: 8) {
                Text("Magic meter").font(IV.font(14, .bold)).foregroundStyle(IV.text); Spacer()
                ForEach(m.stages) { s in IVButton(title: s.max == 0 ? "None" : "\(s.max) MP", strong: m.maxMagic == s.max) { m.maxMagic = s.max; m.magic = min(m.magic, Double(s.max)) } }
            }.padding(.horizontal, 12).frame(minHeight: 46).background(Color.white.opacity(0.045)).overlay(RoundedRectangle(cornerRadius: 4).stroke(IV.line, lineWidth: 1))
            if m.maxMagic > 0 { IVNumber(label: "Magic", value: Int(m.magic.rounded(.down)), range: 0...m.maxMagic) { m.magic = Double($0) } }
        case "Supplies":
            ForEach(m.supplies.filter { !$0.key }) { s in
                IVNumber(label: s.label, value: min(m.amounts[s.id] ?? s.value, m.limit(s)), range: 0...max(m.limit(s), 0), note: s.group.isEmpty ? "" : "Raising it past your bag picks the bag that holds it") { m.amounts[s.id] = $0 }
            }
        case "Upgrades":
            ForEach(m.capacities) { c in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.label).font(IV.font(14, .bold)).foregroundStyle(IV.text)
                        Text(c.value == 0 ? "Not owned" : "Holds \(c.value) now").font(IV.font(11, .medium)).foregroundStyle(IV.dim)
                    }
                    Spacer()
                    IVButton(title: "Keep", strong: m.upgrades[c.id] == nil) { m.upgrades[c.id] = nil }
                    ForEach(c.tiers, id: \.self) { t in IVButton(title: "\(t)", strong: m.upgrades[c.id] == t) { m.upgrades[c.id] = t; for s in m.supplies where s.group == c.id { m.amounts[s.id] = min(m.amounts[s.id] ?? 0, t) } } }
                }.padding(.horizontal, 12).frame(minHeight: 46).background(Color.white.opacity(0.045)).overlay(RoundedRectangle(cornerRadius: 4).stroke(IV.line, lineWidth: 1))
            }
        case "Keys":
            ForEach(m.supplies.filter { $0.key }) { s in IVNumber(label: s.label, value: m.amounts[s.id] ?? s.value, range: 0...max(s.limit, 0), note: "Small keys") { m.amounts[s.id] = $0 } }
        case "Bottles":
            IVNumber(label: "Bottles", value: m.bottles, range: 0...m.bottleMax, note: "New bottles start empty; removing one takes the last") { m.bottles = $0 }
            ForEach(Array(m.bottleContents.enumerated()), id: \.offset) { i, c in
                Text("Bottle \(i + 1): \(c)").font(IV.font(13, .medium)).foregroundStyle(IV.dim).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12)
            }
        default:
            HStack(spacing: 8) { ForEach(["Owned", "Can add", "All"], id: \.self) { f in IVButton(title: f, strong: filter == f) { filter = f } }; Spacer() }
            let shown = m.items.filter { filter == "All" || (filter == "Owned" ? ($0.owned || m.additions.contains($0.hash)) : $0.canAdd) }
            if shown.isEmpty { Text("Nothing here.").font(IV.font(13, .medium)).foregroundStyle(IV.dim).padding(20) }
            ForEach(shown) { it in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(it.label).font(IV.font(14, .bold)).foregroundStyle(IV.text).lineLimit(1)
                        Text(m.removals.contains(it.hash) ? "Will be removed" : m.additions.contains(it.hash) ? "Will be added" : it.owned ? "Owned · \(it.category)" : it.category)
                            .font(IV.font(11, .medium)).foregroundStyle(m.removals.contains(it.hash) || m.additions.contains(it.hash) ? IV.gold : IV.dim).lineLimit(1)
                    }
                    Spacer()
                    if it.canAdd { IVButton(title: m.additions.contains(it.hash) ? "Don't add" : "Add", strong: m.additions.contains(it.hash)) { if !m.additions.insert(it.hash).inserted { m.additions.remove(it.hash) } } }
                    else if it.owned && it.removeIssue.isEmpty { IVButton(title: m.removals.contains(it.hash) ? "Keep" : "Remove", strong: m.removals.contains(it.hash)) { if !m.removals.insert(it.hash).inserted { m.removals.remove(it.hash) } } }
                    else if it.owned { Text(it.removeIssue.contains("Unequip") ? "Unequip it in the game to remove it" : "Cannot be removed here").font(IV.font(11, .medium)).foregroundStyle(IV.dim) }
                }.padding(.horizontal, 12).frame(minHeight: 46).background(Color.white.opacity(0.045)).overlay(RoundedRectangle(cornerRadius: 4).stroke(IV.line, lineWidth: 1))
            }
        }
    }
}
