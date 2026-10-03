// Drop elaboration: destruction becomes a Core IR property. The storage markers the
// lowerer already places at every scope exit (including early returns, break, and continue) ARE the
// lexical drop points; this pass classifies each one against the move/init dataflow -- unconditional,
// flag-guarded, per-field after a partial move, or omitted -- and rewrites the body so each
// elaborated drop is an explicit `Drop(place)` terminator. The borrow pass runs it on every body it
// keeps, over the move facts and dataflow it already built (`flow_ir::bc_elaborate`), so the kept
// body is the elaborated one; emission elaborates only the bodies it lowers itself (per-instance
// re-lowerings and wrappers) and never a body twice (`CoreBody.elaborated`). `verify_drops` is the
// validation build's independent check of an elaborated body.
import ast::ast as *;
import module::loader as loader;
import lexer::token as tok;
import ir::core as ir;
import borrowck::move_paths as mp;
import borrowck::facts as bf;
import borrowck::dataflow as df;
import utils::bits as bits;

/// Drop classifications.
pub const DK_UNCOND: u8 = 0;
pub const DK_COND: u8 = 1; // reachable with differing init states: one flag guards the free
pub const DK_FIELD: u8 = 2; // partial move upstream: this entry drops one still-owned sub-place
pub const DK_OVER: u8 = 3; // assignment overwrites an initialized value: free it first (path = PlaceId)
pub const DK_OVERC: u8 = 4; // overwrite of a maybe-moved value: the local's flag guards the free

pub struct DropAt {
    pub local: u32,
    pub path: u32, // move path (root for whole-value drops)
    pub kind: u8,
    pub stmt: u32, // the storage marker's statement index (body order)
    pub block: u32,
    // DK_FIELD of a member no place names (`path` is the root): its projection's `data` and `sub`
    // (a named field's decl, or the positional index) and its declared type.
    pub fdata: u32,
    pub fsub: NodeId,
    pub fty: TypeId,
}

/// A drop of `local`'s move path `path` at statement `stmt` of `block`.
const fn drop_at(local: u32, path: u32, kind: u8, stmt: u32, block: u32) DropAt {
    return DropAt {
        local: local,
        path: path,
        kind: kind,
        stmt: stmt,
        block: block,
        fdata: 0,
        fsub: NODE_NONE,
        fty: TYPE_NONE,
    };
}

/// A MOVE event of a root local's path (stmt 0xFFFFFFFF = at the block's terminator).
pub struct MoveAt {
    pub local: u32,
    pub stmt: u32,
    pub block: u32,
}

pub struct Schedule {
    pub drops: Vector<DropAt>,
    /// The MOVE events: the rewrite turns them into flag clears so guarded drops test real state.
    pub moves: Vector<MoveAt>,
}

// Overwrite classification of an assignment target: 2 = fully tracked (dataflow decides),
// 1 = the chain's only cuts are REFERENCE derefs (the checker guarantees an initialized
// referent: overwrite frees unconditionally), 0 = raw-pointer or index storage (never
// auto-free: fresh allocations and array literals write through these before values exist).
fn place_over_class(a: &Ast, b: &ir::CoreBody, pl: &ir::Place) u8 {
    let mut cur = b.locals.at(pl.base as usize).ty;
    let mut cls: u8 = 2;
    for i in 0..pl.proj_len {
        let pr = *b.projections.at((pl.proj_start + i) as usize);
        if pr.kind == ir::PJ_DEREF {
            if cur == TYPE_NONE || a.type_at(cur).kind != TypeKind::TYPE_REFERENCE {
                return 0; // raw-pointer storage: unsafe writes never auto-free
            }
            cls = 1;
        } else if pr.kind == ir::PJ_INDEX_CONST || pr.kind == ir::PJ_INDEX_OP {
            if cur == TYPE_NONE || a.type_at(cur).kind == TypeKind::TYPE_POINTER {
                return 0;
            }
            cls = 1; // container/array element: the tracked ancestor's init bit decides
        } else if pr.kind == ir::PJ_DOWNCAST {
            return 0;
        }
        cur = pr.ty;
    }
    return cls;
}

// A tuple member's fdecl is a bare type node (not NODE_FIELD); its move path is keyed positionally.
fn tuple_member_child(ow: &bf::Owner, forest: &mp::MoveForest, root: u32, m: ModuleId, fdecl: NodeId, idx: u32) u32 {
    if fdecl != NODE_NONE && unsafe (&*(&*ow.pkg).module_ast_const(m)).at_const(fdecl).kind != NodeKind::NODE_FIELD {
        return forest.tuple_child(root, idx);
    }
    return forest.field_child(root, fdecl);
}

/// The elaboration's schedule plus every per-body temporary, pooled by the driver: one instance
/// rebuilds in place per body, so elaboration allocates nothing on the steady state.
pub struct ElabCtx {
    pub sched: Schedule,
    pub mi: Vector<u64>,
    pub di: Vector<u64>,
    pub mm: Vector<u64>,
    pub scratch: Vector<u32>,
    pub sub: Vector<u32>,
    // insert_drops scratch (see there).
    pub ins_cond_l: Vector<u32>,
    pub ins_cond_f: Vector<u32>,
    pub ins_clr_at: Vector<u32>,
    pub ins_clr_fl: Vector<u32>,
    pub ins_flag: Vector<u32>,
    pub ins_off: Vector<u32>,
    pub ins_idx: Vector<u32>,
    pub ins_fill: Vector<u32>,
    // The aggregate field lists a partial move's per-field drops enumerate.
    pub fdecls: Vector<NodeId>,
    pub ftys: Vector<TypeId>,
}

extend ElabCtx {
    pub fn empty() ElabCtx {
        return ElabCtx {
            sched: Schedule { drops: Vector::<DropAt>::new(), moves: Vector::<MoveAt>::new() },
            mi: Vector::<u64>::new(),
            di: Vector::<u64>::new(),
            mm: Vector::<u64>::new(),
            scratch: Vector::<u32>::new(),
            sub: Vector::<u32>::new(),
            ins_cond_l: Vector::<u32>::new(),
            ins_cond_f: Vector::<u32>::new(),
            ins_clr_at: Vector::<u32>::new(),
            ins_clr_fl: Vector::<u32>::new(),
            ins_flag: Vector::<u32>::new(),
            ins_off: Vector::<u32>::new(),
            ins_idx: Vector::<u32>::new(),
            ins_fill: Vector::<u32>::new(),
            fdecls: Vector::<NodeId>::new(),
            ftys: Vector::<TypeId>::new(),
        };
    }

    /// Heap bytes the context keeps across bodies (capacity, not length).
    pub const fn scratch_bytes(self: &Self) u64 {
        return (self.sched.drops.capacity() * sizeof(DropAt) + self.sched.moves.capacity() * sizeof(MoveAt) + (self.mi.capacity() + self.di.capacity() + self.mm.capacity()) * 8 + (self.scratch.capacity() + self.sub.capacity() + self.ins_cond_l.capacity() + self.ins_cond_f.capacity() + self.ins_clr_at.capacity() + self.ins_clr_fl.capacity() + self.ins_flag.capacity() + self.ins_off.capacity() + self.ins_idx.capacity() + self.ins_fill.capacity() + self.fdecls.capacity() + self.ftys.capacity()) * 4) as u64;
    }
}

