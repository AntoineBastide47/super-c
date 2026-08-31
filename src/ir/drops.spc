// Drop elaboration: destruction becomes a Core IR property. The storage markers the
// lowerer already places at every scope exit (including early returns, break, and continue) ARE the
// lexical drop points; this pass classifies each one against the move/init dataflow -- unconditional,
// flag-guarded, per-field after a partial move, or omitted -- and can rewrite the body so each
// elaborated drop is an explicit `Drop(place)` terminator. The C emitter's own free insertion is
// compared against the schedule under the driver's comparison gate.
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
    pub concrete: bool, // every local type concrete: comparable against the emitter's decisions
}

extend Schedule as Free {
    pub fn free(self: &mut Self) {
        self.drops.free();
        self.moves.free();
    }
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
}

extend ElabCtx {
    pub fn empty() ElabCtx {
        return ElabCtx {
            sched: Schedule { drops: Vector::<DropAt>::new(), moves: Vector::<DropAt>::new(), concrete: true },
            mi: Vector::<u64>::new(),
            di: Vector::<u64>::new(),
            mm: Vector::<u64>::new(),
            scratch: Vector::<u32>::new(),
            sub: Vector::<u32>::new(),
        };
    }
}

extend ElabCtx as Free {
    pub fn free(self: &mut Self) {
        self.sched.free();
        self.mi.free();
        self.di.free();
        self.mm.free();
        self.scratch.free();
        self.sub.free();
    }
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
    cx.sched.concrete = true;
    let sched = &mut cx.sched;
    {
        let a = unsafe &*(&*ow.pkg).module_ast_const(b.module);
        for l in 0..b.locals.len() {
            if !a.type_concrete(b.locals.at(l).ty) {
                sched.concrete = false;
            }
        }
    }
    let w = fl.words as usize;
    let mi = &mut cx.mi;
    let di = &mut cx.di;
    let mm = &mut cx.mm;
    let scratch = &mut cx.scratch;
    let sub = &mut cx.sub;
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
                            }
                        }
                    }
                }
            }
            if s.kind == ir::ST_STORAGE_DEAD {
                let l = s.a;
                let decl = b.locals.at(l as usize).decl;
                let lty = b.locals.at(l as usize).ty;
                if decl != NODE_NONE && ow.owns(b.module, lty) {
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
                        let mut fdecls = Vector::<NodeId>::new();
                        let mut ftys = Vector::<TypeId>::new();
                        let mut fom: ModuleId = 0;
                        if ow.agg_fields(b.module, lty, &mut fdecls, &mut ftys, &mut fom) {
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
                        let mut fdecls2 = Vector::<NodeId>::new();
                        let mut ftys2 = Vector::<TypeId>::new();
                        let mut fom2: ModuleId = 0;
                        let have2 = ow.agg_fields(b.module, lty, &mut fdecls2, &mut ftys2, &mut fom2);
                        for i in 0..sub.len() {
                            if sub[i] != root && bits::bit_get(di, sub[i]) && ow.owns(
                                b.module,
                                forest.paths.at(sub[i] as usize).ty,
                            ) {
                                let mut fd2 = NODE_NONE;
                                if have2 {
                                    for fi2 in 0..fdecls2.len() {
                                        if tuple_member_child(ow, forest, root, fom2, fdecls2[fi2], fi2 as u32) == sub[i] {
                                            fd2 = fdecls2[fi2];
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

pub fn insert_drops(b: &mut ir::CoreBody, sched: &Schedule, forest: &mp::MoveForest) {
    let nb = b.blocks.len();
    // Conditional drops test a REAL move flag: one bool temp per guarded local, true at entry and
    // at every storage-live, false after every whole-value move; the guarded Drop carries the flag
    // local in `args_start` (args_len 1 is the marker).
    let mut cond_l = Vector::<u32>::new();
    let mut cond_f = Vector::<u32>::new();
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
            },
        );
        cond_f.push(b.locals.len() as u32 - 1);
    }
    // Flag clears keyed by ORIGINAL statement index (terminator moves attribute to the block's
    // last statement -- the consume happens after it and before the terminator).
    let mut clr_at = Vector::<u32>::new();
    let mut clr_fl = Vector::<u32>::new();
    let mut clr_blk = Vector::<u32>::new(); // empty-block terminator moves: prepend to this block
    let mut clr_blk_fl = Vector::<u32>::new();
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
    for bi in 0..nb {
        // Scheduled whole-value drops in this block, in statement order.
        let mut cuts = Vector::<u32>::new();
        let mut kinds = Vector::<u8>::new();
        let mut locs = Vector::<u32>::new();
        let mut pths = Vector::<u32>::new();
        let mut fdls = Vector::<NodeId>::new();
        for d in 0..sched.drops.len() {
            let da = *sched.drops.at(d);
            if da.block == bi as u32 {
                if da.kind == DK_FIELD && da.fdecl == NODE_NONE {
                    continue; // no reconstructible place: better a leak than a wrong member
                }
                cuts.push(da.stmt);
                kinds.push(da.kind);
                locs.push(da.local);
                pths.push(da.path);
                fdls.push(da.fdecl);
            }
        }
        if cuts.len() == 0 {
            continue;
        }
        let blk = *b.blocks.at(bi);
        let mut run_start = blk.stmt_start;
        let mut cur = bi as u32;
        for c in 0..cuts.len() {
            let cut = cuts[c];
            let over = kinds[c] == DK_OVER || kinds[c] == DK_OVERC;
            // The current part keeps [run_start, cut] (the marker stays; the drop follows it);
            // an OVERWRITE drop splits BEFORE its assignment instead.
            let keep = if over {
                cut - run_start;
            } else {
                cut + 1 - run_start;
            };
            let l = locs[c];
            let mut ty = b.locals.at(l as usize).ty;
            if over {
                ty = b.places.at(pths[c] as usize).ty;
            } else if kinds[c] == DK_FIELD {
                // the still-owned field: one PJ_FIELD projection reconstructed from the move-path
                // key -- bits 32..55 are the original `data` (a tuple member's positional index),
                // the low 32 the original `sub` (a named field's decl, or NODE_NONE for a tuple)
                let mp0 = *forest.paths.at(pths[c] as usize);
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
                pths[c];
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
            if kinds[c] == DK_COND || kinds[c] == DK_OVERC {
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
}
