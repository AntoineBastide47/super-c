// The constant-time check: in each `@constant_time` body (`Body.ct`) of the LIR the code generators
// receive, no branch, memory address or variable-time operation depends on a secret. A value is secret
// when it is an `O_SECRET` (a read from inside a `std::crypto::secret::Secret`), or an operand, argument
// or edge argument of it is, except an `O_PUBLIC` (`declassify`). Only a constant-time body reads a
// secret, and a secret leaves a body only inside a `Secret` (in memory: no secret argument, no secret
// result), so the check of each body is complete by itself, and a body that reads no secret computes on
// none. No body calls a C function that takes a `Secret` or takes its address. Then every `O_SECRET` and
// `O_PUBLIC` of every body is replaced by its operand, so the generators see the code the program has
// without them.
import lir::ir as *;
import lir::verify as lv;
import module::loader as loader;
import utils::errors as diag;
import utils::diag_codes as dc;
import ast::ast as ast;

/// The rules a secret breaks (`Check::violations`), one message each.
pub(package) const R_BRANCH: u8 = 0;
pub(package) const R_ADDR: u8 = 1;
pub(package) const R_DIV: u8 = 2;
pub(package) const R_FLOAT: u8 = 3;
pub(package) const R_ATOMIC: u8 = 4;
pub(package) const R_VOP: u8 = 5;
pub(package) const R_SYS: u8 = 6;
pub(package) const R_SELECT: u8 = 7;
pub(package) const R_INDIRECT: u8 = 8;
pub(package) const R_CALL: u8 = 9;
pub(package) const R_CALL_SEC: u8 = 10;
pub(package) const R_RET: u8 = 11;
pub(package) const R_OUTSIDE: u8 = 12;

// Per rule, its message (`message`).
const MESSAGES: [str<'static>; 13] = [
    "a branch depends on a secret value",
    "a memory address depends on a secret value",
    "a division or remainder of a secret value: its time depends on the operands",
    "a float operation on a secret value: its time may depend on the operands",
    "an atomic operation on a secret value",
    "a vector operation on a secret value: its code may branch on the lanes",
    "a system call with a secret value",
    "a select on a secret condition of a value that is not an integer of at most 64 bits or a pointer: its code may branch",
    "an indirect call with a secret target or argument",
    "a call passes a secret value: a secret leaves a function only inside a 'Secret'",
    "a call or the address of a C function that takes a 'Secret'",
    "a function returns a secret value: a secret leaves a function only inside a 'Secret'",
    "a secret is read outside a '@constant_time' function",
];

/// The message of rule `r`.
pub(package) const fn message(r: u8) str<'static> {
    return MESSAGES[r as usize];
}

/// Check every body of `pk`, the LIR of `p` (`Check::violations`), and report each violation at its source;
/// then remove the secret marks of every body. Whether no body broke a rule. A package that does not load
/// `std::crypto::secret` holds no secret and no mark.
pub(package) fn run(p: &mut loader::Package, pk: &mut Package) bool {
    if !loaded(p) {
        return true;
    }
    let mut c = Check::new();
    let mut ok = true;
    for s in 0..pk.syms.len() {
        let sy = pk.syms[s];
        if sy.kind != SK_FUNC || sy.def == NONE {
            continue;
        }
        let mut found = replace(&mut c.found, Vector::<u64>::new());
        found.truncate(0);
        c.violations(pk, sy.def, &mut found);
        if found.len() != 0 && ok {
            ok = false;
            c.map_files(p, pk);
        }
        for q in 0..found.len() {
            c.report(p, pk, s as u32, (found[q] >> 8) as usize, found[q] as u8);
        }
        c.found = found;
    }
    for k in 0..c.errs.len() {
        let m = c.errs_mod[k] as usize;
        let e = c.errs.index_mut(k);
        e.finalize(&p.modules.at(m).source, &p.modules.at(m).file);
        e.log();
    }
    for k in 0..pk.bodies.len() {
        c.strip(pk.bodies.index_mut(k));
    }
    return ok;
}

