// The borrow checker: a pipeline stage of its own, run after the whole package is typed. The
// typechecker records types and resolutions; this pass owns every borrow, move and lifetime
// analysis. It extends TypeChecker rather than defining a new context so the analyses read the same
// state and helpers the type walk built (types, resolutions, the lifetime side table, diagnostics).
//
// Two layers: the DECLARATION-LEVEL lifetime analyses (Rust's elision rules on return types, the
// requirement that a reference or borrowing type stored in an aggregate names the lifetime it
// borrows for, the modular return-lifetime check), and the flow analysis (bc_fn), which lowers each
// body to Core IR, replays its event tape, and tracks moves, partial moves, borrows, definite-init,
// frees and region ties. Callee resolution is never re-derived here: the typechecker's call_info
// side table is the bridge (bc_call_info).
import lexer::token as tok;
import ast::ast as *;
import module::loader as loader;
import typechecker::typechecker as tc;
import typechecker::typechecker as *;
import borrowck::facts as bfx;
import borrowck::flow_ir as bfi;
import ir::lower as irl;
import ir::core as ir;

// Capacities of the TypeChecker's flow tables: `moved`, and `late` and `borrows`.
// FlowState snapshots have the same sizes, so saving a state never truncates it.
const BC_MOVED_CAP: u32 = 1024;
const BC_TABLE_CAP: u32 = 256;

@c.always_inline
const fn rep_bm(st: &mut bfi::RepSt) u32 {
    return st.bms.pop().unwrap_or(0);
}

// Depth-slot flow push: existing slots are refilled row-wise (no whole-FlowState copies). Out of
// line so the two FlowState temporaries of the first push at a depth stay out of bc_replay's frame.
@c.noinline
fn rep_flow_push(t: &mut tc::TypeChecker, st: &mut bfi::RepSt) {
    let d = st.fdepth;
    if st.pre.len() <= d {
        let mut ps: FlowState;
        t.tc_flow_save(&mut ps);
        st.pre.push(ps);
        let mut ac: FlowState;
        t.tc_flow_clear(&mut ac);
        st.acc.push(ac);
    } else {
        t.tc_flow_save(&mut st.pre[d]);
        t.tc_flow_clear(&mut st.acc[d]);
    }
    st.fdepth = d + 1;
}

