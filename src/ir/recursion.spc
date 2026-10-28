// Unbounded recursion. A function that cannot end without calling itself again, directly or through a
// cycle of such functions, is an error: each call adds a frame until the stack overflows, and a call
// turned into a jump loops forever, so the rule holds for a call in tail position too. The check reads a
// summary of each function's Core IR (`Summarizer`): the batch driver summarizes the kept bodies of the
// reported modules after the borrow pass, before emission rewrites any body (`check_kept`); the language
// server keeps the summaries of each module's last borrow round and checks them when the round ends.
//
// A path of a body ENDS at a return, an `assert` (it may trap), an `unreachable` terminator, a call of a
// `@noreturn` function or a call of an extern C function (it may exit or abort; the verified memory
// and atomic intrinsics return). Every other call returns. The call graph has the direct calls between
// the reported modules' functions and methods only: a call through a function value, a `dyn` value or a
// bound reaches no member. A member of a strongly connected component of that graph ENDS when a path
// from its entry reaches an end without passing a call of a member that does not end. One worklist walk
// per component computes the least such set: a call of a member not yet known to end parks the walk
// until that member ends, so each point is visited at most once and each park resumed at most once. A
// member that does not end is reported at its first parked call, in source order, of a member that does
// not end either; one that calls no member loops without recursing, which is not this error. A trap
// inside a statement (checked arithmetic, a bounds check), a panic or an exit inside another function and
// a task cancellation (the ladder the lowering adds after a call or at a loop safepoint) are not ends:
// as rustc's `unconditional_recursion` does, the rule reads the paths the body itself spells.
//
// A summary keeps the blocks the walk tells apart, as points: an end, a call of a function of a
// reported module (a self call the tail-call pass made a jump, `CoreBody.tail_jumps`, is one), and a
// branch. Every other block passes control to its one successor and is left out, and so is a block no
// path from the entry reaches. Drop elaboration adds only such blocks, and a converted self call is
// still a call of the function, so a body summarizes to the same answer before and after both passes.
// A body with no call of a reported function is in no cycle and gets no summary.
import ast::ast as *;
import lexer::token as tok;
import ir::core as ir;
import ir::lower as irl;
import module::loader as loader;
import utils::errors as diag;

const NONE: u32 = 0xFFFFFFFF;

/// What a summary point does (`Point.kind`).
pub(package) const PK_END: u8 = 0; // a path of the body ends
pub(package) const PK_CALL: u8 = 1; // a call of `callee`; control continues at the successors once it returns
pub(package) const PK_BRANCH: u8 = 2; // control continues at one of the successors

// The role of a block while a body is summarized (`Summarizer.role`): a point kind, or one of these.
const R_PASS: u8 = 3; // control passes to the block's `t0`
const R_DEAD: u8 = 4; // no path of the body continues: a cancellation ladder starts here
const R_SELF: u8 = 5; // a jump that replaced a call of the function to itself

// `Summarizer.rep` of a block: not resolved yet (the zero the scratch starts as), on the chain being
// resolved, resolved to no point; else REP_BLOCK + the block of its point.
const REP_UNSET: u32 = 0;
const REP_CHAIN: u32 = 1;
const REP_NONE: u32 = 2;
const REP_BLOCK: u32 = 3;

/// One point of a summarized body.
pub(package) struct Point {
    pub(package) callee: DefId, // PK_CALL: the function called
    pub(package) span: tok::Span, // PK_CALL: the call
    pub(package) succ_start: u32, // its successors in `Sums.succ`, as points of its function
    pub(package) succ_len: u32,
    pub(package) kind: u8,
}

/// The summary of one function's body.
pub(package) struct FnSum {
    pub(package) node: NodeId, // the function
    pub(package) first: u32, // its points in `Sums.points`
    pub(package) count: u32,
    pub(package) entry: u32, // the point its paths reach first, NONE when none reaches one
}

/// The summaries of one module's functions.
pub(package) struct Sums {
    pub(package) fns: Vector<FnSum>,
    pub(package) points: Vector<Point>,
    pub(package) succ: Vector<u32>,
}

