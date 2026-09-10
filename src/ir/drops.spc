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
    pub fdecl: NodeId, // DK_FIELD: the dropped field's decl (NODE_NONE when not a field drop)
}

pub struct Schedule {
    pub drops: Vector<DropAt>,
    /// Whole-root MOVE events (kind unused; stmt 0xFFFFFFFF = at the block's terminator): the
    /// rewrite turns them into flag clears so guarded drops test real state.
    pub moves: Vector<DropAt>,
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

/// Classify every storage-death point of `b` against the move/init solution.
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
    pub ins_clr_blk: Vector<u32>,
    pub ins_clr_blk_fl: Vector<u32>,
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
            sched: Schedule { drops: Vector::<DropAt>::new(), moves: Vector::<DropAt>::new() },
            mi: Vector::<u64>::new(),
            di: Vector::<u64>::new(),
            mm: Vector::<u64>::new(),
            scratch: Vector::<u32>::new(),
            sub: Vector::<u32>::new(),
            ins_cond_l: Vector::<u32>::new(),
            ins_cond_f: Vector::<u32>::new(),
            ins_clr_at: Vector::<u32>::new(),
            ins_clr_fl: Vector::<u32>::new(),
            ins_clr_blk: Vector::<u32>::new(),
            ins_clr_blk_fl: Vector::<u32>::new(),
            ins_off: Vector::<u32>::new(),
            ins_idx: Vector::<u32>::new(),
            ins_fill: Vector::<u32>::new(),
            fdecls: Vector::<NodeId>::new(),
            ftys: Vector::<TypeId>::new(),
        };
    }

    /// Heap bytes the context keeps across bodies (capacity, not length).
    pub const fn scratch_bytes(self: &Self) u64 {
        return ((self.sched.drops.capacity() + self.sched.moves.capacity()) * sizeof(DropAt) + (self.mi.capacity() + self.di.capacity() + self.mm.capacity()) * 8 + (self.scratch.capacity() + self.sub.capacity() + self.ins_cond_l.capacity() + self.ins_cond_f.capacity() + self.ins_clr_at.capacity() + self.ins_clr_fl.capacity() + self.ins_clr_blk.capacity() + self.ins_clr_blk_fl.capacity() + self.ins_off.capacity() + self.ins_idx.capacity() + self.ins_fill.capacity() + self.fdecls.capacity() + self.ftys.capacity()) * 4) as u64;
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
            if place_over_class(a, b, &pl) != 0 && ow.owns(b.module, pl.ty) {
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
        if ty != TYPE_NONE && ow.owns(b.module, ty) {
            return true;
        }
    }
    return assign_may_schedule(ow, b);
}

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
        mi.clear();
        di.clear();
        mm.clear();
        for k in 0..w {
            mi.push(fl.mi[bi * w + k]);
            di.push(fl.di[bi * w + k]);
            mm.push(fl.mm[bi * w + k]);
        }
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
                        DropAt {
                            local: forest.paths.at(e.path() as usize).base,
                            path: e.path(),
                            kind: 0,
                            stmt: sx as u32,
                            block: bi as u32,
                            fdecl: NODE_NONE,
                        },
                    );
                }
                df::apply_event(forest, &e, scratch, sub, mi, di, mm);
                ev += 1;
            }
            if s.kind == ir::ST_ASSIGN {
                // overwriting an initialized destructible value frees it first (language rule);
                // stores through raw pointers are unsafe storage and never auto-free
                let pl0 = *b.places.at(s.place as usize);
                if pl0.ty != TYPE_NONE && ow.owns(b.module, pl0.ty) {
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
                                sched.drops.push(
                                    DropAt {
                                        local: pl0.base,
                                        path: s.place,
                                        kind: DK_OVER,
                                        stmt: sx as u32,
                                        block: bi as u32,
                                        fdecl: NODE_NONE,
                                    },
                                );
                            } else if bits::bit_get(mi, dp0) && bits::bit_get(di, dp0) {
                                sched.drops.push(
                                    DropAt {
                                        local: pl0.base,
                                        path: s.place,
                                        kind: DK_OVERC,
                                        stmt: sx as u32,
                                        block: bi as u32,
                                        fdecl: NODE_NONE,
                                    },
                                );
                            } else if cls0 == 1 {
                                // A place reached through a REFERENCE deref (cls == 1) names storage
                                // the referent owns: the borrow checker guarantees it holds an
                                // initialized value (a field cannot be moved out through a reference,
                                // an out-of-bounds element traps before the store), so its overwrite
                                // frees the old value. The dataflow bit above tracks LOCAL init and
                                // is not seeded for such a referent -- a spliced-in block boundary
                                // (an inlined call) can leave it clear -- so cls == 1 frees here
                                // regardless, as place_over_class documents.
                                sched.drops.push(
                                    DropAt {
                                        local: pl0.base,
                                        path: s.place,
                                        kind: DK_OVER,
                                        stmt: sx as u32,
                                        block: bi as u32,
                                        fdecl: NODE_NONE,
                                    },
                                );
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
                if declared && ow.owns(b.module, lty) {
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
                    if all_di {
                        sched.drops.push(
                            DropAt {
                                local: l,
                                path: root,
                                kind: DK_UNCOND,
                                stmt: sx as u32,
                                block: bi as u32,
                                fdecl: NODE_NONE,
                            },
                        );
                    } else if sub_moved && !bits::bit_get(mm, root) {
                        // Partially moved (never wholly): every still-owned FIELD drops -- fields
                        // never mentioned have no move path and are owned by construction.
                        fdecls.clear();
                        ftys.clear();
                        let mut fom: ModuleId = 0;
                        if ow.agg_fields(b.module, lty, fdecls, ftys, &mut fom) {
                            for fi in 0..fdecls.len() {
                                let child = tuple_member_child(ow, forest, root, fom, fdecls[fi], fi as u32);
                                let mut live = child == mp::MP_NONE;
                                if child != mp::MP_NONE {
                                    live = bits::bit_get(di, child);
                                }
                                if live && ow.owns(fom, ftys[fi]) {
                                    let mut pth = root;
                                    if child != mp::MP_NONE {
                                        pth = child;
                                    }
                                    sched.drops.push(
                                        DropAt {
                                            local: l,
                                            path: pth,
                                            kind: DK_FIELD,
                                            stmt: sx as u32,
                                            block: bi as u32,
                                            fdecl: fdecls[fi],
                                        },
                                    );
                                }
                            }
                        }
                    } else if bits::bit_get(di, root) || bits::bit_get(mi, root) {
                        // The whole value may or may not still be here: one flag guards it.
                        sched.drops.push(
                            DropAt {
                                local: l,
                                path: root,
                                kind: DK_COND,
                                stmt: sx as u32,
                                block: bi as u32,
                                fdecl: NODE_NONE,
                            },
                        );
                    } else if any_mi {
                        fdecls.clear();
                        ftys.clear();
                        let mut fom2: ModuleId = 0;
                        let have2 = ow.agg_fields(b.module, lty, fdecls, ftys, &mut fom2);
                        for i in 0..sub.len() {
                            if sub[i] != root && bits::bit_get(di, sub[i]) && ow.owns(
                                b.module,
                                forest.paths.at(sub[i] as usize).ty,
                            ) {
                                let mut fd2 = NODE_NONE;
                                if have2 {
                                    for fi2 in 0..fdecls.len() {
                                        if tuple_member_child(ow, forest, root, fom2, fdecls[fi2], fi2 as u32) == sub[i] {
                                            fd2 = fdecls[fi2];
                                            break;
                                        }
                                    }
                                }
                                sched.drops.push(
                                    DropAt {
                                        local: l,
                                        path: sub[i],
                                        kind: DK_FIELD,
                                        stmt: sx as u32,
                                        block: bi as u32,
                                        fdecl: fd2,
                                    },
                                );
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
                        DropAt {
                            local: forest.paths.at(e.path() as usize).base,
                            path: e.path(),
                            kind: 0,
                            stmt: sx as u32,
                            block: bi as u32,
                            fdecl: NODE_NONE,
                        },
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
                    DropAt {
                        local: forest.paths.at(e.path() as usize).base,
                        path: e.path(),
                        kind: 0,
                        stmt: 0xFFFFFFFFu32,
                        block: bi as u32,
                        fdecl: NODE_NONE,
                    },
                );
            }
            ev += 1;
        }
    }
}

/// Rewrite `b` so every scheduled whole-value drop is an explicit `Drop(place)` terminator: the
/// marker's block splits there, the drop chains to the remainder, and `args_len` carries the
/// conditional flag. Statement storage is shared -- split parts reference subranges.
// One `flag = <v>` statement appended to the pool (fresh constant/operand/rvalue/place entries).
fn flag_stmt(b: &mut ir::CoreBody, fl: u32, v: i64, sp: tok::Span) {
    let bt = Ast::builtin(BuiltinType::BT_BOOL);
    b.constants.push(
        ir::Constant {
            kind: ir::CK_BOOL,
            ty: bt,
            val: v,
            raw: sp,
            item: DefId { module: 0, node: NODE_NONE },
            targ_start: 0,
            targ_len: 0,
        },
    );
    b.operands.push(ir::Operand { kind: ir::OP_CONST, data: b.constants.len() as u32 - 1, ty: bt });
    b.rvalues.push(
        ir::Rvalue {
            kind: ir::RV_USE,
            a: b.operands.len() as u32 - 1,
            b: 0,
            c: 0,
            target: bt,
            item: DefId { module: 0, node: NODE_NONE },
        },
    );
    b.places.push(ir::Place { base: fl, proj_start: 0, proj_len: 0, ty: bt });
    b.statements.push(
        ir::Statement {
            kind: ir::ST_ASSIGN,
            place: b.places.len() as u32 - 1,
            rvalue: b.rvalues.len() as u32 - 1,
            a: 0,
            b: 0,
            span: sp,
        },
    );
}

pub fn insert_drops(b: &mut ir::CoreBody, cx: &mut ElabCtx, forest: &mp::MoveForest) {
    let nb = b.blocks.len();
    // Scratch rides in the context (capacity survives across bodies); every vector is taken here
    // and handed back at the end, the one exit.
    let mut cond_l = replace(&mut cx.ins_cond_l, Vector::<u32>::new());
    let mut cond_f = replace(&mut cx.ins_cond_f, Vector::<u32>::new());
    let mut clr_at = replace(&mut cx.ins_clr_at, Vector::<u32>::new());
    let mut clr_fl = replace(&mut cx.ins_clr_fl, Vector::<u32>::new());
    let mut clr_blk = replace(&mut cx.ins_clr_blk, Vector::<u32>::new());
    let mut clr_blk_fl = replace(&mut cx.ins_clr_blk_fl, Vector::<u32>::new());
    let mut ins_off = replace(&mut cx.ins_off, Vector::<u32>::new());
    let mut ins_idx = replace(&mut cx.ins_idx, Vector::<u32>::new());
    cond_l.truncate(0);
    cond_f.truncate(0);
    clr_at.truncate(0);
    clr_fl.truncate(0);
    clr_blk.truncate(0);
    clr_blk_fl.truncate(0);
    let sched = &cx.sched;
    // Conditional drops test a REAL move flag: one bool temp per guarded local, true at entry and
    // at every storage-live, false after every whole-value move; the guarded Drop carries the flag
    // local in `args_start` (args_len 1 is the marker).
    for d in 0..sched.drops.len() {
        let da = *sched.drops.at(d);
        if da.kind != DK_COND && da.kind != DK_OVERC {
            continue;
        }
        let mut have = false;
        for i in 0..cond_l.len() {
            if cond_l[i] == da.local {
                have = true;
                break;
            }
        }
        if have {
            continue;
        }
        cond_l.push(da.local);
        b.locals.push(
            ir::LocalDecl {
                ty: Ast::builtin(BuiltinType::BT_BOOL),
                storage: ir::LS_TEMP,
                is_mutable: true,
                span: b.locals.at(da.local as usize).span,
                decl: NODE_NONE,
                item: DefId { module: 0, node: NODE_NONE },
                name_off: 0,
                name_len: 0,
                dkind: ir::LK_NONE,
                zero_len: false,
            },
        );
        cond_f.push(b.locals.len() as u32 - 1);
    }
    // Flag clears keyed by ORIGINAL statement index (terminator moves attribute to the block's
    // last statement -- the consume happens after it and before the terminator).
    if cond_l.len() != 0 {
        for mvi in 0..sched.moves.len() {
            let mv = *sched.moves.at(mvi);
            let mut fl = 0xFFFFFFFFu32;
            for i in 0..cond_l.len() {
                if cond_l[i] == mv.local {
                    fl = cond_f[i];
                    break;
                }
            }
            if fl == 0xFFFFFFFFu32 {
                continue;
            }
            if mv.stmt != 0xFFFFFFFFu32 {
                clr_at.push(mv.stmt);
                clr_fl.push(fl);
            } else {
                let ob = *b.blocks.at(mv.block as usize);
                if ob.stmt_len != 0 {
                    clr_at.push(ob.stmt_start + ob.stmt_len - 1);
                    clr_fl.push(fl);
                } else {
                    clr_blk.push(mv.block);
                    clr_blk_fl.push(fl);
                }
            }
        }
    }
    // The scheduled whole-value drops per block in schedule order (statement order within a block),
    // as one bucketed index list: `ins_idx[ins_off[bi] .. ins_off[bi + 1]]`. A field drop with no
    // reconstructible place is left out (better a leak than a wrong member).
    ins_off.truncate(0);
    for _i in 0..nb + 1 {
        ins_off.push(0);
    }
    for d in 0..sched.drops.len() {
        let da = sched.drops.at(d);
        if da.kind == DK_FIELD && da.fdecl == NODE_NONE {
            continue;
        }
        ins_off.set(da.block as usize + 1, ins_off[da.block as usize + 1] + 1);
    }
    for bi in 0..nb {
        ins_off.set(bi + 1, ins_off[bi] + ins_off[bi + 1]);
    }
    ins_idx.truncate(0);
    for _i in 0..ins_off[nb] {
        ins_idx.push(0);
    }
    {
        let mut fill = replace(&mut cx.ins_fill, Vector::<u32>::new());
        fill.truncate(0);
        for bi in 0..nb {
            fill.push(ins_off[bi]);
        }
        for d in 0..sched.drops.len() {
            let da = sched.drops.at(d);
            if da.kind == DK_FIELD && da.fdecl == NODE_NONE {
                continue;
            }
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
            let mut ty = b.locals.at(l as usize).ty;
            if over {
                ty = b.places.at(da.path as usize).ty;
            } else if kind == DK_FIELD {
                // the still-owned field: one PJ_FIELD projection reconstructed from the move-path
                // key -- bits 32..55 are the original `data` (a tuple member's positional index),
                // the low 32 the original `sub` (a named field's decl, or NODE_NONE for a tuple)
                let mp0 = *forest.paths.at(da.path as usize);
                ty = mp0.ty;
                b.projections.push(
                    ir::Projection {
                        kind: ir::PJ_FIELD,
                        data: (mp0.elem >> 32 & 0xFFFFFFu64) as u32,
                        sub: (mp0.elem & 0xFFFFFFFFu64) as u32,
                        ty: ty,
                    },
                );
                b.places.push(ir::Place { base: l, proj_start: b.projections.len() as u32 - 1, proj_len: 1, ty: ty });
            } else if !over {
                b.places.push(ir::Place { base: l, proj_start: 0, proj_len: 0, ty: ty });
            }
            let pl = if over {
                da.path;
            } else {
                b.places.len() as u32 - 1;
            };
            let next = b.add_block();
            let sp = b.statements.at(cut as usize).span;
            let mut t = ir::Terminator {
                kind: ir::TM_DROP,
                a: pl,
                args_start: 0,
                args_len: 0,
                dests_start: 0,
                dests_len: 0,
                sw_start: 0,
                sw_len: 0,
                t0: next,
                callee: DefId { module: 0, node: NODE_NONE },
                targs_start: 0,
                targs_len: 0,
                is_variadic: false,
                span: sp,
            };
            if kind == DK_COND || kind == DK_OVERC {
                t.args_len = 1;
                for i in 0..cond_l.len() {
                    if cond_l[i] == l {
                        t.args_start = cond_f[i];
                        break;
                    }
                }
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
    // inits/retrues/clears spliced in (runs stay contiguous; old entries simply go dead).
    if cond_l.len() != 0 {
        let nb2 = b.blocks.len();
        for bi in 0..nb2 {
            let blk = *b.blocks.at(bi);
            let ns = b.statements.len() as u32;
            if bi as u32 == b.entry {
                for i in 0..cond_f.len() {
                    flag_stmt(b, cond_f[i], 1, b.locals.at(cond_l[i] as usize).span);
                }
            }
            for i in 0..clr_blk.len() {
                if clr_blk[i] == bi as u32 {
                    flag_stmt(b, clr_blk_fl[i], 0, blk.term.span);
                }
            }
            for si in 0..blk.stmt_len {
                let sx = blk.stmt_start + si;
                let st = *b.statements.at(sx as usize);
                b.statements.push(st);
                if st.kind == ir::ST_STORAGE_LIVE {
                    for i in 0..cond_l.len() {
                        if cond_l[i] == st.a {
                            flag_stmt(b, cond_f[i], 1, st.span);
                            break;
                        }
                    }
                } else if st.kind == ir::ST_ASSIGN {
                    let pl = *b.places.at(st.place as usize);
                    if pl.proj_len == 0 {
                        for i in 0..cond_l.len() {
                            if cond_l[i] == pl.base {
                                flag_stmt(b, cond_f[i], 1, st.span);
                                break;
                            }
                        }
                    }
                }
                for i in 0..clr_at.len() {
                    if clr_at[i] == sx {
                        flag_stmt(b, clr_fl[i], 0, st.span);
                    }
                }
            }
            b.blocks[bi].stmt_start = ns;
            b.blocks[bi].stmt_len = b.statements.len() as u32 - ns;
        }
    }
    cx.ins_cond_l = cond_l;
    cx.ins_cond_f = cond_f;
    cx.ins_clr_at = clr_at;
    cx.ins_clr_fl = clr_fl;
    cx.ins_clr_blk = clr_blk;
    cx.ins_clr_blk_fl = clr_blk_fl;
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

const fn dv_bit(row: &Vector<u64>, p: u32) bool {
    return (row[(p / 64) as usize] >> (p & 63) as u64 & 1u64) != 0;
}

fn dv_any(row: &Vector<u64>, sub: &Vector<u32>) bool {
    for i in 0..sub.len() {
        if dv_bit(row, sub[i]) {
            return true;
        }
    }
    return false;
}

fn dv_all(row: &Vector<u64>, sub: &Vector<u32>) bool {
    for i in 0..sub.len() {
        if !dv_bit(row, sub[i]) {
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
            if !dv_bit(mi, root) && !dv_bit(di, root) {
                return "guarded-drop-of-unowned";
            }
            if !dv_bit(mm, root) {
                for i in 0..sub.len() {
                    if sub[i] != root && dv_bit(mm, sub[i]) && !dv_bit(di, sub[i]) {
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
    if t.args_len == 0 && !dv_bit(di, path) {
        return "field-drop-of-unowned";
    }
    if t.args_len == 1 && !dv_bit(mi, path) && !dv_bit(di, path) {
        return "guarded-field-drop-of-unowned";
    }
    dv_release(mi, di, mm, sub);
    return "";
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

// The failing block and local, for the validation build's report; the local is kept for the
// event dump the report ends with.
static mut DV_BAD: u32 = 0xFFFFFFFF;

fn dv_where(bi: usize, l: u32) {
    eprintln("verify_drops: block bb{} local _{}", bi, l);
    unsafe DV_BAD = l;
}

/// Independent check of an elaborated body (validation builds): with the move/init state of
/// every move path recomputed from the body's events, every drop terminator releases a value the
/// path definitely holds (or may hold, through a flag guard), never a partially moved whole, and
/// every storage death and return leaves nothing a declared owning local may still hold. Returns
/// "" or the first violated rule.
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
        tracked.push(declared && !cap && l as u32 >= b.returns && ld.ty != TYPE_NONE && ow.owns(b.module, ld.ty));
    }
    let mut forest = mp::MoveForest::empty();
    forest.build_into(b);
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
                            dv_where(cb, s.a);
                            return r;
                        }
                        chain.set(cb, true);
                        cb = ct.t0 as usize;
                        if b.blocks.at(cb).stmt_len != 0 {
                            break;
                        }
                    }
                    forest.subtree(root, &mut scratch, &mut sub);
                    if dv_any(&smi, &sub) {
                        dv_where(bi, s.a);
                        return "dead-with-unreleased-value"; // a maybe-held path the chain never drops
                    }
                } else {
                    forest.subtree(root, &mut scratch, &mut sub);
                    if dv_any(&mi, &sub) {
                        dv_where(bi, s.a);
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
                dv_where(bi, b.places.at(t.a as usize).base);
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
                if dv_any(&mi, &sub) {
                    dv_where(bi, l as u32);
                    return "return-with-live-value";
                }
            }
        }
    }
    return "";
}

/// The init/move events of local `l` in `b`, one line each, for a validation report.
pub fn dump_events(ow: &mut bf::Owner, b: &ir::CoreBody, l: u32) {
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

/// The local the last failed `verify_drops` reported (0xFFFFFFFF when none).
pub fn last_bad_local() u32 {
    return unsafe DV_BAD;
}
