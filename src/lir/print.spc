// The LIR text form: a whole package (its data model, files, symbols, data and bodies) as lines that
// `lir::parse` reads back. Every table is written: a body's layouts and stack slots open it, each call
// carries its signature, and a location follows its instruction as `!line:col` (in the body's file) or
// `!f<k>:line:col`. Values print as `v<k>` and blocks as `b<k>`, numbered in the order they print, so
// print, parse and print give the same bytes. A `;` starts a comment.
import ast::ast as ast;
import lir::ir as *;
import ir::core as core;

/// The text of body `b` of function `name` in package `p` (its symbols and messages named).
pub(package) fn print_body(p: &Package, name: str, b: &Body, out: &mut String) {
    let mut pr = Printer::new();
    pr.body(p, name, b, out);
}

/// The text of package `p`.
pub(package) fn print_package(p: &Package, out: &mut String) {
    out.format_into("lir ptr {}", p.ptr_bytes);
    if p.vec_regs != 16 {
        out.format_into(" vec {}", p.vec_regs);
    }
    out.push_str("\n");
    for i in 0..p.files.len() {
        out.format_into("file f{} ", i);
        push_quoted(p.spell(p.files[i]), out);
        out.push_byte(b'\n');
    }
    for i in 0..p.syms.len() {
        let s = p.syms[i];
        out.push_str("sym ");
        push_name(p.spell(s.name), out);
        out.push_str(
            if s.kind == SK_FUNC {
                " fn";
            } else if s.kind == SK_TLS {
                " tls";
            } else {
                " data";
            },
        );
        out.push_str(ast::pick(s.linkage == SL_GLOBAL, " global", " local"));
        if s.used {
            out.push_str(" used");
        }
        if s.noinline {
            out.push_str(" noinline");
        }
        if s.cold {
            out.push_str(" cold");
        }
        if s.ext {
            out.push_str(" ext");
        }
        if s.sect != NONE {
            out.push_str(" section ");
            push_quoted(p.spell(s.sect), out);
        }
        out.push_byte(b'\n');
    }
    let mut pr = Printer::new();
    for i in 0..p.syms.len() {
        let s = p.syms[i];
        if s.def == NONE {
            continue;
        }
        if s.kind != SK_FUNC {
            print_data(p, s, out);
        } else {
            pr.body(p, p.spell(s.name), &p.bodies[s.def as usize], out);
        }
    }
}

fn print_data(p: &Package, s: Sym, out: &mut String) {
    let d = p.data[s.def as usize];
    out.push_str("data ");
    push_name(p.spell(s.name), out);
    out.format_into(" size {} align {}", d.size, d.align_log2);
    if d.readonly {
        out.push_str(" ro");
    }
    if d.nbytes != 0 {
        out.push_str(" bytes ");
        let bs = p.data_bytes(&d);
        for i in 0..bs.len() {
            push_hex2(bs[i], out);
        }
    }
    for k in 0..d.nrelocs {
        let r = p.relocs[(d.relocs + k) as usize];
        out.format_into(" reloc {} ", r.offset);
        push_name(p.spell(p.syms[r.sym as usize].name), out);
        push_addend(r.addend, out);
    }
    out.push_byte(b'\n');
}

// Per body: the printed number of each value and of each layout.
struct Printer {
    num: Vector<u32>, // per instruction, its value number; NONE without a result
    pnum: Vector<u32>, // per block parameter, its value number
    // Per `lines` entry an inline site uses, its place among the printed sites at its location, in order
    // of first use (`#<n>` past the first: `Scope` tells sites apart); NONE for no site.
    sord: Vector<u32>,
    sfirst: Vector<u32>,
    lay: Vector<u32>, // printed layouts' pool indexes, in number order
    file: u32, // the body's file: the file of its first location
}