extend Sums {
    pub(package) fn new() Sums {
        return Sums { fns: Vector::<FnSum>::new(), points: Vector::<Point>::new(), succ: Vector::<u32>::new() };
    }

    /// Heap bytes held (capacity).
    pub(package) const fn retained_bytes(self: &Self) usize {
        return self.fns.capacity() * sizeof(FnSum) + self.points.capacity() * sizeof(Point) + self.succ.capacity() * 4;
    }
}

/// The language server's recursion state of a package: per module, the summaries of its last borrow
/// round, and whether one changed since the check last ran.
pub(package) struct Summaries {
    pub(package) reported: Vector<bool>, // per module: the server borrow checks it, so the check reports it
    pub(package) mods: Vector<Sums>, // per module; empty before its first borrow round
    pub(package) stale: bool,
}

extend Summaries {
    /// Heap bytes held (capacity).
    pub(package) const fn retained_bytes(self: &Self) usize {
        let mut b = self.reported.capacity() + self.mods.capacity() * sizeof(Sums);
        for m in 0..self.mods.len() {
            b += self.mods.at(m).retained_bytes();
        }
        return b;
    }
}

/// Summarizes bodies into one `Sums`, with scratch kept across bodies.
pub(package) struct Summarizer {
    reported: *const Vector<bool>, // per module: a call of one of its functions is a point
    out: Sums,
    role: Vector<u8>, // per block
    rep: Vector<u32>, // per block: the point control reaches first from it (REP_*)
    at: Vector<u32>, // per block: its point + 1, 0 before it is numbered
    next: Vector<u32>, // per block: its `t0`, read once
    queue: Vector<u32>,
}