extend tc::TypeChecker {
    /// Entry point: run the declaration-level checks and the flow walk over every item of the
    /// current module, then finalize its diagnostics.
    /// Single-module entry (tests, harness): private oracle and pipeline, discarded after. The
    /// package's types must be published first (`publish_checkpoint`), as before every borrow
    /// frontier of the driver.
    pub fn borrowck_solo(self: &mut Self) {
        let mut ow = bfx::Owner::new(self.package);
        let mut ctx = bfi::BorrowCtx::new();
        self.borrowck(&mut ow, &mut ctx);
    }

    /// `ow`/`ctx` are the package-level ownership oracle and borrow pipeline: one of each per
    /// build, so their memo tables and vector capacities survive across modules.
    pub fn borrowck(self: &mut Self, ow: &mut bfx::Owner, ctx: &mut bfi::BorrowCtx) {
        let tp = ctx.st.pr.start();
        if unsafe (&*self.package).co_state == 0 {
            // Single-threaded phase: the const package pointer is the one place mutated (cir precedent).
            unsafe (&mut *self.package).co_compute();
        }
        if unsafe (&*self.package).cancel_state == 0 {
            unsafe (&mut *self.package).cancel_compute();
        }
        ctx.st.pr.stop(bfi::BP_REACH, tp);
        let a = self.cur_ast();
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        // The lowered bodies of the function under analysis: one vector for the module, emptied
        // after every function (a per-function vector reserves eight Lowerer slots on its first push).
        let mut bodies = Vector::<irl::Lowerer>::new();
        for i in 0..items.len {
            let id = unsafe (*a).list(items)[i as usize];
            self.bc_item(id, ow, ctx, &mut bodies);
        }
        let mut file: str = "";
        if self.cur_module() as usize < self.pkg_count() {
            file = unsafe (*self.package).modules[self.cur_module() as usize].file.as_str();
        }
        let ts = ctx.st.pr.start();
        self.errors.finalize(self.source, file);
        ctx.st.pr.stop(bfi::BP_SETUP, ts);
    }

    /// Borrow-check one top-level item: functions get the body walk, aggregates their field-lifetime
    /// checks, extends recurse into their methods.
    pub fn bc_item(
        self: &mut Self,
        id: NodeId,
        ow: &mut bfx::Owner,
        ctx: &mut bfi::BorrowCtx,
        bodies: &mut Vector<irl::Lowerer>,
    ) {
        let a = self.cur_ast();
        let nk = unsafe (*a).at_const(id).kind;
        switch nk {
            NODE_FUNCTION => {
                let td = ctx.st.pr.start();
                self.tc_check_elision(id);
                ctx.st.pr.stop(bfi::BP_DECL, td);
                self.bc_fn(id, ow, ctx, bodies);
            },
            NODE_STRUCT | NODE_ENUM => {
                let td = ctx.st.pr.start();
                self.tc_check_field_lifetimes(id, unsafe (*a).at_const(id).as_data.aggregate.members);
                ctx.st.pr.stop(bfi::BP_DECL, td);
            },
            NODE_EXTEND => {
                let ms = unsafe (*a).at_const(id).as_data.extend_def.items;
                for j in 0..ms.len {
                    self.bc_item(unsafe (*a).list(ms)[j as usize], ow, ctx, bodies);
                }
            },
            _ => {},
        };
    }

    /// Definition-site elision: a return type with an elided lifetime is an error unless rule 3 (a
    /// `self` receiver) or rule 2 (exactly one borrowing input) pins which input it borrows from.
    pub fn tc_check_elision(self: &mut Self, fnid: NodeId) {
        let a = self.cur_ast();
        let fnd = unsafe (*a).at_const(fnid).as_data.function;
        if fnd.returns.len == 0 || self.tc_elision_source(fnid) >= 0 {
            return;
        }
        for i in 0..fnd.returns.len {
            let r = unsafe (*a).list(fnd.returns)[i as usize];
            let rt = unsafe (*a).slot_type_node(r);
            if !self.tc_has_elided_lt(self.cur_module(), rt, 0) {
                continue;
            }
            let sp = unsafe (*a).at_const(rt).span;
            self.errors.emit_span(
                sp,
                format(
                    "missing lifetime specifier: this return type borrows, but which input it borrows from cannot be inferred",
                ),
            );
            self.errors.note(
                format(
                    "name it, e.g. `fn f<'a>(x: &'a T, y: &U) &'a T`; elision only applies with a `self` receiver or exactly one borrowing input",
                ),
            );
        }
    }

    /// The index of the parameter whose lifetime an elided output takes: a `self` receiver (rule 3),
    /// else the only parameter with a lifetime position when there is exactly one position (rule 2);
    /// -1 when neither rule applies.
    pub fn tc_elision_source(self: &mut Self, fnid: NodeId) i32 {
        let a = self.cur_ast();
        let params = unsafe (*a).at_const(fnid).as_data.function.params;
        let mut inputs: i32 = 0;
        let mut src: i32 = -1;
        for i in 0..params.len {
            let pid = unsafe (*a).list(params)[i as usize];
            let c = self.tc_count_lt_positions(self.cur_module(), unsafe (*a).at_const(pid).as_data.parameter.ty, 0);
            if i == 0 && c != 0 && span_is(
                self.source,
                self.name_span(unsafe (*a).at_const(pid).as_data.parameter.name),
                "self",
            ) {
                return 0;
            }
            if c != 0 {
                src = i as i32;
            }
            inputs = inputs + c;
        }
        return pick(inputs == 1, src, -1);
    }

    /// Number of lifetime positions in type node `tyn` of module `m` (each reference and slice, plus
    /// path lifetime args); 0 past depth 6.
    pub fn tc_count_lt_positions(self: &mut Self, m: ModuleId, tyn: NodeId, depth: i32) i32 {
        if tyn == NODE_NONE || depth > 6 {
            return 0;
        }
        let n = unsafe (*self.mod_ast(m)).at_const(tyn);
        if n.kind == NodeKind::NODE_REFERENCE_TYPE || n.kind == NodeKind::NODE_SLICE_TYPE {
            return 1 + self.tc_count_lt_positions(m, n.as_data.indirect_type.ty, depth + 1);
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            return self.tc_count_lt_positions(m, n.as_data.array_type.element, depth + 1);
        }
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            let mut c: i32 = 0;
            let es = n.as_data.array_literal.elements;
            for i in 0..es.len {
                c = c + self.tc_count_lt_positions(m, unsafe (*self.mod_ast(m)).list(es)[i as usize], depth + 1);
            }
            return c;
        }
        if n.kind != NodeKind::NODE_TYPE_PATH {
            return 0;
        }
        let mut c: i32 = 0;
        let dd = unsafe (*self.mod_ast(m)).resolution_def(tyn);
        if dd.node != NODE_NONE {
            c = (unsafe (*self.mod_ast(dd.module)).lifetimes_of(dd.node).len) as i32;
        }
        let args = n.as_data.type_path.args;
        for i in 0..args.len {
            let aid = unsafe (*self.mod_ast(m)).list(args)[i as usize];
            if unsafe (*self.mod_ast(m)).at_const(aid).kind != NodeKind::NODE_LIFETIME {
                c = c + self.tc_count_lt_positions(m, aid, depth + 1);
            }
        }
        return c;
    }

    /// True when type node `tyn` has an elided lifetime position: a reference or slice with no named
    /// lifetime, or a path naming fewer lifetimes than its declaration.
    pub fn tc_has_elided_lt(self: &mut Self, m: ModuleId, tyn: NodeId, depth: i32) bool {
        if tyn == NODE_NONE || depth > 6 {
            return false;
        }
        let n = unsafe (*self.mod_ast(m)).at_const(tyn);
        if n.kind == NodeKind::NODE_REFERENCE_TYPE || n.kind == NodeKind::NODE_SLICE_TYPE {
            if self.tc_span_empty(self.tc_lt_name_in(m, n.as_data.indirect_type.lifetime)) {
                return true;
            }
            return self.tc_has_elided_lt(m, n.as_data.indirect_type.ty, depth + 1);
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            return self.tc_has_elided_lt(m, n.as_data.array_type.element, depth + 1);
        }
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            let es = n.as_data.array_literal.elements;
            for i in 0..es.len {
                if self.tc_has_elided_lt(m, unsafe (*self.mod_ast(m)).list(es)[i as usize], depth + 1) {
                    return true;
                }
            }
            return false;
        }
        if n.kind != NodeKind::NODE_TYPE_PATH {
            return false;
        }
        let args = n.as_data.type_path.args;
        let mut nlt: i32 = 0;
        for i in 0..args.len {
            let aid = unsafe (*self.mod_ast(m)).list(args)[i as usize];
            if unsafe (*self.mod_ast(m)).at_const(aid).kind == NodeKind::NODE_LIFETIME && !self.tc_span_empty(
                self.tc_lt_name_in(m, aid),
            ) {
                nlt = nlt + 1;
            }
        }
        let dd = unsafe (*self.mod_ast(m)).resolution_def(tyn);
        if dd.node != NODE_NONE && (unsafe (*self.mod_ast(dd.module)).lifetimes_of(dd.node).len) as i32 > nlt && !self.tc_path_is_self(
            m,
            tyn,
        ) {
            return true;
        }
        for i in 0..args.len {
            let aid = unsafe (*self.mod_ast(m)).list(args)[i as usize];
            if unsafe (*self.mod_ast(m)).at_const(aid).kind != NodeKind::NODE_LIFETIME && self.tc_has_elided_lt(
                m,
                aid,
                depth + 1,
            ) {
                return true;
            }
        }
        return false;
    }

    /// Report fields of aggregate `decl` whose reference types name a lifetime the declaration does not
    /// declare.
    pub fn tc_check_field_lifetimes(self: &mut Self, decl: NodeId, members: NodeList) {
        let is_tuple = unsafe (*self.cur_ast()).at_const(decl).as_data.aggregate.is_tuple;
        for i in 0..members.len {
            let mid = unsafe (*self.cur_ast()).list(members)[i as usize];
            let tn = unsafe (*self.cur_ast()).member_type_node(mid, is_tuple);
            if tn == NODE_NONE {
                continue;
            }
            self.tc_check_ref_lifetime_named(tn, 0);
        }
    }

    /// Report a lifetime position in field type node `tyn` (a reference, a slice, a borrowing
    /// aggregate's arguments) that names no lifetime (`'_` names none). The resolver rejects a name the
    /// type does not declare.
    pub fn tc_check_ref_lifetime_named(self: &mut Self, tyn: NodeId, depth: i32) {
        if tyn == NODE_NONE || depth > 6 {
            return;
        }
        let a = self.cur_ast();
        let n = unsafe (*a).at_const(tyn);
        if n.kind == NodeKind::NODE_REFERENCE_TYPE || n.kind == NodeKind::NODE_SLICE_TYPE {
            if self.tc_lt_elided(n.as_data.indirect_type.lifetime) {
                let sp = n.span;
                self.errors.emit_span(
                    sp,
                    format(
                        "missing lifetime specifier: a {} stored in a type must name a lifetime the type declares",
                        pick(n.kind == NodeKind::NODE_SLICE_TYPE, "slice", "reference"),
                    ),
                );
                self.errors.note(
                    format("declare one and use it, e.g. `struct S<'a> { r: &'a i32 }`, or borrow for `'static`"),
                );
            }
            self.tc_check_ref_lifetime_named(n.as_data.indirect_type.ty, depth + 1);
            return;
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            self.tc_check_ref_lifetime_named(n.as_data.array_type.element, depth + 1);
            return;
        }
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            let es = n.as_data.array_literal.elements;
            for i in 0..es.len {
                self.tc_check_ref_lifetime_named(unsafe (*a).list(es)[i as usize], depth + 1);
            }
            return;
        }
        if n.kind == NodeKind::NODE_TYPE_PATH {
            // A field whose type is itself a BORROWING type (`str`, `Slice<T>`, any aggregate with
            // lifetime params) must name the lifetime it borrows for, exactly as a bare reference must.
            let dd = unsafe (*a).resolution_def(tyn);
            let args = n.as_data.type_path.args;
            let mut named = false;
            for j in 0..args.len {
                let aid = unsafe (*a).list(args)[j as usize];
                if unsafe (*a).at_const(aid).kind != NodeKind::NODE_LIFETIME {
                    self.tc_check_ref_lifetime_named(aid, depth + 1);
                    continue;
                }
                named = named || !self.tc_lt_elided(aid);
            }
            if !named && dd.node != NODE_NONE && unsafe (*self.mod_ast(dd.module)).lifetimes_of(dd.node).len != 0 && !self.tc_path_is_self(
                self.cur_module(),
                tyn,
            ) {
                let sp = n.span;
                self.errors.emit_span(
                    sp,
                    format(
                        "missing lifetime specifier: this field's type borrows, so it must name the lifetime it borrows for",
                    ),
                );
            }
        }
    }

    /// True when lifetime node `lt` is absent or `'_`.
    const fn tc_lt_elided(self: &Self, lt: NodeId) bool {
        return self.tc_span_empty(self.tc_lt_name(lt));
    }

    /// True when type path `tyn` of module `m` is `Self`: its lifetimes are the ones the enclosing
    /// declaration names, so none of them is elided.
    pub const fn tc_path_is_self(self: &Self, m: ModuleId, tyn: NodeId) bool {
        let sa = self.mod_ast(m);
        let parts = unsafe (*sa).at_const(tyn).as_data.type_path.parts;
        return parts.len == 1 && span_is(
            self.mod_src(m),
            unsafe (*sa).at_const(unsafe (*sa).list(parts)[0]).as_data.name.text,
            "Self",
        );
    }

    /// Watermark into borrows[]; borrow_release_to(mark) drops the transients created since.
    pub const fn borrow_mark(self: &Self) u32 {
        return self.nborrows;
    }

    /// Report that the function under check needs more than `cap` entries in one fixed flow table
    /// (`what` names its entries): past the cap the analysis would lose facts. Reported once per
    /// function, at its name.
    @c.cold
    fn bc_flow_limit(self: &mut Self, what: str, cap: u32) {
        let a = self.cur_ast();
        let sp = self.name_span(unsafe (*a).at_const(self.icx.current_fn).as_data.function.name);
        let msg = format("this function exceeds the borrow checker's limit of {} {}", cap, what);
        for k in self.err_wm..self.errors.errors.len() {
            if self.errors.errors[k].start == sp.start && self.errors.errors[k].msg.equals(&msg) {
                return;
            }
        }
        self.errors.emit_span(sp, msg);
        self.errors.note(format("this is a compiler limitation; split the function into smaller functions"));
    }

    /// Append a borrow of `place` rooted at `root`. New borrows start TRANSIENT (binding ==
    /// NODE_NONE) until a store ties them to a binding. False when the table is full (reported).
    pub fn borrow_push(self: &mut Self, root: NodeId, kind: u8, place: NodeId, origin: NodeId) bool {
        if self.nborrows >= BC_TABLE_CAP {
            self.bc_flow_limit("live borrows", BC_TABLE_CAP);
            return false;
        }
        let k = self.nborrows;
        unsafe self.borrows[k as usize] = Borrow {
            root: root,
            place: place,
            kind: kind,
            region: self.scope_depth as u16,
            origin: origin,
            binding: NODE_NONE,
        };
        self.nborrows = k + 1;
        return true;
    }

    /// Append a copy of `b` tied to `binding` at `region` (dropped and reported when the table is full).
    fn borrow_push_bound(self: &mut Self, b: Borrow, binding: NodeId, region: u16) {
        if self.borrow_push(b.root, b.kind, b.place, b.origin) {
            let k = self.nborrows - 1;
            unsafe self.borrows[k as usize].binding = binding;
            unsafe self.borrows[k as usize].region = region;
        }
    }

    /// Record `decl` as moved, with its moved bit (reported when the table is full).
    fn bc_push_moved(self: &mut Self, decl: NodeId) {
        if self.nmoved >= BC_MOVED_CAP {
            self.bc_flow_limit("moved bindings", BC_MOVED_CAP);
            return;
        }
        let k = self.nmoved;
        unsafe self.moved[k as usize] = decl;
        self.nmoved = k + 1;
        self.ms_bit_set(decl);
    }

    /// Conflict-check, then record: a reported conflict suppresses the new borrow.
    pub fn borrow_create(self: &mut Self, place: NodeId, kind: u8, origin: NodeId) {
        let root = self.borrow_place_root(place);
        if root == NODE_NONE {
            return;
        }
        if !self.borrow_report_conflict(place, kind, origin) {
            self.borrow_push(root, kind, place, origin);
        }
    }

    /// Drop the transient (unbound) borrows at indices >= mark; bound borrows survive, compacted down.
    pub fn borrow_release_to(self: &mut Self, mark: u32) {
        if self.nborrows <= mark {
            return;
        }
        let mut w = mark;
        let mut i = mark;
        while i < self.nborrows {
            if unsafe self.borrows[i as usize].binding != NODE_NONE {
                unsafe self.borrows[w as usize] = unsafe self.borrows[i as usize];
                w = w + 1;
            }
            i = i + 1;
        }
        self.nborrows = w;
    }

    /// Tombstone entry `i` (root = NODE_NONE); every scan skips tombstones.
    pub const fn borrow_tombstone_at(self: &mut Self, i: u32) {
        unsafe self.borrows[i as usize].root = NODE_NONE;
        unsafe self.borrows[i as usize].binding = NODE_NONE;
    }

    /// Tombstone every live borrow produced by expression `origin` (a reference erased into a raw
    /// pointer).
    pub fn borrow_erase_origin(self: &mut Self, origin: NodeId) {
        if origin == NODE_NONE {
            return;
        }
        for i in 0..self.nborrows {
            if unsafe self.borrows[i as usize].origin == origin {
                self.borrow_tombstone_at(i);
            }
        }
    }

    /// True (with a diagnostic) when a live overlapping borrow conflicts with taking `kind` on
    /// `place`; provably dead borrows met on the way are tombstoned instead.
    pub fn borrow_report_conflict(self: &mut Self, place: NodeId, kind: u8, origin: NodeId) bool {
        let root = self.borrow_place_root(place);
        if root == NODE_NONE {
            return false;
        }
        for i in 0..self.nborrows {
            let b = unsafe self.borrows[i as usize];
            if b.root != root || kind == BORROW_SHARED && b.kind == BORROW_SHARED || !self.places_overlap(
                place,
                b.place,
            ) {
                continue;
            }
            // Two-phase borrow: a reserved receiver `&mut` does not conflict with a TRANSIENT shared
            // borrow this same call produced while evaluating its arguments (indices >= the watermark).
            // Those borrows were spent computing the argument values; the `&mut` only truly activates
            // once the call runs.
            if i >= self.tc_twophase_wm && b.kind == BORROW_SHARED && b.binding == NODE_NONE {
                continue;
            }
            if self.borrow_dead_after(b, origin) {
                self.borrow_tombstone_at(i);
                continue;
            }
            // The IR loan analysis owns the conflict wording.
            return true;
        }
        return false;
    }

    /// Only a live BOUND shared borrow blocks a write: transients die with their own statement.
    pub fn borrow_conflicting_write(self: &mut Self, place: NodeId, after: NodeId) bool {
        let root = self.borrow_place_root(place);
        if root == NODE_NONE {
            return false;
        }
        for i in 0..self.nborrows {
            let b = unsafe self.borrows[i as usize];
            if b.root != root || b.kind != BORROW_SHARED || b.binding == NODE_NONE || !self.places_overlap(
                place,
                b.place,
            ) {
                continue;
            }
            if self.borrow_dead_after(b, after) {
                self.borrow_tombstone_at(i);
                continue;
            }
            return true;
        }
        return false;
    }

    /// `let r2 = r1` with a reference RHS: a `&mut` borrow MOVES to the new binding (the source is
    /// marked moved: `&mut` is not duplicable); shared borrows are duplicated onto it.
    pub fn borrow_transfer_ref(self: &mut Self, init: NodeId, binding: NodeId) {
        let a = self.cur_ast();
        let e = unsafe (*a).peel(init, false);
        if unsafe (*a).at_const(e).kind != NodeKind::NODE_IDENTIFIER {
            return;
        }
        let rd = unsafe (*a).resolution_def(e);
        if rd.node == NODE_NONE || rd.module != self.cur_module() {
            return;
        }
        let n0 = self.nborrows;
        let region = self.tc_binding_depth(binding) as u16;
        let mut moved = false;
        for i in 0..n0 {
            if unsafe self.borrows[i as usize].binding == rd.node {
                if unsafe self.borrows[i as usize].kind == BORROW_MUT {
                    unsafe self.borrows[i as usize].binding = binding;
                    unsafe self.borrows[i as usize].region = region;
                    moved = true;
                } else {
                    self.borrow_push_bound(unsafe self.borrows[i as usize], binding, region);
                }
            }
        }
        if moved && !self.is_moved(rd.node) {
            self.bc_push_moved(rd.node);
        }
    }

    /// NLL last-use: true when `b`'s binding is provably unused after `after`, so the borrow may be
    /// tombstoned.
    pub fn borrow_dead_after(self: &mut Self, b: Borrow, after: NodeId) bool {
        if b.binding == NODE_NONE {
            return false;
        }
        // Inside a loop, only a binding confined to that loop's body may use source-order last-use;
        // anything longer-lived stays conservatively live across the back edge. This replaces a blanket
        // "never dead inside any loop" bail, which rejected every borrow that ended before a later
        // mutation in the same iteration.
        if self.loop_depth != 0 && !self.tc_binding_in_innermost_loop(b.binding) {
            return false;
        }
        let bn = unsafe (*self.cur_ast()).at_const(b.binding);
        if bn.kind == NodeKind::NODE_LET && unsafe (*self.cur_ast()).at_const(bn.as_data.let_stmt.name).kind == NodeKind::NODE_PATTERN_TUPLE {
            return false;
        }
        for i in 0..self.nborrows {
            if unsafe self.borrows[i as usize].binding != b.binding && self.place_through_binding(
                unsafe self.borrows[i as usize].place,
            ) == b.binding {
                return false;
            }
        }
        if !self.last_use_built {
            self.tc_build_last_use();
        }
        if self.last_use_at(b.binding as usize) > after {
            return false;
        }
        return true;
    }

    /// Per-statement NLL: after statement `si`, drop borrows bound at this scope whose binding is not
    /// mentioned again in the block; borrows reaching a kept binding are kept too. The mention scan
    /// walks node ids in (stmt id, block id): a block node is allocated after its children, so that
    /// range is exactly the later statements' subtrees.
    pub fn borrow_nll_drop(self: &mut Self, block_id: NodeId, ids: *const NodeId, si: u32) {
        if self.nborrows == 0 {
            return;
        }
        let mut keep = Keep256 {};
        for k in 0..self.nborrows {
            keep[k as usize] = true;
            let b = unsafe self.borrows[k as usize];
            if b.binding != NODE_NONE && b.region == self.scope_depth as u16 {
                let bn = unsafe (*self.cur_ast()).at_const(b.binding);
                let tuple = bn.kind == NodeKind::NODE_LET && unsafe (*self.cur_ast()).at_const(bn.as_data.let_stmt.name).kind == NodeKind::NODE_PATTERN_TUPLE;
                if !tuple {
                    keep[k as usize] = false;
                    let mut nid = unsafe ids[si as usize] + 1;
                    while nid < block_id && !keep[k as usize] {
                        let rd = unsafe (*self.cur_ast()).resolution_def(nid);
                        keep[k as usize] = rd.node == b.binding && rd.module == self.cur_module();
                        nid = nid + 1;
                    }
                }
            }
        }
        let mut kk = self.nborrows as i32 - 1;
        while kk >= 0 {
            if keep[kk as usize] {
                let thru = self.place_through_binding(unsafe self.borrows[kk as usize].place);
                if thru != NODE_NONE {
                    for j in 0..self.nborrows {
                        if unsafe self.borrows[j as usize].binding == thru {
                            keep[j as usize] = true;
                        }
                    }
                }
            }
            kk = kk - 1;
        }
        let mut w: u32 = 0;
        for k in 0..self.nborrows {
            if keep[k as usize] {
                unsafe self.borrows[w as usize] = unsafe self.borrows[k as usize];
                w = w + 1;
            }
        }
        self.nborrows = w;
    }

    /// The base binding of place expression `place` through at most PLACE_MAX_STEPS projections, or
    /// NODE_NONE.
    pub fn borrow_place_root(self: &mut Self, place: NodeId) NodeId {
        let mut steps = Steps16 {};
        let mut n: i32 = 0;
        return self.place_decompose(place, &mut steps[0], &mut n, PLACE_MAX_STEPS);
    }

    /// Escape class of what `binding`'s live borrows point at: 0 none, 1 a local, 2 a parameter
    /// (caller-owned storage). Bounded at depth 8.
    pub fn borrow_escape_of_binding(self: &mut Self, binding: NodeId, depth: u32) i32 {
        if depth > 8 {
            return 0;
        }
        let mut esc: i32 = 0;
        for i in 0..self.nborrows {
            if unsafe self.borrows[i as usize].binding == binding {
                let e = self.place_escape(unsafe self.borrows[i as usize].place, depth);
                if e == 1 {
                    return 1;
                }
                if e != 0 {
                    esc = e;
                }
            }
        }
        return esc;
    }

    /// True when two borrow records name the same root, kind, region, and origin.
    pub const fn borrow_same(self: &Self, a: Borrow, b: Borrow) bool {
        return a.root == b.root && a.kind == b.kind && a.region == b.region && a.origin == b.origin;
    }

    /// Copy the move/split-init/borrow flow state into `s` (a branch checkpoint).
    pub fn tc_flow_save(self: &Self, s: &mut FlowState) {
        s.nmoved = self.nmoved;
        for i in 0..self.nmoved {
            unsafe s.moved[i as usize] = unsafe self.moved[i as usize];
        }
        s.nlate = self.nlate;
        for i in 0..self.nlate {
            unsafe s.late[i as usize] = unsafe self.late[i as usize];
        }
        s.nborrows = self.nborrows;
        for i in 0..self.nborrows {
            unsafe s.borrows[i as usize] = unsafe self.borrows[i as usize];
        }
    }

    /// Restore the flow state saved in `s`, rebuilding the moved-bit index.
    pub fn tc_flow_set(self: &mut Self, s: &FlowState) {
        for i in 0..self.nmoved {
            self.ms_bit_clear(unsafe self.moved[i as usize]);
        }
        self.nmoved = s.nmoved;
        for i in 0..s.nmoved {
            unsafe self.moved[i as usize] = unsafe s.moved[i as usize];
            self.ms_bit_set(unsafe s.moved[i as usize]);
        }
        self.nlate = s.nlate;
        for i in 0..s.nlate {
            unsafe self.late[i as usize] = unsafe s.late[i as usize];
        }
        self.nborrows = s.nborrows;
        for i in 0..s.nborrows {
            unsafe self.borrows[i as usize] = unsafe s.borrows[i as usize];
        }
    }

    /// Reset `s` to the empty flow state.
    pub const fn tc_flow_clear(self: &Self, s: &mut FlowState) {
        s.nmoved = 0;
        s.nlate = 0;
        s.nborrows = 0;
    }

    /// Union this state's flow facts into `acc` (deduplicated). A union past a table's capacity is
    /// reported: the join would otherwise drop facts.
    pub fn tc_flow_collect(self: &mut Self, acc: *mut FlowState) {
        'm: for i in 0..self.nmoved {
            for j in 0..unsafe (*acc).nmoved {
                if unsafe (*acc).moved[j as usize] == unsafe self.moved[i as usize] {
                    continue 'm;
                }
            }
            if unsafe (*acc).nmoved < BC_MOVED_CAP {
                let k = unsafe (*acc).nmoved;
                unsafe (*acc).moved[k as usize] = unsafe self.moved[i as usize];
                unsafe (*acc).nmoved = k + 1;
            } else {
                self.bc_flow_limit("moved bindings", BC_MOVED_CAP);
            }
        }
        'l: for i in 0..self.nlate {
            for j in 0..unsafe (*acc).nlate {
                if unsafe (*acc).late[j as usize] == unsafe self.late[i as usize] {
                    continue 'l;
                }
            }
            if unsafe (*acc).nlate < BC_TABLE_CAP {
                let k = unsafe (*acc).nlate;
                unsafe (*acc).late[k as usize] = unsafe self.late[i as usize];
                unsafe (*acc).nlate = k + 1;
            } else {
                self.bc_flow_limit("split-initialized bindings", BC_TABLE_CAP);
            }
        }
        'b: for i in 0..self.nborrows {
            for j in 0..unsafe (*acc).nborrows {
                if self.borrow_same(unsafe (*acc).borrows[j as usize], unsafe self.borrows[i as usize]) {
                    continue 'b;
                }
            }
            if unsafe (*acc).nborrows < BC_TABLE_CAP {
                let k = unsafe (*acc).nborrows;
                unsafe (*acc).borrows[k as usize] = unsafe self.borrows[i as usize];
                unsafe (*acc).nborrows = k + 1;
            } else {
                self.bc_flow_limit("live borrows", BC_TABLE_CAP);
            }
        }
    }

    /// The move rule the Core IR cannot see: moving an owning `const` out through a `.free()`
    /// receiver is an error. Every other move check belongs to the Core IR move
    /// analysis and free-move rules.
    pub fn tc_mark_move(self: &mut Self, expr0: NodeId) {
        if expr0 == NODE_NONE {
            return;
        }
        let a = self.cur_ast();
        let expr = unsafe (*a).peel(expr0, false);
        let xk = unsafe (*a).at_const(expr).kind;
        // A constant is named bare (`V`) or qualified (`data::V`); both must reach the const rule below.
        let path_const = xk == NodeKind::NODE_MEMBER && unsafe (*a).at_const(expr).as_data.member.path;
        if xk != NodeKind::NODE_IDENTIFIER && !path_const {
            return;
        }
        let mut d = unsafe (*a).resolution_def(expr);
        if d.node == NODE_NONE && path_const {
            d = unsafe (*a).resolution_def(unsafe (*a).at_const(expr).as_data.member.member);
        }
        if d.node == NODE_NONE {
            return;
        }
        // A `const` is checked WHEREVER it was declared: an owning one imported from another module is
        // the same hazard, and skipping foreign decls let a copy of it reach a free().
        if d.module != self.cur_module() && d.module as usize >= self.pkg_count() {
            return;
        }
        if unsafe (*self.mod_ast(d.module)).at_const(d.node).kind != NodeKind::NODE_CONST {
            return;
        }
        // An owning `const` stays put: read it or borrow it, never move it. A local one is a runtime
        // value freed at scope exit, so a copy would double-free; a top-level one lives in the binary,
        // so a copy would free storage the allocator never handed out.
        let cd = unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.const_def;
        // A `.free()` receiver reaches the IR as a `&mut` temp, never a marked move: its const check
        // stays here even when the IR rules are authoritative. So does a call FOLDED to its value:
        // the fold erased the move from the IR.
        if !cd.is_static_mut && !cd.is_extern && self.tc_type_is_free(unsafe (*a).type_of(expr)) {
            let sp = unsafe (*a).at_const(expr).span;
            self.errors.emit_span(sp, format("cannot move a value out of a 'const' binding"));
            self.errors.note(
                format(
                    "a constant of an owning type is read or borrowed, never moved: the copy would free storage the constant still owns",
                ),
            );
        }
    }

    /// Revive `decl` after a store: remove one moved entry and clear its bit once no duplicate remains.
    pub fn tc_unmark_move(self: &mut Self, decl: NodeId) {
        let mut i: u32 = 0;
        while i < self.nmoved {
            if unsafe self.moved[i as usize] == decl {
                self.nmoved = self.nmoved - 1;
                unsafe self.moved[i as usize] = unsafe self.moved[self.nmoved as usize];
                break;
            }
            i = i + 1;
        }
        // Moved[] can hold duplicates (closure captures push unguarded): only drop the bit once
        // no entry remains.
        let mut still = false;
        i = 0;
        while i < self.nmoved {
            if unsafe self.moved[i as usize] == decl {
                still = true;
                break;
            }
            i = i + 1;
        }
        if !still {
            self.ms_bit_clear(decl);
        }
    }

    /// O(1) membership: moved_bits is a bitset over the dense node index mirroring moved[] (duplicates share one bit).
    pub const fn is_moved(self: &Self, decl: NodeId) bool {
        let dk = unsafe (*self.cur_ast()).dense(decl);
        let idx = dk >> 6;
        if idx >= self.moved_bits.len() {
            return false;
        }
        return (self.moved_bits[idx] >> (dk & 63) as u64 & 1u64) != 0u64;
    }

    /// Set `d`'s moved bit, growing the bitset on demand.
    pub fn ms_bit_set(self: &mut Self, d: NodeId) {
        let dk = unsafe (*self.cur_ast()).dense(d);
        let idx = dk >> 6;
        while self.moved_bits.len() <= idx {
            self.moved_bits.push(0u64);
        }
        self.moved_bits.set(idx, self.moved_bits[idx] | 1u64 << (dk & 63) as u64);
    }

    /// Clear `d`'s moved bit; a no-op when the bitset is shorter.
    pub const fn ms_bit_clear(self: &mut Self, d: NodeId) {
        let dk = unsafe (*self.cur_ast()).dense(d);
        let idx = dk >> 6;
        if idx < self.moved_bits.len() {
            self.moved_bits.set(idx, self.moved_bits[idx] & ~(1u64 << (dk & 63) as u64));
        }
    }

    /// Leave the current scope: drop every borrow whose region is this scope, keeping borrows rooted in
    /// reference bindings that point outward.
    pub fn tc_scope_exit(self: &mut Self) {
        let d = self.scope_depth;
        let mut w: u32 = 0;
        for i in 0..self.nborrows {
            let b = unsafe self.borrows[i as usize];
            if b.region as u32 >= d {
                continue;
            }
            // A borrow whose ROOT is a reference-typed binding borrows that reference's REFERENT, and
            // a reference cannot outlive what it points at, so leaving this scope destroys the
            // reference variable, not the data (`td: &JSON` bound from a parameter stays valid).
            // Whenever such a reference does borrow a local, that local is the root of its OWN borrow
            // and is still reported here, so this is not a hole.
            if b.root != NODE_NONE && self.tc_root_is_reference(b.root) {
                unsafe self.borrows[w as usize] = unsafe self.borrows[i as usize];
                w = w + 1;
                continue;
            }
            if b.binding != NODE_NONE && b.root != NODE_NONE && self.tc_binding_depth(b.root) >= d {
                // The loan solver owns the block-scope dangle wording.
                continue;
            }
            unsafe self.borrows[w as usize] = unsafe self.borrows[i as usize];
            w = w + 1;
        }
        self.nborrows = w;
        if self.scope_depth != 0 {
            self.scope_depth = self.scope_depth - 1;
        }
    }

    /// Record that `decl` was bound at the current scope depth.
    pub fn tc_record_binding_depth(self: &mut Self, decl: NodeId) {
        if decl != NODE_NONE {
            self.binding_depth.insert(decl, self.scope_depth);
        }
    }

    /// The scope depth `decl` was bound at; 0 for parameters and unknown bindings.
    pub fn tc_binding_depth(self: &Self, decl: NodeId) u32 {
        if decl == NODE_NONE || unsafe (*self.cur_ast()).at_const(decl).kind == NodeKind::NODE_PARAMETER {
            return 0;
        }
        switch self.binding_depth.get(&decl) {
            Some(v) => {
                return *v;
            },
            _ => {},
        };
        return 0;
    }

    /// True when `binding` was bound inside the innermost enclosing loop body.
    pub fn tc_binding_in_innermost_loop(self: &Self, binding: NodeId) bool {
        if self.nloops == 0 {
            return false;
        }
        return self.tc_binding_depth(binding) > unsafe self.loop_stack[(self.nloops - 1) as usize].depth;
    }

    /// Escape class of `e0` used as an address/reference source: 0 = none, 1 = borrows a local,
    /// 2 = borrows a by-value parameter.
    pub fn addr_escape_at(self: &mut Self, e0: NodeId, depth: u32) i32 {
        let a = self.cur_ast();
        let e = unsafe (*a).peel(e0, true);
        let n = unsafe (*a).at_const(e);
        if n.kind == NodeKind::NODE_UNARY && n.as_data.unary.op == TokenType::Ampersand {
            return self.place_escape(n.as_data.unary.operand, depth);
        }
        if n.kind == NodeKind::NODE_IDENTIFIER && depth < BORROW_ESCAPE_MAX_DEPTH {
            let d = unsafe (*a).resolution_def(e);
            if d.module == self.cur_module() && d.node != NODE_NONE {
                let dn = unsafe (*a).at_const(d.node);
                let dt = unsafe (*a).type_of(d.node);
                if dt != TYPE_NONE && self.type_at(dt).kind == TypeKind::TYPE_REFERENCE {
                    return self.borrow_escape_of_binding(d.node, depth);
                }
                if dn.kind == NodeKind::NODE_LET && dn.as_data.let_stmt.value != NODE_NONE {
                    return self.addr_escape_at(dn.as_data.let_stmt.value, depth + 1);
                }
            }
        }
        return 0;
    }

    /// Escape class of storing a borrow of `place`: 0 none (through a parameter reference), 1 a local,
    /// 2 a parameter.
    pub fn place_escape(self: &mut Self, place: NodeId, depth: u32) i32 {
        let mut steps = Steps16 {};
        let mut ns: i32 = 0;
        let root = self.place_decompose(place, &mut steps[0], &mut ns, PLACE_MAX_STEPS);
        if root == NODE_NONE {
            return 0;
        }
        let mut thru = false;
        for i in 0..ns {
            if steps[i as usize].kind == PS_DEREF {
                thru = true;
            }
        }
        if thru {
            if unsafe (*self.cur_ast()).at_const(root).kind == NodeKind::NODE_PARAMETER {
                return 0;
            }
            return self.borrow_escape_of_binding(root, depth + 1);
        }
        if unsafe (*self.cur_ast()).at_const(root).kind == NodeKind::NODE_PARAMETER {
            return 2;
        }
        return 1;
    }

    /// The lifetime slots a type NODE denotes, in order: `&'l T` and `[]'l T` -> ['l]; an aggregate
    /// `S<'l, ..>` -> its lifetime args. Returns the count; fills `out` (up to `cap`). This is the
    /// structural lifetime vector of a signature type, which relates a returned value's lifetimes to
    /// the return type's.
    pub fn tc_collect_slot_lts(self: &mut Self, m: ModuleId, tyn: NodeId, out: &mut Spans8) i32 {
        if tyn == NODE_NONE {
            return 0;
        }
        let k = unsafe (*self.mod_ast(m)).at_const(tyn).kind;
        if k == NodeKind::NODE_REFERENCE_TYPE || k == NodeKind::NODE_SLICE_TYPE {
            out[0] = self.tc_lt_name_in(m, unsafe (*self.mod_ast(m)).at_const(tyn).as_data.indirect_type.lifetime);
            return 1;
        }
        let mut n = self.tc_collect_lt_args(m, tyn, out);
        if k != NodeKind::NODE_TYPE_PATH || self.tc_path_is_self(m, tyn) {
            return n;
        }
        // Lifetime params the path leaves unwritten are elided slots.
        let dd = unsafe (*self.mod_ast(m)).resolution_def(tyn);
        if dd.node == NODE_NONE {
            return n;
        }
        let nlt = (unsafe (*self.mod_ast(dd.module)).lifetimes_of(dd.node).len) as i32;
        while n < nlt && n as usize < out.len() {
            out[n as usize] = tok::Span { start: 0, end: 0 };
            n = n + 1;
        }
        return n;
    }

    /// The lifetime a return TYPE node denotes overall (first slot), for call-site precision.
    /// `m` is the module whose ast `ret_tyn` indexes: the CALLEE's for a cross-module call; a
    /// foreign id read against the caller's pool answers from unrelated storage (or past its end).
    pub fn tc_return_dest_lifetime(self: &mut Self, m: ModuleId, ret_tyn: NodeId) tok::Span {
        let mut dest = Spans8 {};
        let n = self.tc_collect_slot_lts(m, ret_tyn, &mut dest);
        if n > 0 {
            return dest[0];
        }
        return tok::Span { start: 0, end: 0 };
    }

    /// MODULAR definition-site check: each lifetime a returned value borrows for must be DECLARED to
    /// outlive the return type's lifetime in the same slot, using only the signature's outlives edges:
    /// exactly Rust's rule. `fn f<'a,'b>(x:&'a,y:&'b) &'a { return y; }` (and its aggregate form) needs
    /// `'b: 'a`; without it the body does not honour its signature, so it is wrong at the DEFINITION
    /// regardless of any caller. This is what lets call sites TRUST the signature (relate_result_precision)
    /// instead of tying the result to every argument. An elided input lifetime is its own anonymous
    /// region: only `'static` outlives it and it outlives nothing else. An elided output slot is the
    /// elision source's lifetime.
    pub fn tc_check_return_lifetime(self: &mut Self, vid: NodeId, ret_tyn: NodeId) {
        let mut dest = Spans8 {};
        let nd = self.tc_collect_slot_lts(self.cur_module(), ret_tyn, &mut dest);
        if nd == 0 {
            return;
        }
        let ptyn = self.tc_returned_param_typenode(self.cur_module(), vid);
        if ptyn == NODE_NONE {
            return;
        }
        let mut src = Spans8 {};
        let ns = self.tc_collect_slot_lts(self.cur_module(), ptyn, &mut src);
        let mut n = nd;
        if ns < n {
            n = ns;
        }
        let a = self.cur_ast();
        for i in 0..n {
            let mut d = dest[i as usize];
            if self.tc_span_empty(d) {
                // Rule 3 or 2 gives the slot the source parameter's lifetime; returning that parameter
                // itself matches. Without a source the elision check already reported the signature.
                let es = self.tc_elision_source(self.icx.current_fn);
                if es < 0 {
                    continue;
                }
                let params = unsafe (*a).at_const(self.icx.current_fn).as_data.function.params;
                let etyn = unsafe (*a).at_const(unsafe (*a).list(params)[es as usize]).as_data.parameter.ty;
                let mut es_lts = Spans8 {};
                if etyn == ptyn || self.tc_collect_slot_lts(self.cur_module(), etyn, &mut es_lts) == 0 {
                    continue;
                }
                d = es_lts[0];
            }
            if !self.tc_lifetime_outlives(src[i as usize], d) {
                self.tc_return_lifetime_diag(vid);
                return;
            }
        }
    }

    /// Report returned value `vid` whose lifetime is not declared to outlive the return type's.
    fn tc_return_lifetime_diag(self: &mut Self, vid: NodeId) {
        let sp = unsafe (*self.cur_ast()).at_const(vid).span;
        let di = self.tc_region_diag(
            sp.start,
            sp.end - sp.start,
            format(
                "lifetime mismatch: the returned value's lifetime is not declared to outlive the return type's lifetime",
            ),
        );
        self.tc_region_note(
            di,
            format(
                "declare the relationship in the signature, e.g. add `'b: 'a` where the argument's lifetime must outlive the return",
            ),
        );
    }

    /// A fresh RegionVid.
    pub const fn region_new(self: &mut Self) u32 {
        let r = self.region_next;
        self.region_next = r + 1;
        return r;
    }

    /// Fresh region universe for `fnid`: a region per declared lifetime plus its declared outlives edges.
    pub fn region_reset(self: &mut Self, fnid: NodeId) {
        self.region_next = REGION_STATIC + 1;
        if fnid == NODE_NONE {
            return;
        }
        self.outlives.clear();
        let lts = unsafe (*self.cur_ast()).lifetimes_of(fnid);
        for i in 0..lts.len {
            let lp = unsafe (*self.cur_ast()).list(lts)[i as usize];
            let r = self.region_new();
            self.lt_region.insert(lp, r);
        }
        // Seed the declared outlives edges: `<'a: 'b>` param bounds and `where 'a: 'b` predicates.
        for i in 0..lts.len {
            let lp = unsafe (*self.cur_ast()).list(lts)[i as usize];
            let sup = self.tc_lt_region_of_name(self.tc_lt_name(lp));
            let bnds = unsafe (*self.cur_ast()).at_const(lp).as_data.generic_param.bounds;
            for b in 0..bnds.len {
                let bid = unsafe (*self.cur_ast()).list(bnds)[b as usize];
                self.region_add_outlives(sup, self.tc_lt_region_of_name(self.tc_lt_name(bid)));
            }
        }
        let wc = unsafe (*self.cur_ast()).at_const(fnid).as_data.function.where_clause;
        for w in 0..wc.len {
            let wp = unsafe (*self.cur_ast()).at_const(unsafe (*self.cur_ast()).list(wc)[w as usize]).as_data.where_predicate;
            if unsafe (*self.cur_ast()).at_const(wp.ty).kind != NodeKind::NODE_LIFETIME {
                continue;
            }
            let sup = self.tc_lt_region_of_name(self.tc_lt_name(wp.ty));
            for b in 0..wp.bounds.len {
                let bid = unsafe (*self.cur_ast()).list(wp.bounds)[b as usize];
                if unsafe (*self.cur_ast()).at_const(bid).kind == NodeKind::NODE_LIFETIME {
                    self.region_add_outlives(sup, self.tc_lt_region_of_name(self.tc_lt_name(bid)));
                }
            }
        }
    }

    /// The RegionVid a lifetime name denotes in the current function: REGION_STATIC for `'static`,
    /// REGION_NONE when undeclared.
    pub fn tc_lt_region_of_name(self: &Self, name: tok::Span) u32 {
        if self.tc_span_empty(name) {
            return REGION_NONE;
        }
        // `'static` is not a declared parameter: it is THE universal region that outlives every other,
        // so it needs no signature entry and is available in any function.
        if span_is(self.source, name, "'static") {
            return REGION_STATIC;
        }
        if self.icx.current_fn == NODE_NONE {
            return REGION_NONE;
        }
        let a = self.cur_ast();
        let lts = unsafe (*a).lifetimes_of(self.icx.current_fn);
        for i in 0..lts.len {
            let lp = unsafe (*a).list(lts)[i as usize];
            if spans_eq2(self.source, self.tc_lt_name(lp), self.source, name) {
                switch self.lt_region.get(&lp) {
                    Some(v) => {
                        return *v;
                    },
                    _ => {},
                };
            }
        }
        return REGION_NONE;
    }

    /// Record the declared edge `sup: sub` (sup outlives sub); trivial or REGION_NONE edges are
    /// dropped.
    pub fn region_add_outlives(self: &mut Self, sup: u32, sub: u32) {
        if sup == REGION_NONE || sub == REGION_NONE || sup == sub {
            return;
        }
        self.outlives.push(sup as u64 << 32 | sub as u64);
    }

    /// Reflexive-transitive over declared edges ('static outlives all); the DFS caps at 32 regions
    /// and fails closed.
    pub fn region_outlives(self: &Self, a: u32, b: u32) bool {
        if a == REGION_NONE || b == REGION_NONE {
            return false;
        }
        if a == b || a == REGION_STATIC {
            return true;
        }
        let mut stack = Regions32 {};
        let mut seen = Regions32 {};
        let mut ns: u32 = 0;
        let mut nseen: u32 = 0;
        stack[0] = a;
        ns = 1;
        while ns > 0 {
            ns = ns - 1;
            let cur = stack[ns as usize];
            if cur == b {
                return true;
            }
            let mut dup = false;
            for i in 0..nseen {
                if seen[i as usize] == cur {
                    dup = true;
                }
            }
            if dup {
                continue;
            }
            if nseen >= 32 {
                return false;
            }
            seen[nseen as usize] = cur;
            nseen = nseen + 1;
            for i in 0..self.outlives.len() {
                let e = self.outlives[i];
                if (e >> 32) as u32 != cur {
                    continue;
                }
                if ns >= 32 {
                    return false;
                }
                stack[ns as usize] = e as u32;
                ns = ns + 1;
            }
        }
        return false;
    }

    /// True when lifetime name `src` provably outlives `dst`: `'static` (which outlives every lifetime,
    /// an elided one too), the same name, or a path in the declared outlives graph.
    pub fn tc_lifetime_outlives(self: &mut Self, src: tok::Span, dst: tok::Span) bool {
        if span_is(self.source, src, "'static") {
            return true;
        }
        if self.tc_span_empty(src) || self.tc_span_empty(dst) {
            return false;
        }
        if spans_eq2(self.source, src, self.source, dst) {
            return true;
        }
        return self.region_outlives(self.tc_lt_region_of_name(src), self.tc_lt_region_of_name(dst));
    }

    /// `C<'a>` is a subtype of `C<'b>` only if 'a and 'b relate per C's variance in that slot:
    /// covariant needs 'a: 'b, contravariant 'b: 'a, invariant both directions. Inferred by rustc's
    /// algorithm over the field types: `&T` covariant, `&mut T` invariant in the pointee, a nested
    /// aggregate composes with ITS variance, fn params contravariant. Lazy + memoized; a recursion
    /// cycle resolves to all-invariant (sound: over-restricts only recursive types).
    pub const fn v_flip(self: &Self, v: u32) u32 {
        // Bit 0 is a covariant use and bit 1 a contravariant one (V_* values): flipping swaps them.
        return (v >> 1 | v << 1) & 3;
    }

    /// Lattice join of two variances (BIVARIANT is the identity, mismatches become INVARIANT).
    pub const fn v_join(self: &Self, a: u32, b: u32) u32 {
        // The union of the use bits (see v_flip): BIVARIANT (0) is the identity, COVARIANT | CONTRAVARIANT
        // is INVARIANT.
        return a | b;
    }

    /// The variance of a position with variance `v` nested inside a context of variance `ctx`.
    pub const fn v_transform(self: &Self, ctx: u32, v: u32) u32 {
        if ctx == V_COVARIANT {
            return v;
        }
        if ctx == V_CONTRAVARIANT {
            return self.v_flip(v);
        }
        if ctx == V_BIVARIANT || v == V_BIVARIANT {
            return V_BIVARIANT;
        }
        return V_INVARIANT;
    }

    /// Number of lifetime params declared by aggregate `dd`.
    pub fn variance_nlt(self: &Self, dd: DefId) i32 {
        return (unsafe (*self.mod_ast(dd.module)).lifetimes_of(dd.node).len) as i32;
    }

    /// Number of variance slots of aggregate `dd`: lifetime params then type params.
    pub fn variance_nparams(self: &Self, dd: DefId) i32 {
        let sa = self.mod_ast(dd.module);
        let nk = unsafe (*sa).at_const(dd.node).kind;
        let mut nty: i32 = 0;
        if nk == NodeKind::NODE_STRUCT || nk == NodeKind::NODE_ENUM {
            nty = (unsafe (*sa).at_const(dd.node).as_data.aggregate.generics.len) as i32;
        }
        return self.variance_nlt(dd) + nty;
    }

    /// `packed` with slot `idx` set to `v` (2 bits per slot); indexes past 32 leave it unchanged.
    pub const fn variance_pack_set(self: &Self, packed: u64, idx: i32, v: u32) u64 {
        if idx < 0 || idx >= 32 {
            return packed;
        }
        let sh = (idx * 2) as u64;
        let cur = (packed >> sh & 0x3u64) as u32;
        let nv = self.v_join(cur, v);
        return packed & ~(0x3u64 << sh) | nv as u64 << sh;
    }

    /// The packed variance vector with every slot of `dd` INVARIANT (the conservative answer).
    pub fn variance_all_invariant(self: &Self, dd: DefId) u64 {
        let n = self.variance_nparams(dd);
        let mut packed: u64 = 0;
        let mut i: i32 = 0;
        while i < n && i < 32 {
            packed = packed | V_INVARIANT as u64 << (i * 2) as u64;
            i = i + 1;
        }
        return packed;
    }

    /// The inferred variance of slot `idx` of aggregate `dd`; INVARIANT past 32 slots.
    pub fn variance_param(self: &mut Self, dd: DefId, idx: i32) u32 {
        if idx < 0 || idx >= 32 {
            return V_INVARIANT;
        }
        return (self.variance_infer(dd) >> (idx * 2) as u64 & 0x3u64) as u32;
    }

    /// Index in the packed variance of the lifetime param named `name` in `dd`, or -1 (outer/'static).
    pub fn variance_lt_index(self: &Self, dd: DefId, name: tok::Span) i32 {
        if self.tc_span_empty(name) {
            return -1;
        }
        let sa = self.mod_ast(dd.module);
        let lts = unsafe (*sa).lifetimes_of(dd.node);
        for i in 0..lts.len {
            let lp = unsafe (*sa).list(lts)[i as usize];
            if spans_eq2(self.mod_src(dd.module), self.tc_lt_name_in(dd.module, lp), self.mod_src(dd.module), name) {
                return i as i32;
            }
        }
        return -1;
    }

    /// Index of the type param `dd`'s field-type-path `tyn` names, or -1 if it names another aggregate.
    pub fn variance_ty_index(self: &Self, dd: DefId, tyn: NodeId) i32 {
        let sa = self.mod_ast(dd.module);
        let rd = unsafe (*sa).resolution_def(tyn);
        if rd.node == NODE_NONE || rd.module != dd.module {
            return -1;
        }
        let gens = unsafe (*sa).at_const(dd.node).as_data.aggregate.generics;
        for j in 0..gens.len {
            if unsafe (*sa).list(gens)[j as usize] == rd.node {
                return self.variance_nlt(dd) + j as i32;
            }
        }
        return -1;
    }

    /// The packed variance vector of aggregate `dd`, inferred from its field types and memoized; a
    /// recursive query answers INVARIANT.
    pub fn variance_infer(self: &mut Self, dd: DefId) u64 {
        if dd.node == NODE_NONE {
            return 0;
        }
        let key = dd.module as u64 << 32 | dd.node as u64;
        switch self.variance_of.get(&key) {
            Some(v) => {
                return *v;
            },
            None => {},
        };
        switch self.variance_wip.get(&key) {
            Some(_) => {
                return self.variance_all_invariant(dd);
            },
            None => {},
        };
        let nk = unsafe (*self.mod_ast(dd.module)).at_const(dd.node).kind;
        if nk != NodeKind::NODE_STRUCT && nk != NodeKind::NODE_ENUM {
            self.variance_of.insert(key, 0);
            return 0;
        }
        self.variance_wip.insert(key, true);
        let mut packed: u64 = 0;
        let is_tuple = unsafe (*self.mod_ast(dd.module)).at_const(dd.node).as_data.aggregate.is_tuple;
        let members = unsafe (*self.mod_ast(dd.module)).at_const(dd.node).as_data.aggregate.members;
        for i in 0..members.len {
            let mid = unsafe (*self.mod_ast(dd.module)).list(members)[i as usize];
            let mk = unsafe (*self.mod_ast(dd.module)).at_const(mid).kind;
            if mk == NodeKind::NODE_FIELD || is_tuple {
                let tn = unsafe (*self.mod_ast(dd.module)).member_type_node(mid, is_tuple);
                packed = self.variance_walk(dd, tn, V_COVARIANT, packed, 0);
            } else if mk == NodeKind::NODE_VARIANT {
                let pl = unsafe (*self.mod_ast(dd.module)).at_const(mid).as_data.variant.payload;
                for p in 0..pl.len {
                    packed = self.variance_walk(
                        dd,
                        unsafe (*self.mod_ast(dd.module)).list(pl)[p as usize],
                        V_COVARIANT,
                        packed,
                        0,
                    );
                }
            }
        }
        self.variance_wip.remove(&key);
        self.variance_of.insert(key, packed);
        return packed;
    }

    /// Fold every occurrence of one of `dd`'s params in the field type node `tyn` (a node in dd.module)
    /// into `packed`, under the accumulated context variance `ctx`.
    pub fn variance_walk(self: &mut Self, dd: DefId, tyn: NodeId, ctx: u32, packed: u64, depth: i32) u64 {
        if tyn == NODE_NONE || depth > 8 || ctx == V_BIVARIANT {
            return packed;
        }
        let sa = self.mod_ast(dd.module);
        let n = unsafe (*sa).at_const(tyn);
        let nk = n.kind;
        if nk == NodeKind::NODE_LIFETIME {
            return self.variance_pack_set(packed, self.variance_lt_index(dd, self.tc_lt_name_in(dd.module, tyn)), ctx);
        }
        if nk == NodeKind::NODE_REFERENCE_TYPE || nk == NodeKind::NODE_SLICE_TYPE {
            let mut p = packed;
            let lifen = n.as_data.indirect_type.lifetime;
            if nk == NodeKind::NODE_REFERENCE_TYPE && lifen != NODE_NONE {
                p = self.variance_pack_set(p, self.variance_lt_index(dd, self.tc_lt_name_in(dd.module, lifen)), ctx);
            }
            let mut inner = ctx;
            if n.as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_MUT {
                inner = self.v_transform(ctx, V_INVARIANT);
            }
            return self.variance_walk(dd, n.as_data.indirect_type.ty, inner, p, depth + 1);
        }
        if nk == NodeKind::NODE_POINTER_TYPE {
            // Raw pointer: regions/borrows erased; no lifetime slot, so variance is moot.
            return packed;
        }
        if nk == NodeKind::NODE_ARRAY_TYPE {
            return self.variance_walk(dd, n.as_data.array_type.element, ctx, packed, depth + 1);
        }
        if nk == NodeKind::NODE_TUPLE_TYPE {
            let mut p = packed;
            let es = n.as_data.array_literal.elements;
            for i in 0..es.len {
                p = self.variance_walk(dd, unsafe (*sa).list(es)[i as usize], ctx, p, depth + 1);
            }
            return p;
        }
        if nk == NodeKind::NODE_FUNCTION_TYPE {
            let mut p = packed;
            let ps = n.as_data.function_type.params;
            for i in 0..ps.len {
                p = self.variance_walk(
                    dd,
                    unsafe (*sa).list(ps)[i as usize],
                    self.v_transform(ctx, V_CONTRAVARIANT),
                    p,
                    depth + 1,
                );
            }
            let rs = n.as_data.function_type.returns;
            for i in 0..rs.len {
                p = self.variance_walk(dd, unsafe (*sa).list(rs)[i as usize], ctx, p, depth + 1);
            }
            return p;
        }
        if nk == NodeKind::NODE_TYPE_PATH {
            let tidx = self.variance_ty_index(dd, tyn);
            if tidx >= 0 {
                return self.variance_pack_set(packed, tidx, ctx);
            }
            let rd = unsafe (*sa).resolution_def(tyn);
            let args = n.as_data.type_path.args;
            if rd.node == NODE_NONE || args.len == 0 {
                return packed;
            }
            let ncalleeLt = self.variance_nlt(rd);
            let mut p = packed;
            let mut lti: i32 = 0;
            let mut tyi: i32 = 0;
            for i in 0..args.len {
                let aid = unsafe (*sa).list(args)[i as usize];
                let mut cvar: u32 = V_INVARIANT;
                if unsafe (*sa).at_const(aid).kind == NodeKind::NODE_LIFETIME {
                    cvar = self.variance_param(rd, lti);
                    lti = lti + 1;
                } else {
                    cvar = self.variance_param(rd, ncalleeLt + tyi);
                    tyi = tyi + 1;
                }
                p = self.variance_walk(dd, aid, self.v_transform(ctx, cvar), p, depth + 1);
            }
            return p;
        }
        return packed;
    }

    /// The lifetime name of the reference `value` evaluates to (through casts, `move`, `unsafe`), or
    /// the empty span.
    pub fn tc_value_source_lifetime(self: &mut Self, value: NodeId) tok::Span {
        let p = self.tc_ident_ref_param(value);
        if p == NODE_NONE {
            return tok::Span { start: 0, end: 0 };
        }
        return self.tc_ref_typenode_lt(unsafe (*self.cur_ast()).at_const(p).as_data.parameter.ty);
    }

    /// The lifetime arguments written on type path `tyn` of module `m` into `out` (at most 8); returns
    /// the count.
    pub fn tc_collect_lt_args(self: &Self, m: ModuleId, tyn: NodeId, out: &mut Spans8) i32 {
        if tyn == NODE_NONE || unsafe (*self.mod_ast(m)).at_const(tyn).kind != NodeKind::NODE_TYPE_PATH {
            return 0;
        }
        let args = unsafe (*self.mod_ast(m)).at_const(tyn).as_data.type_path.args;
        let mut n: i32 = 0;
        for i in 0..args.len {
            let aid = unsafe (*self.mod_ast(m)).list(args)[i as usize];
            if unsafe (*self.mod_ast(m)).at_const(aid).kind == NodeKind::NODE_LIFETIME && n as usize < out.len() {
                out[n as usize] = self.tc_lt_name_in(m, aid);
                n = n + 1;
            }
        }
        return n;
    }

    /// The first lifetime argument written on parameter type node `ptyn` (through references), or the
    /// empty span.
    pub fn tc_container_elem_lt(self: &Self, m: ModuleId, ptyn: NodeId) tok::Span {
        if ptyn == NODE_NONE {
            return tok::Span { start: 0, end: 0 };
        }
        let n = unsafe (*self.mod_ast(m)).at_const(ptyn);
        if n.kind == NodeKind::NODE_REFERENCE_TYPE {
            return self.tc_container_elem_lt(m, n.as_data.indirect_type.ty);
        }
        if n.kind == NodeKind::NODE_TYPE_PATH {
            let args = n.as_data.type_path.args;
            for i in 0..args.len {
                let aid = unsafe (*self.mod_ast(m)).list(args)[i as usize];
                if unsafe (*self.mod_ast(m)).at_const(aid).kind == NodeKind::NODE_REFERENCE_TYPE {
                    return self.tc_lt_name_in(m, unsafe (*self.mod_ast(m)).at_const(aid).as_data.indirect_type.lifetime);
                }
            }
        }
        return tok::Span { start: 0, end: 0 };
    }

    /// The reference-typed parameter that argument expression `arg0` names directly (through casts,
    /// `move`, `unsafe`), or NODE_NONE.
    pub fn tc_ident_ref_param(self: &mut Self, arg0: NodeId) NodeId {
        let a = self.cur_ast();
        let e = unsafe (*a).peel(arg0, true);
        if unsafe (*a).at_const(e).kind != NodeKind::NODE_IDENTIFIER {
            return NODE_NONE;
        }
        let d = unsafe (*a).resolution_def(e);
        if d.module != self.cur_module() || d.node == NODE_NONE || !self.tc_is_ref_param(d.node) {
            return NODE_NONE;
        }
        return d.node;
    }

    /// True when `node` is a parameter declared with a reference type.
    pub fn tc_is_ref_param(self: &mut Self, node: NodeId) bool {
        if node == NODE_NONE {
            return false;
        }
        let a = self.cur_ast();
        if unsafe (*a).at_const(node).kind != NodeKind::NODE_PARAMETER {
            return false;
        }
        let tyn = unsafe (*a).at_const(node).as_data.parameter.ty;
        if tyn == NODE_NONE {
            return false;
        }
        let t = self.lower_type_in(self.cur_module(), tyn);
        return t != TYPE_NONE && self.type_at(t).kind == TypeKind::TYPE_REFERENCE;
    }

    /// The binding a `&place` / `&mut place` argument borrows, or the argument's own base binding;
    /// NODE_NONE when neither.
    pub fn tc_ref_arg_referent(self: &Self, arg0: NodeId) NodeId {
        let a = self.cur_ast();
        let e = unsafe (*a).peel(arg0, true);
        let n = unsafe (*a).at_const(e);
        if n.kind == NodeKind::NODE_UNARY && n.as_data.unary.op == TokenType::Ampersand {
            return self.tc_place_base_binding(n.as_data.unary.operand);
        }
        return self.tc_place_base_binding(e);
    }

    /// True when `elem` is generic param `(vm, vd)` itself or an aggregate instantiated with it.
    pub fn tc_ref_covers_generic(self: &mut Self, elem: TypeId, vd: NodeId, vm: ModuleId) bool {
        if elem == TYPE_NONE {
            return false;
        }
        if self.type_at(elem).kind == TypeKind::TYPE_GENERIC && self.type_at(elem).as_data.decl == vd && self.type_at(
            elem,
        ).module == vm {
            return true;
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if self.aggregate_of(self.strip(elem), &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
            for gi in 0..gn {
                let g = ga[gi as usize];
                if self.type_at(g).kind == TypeKind::TYPE_GENERIC && self.type_at(g).as_data.decl == vd && self.type_at(
                    g,
                ).module == vm {
                    return true;
                }
            }
        }
        return false;
    }

    /// Append every lifetime name written in type node `tyn` to `out` (at most 8, `*n` is the fill
    /// count).
    pub fn tc_typenode_lifetimes(self: &Self, m: ModuleId, tyn: NodeId, out: &mut Spans8, n: &mut i32, depth: i32) {
        if tyn == NODE_NONE || depth > 6 || (*n) as usize >= out.len() {
            return;
        }
        let node = unsafe (*self.mod_ast(m)).at_const(tyn);
        if node.kind == NodeKind::NODE_REFERENCE_TYPE || node.kind == NodeKind::NODE_SLICE_TYPE {
            let l = self.tc_lt_name_in(m, node.as_data.indirect_type.lifetime);
            if !self.tc_span_empty(l) && (*n) as usize < out.len() {
                out[(*n) as usize] = l;
                *n = *n + 1;
            }
            self.tc_typenode_lifetimes(m, node.as_data.indirect_type.ty, out, n, depth + 1);
            return;
        }
        if node.kind == NodeKind::NODE_ARRAY_TYPE {
            self.tc_typenode_lifetimes(m, node.as_data.array_type.element, out, n, depth + 1);
            return;
        }
        if node.kind == NodeKind::NODE_TUPLE_TYPE {
            let es = node.as_data.array_literal.elements;
            for i in 0..es.len {
                self.tc_typenode_lifetimes(m, unsafe (*self.mod_ast(m)).list(es)[i as usize], out, n, depth + 1);
            }
            return;
        }
        if node.kind == NodeKind::NODE_TYPE_PATH {
            let args = node.as_data.type_path.args;
            for i in 0..args.len {
                let aid = unsafe (*self.mod_ast(m)).list(args)[i as usize];
                if unsafe (*self.mod_ast(m)).at_const(aid).kind == NodeKind::NODE_LIFETIME {
                    let l = self.tc_lt_name_in(m, aid);
                    if !self.tc_span_empty(l) && (*n) as usize < out.len() {
                        out[(*n) as usize] = l;
                        *n = *n + 1;
                    }
                } else {
                    self.tc_typenode_lifetimes(m, aid, out, n, depth + 1);
                }
            }
        }
    }

    /// True when type node `node` of module `m` mentions lifetime `lt` anywhere.
    pub fn tc_typenode_covers_lt(self: &Self, m: ModuleId, node: NodeId, lt: tok::Span) bool {
        if node == NODE_NONE || self.tc_span_empty(lt) {
            return false;
        }
        let n = unsafe (*self.mod_ast(m)).at_const(node);
        if n.kind == NodeKind::NODE_REFERENCE_TYPE || n.kind == NodeKind::NODE_SLICE_TYPE {
            let rl = self.tc_lt_name_in(m, n.as_data.indirect_type.lifetime);
            if !self.tc_span_empty(rl) && spans_eq2(self.mod_src(m), rl, self.mod_src(m), lt) {
                return true;
            }
            return self.tc_typenode_covers_lt(m, n.as_data.indirect_type.ty, lt);
        }
        if n.kind == NodeKind::NODE_ARRAY_TYPE {
            return self.tc_typenode_covers_lt(m, n.as_data.array_type.element, lt);
        }
        let mut subs = NodeList { start: 0, len: 0 };
        if n.kind == NodeKind::NODE_TUPLE_TYPE {
            subs = n.as_data.array_literal.elements;
        } else if n.kind == NodeKind::NODE_TYPE_PATH {
            subs = n.as_data.type_path.args;
        }
        for i in 0..subs.len {
            let aid = unsafe (*self.mod_ast(m)).list(subs)[i as usize];
            if unsafe (*self.mod_ast(m)).at_const(aid).kind == NodeKind::NODE_LIFETIME {
                if spans_eq2(self.mod_src(m), self.tc_lt_name_in(m, aid), self.mod_src(m), lt) {
                    return true;
                }
            } else if self.tc_typenode_covers_lt(m, aid, lt) {
                return true;
            }
        }
        return false;
    }

    /// For a `&mut T` parameter type node, the pointee type when writes through it can smuggle a
    /// shorter borrow (T mentions a callee type variable or is invariant); TYPE_NONE otherwise.
    pub fn tc_mut_ref_invariant_elem(self: &mut Self, fmod: ModuleId, pn: NodeId) TypeId {
        let lt = self.decl_type_in(fmod, pn);
        if lt == TYPE_NONE || self.type_at(lt).kind != TypeKind::TYPE_REFERENCE || self.type_at(lt).qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 {
            return TYPE_NONE;
        }
        let elem = self.type_at(lt).as_data.elem;
        // (a) `&mut <ref/ptr mentioning a callee type variable>`: two such args can be swapped by
        // the callee, so a too-short borrow in one is stored into the other (the original rule).
        if self.tc_type_mentions_generic(elem, 0) {
            return elem;
        }
        // (b) `&mut <aggregate invariant in one of its lifetime/type params>`: the variance
        // generalization: an invariant param means the pointee cannot be shortened, so two such args
        // are likewise swappable. `&'a mut i32` alone is covariant in 'a (the invariance is in the
        // pointee), so this only fires when a lifetime reaches an invariant slot, e.g. `&'a mut &'a i32`.
        if self.tc_aggregate_has_invariant_param(elem) {
            return elem;
        }
        return TYPE_NONE;
    }

    /// True when `ty` is an aggregate with at least one INVARIANT parameter slot.
    pub fn tc_aggregate_has_invariant_param(self: &mut Self, ty: TypeId) bool {
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(self.strip(ty), &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
            return false;
        }
        let dd = DefId { module: om, node: od };
        let np = self.variance_nparams(dd);
        for i in 0..np {
            if self.variance_param(dd, i) == V_INVARIANT {
                return true;
            }
        }
        return false;
    }

    /// True when `ty` contains a generic parameter anywhere (bounded at depth 6).
    pub fn tc_type_mentions_generic(self: &mut Self, ty: TypeId, depth: i32) bool {
        if ty == TYPE_NONE || depth > 6 {
            return false;
        }
        let k = self.type_at(ty).kind;
        if k == TypeKind::TYPE_GENERIC || k == TypeKind::TYPE_ASSOC {
            return true;
        }
        if k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_POINTER {
            return self.tc_type_mentions_generic(self.type_at(ty).as_data.elem, depth + 1);
        }
        if k == TypeKind::TYPE_ARRAY {
            return self.tc_type_mentions_generic(self.type_at(ty).as_data.arr.elem, depth + 1);
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(self.strip(ty), &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
            return false;
        }
        for gi in 0..gn {
            if self.tc_type_mentions_generic(ga[gi as usize], depth + 1) {
                return true;
            }
        }
        return false;
    }

    /// Duplicate every borrow bound to `from_ref` onto `to_ref` (with `to_ref`'s region): after a
    /// possible cross-store, both referents must pin the same borrows.
    pub fn tc_cross_tie(self: &mut Self, from_ref: NodeId, to_ref: NodeId) {
        let region = self.tc_binding_depth(to_ref) as u16;
        let n = self.nborrows;
        for b in 0..n {
            let bb = unsafe self.borrows[b as usize];
            if bb.binding == from_ref && bb.root != NODE_NONE && bb.root != to_ref {
                self.borrow_push_bound(bb, to_ref, region);
            }
        }
    }

    /// Cross-tie the borrows of argument pairs passed to invariant `&mut` parameters of one element
    /// type: the callee may swap either into the other's storage. `skip` leading params are the
    /// receiver.
    pub fn tc_check_invariant_args(
        self: &mut Self,
        fmod: ModuleId,
        fdecl: NodeId,
        params: NodeList,
        args: NodeList,
        skip: u32,
    ) {
        let fa = self.mod_ast(fmod);
        if unsafe (*fa).at_const(fdecl).kind != NodeKind::NODE_FUNCTION {
            return;
        }
        // Parameters `skip..end` take arguments `0..end - skip`.
        let end = params.len.min(args.len + skip);
        for i in skip..end {
            let ai = i - skip;
            let ei = self.tc_mut_ref_invariant_elem(fmod, unsafe (*fa).list(params)[i as usize]);
            if ei == TYPE_NONE {
                continue;
            }
            for j in i + 1..end {
                let aj = j - skip;
                let ej = self.tc_mut_ref_invariant_elem(fmod, unsafe (*fa).list(params)[j as usize]);
                if ej != ei {
                    continue;
                }
                let ri = self.tc_ref_arg_referent(unsafe (*self.cur_ast()).list(args)[ai as usize]);
                let rj = self.tc_ref_arg_referent(unsafe (*self.cur_ast()).list(args)[aj as usize]);
                if ri == NODE_NONE || rj == NODE_NONE || ri == rj {
                    continue;
                }
                self.tc_cross_tie(ri, rj);
                self.tc_cross_tie(rj, ri);
            }
        }
    }

    /// Report call arguments that violate a `T: 'static` bound on the callee's generic params. `skip`
    /// leading params are the receiver.
    pub fn tc_check_type_outlives_bounds(
        self: &mut Self,
        fmod: ModuleId,
        fdecl: NodeId,
        params: NodeList,
        args: NodeList,
        skip: u32,
    ) {
        let fa = self.mod_ast(fmod);
        if unsafe (*fa).at_const(fdecl).kind != NodeKind::NODE_FUNCTION {
            return;
        }
        let gens = unsafe (*fa).at_const(fdecl).as_data.function.generics;
        if gens.len == 0 {
            return;
        }
        for gi in 0..gens.len {
            let g = unsafe (*fa).list(gens)[gi as usize];
            if !self.tc_generic_has_static_bound(fmod, fdecl, g) {
                continue;
            }
            // Every parameter declared as exactly this type variable must receive a borrow-free type.
            for pi in skip..params.len.min(args.len + skip) {
                let ai = pi - skip;
                let pt = self.decl_type_in(fmod, unsafe (*fa).list(params)[pi as usize]);
                if pt == TYPE_NONE || self.type_at(pt).kind != TypeKind::TYPE_GENERIC || self.type_at(pt).as_data.decl != g {
                    continue;
                }
                let aid = unsafe (*self.cur_ast()).list(args)[ai as usize];
                let at = unsafe (*self.cur_ast()).type_of(aid);
                if at == TYPE_NONE || !self.tc_carries_borrow(at) {
                    continue;
                }
                let asp = unsafe (*self.cur_ast()).at_const(aid).span;
                let di = self.tc_region_diag(
                    asp.start,
                    asp.end - asp.start,
                    format("borrowed value does not live long enough: this argument must satisfy 'static"),
                );
                self.tc_region_note(
                    di,
                    format("the parameter's type variable is declared `: 'static`, so it cannot hold a borrow"),
                );
                if self.type_at(at).kind == TypeKind::TYPE_FUNCTION {
                    self.tc_region_note(
                        di,
                        format(
                            "this closure captures a borrow (or mutates a capture, which captures `&mut`); move the value in instead, or share it through an `Arc`",
                        ),
                    );
                }
            }
        }
    }

    /// True when generic param `g` of function `(fmod, fdecl)` carries a `'static` bound.
    pub fn tc_generic_has_static_bound(self: &mut Self, fmod: ModuleId, fdecl: NodeId, g: NodeId) bool {
        let fa = self.mod_ast(fmod);
        if self.tc_bounds_have_static(fmod, unsafe (*fa).at_const(g).as_data.generic_param.bounds) {
            return true;
        }
        let wc = unsafe (*fa).at_const(fdecl).as_data.function.where_clause;
        for w in 0..wc.len {
            let wp = unsafe (*fa).at_const(unsafe (*fa).list(wc)[w as usize]).as_data.where_predicate;
            if unsafe (*fa).resolution(wp.ty) == g && self.tc_bounds_have_static(fmod, wp.bounds) {
                return true;
            }
        }
        return false;
    }

    // True when bound list `bnds` of module `fmod` names `'static`.
    fn tc_bounds_have_static(self: &Self, fmod: ModuleId, bnds: NodeList) bool {
        let fa = self.mod_ast(fmod);
        for b in 0..bnds.len {
            let bid = unsafe (*fa).list(bnds)[b as usize];
            if unsafe (*fa).at_const(bid).kind == NodeKind::NODE_LIFETIME && span_is(
                self.mod_src(fmod),
                self.tc_lt_name_in(fmod, bid),
                "'static",
            ) {
                return true;
            }
        }
        return false;
    }

    /// True when method `md`'s parameter `idx` is a bare type variable the receiver instantiates with a
    /// borrow-carrying type, so the argument must outlive the receiver.
    pub fn tc_param_shares_recv_region(self: &mut Self, md: DefId, recv_ty: TypeId, idx: i32, arg: NodeId) bool {
        let fa = self.mod_ast(md.module);
        let fnn = unsafe (*fa).at_const(md.node);
        if fnn.kind != NodeKind::NODE_FUNCTION || fnn.as_data.function.params.len as i32 <= idx {
            return false;
        }
        let pdecl = unsafe (*fa).list(fnn.as_data.function.params)[idx as usize];
        let ptyn = unsafe (*fa).at_const(pdecl).as_data.parameter.ty;
        if ptyn == NODE_NONE {
            return false;
        }
        // The DECLARED param type must be a bare type variable (`value: T`), not `&T` or a concrete
        // type: that is what shares its region with the container's elements. `x: &T` (as in
        // `contains`) reads through a fresh reference and is excluded here.
        let pt = self.decl_type_in(md.module, pdecl);
        if pt == TYPE_NONE || self.type_at(pt).kind != TypeKind::TYPE_GENERIC {
            return false;
        }
        // Exclude the method's OWN generic params: those (`fn map<U, F>(f: F)`) are not bound to the
        // receiver, so their region is unrelated. Only a type variable inherited from the extend/type
        // (`extend<T, A> Vector<T, A> { fn push(value: T) }`) shares the receiver's region.
        let gdecl = self.type_at(pt).as_data.decl;
        let gmod = self.type_at(pt).module;
        let own = fnn.as_data.function.generics;
        for k in 0..own.len {
            if unsafe (*fa).list(own)[k as usize] == gdecl && gmod == md.module {
                return false;
            }
        }
        // A keyed extend's parameters (`ext_keyed`) are the target itself or solved by the interface's
        // arguments: none is an element type of the receiver.
        let ext = self.enclosing(md.module, md.node, NodeKind::NODE_EXTEND);
        if ext != NODE_NONE && self.tc_ext_keyed(md.module, ext) {
            return false;
        }
        // Receiver-inherited type variable: is it a borrow-carrying type in THIS instantiation?
        // A capturing closure argument counts even when its substituted type is `dyn fn` (which
        // erases the captured borrow): the closure VALUE carries a borrow of its captured referent,
        // and storing it as an element ties that referent to the container exactly as `push(&local)` does.
        let subst = self.tc_method_param(recv_ty, md, idx);
        return self.tc_carries_borrow(subst) || arg != NODE_NONE && self.tc_expr_is_closure(arg);
    }

    /// Is `e` a closure literal (possibly wrapped in `move`/`unsafe`)? Store sites use this to decide
    /// whether the RHS may have re-exposed captured borrows (bc_closure) that must be tied to the
    /// destination's region: the closure's own stored type is `dyn fn` and cannot carry that borrow.
    pub fn tc_expr_is_closure(self: &Self, e0: NodeId) bool {
        let a = self.cur_ast();
        let mut e = e0;
        loop {
            let n = unsafe (*a).at_const(e);
            if n.kind == NodeKind::NODE_UNARY && (n.as_data.unary.op == TokenType::Move || n.as_data.unary.op == TokenType::Unsafe) {
                e = n.as_data.unary.operand;
            } else {
                return n.kind == NodeKind::NODE_CLOSURE;
            }
        }
    }

    /// True when binding `root` has a reference type.
    pub const fn tc_root_is_reference(self: &mut Self, root: NodeId) bool {
        if root == NODE_NONE {
            return false;
        }
        let t = unsafe (*self.cur_ast()).type_of(root);
        return t != TYPE_NONE && self.type_at(t).kind == TypeKind::TYPE_REFERENCE;
    }

    /// Does `ty` transitively contain a reference or a lifetime-parameterized aggregate? Memoized
    /// unless the answer read a closure's capture state, which changes as bodies are lowered.
    pub fn tc_carries_borrow(self: &mut Self, ty: TypeId) bool {
        if ty == TYPE_NONE {
            return false;
        }
        let key = self.cur_module() as u64 << 32 | ty as u64;
        switch self.carries_memo.get(&key) {
            Some(v) => {
                return *v != 0;
            },
            None => {},
        };
        let mut pure = true;
        let r = self.tc_carries_borrow_rec(ty, 0, &mut pure);
        if pure {
            self.carries_memo.insert(key, r as u8);
        }
        return r;
    }

    // Memoized per (ty, depth) (the depth cutoff makes results depth-dependent), but ONLY for
    // computations whose recursion never touched a TYPE_FUNCTION: a closure's answer reads the
    // capture analysis' mut_caps bits and the current module, both of which change under the walk.
    fn tc_carries_borrow_rec(self: &mut Self, ty: TypeId, depth: i32, pure: &mut bool) bool {
        if ty == TYPE_NONE || depth > 4 {
            return false;
        }
        let slot = ty_dense(ty) * 5 + depth as usize;
        let c = memo2_get(&self.carries_borrow_memo, slot);
        if c >= 0 {
            return c != 0;
        }
        let mut p2 = true;
        let r = self.tc_carries_borrow_impl(ty, depth, &mut p2);
        if p2 {
            memo2_set(&mut self.carries_borrow_memo, slot, r);
        } else {
            *pure = false;
        }
        return r;
    }

    fn tc_carries_borrow_impl(self: &mut Self, ty: TypeId, depth: i32, pure: &mut bool) bool {
        if self.type_at(ty).kind == TypeKind::TYPE_REFERENCE {
            return true;
        }
        // A closure's ENVIRONMENT is where its borrows live, and none of it shows in its type: `fn(..)`
        // erases the captures. So look at them directly: a captured `&T` (or a value the capture
        // analysis turned into an implicit `&mut`, i.e. a mutated capture) is a borrow of the enclosing
        // frame, and a closure holding one is not `'static` no matter what its signature says.
        if self.type_at(ty).kind == TypeKind::TYPE_FUNCTION {
            // Capture state and the current module change under the walk.
            *pure = false;
            let fmod = self.type_at(ty).module;
            if fmod != self.cur_module() {
                // A foreign closure cannot have captured one of our locals.
                return false;
            }
            let fdecl = self.type_at(ty).as_data.decl;
            if fdecl == NODE_NONE || unsafe (*self.cur_ast()).at_const(fdecl).kind != NodeKind::NODE_CLOSURE {
                // A plain function pointer captures nothing.
                return false;
            }
            let cl = unsafe (*self.cur_ast()).at_const(fdecl).as_data.closure;
            if (cl.mut_caps | cl.ref_caps) != 0 {
                return true;
            }
            let cids = unsafe (*self.cur_ast()).list(cl.captures);
            for ci in 0..cl.captures.len {
                let cty = unsafe (*self.cur_ast()).type_of(unsafe cids[ci as usize]);
                if self.tc_carries_borrow_rec(cty, depth + 1, pure) {
                    return true;
                }
            }
            return false;
        }
        // A RAW POINTER is the language's lifetime hand-off boundary: dereferencing it needs
        // `unsafe`, and the checker deliberately ends borrow tracking at the cast that produced
        // it (the `interp_new(&mut p)` precedent). Peeling it here made every pointer to a
        // str-carrying aggregate count as a borrow, which rejected 'static task payloads built
        // from raw handles.
        if self.type_at(ty).kind == TypeKind::TYPE_POINTER {
            return false;
        }
        let mut om: ModuleId = 0;
        let mut od = NODE_NONE;
        let mut gp = Defs8 {};
        let mut ga = Tys8 {};
        let mut gn: i32 = 0;
        if !self.aggregate_of(self.strip(ty), &mut om, &mut od, &mut gp, &mut ga, &mut gn) {
            return false;
        }
        for gi in 0..gn {
            if self.tc_carries_borrow_rec(ga[gi as usize], depth + 1, pure) {
                return true;
            }
        }
        let ma = self.mod_ast(om);
        if unsafe (*ma).lifetimes_of(od).len != 0 {
            // `struct S<'a>` borrows by construction.
            return true;
        }
        let is_tuple = unsafe (*ma).at_const(od).as_data.aggregate.is_tuple;
        let members = unsafe (*ma).at_const(od).as_data.aggregate.members;
        for i in 0..members.len {
            let mid = unsafe (*ma).list(members)[i as usize];
            let fnode = unsafe (*ma).member_type_node(mid, is_tuple);
            if fnode == NODE_NONE {
                continue;
            }
            if unsafe (*ma).at_const(fnode).kind == NodeKind::NODE_REFERENCE_TYPE {
                return true;
            }
            if self.tc_carries_borrow_rec(self.node_type_in(om, fnode), depth + 1, pure) {
                return true;
            }
        }
        return false;
    }

    /// A use through `recv_n` re-exposes the borrows its base binding holds, as fresh borrows with
    /// origin `origin` (a reborrow).
    pub fn tc_reborrow_inherit(self: &mut Self, recv_n: NodeId, origin: NodeId) {
        let root = self.tc_place_base_binding(recv_n);
        if root == NODE_NONE {
            return;
        }
        let n = self.nborrows;
        for i in 0..n {
            let b = unsafe self.borrows[i as usize];
            if b.binding == root && b.root != NODE_NONE {
                self.borrow_push(b.root, b.kind, b.place, origin);
            }
        }
    }

    /// Record the borrow a slicing result holds on `obj_n`: a fresh shared borrow of an owner, or the
    /// inherited borrows of a view.
    pub fn tc_slice_result_borrows(self: &mut Self, obj_n: NodeId, result: TypeId) {
        if result == TYPE_NONE || !self.tc_carries_borrow(result) {
            return;
        }
        let rty = self.strip(unsafe (*self.cur_ast()).type_of(obj_n));
        if !self.tc_carries_borrow(rty) {
            self.borrow_create(obj_n, BORROW_SHARED, obj_n);
        } else {
            self.tc_reborrow_inherit(obj_n, obj_n);
        }
    }

    /// Moving a whole borrow-carrying value out of one binding into another (`outer = inner`,
    /// `let x = inner`) must carry the borrows the source holds to the destination: otherwise the
    /// destination silently outlives them. Borrows freshly minted by a struct-literal or call RHS are
    /// already retied by the [bm, nborrows) scan at the store; this covers the identifier-RHS whole-value
    /// move that scan misses (the source holds the borrows from an earlier statement, not this one).
    pub fn bc_move_held_borrows(self: &mut Self, from_expr: NodeId, to_binding: NodeId, to_region: u16) {
        if to_binding == NODE_NONE {
            return;
        }
        let a = self.cur_ast();
        let e = unsafe (*a).peel(from_expr, false);
        if unsafe (*a).at_const(e).kind != NodeKind::NODE_IDENTIFIER {
            return;
        }
        let d = unsafe (*a).resolution_def(e);
        if d.module != self.cur_module() || d.node == NODE_NONE || d.node == to_binding {
            return;
        }
        let cnt = self.nborrows;
        for i in 0..cnt {
            let b = unsafe self.borrows[i as usize];
            if b.binding == d.node && b.root != NODE_NONE {
                self.borrow_push_bound(b, to_binding, to_region);
            }
        }
    }

    /// The local binding a place expression is rooted in, or NODE_NONE (foreign items, paths, rvalues).
    pub fn tc_place_base_binding(self: &Self, place: NodeId) NodeId {
        let a = self.cur_ast();
        let pn = unsafe (*a).at_const(place);
        switch pn.kind {
            NODE_IDENTIFIER => {
                let d = unsafe (*a).resolution_def(place);
                return pick(d.module == self.cur_module(), d.node, NODE_NONE);
            },
            NODE_MEMBER => {
                if pn.as_data.member.path {
                    return NODE_NONE;
                }
                return self.tc_place_base_binding(pn.as_data.member.object);
            },
            NODE_INDEX => {
                return self.tc_place_base_binding(pn.as_data.index.object);
            },
            NODE_UNARY => {
                if pn.as_data.unary.op == TokenType::Star {
                    return self.tc_place_base_binding(pn.as_data.unary.operand);
                }
                return NODE_NONE;
            },
            _ => {
                return NODE_NONE;
            },
        };
    }

    /// Region diagnostics insert in source order after err_wm (the per-function error watermark bc_fn sets).
    pub fn tc_region_diag(self: &mut Self, at: u32, len: u32, msg: String) usize {
        return self.errors.emit_ordered(self.err_wm, at, len, msg);
    }

    /// Attach a note to diagnostic `index` (see Errors::note_at).
    pub fn tc_region_note(self: &mut Self, index: usize, msg: String) {
        self.errors.note_at(index, msg);
    }

    /// The name span of lifetime node `lt` (a NODE_LIFETIME or the generic param wrapping one); the
    /// empty span for an elided lifetime: NODE_NONE or `'_`, which names a fresh lifetime at each
    /// occurrence.
    pub fn tc_lt_name(self: &Self, lt: NodeId) tok::Span {
        return self.tc_lt_name_in(self.cur_module(), lt);
    }

    /// `tc_lt_name` for a node of module `m`.
    pub fn tc_lt_name_in(self: &Self, m: ModuleId, lt: NodeId) tok::Span {
        if lt == NODE_NONE {
            return tok::Span { start: 0, end: 0 };
        }
        let n = unsafe (*self.mod_ast(m)).at_const(lt);
        if n.kind == NodeKind::NODE_GENERIC_PARAM {
            return self.tc_lt_name_in(m, n.as_data.generic_param.name);
        }
        if span_is(self.mod_src(m), n.as_data.name.text, "'_") {
            return tok::Span { start: 0, end: 0 };
        }
        return n.as_data.name.text;
    }

    /// True for an empty or unset span.
    pub const fn tc_span_empty(self: &Self, s: tok::Span) bool {
        return s.end <= s.start;
    }

    // Mirrors the typechecker's evaluation order over an already-typed AST, firing only the
    // borrow/move/lifetime analyses. Types and resolutions are read back from the AST; nothing here
    // types anything.
    /// Flow-check one function: reset every per-function fact (moves, freed, borrows,
    /// scopes, regions, error watermark) and walk the body in evaluation order. `irbodies` is the
    /// caller's empty scratch for the lowerings; it is empty again on return.
    pub fn bc_fn(
        self: &mut Self,
        id: NodeId,
        ow: &mut bfx::Owner,
        ctx: &mut bfi::BorrowCtx,
        irbodies: &mut Vector<irl::Lowerer>,
    ) {
        let a = self.cur_ast();
        let fnd = unsafe (*a).at_const(id).as_data.function;
        if fnd.body == NODE_NONE {
            return;
        }
        self.bc_flow_reset(id);
        self.err_wm = self.errors.errors.len();
        // Lower first (the tape and the facts come from the lowerings), replay the tape (the same
        // helper calls the walk made, without traversing the expression tree), then analyze the
        // lowered bodies against the final side tables and emit the flow diagnostics. A body that
        // fails to lower was reported as an error by bc_ir_lower: nothing further to check.
        self.bc_unsafe_spans.truncate(0);
        let tl = ctx.st.pr.start();
        let quiet = self.bc_ir_lower(id, ctx, irbodies);
        ctx.st.pr.stop(bfi::BP_LOWER, tl);
        for b in 0..irbodies.len() {
            let bw = irbodies.at(b);
            for u in 0..bw.unsafe_spans.len() {
                self.bc_unsafe_spans.push(bw.unsafe_spans[u]);
            }
        }
        let td = ctx.st.pr.start();
        self.region_reset(id);
        ctx.st.pr.stop(bfi::BP_DECL, td);
        if quiet && irbodies.len() != 0 {
            ctx.rep.reset();
            let tn = irbodies.at(0).tape.len();
            let tr = ctx.st.pr.start();
            self.bc_replay(irbodies, 0, 0, tn, &mut ctx.rep);
            ctx.st.pr.stop(bfi::BP_REPLAY, tr);
            let mut irres = Vector::<bfi::FlowErr>::new();
            self.bc_ir_analyze(ow, irbodies, ctx, &mut irres);
            let te = ctx.st.pr.start();
            self.bc_ir_emit(&mut irres);
            ctx.st.pr.stop(bfi::BP_EMIT, te);
        }
        // Recycle the spent Lowerers (and their CoreBody pools) instead of freeing them.
        loop {
            switch irbodies.pop() {
                Some(lw) => {
                    if ctx.keep != null {
                        unsafe (&mut *ctx.keep).put(&lw);
                    }
                    ctx.lower_pool.push(lw);
                },
                _ => {
                    break;
                },
            };
        }
        self.bc_flow_reset(NODE_NONE);
    }

    // Clear the per-function flow facts and make `f` the function under check.
    fn bc_flow_reset(self: &mut Self, f: NodeId) {
        for mi in 0..self.nmoved {
            self.ms_bit_clear(unsafe self.moved[mi as usize]);
        }
        self.nmoved = 0;
        self.nlate = 0;
        self.nborrows = 0;
        self.scope_depth = 0;
        self.loop_depth = 0;
        self.icx.current_fn = f;
    }

    /// Replay the lowerer's event tape in place of the quiet walk: the same helper calls at the
    /// same AST sites, without traversing the expression tree. `st` carries the nesting stacks;
    /// pairs are strictly nested so one stack per family suffices.
    pub fn bc_replay(
        self: &mut Self,
        bodies: &Vector<irl::Lowerer>,
        bi: usize,
        lo: usize,
        hi: usize,
        st: &mut bfi::RepSt,
    ) {
        let a = self.cur_ast();
        let tp9 = bodies.at(bi).tape.as_ptr();
        let mut i = lo;
        while i < hi {
            let e = unsafe tp9[i];
            let k = (e >> 56) as u8;
            let aux = (e >> 32 & 0xFFFFFFu64) as u32;
            let node = (e & 0xFFFFFFFFu64) as NodeId;
            if k == ir::TP_MARK_PUSH || k == ir::TP_CALL_MARK {
                st.bms.push(self.borrow_mark());
            } else if k == ir::TP_MARK_POP {
                self.borrow_release_to(rep_bm(st));
            } else if k == ir::TP_SCOPE_PUSH {
                self.scope_depth = self.scope_depth + 1;
            } else if k == ir::TP_SCOPE_POP {
                // Block exit: the scope's borrows and regions die. Defers need no re-walk here: the
                // lowerer tapes every defer body at every exit (marked), so their per-exit flow
                // effects replay in place.
                self.tc_scope_exit();
            } else if k == ir::TP_NLL {
                if self.nborrows != 0 {
                    let ss = unsafe (*a).at_const(node).as_data.block.statements;
                    self.borrow_nll_drop(node, unsafe (*a).list(ss), aux);
                }
            } else if k == ir::TP_LET {
                let bm = rep_bm(st);
                self.bc_let_post(node, bm);
            } else if k == ir::TP_LET_TUPLE {
                let bm = rep_bm(st);
                self.bc_let_tuple_post(node, bm);
            } else if k == ir::TP_ASSIGN_PRE {
                self.bc_assign_pre(node);
                st.bms.push(self.borrow_mark());
            } else if k == ir::TP_ASSIGN_POST {
                let bm = rep_bm(st);
                self.bc_assign_post(node, bm);
            } else if k == ir::TP_RET_VAL {
                if self.icx.current_fn != NODE_NONE {
                    let rl = unsafe (*a).at_const(self.icx.current_fn).as_data.function.returns;
                    if aux < rl.len {
                        self.tc_check_return_lifetime(node, unsafe (*a).list(rl)[aux as usize]);
                    }
                }
            } else if k == ir::TP_RET_POST {
                let bm = rep_bm(st);
                self.bc_return_post(node, bm);
            } else if k == ir::TP_CALL {
                if aux == 1 {
                    // `d.free()` on a dyn receiver: destruction consumes the value.
                    let obj = unsafe (*a).at_const(unsafe (*a).at_const(node).as_data.call.callee).as_data.member.object;
                    self.tc_mark_move(obj);
                } else {
                    let bm = rep_bm(st);
                    self.bc_call_post(node, bm, self.nborrows);
                }
            } else if k == ir::TP_REF {
                let operand = unsafe (*a).at_const(node).as_data.unary.operand;
                let rt = unsafe (*a).type_of(node);
                let mut bk = BORROW_SHARED;
                if rt != TYPE_NONE && self.type_at(rt).kind == TypeKind::TYPE_REFERENCE && self.type_at(rt).qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                    bk = BORROW_MUT;
                }
                self.borrow_create(operand, bk, node);
            } else if k == ir::TP_CAST_ERASE {
                self.borrow_erase_origin(node);
            } else if k == ir::TP_SLICE {
                self.tc_slice_result_borrows(unsafe (*a).at_const(node).as_data.index.object, unsafe (*a).type_of(node));
            } else if k == ir::TP_CLOSURE {
                if self.icx.nclos < 8 {
                    let cn = self.icx.nclos;
                    unsafe self.icx.clos_stack[cn as usize] = node;
                    self.icx.nclos = cn + 1;
                    for b2 in 0..bodies.len() {
                        if bodies.at(b2).body.owner.node == node {
                            self.bc_replay(bodies, b2, 0, bodies.at(b2).tape.len(), st);
                            break;
                        }
                    }
                    self.icx.nclos = self.icx.nclos - 1;
                    self.bc_closure_caps(node);
                } else {
                    self.bc_flow_limit("nested closures", 8);
                }
            } else if k == ir::TP_FLOW_SAVE {
                rep_flow_push(self, st);
            } else if k == ir::TP_FLOW_ELSE {
                let ti = st.fdepth - 1;
                if !self.tc_stmt_returns(unsafe (*a).at_const(node).as_data.if_stmt.then_branch) {
                    self.tc_flow_collect(&mut st.acc[ti]);
                }
                self.tc_flow_set(&st.pre[ti]);
            } else if k == ir::TP_FLOW_JOIN {
                let ti = st.fdepth - 1;
                if !self.tc_stmt_returns(unsafe (*a).at_const(node).as_data.if_stmt.else_branch) {
                    self.tc_flow_collect(&mut st.acc[ti]);
                }
                self.tc_flow_set(&st.acc[ti]);
                st.fdepth = ti;
            } else if k == ir::TP_MATCH_PRE {
                let bm = rep_bm(st);
                let scrut = unsafe (*a).at_const(node).as_data.match_expr.value;
                let sy = unsafe (*a).type_of(scrut);
                let mut bind_ref = false;
                if sy != TYPE_NONE {
                    let sk = self.type_at(sy).kind;
                    bind_ref = sk == TypeKind::TYPE_REFERENCE || sk == TypeKind::TYPE_POINTER;
                }
                if !bind_ref {
                    self.borrow_release_to(bm);
                }
                rep_flow_push(self, st);
                st.mbm.push(bm);
            } else if k == ir::TP_ARM {
                let ti = st.fdepth - 1;
                self.tc_flow_set(&st.pre[ti]);
                self.bc_pattern_depths(unsafe (*a).at_const(node).as_data.match_arm.pattern);
            } else if k == ir::TP_ARM_END {
                let body = unsafe (*a).at_const(node).as_data.match_arm.body;
                let bt = unsafe (*a).type_of(body);
                let diverges = self.tc_stmt_returns(body) || bt != TYPE_NONE && self.type_at(bt).kind == TypeKind::TYPE_NEVER;
                let ti = st.fdepth - 1;
                if !diverges {
                    self.tc_flow_collect(&mut st.acc[ti]);
                }
            } else if k == ir::TP_MATCH_POST {
                let ti = st.fdepth - 1;
                if unsafe (*a).at_const(node).as_data.match_expr.arms.len != 0 {
                    self.tc_flow_set(&st.acc[ti]);
                }
                st.fdepth = ti;
                self.borrow_release_to(st.mbm.pop().unwrap_or(0));
            } else if k == ir::TP_LOOP_PUSH {
                self.loop_depth = self.loop_depth + 1;
                let nk9 = unsafe (*a).at_const(node).kind;
                let lbl = if nk9 == NodeKind::NODE_WHILE {
                    unsafe (*a).at_const(node).as_data.while_stmt.label;
                } else {
                    unsafe (*a).at_const(node).as_data.for_stmt.label;
                };
                st.les.push(self.tc_loop_push(lbl, node, false));
            } else if k == ir::TP_LOOP_POP {
                // Leave the loop entered at stack height `le` (negative: no loop was pushed).
                let le = st.les.pop().unwrap_or(-1);
                if le >= 0 {
                    self.nloops = le as u32;
                }
                self.loop_depth = self.loop_depth - 1;
            } else if k == ir::TP_BODY_START {
                let nk9 = unsafe (*a).at_const(node).kind;
                if nk9 == NodeKind::NODE_FOR || nk9 == NodeKind::NODE_INLINE_FOR {
                    self.tc_record_binding_depth(node);
                    // A pattern binding's names are declarations of their own.
                    self.bc_pattern_depths(unsafe (*a).at_const(node).as_data.for_stmt.binding);
                }
                st.seg.push((i + 1) as u64 << 32 | self.nmoved as u64 << 16 | self.nborrows as u64);
            } else if k == ir::TP_BODY_END {
                let sv = st.seg.pop().unwrap_or(0);
                let start = (sv >> 32) as usize;
                let nm0 = (sv >> 16 & 0xFFFFu64) as u32;
                let nb0 = (sv & 0xFFFFu64) as u32;
                if (self.nmoved > nm0 || self.nborrows > nb0) && !self.in_loop_recheck {
                    self.in_loop_recheck = true;
                    self.bc_replay(bodies, bi, start, i, st);
                    self.in_loop_recheck = false;
                }
            }
            i += 1;
        }
    }

    /// The walk's return-statement second pass: escape and region checks over the returned
    /// values, then the statement's borrow release. Shared with the tape replay.
    pub fn bc_return_post(self: &mut Self, id: NodeId, bm: u32) {
        let a = self.cur_ast();
        let values = unsafe (*a).at_const(id).as_data.return_stmt.values;
        let mut ret_list = NodeList { start: 0, len: 0 };
        if self.icx.current_fn != NODE_NONE {
            ret_list = unsafe (*a).at_const(self.icx.current_fn).as_data.function.returns;
        }
        for i in 0..values.len {
            let vid = unsafe (*a).list(values)[i as usize];
            let esc = self.addr_escape_at(vid, 0);
            if esc != 0 {
                // The Core IR path reports escapes only for borrow-CARRYING returns; addresses
                // that leave as raw pointers or integers carry no loan there, so this depth-based
                // check stays on for every non-carrying return type. The DECLARED return type
                // decides which path owns the report: a pointer (or integer) return coerces the
                // borrow away, so no Core IR loan reaches the return there.
                let mut ret_ptr = false;
                if i < ret_list.len {
                    let rt2 = unsafe (*a).slot_type_node(unsafe (*a).list(ret_list)[i as usize]);
                    ret_ptr = unsafe (*a).at_const(rt2).kind == NodeKind::NODE_POINTER_TYPE;
                }
                let vt2 = unsafe (*a).type_of(vid);
                let vt2k = pick(vt2 != TYPE_NONE, self.type_at(vt2).kind as u8, 0xFF);
                if !ret_ptr && vt2 != TYPE_NONE && vt2k != TypeKind::TYPE_POINTER as u8 && self.tc_carries_borrow(vt2) {
                    // The Core IR path reports carrying-return escapes.
                    continue;
                }
                let sp = unsafe (*a).at_const(vid).span;
                let w = if esc == 2 {
                    "function parameter";
                } else {
                    "local variable";
                };
                self.errors.emit_span(
                    sp,
                    format("returning a pointer/reference to a {}, which does not outlive the call", w),
                );
            }
            // Carrying returns: the loan solver owns the borrowed-from-local escape wording.
        }
        self.borrow_release_to(bm);
    }

    /// Tuple-destructuring let: binding depths, then retie the RHS borrows to the whole binding
    /// when any element is a reference. Shared with the tape replay; depth recording moved after
    /// the value (the initializer cannot name the binding, so the order is unobservable).
    pub fn bc_let_tuple_post(self: &mut Self, id: NodeId, bm: u32) {
        let a = self.cur_ast();
        let nm = unsafe (*a).at_const(id).as_data.let_stmt.name;
        let eids = unsafe (*a).at_const(nm).as_data.pattern.children;
        for k in 0..eids.len {
            self.tc_record_binding_depth(unsafe (*a).list(eids)[k as usize]);
        }
        self.tc_record_binding_depth(id);
        if self.bc_tuple_binds_reference(nm) && self.nborrows > bm {
            for j in bm..self.nborrows {
                unsafe self.borrows[j as usize].binding = id;
                unsafe self.borrows[j as usize].region = self.scope_depth as u16;
            }
        } else {
            self.borrow_release_to(bm);
        }
    }

    /// Plain let: binding depth, then tie or release the initializer's borrows.
    pub fn bc_let_post(self: &mut Self, id: NodeId, bm: u32) {
        let a = self.cur_ast();
        let value = unsafe (*a).at_const(id).as_data.let_stmt.value;
        self.tc_record_binding_depth(id);
        let binding = unsafe (*a).type_of(id);
        let binding_is_ref = binding != TYPE_NONE && self.type_at(binding).kind == TypeKind::TYPE_REFERENCE;
        let binding_carries = binding != TYPE_NONE && self.tc_carries_borrow(binding);
        if binding_carries && self.nborrows > bm {
            for k in bm..self.nborrows {
                unsafe self.borrows[k as usize].binding = id;
                unsafe self.borrows[k as usize].region = self.scope_depth as u16;
            }
        } else if binding_carries && !binding_is_ref && value != NODE_NONE {
            // Whole-value move of a borrow-carrying aggregate out of an identifier (`let x =
            // inner`): the RHS holds the borrows from an earlier statement, so no fresh borrow
            // was minted to retie: carry them across. A bare reference stays on the
            // transfer-ref path below (copying a `&mut` must MOVE it, not duplicate it).
            self.bc_move_held_borrows(value, id, self.scope_depth as u16);
        } else {
            self.borrow_release_to(bm);
            if binding_is_ref && value != NODE_NONE {
                self.borrow_transfer_ref(value, id);
            }
        }
    }

    /// True when any element of tuple pattern `nm` binds a reference-typed value.
    pub fn bc_tuple_binds_reference(self: &mut Self, nm: NodeId) bool {
        let a = self.cur_ast();
        let eids = unsafe (*a).at_const(nm).as_data.pattern.children;
        for k in 0..eids.len {
            let t = unsafe (*a).type_of(unsafe (*a).list(eids)[k as usize]);
            if t != TYPE_NONE && self.type_at(t).kind == TypeKind::TYPE_REFERENCE {
                return true;
            }
        }
        return false;
    }

    /// Record the scope depth of every binding in `pat` and revive names the arm rebinds from the
    /// scrutinee.
    pub fn bc_pattern_depths(self: &mut Self, pat: NodeId) {
        if pat == NODE_NONE {
            return;
        }
        let a = self.cur_ast();
        let n = unsafe (*a).at_const(pat);
        if n.kind == NodeKind::NODE_PATTERN_NAME {
            self.tc_record_binding_depth(pat);
            // Entering the arm BINDS this name afresh from the scrutinee, exactly as a `let` with a value
            // does, so any move recorded for it is from an earlier binding and does not apply. Without
            // this, the second pass `bc_loop_body` makes over a loop sees a binding the first pass moved
            // (captured into an owning closure, say) and reports the arm's own use as a use-after-move.
            self.tc_unmark_move(pat);
            return;
        }
        if n.kind == NodeKind::NODE_PATTERN_TUPLE || n.kind == NodeKind::NODE_PATTERN_STRUCT {
            let cs = n.as_data.pattern.children;
            for i in 0..cs.len {
                self.bc_pattern_depths(unsafe (*a).list(cs)[i as usize]);
            }
        }
    }

    /// Assignment pre-pass: split-init enforcement and rebind tombstones; everything the walk
    /// does BEFORE evaluating either side. Shared with the tape replay.
    pub fn bc_assign_pre(self: &mut Self, id: NodeId) {
        let a = self.cur_ast();
        let bd = unsafe (*a).at_const(id).as_data.binary;
        let plain = bd.op == TokenType::Equal;
        let mut ld = DefId { module: 0, node: NODE_NONE };
        if plain && unsafe (*a).at_const(bd.left).kind == NodeKind::NODE_IDENTIFIER {
            ld = unsafe (*a).resolution_def(bd.left);
        }
        let lhs_local = ld.node != NODE_NONE && ld.module == self.cur_module();
        if lhs_local {
            // Split initialization of an immutable binding: the assignment is its ONE initialization.
            // Reject a second one (or one already made on some earlier path), and one inside a loop
            // the binding does not belong to (it would re-run against the same binding; use `mut`).
            let ln = unsafe (*a).at_const(ld.node);
            if ln.kind == NodeKind::NODE_LET && !ln.as_data.let_stmt.is_mutable {
                let sp = unsafe (*a).at_const(bd.left).span;
                if self.tc_is_late(ld.node) {
                    self.errors.emit_span(
                        sp,
                        format("cannot assign twice to an immutable binding; declare it 'let mut'"),
                    );
                } else if self.nloops != 0 && !self.tc_binding_in_innermost_loop(ld.node) {
                    self.errors.emit_span(
                        sp,
                        format(
                            "cannot initialize an immutable binding inside a loop it was declared outside of; declare it 'let mut'",
                        ),
                    );
                } else if self.nlate < BC_TABLE_CAP {
                    self.tc_add_late(ld.node);
                } else {
                    self.bc_flow_limit("split-initialized bindings", BC_TABLE_CAP);
                }
            }
        }
        let lt = pick(lhs_local, unsafe (*a).type_of(ld.node), TYPE_NONE);
        let ref_rebind = lt != TYPE_NONE && self.type_at(lt).kind == TypeKind::TYPE_REFERENCE;
        let carrier_rebind = lt != TYPE_NONE && !ref_rebind && self.tc_carries_borrow(lt);
        if ref_rebind || carrier_rebind {
            for i in 0..self.nborrows {
                if unsafe self.borrows[i as usize].binding == ld.node {
                    self.borrow_tombstone_at(i);
                }
            }
        }
    }

    /// Assignment post-pass: retie the fresh borrows, then the write-conflict check: everything the
    /// walk does AFTER both sides. Shared with the tape replay.
    pub fn bc_assign_post(self: &mut Self, id: NodeId, bm: u32) {
        let a = self.cur_ast();
        let bd = unsafe (*a).at_const(id).as_data.binary;
        let plain = bd.op == TokenType::Equal;
        let mut ld = DefId { module: 0, node: NODE_NONE };
        if plain && unsafe (*a).at_const(bd.left).kind == NodeKind::NODE_IDENTIFIER {
            ld = unsafe (*a).resolution_def(bd.left);
        }
        let lhs_local = ld.node != NODE_NONE && ld.module == self.cur_module();
        let lt = pick(lhs_local, unsafe (*a).type_of(ld.node), TYPE_NONE);
        let ref_rebind = lt != TYPE_NONE && self.type_at(lt).kind == TypeKind::TYPE_REFERENCE;
        let carrier_rebind = lt != TYPE_NONE && !ref_rebind && self.tc_carries_borrow(lt);
        let l = unsafe (*a).type_of(bd.left);
        if ref_rebind {
            if self.nborrows > bm {
                let region = self.tc_binding_depth(ld.node) as u16;
                for k in bm..self.nborrows {
                    unsafe self.borrows[k as usize].binding = ld.node;
                    unsafe self.borrows[k as usize].region = region;
                }
            } else {
                self.borrow_transfer_ref(bd.right, ld.node);
            }
        } else if carrier_rebind || lt == TYPE_NONE && self.tc_carries_borrow(l) || self.tc_expr_is_closure(bd.right) {
            let proot = self.tc_place_base_binding(bd.left);
            if proot != NODE_NONE {
                let region = self.tc_binding_depth(proot) as u16;
                for k in bm..self.nborrows {
                    if unsafe self.borrows[k as usize].binding == NODE_NONE && unsafe self.borrows[k as usize].root != NODE_NONE {
                        unsafe self.borrows[k as usize].binding = proot;
                        unsafe self.borrows[k as usize].region = region;
                    }
                }
                self.bc_move_held_borrows(bd.right, proot, region);
            }
        }
        let _ = self.borrow_conflicting_write(bd.left, id); // the loan solver owns the wording
    }

    /// Call post-pass over the typechecker's recorded callee: pointer-coercion erases, receiver
    /// borrow/move effects, result reborrows, and the call-boundary lifetime relation. Everything
    /// the walk does after evaluating receiver and arguments; shared with the tape replay.
    pub fn bc_call_post(self: &mut Self, id: NodeId, arg_bm: u32, arg_end: u32) {
        // Callee resolution is the one the typechecker computed for this call node: recorded there
        // (call_info) so the flow pass never re-derives generic instantiation or receiver skip and can
        // never disagree with it.
        let packed = self.bc_call_info(id);
        if packed == 0u64 {
            return;
        }
        let a = self.cur_ast();
        let callee_id = unsafe (*a).at_const(id).as_data.call.callee;
        let args = unsafe (*a).at_const(id).as_data.call.args;
        let mut recv_n = NODE_NONE;
        if unsafe (*a).at_const(callee_id).kind == NodeKind::NODE_MEMBER && !unsafe (*a).at_const(callee_id).as_data.member.path {
            recv_n = unsafe (*a).at_const(callee_id).as_data.member.object;
        }
        let md = DefId { module: (packed >> 40) as ModuleId, node: (packed >> 8 & 0xFFFFFFFFu64) as NodeId };
        let skip = (packed & 0xFFu64) as u32;
        let fa = self.mod_ast(md.module);
        let params = unsafe (*fa).at_const(md.node).as_data.function.params;
        let returns = unsafe (*fa).at_const(md.node).as_data.function.returns;
        // A ref->ptr coercion at an argument erases the borrow.
        for pi in skip..params.len.min(args.len + skip) {
            let i = pi - skip;
            let ptyn = unsafe (*fa).at_const(unsafe (*fa).list(params)[pi as usize]).as_data.parameter.ty;
            if ptyn == NODE_NONE {
                continue;
            }
            let aid = unsafe (*a).list(args)[i as usize];
            let at = unsafe (*a).type_of(aid);
            if unsafe (*fa).at_const(ptyn).kind == NodeKind::NODE_POINTER_TYPE && at != TYPE_NONE && self.type_at(at).kind == TypeKind::TYPE_REFERENCE {
                self.borrow_erase_origin(aid);
            }
        }
        // Receiver borrow/move effects, with this call's own arg borrows two-phase exempted.
        if recv_n != NODE_NONE && skip == 1 {
            let saved_tp = self.tc_twophase_wm;
            self.tc_twophase_wm = arg_bm;
            self.check_call_receiver(callee_id, md.module, params, returns);
            self.tc_twophase_wm = saved_tp;
        }
        // A result that carries a borrow pins (or reborrows through) its receiver.
        let ret = unsafe (*a).type_of(id);
        let ret_kind = pick(ret != TYPE_NONE, self.type_at(ret).kind as u8, 0xFF);
        if recv_n != NODE_NONE && skip == 1 && ret != TYPE_NONE && ret_kind != TypeKind::TYPE_REFERENCE as u8 && self.tc_carries_borrow(
            ret,
        ) {
            let raw = unsafe (*a).type_of(recv_n);
            let via_ref = raw != TYPE_NONE && self.type_at(raw).kind == TypeKind::TYPE_REFERENCE;
            let rty = self.strip(raw);
            if !via_ref && !self.tc_carries_borrow(rty) {
                self.borrow_create(recv_n, BORROW_SHARED, recv_n);
            } else {
                self.tc_reborrow_inherit(recv_n, recv_n);
            }
        }
        // The lifetime relation across the argument boundary: a borrow flowing into storage that
        // outlives the call is tied to (and must outlive) that storage. One uniform storage x consumer
        // relation, so no argument shape can escape a store it flows into.
        self.relate_call(md, params, args, skip, recv_n, arg_bm, arg_end);
        // Call-site PRECISION: the signature is verified modularly (tc_check_return_lifetime), so the
        // result borrows ONLY the arguments whose lifetime the return type names. Release the transient
        // borrows of arguments that do not flow into the result, instead of conservatively tying every
        // argument to it: this is what makes `fn first<'a,'b>(x:&'a,y:&'b) &'a { x }` usable with a
        // short-lived second argument.
        if ret != TYPE_NONE && self.tc_carries_borrow(ret) && recv_n == NODE_NONE {
            let rtn = pick(returns.len > 0, unsafe (*fa).list(returns)[0], NODE_NONE);
            self.relate_result_precision(md, params, args, skip, arg_bm, arg_end, rtn);
        }
    }

    /// Record the result-attributability verdict of every function of the current module in the
    /// package's item table (`ItemSched.ret_attr`), right after its type check and before any
    /// module releases its body syntax: the borrow pass of every caller reads the table instead.
    pub fn bc_record_ret_attr(self: &mut Self) {
        if !unsafe (&*self.package).sched.built {
            return;
        }
        let m = self.cur_module();
        let a = self.cur_ast();
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        for i in 0..items.len {
            let id = unsafe (*a).list(items)[i as usize];
            let k = unsafe (*a).at_const(id).kind;
            if k == NodeKind::NODE_FUNCTION {
                let ra = self.tc_scan_returns_attributable(m, unsafe (*a).at_const(id).as_data.function.body, 0);
                unsafe (&mut *self.package).set_item_ret_attr(m, id, ra);
            } else if k == NodeKind::NODE_EXTEND {
                let ms = unsafe (*a).at_const(id).as_data.extend_def.items;
                for j in 0..ms.len {
                    let mid = unsafe (*a).list(ms)[j as usize];
                    if unsafe (*a).at_const(mid).kind == NodeKind::NODE_FUNCTION {
                        let ra = self.tc_scan_returns_attributable(
                            m,
                            unsafe (*a).at_const(mid).as_data.function.body,
                            0,
                        );
                        unsafe (&mut *self.package).set_item_ret_attr(m, mid, ra);
                    }
                }
            }
        }
    }

    /// Is `md`'s result lifetime fully attributable to bare-parameter returns? Only then has the modular
    /// return check verified exactly which parameters the result borrows, so a caller may release the
    /// non-flowing arguments. A return of a local, a call result, or a value laundered through a local
    /// is NOT attributable: the signature may be dishonoured there, so the caller stays conservative.
    pub fn tc_result_attributable(self: &mut Self, md: DefId) bool {
        // The checker recorded the verdict at the end of the callee's body check (its syntax may be
        // released by now); a call target outside the item table is scanned directly.
        let v = unsafe (&*self.package).item_ret_attr(md.module, md.node);
        if v == 0 || v == 1 {
            return v != 0;
        }
        let fa = self.mod_ast(md.module);
        let body = unsafe (*fa).at_const(md.node).as_data.function.body;
        return self.tc_scan_returns_attributable(md.module, body, 0);
    }

    /// True when every `return` reachable in `node` returns a value whose borrows attribute to the
    /// function's inputs. Conservative: false past the depth bound. A closure's returns are its own.
    pub fn tc_scan_returns_attributable(self: &mut Self, m: ModuleId, node: NodeId, depth: i32) bool {
        if node == NODE_NONE {
            return true;
        }
        if depth > 64 {
            return false;
        }
        let fa = self.mod_ast(m);
        let n = *unsafe (*fa).at_const(node);
        let d = depth + 1;
        return switch n.kind {
            NODE_RETURN => {
                let vals = n.as_data.return_stmt.values;
                for i in 0..vals.len {
                    let vid = unsafe (*self.mod_ast(m)).list(vals)[i as usize];
                    let vt = unsafe (*self.mod_ast(m)).type_of(vid);
                    // An owned (borrow-free) result attributes to nothing: fine to release all args.
                    if vt != TYPE_NONE && !self.tc_carries_borrow(vt) {
                        continue;
                    }
                    // A borrow-carrying result must be a bare parameter for the modular check to have
                    // pinned exactly which lifetimes it carries.
                    if self.tc_returned_param_typenode(m, vid) == NODE_NONE {
                        return false;
                    }
                }
                true;
            },
            NODE_BLOCK => self.tc_scan_list_attributable(m, n.as_data.block.statements, d),
            NODE_IF => self.tc_scan_returns_attributable(m, n.as_data.if_stmt.condition, d) && self.tc_scan_returns_attributable(
                m,
                n.as_data.if_stmt.then_branch,
                d,
            ) && self.tc_scan_returns_attributable(m, n.as_data.if_stmt.else_branch, d),
            NODE_WHILE => self.tc_scan_returns_attributable(m, n.as_data.while_stmt.condition, d) && self.tc_scan_returns_attributable(
                m,
                n.as_data.while_stmt.body,
                d,
            ),
            NODE_FOR | NODE_INLINE_FOR => self.tc_scan_returns_attributable(m, n.as_data.for_stmt.iterable, d) && self.tc_scan_returns_attributable(
                m,
                n.as_data.for_stmt.body,
                d,
            ),
            NODE_MATCH => {
                if !self.tc_scan_returns_attributable(m, n.as_data.match_expr.value, d) {
                    return false;
                }
                self.tc_scan_list_attributable(m, n.as_data.match_expr.arms, d);
            },
            NODE_MATCH_ARM => self.tc_scan_returns_attributable(m, n.as_data.match_arm.guard, d) && self.tc_scan_returns_attributable(
                m,
                n.as_data.match_arm.body,
                d,
            ),
            NODE_LET => self.tc_scan_returns_attributable(m, n.as_data.let_stmt.value, d),
            NODE_EXPRESSION_STATEMENT | NODE_DEFER => self.tc_scan_returns_attributable(m, n.as_data.single.value, d),
            NODE_BREAK => self.tc_scan_returns_attributable(m, n.as_data.flow.value, d),
            NODE_UNARY => self.tc_scan_returns_attributable(m, n.as_data.unary.operand, d),
            NODE_BINARY | NODE_ASSIGNMENT => self.tc_scan_returns_attributable(m, n.as_data.binary.left, d) && self.tc_scan_returns_attributable(
                m,
                n.as_data.binary.right,
                d,
            ),
            NODE_CALL => self.tc_scan_returns_attributable(m, n.as_data.call.callee, d) && self.tc_scan_list_attributable(
                m,
                n.as_data.call.args,
                d,
            ),
            NODE_INDEX => self.tc_scan_returns_attributable(m, n.as_data.index.object, d) && self.tc_scan_returns_attributable(
                m,
                n.as_data.index.index,
                d,
            ),
            NODE_MEMBER => self.tc_scan_returns_attributable(m, n.as_data.member.object, d),
            NODE_CAST => self.tc_scan_returns_attributable(m, n.as_data.cast.expression, d),
            NODE_GENERIC_SPECIALIZATION => self.tc_scan_returns_attributable(m, n.as_data.specialization.expression, d),
            NODE_NEW => self.tc_scan_returns_attributable(m, n.as_data.new_expr.initializer, d),
            NODE_ARRAY_LITERAL | NODE_TUPLE => self.tc_scan_list_attributable(m, n.as_data.array_literal.elements, d),
            NODE_STRUCT_INITIALIZER => self.tc_scan_list_attributable(m, n.as_data.struct_initializer.fields, d),
            NODE_FIELD_INITIALIZER => self.tc_scan_returns_attributable(m, n.as_data.field_initializer.value, d),
            NODE_RANGE => self.tc_scan_returns_attributable(m, n.as_data.pattern_range.start, d) && self.tc_scan_returns_attributable(
                m,
                n.as_data.pattern_range.end,
                d,
            ),
            NODE_VA_EXPR => self.tc_scan_returns_attributable(m, n.as_data.va_op.ap, d) && self.tc_scan_returns_attributable(
                m,
                n.as_data.va_op.extra,
                d,
            ),
            // Leaves (names, literals, paths, patterns, asm, continue) hold no `return`, `sizeof`
            // does not evaluate its operand, and a closure's returns leave the closure only.
            _ => true,
        };
    }

    // tc_scan_returns_attributable over every node of `list`.
    fn tc_scan_list_attributable(self: &mut Self, m: ModuleId, list: NodeList, depth: i32) bool {
        for i in 0..list.len {
            if !self.tc_scan_returns_attributable(m, unsafe (*self.mod_ast(m)).list(list)[i as usize], depth) {
                return false;
            }
        }
        return true;
    }

    /// The parameter type NODE a returned bare-identifier value of module `m` refers to, or NODE_NONE.
    /// Only a whole parameter's lifetimes are known statically here; other returned expressions are
    /// covered by the local-escape check and the call-site relation. A parameter resolves only within
    /// its own function, so the result indexes `m`'s AST.
    pub fn tc_returned_param_typenode(self: &mut Self, m: ModuleId, vid: NodeId) NodeId {
        let fa = self.mod_ast(m);
        let e = unsafe (*fa).peel(vid, true);
        if unsafe (*fa).at_const(e).kind != NodeKind::NODE_IDENTIFIER {
            return NODE_NONE;
        }
        let d = unsafe (*fa).resolution_def(e);
        if d.node == NODE_NONE || unsafe (*self.mod_ast(d.module)).at_const(d.node).kind != NodeKind::NODE_PARAMETER {
            return NODE_NONE;
        }
        return unsafe (*self.mod_ast(d.module)).at_const(d.node).as_data.parameter.ty;
    }

    /// Tombstone the transient, UNSTORED borrows of arguments that do not flow into the call's result,
    /// so the enclosing let/assign ties the result to only the flowing arguments. Sound because the
    /// signature was verified: a param flows iff the return type names one of the lifetimes its type
    /// carries. Only borrows still `binding == NONE` are touched: anything relate_call tied to a
    /// storage keeps its binding and is left alone.
    pub fn relate_result_precision(
        self: &mut Self,
        md: DefId,
        params: NodeList,
        args: NodeList,
        skip: u32,
        arg_bm: u32,
        arg_end: u32,
        ret_tyn: NodeId,
    ) {
        if arg_end <= arg_bm {
            return;
        }
        // Only trust the signature when the modular return check has verified exactly what the result
        // borrows; otherwise keep every argument tied (the sound, conservative default).
        if !self.tc_result_attributable(md) {
            return;
        }
        let fa = self.mod_ast(md.module);
        let dest = self.tc_return_dest_lifetime(md.module, ret_tyn);
        // Elided return with exactly one input reference: that reference flows (elision rule 1).
        let mut nref: i32 = 0;
        let mut only_ref: i32 = -1;
        for pi in skip..params.len {
            let pt = unsafe (*fa).at_const(unsafe (*fa).list(params)[pi as usize]).as_data.parameter.ty;
            if pt != NODE_NONE && unsafe (*fa).at_const(pt).kind == NodeKind::NODE_REFERENCE_TYPE {
                nref = nref + 1;
                only_ref = pi as i32;
            }
        }
        if self.tc_span_empty(dest) && nref != 1 {
            // Cannot pin the flowing input: keep the conservative all-args tie.
            return;
        }
        // A param flows into the result if the return type names a lifetime its type carries (or it is
        // the single elided input). Collect the flowing arguments' referents first.
        let mut flowing = Nodes8 {};
        let mut nflow: i32 = 0;
        for pi in skip..params.len.min(args.len + skip) {
            let ptyn = unsafe (*fa).at_const(unsafe (*fa).list(params)[pi as usize]).as_data.parameter.ty;
            let mut flows = false;
            if self.tc_span_empty(dest) {
                flows = pi as i32 == only_ref;
            } else {
                flows = ptyn != NODE_NONE && self.tc_typenode_covers_lt(md.module, ptyn, dest);
            }
            let ai = pi - skip;
            if flows {
                if nflow == 8 {
                    // More flowing referents than recorded: keep the conservative all-args tie.
                    return;
                }
                flowing[nflow as usize] = self.tc_ref_arg_referent(unsafe (*self.cur_ast()).list(args)[ai as usize]);
                nflow = nflow + 1;
            }
        }
        for pi in skip..params.len.min(args.len + skip) {
            let ai = pi - skip;
            let ptyn = unsafe (*fa).at_const(unsafe (*fa).list(params)[pi as usize]).as_data.parameter.ty;
            let mut flows = false;
            if self.tc_span_empty(dest) {
                flows = pi as i32 == only_ref;
            } else {
                flows = ptyn != NODE_NONE && self.tc_typenode_covers_lt(md.module, ptyn, dest);
            }
            if flows {
                continue;
            }
            let referent = self.tc_ref_arg_referent(unsafe (*self.cur_ast()).list(args)[ai as usize]);
            if referent == NODE_NONE {
                continue;
            }
            let mut shared = false;
            for f in 0..nflow {
                if flowing[f as usize] == referent {
                    shared = true;
                }
            }
            if shared {
                // Same referent also flows: do not release.
                continue;
            }
            for bi in arg_bm..arg_end {
                if unsafe self.borrows[bi as usize].binding == NODE_NONE && unsafe self.borrows[bi as usize].root == referent {
                    self.borrow_tombstone_at(bi);
                }
            }
        }
    }

    /// Unified call-boundary lifetime relation. A parameter (or the method receiver) can denote STORAGE
    /// that outlives the call: the receiver's container, or a `&mut C<..>` referent. Any parameter
    /// sharing a type variable or named lifetime with that storage's contents has its argument flow in,
    /// so the argument's borrows are tied to (and must outlive) the storage. ONE storage x consumer
    /// enumeration replaces the two per-shape store hooks; 'static bounds and &mut invariance stay
    /// orthogonal. Correctness by construction: every storage is paired with every consumer here, so no
    /// argument shape can escape a store it flows into.
    pub fn relate_call(
        self: &mut Self,
        md: DefId,
        params: NodeList,
        args: NodeList,
        skip: u32,
        recv_n: NodeId,
        arg_bm: u32,
        arg_end: u32,
    ) {
        let fa = self.mod_ast(md.module);
        if unsafe (*fa).at_const(md.node).kind != NodeKind::NODE_FUNCTION {
            return;
        }
        self.tc_check_type_outlives_bounds(md.module, md.node, params, args, skip);
        self.tc_check_invariant_args(md.module, md.node, params, args, skip);
        // storage index -1 denotes the method receiver; 0.. the parameters.
        let mut sidx: i32 = 0;
        if recv_n != NODE_NONE && skip == 1 {
            sidx = -1;
        }
        while sidx < params.len as i32 {
            let cur = sidx;
            sidx = sidx + 1;
            let mut store_root = NODE_NONE;
            let mut is_recv = false;
            let mut recv_ty: TypeId = TYPE_NONE;
            let mut ps_elem: TypeId = TYPE_NONE;
            let mut ps_pointee = NODE_NONE;
            if cur == -1 {
                is_recv = true;
                recv_ty = unsafe (*self.cur_ast()).type_of(recv_n);
                let mut arg_closure = false;
                for ci in 0..args.len {
                    if self.tc_expr_is_closure(unsafe (*self.cur_ast()).list(args)[ci as usize]) {
                        arg_closure = true;
                    }
                }
                if !self.tc_carries_borrow(recv_ty) && !arg_closure || params.len <= 1 {
                    continue;
                }
                if unsafe (*self.cur_ast()).at_const(recv_n).kind == NodeKind::NODE_IDENTIFIER {
                    let rd = unsafe (*self.cur_ast()).resolution_def(recv_n);
                    if rd.module == self.cur_module() && rd.node != NODE_NONE {
                        store_root = rd.node;
                    }
                } else {
                    store_root = self.place_through_binding(recv_n);
                }
            } else {
                if cur as u32 < skip {
                    continue;
                }
                let ps_ty = unsafe (*fa).at_const(unsafe (*fa).list(params)[cur as usize]).as_data.parameter.ty;
                if ps_ty == NODE_NONE {
                    continue;
                }
                let lt = self.decl_type_in(md.module, unsafe (*fa).list(params)[cur as usize]);
                if lt == TYPE_NONE || self.type_at(lt).kind != TypeKind::TYPE_REFERENCE || self.type_at(lt).qualifier != TypeQualifier::TYPE_QUAL_MUT as u8 {
                    continue;
                }
                ps_elem = self.type_at(lt).as_data.elem;
                ps_pointee = unsafe (*fa).at_const(ps_ty).as_data.indirect_type.ty;
                let sa = cur as u32 - skip;
                if sa >= args.len {
                    continue;
                }
                store_root = self.tc_ref_arg_referent(unsafe (*self.cur_ast()).list(args)[sa as usize]);
            }
            if store_root == NODE_NONE {
                continue;
            }
            self.relate_store_consumers(
                md,
                params,
                args,
                skip,
                cur,
                store_root,
                is_recv,
                recv_ty,
                ps_elem,
                ps_pointee,
                arg_bm,
                arg_end,
            );
        }
    }

    /// Tie every consumer argument that shares the storage's region to the storage, and diagnose a
    /// borrow that is not declared to outlive it. Shared by the receiver and `&mut C` storage kinds.
    pub fn relate_store_consumers(
        self: &mut Self,
        md: DefId,
        params: NodeList,
        args: NodeList,
        skip: u32,
        sidx: i32,
        store_root: NodeId,
        is_recv: bool,
        recv_ty: TypeId,
        ps_elem: TypeId,
        ps_pointee: NodeId,
        arg_bm: u32,
        arg_end: u32,
    ) {
        let region = self.tc_binding_depth(store_root) as u16;
        let is_ref_store = self.tc_is_ref_param(store_root);
        let mut elem_lt = tok::Span { start: 0, end: 0 };
        if is_ref_store {
            elem_lt = self.tc_container_elem_lt(
                self.cur_module(),
                unsafe (*self.cur_ast()).at_const(store_root).as_data.parameter.ty,
            );
        }
        for c in skip..params.len.min(args.len + skip) {
            if c as i32 == sidx {
                continue;
            }
            let ca = c - skip;
            let aid = unsafe (*self.cur_ast()).list(args)[ca as usize];
            let shares = self.relate_consumer_shares(md, c, aid, is_recv, recv_ty, ps_elem, ps_pointee);
            if !shares {
                continue;
            }
            for bi in arg_bm..arg_end {
                if unsafe self.borrows[bi as usize].binding == NODE_NONE && unsafe self.borrows[bi as usize].root != NODE_NONE && unsafe self.borrows[bi as usize].root != store_root {
                    unsafe self.borrows[bi as usize].binding = store_root;
                    unsafe self.borrows[bi as usize].region = region;
                }
            }
            let vbase = self.tc_place_base_binding(aid);
            if vbase != NODE_NONE && vbase != store_root {
                self.tc_cross_tie(vbase, store_root);
            }
            let cp = self.tc_ident_ref_param(aid);
            let mut escapes = false;
            if is_ref_store && cp != NODE_NONE && cp != store_root {
                // A storage argument naming the caller's parameter directly relates the callee's
                // lifetimes position by position; any other storage place uses its element lifetime.
                let mut sp = NODE_NONE;
                if !is_recv {
                    sp = self.tc_ident_ref_param(unsafe (*self.cur_ast()).list(args)[(sidx as u32 - skip) as usize]);
                }
                if sp == store_root {
                    escapes = !self.relate_store_lts_ok(md, c, sp, cp, ps_pointee);
                } else {
                    escapes = !self.tc_lifetime_outlives(self.tc_value_source_lifetime(aid), elem_lt);
                }
            }
            if escapes {
                let asp = unsafe (*self.cur_ast()).at_const(aid).span;
                let di = self.tc_region_diag(
                    asp.start,
                    asp.end - asp.start,
                    format(
                        "borrowed value does not live long enough: it is stored into caller-visible data whose lifetime it is not declared to outlive",
                    ),
                );
                self.tc_region_note(
                    di,
                    format(
                        "tie the lifetimes with a shared parameter, e.g. `fn f<'a>(dst: &mut Vector<&'a T>, src: &'a T)`",
                    ),
                );
            }
        }
    }

    /// Rust's outlives check of a call's universal regions: callee parameter `c` stores into the
    /// pointee `ps_pointee` of `&mut` parameter `sidx`, and both arguments are the caller's reference
    /// parameters `sp` and `cp`. Each callee lifetime the pointee names is the caller lifetime at the
    /// same position of `sp`'s pointee (invariant, so exactly that one); every caller lifetime of
    /// `cp`'s type at a position where parameter `c` names it must outlive it. False when one does not.
    pub fn relate_store_lts_ok(self: &mut Self, md: DefId, c: u32, sp: NodeId, cp: NodeId, ps_pointee: NodeId) bool {
        let fa = self.mod_ast(md.module);
        let params = unsafe (*fa).at_const(md.node).as_data.function.params;
        let ct = unsafe (*fa).at_const(unsafe (*fa).list(params)[c as usize]).as_data.parameter.ty;
        let rst = unsafe (*self.cur_ast()).at_const(sp).as_data.parameter.ty;
        let rct = unsafe (*self.cur_ast()).at_const(cp).as_data.parameter.ty;
        if unsafe (*self.cur_ast()).at_const(rst).kind != NodeKind::NODE_REFERENCE_TYPE {
            return true;
        }
        let rpointee = unsafe (*self.cur_ast()).at_const(rst).as_data.indirect_type.ty;
        let mut lts = Spans8 {};
        let mut nl: i32 = 0;
        self.tc_typenode_lifetimes(md.module, ps_pointee, &mut lts, &mut nl, 0);
        for i in 0..nl {
            let mut ds = Spans8 {};
            let mut nd: i32 = 0;
            self.tc_caller_lts_at(md.module, ps_pointee, rpointee, lts[i as usize], &mut ds, &mut nd, 0);
            if nd == 0 {
                continue;
            }
            let mut ss = Spans8 {};
            let mut ns: i32 = 0;
            self.tc_caller_lts_at(md.module, ct, rct, lts[i as usize], &mut ss, &mut ns, 0);
            if ns as usize > ss.len() {
                // More positions than recorded: fail closed.
                return false;
            }
            for k in 0..ns {
                if !self.tc_lifetime_outlives(ss[k as usize], ds[0]) {
                    return false;
                }
            }
        }
        return true;
    }

    /// Append to `out` the lifetime caller type node `rt` (current module) has at each position where
    /// callee type node `ct` of module `cm` names lifetime `l`, pairing the two nodes structurally (the
    /// empty span for an elided caller lifetime). `*n` counts every pair, past `out`'s capacity too.
    pub fn tc_caller_lts_at(
        self: &Self,
        cm: ModuleId,
        ct: NodeId,
        rt: NodeId,
        l: tok::Span,
        out: &mut Spans8,
        n: &mut i32,
        depth: i32,
    ) {
        if ct == NODE_NONE || rt == NODE_NONE || depth > 6 {
            return;
        }
        let ca = self.mod_ast(cm);
        let ra = self.cur_ast();
        let cn = unsafe (*ca).at_const(ct);
        let rn = unsafe (*ra).at_const(rt);
        if cn.kind != rn.kind {
            return;
        }
        if cn.kind == NodeKind::NODE_REFERENCE_TYPE || cn.kind == NodeKind::NODE_SLICE_TYPE {
            if spans_eq2(
                self.mod_src(cm),
                self.tc_lt_name_in(cm, cn.as_data.indirect_type.lifetime),
                self.mod_src(cm),
                l,
            ) {
                if (*n) as usize < out.len() {
                    out[(*n) as usize] = self.tc_lt_name(rn.as_data.indirect_type.lifetime);
                }
                *n = *n + 1;
            }
            self.tc_caller_lts_at(cm, cn.as_data.indirect_type.ty, rn.as_data.indirect_type.ty, l, out, n, depth + 1);
            return;
        }
        if cn.kind == NodeKind::NODE_ARRAY_TYPE {
            self.tc_caller_lts_at(
                cm,
                cn.as_data.array_type.element,
                rn.as_data.array_type.element,
                l,
                out,
                n,
                depth + 1,
            );
            return;
        }
        let mut cs = NodeList { start: 0, len: 0 };
        let mut rs = NodeList { start: 0, len: 0 };
        if cn.kind == NodeKind::NODE_TUPLE_TYPE {
            cs = cn.as_data.array_literal.elements;
            rs = rn.as_data.array_literal.elements;
        } else if cn.kind == NodeKind::NODE_TYPE_PATH {
            let cd = unsafe (*ca).resolution_def(ct);
            let rd = unsafe (*ra).resolution_def(rt);
            if cd.node == NODE_NONE || cd.node != rd.node || cd.module != rd.module || self.tc_path_is_self(
                self.cur_module(),
                rt,
            ) {
                return;
            }
            cs = cn.as_data.type_path.args;
            rs = rn.as_data.type_path.args;
        }
        // Lifetime arguments pair by lifetime index and type arguments by type index; an unwritten
        // caller lifetime argument is elided.
        let mut nlt: u32 = 0;
        let mut nty: u32 = 0;
        for i in 0..cs.len {
            let cid = unsafe (*ca).list(cs)[i as usize];
            let is_lt = unsafe (*ca).at_const(cid).kind == NodeKind::NODE_LIFETIME;
            let rid = self.tc_nth_arg(rs, is_lt, pick(is_lt, nlt, nty));
            if !is_lt {
                nty = nty + 1;
                self.tc_caller_lts_at(cm, cid, rid, l, out, n, depth + 1);
                continue;
            }
            nlt = nlt + 1;
            if spans_eq2(self.mod_src(cm), self.tc_lt_name_in(cm, cid), self.mod_src(cm), l) {
                if (*n) as usize < out.len() {
                    out[(*n) as usize] = self.tc_lt_name(rid);
                }
                *n = *n + 1;
            }
        }
    }

    /// The `k`-th lifetime argument (`lts`) or type argument (otherwise) of current-module list `args`,
    /// or NODE_NONE.
    pub fn tc_nth_arg(self: &Self, args: NodeList, lts: bool, k: u32) NodeId {
        let a = self.cur_ast();
        let mut seen: u32 = 0;
        for i in 0..args.len {
            let aid = unsafe (*a).list(args)[i as usize];
            if unsafe (*a).at_const(aid).kind == NodeKind::NODE_LIFETIME == lts {
                if seen == k {
                    return aid;
                }
                seen = seen + 1;
            }
        }
        return NODE_NONE;
    }

    /// Does consumer parameter `c` (argument `aid`) share the storage's region? The receiver storage
    /// shares through a type variable the receiver instantiates; a `&mut C` storage shares when its
    /// pointee mentions the consumer's type variable or a named lifetime the consumer also carries.
    pub fn relate_consumer_shares(
        self: &mut Self,
        md: DefId,
        c: u32,
        aid: NodeId,
        is_recv: bool,
        recv_ty: TypeId,
        ps_elem: TypeId,
        ps_pointee: NodeId,
    ) bool {
        if is_recv {
            return self.tc_param_shares_recv_region(md, recv_ty, c as i32, aid);
        }
        let fa = self.mod_ast(md.module);
        let params = unsafe (*fa).at_const(md.node).as_data.function.params;
        let pv_ty = unsafe (*fa).at_const(unsafe (*fa).list(params)[c as usize]).as_data.parameter.ty;
        if pv_ty == NODE_NONE {
            return false;
        }
        let vt = self.decl_type_in(md.module, unsafe (*fa).list(params)[c as usize]);
        if vt != TYPE_NONE && self.type_at(vt).kind == TypeKind::TYPE_GENERIC {
            if self.tc_ref_covers_generic(ps_elem, self.type_at(vt).as_data.decl, self.type_at(vt).module) {
                return true;
            }
        }
        let mut vlts = Spans8 {};
        let mut nvlt: i32 = 0;
        self.tc_typenode_lifetimes(md.module, pv_ty, &mut vlts, &mut nvlt, 0);
        for li in 0..nvlt {
            if self.tc_typenode_covers_lt(md.module, ps_pointee, vlts[li as usize]) {
                return true;
            }
        }
        return false;
    }

    /// Closure post-body pass: capture-of-moved/borrowed checks, capture moved-recording, borrow
    /// re-exposure through the closure value, and implicit mut-capture borrows. Everything the
    /// walk does after the closure body; shared with the tape replay.
    pub fn bc_closure_caps(self: &mut Self, id: NodeId) {
        let a = self.cur_ast();
        let caps = unsafe (*a).at_const(id).as_data.closure.captures;
        let mut_caps = (unsafe (*a).at_const(id).as_data.closure.mut_caps) as u64;
        let ref_caps = (unsafe (*a).at_const(id).as_data.closure.ref_caps) as u64;
        for i in 0..caps.len {
            let cid = unsafe (*a).list(caps)[i as usize];
            let cty = unsafe (*a).type_of(cid);
            let by_ptr = ((mut_caps | ref_caps) >> i as u64 & 1u64) != 0;
            if by_ptr || !self.tc_capture_owns(cty) {
                continue;
            }
            // Capture-of-moved is IR-owned (CAT_C_CAP).
            for f in 0..self.icx.nclos {
                if self.tc_capture_index(unsafe self.icx.clos_stack[f as usize], cid) >= 0 {
                    let sp = unsafe (*a).at_const(id).span;
                    self.errors.emit_span(
                        sp,
                        format("cannot take ownership of a value also captured by an enclosing closure"),
                    );
                    break;
                }
            }
            for b in 0..self.nborrows {
                if unsafe self.borrows[b as usize].root == cid && self.borrow_dead_after(
                    unsafe self.borrows[b as usize],
                    id,
                ) {
                    // Capture-while-borrowed is IR-owned.
                    self.borrow_tombstone_at(b);
                }
            }
            self.bc_push_moved(cid);
        }
        // Re-expose borrows held by the captured bindings as borrows of the closure value itself
        // (origin = the closure node): storing or returning the closure carries them.
        let cap_bw = self.nborrows;
        for i in 0..caps.len {
            let cid = unsafe (*a).list(caps)[i as usize];
            for b in 0..cap_bw {
                let bb = unsafe self.borrows[b as usize];
                if bb.binding == cid && bb.root != NODE_NONE {
                    self.borrow_push(bb.root, bb.kind, bb.place, id);
                }
            }
        }
        // A MUTATED capture of a plain local (`mut_caps` bit set, not a reference/pointer binding)
        // is an implicit `&mut` of that local: the env holds a pointer to it. Give the closure
        // value a mutable borrow rooted at the local so storing or returning it past the local's
        // scope is caught exactly like an explicit `&local` capture; a synchronously-consumed
        // closure never ties the borrow to an outer place, so it stays fine.
        for i in 0..caps.len {
            if (mut_caps >> i as u64 & 1u64) == 0 {
                continue;
            }
            let cid = unsafe (*a).list(caps)[i as usize];
            let cty = unsafe (*a).type_of(cid);
            if cty == TYPE_NONE {
                continue;
            }
            let ck = self.type_at(cty).kind;
            if ck == TypeKind::TYPE_REFERENCE || ck == TypeKind::TYPE_POINTER {
                // A reference/pointer binding's own borrow is re-exposed above.
                continue;
            }
            self.borrow_push(cid, BORROW_MUT, cid, id);
        }
        // A BORROWED capture (`ref_caps`) is an implicit `&` of its local, held the same way.
        for i in 0..caps.len {
            if (ref_caps >> i as u64 & 1u64) != 0 {
                let cid = unsafe (*a).list(caps)[i as usize];
                self.borrow_push(cid, BORROW_SHARED, cid, id);
            }
        }
    }

    /// Check a method call's receiver: reject a reference-returning method on an owned temporary and
    /// tie the returned borrow to the receiver.
    pub fn check_call_receiver(self: &mut Self, callee_id: NodeId, fmod: ModuleId, params: NodeList, returns: NodeList) {
        let a = self.cur_ast();
        let mem = unsafe (*a).at_const(callee_id).as_data.member.member;
        let recv = unsafe (*a).at_const(callee_id).as_data.member.object;
        // A method returning a reference borrows its receiver (elision). If the receiver is a
        // TEMPORARY (an rvalue: a call/constructor result, not a named place), the returned
        // reference would outlive the temporary: today the temporary is kept alive to back it but
        // never freed (leak), and any other lowering would dangle. Reject it: bind the receiver to
        // a variable first. (`self`-by-value methods return an owned value, not a borrow of a temp.)
        let rvk = self.type_at(unsafe (*a).type_of(recv)).kind;
        let recv_is_owned_temp = !self.is_place(recv) && rvk != TypeKind::TYPE_REFERENCE && rvk != TypeKind::TYPE_POINTER;
        if returns.len == 1 && recv_is_owned_temp {
            let fa0 = self.mod_ast(fmod);
            let r0 = unsafe (*fa0).list(returns)[0];
            if unsafe (*fa0).at_const(r0).kind == NodeKind::NODE_REFERENCE_TYPE {
                let rsp = unsafe (*a).at_const(recv).span;
                self.errors.emit_span(rsp, format("cannot borrow into a temporary value; bind it to a variable first"));
            }
        }
        let is_free = span_is(self.mod_src(self.cur_module()), unsafe (*a).at_const(mem).as_data.name.text, "free");
        if is_free {
            let rty = *self.type_at(unsafe (*a).type_of(recv));
            let mut thru = NODE_NONE;
            if rty.kind == TypeKind::TYPE_REFERENCE && unsafe (*a).at_const(recv).kind == NodeKind::NODE_IDENTIFIER {
                let rd = unsafe (*a).resolution_def(recv);
                if rd.module == self.cur_module() {
                    thru = rd.node;
                }
            } else if rty.kind != TypeKind::TYPE_POINTER {
                thru = self.place_through_binding(recv);
            }
            let mut through_owner = false;
            let mut i: u32 = 0;
            while thru != NODE_NONE && i < self.nborrows && !through_owner {
                let b = unsafe self.borrows[i as usize];
                if b.binding == thru && b.root != NODE_NONE {
                    let rk = unsafe (*a).at_const(b.root).kind;
                    if rk == NodeKind::NODE_LET || rk == NodeKind::NODE_PATTERN_NAME || rk == NodeKind::NODE_IDENTIFIER || rk == NodeKind::NODE_FOR || rk == NodeKind::NODE_INLINE_FOR {
                        // A free THROUGH a reference binding never reaches the Core IR free access
                        // (the receiver operand is already a reference), so that case stays noisy.
                        if rty.kind == TypeKind::TYPE_REFERENCE {
                            let rsp = unsafe (*a).at_const(recv).span;
                            self.errors.emit_span(
                                rsp,
                                format("cannot free a borrowed value: its owning binding frees it again at scope exit"),
                            );
                        }
                        through_owner = true;
                    }
                }
                i = i + 1;
            }
            if !through_owner && rty.kind != TypeKind::TYPE_POINTER && rty.kind != TypeKind::TYPE_REFERENCE && self.tc_type_is_free(
                unsafe (*a).type_of(recv),
            ) {
                self.tc_mark_move(recv);
            }
            return;
        }
        let fa = self.mod_ast(fmod);
        let p0 = unsafe (*fa).list(params)[0];
        let pt = unsafe (*fa).at_const(p0).as_data.parameter.ty;
        let mut ptk = NodeKind::NODE_NONE_KIND;
        if pt != NODE_NONE {
            ptk = unsafe (*fa).at_const(pt).kind;
        }
        if ptk != NodeKind::NODE_POINTER_TYPE && ptk != NodeKind::NODE_REFERENCE_TYPE {
            if unsafe (*a).deref_use_at(mem) != null {
                self.borrow_report_conflict(recv, BORROW_SHARED, recv);
            }
        } else {
            let mut bk = BORROW_SHARED;
            if unsafe (*fa).at_const(pt).as_data.indirect_type.qualifier == TypeQualifier::TYPE_QUAL_MUT {
                bk = BORROW_MUT;
            }
            let mut ret_ref = false;
            if returns.len == 1 {
                let rr0 = unsafe (*fa).list(returns)[0];
                let rtn = unsafe (*fa).slot_type_node(rr0);
                ret_ref = rtn != NODE_NONE && unsafe (*fa).at_const(rtn).kind == NodeKind::NODE_REFERENCE_TYPE;
            }
            if ret_ref {
                self.borrow_create(recv, bk, recv);
            } else {
                self.borrow_report_conflict(recv, bk, recv);
            }
        }
    }
    /// The lifetime name written on reference type node `tyn`, or the empty span.
    pub fn tc_ref_typenode_lt(self: &Self, tyn: NodeId) tok::Span {
        if tyn == NODE_NONE {
            return tok::Span { start: 0, end: 0 };
        }
        let n = unsafe (*self.cur_ast()).at_const(tyn);
        if n.kind != NodeKind::NODE_REFERENCE_TYPE {
            return tok::Span { start: 0, end: 0 };
        }
        return self.tc_lt_name(n.as_data.indirect_type.lifetime);
    }

    /// The typechecker's recorded callee for call `id`: fmod<<40 | fdecl<<8 | receiver-skip (the
    /// call_info side table); 0 = no resolution recorded, and bc_call skips the call-boundary analyses.
    pub fn bc_call_info(self: &Self, id: NodeId) u64 {
        switch unsafe (*self.cur_ast()).call_info.get(&id) {
            Some(v) => {
                return *v;
            },
            _ => {},
        };
        return 0u64;
    }
}