/// Can a store of `b` schedule an overwrite drop: a destination that owns, reached through storage
/// that auto-frees (`place_over_class` 1 or 2; raw-pointer and pointer-element stores never do)?
/// The caller has already answered for the locals' own types, so a whole-local store spelled with
/// the local's type is skipped; the storage class is tested before the ownership oracle, whose
/// answer for a generic type is not memoized.
pub fn assign_may_schedule(ow: &mut bf::Owner, b: &ir::CoreBody) bool {
    let a = unsafe &*(&*ow.pkg).module_ast_const(b.module);
    for si in 0..b.statements.len() {
        let s = b.statements.at(si);
        if s.kind == ir::ST_ASSIGN {
            let pl = *b.places.at(s.place as usize);
            if pl.ty == TYPE_NONE || pl.proj_len == 0 && pl.ty == b.locals.at(pl.base as usize).ty {
                continue;
            }
            if place_over_class(a, b, &pl) != 0 && ow.owns(b.owner, b.module, pl.ty) {
                return true;
            }
        }
    }
    return false;
}

/// Can elaboration schedule any drop for `b`? Every drop frees either a declared owning local at
/// its storage death or the old value of a store whose destination place owns (through a reference
/// too), so a body with neither needs no move facts and no elaboration at all.
pub fn may_schedule(ow: &mut bf::Owner, b: &ir::CoreBody) bool {
    for l in 0..b.locals.len() {
        let ty = b.locals.at(l).ty;
        if ty != TYPE_NONE && ow.owns(b.owner, b.module, ty) {
            return true;
        }
    }
    return assign_may_schedule(ow, b);
}

/// Classify every storage-death point of `b` against the move/init solution.
pub fn elaborate_into(
    ow: &mut bf::Owner,
    b: &ir::CoreBody,
    forest: &mp::MoveForest,
    facts: &bf::BodyFacts,
    fl: &df::MoveFlow,
    cx: &mut ElabCtx,
) {
    cx.sched.drops.truncate(0);
    cx.sched.moves.truncate(0);
    let sched = &mut cx.sched;
    let w = fl.words as usize;
    let mi = &mut cx.mi;
    let di = &mut cx.di;
    let mm = &mut cx.mm;
    let scratch = &mut cx.scratch;
    let sub = &mut cx.sub;
    let fdecls = &mut cx.fdecls;
    let ftys = &mut cx.ftys;
    for bi in 0..b.blocks.len() {
        dv_load(w, bi, &fl.mi, &fl.di, &fl.mm, mi, di, mm);
        let blk = *b.blocks.at(bi);
        let mut ev = facts.ev_start[bi];
        let ev_end = facts.ev_start[bi + 1];
        for si in 0..blk.stmt_len {
            let sx = (blk.stmt_start + si) as usize;
            let s = *b.statements.at(sx);
            let exit = facts.block_base[bi] + si * 2 + 1;
            // Entry-point events (reads, moves) land before this statement's own effect.
            while ev < ev_end && facts.events.at(ev as usize).point < exit {
                let e = *facts.events.at(ev as usize);
                if e.kind() == bf::EV_MOVE || e.kind() == bf::EV_MOVE_CUT {
                    // FIELD moves clear the root local's guard flag too: an overwrite drop of a
                    // conditionally-moved FIELD must not free what the branch moved out
                    sched.moves.push(
                        MoveAt { local: forest.paths.at(e.path() as usize).base, stmt: sx as u32, block: bi as u32 },
                    );
                }
                df::apply_event(forest, &e, scratch, sub, mi, di, mm);
                ev += 1;
            }
            if s.kind == ir::ST_ASSIGN {
                // overwriting an initialized destructible value frees it first (language rule);
                // stores through raw pointers are unsafe storage and never auto-free
                let pl0 = *b.places.at(s.place as usize);
                if pl0.ty != TYPE_NONE && ow.owns(b.owner, b.module, pl0.ty) {
                    let a0 = unsafe &*(&*ow.pkg).module_ast_const(b.module);
                    let cls0 = place_over_class(a0, b, &pl0);
                    if cls0 != 0 {
                        // fully tracked places answer from their own path; cut chains (through a
                        // reference or a container element) answer from the nearest tracked
                        // ancestor -- fresh storage (array literals filling a new local) shows
                        // uninitialized there and schedules nothing
                        let mut dp0 = forest.place_path[s.place as usize];
                        if cls0 == 1 || dp0 == mp::MP_NONE {
                            dp0 = forest.place_cut[s.place as usize];
                        }
                        if dp0 != mp::MP_NONE {
                            if bits::bit_get(di, dp0) && !bits::bit_get(mi, dp0) {
                                sched.drops.push(drop_at(pl0.base, s.place, DK_OVER, sx as u32, bi as u32));
                            } else if bits::bit_get(mi, dp0) && bits::bit_get(di, dp0) {
                                sched.drops.push(drop_at(pl0.base, s.place, DK_OVERC, sx as u32, bi as u32));
                            } else if cls0 == 1 {
                                // A place reached through a REFERENCE deref (cls == 1) names storage
                                // the referent owns: the borrow checker guarantees it holds an
                                // initialized value (a field cannot be moved out through a reference,
                                // an out-of-bounds element traps before the store), so its overwrite
                                // frees the old value. The dataflow bit above tracks LOCAL init and
                                // is not seeded for such a referent -- a spliced-in block boundary
                                // (an inlined call) can leave it clear -- so cls == 1 frees here
                                // regardless, as place_over_class documents.
                                sched.drops.push(drop_at(pl0.base, s.place, DK_OVER, sx as u32, bi as u32));
                            }
                        }
                    }
                }
            }
            if s.kind == ir::ST_STORAGE_DEAD {
                let l = s.a;
                let decl = b.locals.at(l as usize).decl;
                let lty = b.locals.at(l as usize).ty;
                let declared = decl != NODE_NONE || b.locals.at(l as usize).storage == ir::LS_INL;
                if declared && ow.owns(b.owner, b.module, lty) {
                    let root = forest.local_root[l as usize];
                    forest.subtree(root, scratch, sub);
                    let mut all_di = true;
                    let mut any_mi = false;
                    let mut sub_moved = false;
                    for i in 0..sub.len() {
                        if !bits::bit_get(di, sub[i]) {
                            all_di = false;
                        }
                        if bits::bit_get(mi, sub[i]) {
                            any_mi = true;
                        }
                        if sub[i] != root && bits::bit_get(mm, sub[i]) {
                            sub_moved = true;
                        }
                    }
                    let mut fom: ModuleId = 0;
                    if all_di {
                        sched.drops.push(drop_at(l, root, DK_UNCOND, sx as u32, bi as u32));
                    } else if sub_moved && !bits::bit_get(mm, root) && ow.agg_fields(
                        b.module,
                        lty,
                        fdecls,
                        ftys,
                        &mut fom,
                    ) {
                        // Partially moved struct or tuple (never wholly): every still-owned member
                        // drops. A member some place names has a move path of concrete type. A
                        // member no place names is owned by construction and drops through its
                        // declared type, which must be concrete: a destructuring names every
                        // member (the lowering's `mention_members`), since a declared type
                        // parameter says nothing about the instance. A member only partly held
                        // releases its own held parts (`part_drops`).
                        for fi in 0..fdecls.len() {
                            let child = tuple_member_child(ow, forest, root, fom, fdecls[fi], fi as u32);
                            if child != mp::MP_NONE {
                                let _ = part_drops(
                                    ow,
                                    b,
                                    forest,
                                    mi,
                                    di,
                                    l,
                                    child,
                                    sx as u32,
                                    bi as u32,
                                    &mut sched.drops,
                                    scratch,
                                    sub,
                                );
                            } else if ow.ast_of(fom).type_concrete(ftys[fi]) && ow.owns(b.owner, fom, ftys[fi]) {
                                let mut da = drop_at(l, root, DK_FIELD, sx as u32, bi as u32);
                                if ow.ast_of(fom).at_const(fdecls[fi]).kind == NodeKind::NODE_FIELD {
                                    da.fdata = ir::IR_NONE;
                                    da.fsub = fdecls[fi];
                                } else {
                                    da.fdata = fi as u32;
                                }
                                da.fty = ftys[fi];
                                sched.drops.push(da);
                            }
                        }
                    } else if sub_moved && !bits::bit_get(mm, root) && part_drops(
                        ow,
                        b,
                        forest,
                        mi,
                        di,
                        l,
                        root,
                        sx as u32,
                        bi as u32,
                        &mut sched.drops,
                        scratch,
                        sub,
                    ) {
                        // A partially moved enum: the members of the variant it holds drop.
                    } else if bits::bit_get(di, root) || bits::bit_get(mi, root) {
                        // The whole value may or may not still be here: one flag guards it.
                        sched.drops.push(drop_at(l, root, DK_COND, sx as u32, bi as u32));
                    } else if any_mi && member_count(ow, b.module, lty) >= 0 {
                        // A wholly moved struct or tuple with members stored again: those drop.
                        for i in 0..sub.len() {
                            if forest.parent[sub[i] as usize] == root && bits::bit_get(di, sub[i]) && ow.owns(
                                b.owner,
                                b.module,
                                forest.paths.at(sub[i] as usize).ty,
                            ) {
                                sched.drops.push(drop_at(l, sub[i], DK_FIELD, sx as u32, bi as u32));
                            }
                        }
                    }
                }
            }
            while ev < ev_end && facts.events.at(ev as usize).point <= exit {
                let e = *facts.events.at(ev as usize);
                if e.kind() == bf::EV_MOVE || e.kind() == bf::EV_MOVE_CUT {
                    // FIELD moves clear the root local's guard flag too: an overwrite drop of a
                    // conditionally-moved FIELD must not free what the branch moved out
                    sched.moves.push(
                        MoveAt { local: forest.paths.at(e.path() as usize).base, stmt: sx as u32, block: bi as u32 },
                    );
                }
                df::apply_event(forest, &e, scratch, sub, mi, di, mm);
                ev += 1;
            }
        }
        // terminator-point moves (call arguments): the consume lands after the block's statements
        while ev < ev_end {
            let e = *facts.events.at(ev as usize);
            if e.kind() == bf::EV_MOVE || e.kind() == bf::EV_MOVE_CUT {
                sched.moves.push(
                    MoveAt { local: forest.paths.at(e.path() as usize).base, stmt: 0xFFFFFFFFu32, block: bi as u32 },
                );
            }
            ev += 1;
        }
    }
}