extend Summarizer {
    /// A summarizer whose call points name the functions of the modules `reported` marks.
    pub(package) fn new(reported: *const Vector<bool>) Summarizer {
        return Summarizer {
            reported: reported,
            out: Sums::new(),
            role: Vector::<u8>::new(),
            rep: Vector::<u32>::new(),
            at: Vector::<u32>::new(),
            next: Vector::<u32>::new(),
            queue: Vector::<u32>::new(),
        };
    }

    /// The summaries added since the last take.
    pub(package) fn take(self: &mut Self) Sums {
        return replace(&mut self.out, Sums::new());
    }

    /// Add the summary of `b`, the body of a function or method (not of a closure).
    pub(package) fn add(self: &mut Self, p: &loader::Package, b: &ir::CoreBody) {
        let nb = b.blocks.len();
        let rmods = unsafe &*self.reported;
        // A body without a call of a reported function is in no cycle: it needs no summary, and a call
        // of it passes, as a call of a member of another component does.
        let mut calls = b.tail_jumps.len() != 0;
        for k in 0..nb {
            if calls {
                break;
            }
            let t = &b.blocks.at(k).term;
            calls = t.kind == ir::TM_CALL && t.callee.node != NODE_NONE && (t.callee.node & NODE_BODY) == 0 && rmods[t.callee.module as usize];
        }
        if !calls {
            return;
        }
        let lbegin = p.sugar_item(loader::SugarItem::SI_CANCEL_LBEGIN);
        // The scratch is zero-filled per body: one store per block below, no length check.
        self.role.truncate(0);
        self.role.resize_default(nb);
        self.rep.truncate(0);
        self.rep.resize_default(nb);
        self.at.truncate(0);
        self.at.resize_default(nb);
        self.next.truncate(0);
        self.next.resize_default(nb);
        for k in 0..nb {
            let t = &b.blocks.at(k).term;
            self.next.set(k, t.t0);
            let r = if t.kind == ir::TM_RETURN || t.kind == ir::TM_ASSERT || t.kind == ir::TM_UNREACHABLE {
                PK_END;
            } else if t.kind == ir::TM_SWITCH {
                PK_BRANCH;
            } else if t.kind != ir::TM_CALL {
                R_PASS; // goto, drop
            } else if lbegin.node != NODE_NONE && t.callee.node == lbegin.node && t.callee.module == lbegin.module {
                R_DEAD;
            } else if call_ends(p, t) {
                PK_END;
            } else if t.callee.node != NODE_NONE && (t.callee.node & NODE_BODY) == 0 && rmods[t.callee.module as usize] {
                PK_CALL;
            } else {
                R_PASS;
            };
            self.role.set(k, r);
        }
        for i in 0..b.tail_jumps.len() {
            self.role.set(b.tail_jumps[i] as usize, R_SELF);
        }
        // Resolve each block to the point control reaches first from it: follow its chain of passing
        // blocks (each joins a chain once), then walk the chain again to store the answer.
        for k in 0..nb {
            if self.rep[k] != REP_UNSET {
                continue;
            }
            let mut cur = k as u32;
            let mut r = REP_NONE;
            loop {
                let s = self.rep[cur as usize];
                if s != REP_UNSET {
                    if s != REP_CHAIN {
                        r = s;
                    }
                    break; // a resolved block, or a loop of passing blocks: no point
                }
                let role = self.role[cur as usize];
                if role != R_PASS {
                    if role != R_DEAD {
                        r = REP_BLOCK + cur;
                    }
                    self.rep.set(cur as usize, r);
                    break;
                }
                self.rep.set(cur as usize, REP_CHAIN);
                cur = self.next[cur as usize];
            }
            cur = k as u32;
            while self.rep[cur as usize] == REP_CHAIN {
                self.rep.set(cur as usize, r);
                cur = self.next[cur as usize];
            }
        }
        // Number the points reachable from the entry, breadth first; each is queued once.
        let first = self.out.points.len() as u32;
        self.queue.truncate(0);
        let mut entry = NONE;
        let e = self.rep[b.entry as usize];
        if e != REP_NONE {
            entry = 0;
            self.at.set((e - REP_BLOCK) as usize, 1);
            self.queue.push(e - REP_BLOCK);
        }
        let mut qi: usize = 0;
        while qi < self.queue.len() {
            let k = self.queue[qi] as usize;
            qi += 1;
            let t = &b.blocks.at(k).term;
            let role = self.role[k];
            let mut pt = Point {
                callee: DefId { module: 0, node: NODE_NONE },
                span: tok::Span::empty(),
                succ_start: self.out.succ.len() as u32,
                succ_len: 0,
                kind: role,
            };
            if role == R_SELF {
                pt.kind = PK_CALL;
                pt.callee = b.owner;
                pt.span = t.span;
            } else if role == PK_CALL {
                pt.callee = t.callee;
                pt.span = t.span;
                self.succ_to(t.t0);
            } else if role == PK_BRANCH {
                for i in 0..t.sw_len {
                    self.succ_to((b.switch_pool[(t.sw_start + i) as usize] & 0xFFFFFFFFu64) as u32);
                }
                self.succ_to(t.t0);
            }
            pt.succ_len = self.out.succ.len() as u32 - pt.succ_start;
            self.out.points.push(pt);
        }
        self.out.fns.push(FnSum { node: b.owner.node, first: first, count: self.queue.len() as u32, entry: entry });
    }

    // Record block `blk` as a successor of the point being built, numbering its point first.
    fn succ_to(self: &mut Self, blk: u32) {
        let v = self.rep[blk as usize];
        if v == REP_NONE {
            return;
        }
        let r = (v - REP_BLOCK) as usize;
        if self.at[r] == 0 {
            self.queue.push(r as u32);
            self.at.set(r, self.queue.len() as u32);
        }
        self.out.succ.push(self.at[r] - 1);
    }
}

// A reported function or method with a summary.
struct Member {
    pub(package) item: u32, // its ItemMeta in the package index
    pub(package) module: u32,
    pub(package) fi: u32, // its summary in `sums[module].fns`
    pub(package) edge_start: u32, // its callees among the members, in `Recur.edges`
    pub(package) edge_end: u32,
    pub(package) index: u32, // Tarjan's visit index, NONE before the visit
    pub(package) low: u32,
    pub(package) comp: u32, // its strongly connected component
    pub(package) seen_start: u32, // its points in `Recur.seen`, during its component's walk
    pub(package) wait_head: u32, // the parked calls of it, in `Recur.waits`
    pub(package) park: u32, // the point of its first parked call of a member that does not end, NONE when none
    pub(package) on_stack: bool,
    pub(package) cyclic: bool, // its component has a cycle
    pub(package) ends: bool,
}

// A call of member `on` at point `point` of member `caller`, waiting until `on` ends.
struct Wait {
    pub(package) caller: u32,
    pub(package) point: u32,
    pub(package) next: u32,
}

