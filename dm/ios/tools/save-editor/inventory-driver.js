// What OOT SW2SE's core expects from a browser and JavaScriptCore alone lacks (the inventory manager runs the core without a page)
var window = { chrome: { webview: { addEventListener() {}, postMessage() {} } } };
class TextEncoder { encode(s) { const u = unescape(encodeURIComponent(String(s))), b = new Uint8Array(u.length); for (let i = 0; i < u.length; i++) b[i] = u.charCodeAt(i); return b; } }
class TextDecoder { decode(b) { let s = ''; for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]); try { return decodeURIComponent(escape(s)); } catch (e) { return s; } } }
class Blob { constructor(parts) { this.parts = parts; } }
//---DRIVER---
// HookLink's inventory manager on OOT SW2SE's core (readSlot, updateSlot and their tables, unchanged): hlOpen reads one slot and describes it, hlApply makes the edited files.
// Every rule and check is the core's; this file only lists what it knows and passes the player's choices on. Bytes travel as plain arrays of numbers.
const hlCatalog = JSON.parse(HL_CATALOG);
const hlEdit = editOptions(hlCatalog);
let hlSlot = null;
function hlOpen(progress, caption) {
  hlSlot = readSlot(Uint8Array.from(progress), Uint8Array.from(caption));
  const s = hlSlot, owned = h => s.p.fields.has(h) && s.p.int(h) === 1;
  return JSON.stringify({
    wallet: s.w.id, wallets: wallets.map(w => ({ id: w.id, label: w.label, limit: w.limit })), rupees: s.rupees,
    vitals: s.vitals, magicStages: magicStages.map(m => ({ max: m.max, label: m.label })),
    supplies: quantityFields.map(i => ({ id: i.id, label: i.label, value: s.counts[i.id], limit: amountLimit(s, i), group: i.group || '', key: !i.group && smallKeys.some(k => k.id === i.id) })),
    capacities: capacityGroups.map(g => ({ id: g.id, label: g.label, value: s.capacities[g.id], tiers: g.tiers.filter(t => tierSelectable(s, g, t)).map(t => t[0]) })),
    bottles: s.bottles.filter(b => b.stock === 1).length, bottleMax: bottleSlots.length,
    bottleContents: s.bottles.filter(b => b.stock === 1).map(b => bottleContents.get(b.content) || 'unknown'),
    items: hlCatalog.inventory.filter(i => s.p.fields.has(i[0])).map(([hash, name, category, editable, label]) => ({
      hash, name, category, label: label || name, owned: owned(hash), raw: s.p.int(hash),
      canAdd: editable && s.p.int(hash) === 0, removeIssue: owned(hash) ? removalIssue(s.p, hash, hlEdit) : 'not owned' })),
  });
}
function hlApply(json) {
  if (!hlSlot) throw Error('No save is open.');
  const c = JSON.parse(json);
  const out = updateSlot(hlSlot, { wallet: c.wallet, rupees: c.rupees, vitals: c.vitals, amounts: c.amounts, upgrades: c.upgrades || {}, bottles: c.bottles,
    additions: c.additions || [], removals: c.removals || [], clearAcquisitions: c.clearAcquisitions || [], flags: new Map() }, hlEdit);
  return JSON.stringify({ progress: Array.from(out[0]), caption: Array.from(out[1]) });
}