// The member count of struct or tuple type `ty` (as `Owner::agg_fields` lists them), or -1 for
// every other shape.
fn member_count(ow: &bf::Owner, mid: ModuleId, ty: TypeId) i64 {
    let y = *ow.ast_of(mid).type_at(ty);
    let mut om: ModuleId = 0;
    let mut od = NODE_NONE;
    if y.kind == TypeKind::TYPE_STRUCT {
        om = y.module;
        od = y.as_data.decl;
    } else if y.kind == TypeKind::TYPE_INSTANCE {
        let it = *ow.ast_of(mid).instance(y.as_data.inst);
        om = it.module;
        od = it.decl;
    } else {
        return 0 - 1;
    }
    let oa = ow.ast_of(om);
    let dn = *oa.at_const(od);
    if dn.kind != NodeKind::NODE_STRUCT || dn.as_data.aggregate.is_union {
        return 0 - 1;
    }
    if dn.as_data.aggregate.is_tuple {
        return dn.as_data.aggregate.members.len;
    }
    let mut n: i64 = 0;
    for i in 0..dn.as_data.aggregate.members.len {
        if oa.at_const(unsafe oa.list(dn.as_data.aggregate.members)[i as usize]).kind == NodeKind::NODE_FIELD {
            n += 1;
        }
    }
    return n;
}

// The payload member count of the variant downcast path `d` names (its key's `sub` is the variant
// declaration, in the module of the enum type's declaration), or -1.
const fn payload_count(ow: &bf::Owner, mid: ModuleId, forest: &mp::MoveForest, d: u32) i64 {
    let y = *ow.ast_of(mid).type_at(forest.paths.at(d as usize).ty);
    let mut om: ModuleId = 0;
    if y.kind == TypeKind::TYPE_ENUM || y.kind == TypeKind::TYPE_STRUCT {
        om = y.module;
    } else if y.kind == TypeKind::TYPE_INSTANCE {
        om = ow.ast_of(mid).instance(y.as_data.inst).module;
    } else {
        return 0 - 1;
    }
    let vn = *ow.ast_of(om).at_const((forest.paths.at(d as usize).elem & 0xFFFFFFFFu64) as NodeId);
    if vn.kind != NodeKind::NODE_VARIANT {
        return 0 - 1;
    }
    return vn.as_data.variant.payload.len;
}