struct Recur {
    pub(package) members: Vector<Member>,
    pub(package) ix: Map<u64, u32>, // def_key(module, node) -> member
    pub(package) edges: Vector<u32>,
    pub(package) comp_members: Vector<u32>, // the members of each component, component after component
    pub(package) comp_start: Vector<u32>, // components + 1 offsets into `comp_members`
    pub(package) seen: Vector<bool>,
    pub(package) work: Vector<u64>, // member << 32 | point
    pub(package) waits: Vector<Wait>,
}

/// One module's unbounded-recursion errors (`check`), finalized.
pub(package) struct Report {
    pub(package) module: u32,
    pub(package) errs: diag::Errors,
}

/// Report every function or method of a module `reported` marks whose summary in `sums` (indexed by
/// module) shows it cannot end without calling itself again, directly or through a cycle (see the top
/// of this file). One report per module with an error, in module order.
pub(package) fn check(p: &loader::Package, sums: &Vector<Sums>, reported: &Vector<bool>) Vector<Report> {
    assert(sums.len() == p.modules.len() && reported.len() == p.modules.len(), "one summary set per module");
    let mut r = Recur::new();
    r.collect(p, sums, reported);
    if r.members.len() == 0 {
        return Vector::<Report>::new();
    }
    r.link(sums);
    r.components();
    for c in 0..r.comp_start.len() - 1 {
        if r.members[r.comp_members[r.comp_start[c] as usize] as usize].cyclic {
            r.walk(sums, c as u32);
        }
    }
    return r.report(p, sums);
}

/// The batch driver's check: summarize the kept bodies of the modules `reported` marks (`keep` holds
/// the borrow pass's bodies), check them and print the errors. True when nothing was reported.
/// Only the members of a cyclic component of the direct-call graph get a summary: the graph comes from
/// the call terminators and the converted self calls of every kept body, a superset of the calls the
/// summaries keep, so every function `check` finds in a cycle is summarized, and a call of one that is
/// not passes there as a call of a member of another component does.
pub(package) fn check_kept(p: &loader::Package, keep: &irl::Keep, reported: &Vector<bool>) bool {
    let mut g = Recur::new();
    for m in 0..p.modules.len() {
        if !reported[m] || !p.modules.at(m).has_ast {
            continue;
        }
        for k in p.idx.mod_items[m]..p.idx.mod_items[m + 1] {
            let it = *p.idx.items.at(k as usize);
            if it.kind != loader::ItemKind::IK_FUNCTION as u8 && it.kind != loader::ItemKind::IK_METHOD as u8 {
                continue;
            }
            switch keep.ix.get(&def_key(it.module, it.node)) {
                Some(v) => {
                    g.add_member(k, m as u32, (*v) as u32, it.node);
                },
                None => {},
            };
        }
    }
    g.link_kept(keep, reported);
    g.components();
    let mut s = Summarizer::new(reported);
    let mut sums = Vector::<Sums>::with_capacity(p.modules.len());
    let mut f: usize = 0;
    for m in 0..p.modules.len() {
        while f < g.members.len() && g.members[f].module == m as u32 {
            if g.members[f].cyclic {
                s.add(p, &keep.kept.at(g.members[f].fi as usize).body);
            }
            f += 1;
        }
        sums.push(s.take());
    }
    let reps = check(p, &sums, reported);
    for i in 0..reps.len() {
        reps.at(i).errs.log();
    }
    return reps.len() == 0;
}

const fn def_key(module: ModuleId, node: NodeId) u64 {
    return skey_mix(0, module as u64 << 32 | node as u64);
}

// The callee of `t` may end the caller's path: a `@noreturn` function, or an extern C function other
// than a verified intrinsic.
fn call_ends(p: &loader::Package, t: &ir::Terminator) bool {
    let d = t.callee;
    if d.node == NODE_NONE || (d.node & NODE_BODY) != 0 || d.module as usize >= p.modules.len() || !p.modules.at(
        d.module as usize,
    ).has_ast {
        return false;
    }
    let a = unsafe &*p.module_ast_const(d.module);
    if !a.valid(d.node) {
        return false;
    }
    if a.attr_of(d.node, AttrKind::ATTR_NORETURN) != null {
        return true;
    }
    let nd = a.at_const(d.node);
    return nd.kind == NodeKind::NODE_FUNCTION && nd.as_data.function.is_extern() && t.intr == ir::CI_NONE;
}

