//! Applies a save (format: save.zig) to a freshly created world (game.Game.load).

const std = @import("std");
const state_object = @import("../state.zig").object;
const fields = @import("../fields.zig");
const world_mod = @import("../state.zig").world;
const World = world_mod.World;
const WorldState = @import("../world.zig").saved.WorldState;
const SavedObj = @import("../world.zig").saved.Save.Obj;
const snapshot = @import("../world.zig").snapshot;
const sources = @import("../world.zig").sources;
const start = @import("../world.zig").start;
const walk = @import("../world.zig").walk;
const inventory = @import("../inventory.zig");
const names_classic = @import("../script.zig").classic.names;
const Value = @import("../script.zig").value.Value;

pub fn apply(ws: *const WorldState, w: *World) !void {
    const ra = w.rt.arena();
    w.scene.dropForLoad();
    for (ws.objects) |e| {
        var obj = w.rt.findObject(e.name);
        if (obj == null) {
            if (e.kind == .ambient) continue;
            if (w.block_item != null) {
                // An OpenGorky project: made again from its block (saved.zig writes it).
                const o = try start.recreateBlock(w, e.name, e.class_file, null) orelse {
                    try w.countMissing("class ", e.class_file);
                    continue;
                };
                World.nativeOf(o).kind = e.kind;
                if (e.kind == .actor) try snapshot.created(w, o);
                obj = o;
            } else {
                const cls = w.rt.loadClass(e.class_file) catch blk: {
                    // Class from another location's archive (items picked up there).
                    if (!try sources.addForeignSource(w, e.class_file)) {
                        try w.countMissing("class ", e.class_file);
                        continue;
                    }
                    break :blk w.rt.loadClass(e.class_file) catch |err| {
                        try w.classMissing(e.class_file, err);
                        continue;
                    };
                };
                var nat = state_object.nativeFor(std.fs.path.extension(e.class_file));
                nat.kind = e.kind;
                // A recreated actor (hero who joined elsewhere: MacFadden, Medusa) gets init() as in
                // party transfer; vars then come from the save.
                obj = try snapshot.recreate(w, e.name, cls, nat, e.kind == .actor);
            }
        }
        const o = obj.?;
        const n = World.nativeOf(o);
        // Party membership comes from the save: BT is created as a non-hero on his own
        // location and joins via the meeting scene's SETHERO.
        n.hero = e.hero;
        o.enabled = e.enabled;
        n.deleted = e.deleted;
        n.actor.placed = e.placed;
        n.actor.map = e.map;
        n.actor.state = e.state;
        n.actor.idle_off = e.idle_off;
        // Takes effect at the pickIdle below (the exe restores currentAnimID beside it).
        n.actor.forced_idle = if (e.idle_anim.len == 0) null else try ra.dupe(u8, e.idle_anim);
        n.actor.resetForLoad();
        // Item animation (open/closed box) jumps to its last frame; otherwise the fresh
        // post_init's "closed" would remain.
        if ((e.kind == .item or e.kind == .weapon) and e.anim.len > 0) n.actor.holdLast(try ra.dupe(u8, e.anim), e.anim_reverse);
    }
    // Vars once every object is there: a reference finds one made again further on.
    const lost = lostRenamedFields(ws);
    for (ws.objects) |e| {
        const o = w.rt.findObject(e.name) orelse continue;
        if (lost) try repairLost(w, o, e) else try snapshot.restore(w, o, e.vars, e.skills, e.stat_points);
        // Its components' (an instance its host lacks now, the code changed: its values go).
        try snapshot.restoreComps(&w.rt, w.level_name, o, e.comps, "save");
    }
    // The subscriptions are the save's, in its order (those the objects made as the world
    // was made go, the `game` object's stay: saved.zig); one of an instance not there, or
    // of a method it lacks now, is dropped.
    var kept: usize = 0;
    for (w.rt.subs.items) |sb| if (sb.inst.owner.?.host == null) {
        w.rt.subs.items[kept] = sb;
        kept += 1;
    };
    w.rt.subs.shrinkRetainingCapacity(kept);
    try snapshot.attachSubs(&w.rt, ws.subs, "save");
    // Objects the save lacks: ones scripts made again (Item_New in post_init) are deleted;
    // a script file of the archive newer than the save (a mod's hero, enemy, box) stays
    // as created, as in the exe.
    for (w.rt.objects.items) |o| {
        const n = World.nativeOf(o);
        if (n.kind == .ambient or n.kind == .level or n.from_file) continue;
        const known = for (ws.objects) |e| {
            if (std.ascii.eqlIgnoreCase(e.name, o.name)) break true;
        } else false;
        if (!known) {
            n.deleted = true;
            o.enabled = false;
        }
    }
    restoreAmmoPacks(w);
    // Stance by weapon and mode (old saves had stance 1 outside battle).
    inventory.equipment.refreshHoldStates(w);
    walk.unstickHeroes(w);
    for (w.rt.objects.items) |o| {
        const n = World.nativeOf(o);
        if (n.kind == .actor) n.actor.pickIdle(w.crt());
    }
    // Area walkability (0x47a040): forbids first, then allows.
    for ([_]bool{ false, true }) |allow| for (ws.walk) |wa| if (wa.allow == allow) try walk.setWalkInArea(w, wa.name, allow, wa.floor);
    // The party is the save's.
    try @import("../world.zig").party.syncRoles(w);
}