// The number of tracked children of path `p`.
fn child_count(forest: &mp::MoveForest, p: u32) i64 {
    let mut n: i64 = 0;
    let mut c = forest.paths.at(p as usize).first_child;
    while c != mp::MP_NONE {
        n += 1;
        c = forest.paths.at(c as usize).next_sibling;
    }
    return n;
}

// Schedule a DK_FIELD drop, at the storage death (`stmt`, `block`) of local `l`, for every part of
// its path `p` still held. A path held whole drops whole; a struct or tuple releases member by
// member; an enum releases the members of the variant that a definite move below it proves: a
// payload member moves only after its tag test passed, and only a whole store changes the tag,
// which initializes every path below again. Every member of an aggregate released by parts has a
// path (the lowering's `mention_parts`). False, with nothing scheduled for
// `p`, when a part is only maybe held: no flag guards a part.
fn part_drops(
    ow: &mut bf::Owner,
    b: &ir::CoreBody,
    forest: &mp::MoveForest,
    mi: &Vector<u64>,
    di: &Vector<u64>,
    l: u32,
    p: u32,
    stmt: u32,
    block: u32,
    drops: &mut Vector<DropAt>,
    scratch: &mut Vector<u32>,
    sub: &mut Vector<u32>,
) bool {
    forest.subtree(p, scratch, sub);
    let mut all_di = true;
    let mut any_mi = false;
    for i in 0..sub.len() {
        if !bits::bit_get(di, sub[i]) {
            all_di = false;
        }
        if bits::bit_get(mi, sub[i]) {
            any_mi = true;
        }
    }
    if all_di {
        if ow.owns(b.owner, b.module, forest.paths.at(p as usize).ty) {
            drops.push(drop_at(l, p, DK_FIELD, stmt, block));
        }
        return true;
    }
    if !any_mi {
        return true; // moved out whole
    }
    if !bits::bit_get(di, p) {
        return false;
    }
    let mut c = forest.paths.at(p as usize).first_child;
    if c != mp::MP_NONE && (forest.paths.at(c as usize).elem >> 56) as u8 == ir::PJ_DOWNCAST {
        let mut held = mp::MP_NONE;
        while c != mp::MP_NONE {
            forest.subtree(c, scratch, sub);
            let mut proven = false;
            for i in 0..sub.len() {
                if !bits::bit_get(mi, sub[i]) {
                    proven = true;
                }
            }
            if proven {
                if held != mp::MP_NONE {
                    return false;
                }
                held = c;
            }
            c = forest.paths.at(c as usize).next_sibling;
        }
        if held == mp::MP_NONE || payload_count(ow, b.module, forest, held) != child_count(forest, held) {
            return false;
        }
        c = forest.paths.at(held as usize).first_child;
    } else if member_count(ow, b.module, forest.paths.at(p as usize).ty) != child_count(forest, p) {
        return false;
    }
    let mark = drops.len();
    while c != mp::MP_NONE {
        if !part_drops(ow, b, forest, mi, di, l, c, stmt, block, drops, scratch, sub) {
            drops.truncate(mark);
            return false;
        }
        c = forest.paths.at(c as usize).next_sibling;
    }
    return true;
}

// A fresh place of local `l` naming move path `path` (not a root): the path's projection chain,
// rebuilt from the keys (bits 56.. the kind, 32..55 the `data` with 0xFFFFFF for a named field's
// IR_NONE, the low 32 the `sub`).
fn path_place(b: &mut ir::CoreBody, forest: &mp::MoveForest, l: u32, path: u32) ir::Place {
    let mut n: u32 = 0;
    let mut p = path;
    while forest.paths.at(p as usize).parent != mp::MP_NONE {
        n += 1;
        p = forest.paths.at(p as usize).parent;
    }
    let start = b.projections.len() as u32;
    for _i in 0..n {
        b.projections.push(ir::Projection { kind: 0, data: 0, sub: 0, ty: TYPE_NONE });
    }
    p = path;
    for i in 0..n {
        let mp0 = *forest.paths.at(p as usize);
        let mut data = (mp0.elem >> 32 & 0xFFFFFFu64) as u32;
        if data == 0xFFFFFF {
            data = ir::IR_NONE;
        }
        b.projections.set(
            (start + n - 1 - i) as usize,
            ir::Projection {
                kind: (mp0.elem >> 56) as u8,
                data: data,
                sub: (mp0.elem & 0xFFFFFFFFu64) as u32,
                ty: mp0.ty,
            },
        );
        p = mp0.parent;
    }
    return ir::Place { base: l, proj_start: start, proj_len: n, ty: forest.paths.at(path as usize).ty };
}

const NO_FLAG: u32 = 0xFFFFFFFF;

// One `flag = <v>` statement appended to the pool (fresh constant/operand/rvalue/place entries).
fn flag_stmt(b: &mut ir::CoreBody, fl: u32, v: i64, sp: tok::Span) {
    let bt = Ast::builtin(BuiltinType::BT_BOOL);
    b.constants.push(
        ir::Constant { kind: ir::CK_BOOL, ty: bt, val: v, raw: sp, item: DefId { module: 0, node: NODE_NONE } },
    );
    b.operands.push(ir::Operand { kind: ir::OP_CONST, data: b.constants.len() as u32 - 1, ty: bt });
    b.assign_local_use(fl, b.operands.len() as u32 - 1, sp);
}