// The name of index item `item`.
const fn item_name(p: &loader::Package, item: u32) str {
    let it = *p.idx.items.at(item as usize);
    return p.modules.at(it.module as usize).source.as_str().slice(it.start as usize, (it.start + it.len) as usize);
}

// Does call point `a` come before call point `b` in source order (then by callee, so the choice never
// depends on the walk's order)?
const fn earlier(a: Point, b: Point) bool {
    if a.span.start != b.span.start {
        return a.span.start < b.span.start;
    }
    if a.span.end != b.span.end {
        return a.span.end < b.span.end;
    }
    return def_key(a.callee.module, a.callee.node) < def_key(b.callee.module, b.callee.node);
}

extend Recur {
    fn new() Recur {
        return Recur {
            members: Vector::<Member>::new(),
            ix: Map::<u64, u32>::new(),
            edges: Vector::<u32>::new(),
            comp_members: Vector::<u32>::new(),
            comp_start: Vector::<u32>::new(),
            seen: Vector::<bool>::new(),
            work: Vector::<u64>::new(),
            waits: Vector::<Wait>::new(),
        };
    }

    // Every function and method with a summary in a reported module, in module and summary order.
    fn collect(self: &mut Recur, p: &loader::Package, sums: &Vector<Sums>, reported: &Vector<bool>) {
        for m in 0..p.modules.len() {
            if !reported[m] {
                continue;
            }
            let s = sums.at(m);
            for fi in 0..s.fns.len() {
                let node = s.fns.at(fi).node;
                let k = p.item_of(m as ModuleId, node);
                assert(k != loader::ITEM_NONE, "a summarized function is an index item");
                self.add_member(k, m as u32, fi as u32, node);
            }
        }
    }

    // A member for index item `item` (declaration `node` of module `module`); `fi` is its summary
    // (`check`) or its kept body (`check_kept`).
    fn add_member(self: &mut Recur, item: u32, module: u32, fi: u32, node: NodeId) {
        self.ix.insert(def_key(module as ModuleId, node), self.members.len() as u32);
        self.members.push(
            Member {
                item: item,
                module: module,
                fi: fi,
                edge_start: 0,
                edge_end: 0,
                index: NONE,
                low: 0,
                comp: NONE,
                seen_start: 0,
                wait_head: NONE,
                park: NONE,
                on_stack: false,
                cyclic: false,
                ends: false,
            },
        );
    }

    // The direct-call graph between members whose `fi` is a kept body: every call of a member and,
    // when the pass made one a jump, a call of the member itself; a self call makes the component
    // cyclic.
    fn link_kept(self: &mut Recur, keep: &irl::Keep, reported: &Vector<bool>) {
        for f in 0..self.members.len() {
            self.members[f].edge_start = self.edges.len() as u32;
            let b = &keep.kept.at(self.members[f].fi as usize).body;
            if b.tail_jumps.len() != 0 {
                self.edges.push(f as u32);
                self.members[f].cyclic = true;
            }
            for k in 0..b.blocks.len() {
                let t = &b.blocks.at(k).term;
                if t.kind != ir::TM_CALL || t.callee.node == NODE_NONE || !reported[t.callee.module as usize] {
                    continue;
                }
                let g = self.member_of(t.callee);
                if g == NONE {
                    continue;
                }
                self.edges.push(g);
                if g == f as u32 {
                    self.members[f].cyclic = true;
                }
            }
            self.members[f].edge_end = self.edges.len() as u32;
        }
    }

    // The summary of member `f`.
    const fn fsum(self: &Recur, sums: &Vector<Sums>, f: u32) FnSum {
        let me = self.members.at(f as usize);
        return *sums.at(me.module as usize).fns.at(me.fi as usize);
    }

    // Point `x` of member `f`.
    const fn point(self: &Recur, sums: &Vector<Sums>, f: u32, x: u32) Point {
        let me = self.members.at(f as usize);
        let s = sums.at(me.module as usize);
        return *s.points.at((s.fns.at(me.fi as usize).first + x) as usize);
    }

    // The member a direct call of `d` reaches, or NONE.
    const fn member_of(self: &Recur, d: DefId) u32 {
        if d.node == NODE_NONE {
            return NONE;
        }
        return switch self.ix.get(&def_key(d.module, d.node)) {
            Some(v) => *v,
            None => NONE,
        };
    }

    // The call graph between the members; a self call makes its member's component cyclic.
    fn link(self: &mut Recur, sums: &Vector<Sums>) {
        for f in 0..self.members.len() {
            self.members[f].edge_start = self.edges.len() as u32;
            let fs = self.fsum(sums, f as u32);
            for x in 0..fs.count {
                let pt = self.point(sums, f as u32, x);
                if pt.kind != PK_CALL {
                    continue;
                }
                let g = self.member_of(pt.callee);
                if g == NONE {
                    continue;
                }
                self.edges.push(g);
                if g == f as u32 {
                    self.members[f].cyclic = true;
                }
            }
            self.members[f].edge_end = self.edges.len() as u32;
        }
    }

    // Tarjan's strongly connected components, with an explicit stack: each member and each edge is
    // visited once.
    fn components(self: &mut Recur) {
        let mut next: u32 = 0;
        let mut stack = Vector::<u32>::new(); // members of the components in progress
        let mut frames = Vector::<u64>::new(); // member << 32 | its next edge
        for root in 0..self.members.len() {
            if self.members[root].index != NONE {
                continue;
            }
            self.enter(root as u32, &mut next, &mut stack, &mut frames);
            while frames.len() != 0 {
                let top = frames[frames.len() - 1];
                let v = (top >> 32) as u32;
                let e = (top & 0xFFFFFFFFu64) as u32;
                if e < self.members[v as usize].edge_end {
                    frames.set(frames.len() - 1, top + 1);
                    let w = self.edges[e as usize];
                    if self.members[w as usize].index == NONE {
                        self.enter(w, &mut next, &mut stack, &mut frames);
                    } else if self.members[w as usize].on_stack && self.members[w as usize].index < self.members[v as usize].low {
                        self.members[v as usize].low = self.members[w as usize].index;
                    }
                    continue;
                }
                let _ = frames.pop();
                if self.members[v as usize].low == self.members[v as usize].index {
                    self.close(v, &mut stack);
                }
                if frames.len() != 0 {
                    let u = (frames[frames.len() - 1] >> 32) as usize;
                    if self.members[v as usize].low < self.members[u].low {
                        self.members[u].low = self.members[v as usize].low;
                    }
                }
            }
        }
        self.comp_start.push(self.comp_members.len() as u32);
    }

    fn enter(self: &mut Recur, v: u32, next: &mut u32, stack: &mut Vector<u32>, frames: &mut Vector<u64>) {
        self.members[v as usize].index = *next;
        self.members[v as usize].low = *next;
        *next = *next + 1;
        self.members[v as usize].on_stack = true;
        stack.push(v);
        frames.push(v as u64 << 32 | self.members[v as usize].edge_start as u64);
    }

    // Pop the component rooted at `v`; more than one member makes it cyclic.
    fn close(self: &mut Recur, v: u32, stack: &mut Vector<u32>) {
        let c = self.comp_start.len() as u32;
        self.comp_start.push(self.comp_members.len() as u32);
        let first = self.comp_members.len();
        loop {
            let w = switch stack.pop() {
                Some(x) => x,
                None => {
                    break;
                },
            };
            self.members[w as usize].on_stack = false;
            self.members[w as usize].comp = c;
            self.comp_members.push(w);
            if w == v {
                break;
            }
        }
        if self.comp_members.len() - first > 1 {
            for k in first..self.comp_members.len() {
                let w = self.comp_members[k] as usize;
                self.members[w].cyclic = true;
            }
        }
    }

    // The member a direct call of `d` reaches inside component `c`, or NONE.
    const fn member_in(self: &Recur, d: DefId, c: u32) u32 {
        let g = self.member_of(d);
        if g == NONE || self.members[g as usize].comp != c {
            return NONE;
        }
        return g;
    }

    // Queue point `x` of member `f` unless it was queued before.
    fn visit(self: &mut Recur, f: u32, x: u32) {
        let at = (self.members[f as usize].seen_start + x) as usize;
        if self.seen[at] {
            return;
        }
        self.seen.set(at, true);
        self.work.push(f as u64 << 32 | x as u64);
    }

    // Queue the successors of point `pt` of member `f`.
    fn visit_succ(self: &mut Recur, sums: &Vector<Sums>, f: u32, pt: &Point) {
        let m = self.members[f as usize].module as usize;
        for i in 0..pt.succ_len {
            let x = sums.at(m).succ[(pt.succ_start + i) as usize];
            self.visit(f, x);
        }
    }

    // Member `f` ends: every walk parked on it continues after its call.
    fn finish(self: &mut Recur, sums: &Vector<Sums>, f: u32) {
        self.members[f as usize].ends = true;
        let mut w = self.members[f as usize].wait_head;
        self.members[f as usize].wait_head = NONE;
        while w != NONE {
            let x = self.waits[w as usize];
            if !self.members[x.caller as usize].ends {
                let pt = self.point(sums, x.caller, x.point);
                self.visit_succ(sums, x.caller, &pt);
            }
            w = x.next;
        }
    }

    // The least set of component `c`'s members that end (see the top of this file), then the park of
    // each member that does not.
    fn walk(self: &mut Recur, sums: &Vector<Sums>, c: u32) {
        self.seen.truncate(0);
        self.work.truncate(0);
        self.waits.truncate(0);
        let lo = self.comp_start[c as usize] as usize;
        let hi = self.comp_start[c as usize + 1] as usize;
        let mut np: u32 = 0;
        for k in lo..hi {
            let f = self.comp_members[k];
            self.members[f as usize].seen_start = np;
            np += self.fsum(sums, f).count;
        }
        self.seen.resize_default(np as usize);
        for k in lo..hi {
            let f = self.comp_members[k];
            let entry = self.fsum(sums, f).entry;
            if entry != NONE {
                self.visit(f, entry);
            }
        }
        loop {
            let w = switch self.work.pop() {
                Some(v) => v,
                None => {
                    break;
                },
            };
            let f = (w >> 32) as u32;
            let x = (w & 0xFFFFFFFFu64) as u32;
            if self.members[f as usize].ends {
                continue;
            }
            let pt = self.point(sums, f, x);
            if pt.kind == PK_END {
                self.finish(sums, f);
            } else if pt.kind == PK_CALL {
                let g = self.member_in(pt.callee, c);
                if g == NONE || self.members[g as usize].ends {
                    self.visit_succ(sums, f, &pt);
                    continue;
                }
                self.waits.push(Wait { caller: f, point: x, next: self.members[g as usize].wait_head });
                self.members[g as usize].wait_head = (self.waits.len() - 1) as u32;
            } else {
                self.visit_succ(sums, f, &pt);
            }
        }
        // The calls still parked wait on members that do not end.
        for k in lo..hi {
            let g = self.comp_members[k] as usize;
            let mut w = self.members[g].wait_head;
            while w != NONE {
                let x = self.waits[w as usize];
                w = x.next;
                let me = self.members[x.caller as usize];
                if me.ends {
                    continue;
                }
                if me.park == NONE || earlier(self.point(sums, x.caller, x.point), self.point(sums, x.caller, me.park)) {
                    self.members[x.caller as usize].park = x.point;
                }
            }
        }
    }

    // One error per member of a cyclic component that does not end, at its park, in module and item
    // order.
    fn report(self: &Recur, p: &loader::Package, sums: &Vector<Sums>) Vector<Report> {
        let mut out = Vector::<Report>::new();
        let mut f: usize = 0;
        while f < self.members.len() {
            let m = self.members[f].module;
            let mut errs = diag::Errors::new();
            while f < self.members.len() && self.members[f].module == m {
                let me = self.members[f];
                let fi = f as u32;
                f += 1;
                if !me.cyclic || me.ends || me.park == NONE {
                    continue;
                }
                let pt = self.point(sums, fi, me.park);
                let g = self.member_of(pt.callee);
                let name = item_name(p, me.item);
                if g == fi {
                    errs.emit_span(pt.span, format("function '{}' cannot return without calling itself", name));
                } else {
                    errs.emit_span(
                        pt.span,
                        format(
                            "function '{}' cannot return without calling '{}', which cannot return either",
                            name,
                            item_name(p, self.members[g as usize].item),
                        ),
                    );
                }
                errs.note(
                    String::from_str(
                        "no path returns before such a call: the recursion never ends and overflows the stack",
                    ),
                );
            }
            if errs.errors.len() != 0 {
                errs.finalize(p.modules.at(m as usize).source.as_str(), p.modules.at(m as usize).file.as_str());
                out.push(Report { module: m, errs: errs });
            }
        }
        return out;
    }
}