/// A save the engine wrote after loading one of an engine before the OG Script names
/// without reading the fields the exe spells otherwise (`nameid`, `spritefile`, a weapon's
/// `type`; world/snapshot.zig restoreVars before it knew them): a weapon or item somebody
/// carries has classic_id 0 there ("Nie zdefiniowano", no icon, no mesh). Items always
/// have a name, so one such is the trace.
fn lostRenamedFields(ws: *const WorldState) bool {
    for (ws.objects) |e| {
        if (e.kind != .item and e.kind != .weapon) continue;
        const id = savedVar(e, "classic_id") orelse continue;
        const owner = savedVar(e, "owner") orelse continue;
        if (id == .int and id.int == 0 and owner == .string and owner.string.len > 0) return true;
    }
    return false;
}

/// `restore` for a world with `lostRenamedFields`: every field the engine renamed that the
/// save has at its default (0, "", false) keeps the value the object has before the save's
/// (the level made it, or a weapon or item made again from its class gets its class_init,
/// as Item_New gives it); a hero of the party (the save's hero flag) left out of battles
/// by the lost `avoidEnumerate` is in again.
fn repairLost(w: *World, o: *@import("../script.zig").object.Object, e: SavedObj) !void {
    const n = World.nativeOf(o);
    if ((e.kind == .item or e.kind == .weapon) and o.getInt("classic_id") == 0) _ = try w.rt.callIfExists(o, "class_init", &.{});
    var keep: std.ArrayList(snapshot.VarCopy) = .empty;
    defer keep.deinit(w.gpa);
    for (e.vars) |v| {
        if (!isDefault(v.value) or std.mem.eql(u8, names_classic.classic(o.class.host, v.name), v.name)) continue;
        const cur = o.getVarDyn(v.name) orelse continue;
        if (!isDefault(cur.value)) try keep.append(w.gpa, .{ .name = v.name, .value = cur.value });
    }
    try snapshot.restore(w, o, e.vars, e.skills, e.stat_points);
    for (keep.items) |k| o.getVarDyn(k.name).?.value = k.value;
    if (e.hero and n.kind == .actor and o.getInt("outside_party") == 1) o.setInt("outside_party", 0);
}

fn savedVar(e: SavedObj, name: []const u8) ?Value {
    for (e.vars) |v| if (std.ascii.eqlIgnoreCase(v.name, name)) return v.value;
    return null;
}

fn isDefault(v: Value) bool {
    return switch (v) {
        .int => |x| x == 0,
        .float => |x| x == 0,
        .string => |s| s.len == 0,
        .bool => |b| !b,
        .nil => true,
        else => false,
    };
}

/// Repairs saves made before disabled objects got post_init: a hero who joined on his own
/// location (MacFadden in 02_serwers) lacked ammo packs because the post_init creating them
/// (Item_New(…, 0)) never ran. Giving ammo (0x4b3630) only fills the receiver's pack
/// (0x47d880), so it got "No ammo". In the exe every hero has packs of all kinds (9 per
/// .hro); a missing pack is created empty from another hero's pack class.
fn restoreAmmoPacks(w: *World) void {
    const heroes = w.party();
    const party = heroes.slice();
    for (party) |h| {
        var i: usize = 0;
        while (i < w.rt.objects.items.len) : (i += 1) {
            const p = w.rt.objects.items[i];
            if (!world_mod.isItem(p) or inventory.item.typeOf(p) != .ammo) continue;
            const owner = fields.owner(p);
            const of_party = for (party) |q| {
                if (std.ascii.eqlIgnoreCase(q.name, owner)) break true;
            } else false;
            if (!of_party) continue;
            _ = inventory.ammo.ammoPackOf(w, h, p);
        }
    }
}