/// Rewrite `b` so every scheduled whole-value drop is an explicit `Drop(place)` terminator: the
/// marker's block splits there, the drop chains to the remainder, and `args_len` carries the
/// conditional flag. Statement storage is shared -- split parts reference subranges.
pub fn insert_drops(b: &mut ir::CoreBody, cx: &mut ElabCtx, forest: &mp::MoveForest) {
    let nb = b.blocks.len();
    // Scratch rides in the context (capacity survives across bodies); every vector is taken here
    // and handed back at the end, the one exit.
    let mut cond_l = replace(&mut cx.ins_cond_l, Vector::<u32>::new());
    let mut cond_f = replace(&mut cx.ins_cond_f, Vector::<u32>::new());
    let mut clr_at = replace(&mut cx.ins_clr_at, Vector::<u32>::new());
    let mut clr_fl = replace(&mut cx.ins_clr_fl, Vector::<u32>::new());
    let mut flag = replace(&mut cx.ins_flag, Vector::<u32>::new());
    let mut ins_off = replace(&mut cx.ins_off, Vector::<u32>::new());
    let mut ins_idx = replace(&mut cx.ins_idx, Vector::<u32>::new());
    cond_l.truncate(0);
    cond_f.truncate(0);
    clr_at.truncate(0);
    clr_fl.truncate(0);
    // The guard flag local of each original local, NO_FLAG when it has none.
    flag.truncate(0);
    for _i in 0..b.locals.len() {
        flag.push(NO_FLAG);
    }
    let sched = &cx.sched;
    // Conditional drops test a REAL move flag: one bool temp per guarded local, true at entry and
    // at every storage-live, false after every whole-value move; the guarded Drop carries the flag
    // local in `args_start` (args_len 1 is the marker).
    for d in 0..sched.drops.len() {
        let da = *sched.drops.at(d);
        if da.kind != DK_COND && da.kind != DK_OVERC {
            continue;
        }
        if flag[da.local as usize] != NO_FLAG {
            continue;
        }
        cond_l.push(da.local);
        b.locals.push(
            ir::LocalDecl::anon(Ast::builtin(BuiltinType::BT_BOOL), ir::LS_TEMP, b.locals.at(da.local as usize).span),
        );
        cond_f.push(b.locals.len() as u32 - 1);
        flag.set(da.local as usize, b.locals.len() as u32 - 1);
    }
    // Flag clears keyed by ORIGINAL statement index (terminator moves attribute to the block's
    // last statement: the consume happens after it and before the terminator); a move out of a
    // block with no statements keys on `nst + block`.
    let nst = b.statements.len() as u32;
    if cond_l.len() != 0 {
        for mvi in 0..sched.moves.len() {
            let mv = *sched.moves.at(mvi);
            let fl = flag[mv.local as usize];
            if fl == NO_FLAG {
                continue;
            }
            if mv.stmt != 0xFFFFFFFFu32 {
                clr_at.push(mv.stmt);
            } else {
                let ob = *b.blocks.at(mv.block as usize);
                if ob.stmt_len != 0 {
                    clr_at.push(ob.stmt_start + ob.stmt_len - 1);
                } else {
                    clr_at.push(nst + mv.block);
                }
            }
            clr_fl.push(fl);
        }
    }
    // The scheduled whole-value drops per block in schedule order (statement order within a block),
    // as one bucketed index list: `ins_idx[ins_off[bi] .. ins_off[bi + 1]]`.
    ins_off.clear();
    ins_off.resize_default(nb + 1);
    for d in 0..sched.drops.len() {
        let da = sched.drops.at(d);
        ins_off.set(da.block as usize + 1, ins_off[da.block as usize + 1] + 1);
    }
    for bi in 0..nb {
        ins_off.set(bi + 1, ins_off[bi] + ins_off[bi + 1]);
    }
    ins_idx.clear();
    ins_idx.resize_default(ins_off[nb] as usize);
    {
        let mut fill = replace(&mut cx.ins_fill, Vector::<u32>::new());
        fill.truncate(0);
        for bi in 0..nb {
            fill.push(ins_off[bi]);
        }
        for d in 0..sched.drops.len() {
            let da = sched.drops.at(d);
            let k = fill[da.block as usize];
            ins_idx.set(k as usize, d as u32);
            fill.set(da.block as usize, k + 1);
        }
        cx.ins_fill = fill;
    }
    for bi in 0..nb {
        let c0 = ins_off[bi] as usize;
        let c1 = ins_off[bi + 1] as usize;
        if c0 == c1 {
            continue;
        }
        let blk = *b.blocks.at(bi);
        let mut run_start = blk.stmt_start;
        let mut cur = bi as u32;
        for c in c0..c1 {
            let da = *sched.drops.at(ins_idx[c] as usize);
            let cut = da.stmt;
            let kind = da.kind;
            let over = kind == DK_OVER || kind == DK_OVERC;
            // The current part keeps [run_start, cut] (the marker stays; the drop follows it);
            // an OVERWRITE drop splits BEFORE its assignment instead.
            let keep = if over {
                cut - run_start;
            } else {
                cut + 1 - run_start;
            };
            let l = da.local;
            if kind == DK_FIELD {
                // the still-owned part: a member no place names (the path is the root) from its
                // decl, index and type; else the path's projection chain from the root
                let mp0 = *forest.paths.at(da.path as usize);
                if mp0.parent == mp::MP_NONE {
                    b.projections.push(ir::Projection { kind: ir::PJ_FIELD, data: da.fdata, sub: da.fsub, ty: da.fty });
                    b.places.push(
                        ir::Place { base: l, proj_start: b.projections.len() as u32 - 1, proj_len: 1, ty: da.fty },
                    );
                } else {
                    b.places.push(path_place(b, forest, l, da.path));
                }
            } else if !over {
                b.places.push(ir::Place { base: l, proj_start: 0, proj_len: 0, ty: b.locals.at(l as usize).ty });
            }
            let pl = if over {
                da.path;
            } else {
                b.places.len() as u32 - 1;
            };
            let next = b.add_block();
            let sp = b.statements.at(cut as usize).span;
            let mut t = ir::term0(ir::TM_DROP, sp);
            t.a = pl;
            t.t0 = next;
            if kind == DK_COND || kind == DK_OVERC {
                t.args_len = 1;
                t.args_start = flag[l as usize];
            }
            b.blocks[cur as usize].stmt_start = run_start;
            b.blocks[cur as usize].stmt_len = keep;
            b.blocks[cur as usize].term = t;
            b.blocks[cur as usize].sealed = true;
            run_start = if over {
                cut;
            } else {
                cut + 1;
            };
            cur = next;
        }
        // The final part carries the original run tail and terminator.
        b.blocks[cur as usize].stmt_start = run_start;
        b.blocks[cur as usize].stmt_len = blk.stmt_start + blk.stmt_len - run_start;
        b.blocks[cur as usize].term = blk.term;
        b.blocks[cur as usize].sealed = true;
    }
    // Materialize the flag statements: every block's run is re-copied to the pool's end with the
    // inits/retrues/clears spliced in (runs stay contiguous), then the old entries are removed: the
    // emitter's per-local counts read the whole pool.
    if cond_l.len() != 0 {
        // The clears bucketed by key in move order, reusing the drop buckets:
        // `ins_idx[ins_off[k] .. ins_off[k + 1]]` indexes `clr_at`/`clr_fl`.
        let nk = nst as usize + nb;
        ins_off.clear();
        ins_off.resize_default(nk + 1);
        for i in 0..clr_at.len() {
            ins_off.set(clr_at[i] as usize + 1, ins_off[clr_at[i] as usize + 1] + 1);
        }
        for k in 0..nk {
            ins_off.set(k + 1, ins_off[k] + ins_off[k + 1]);
        }
        ins_idx.clear();
        ins_idx.resize_default(clr_at.len());
        let mut fill = replace(&mut cx.ins_fill, Vector::<u32>::new());
        fill.truncate(0);
        for k in 0..nk {
            fill.push(ins_off[k]);
        }
        for i in 0..clr_at.len() {
            let k = fill[clr_at[i] as usize];
            ins_idx.set(k as usize, i as u32);
            fill.set(clr_at[i] as usize, k + 1);
        }
        cx.ins_fill = fill;
        let nb2 = b.blocks.len();
        let old = b.statements.len();
        for bi in 0..nb2 {
            let blk = *b.blocks.at(bi);
            let ns = b.statements.len() as u32;
            if bi as u32 == b.entry {
                for i in 0..cond_f.len() {
                    flag_stmt(b, cond_f[i], 1, b.locals.at(cond_l[i] as usize).span);
                }
            }
            if bi < nb {
                for c in ins_off[nst as usize + bi]..ins_off[nst as usize + bi + 1] {
                    flag_stmt(b, clr_fl[ins_idx[c as usize] as usize], 0, blk.term.span);
                }
            }
            for si in 0..blk.stmt_len {
                let sx = blk.stmt_start + si;
                let st = *b.statements.at(sx as usize);
                b.statements.push(st);
                // a storage-live or a whole-local store re-arms the local's flag
                let mut rl = NO_FLAG;
                if st.kind == ir::ST_STORAGE_LIVE {
                    rl = st.a;
                } else if st.kind == ir::ST_ASSIGN && b.places.at(st.place as usize).proj_len == 0 {
                    rl = b.places.at(st.place as usize).base;
                }
                if rl != NO_FLAG && flag[rl as usize] != NO_FLAG {
                    flag_stmt(b, flag[rl as usize], 1, st.span);
                }
                for c in ins_off[sx as usize]..ins_off[sx as usize + 1] {
                    flag_stmt(b, clr_fl[ins_idx[c as usize] as usize], 0, st.span);
                }
            }
            b.blocks[bi].stmt_start = ns;
            b.blocks[bi].stmt_len = b.statements.len() as u32 - ns;
        }
        let n = b.statements.len();
        for i in old..n {
            let st = *b.statements.at(i);
            b.statements.set(i - old, st);
        }
        b.statements.truncate(n - old);
        for bi in 0..nb2 {
            b.blocks[bi].stmt_start -= old as u32;
        }
    }
    cx.ins_cond_l = cond_l;
    cx.ins_cond_f = cond_f;
    cx.ins_clr_at = clr_at;
    cx.ins_clr_fl = clr_fl;
    cx.ins_flag = flag;
    cx.ins_off = ins_off;
    cx.ins_idx = ins_idx;
}