// The rules body `b` of `pk`, which is not constant-time, breaks: R_OUTSIDE at each read of a secret, and
// R_CALL_SEC at each call or address of a C function that takes a `Secret`.
fn outside(pk: &Package, b: &Body, out: &mut Vector<u64>) {
    for i in 0..b.insts.len() {
        let t = b.insts[i];
        if t.op == O_SECRET {
            out.push(i as u64 << 8 | R_OUTSIDE as u64);
        } else if takes_secret(pk, b, t) {
            out.push(i as u64 << 8 | R_CALL_SEC as u64);
        }
    }
}

// Whether instruction `t` of `b` calls or takes the address of a C function that takes a `Secret`
// (`Sym.sec`), which may read the secret with any operation.
const fn takes_secret(pk: &Package, b: &Body, t: Inst) bool {
    return (t.op == O_CALL || t.op == O_SYMADDR) && pk.syms[b.syms[t.a as usize] as usize].sec;
}

/// Whether package `p` loads `std::crypto::secret`: its LIR may hold secrets, and the check reports at the
/// sources, so the line tables and the source text stay to the end (`driver::emit::syntax_done`).
pub(package) fn loaded(p: &loader::Package) bool {
    return p.find("std::crypto::secret") >= 0;
}

/// The check's tables, reused from body to body.
pub(package) struct Check {
    taint: Vector<bool>, // per instruction, then per block parameter: the value is secret
    us: Vector<Value>,
    rep: Vector<Value>, // `strip`: per instruction, the value that replaces it
    fmod: Map<u32, u32>, // file id to module
    seen: Set<u64>, // the rule and location of each violation reported
    errs: Vector<diag::Errors>, // one per module with an error, in order of first error
    errs_mod: Vector<u32>,
    found: Vector<u64>, // `violations` of the body `run` checks
}