extend Printer {
    fn new() Printer {
        return Printer {
            num: Vector::<u32>::new(),
            pnum: Vector::<u32>::new(),
            sord: Vector::<u32>::new(),
            sfirst: Vector::<u32>::new(),
            lay: Vector::<u32>::new(),
            file: 0,
        };
    }

    fn body(self: &mut Self, p: &Package, name: str, b: &Body, out: &mut String) {
        self.number(b);
        self.sites(b);
        out.push_str("fn ");
        push_name(name, out);
        out.push_byte(b'\n');
        self.file = NONE;
        for i in 0..b.locs.len() {
            if b.locs[i] != 0 {
                self.file = b.lines[b.locs[i] as usize].file;
                break;
            }
        }
        if self.file != NONE {
            out.format_into("  file f{}\n", self.file);
        }
        if b.naked {
            out.push_str("  naked\n");
        }
        for k in 0..self.lay.len() {
            let l = self.lay[k];
            out.format_into("  layout l{} size {} align {} [", k, b.pool[l as usize], b.pool[l as usize + 1]);
            for j in 0..b.pool[l as usize + 2] {
                if j != 0 {
                    out.push_str(", ");
                }
                out.format_into("{} ", b.pool[(l + 3 + 2 * j) as usize]);
                push_type(b.pool[(l + 4 + 2 * j) as usize] as u8, out);
            }
            out.push_str("]\n");
        }
        out.push_str("  sig ");
        self.sig(b, b.sig, out);
        out.push_byte(b'\n');
        for k in 0..b.refs.len() {
            let r = b.refs[k];
            if r != 0 {
                out.format_into("  ref p{} {}", k, r & REF_BYTES);
                if (r & REF_INNER) != 0 {
                    out.push_str(" inner");
                }
                if (r & REF_NOALIAS) != 0 {
                    out.push_str(" noalias");
                }
                out.push_byte(b'\n');
            }
        }
        for k in 0..64u32 {
            if (b.bools >> k as u64 & 1) != 0 {
                out.format_into("  bool p{}\n", k);
            }
        }
        for x in 0..b.scopes.len() {
            let sc = b.scopes[x];
            out.push_str("  scope @");
            self.site(b, sc.site, out);
            out.format_into(" g{} ", sc.group);
            self.val(sc.root, out);
            out.push_byte(b'\n');
        }
        for k in 0..b.slots.len() {
            out.format_into("  slot s{} size {} align {}\n", k, b.slots[k].size, b.slots[k].align_log2);
        }
        for k in 0..b.blocks.len() {
            let blk = b.blocks[k];
            out.format_into("b{}", k);
            if blk.param_len != 0 {
                out.push_byte(b'(');
                for j in 0..blk.param_len as u32 {
                    if j != 0 {
                        out.push_str(", ");
                    }
                    out.format_into("v{}: ", self.pnum[(blk.param_start + j) as usize]);
                    push_type(b.params[(blk.param_start + j) as usize], out);
                }
                out.push_byte(b')');
            }
            out.push_byte(b':');
            if (blk.flags & BLOCK_COLD) != 0 {
                out.push_str(" cold");
            }
            if (blk.flags & BLOCK_UNLIKELY) != 0 {
                out.push_str(" unlikely");
            }
            if (blk.flags & BLOCK_NOVEC) != 0 {
                out.push_str(" novec");
            }
            out.push_byte(b'\n');
            for j in 0..blk.len {
                self.inst(p, b, blk.start + j, out);
            }
        }
    }

    // Number the values in print order (each block's parameters, then its results) and the layouts in
    // order of first use by a signature.
    fn number(self: &mut Self, b: &Body) {
        self.num.truncate(0);
        self.num.resize_default(b.insts.len());
        self.pnum.truncate(0);
        self.pnum.resize_default(b.params.len());
        self.lay.truncate(0);
        let mut n: u32 = 0;
        for k in 0..b.blocks.len() {
            let blk = b.blocks[k];
            for j in 0..blk.param_len as u32 {
                self.pnum[(blk.param_start + j) as usize] = n;
                n += 1;
            }
            for j in 0..blk.len {
                let i = (blk.start + j) as usize;
                if b.insts[i].ty != T_NONE {
                    self.num[i] = n;
                    n += ast::pick(op_info(b.insts[i].op).form == F_OVF, 2u32, 1);
                } else {
                    self.num[i] = NONE;
                }
            }
        }
        self.sig_layouts(b, b.sig);
        for k in 0..b.blocks.len() {
            let blk = b.blocks[k];
            for j in 0..blk.len {
                let t = b.insts[(blk.start + j) as usize];
                if t.op == O_CALL || t.op == O_CALLIND {
                    self.sig_layouts(b, t.b);
                }
            }
        }
    }

    fn sig_layouts(self: &mut Self, b: &Body, s: u32) {
        let np = b.pool[s as usize];
        for k in 0..np + 1 {
            let pt = if k == np {
                b.pool[s as usize + 2];
            } else {
                b.pool[(s + 3 + k) as usize];
            };
            if (pt & AGG) != 0 && self.layout_no(pt & ~AGG) == NONE {
                self.lay.push(pt & ~AGG);
            }
        }
    }

    // The printed number of the layout at pool index `l`, NONE when not yet numbered. Layouts compare
    // by content: two copies of one layout print as one.
    const fn layout_no(self: &Self, l: u32) u32 {
        for k in 0..self.lay.len() {
            if self.lay[k] == l {
                return k as u32;
            }
        }
        return NONE;
    }

    fn sig(self: &Self, b: &Body, s: u32, out: &mut String) {
        let np = b.pool[s as usize];
        let nfixed = b.pool[s as usize + 1];
        let variadic = (nfixed & SIG_VARIADIC) != 0;
        let fixed = nfixed & ~SIG_VARIADIC;
        out.push_byte(b'(');
        for k in 0..np {
            if k != 0 {
                out.push_str(", ");
            }
            if variadic && k == fixed {
                out.push_str("... ");
            }
            self.param_type(b.pool[(s + 3 + k) as usize], out);
        }
        if variadic && fixed == np {
            out.push_str(ast::pick(np == 0, "...", ", ..."));
        }
        out.push_str(") -> ");
        self.param_type(b.pool[s as usize + 2], out);
    }

    fn param_type(self: &Self, pt: u32, out: &mut String) {
        if (pt & AGG) != 0 {
            out.format_into("l{}", self.layout_no(pt & ~AGG));
        } else if pt == T_NONE as u32 {
            out.push_str("void");
        } else {
            push_type(pt as u8, out);
            if (pt & SIG_SEXT) != 0 {
                out.push_str(".s");
            }
        }
    }

    fn val(self: &Self, v: Value, out: &mut String) {
        if v == VNONE {
            out.push_str("none");
        } else if (v & VPARAM) != 0 {
            out.format_into("v{}", self.pnum[(v & ~VPARAM) as usize]);
        } else if (v & VFLAG) != 0 {
            out.format_into("v{}", self.num[(v & ~VFLAG) as usize] + 1);
        } else {
            out.format_into("v{}", self.num[v as usize]);
        }
    }

    fn edge(self: &Self, b: &Body, e: u32, out: &mut String) {
        out.format_into("b{}", b.edge_target(e));
        let n = b.edge_nargs(e);
        if n != 0 {
            out.push_byte(b'(');
            for k in 0..n {
                if k != 0 {
                    out.push_str(", ");
                }
                self.val(b.edge_arg(e, k), out);
            }
            out.push_byte(b')');
        }
    }

    fn inst(self: &Self, p: &Package, b: &Body, i: u32, out: &mut String) {
        let t = b.insts[i as usize];
        let info = op_info(t.op);
        out.push_str("  ");
        let f = info.form;
        if t.ty != T_NONE {
            self.val(i, out);
            if f == F_OVF {
                out.push_str(", ");
                self.val(VFLAG | i, out);
            }
            out.push_str(" = ");
        }
        out.push_str(info.name);
        if f == F_CMP {
            out.push_byte(b'.');
            out.push_str(cond_name(t.aux));
        } else if f == F_OVF {
            out.push_str(ast::pick(t.aux == OV_SIGNED, ".s", ".u"));
        } else if t.op == O_ARMW {
            out.push_byte(b'.');
            out.push_str(rmw_name(t.aux >> 4));
        } else if t.op == O_MEMCPY && t.aux == MEM_OVERLAP {
            out.push_str(".overlap");
        } else if t.op == O_LSHR && t.aux == SH_EXACT {
            out.push_str(".exact");
        } else if (t.op == O_FPTOSI || t.op == O_FPTOUI) && t.aux == CV_UNCHECKED {
            out.push_str(".unchecked");
        } else if t.op == O_SYS {
            out.push_byte(b'.');
            out.push_str(sys_name(t.aux));
        } else if t.op == O_VOP {
            out.push_byte(b'.');
            out.push_str(core::op_name(t.aux & VOP_CODE));
            if (t.aux & VOP_SIGNED) != 0 {
                out.push_str(".s");
            }
            if (t.aux & VOP_DSIGNED) != 0 {
                out.push_str(".ds");
            }
            if (t.aux & VOP_UNCHECKED) != 0 {
                out.push_str(".unchecked");
            }
        }
        if t.ty != T_NONE && (f != F_CMP || t.op == O_VCMP) && t.op != O_ACAS && t.op != O_SLOTADDR && t.op != O_SYMADDR && t.op != O_RETADDR && t.op != O_PTRADD {
            out.push_byte(b'.');
            push_type(t.ty, out);
        }
        if f == F_IMM {
            out.push_byte(b' ');
            let bits = t.b as u64 << 32 | t.a as u64;
            if t.op == O_FCONST {
                out.push_str("0x");
                out.push_hex(bits, false);
            } else {
                out.push_i64(sign_extend(bits, type_bits(t.ty, p.ptr_bytes)));
            }
        } else if f == F_WIDE {
            for k in 0..t.b {
                out.push_str(ast::pick(k == 0, " 0x", ", 0x"));
                out.push_hex(b.words[(t.a + k) as usize], false);
            }
        } else if f == F_SYM {
            out.push_byte(b' ');
            push_name(p.spell(p.syms[b.syms[t.a as usize] as usize].name), out);
            push_addend(t.b as i32, out);
        } else if f == F_SLOT {
            out.format_into(" s{}", t.a);
        } else if f == F_UN || f == F_RET && t.a != VNONE {
            out.push_byte(b' ');
            self.val(t.a, out);
        } else if f == F_BIN || f == F_CMP || f == F_OVF {
            out.push_byte(b' ');
            self.val(t.a, out);
            out.push_str(", ");
            self.val(t.b, out);
        } else if f == F_SYS {
            for k in 0..sys_arity(t.aux) {
                out.push_str(ast::pick(k == 0, " ", ", "));
                self.val(
                    if k == 0 {
                        t.a;
                    } else if k == 1 {
                        t.b;
                    } else {
                        t.c;
                    },
                    out,
                );
            }
        } else if f == F_TRI {
            out.push_byte(b' ');
            self.val(t.a, out);
            out.push_str(", ");
            self.val(t.b, out);
            out.push_str(", ");
            self.val(t.c, out);
            if t.op == O_ACAS {
                out.format_into(" {} {}", order_name(t.aux & 7), order_name(t.aux >> 3 & 7));
                if (t.aux & ACAS_WEAK) != 0 {
                    out.push_str(" weak");
                }
            }
        } else if f == F_PTRADD {
            out.push_byte(b' ');
            self.val(t.a, out);
            if t.b != VNONE {
                out.push_str(", ");
                self.val(t.b, out);
                out.format_into(" * {}", t.aux);
            }
            push_offset(t.c, out);
        } else if f == F_LOAD {
            out.push_byte(b' ');
            self.val(t.a, out);
            push_offset(t.c, out);
            self.mem_flags(t, out);
        } else if f == F_STORE {
            out.push_byte(b' ');
            self.val(t.b, out);
            out.push_str(", ");
            self.val(t.a, out);
            push_offset(t.c, out);
            self.mem_flags(t, out);
        } else if f == F_CALL || f == F_CALLIND {
            out.push_byte(b' ');
            if f == F_CALL {
                push_name(p.spell(p.syms[b.syms[t.a as usize] as usize].name), out);
            } else {
                self.val(t.a, out);
            }
            out.push_byte(b'(');
            for k in 0..t.aux as u32 {
                if k != 0 {
                    out.push_str(", ");
                }
                self.val(b.pool[(t.c + k) as usize], out);
            }
            out.push_str(") : ");
            self.sig(b, t.b, out);
        } else if f == F_ASM {
            // `"template" out["=r" i64, ..] in["r", ..] clobber["memory", ..] (values)`.
            let r = t.c;
            out.push_byte(b' ');
            push_quoted(p.spell(p.msgs[b.msgs[asm_template(b, r) as usize] as usize]), out);
            out.push_str(" out[");
            for k in 0..asm_nout(b, r) {
                if k != 0 {
                    out.push_str(", ");
                }
                push_quoted(p.spell(p.msgs[b.msgs[asm_out_con(b, r, k) as usize] as usize]), out);
                out.push_byte(b' ');
                push_type(asm_out_ty(b, r, k), out);
            }
            out.push_str("] in[");
            for k in 0..asm_nin(b, r) {
                if k != 0 {
                    out.push_str(", ");
                }
                push_quoted(p.spell(p.msgs[b.msgs[asm_in_con(b, r, k) as usize] as usize]), out);
            }
            out.push_str("] clobber[");
            for k in 0..asm_nclob(b, r) {
                if k != 0 {
                    out.push_str(", ");
                }
                push_quoted(p.spell(p.msgs[b.msgs[asm_clob(b, r, k) as usize] as usize]), out);
            }
            out.push_str("] (");
            for k in 0..t.b {
                if k != 0 {
                    out.push_str(", ");
                }
                self.val(b.pool[(t.a + k) as usize], out);
            }
            out.push_byte(b')');
        } else if f == F_VOP {
            out.push_str(" (");
            for k in 0..t.b {
                if k != 0 {
                    out.push_str(", ");
                }
                self.val(b.pool[(t.a + k) as usize], out);
            }
            out.push_byte(b')');
            if t.c != VNONE {
                out.push_str(" lanes [");
                for k in 0..b.pool[t.c as usize] {
                    if k != 0 {
                        out.push_str(", ");
                    }
                    out.push_u64(b.pool[(t.c + 1 + k) as usize]);
                }
                out.push_byte(b']');
            }
        } else if f == F_JMP {
            out.push_byte(b' ');
            self.edge(b, t.a, out);
        } else if f == F_BR {
            out.push_byte(b' ');
            self.val(t.a, out);
            out.push_str(", ");
            self.edge(b, t.b, out);
            out.push_str(", ");
            self.edge(b, t.c, out);
        } else if f == F_SWITCH {
            out.push_byte(b' ');
            self.val(t.a, out);
            out.push_str(" [");
            for k in 0..t.aux as u32 {
                if k != 0 {
                    out.push_str(", ");
                }
                out.push_i64(b.words[(t.b + k) as usize] as i64);
                out.push_str(" -> ");
                self.edge(b, b.switch_edge(t, k), out);
            }
            out.push_str("] else ");
            self.edge(b, b.switch_edge(t, t.aux), out);
        } else if f == F_PANIC {
            out.push_byte(b' ');
            push_quoted(p.spell(p.msgs[b.msgs[t.a as usize] as usize]), out);
            if t.b != VNONE {
                out.push_str(" lane ");
                self.val(t.b, out);
            }
        } else if t.op == O_FENCE {
            out.format_into(" {}", order_name(t.aux));
        }
        let l = b.lines[b.locs[i as usize] as usize];
        if l.line != 0 {
            out.push_str(" !");
            self.loc(l, out);
            // The call it was inlined from.
            if b.inl.len() != 0 && b.inl[i as usize] != 0 {
                out.push_byte(b'@');
                self.site(b, b.inl[i as usize], out);
            }
        }
        out.push_byte(b'\n');
    }

    // The places of the inline sites among those at their location (`sord`): the printed ones in
    // instruction order, then the scopes'.
    fn sites(self: &mut Self, b: &Body) {
        self.sord.truncate(0);
        for _ in 0..b.lines.len() {
            self.sord.push(NONE);
        }
        self.sfirst.truncate(0);
        for i in 0..b.inl.len() {
            if b.inl[i] != 0 && b.lines[b.locs[i] as usize].line != 0 {
                self.place(b, b.inl[i]);
            }
        }
        for x in 0..b.scopes.len() {
            self.place(b, b.scopes[x].site);
        }
    }

    fn place(self: &mut Self, b: &Body, s: u32) {
        if self.sord[s as usize] != NONE {
            return;
        }
        let l = b.lines[s as usize];
        let mut n: u32 = 0;
        for j in 0..self.sfirst.len() {
            let m = b.lines[self.sfirst[j] as usize];
            if m.file == l.file && m.line == l.line && m.col == l.col {
                n += 1;
            }
        }
        self.sord[s as usize] = n;
        self.sfirst.push(s);
    }

    // Inline site `s`: its location, and `#<n>` past the first site there.
    fn site(self: &Self, b: &Body, s: u32, out: &mut String) {
        self.loc(b.lines[s as usize], out);
        if self.sord[s as usize] != 0 {
            out.format_into("#{}", self.sord[s as usize]);
        }
    }

    // Location `l`: its file when not the body's, its line and column.
    fn loc(self: &Self, l: Loc, out: &mut String) {
        if l.file == self.file {
            out.format_into("{}:{}", l.line, l.col);
        } else {
            out.format_into("f{}:{}:{}", l.file, l.line, l.col);
        }
    }

    // The alignment and volatility of a load or store, the order of an atomic one.
    fn mem_flags(self: &Self, t: Inst, out: &mut String) {
        if t.op == O_ALOAD || t.op == O_ASTORE || t.op == O_ARMW {
            out.format_into(" {}", order_name(t.aux & 7));
            return;
        }
        out.format_into(" align {}", t.aux & 15);
        if (t.aux & MEM_VOLATILE) != 0 {
            out.push_str(" volatile");
        }
        if tbaa(t) != 0 {
            out.format_into(" tbaa {}", tbaa(t));
        }
        if t.op == O_LOAD && (t.aux & MEM_BOOL) != 0 {
            out.push_str(" bool");
        }
    }
}