// The elaborated-body verifier (validation builds). It recomputes the move/init state of every
// move path from the elaborated body's own events (`df::apply_event`, the one transfer function)
// with its own fixpoint, then judges every drop terminator and storage marker against that state:
// no unguarded drop of a value that is not definitely held, no guarded whole-value drop of a
// partially moved value, no storage death or return that leaves a maybe-held value without a drop.
// A marker's drops follow it in a chain of cut blocks, so the chain is judged against the state
// before the marker, releasing path by path.

// True when `row` holds a path of `sub` that `owned` marks (see `dv_owned_paths`).
fn dv_any_owned(row: &Vector<u64>, owned: &Vector<u64>, sub: &Vector<u32>) bool {
    for i in 0..sub.len() {
        if bits::bit_get(row, sub[i]) && bits::bit_get(owned, sub[i]) {
            return true;
        }
    }
    return false;
}

fn dv_all(row: &Vector<u64>, sub: &Vector<u32>) bool {
    for i in 0..sub.len() {
        if !bits::bit_get(row, sub[i]) {
            return false;
        }
    }
    return true;
}

// Release the paths of `sub` in the rows (what a drop does to the state).
fn dv_release(mi: &mut Vector<u64>, di: &mut Vector<u64>, mm: &mut Vector<u64>, sub: &Vector<u32>) {
    for i in 0..sub.len() {
        bits::bit_clear(mi, sub[i]);
        bits::bit_clear(di, sub[i]);
        bits::bit_set(mm, sub[i]);
    }
}

// Judge the drop terminator `t` against the rows, then apply its release to them. The first
// violated rule, or "".
fn dv_check_drop(
    b: &ir::CoreBody,
    forest: &mp::MoveForest,
    t: &ir::Terminator,
    mi: &mut Vector<u64>,
    di: &mut Vector<u64>,
    mm: &mut Vector<u64>,
    scratch: &mut Vector<u32>,
    sub: &mut Vector<u32>,
) str<'static> {
    let pl = *b.places.at(t.a as usize);
    if pl.proj_len == 0 {
        let root = forest.local_root[pl.base as usize];
        forest.subtree(root, scratch, sub);
        if t.args_len == 0 && !dv_all(di, sub) {
            return "drop-of-unowned"; // a second release, or a value not definitely initialized
        }
        if t.args_len == 1 {
            if !bits::bit_get(mi, root) && !bits::bit_get(di, root) {
                return "guarded-drop-of-unowned";
            }
            if !bits::bit_get(mm, root) {
                for i in 0..sub.len() {
                    if sub[i] != root && bits::bit_get(mm, sub[i]) && !bits::bit_get(di, sub[i]) {
                        return "guarded-drop-of-partial"; // the flag would free a moved-out field
                    }
                }
            }
        }
        dv_release(mi, di, mm, sub);
        return "";
    }
    let path = forest.place_path[t.a as usize];
    if path == mp::MP_NONE {
        return ""; // a store through a reference or an element: not this body's tracked storage
    }
    forest.subtree(path, scratch, sub);
    if t.args_len == 0 && !bits::bit_get(di, path) {
        return "field-drop-of-unowned";
    }
    if t.args_len == 1 && !bits::bit_get(mi, path) && !bits::bit_get(di, path) {
        return "guarded-field-drop-of-unowned";
    }
    dv_release(mi, di, mm, sub);
    return "";
}

// A definite move below one variant of an enum path proves the value holds that variant (see
// `part_drops`): the enum and its variant paths then hold nothing beyond that variant's members,
// which are judged as paths of their own. Clears those paths' bits in `mi` for every enum path of
// `sub` with exactly one proven variant.
fn dv_prove_variants(
    forest: &mp::MoveForest,
    sub: &Vector<u32>,
    mi: &mut Vector<u64>,
    scratch: &mut Vector<u32>,
    csub: &mut Vector<u32>,
) {
    for i in 0..sub.len() {
        let e = sub[i];
        let c0 = forest.paths.at(e as usize).first_child;
        if c0 == mp::MP_NONE || (forest.paths.at(c0 as usize).elem >> 56) as u8 != ir::PJ_DOWNCAST {
            continue;
        }
        let mut held = mp::MP_NONE;
        let mut proofs: u32 = 0;
        let mut c = c0;
        while c != mp::MP_NONE {
            forest.subtree(c, scratch, csub);
            for k in 0..csub.len() {
                if !bits::bit_get(mi, csub[k]) {
                    held = c;
                    proofs += 1;
                    break;
                }
            }
            c = forest.paths.at(c as usize).next_sibling;
        }
        if proofs != 1 {
            continue;
        }
        bits::bit_clear(mi, e);
        bits::bit_clear(mi, held);
        c = c0;
        while c != mp::MP_NONE {
            if c != held {
                forest.subtree(c, scratch, csub);
                for k in 0..csub.len() {
                    bits::bit_clear(mi, csub[k]);
                }
            }
            c = forest.paths.at(c as usize).next_sibling;
        }
    }
}

