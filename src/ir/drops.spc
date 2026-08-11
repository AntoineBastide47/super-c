// Drop elaboration: destruction becomes a Core IR property. The storage markers the
// lowerer already places at every scope exit (including early returns, break, and continue) ARE the
// lexical drop points; this pass classifies each one against the move/init dataflow -- unconditional,
// flag-guarded, per-field after a partial move, or omitted -- and can rewrite the body so each
// elaborated drop is an explicit `Drop(place)` terminator. The C emitter's own free insertion is
// compared against the schedule under the driver's comparison gate.
import ast::ast as *;
import module::loader as loader;
import ir::core as ir;
import borrowck::move_paths as mp;
import borrowck::facts as bf;
import borrowck::dataflow as df;

/// Drop classifications.
pub const DK_UNCOND: u8 = 0;
pub const DK_COND: u8 = 1; // reachable with differing init states: one flag guards the free
pub const DK_FIELD: u8 = 2; // partial move upstream: this entry drops one still-owned sub-place

pub struct DropAt {
    pub local: u32,
    pub path: u32, // move path (root for whole-value drops)
    pub kind: u8,
    pub stmt: u32, // the storage marker's statement index (body order)
    pub block: u32,
}

pub struct Schedule {
    pub drops: Vector<DropAt>,
    pub concrete: bool, // every local type concrete: comparable against the emitter's decisions
}

extend Schedule as Free {
    pub fn free(self: &mut Self) {
        self.drops.free();
    }
}

fn bit(v: &Vector<u64>, i: u32) bool {
    return (*v.at((i / 64) as usize) >> (i & 63) as u64 & 1u64) != 0;
}

/// Classify every storage-death point of `b` against the move/init solution.
pub fn elaborate(
    ow: &mut bf::Owner,
    b: &ir::CoreBody,
    forest: &mp::MoveForest,
    facts: &bf::BodyFacts,
    fl: &df::MoveFlow,
) Schedule {
    let mut sched = Schedule { drops: Vector::<DropAt>::new(), concrete: true };
    {
        let a = unsafe &*(&*ow.pkg).module_ast_const(b.module);
        for l in 0..b.locals.len() {
            if !a.type_concrete(b.locals.at(l).ty) {
                sched.concrete = false;
            }
        }
    }
    let w = fl.words as usize;
    let mut mi = Vector::<u64>::new();
    let mut di = Vector::<u64>::new();
    let mut mm = Vector::<u64>::new();
    let mut scratch = Vector::<u32>::new();
    let mut sub = Vector::<u32>::new();
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
                df::apply_event(forest, &e, &mut scratch, &mut sub, &mut mi, &mut di, &mut mm);
                ev += 1;
            }
            if s.kind == ir::ST_STORAGE_DEAD {
                let l = s.a;
                let decl = b.locals.at(l as usize).decl;
                let lty = b.locals.at(l as usize).ty;
                if decl != NODE_NONE && ow.owns(b.module, lty) {
                    let root = forest.local_root[l as usize];
                    forest.subtree(root, &mut scratch, &mut sub);
                    let mut all_di = true;
                    let mut any_mi = false;
                    let mut sub_moved = false;
                    for i in 0..sub.len() {
                        if !bit(&di, sub[i]) {
                            all_di = false;
                        }
                        if bit(&mi, sub[i]) {
                            any_mi = true;
                        }
                        if sub[i] != root && bit(&mm, sub[i]) {
                            sub_moved = true;
                        }
                    }
                    if all_di {
                        sched.drops.push(
                            DropAt { local: l, path: root, kind: DK_UNCOND, stmt: sx as u32, block: bi as u32 },
                        );
                    } else if sub_moved && !bit(&mm, root) {
                        // Partially moved (never wholly): every still-owned FIELD drops -- fields
                        // never mentioned have no move path and are owned by construction.
                        let mut fdecls = Vector::<NodeId>::new();
                        let mut ftys = Vector::<TypeId>::new();
                        let mut fom: ModuleId = 0;
                        if ow.agg_fields(b.module, lty, &mut fdecls, &mut ftys, &mut fom) {
                            for fi in 0..fdecls.len() {
                                let child = forest.field_child(root, fdecls[fi]);
                                let mut live = child == mp::MP_NONE;
                                if child != mp::MP_NONE {
                                    live = bit(&di, child);
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
                                        },
                                    );
                                }
                            }
                        }
                        fdecls.free();
                        ftys.free();
                    } else if bit(&di, root) || bit(&mi, root) {
                        // The whole value may or may not still be here: one flag guards it.
                        sched.drops.push(
                            DropAt { local: l, path: root, kind: DK_COND, stmt: sx as u32, block: bi as u32 },
                        );
                    } else if any_mi {
                        for i in 0..sub.len() {
                            if sub[i] != root && bit(&di, sub[i]) && ow.owns(
                                b.module,
                                forest.paths.at(sub[i] as usize).ty,
                            ) {
                                sched.drops.push(
                                    DropAt { local: l, path: sub[i], kind: DK_FIELD, stmt: sx as u32, block: bi as u32 },
                                );
                            }
                        }
                    }
                }
            }
            while ev < ev_end && facts.events.at(ev as usize).point <= exit {
                let e = *facts.events.at(ev as usize);
                df::apply_event(forest, &e, &mut scratch, &mut sub, &mut mi, &mut di, &mut mm);
                ev += 1;
            }
        }
    }
    mi.free();
    di.free();
    mm.free();
    scratch.free();
    sub.free();
    return sched;
}

/// Rewrite `b` so every scheduled whole-value drop is an explicit `Drop(place)` terminator: the
/// marker's block splits there, the drop chains to the remainder, and `args_len` carries the
/// conditional flag. Statement storage is shared -- split parts reference subranges.
pub fn insert_drops(b: &mut ir::CoreBody, sched: &Schedule) {
    let nb = b.blocks.len();
    for bi in 0..nb {
        // Scheduled whole-value drops in this block, in statement order.
        let mut cuts = Vector::<u32>::new();
        let mut kinds = Vector::<u8>::new();
        let mut locs = Vector::<u32>::new();
        for d in 0..sched.drops.len() {
            let da = *sched.drops.at(d);
            if da.block == bi as u32 && da.kind != DK_FIELD {
                cuts.push(da.stmt);
                kinds.push(da.kind);
                locs.push(da.local);
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
            // The current part keeps [run_start, cut] (the marker stays; the drop follows it).
            let keep = cut + 1 - run_start;
            let l = locs[c];
            let ty = b.locals.at(l as usize).ty;
            b.places.push(ir::Place { base: l, proj_start: 0, proj_len: 0, ty: ty });
            let pl = b.places.len() as u32 - 1;
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
            if kinds[c] == DK_COND {
                t.args_len = 1;
            }
            b.blocks[cur as usize].stmt_start = run_start;
            b.blocks[cur as usize].stmt_len = keep;
            b.blocks[cur as usize].term = t;
            b.blocks[cur as usize].sealed = true;
            run_start = cut + 1;
            cur = next;
        }
        // The final part carries the original run tail and terminator.
        b.blocks[cur as usize].stmt_start = run_start;
        b.blocks[cur as usize].stmt_len = blk.stmt_start + blk.stmt_len - run_start;
        b.blocks[cur as usize].term = blk.term;
        b.blocks[cur as usize].sealed = true;
    }
}