/// The text of type `t`: `i8` to `i128`, `f32`, `f64`, `ptr`, or a vector `v<lanes><lane>` (`v4f32`).
pub(package) fn push_type(t: u8, out: &mut String) {
    if is_vec(t) {
        out.format_into("v{}", lanes(t));
        push_type(lane_type(t), out);
        return;
    }
    let names: []str = ["none", "i8", "i16", "i32", "i64", "i128", "f32", "f64", "ptr"];
    out.push_str(names[t as usize]);
}

// `+n` or `-n` for a nonzero byte offset (an i32 in `c`).
fn push_offset(c: u32, out: &mut String) {
    push_addend(c as i32, out);
}

fn push_addend(a: i64, out: &mut String) {
    if a > 0 {
        out.push_byte(b'+');
        out.push_i64(a);
    } else if a < 0 {
        out.push_i64(a);
    }
}

// `@name`, quoted when it holds a byte outside letters, digits, `_`, `.` and `$`.
fn push_name(s: str, out: &mut String) {
    out.push_byte(b'@');
    for i in 0..s.len() {
        if !name_byte(s.byte_at(i)) {
            push_quoted(s, out);
            return;
        }
    }
    if s.len() == 0 {
        out.push_str("\"\"");
        return;
    }
    out.push_str(s);
}