// Copy row `bi` of the three tables into the working rows.
fn dv_load(
    w: usize,
    bi: usize,
    rmi: &Vector<u64>,
    rdi: &Vector<u64>,
    rmm: &Vector<u64>,
    mi: &mut Vector<u64>,
    di: &mut Vector<u64>,
    mm: &mut Vector<u64>,
) {
    mi.clear();
    di.clear();
    mm.clear();
    for k in 0..w {
        mi.push(rmi[bi * w + k]);
        di.push(rdi[bi * w + k]);
        mm.push(rmm[bi * w + k]);
    }
}

// The failing block and local, with the local's init/move events, for the validation build's report.
fn dv_where(ow: &mut bf::Owner, b: &ir::CoreBody, bi: usize, l: u32) {
    eprintln("verify_drops: block bb{} local _{}", bi, l);
    dump_events(ow, b, l);
}

/// Independent check of an elaborated body (validation builds): with the move/init state of
/// every move path recomputed from the body's events, every drop terminator releases a value the
/// path definitely holds (or may hold, through a flag guard), never a partially moved whole, and
/// every storage death and return leaves nothing a declared owning local may still hold. Returns
/// "" or the first violated rule; a violation also prints its block and local, and the local's
/// events, to stderr.
// The paths whose holding needs a release: the type owns memory, and the path is a leaf or a
// value some member of which has no path of its own. A held member that owns nothing (an integer
// beside a moved-out string) needs none, and a struct or tuple whose every member has a path (a
// destructuring names them all, see the lowering's `mention_members`) is released member by
// member.
fn dv_owned_paths(ow: &mut bf::Owner, b: &ir::CoreBody, forest: &mp::MoveForest) Vector<u64> {
    let mut owned = Vector::<u64>::new();
    owned.resize_default((forest.paths.len() + 63) / 64);
    let mut fdecls = Vector::<NodeId>::new();
    let mut ftys = Vector::<TypeId>::new();
    for p in 0..forest.paths.len() {
        let ty = forest.paths.at(p).ty;
        if !ow.owns(b.owner, b.module, ty) {
            continue;
        }
        let mut covered = false;
        let mut fom: ModuleId = 0;
        if !forest.is_leaf(p as u32) && ow.agg_fields(b.module, ty, &mut fdecls, &mut ftys, &mut fom) {
            covered = true;
            for fi in 0..fdecls.len() {
                if tuple_member_child(ow, forest, p as u32, fom, fdecls[fi], fi as u32) == mp::MP_NONE {
                    covered = false;
                }
            }
        }
        if !covered {
            bits::bit_set(&mut owned, p as u32);
        }
    }
    return owned;
}