extend Check {
    pub(package) fn new() Check {
        return Check {
            taint: Vector::<bool>::new(),
            us: Vector::<Value>::new(),
            rep: Vector::<Value>::new(),
            fmod: Map::<u32, u32>::new(),
            seen: Set::<u64>::new(),
            errs: Vector::<diag::Errors>::new(),
            errs_mod: Vector::<u32>::new(),
            found: Vector::<u64>::new(),
        };
    }

    const fn secret(self: &Self, n: usize, v: Value) bool {
        if v == VNONE {
            return false;
        }
        if (v & VPARAM) != 0 {
            return self.taint[n + (v & ~VPARAM) as usize];
        }
        return self.taint[(v & ~VFLAG) as usize];
    }

    // Whether a value instruction `t` of `b` uses (its edges' arguments aside) is secret.
    fn any_secret(self: &mut Self, b: &Body, n: usize, t: Inst) bool {
        lv::uses(b, t, &mut self.us);
        for q in 0..self.us.len() {
            if self.secret(n, self.us[q]) {
                return true;
            }
        }
        return false;
    }

    /// The rules body `k` of `pk` breaks, appended to `out` in instruction order: `i << 8 | rule` for
    /// instruction `i`. A body that is not constant-time breaks R_OUTSIDE and R_CALL_SEC alone (`outside`).
    pub(package) fn violations(self: &mut Self, pk: &Package, k: u32, out: &mut Vector<u64>) {
        let b = &pk.bodies[k as usize];
        if !b.ct {
            outside(pk, b, out);
            return;
        }
        let n = b.insts.len();
        fill(&mut self.taint, n + b.params.len(), false);
        // Each sweep that changes marks one more value, so at most one sweep per value and a last one.
        let mut changed = true;
        let mut sweeps: usize = 0;
        while changed {
            assert(sweeps <= n + b.params.len(), "ct: the secret values do not settle");
            sweeps += 1;
            changed = false;
            for i in 0..n {
                let t = b.insts[i];
                if !self.taint[i] {
                    let s = if t.op == O_SECRET {
                        true
                    } else if t.op == O_PUBLIC {
                        false
                    } else {
                        self.any_secret(b, n, t)
                    };
                    if s {
                        self.taint[i] = true;
                        changed = true;
                    }
                }
                for e in 0..edge_count(t) {
                    let ed = edge_of(b, t, e);
                    let to = b.blocks[b.edge_target(ed) as usize].param_start as usize;
                    for x in 0..b.edge_nargs(ed) {
                        if !self.taint[n + to + x as usize] && self.secret(n, b.edge_arg(ed, x)) {
                            self.taint[n + to + x as usize] = true;
                            changed = true;
                        }
                    }
                }
            }
        }
        for i in 0..n {
            let r = self.rule(pk, b, n, b.insts[i]);
            if r != NONE {
                out.push(i as u64 << 8 | r as u64);
            }
        }
    }

    // The rule instruction `t` of `b` breaks, NONE for none.
    fn rule(self: &mut Self, pk: &Package, b: &Body, n: usize, t: Inst) u32 {
        let op = t.op;
        if op == O_BR || op == O_SWITCH {
            return ast::pick(self.secret(n, t.a), R_BRANCH, NONE);
        }
        if op == O_LOAD || op == O_STORE {
            return ast::pick(self.secret(n, t.a), R_ADDR, NONE);
        }
        if op == O_MEMCPY || op == O_MEMSET {
            let s = self.secret(n, t.a) || self.secret(n, t.c) || op == O_MEMCPY && self.secret(n, t.b);
            return ast::pick(s, R_ADDR, NONE);
        }
        // The generators lower a lane select (`O_VSEL`) to bitwise operations, and a select of an integer
        // of up to 64 bits or of a pointer to a conditional move; another select may branch.
        if op == O_SELECT {
            let narrow = is_int(t.ty) && t.ty != T_I128 || t.ty == T_PTR;
            return ast::pick(self.secret(n, t.a) && !narrow, R_SELECT, NONE);
        }
        if op == O_CALL && self.any_secret(b, n, t) {
            return R_CALL;
        }
        if takes_secret(pk, b, t) {
            return R_CALL_SEC;
        }
        if op == O_CALL {
            return NONE;
        }
        if op == O_RET {
            return ast::pick(self.secret(n, t.a), R_RET, NONE);
        }
        let r = if op >= O_SDIV && op <= O_UREM {
            R_DIV
        } else if op == O_FCMP || op >= O_FADD && op <= O_FDIV || op >= O_FPEXT && op <= O_UITOFP || op == O_FMA || op == O_HTOF || op == O_FTOH || op == O_FSQRT {
            R_FLOAT
        } else if op >= O_ALOAD && op <= O_ACAS {
            R_ATOMIC
        } else if op == O_VOP {
            R_VOP
        } else if op == O_SYS {
            R_SYS
        } else if op == O_CALLIND {
            R_INDIRECT
        } else {
            return NONE;
        };
        return ast::pick(self.any_secret(b, n, t), r, NONE);
    }

    // Each file of `pk` that is a module's source, to that module (`offset`).
    fn map_files(self: &mut Self, p: &loader::Package, pk: &Package) {
        let mut by_path = Map::<str, u32>::new();
        for m in 0..p.modules.len() {
            by_path.insert(&p.modules.at(m).file, m as u32);
        }
        for f in 0..pk.files.len() {
            let nm = pk.spell(pk.files[f]);
            if let Some(m) = by_path.get(&nm) {
                self.fmod.insert(f as u32, *m);
            }
        }
    }

    // Report rule `r` at instruction `i` of the body of symbol `s`, once per rule and location; without a
    // location, by the symbol's name.
    fn report(self: &mut Self, p: &loader::Package, pk: &Package, s: u32, i: usize, r: u8) {
        let b = &pk.bodies[pk.syms[s as usize].def as usize];
        let mut li = b.locs[i];
        let site = if b.inl.len() != 0 {
            b.inl[i]
        } else {
            0
        };
        if li == 0 {
            li = site;
        }
        if li == 0 {
            // No location: the body's first one.
            for j in 0..b.locs.len() {
                if b.locs[j] != 0 {
                    li = b.locs[j];
                    break;
                }
            }
        }
        let key = r as u64 << 32 | li as u64;
        if self.seen.contains(&key) {
            return;
        }
        self.seen.insert(key);
        let (m, at) = if li == 0 {
            (NONE, 0u32)
        } else {
            self.offset(p, b.lines[li as usize])
        };
        if m == NONE {
            eprintln("error: {} in '@constant_time' function '{}'", message(r), pk.spell(pk.syms[s as usize].name));
            return;
        }
        let mut k: usize = 0;
        while k < self.errs_mod.len() && self.errs_mod[k] != m {
            k += 1;
        }
        if k == self.errs_mod.len() {
            self.errs.push(diag::Errors::new());
            self.errs_mod.push(m);
        }
        let ix = self.errs.index_mut(k).emit_ordered(dc::NOT_CONSTANT_TIME, 0, at, 1, String::from_str(message(r)));
        if site != 0 && site != li && ix < diag::ERRORS_MAX {
            let l = b.lines[site as usize];
            let (sm, _) = self.offset(p, l);
            let note = if sm == NONE {
                format("in the '@constant_time' function, inlined from its call at line {}", l.line)
            } else {
                format(
                    "in the '@constant_time' function, inlined from its call at {}:{}:{}",
                    p.modules.at(sm as usize).file.as_str(),
                    l.line,
                    l.col,
                )
            };
            self.errs.index_mut(k).note_at(ix, note);
        }
    }

    // The module and byte offset of location `l`; NONE for a file no module has.
    const fn offset(self: &Self, p: &loader::Package, l: Loc) (u32, u32) {
        let m = switch self.fmod.get(&l.file) {
            Some(x) => *x,
            None => NONE,
        };
        if m == NONE || m as usize >= p.lines.len() || l.line == 0 || l.line as usize > p.lines[m as usize].len() {
            return (NONE, 0);
        }
        return (m, p.lines[m as usize][(l.line - 1) as usize] + l.col - 1);
    }

    /// Replace each `O_SECRET` and `O_PUBLIC` of `b` by its operand, then make it a constant nothing reads,
    /// which no generator emits.
    pub(package) fn strip(self: &mut Self, b: &mut Body) {
        let n = b.insts.len();
        let mut any = false;
        for i in 0..n {
            any = any || b.insts[i].op == O_SECRET || b.insts[i].op == O_PUBLIC;
        }
        if !any {
            return;
        }
        self.rep.truncate(0);
        for i in 0..n {
            self.rep.push(i as Value);
        }
        // A mark's operand is defined before it in a dominator, not always at a lower index: chains of
        // marks resolve in at most `n` steps each.
        for i in 0..n {
            let mut v = i as Value;
            let mut steps: usize = 0;
            while (v & (VPARAM | VFLAG)) == 0 && v != VNONE && (b.insts[v as usize].op == O_SECRET || b.insts[v as usize].op == O_PUBLIC) {
                assert(steps < n, "ct: a cycle of secret marks");
                v = b.insts[v as usize].a;
                steps += 1;
            }
            self.rep[i] = v;
        }
        for i in 0..n {
            let t = b.insts[i];
            let f = op_info(t.op).form;
            let mut u = t;
            if lv::operand_a(f) {
                u.a = self.re(t.a);
            }
            if lv::operand_b(f) {
                u.b = self.re(t.b);
            }
            if lv::operand_c(f) {
                u.c = self.re(t.c);
            }
            b.insts[i] = u;
            if f == F_CALL || f == F_CALLIND {
                for q in 0..t.aux as u32 {
                    b.pool[(t.c + q) as usize] = self.re(b.pool[(t.c + q) as usize]);
                }
            } else if f == F_VOP || f == F_ASM {
                for q in 0..t.b {
                    b.pool[(t.a + q) as usize] = self.re(b.pool[(t.a + q) as usize]);
                }
            }
            for e in 0..edge_count(t) {
                let ed = edge_of(b, t, e);
                for x in 0..b.edge_nargs(ed) {
                    b.pool[(ed + 2 + x) as usize] = self.re(b.pool[(ed + 2 + x) as usize]);
                }
            }
        }
        for x in 0..b.scopes.len() {
            b.scopes.index_mut(x).root = self.re(b.scopes[x].root);
        }
        for i in 0..n {
            if b.insts[i].op == O_SECRET || b.insts[i].op == O_PUBLIC {
                b.insts[i] = iconst(T_I8, 0);
            }
        }
    }

    // The value that replaces value `v` (`strip`).
    const fn re(self: &Self, v: Value) Value {
        if v == VNONE || (v & VPARAM) != 0 {
            return v;
        }
        if (v & VFLAG) != 0 {
            return v;
        }
        return self.rep[v as usize];
    }
}