/// Whether `c` may appear in an unquoted name.
pub(package) const fn name_byte(c: u8) bool {
    return c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c >= b'0' && c <= b'9' || c == b'_' || c == b'.' || c == b'$';
}

// A string literal: printable ASCII as itself but `"` and `\`, every other byte as `\xHH`.
fn push_quoted(s: str, out: &mut String) {
    out.push_byte(b'"');
    for i in 0..s.len() {
        let c = s.byte_at(i);
        if c == b'"' || c == b'\\' {
            out.push_byte(b'\\');
            out.push_byte(c);
        } else if c >= 32 && c < 127 {
            out.push_byte(c);
        } else {
            out.push_str("\\x");
            push_hex2(c, out);
        }
    }
    out.push_byte(b'"');
}

fn push_hex2(c: u8, out: &mut String) {
    let d: str = "0123456789abcdef";
    out.push_byte(d.byte_at((c >> 4) as usize));
    out.push_byte(d.byte_at((c & 15) as usize));
}

/// `bits` read as a signed integer of `w` bits (1 to 64).
pub(package) const fn sign_extend(bits: u64, w: u32) i64 {
    if w >= 64 {
        return bits as i64;
    }
    let sh = (64 - w) as u64;
    return (bits << sh) as i64 >> sh as i64;
}