pub fn verify_drops(ow: &mut bf::Owner, b: &ir::CoreBody) str<'static> {
    let nl = b.locals.len();
    // A closure's captures are argument locals the body never destroys: the env owns them across
    // every call (see `Lowerer::lower_closure_body`).
    let mut cap_lo: u32 = 0xFFFFFFFFu32;
    let mut cap_hi: u32 = 0;
    let oa = unsafe &*(&*ow.pkg).module_ast_const(b.owner.module);
    if b.owner.node != NODE_NONE && oa.at_const(b.owner.node).kind == NodeKind::NODE_CLOSURE {
        cap_lo = b.returns + oa.at_const(b.owner.node).as_data.closure.params.len;
        cap_hi = b.returns + b.args;
    }
    let mut tracked = Vector::<bool>::new();
    for l in 0..nl {
        let ld = *b.locals.at(l);
        let declared = ld.decl != NODE_NONE || ld.storage == ir::LS_INL;
        let cap = l as u32 >= cap_lo && l as u32 < cap_hi;
        tracked.push(
            declared && !cap && l as u32 >= b.returns && ld.ty != TYPE_NONE && ow.owns(b.owner, b.module, ld.ty),
        );
    }
    let mut forest = mp::MoveForest::empty();
    forest.build_into(b);
    let owned = dv_owned_paths(ow, b, &forest);
    let mut facts = bf::BodyFacts::empty();
    ow.generate_into(b, &forest, &mut facts, false);
    let mut cfg = df::Cfg::empty();
    cfg.build_into(b);
    let nb = b.blocks.len();
    let np = forest.paths.len() as u32;
    let mut w = ((np + 63) / 64) as usize;
    if w == 0 {
        w = 1;
    }
    let mut rmi = Vector::<u64>::new();
    let mut rdi = Vector::<u64>::new();
    let mut rmm = Vector::<u64>::new();
    for _i in 0..nb * w {
        rmi.push(0u64);
        rdi.push(0u64);
        rmm.push(0u64);
    }
    let mut scratch = Vector::<u32>::new();
    let mut sub = Vector::<u32>::new();
    let mut csub = Vector::<u32>::new();
    let eb = b.entry as usize * w;
    for l in 0..nl {
        let st = b.locals.at(l).storage;
        if (st == ir::LS_ARG || st == ir::LS_STATIC_REF) && l as u32 >= b.returns {
            forest.subtree(forest.local_root[l], &mut scratch, &mut sub);
            for i in 0..sub.len() {
                let p = sub[i];
                rmi.set(eb + (p / 64) as usize, rmi[eb + (p / 64) as usize] | 1u64 << (p & 63) as u64);
                rdi.set(eb + (p / 64) as usize, rdi[eb + (p / 64) as usize] | 1u64 << (p & 63) as u64);
            }
        }
    }
    let mut reached = Vector::<bool>::new();
    let mut queued = Vector::<bool>::new();
    for _i in 0..nb {
        reached.push(false);
        queued.push(false);
    }
    reached.set(b.entry as usize, true);
    let mut queue = Vector::<u32>::new();
    for i in 0..cfg.rpo.len() {
        queue.push(cfg.rpo[cfg.rpo.len() - 1 - i]);
        queued.set(cfg.rpo[i] as usize, true);
    }
    let mut mi = Vector::<u64>::new();
    let mut di = Vector::<u64>::new();
    let mut mm = Vector::<u64>::new();
    // The fixpoint over the plain event semantics: maybe rows only grow, the definite row only
    // shrinks, so every block re-queues at most once per bit.
    while queue.len() != 0 {
        let bi = queue[queue.len() - 1] as usize;
        let _ = queue.pop();
        queued.set(bi, false);
        dv_load(w, bi, &rmi, &rdi, &rmm, &mut mi, &mut di, &mut mm);
        for e in facts.ev_start[bi]..facts.ev_start[bi + 1] {
            df::apply_event(&forest, facts.events.at(e as usize), &mut scratch, &mut sub, &mut mi, &mut di, &mut mm);
        }
        for si in cfg.succ_start[bi]..cfg.succ_start[bi + 1] {
            let t = cfg.succ[si as usize] as usize;
            let mut changed = false;
            for k in 0..w {
                let mut nmi = mi[k];
                let mut ndi = di[k];
                let mut nmm = mm[k];
                if reached[t] {
                    nmi = nmi | rmi[t * w + k];
                    ndi = ndi & rdi[t * w + k];
                    nmm = nmm | rmm[t * w + k];
                }
                if nmi != rmi[t * w + k] || ndi != rdi[t * w + k] || nmm != rmm[t * w + k] {
                    rmi.set(t * w + k, nmi);
                    rdi.set(t * w + k, ndi);
                    rmm.set(t * w + k, nmm);
                    changed = true;
                }
            }
            if !reached[t] {
                reached.set(t, true);
                changed = true;
            }
            if changed && !queued[t] {
                queued.set(t, true);
                queue.push(t as u32);
            }
        }
    }
    // The judging pass. A marker's drop chain is judged from the marker's block; the chain's own
    // blocks (cut after it, with empty runs) are then skipped as terminators.
    let mut chain = Vector::<bool>::new();
    for _i in 0..nb {
        chain.push(false);
    }
    let mut smi = Vector::<u64>::new();
    let mut sdi = Vector::<u64>::new();
    let mut smm = Vector::<u64>::new();
    for bi in 0..nb {
        if !reached[bi] {
            continue;
        }
        dv_load(w, bi, &rmi, &rdi, &rmm, &mut mi, &mut di, &mut mm);
        let blk = *b.blocks.at(bi);
        let t = blk.term;
        let base = facts.block_base[bi];
        let mut ev = facts.ev_start[bi];
        let ev_end = facts.ev_start[bi + 1];
        for si in 0..blk.stmt_len {
            let exit = base + si * 2 + 1;
            while ev < ev_end && facts.events.at(ev as usize).point < exit {
                df::apply_event(
                    &forest,
                    facts.events.at(ev as usize),
                    &mut scratch,
                    &mut sub,
                    &mut mi,
                    &mut di,
                    &mut mm,
                );
                ev += 1;
            }
            let s = *b.statements.at((blk.stmt_start + si) as usize);
            if s.kind == ir::ST_STORAGE_DEAD && tracked[s.a as usize] {
                let root = forest.local_root[s.a as usize];
                let dropped = si + 1 == blk.stmt_len && t.kind == ir::TM_DROP && b.places.at(t.a as usize).base == s.a;
                if dropped {
                    smi.clear();
                    sdi.clear();
                    smm.clear();
                    for k in 0..w {
                        smi.push(mi[k]);
                        sdi.push(di[k]);
                        smm.push(mm[k]);
                    }
                    let mut cb = bi;
                    let mut n: usize = 0;
                    while n <= nb {
                        n += 1;
                        let ct = b.blocks.at(cb).term;
                        if ct.kind != ir::TM_DROP || b.places.at(ct.a as usize).base != s.a {
                            break;
                        }
                        let r = dv_check_drop(b, &forest, &ct, &mut smi, &mut sdi, &mut smm, &mut scratch, &mut sub);
                        if r.len() != 0 {
                            dv_where(ow, b, cb, s.a);
                            return r;
                        }
                        chain.set(cb, true);
                        cb = ct.t0 as usize;
                        if b.blocks.at(cb).stmt_len != 0 {
                            break;
                        }
                    }
                    forest.subtree(root, &mut scratch, &mut sub);
                    dv_prove_variants(&forest, &sub, &mut smi, &mut scratch, &mut csub);
                    if dv_any_owned(&smi, &owned, &sub) {
                        dv_where(ow, b, bi, s.a);
                        return "dead-with-unreleased-value"; // a maybe-held path the chain never drops
                    }
                } else {
                    forest.subtree(root, &mut scratch, &mut sub);
                    smi.clear();
                    for k in 0..w {
                        smi.push(mi[k]);
                    }
                    dv_prove_variants(&forest, &sub, &mut smi, &mut scratch, &mut csub);
                    if dv_any_owned(&smi, &owned, &sub) {
                        dv_where(ow, b, bi, s.a);
                        return "dead-without-drop";
                    }
                }
            }
            while ev < ev_end && facts.events.at(ev as usize).point <= exit {
                df::apply_event(
                    &forest,
                    facts.events.at(ev as usize),
                    &mut scratch,
                    &mut sub,
                    &mut mi,
                    &mut di,
                    &mut mm,
                );
                ev += 1;
            }
        }
        if t.kind == ir::TM_DROP && !chain[bi] && tracked[b.places.at(t.a as usize).base as usize] {
            // An overwrite drop or a user-written destruction: judged where it stands.
            let r = dv_check_drop(b, &forest, &t, &mut mi, &mut di, &mut mm, &mut scratch, &mut sub);
            if r.len() != 0 {
                dv_where(ow, b, bi, b.places.at(t.a as usize).base);
                return r;
            }
        }
        while ev < ev_end {
            df::apply_event(&forest, facts.events.at(ev as usize), &mut scratch, &mut sub, &mut mi, &mut di, &mut mm);
            ev += 1;
        }
        if t.kind == ir::TM_RETURN {
            for l in 0..nl {
                if !tracked[l] {
                    continue;
                }
                forest.subtree(forest.local_root[l], &mut scratch, &mut sub);
                if dv_any_owned(&mi, &owned, &sub) {
                    dv_where(ow, b, bi, l as u32);
                    return "return-with-live-value";
                }
            }
        }
    }
    return "";
}

// The init/move events of local `l` in `b`, one line each, for a validation report.
fn dump_events(ow: &mut bf::Owner, b: &ir::CoreBody, l: u32) {
    let mut forest = mp::MoveForest::empty();
    forest.build_into(b);
    let mut facts = bf::BodyFacts::empty();
    ow.generate_into(b, &forest, &mut facts, false);
    for e in 0..facts.events.len() {
        let ev = *facts.events.at(e);
        let mp0 = forest.paths.at(ev.path() as usize);
        if mp0.base != l || ev.kind() == bf::EV_USE {
            continue;
        }
        let mut eb: usize = 0;
        while eb + 1 < facts.block_base.len() && facts.block_base[eb + 1] <= ev.point {
            eb += 1;
        }
        eprintln(
            "  event kind {} on path {} (root {}) at point {} in bb{}",
            ev.kind(),
            ev.path(),
            mp0.parent == mp::MP_NONE,
            ev.point,
            eb,
        );
    }
}
