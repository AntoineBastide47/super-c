// The assembler for module-level assembly: GNU syntax statements into an object (`codegen::obj`).
// Labels, sections, data, symbol attributes and call frame directives are shared; each instruction
// goes to its instruction set's assembler (`a64asm`, `x64asm`). A reference to a label of the same
// section resolves in place, any other becomes a relocation. On x86-64 a branch to a label behind takes
// the shortest form; one to a label ahead takes 32 bits, as no pass relaxes it.
import codegen::obj as ob;
import target::a64 as a;
import target::a64asm as aa;
import target::x64 as x;
import target::x64asm as xa;
import target::wasm as w;
import target::wasmasm as wa;
import target::wasmobj as wo;

/// Instruction sets.
pub(package) const ISA_A64: u8 = 0;
pub(package) const ISA_X64: u8 = 1;
/// Object formats: the symbol names they spell and the directives they take.
pub(package) const FMT_MACHO: u8 = 0;
pub(package) const FMT_ELF: u8 = 1;
pub(package) const FMT_COFF: u8 = 2;

// ---- Statements ----

/// The statements of `text`, one per line or `;`, without comments (`//`, `/* */`; `#` to the end of
/// the line for x86-64): each holds its labels and the rest (a directive or an instruction).
pub(package) struct Stmt {
    pub(package) labels: Vector<String>,
    pub(package) body: String,
    pub(package) line: u32,
}

/// Split `text` into statements.
pub(package) fn statements(text: str, hash_comment: bool, out: &mut Vector<Stmt>) {
    let mut cur = String::new();
    let mut line: u32 = 1;
    let mut start_line: u32 = 1;
    let mut i: usize = 0;
    let n = text.len();
    let mut in_str = false;
    while i <= n {
        let c: u8 = if i < n {
            text.byte_at(i)
        } else {
            b'\n'
        };
        if in_str {
            cur.push_byte(c);
            if c == b'\\' && i + 1 < n {
                cur.push_byte(text.byte_at(i + 1));
                i += 2;
                continue;
            }
            if c == b'"' {
                in_str = false;
            }
            i += 1;
            continue;
        }
        if c == b'"' {
            in_str = true;
            cur.push_byte(c);
            i += 1;
            continue;
        }
        if c == b'/' && i + 1 < n && text.byte_at(i + 1) == b'*' {
            let mut j = i + 2;
            while j + 1 < n && !(text.byte_at(j) == b'*' && text.byte_at(j + 1) == b'/') {
                if text.byte_at(j) == b'\n' {
                    line += 1;
                }
                j += 1;
            }
            i = j + 2;
            cur.push_byte(b' ');
            continue;
        }
        if c == b'/' && i + 1 < n && text.byte_at(i + 1) == b'/' || hash_comment && c == b'#' {
            while i < n && text.byte_at(i) != b'\n' {
                i += 1;
            }
            continue;
        }
        if c == b'\n' || c == b';' {
            push_stmt(&cur, start_line, out);
            cur.clear();
            if c == b'\n' {
                line += 1;
            }
            start_line = line;
            i += 1;
            continue;
        }
        cur.push_byte(c);
        i += 1;
    }
}

// One statement's labels (`name:`, `1:`) and body.
fn push_stmt(s0: str, line: u32, out: &mut Vector<Stmt>) {
    let mut s = s0.trim();
    let mut st = Stmt { labels: Vector::<String>::new(), body: String::new(), line: line };
    // Each step removes one label.
    loop {
        let mut j: usize = 0;
        let digits = s.len() != 0 && s.byte_at(0) >= b'0' && s.byte_at(0) <= b'9';
        while j < s.len() && (is_sym_byte(s.byte_at(j), j == 0) || digits && s.byte_at(j) >= b'0' && s.byte_at(j) <= b'9') {
            j += 1;
        }
        if j == 0 || j >= s.len() || s.byte_at(j) != b':' {
            break;
        }
        st.labels.push(String::from_str(s.slice(0, j)));
        s = s.slice(j + 1, s.len()).trim();
    }
    if s.len() == 0 && st.labels.len() == 0 {
        return;
    }
    st.body = String::from_str(s);
    out.push(st);
}

/// Whether `c` may be byte `first`-or-later of a symbol name.
pub(package) const fn is_sym_byte(c: u8, first: bool) bool {
    return c >= b'a' && c <= b'z' || c >= b'A' && c <= b'Z' || c == b'_' || c == b'.' || c == b'$' || !first && c >= b'0' && c <= b'9';
}

// Whether `w` is a numeric local label (`1`, `23`).
const fn numeric(w: str) bool {
    if w.len() == 0 {
        return false;
    }
    for i in 0..w.len() {
        if w.byte_at(i) < b'0' || w.byte_at(i) > b'9' {
            return false;
        }
    }
    return true;
}

// ---- The assembler ----

// A label: its section and offset, the statement it is defined at (numeric labels repeat).
struct Label {
    pub(package) name: String,
    pub(package) sec: u8,
    pub(package) off: u64,
    pub(package) stmt: u32,
}

// A reference to resolve once every label is known: at byte `off` of section `sec`, kind `kind`.
struct Ref {
    pub(package) sec: u8,
    pub(package) off: u32,
    pub(package) kind: u8,
    pub(package) name: String,
    pub(package) addend: i64,
    pub(package) stmt: u32,
    pub(package) line: u32,
}

// The call frame of a `.cfi_startproc`: its section, start, CFA offset and rules so far.
struct Cfi {
    pub(package) open: bool,
    pub(package) sec: u8,
    pub(package) start: u64,
    pub(package) last: u64,
    pub(package) cfa: i64,
    pub(package) at: u32,
    pub(package) stack: Vector<i64>,
}

pub(package) struct Asm {
    pub(package) isa: u8,
    pub(package) fmt: u8,
    pub(package) err: String,
    sec: u8,
    labels: Vector<Label>,
    refs: Vector<Ref>,
    globals: Vector<String>,
    hidden: Vector<String>,
    funcs: Vector<String>,
    cfi: Cfi,
    seh: Seh,
    stmt: u32,
    line: u32,
}

// The Microsoft x64 unwind codes of a `.seh_proc`: its section and start, its prologue's size,
// its frame register and offset, and the codes in prologue order (`groups`: each one's first byte in
// `codes`).
struct Seh {
    pub(package) open: bool,
    pub(package) sec: u8,
    pub(package) start: u64,
    pub(package) prolog: u32,
    pub(package) frame: u8,
    pub(package) codes: Vector<u8>,
    pub(package) groups: Vector<u32>,
}

extend Asm {
    pub(package) fn new(isa: u8, fmt: u8) Asm {
        return Asm {
            isa: isa,
            fmt: fmt,
            err: String::new(),
            sec: ob::S_TEXT,
            labels: Vector::<Label>::new(),
            refs: Vector::<Ref>::new(),
            globals: Vector::<String>::new(),
            hidden: Vector::<String>::new(),
            funcs: Vector::<String>::new(),
            cfi: Cfi { open: false, sec: 0, start: 0, last: 0, cfa: 0, at: 0, stack: Vector::<i64>::new() },
            seh: Seh {
                open: false,
                sec: 0,
                start: 0,
                prolog: 0,
                frame: 0,
                codes: Vector::<u8>::new(),
                groups: Vector::<u32>::new(),
            },
            stmt: 0,
            line: 0,
        };
    }

    fn fail(self: &mut Self, what: str) bool {
        if self.err.len() == 0 {
            self.err.format_into("line {}: {}", self.line, what);
        }
        return false;
    }

    /// Assemble `text` into `o`; false with `err` set when a statement does not assemble.
    pub(package) fn module(self: &mut Self, o: &mut ob::Obj, text: str) bool {
        let mut sts = Vector::<Stmt>::new();
        statements(text, self.isa == ISA_X64, &mut sts);
        for k in 0..sts.len() {
            self.stmt = k as u32;
            self.line = sts[k].line;
            for j in 0..sts[k].labels.len() {
                let name = sts[k].labels[j].clone();
                let off = o.secs[self.sec as usize].size;
                self.labels.push(Label { name: name, sec: self.sec, off: off, stmt: k as u32 });
            }
            let body = sts[k].body.as_str();
            if body.len() == 0 {
                continue;
            }
            let ok = if body.byte_at(0) == b'.' {
                self.directive(o, body)
            } else {
                self.inst(o, body)
            };
            if !ok {
                return false;
            }
        }
        if self.cfi.open {
            return self.fail("a '.cfi_startproc' without its '.cfi_endproc'");
        }
        if self.seh.open {
            return self.fail("a '.seh_proc' without its '.seh_endproc'");
        }
        return self.symbols(o) && self.resolve(o);
    }

    // The C name of assembly symbol `name`: Mach-O spells C names with a leading `_`.
    const fn c_name<'a>(self: &Self, name: str<'a>) str<'a> {
        if self.fmt == FMT_MACHO && name.starts_with("_") {
            return name.slice(1, name.len());
        }
        return name;
    }

    // Whether `name` is in `list`.
    const fn listed(list: &Vector<String>, name: str) bool {
        for i in 0..list.len() {
            if list[i].as_str() == name {
                return true;
            }
        }
        return false;
    }

    // Define the symbols of the global labels, and every label a relocation names.
    fn symbols(self: &mut Self, o: &mut ob::Obj) bool {
        for i in 0..self.globals.len() {
            let g = self.globals[i].clone();
            let mut found = false;
            for j in 0..self.labels.len() {
                if self.labels[j].name.as_str() != g.as_str() {
                    continue;
                }
                if self.fmt == FMT_MACHO && !g.starts_with("_") {
                    self.line = 0;
                    return self.fail(
                        format("the global symbol '{}' has no '_': Mach-O spells a C name with one", g.as_str()).as_str(),
                    );
                }
                let k = o.sym(self.c_name(&g));
                let l = &self.labels[j];
                let mut fl = ob::SF_GLOBAL;
                if o.secs[l.sec as usize].code || l.sec == ob::S_TEXT || Asm::listed(&self.funcs, &g) {
                    fl |= ob::SF_FUNC;
                }
                if Asm::listed(&self.hidden, &g) {
                    fl |= ob::SF_HIDDEN;
                }
                let y = o.syms.index_mut(k as usize);
                y.sec = l.sec;
                y.off = l.off;
                y.flags = fl;
                found = true;
                break;
            }
            if !found {
                // A `.globl` of a symbol defined elsewhere names it, as GNU as does.
                let _ = o.sym(self.c_name(&g));
            }
        }
        return true;
    }

    // The label `name` a reference at statement `stmt` means: the global or plain label of that name,
    // or for `<n>f` / `<n>b` the next or the last definition of local label n. -1 when none.
    const fn find(self: &Self, name: str, stmt: u32) i64 {
        let last = name.byte_at(name.len() - 1);
        if name.len() > 1 && numeric(name.slice(0, name.len() - 1)) && (last == b'f' || last == b'b') {
            let n = name.slice(0, name.len() - 1);
            let mut best: i64 = -1;
            for i in 0..self.labels.len() {
                let l = &self.labels[i];
                if l.name.as_str() != n {
                    continue;
                }
                if last == b'b' && l.stmt <= stmt {
                    best = i as i64;
                }
                if last == b'f' && l.stmt > stmt {
                    return i as i64;
                }
            }
            return best;
        }
        for i in 0..self.labels.len() {
            if self.labels[i].name.as_str() == name {
                return i as i64;
            }
        }
        return -1;
    }

    // Resolve every reference: in place for a label of the same section, else a relocation of the
    // label's symbol (a local one for a label nothing makes global) or of an external symbol.
    fn resolve(self: &mut Self, o: &mut ob::Obj) bool {
        for i in 0..self.refs.len() {
            let r = Ref {
                sec: self.refs[i].sec,
                off: self.refs[i].off,
                kind: self.refs[i].kind,
                name: self.refs[i].name.clone(),
                addend: self.refs[i].addend,
                stmt: self.refs[i].stmt,
                line: self.refs[i].line,
            };
            self.line = r.line;
            let li = self.find(&r.name, r.stmt);
            if li >= 0 && self.labels[li as usize].sec == r.sec && self.local_kind(r.kind) {
                let off = self.labels[li as usize].off as i64 + r.addend - r.off as i64;
                if !self.patch(o, r.sec, r.off, r.kind, off) {
                    return self.fail(format("'{}' is out of the instruction's reach", r.name.as_str()).as_str());
                }
                continue;
            }
            if r.kind == aa::FX_B19 || r.kind == aa::FX_B14 || r.kind == aa::FX_ADR {
                return self.fail(
                    format("'{}' is not a label of this section: the instruction reaches only those", r.name.as_str()).as_str(),
                );
            }
            let k = if li >= 0 && !Asm::listed(&self.globals, &r.name) {
                // A local label: a local symbol of its own name.
                let l = &self.labels[li as usize];
                let nm = format(".Lsc_asm{}", li);
                let s = o.sym(&nm);
                let y = o.syms.index_mut(s as usize);
                y.sec = l.sec;
                y.off = l.off;
                y.flags = 0;
                s
            } else {
                o.sym(self.c_name(&r.name))
            };
            o.reloc(r.sec, r.kind, r.off, k, r.addend);
        }
        return true;
    }

    // Whether a reference of kind `k` to a label of its own section resolves in place.
    const fn local_kind(self: &Self, k: u8) bool {
        if self.isa == ISA_X64 {
            return k == x::R_PLT32 || k == x::R_PC32;
        }
        return k == a::R_BRANCH26 || k == aa::FX_B19 || k == aa::FX_B14 || k == aa::FX_ADR;
    }

    // Patch the field of the instruction at `off` of section `sec` to `delta` bytes.
    fn patch(self: &Self, o: &mut ob::Obj, sec: u8, off: u32, k: u8, delta: i64) bool {
        let at = off as usize;
        if self.isa == ISA_X64 {
            // A 32-bit field relative to its instruction's end: `delta` counts from the field.
            if delta < -0x80000000 || delta > 0x7FFFFFFF {
                return false;
            }
            let bm = o.secs.index_mut(sec as usize);
            for q in 0..4usize {
                bm.bytes.set(at + q, (delta as u64 >> 8 * q as u64 & 0xFF) as u8);
            }
            return true;
        }
        let b = &o.secs[sec as usize].bytes;
        let w = b[at] as u32 | b[at + 1] as u32 << 8 | b[at + 2] as u32 << 16 | b[at + 3] as u32 << 24;
        let mut nw = w;
        if k == aa::FX_ADR {
            if delta < -(1i64 << 20) || delta >= 1i64 << 20 {
                return false;
            }
            let u = delta as u32;
            nw = w & 0x9F00001F | (u & 3) << 29 | (u >> 2 & 0x7FFFF) << 5;
        } else {
            if (delta & 3) != 0 || !a::reaches(w, delta) {
                return false;
            }
            nw = a::repatch(w, delta as i32);
        }
        let bm = o.secs.index_mut(sec as usize);
        bm.bytes.set(at, (nw & 0xFF) as u8);
        bm.bytes.set(at + 1, (nw >> 8 & 0xFF) as u8);
        bm.bytes.set(at + 2, (nw >> 16 & 0xFF) as u8);
        bm.bytes.set(at + 3, (nw >> 24) as u8);
        return true;
    }

    // An instruction statement.
    fn inst(self: &mut Self, o: &mut ob::Obj, body: str) bool {
        if !o.secs[self.sec as usize].code && self.sec != ob::S_TEXT {
            return self.fail("an instruction outside a code section");
        }
        if self.isa == ISA_X64 {
            return self.inst_x64(o, body);
        }
        let mut w: u32 = 0;
        let mut fx = aa::Fix::new();
        let mut e = String::new();
        if !aa::assemble(body, &mut w, &mut fx, &mut e) {
            return self.fail(&e);
        }
        let off = o.secs[self.sec as usize].size as u32;
        if fx.kind != aa::FX_NONE {
            self.refs.push(
                Ref {
                    sec: self.sec,
                    off: off,
                    kind: fx.kind,
                    name: fx.name.clone(),
                    addend: fx.addend,
                    stmt: self.stmt,
                    line: self.line,
                },
            );
        }
        let mut b = Vector::<u8>::new();
        ob::w32(&mut b, w);
        o.put(self.sec, b[0..4]);
        return true;
    }

    // An x86-64 instruction statement.
    fn inst_x64(self: &mut Self, o: &mut ob::Obj, body: str) bool {
        let off = o.secs[self.sec as usize].size;
        let mut b = Vector::<u8>::with_capacity(16);
        let mut fx = xa::Fix::new();
        let mut e = String::new();
        if !xa::assemble(body, xa::NOTGT, &mut b, &mut fx, &mut e) {
            return self.fail(&e);
        }
        if fx.kind == x::R_PLT32 {
            // A branch to a label behind in this section: its distance picks the form.
            let li = self.find(&fx.name, self.stmt);
            if li >= 0 && self.labels[li as usize].sec == self.sec && self.labels[li as usize].stmt <= self.stmt && !Asm::listed(
                &self.globals,
                &fx.name,
            ) {
                b.truncate(0);
                let tgt = self.labels[li as usize].off as i64 - off as i64;
                if !xa::assemble(body, tgt, &mut b, &mut fx, &mut e) {
                    return self.fail(&e);
                }
                o.put(self.sec, b[0..b.len()]);
                return true;
            }
        }
        if fx.kind != xa::FX_NONE {
            self.refs.push(
                Ref {
                    sec: self.sec,
                    off: off as u32 + fx.at,
                    kind: fx.kind,
                    name: fx.name.clone(),
                    addend: fx.addend,
                    stmt: self.stmt,
                    line: self.line,
                },
            );
        }
        o.put(self.sec, b[0..b.len()]);
        return true;
    }

    // ---- Directives ----

    fn directive(self: &mut Self, o: &mut ob::Obj, body: str) bool {
        let mut j: usize = 0;
        while j < body.len() && body.byte_at(j) != b' ' && body.byte_at(j) != b'\t' {
            j += 1;
        }
        let d = body.slice(0, j);
        let rest = body.slice(j, body.len()).trim();
        if d == ".text" {
            self.sec = ob::S_TEXT;
            return true;
        }
        if d == ".data" {
            self.sec = ob::S_DATA;
            return true;
        }
        if d == ".bss" {
            self.sec = ob::S_BSS;
            return true;
        }
        if d == ".rodata" || d == ".const" {
            self.sec = ob::S_RODATA;
            return true;
        }
        if d == ".section" {
            return self.section(o, rest);
        }
        if d == ".globl" || d == ".global" {
            return self.names(rest, 0);
        }
        if d == ".hidden" || d == ".private_extern" {
            return self.names(rest, 1);
        }
        if d == ".type" {
            // `.type name, @function` (`%function`, `STT_FUNC`).
            let c = rest.find_byte(b',');
            if c < 0 {
                return self.fail("'.type' takes a name and a type");
            }
            let ty = rest.slice(c as usize + 1, rest.len()).trim();
            if ty.ends_with("function") || ty == "STT_FUNC" {
                self.funcs.push(String::from_str(rest.slice(0, c as usize).trim()));
            }
            return true;
        }
        if d == ".p2align" || d == ".balign" || d == ".align" {
            return self.align(o, d, rest);
        }
        if d == ".byte" || d == ".hword" || d == ".short" || d == ".2byte" || d == ".word" || d == ".long" || d == ".int" || d == ".4byte" || d == ".quad" || d == ".xword" || d == ".8byte" || d == ".inst" {
            return self.data(o, d, rest);
        }
        if d == ".ascii" || d == ".asciz" || d == ".string" {
            return self.ascii(o, rest, d != ".ascii");
        }
        if d == ".zero" || d == ".space" || d == ".skip" {
            return self.space(o, rest);
        }
        if d.starts_with(".cfi_") {
            return self.cfi_dir(o, d, rest);
        }
        if d.starts_with(".seh_") && self.fmt == FMT_COFF {
            return self.seh_dir(o, d, rest);
        }
        // Directives that change nothing in the object.
        if d == ".size" || d == ".arch_extension" || d == ".arch" || d == ".cpu" || d == ".file" || d == ".ident" || d == ".subsections_via_symbols" || d == ".build_version" || d == ".macosx_version_min" || d == ".addrsig" {
            return true;
        }
        return self.fail(format("the directive '{}' is not one this assembler takes", d).as_str());
    }

    // `.section`: a section kind by its usual name, else a named section.
    fn section(self: &mut Self, o: &mut ob::Obj, rest: str) bool {
        let mut name = rest;
        if self.fmt != FMT_MACHO {
            let c = rest.find_byte(b',');
            if c >= 0 {
                name = rest.slice(0, c as usize).trim();
            }
        } else {
            // `segment,section[,type]`: the kinds by their segment and section.
            let c = rest.find_byte(b',');
            if c >= 0 {
                let rest2 = rest.slice(c as usize + 1, rest.len());
                let c2 = rest2.find_byte(b',');
                let sect = if c2 >= 0 {
                    rest2.slice(0, c2 as usize).trim()
                } else {
                    rest2.trim()
                };
                let seg = rest.slice(0, c as usize).trim();
                name = rest.trim();
                if seg == "__TEXT" && sect == "__text" {
                    self.sec = ob::S_TEXT;
                    return true;
                }
                if seg == "__DATA" && sect == "__data" {
                    self.sec = ob::S_DATA;
                    return true;
                }
                if seg == "__TEXT" && sect == "__const" {
                    self.sec = ob::S_RODATA;
                    return true;
                }
                if seg == "__DATA" && sect == "__bss" {
                    self.sec = ob::S_BSS;
                    return true;
                }
            }
        }
        if name == ".text" {
            self.sec = ob::S_TEXT;
            return true;
        }
        if name == ".data" {
            self.sec = ob::S_DATA;
            return true;
        }
        if name == ".bss" {
            self.sec = ob::S_BSS;
            return true;
        }
        if name == ".rodata" {
            self.sec = ob::S_RODATA;
            return true;
        }
        let code = name.starts_with(".text") || rest.contains("\"ax\"") || rest.contains("regular,pure_instructions") || rest.contains(
            "__TEXT,__text",
        );
        let s = o.named(name, code);
        if s == ob::NOSEC {
            return self.fail("too many sections");
        }
        self.sec = s;
        return true;
    }

    // The names of a comma-separated list into the globals (`what` 0) or the hidden ones (1).
    fn names(self: &mut Self, rest: str, what: u32) bool {
        let mut it = rest.split(",");
        loop {
            let n = switch it.next() {
                Some(x) => x.trim(),
                None => {
                    break;
                },
            };
            if n.len() == 0 {
                return self.fail("a symbol directive without a name");
            }
            if what == 0 {
                if !Asm::listed(&self.globals, n) {
                    self.globals.push(String::from_str(n));
                }
            } else {
                self.hidden.push(String::from_str(n));
                if !Asm::listed(&self.globals, n) {
                    self.globals.push(String::from_str(n));
                }
            }
        }
        return true;
    }

    // A number of a directive.
    const fn num(s: str, out: &mut i64) bool {
        let t = s.trim();
        let neg = t.starts_with("-");
        let u = if neg {
            t.slice(1, t.len()).trim()
        } else {
            t
        };
        let v = if u.starts_with("0x") || u.starts_with("0X") {
            u.slice(2, u.len()).parse_u64_radix(16)
        } else {
            u.parse_u64()
        };
        return switch v {
            Some(x) => {
                *out = if neg {
                    (x as i64).wrapping_neg()
                } else {
                    x as i64
                };
                true
            },
            None => false,
        };
    }

    // `.p2align n[, fill]`, `.balign n`, `.align n` (a power of two on arm64, bytes on x86-64 ELF).
    fn align(self: &mut Self, o: &mut ob::Obj, d: str, rest: str) bool {
        let c = rest.find_byte(b',');
        let first = if c >= 0 {
            rest.slice(0, c as usize)
        } else {
            rest
        };
        let mut n: i64 = 0;
        if !Asm::num(first, &mut n) || n < 0 {
            return self.fail("an alignment is a number");
        }
        let bytes = d == ".balign" || d == ".align" && self.isa == ISA_X64;
        let mut lg: u8 = 0;
        if bytes {
            if n == 0 || (n & n - 1) != 0 {
                return self.fail("'.balign' takes a power of two");
            }
            lg = (n as u64).trailing_zeros() as u8;
        } else {
            if n > 16 {
                return self.fail("an alignment past 2^16");
            }
            lg = n as u8;
        }
        let code = o.secs[self.sec as usize].code || self.sec == ob::S_TEXT;
        let start = o.secs[self.sec as usize].size;
        let at = o.align(self.sec, lg);
        if code && self.isa == ISA_A64 && (at - start) % 4 == 0 {
            // Padding in code is NOPs, as GNU as writes it.
            let bm = o.secs.index_mut(self.sec as usize);
            let mut p = start;
            while p < at {
                bm.bytes.set(p as usize, 0x1F);
                bm.bytes.set(p as usize + 1, 0x20);
                bm.bytes.set(p as usize + 2, 0x03);
                bm.bytes.set(p as usize + 3, 0xD5);
                p += 4;
            }
        }
        if code && self.isa == ISA_X64 {
            // The NOPs GNU as and LLVM write: the longest, 10 bytes, then the rest's.
            let bm = o.secs.index_mut(self.sec as usize);
            let mut p = start as usize;
            while p < at as usize {
                let n = if at as usize - p < 10 {
                    at as usize - p
                } else {
                    10usize
                };
                let nops: []u8 = NOPS;
                for q in 0..n {
                    bm.bytes.set(p + q, nops[n * (n - 1) / 2 + q]);
                }
                p += n;
            }
        }
        return true;
    }

    // `.byte`, `.short`, `.word` (4 bytes on arm64), `.quad`, `.inst`: numbers, or symbols for 8-byte ones.
    fn data(self: &mut Self, o: &mut ob::Obj, d: str, rest: str) bool {
        let size: u32 = if d == ".byte" {
            1
        } else if d == ".hword" || d == ".short" || d == ".2byte" || d == ".word" && self.isa == ISA_X64 {
            2
        } else if d == ".quad" || d == ".xword" || d == ".8byte" {
            8
        } else {
            4
        };
        if self.sec == ob::S_BSS {
            return self.fail("data in '.bss'");
        }
        let mut it = rest.split(",");
        loop {
            let t = switch it.next() {
                Some(x) => x.trim(),
                None => {
                    break;
                },
            };
            let mut v: i64 = 0;
            if !Asm::num(t, &mut v) {
                if size != 8 || t.len() == 0 || !is_sym_byte(t.byte_at(0), true) {
                    return self.fail(format("'{}' is no number", t).as_str());
                }
                // A symbol, with an optional addend.
                let mut e: usize = 0;
                while e < t.len() && is_sym_byte(t.byte_at(e), e == 0) {
                    e += 1;
                }
                let mut add: i64 = 0;
                let tail = t.slice(e, t.len()).trim();
                if tail.len() != 0 {
                    let neg = tail.byte_at(0) == b'-';
                    if tail.byte_at(0) != b'+' && !neg || !Asm::num(tail.slice(1, tail.len()), &mut add) {
                        return self.fail(format("'{}' is no symbol and addend", t).as_str());
                    }
                    if neg {
                        add = -add;
                    }
                }
                let off = o.secs[self.sec as usize].size as u32;
                let kind = if self.isa == ISA_X64 {
                    x::R_ABS64
                } else {
                    a::R_ABS64
                };
                self.refs.push(
                    Ref {
                        sec: self.sec,
                        off: off,
                        kind: kind,
                        name: String::from_str(t.slice(0, e)),
                        addend: add,
                        stmt: self.stmt,
                        line: self.line,
                    },
                );
                v = 0;
            }
            let mut b = Vector::<u8>::new();
            for k in 0..size {
                b.push((v as u64 >> (8 * k) as u64 & 0xFF) as u8);
            }
            o.put(self.sec, b[0..b.len()]);
        }
        return true;
    }

    // `.ascii "..."`, `.asciz "..."` (NUL-terminated).
    fn ascii(self: &mut Self, o: &mut ob::Obj, rest: str, nul: bool) bool {
        let t = rest.trim();
        if t.len() < 2 || t.byte_at(0) != b'"' || t.byte_at(t.len() - 1) != b'"' {
            return self.fail("a string directive takes one string");
        }
        let mut b = Vector::<u8>::new();
        let mut i: usize = 1;
        while i + 1 < t.len() {
            let c = t.byte_at(i);
            i += 1;
            if c != b'\\' {
                b.push(c);
                continue;
            }
            let e = t.byte_at(i);
            i += 1;
            if e >= b'0' && e <= b'7' {
                let mut v: u32 = e - b'0';
                let mut k: u32 = 1;
                while k < 3 && i + 1 < t.len() && t.byte_at(i) >= b'0' && t.byte_at(i) <= b'7' {
                    v = v * 8 + (t.byte_at(i) - b'0') as u32;
                    i += 1;
                    k += 1;
                }
                b.push((v & 0xFF) as u8);
                continue;
            }
            b.push(
                switch e {
                    b'n' => 10u8,
                    b't' => 9u8,
                    b'r' => 13u8,
                    b'0' => 0u8,
                    _ => e,
                },
            );
        }
        if nul {
            b.push(0);
        }
        o.put(self.sec, b[0..b.len()]);
        return true;
    }

    // `.zero n`, `.space n[, fill]`.
    fn space(self: &mut Self, o: &mut ob::Obj, rest: str) bool {
        let c = rest.find_byte(b',');
        let mut n: i64 = 0;
        let mut fill: i64 = 0;
        if !Asm::num(
            if c >= 0 {
                rest.slice(0, c as usize)
            } else {
                rest
            },
            &mut n,
        ) || n < 0 || c >= 0 && !Asm::num(rest.slice(c as usize + 1, rest.len()), &mut fill) {
            return self.fail("'.space' takes a count and a fill byte");
        }
        if self.sec == ob::S_BSS {
            let bm = o.secs.index_mut(self.sec as usize);
            bm.size += n as u64;
            return true;
        }
        let mut b = Vector::<u8>::new();
        for _ in 0..n {
            b.push((fill & 0xFF) as u8);
        }
        o.put(self.sec, b[0..b.len()]);
        return true;
    }

    // ---- Call frame information ----

    // The DWARF number of register `r` (`x30`, `d8`, `sp`); -1 when unknown.
    const fn dwarf_reg(self: &Self, r0: str) i64 {
        let r = r0.trim();
        if self.isa == ISA_X64 {
            return x64_dwarf(
                if r.starts_with("%") {
                    r.slice(1, r.len())
                } else {
                    r
                },
            );
        }
        if r == "sp" {
            return 31;
        }
        if r == "fp" {
            return 29;
        }
        if r == "lr" {
            return 30;
        }
        if r.len() < 2 {
            return -1;
        }
        let n = switch r.slice(1, r.len()).parse_u64() {
            Some(x) => x as i64,
            None => -1i64,
        };
        if n < 0 || n > 31 {
            return -1;
        }
        let c = r.byte_at(0);
        if c == b'x' || c == b'w' {
            return n;
        }
        if c == b'd' || c == b'q' || c == b'v' || c == b's' {
            return 64 + n;
        }
        return -1;
    }

    // Advance the open frame's rules to the current offset.
    fn cfi_advance(self: &mut Self, o: &mut ob::Obj) {
        let here = o.secs[self.cfi.sec as usize].size;
        let factor: u64 = if self.isa == ISA_A64 {
            4
        } else {
            1
        };
        let d = (here - self.cfi.last) / factor;
        if d == 0 {
            return;
        }
        if d < 64 {
            o.cfi.push(0x40 | d as u8);
        } else if d < 256 {
            o.cfi.push(0x02);
            o.cfi.push(d as u8);
        } else if d < 65536 {
            o.cfi.push(0x03);
            ob::w16(&mut o.cfi, d as u32);
        } else {
            o.cfi.push(0x04);
            ob::w32(&mut o.cfi, d as u32);
        }
        self.cfi.last = here;
    }

    // The symbol of the label at `off` of section `sec` a frame names: its global symbol, else a local
    // one; 0xFFFFFFFF for none.
    fn frame_sym(self: &Self, o: &mut ob::Obj, sec: u8, off: u64) u32 {
        for i in 0..self.labels.len() {
            let l = &self.labels[i];
            if l.sec != sec || l.off != off || numeric(&l.name) {
                continue;
            }
            let global = Asm::listed(&self.globals, &l.name);
            let nm = if global {
                String::from_str(self.c_name(&l.name))
            } else {
                format(".Lsc_asm{}", i)
            };
            let sym = o.sym(&nm);
            if !global {
                let y = o.syms.index_mut(sym as usize);
                y.sec = l.sec;
                y.off = l.off;
            }
            return sym;
        }
        return 0xFFFFFFFF;
    }

    // ---- Microsoft x64 unwind directives ----

    // One unwind code: the prologue offset (the bytes so far), the operation and its info, and
    // `extra` 16-bit slots of `v`.
    fn seh_code(self: &mut Self, o: &ob::Obj, op: u32, info: u32, extra: u32, v: u32) bool {
        let here = o.secs[self.seh.sec as usize].size - self.seh.start;
        if here > 255 || self.seh.prolog != 0xFFFFFFFF {
            return self.fail("an unwind code past the prologue's 255 bytes or its end");
        }
        self.seh.groups.push(self.seh.codes.len() as u32);
        self.seh.codes.push(here as u8);
        self.seh.codes.push((op | info << 4) as u8);
        for q in 0..extra {
            ob::w16(&mut self.seh.codes, v >> 16 * q);
        }
        return true;
    }

    fn seh_dir(self: &mut Self, o: &mut ob::Obj, d: str, rest: str) bool {
        if d == ".seh_proc" {
            if self.seh.open {
                return self.fail("a '.seh_proc' inside another");
            }
            self.seh.open = true;
            self.seh.sec = self.sec;
            self.seh.start = o.secs[self.sec as usize].size;
            self.seh.prolog = 0xFFFFFFFF;
            self.seh.frame = 0;
            self.seh.codes.truncate(0);
            self.seh.groups.truncate(0);
            return true;
        }
        if !self.seh.open {
            return self.fail(format("'{}' outside a '.seh_proc'", d).as_str());
        }
        let mut a0 = rest;
        let mut n: i64 = 0;
        let c = rest.find_byte(b',');
        if c >= 0 {
            a0 = rest.slice(0, c as usize).trim();
            if !Asm::num(rest.slice(c as usize + 1, rest.len()), &mut n) || n < 0 {
                return self.fail("an unwind offset is a number");
            }
        }
        let r = x64_reg_number(
            if a0.starts_with("%") {
                a0.slice(1, a0.len())
            } else {
                a0
            },
        );
        if d == ".seh_endprologue" {
            self.seh.prolog = (o.secs[self.seh.sec as usize].size - self.seh.start) as u32;
            if self.seh.prolog > 255 {
                return self.fail("a prologue past 255 bytes");
            }
            return true;
        }
        if d == ".seh_endproc" {
            self.seh.open = false;
            if self.seh.prolog == 0xFFFFFFFF {
                self.seh.prolog = 0;
            }
            // The function starts at the directive, as GNU as and LLVM place it: an alignment after it
            // belongs to the prologue.
            let sym = o.sym(format(".Lsc_seh{}", o.frames.len()).as_str());
            let y = o.syms.index_mut(sym as usize);
            y.sec = self.seh.sec;
            y.off = self.seh.start;
            // UNWIND_INFO: version 1, the prologue's size, the slot count, the frame register, then the
            // codes from the prologue's end back to its start, to an even count.
            let at = o.cfi.len() as u32;
            let nslots = self.seh.codes.len() / 2;
            o.cfi.push(1);
            o.cfi.push(self.seh.prolog as u8);
            o.cfi.push(nslots as u8);
            o.cfi.push(self.seh.frame);
            let mut g = self.seh.groups.len();
            while g > 0 {
                g -= 1;
                let st = self.seh.groups[g] as usize;
                let en = if g + 1 < self.seh.groups.len() {
                    self.seh.groups[g + 1] as usize
                } else {
                    self.seh.codes.len()
                };
                for q in st..en {
                    o.cfi.push(self.seh.codes[q]);
                }
            }
            if nslots % 2 != 0 {
                o.cfi.push(0);
                o.cfi.push(0);
            }
            let size = (o.secs[self.seh.sec as usize].size - self.seh.start) as u32;
            o.frames.push(ob::OFrame { sym: sym, size: size, cfi_at: at, cfi_len: o.cfi.len() as u32 - at });
            return true;
        }
        if d == ".seh_stackalloc" {
            if !Asm::num(rest, &mut n) || n <= 0 || n % 8 != 0 {
                return self.fail("'.seh_stackalloc' takes a positive multiple of 8");
            }
            if n <= 128 {
                return self.seh_code(o, 2, (n / 8 - 1) as u32, 0, 0);
            }
            if n <= 524280 {
                return self.seh_code(o, 1, 0, 1, (n / 8) as u32);
            }
            return self.seh_code(o, 1, 1, 2, n as u32);
        }
        if d == ".seh_pushreg" {
            if r < 0 || r > 15 {
                return self.fail("'.seh_pushreg' takes a general register");
            }
            return self.seh_code(o, 0, r as u32, 0, 0);
        }
        if d == ".seh_savereg" {
            if r < 0 || r > 15 || c < 0 || n % 8 != 0 {
                return self.fail("'.seh_savereg' takes a general register and a multiple of 8");
            }
            if n / 8 <= 0xFFFF {
                return self.seh_code(o, 4, r as u32, 1, (n / 8) as u32);
            }
            return self.seh_code(o, 5, r as u32, 2, n as u32);
        }
        if d == ".seh_savexmm" {
            if r < 16 || r > 31 || c < 0 || n % 16 != 0 {
                return self.fail("'.seh_savexmm' takes an xmm register and a multiple of 16");
            }
            if n / 16 <= 0xFFFF {
                return self.seh_code(o, 8, (r - 16) as u32, 1, (n / 16) as u32);
            }
            return self.seh_code(o, 9, (r - 16) as u32, 2, n as u32);
        }
        if d == ".seh_setframe" {
            if r < 0 || r > 15 || c < 0 || n % 16 != 0 || n > 240 {
                return self.fail("'.seh_setframe' takes a general register and a multiple of 16 to 240");
            }
            self.seh.frame = (r as u32 | (n / 16) as u32 << 4) as u8;
            return self.seh_code(o, 3, 0, 0, 0);
        }
        return self.fail(format("the directive '{}' is not one this assembler takes", d).as_str());
    }

    fn cfi_dir(self: &mut Self, o: &mut ob::Obj, d: str, rest: str) bool {
        if d == ".cfi_startproc" {
            if self.cfi.open {
                return self.fail("a '.cfi_startproc' inside another");
            }
            self.cfi.open = true;
            self.cfi.sec = self.sec;
            self.cfi.start = o.secs[self.sec as usize].size;
            self.cfi.last = self.cfi.start;
            self.cfi.cfa = 0;
            self.cfi.at = o.cfi.len() as u32;
            return true;
        }
        if !self.cfi.open {
            return self.fail(format("'{}' outside a '.cfi_startproc'", d).as_str());
        }
        if d == ".cfi_endproc" {
            self.cfi.open = false;
            let sym = self.frame_sym(o, self.cfi.sec, self.cfi.start);
            if sym == 0xFFFFFFFF {
                return self.fail("a frame starts at no label");
            }
            let size = (o.secs[self.cfi.sec as usize].size - self.cfi.start) as u32;
            o.frames.push(
                ob::OFrame { sym: sym, size: size, cfi_at: self.cfi.at, cfi_len: o.cfi.len() as u32 - self.cfi.at },
            );
            return true;
        }
        self.cfi_advance(o);
        let mut a0 = rest;
        let mut a1 = "";
        let c = rest.find_byte(b',');
        if c >= 0 {
            a0 = rest.slice(0, c as usize).trim();
            a1 = rest.slice(c as usize + 1, rest.len()).trim();
        }
        let mut n: i64 = 0;
        if d == ".cfi_def_cfa_offset" || d == ".cfi_adjust_cfa_offset" {
            if !Asm::num(a0, &mut n) {
                return self.fail("a CFA offset is a number");
            }
            self.cfi.cfa = if d == ".cfi_adjust_cfa_offset" {
                self.cfi.cfa + n
            } else {
                n
            };
            o.cfi.push(0x0E);
            uleb(&mut o.cfi, self.cfi.cfa as u64);
            return true;
        }
        if d == ".cfi_remember_state" {
            o.cfi.push(0x0A);
            self.cfi.stack.push(self.cfi.cfa);
            return true;
        }
        if d == ".cfi_restore_state" {
            o.cfi.push(0x0B);
            if self.cfi.stack.len() != 0 {
                self.cfi.cfa = self.cfi.stack.pop().unwrap_or(0);
            }
            return true;
        }
        let r = self.dwarf_reg(a0);
        if r < 0 {
            return self.fail(format("'{}' is no register a frame rule names", a0).as_str());
        }
        if d == ".cfi_offset" {
            if !Asm::num(a1, &mut n) || n % 8 != 0 {
                return self.fail("a register's offset is a multiple of 8");
            }
            let f = -n / 8;
            if r < 64 && f >= 0 {
                o.cfi.push(0x80 | r as u8);
                uleb(&mut o.cfi, f as u64);
            } else {
                o.cfi.push(0x11);
                uleb(&mut o.cfi, r as u64);
                sleb(&mut o.cfi, f);
            }
            return true;
        }
        if d == ".cfi_restore" {
            if r < 64 {
                o.cfi.push(0xC0 | r as u8);
            } else {
                o.cfi.push(0x06);
                uleb(&mut o.cfi, r as u64);
            }
            return true;
        }
        if d == ".cfi_undefined" || d == ".cfi_same_value" {
            o.cfi.push(
                if d == ".cfi_undefined" {
                    0x07u8
                } else {
                    0x08u8
                },
            );
            uleb(&mut o.cfi, r as u64);
            return true;
        }
        if d == ".cfi_def_cfa_register" {
            o.cfi.push(0x0D);
            uleb(&mut o.cfi, r as u64);
            return true;
        }
        if d == ".cfi_def_cfa" {
            if !Asm::num(a1, &mut n) || n < 0 {
                return self.fail("a CFA offset is a number");
            }
            self.cfi.cfa = n;
            o.cfi.push(0x0C);
            uleb(&mut o.cfi, r as u64);
            uleb(&mut o.cfi, n as u64);
            return true;
        }
        return self.fail(format("the directive '{}' is not one this assembler takes", d).as_str());
    }
}

/// Append `v` to `o` as unsigned LEB128.
pub(package) fn uleb(o: &mut Vector<u8>, v0: u64) {
    let mut v = v0;
    loop {
        let b = (v & 0x7F) as u8;
        v >>= 7;
        if v == 0 {
            o.push(b);
            return;
        }
        o.push(b | 0x80);
    }
}

/// Append `v` to `o` as signed LEB128.
pub(package) fn sleb(o: &mut Vector<u8>, v0: i64) {
    let mut v = v0;
    loop {
        let b = (v & 0x7F) as u8;
        v >>= 7;
        if v == 0 && (b & 0x40) == 0 || v == -1 && (b & 0x40) != 0 {
            o.push(b);
            return;
        }
        o.push(b | 0x80);
    }
}

/// A symbol an inline template names: the word it is in, the relocation kind, the C name, the addend.
pub(package) struct InlRel {
    pub(package) at: u32,
    pub(package) kind: u8,
    pub(package) name: String,
    pub(package) addend: i64,
}

extend Asm {
    /// Assemble the arm64 inline template `text` (operands substituted) into `words`; each symbol it names
    /// into `rels` (C names: `apple` spells them with a leading `_`). A label of the template resolves in
    /// place. False with `err` set when a statement does not assemble.
    pub(package) fn inline_a64(
        text: str,
        apple: bool,
        words: &mut Vector<u32>,
        rels: &mut Vector<InlRel>,
        err: &mut String,
    ) bool {
        let mut sts = Vector::<Stmt>::new();
        statements(text, false, &mut sts);
        let mut a0 = Asm::new(
            ISA_A64,
            if apple {
                FMT_MACHO
            } else {
                FMT_ELF
            },
        );
        let base = words.len();
        let mut refs = Vector::<InlRef>::new();
        for k in 0..sts.len() {
            for j in 0..sts[k].labels.len() {
                a0.labels.push(
                    Label {
                        name: sts[k].labels[j].clone(),
                        sec: 0,
                        off: (words.len() - base) as u64 * 4,
                        stmt: k as u32,
                    },
                );
            }
            let body = sts[k].body.as_str();
            if body.len() == 0 {
                continue;
            }
            if body.starts_with(".inst") || body.starts_with(".word") || body.starts_with(".long") {
                let mut v: i64 = 0;
                if !Asm::num(body.slice(5, body.len()), &mut v) {
                    err.format_into("line {}: '{}' takes one number", sts[k].line, body);
                    return false;
                }
                words.push(v as u32);
                continue;
            }
            if body.byte_at(0) == b'.' {
                err.format_into("line {}: inline assembly takes no directive but '.inst': '{}'", sts[k].line, body);
                return false;
            }
            let mut w: u32 = 0;
            let mut fx = aa::Fix::new();
            let mut e = String::new();
            if !aa::assemble(body, &mut w, &mut fx, &mut e) {
                err.format_into("line {}: {}", sts[k].line, e.as_str());
                return false;
            }
            if fx.kind != aa::FX_NONE {
                refs.push(
                    InlRef {
                        at: (words.len() - base) as u32,
                        kind: fx.kind,
                        name: fx.name.clone(),
                        addend: fx.addend,
                        stmt: k as u32,
                    },
                );
            }
            words.push(w);
        }
        for i in 0..refs.len() {
            let at = refs[i].at;
            let kind = refs[i].kind;
            let li = a0.find(&refs[i].name, refs[i].stmt);
            if li >= 0 && a0.local_kind(kind) {
                let d = a0.labels[li as usize].off as i64 + refs[i].addend - at as i64 * 4;
                let w = words[base + at as usize];
                if kind == aa::FX_ADR {
                    if d < -(1i64 << 20) || d >= 1i64 << 20 {
                        err.format_into("'{}' is out of the instruction's reach", refs[i].name.as_str());
                        return false;
                    }
                    let u = d as u32;
                    words.set(base + at as usize, w & 0x9F00001F | (u & 3) << 29 | (u >> 2 & 0x7FFFF) << 5);
                } else {
                    if (d & 3) != 0 || !a::reaches(w, d) {
                        err.format_into("'{}' is out of the instruction's reach", refs[i].name.as_str());
                        return false;
                    }
                    words.set(base + at as usize, a::repatch(w, d as i32));
                }
                continue;
            }
            if li >= 0 || kind == aa::FX_B19 || kind == aa::FX_B14 || kind == aa::FX_ADR {
                err.format_into("'{}': inline assembly reaches its own labels by branches only", refs[i].name.as_str());
                return false;
            }
            rels.push(
                InlRel {
                    at: base as u32 + at,
                    kind: kind,
                    name: String::from_str(a0.c_name(&refs[i].name)),
                    addend: refs[i].addend,
                },
            );
        }
        return true;
    }
}

extend Asm {
    /// Assemble the x86-64 inline template `text` (operands substituted) onto `code`; each symbol it
    /// names into `rels` (`at`: its field's position in `code`). A label of the template resolves in
    /// place: a branch to one behind takes the shortest form, one to a label ahead 32 bits. False with
    /// `err` set when a statement does not assemble.
    pub(package) fn inline_x64(text: str, code: &mut Vector<u8>, rels: &mut Vector<InlRel>, err: &mut String) bool {
        let mut sts = Vector::<Stmt>::new();
        statements(text, true, &mut sts);
        let mut a0 = Asm::new(ISA_X64, FMT_ELF);
        let base = code.len();
        let mut refs = Vector::<InlRef>::new();
        for k in 0..sts.len() {
            let here = (code.len() - base) as u64;
            for j in 0..sts[k].labels.len() {
                a0.labels.push(Label { name: sts[k].labels[j].clone(), sec: 0, off: here, stmt: k as u32 });
            }
            let body = sts[k].body.as_str();
            if body.len() == 0 {
                continue;
            }
            if body.starts_with(".byte") {
                let mut it = body.slice(5, body.len()).split(",");
                loop {
                    let t = switch it.next() {
                        Some(y) => y,
                        None => {
                            break;
                        },
                    };
                    let mut v: i64 = 0;
                    if !Asm::num(t, &mut v) || v < -128 || v > 255 {
                        err.format_into("line {}: '.byte' takes bytes: '{}'", sts[k].line, body);
                        return false;
                    }
                    code.push((v & 0xFF) as u8);
                }
                continue;
            }
            if body.byte_at(0) == b'.' {
                err.format_into("line {}: inline assembly takes no directive but '.byte': '{}'", sts[k].line, body);
                return false;
            }
            let mut fx = xa::Fix::new();
            let mut e = String::new();
            let at = code.len();
            if !xa::assemble(body, xa::NOTGT, code, &mut fx, &mut e) {
                err.format_into("line {}: {}", sts[k].line, e.as_str());
                return false;
            }
            if fx.kind == xa::FX_NONE {
                continue;
            }
            let li = a0.find(&fx.name, k as u32);
            if li >= 0 && fx.kind == x::R_PLT32 && a0.labels[li as usize].stmt <= k as u32 {
                code.truncate(at);
                let tgt = a0.labels[li as usize].off as i64 - here as i64;
                if !xa::assemble(body, tgt, code, &mut fx, &mut e) {
                    err.format_into("line {}: {}", sts[k].line, e.as_str());
                    return false;
                }
                continue;
            }
            refs.push(
                InlRef {
                    at: (at - base) as u32 + fx.at,
                    kind: fx.kind,
                    name: fx.name.clone(),
                    addend: fx.addend,
                    stmt: k as u32,
                },
            );
        }
        for i in 0..refs.len() {
            let li = a0.find(&refs[i].name, refs[i].stmt);
            if li >= 0 {
                if !a0.local_kind(refs[i].kind) {
                    err.format_into(
                        "'{}': inline assembly reaches its own labels by branches and RIP-relative operands only",
                        refs[i].name.as_str(),
                    );
                    return false;
                }
                let d = a0.labels[li as usize].off as i64 + refs[i].addend - refs[i].at as i64;
                for q in 0..4usize {
                    code.set(base + refs[i].at as usize + q, (d as u64 >> 8 * q as u64 & 0xFF) as u8);
                }
                continue;
            }
            rels.push(
                InlRel {
                    at: base as u32 + refs[i].at,
                    kind: refs[i].kind,
                    name: refs[i].name.clone(),
                    addend: refs[i].addend,
                },
            );
        }
        return true;
    }
}

// The x86-64 NOPs GNU as and LLVM write, of 1 to 10 bytes: the one of `n` bytes starts at n(n-1)/2.
const NOPS: [u8; 55] = [
    0x90,
    0x66,
    0x90,
    0x0F,
    0x1F,
    0x00,
    0x0F,
    0x1F,
    0x40,
    0x00,
    0x0F,
    0x1F,
    0x44,
    0x00,
    0x00,
    0x66,
    0x0F,
    0x1F,
    0x44,
    0x00,
    0x00,
    0x0F,
    0x1F,
    0x80,
    0x00,
    0x00,
    0x00,
    0x00,
    0x0F,
    0x1F,
    0x84,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x66,
    0x0F,
    0x1F,
    0x84,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x66,
    0x2E,
    0x0F,
    0x1F,
    0x84,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
];

// The encoding number of x86-64 register `r` (a 64-bit general register 0..15, xmm 16..31); -1 for
// none.
const fn x64_reg_number(r: str) i64 {
    let gp: [str<'static>; 16] = [
        "rax",
        "rcx",
        "rdx",
        "rbx",
        "rsp",
        "rbp",
        "rsi",
        "rdi",
        "r8",
        "r9",
        "r10",
        "r11",
        "r12",
        "r13",
        "r14",
        "r15",
    ];
    for i in 0..16usize {
        if unsafe gp[i] == r {
            return i as i64;
        }
    }
    if r.starts_with("xmm") && r.len() > 3 && r.len() <= 5 {
        return switch r.slice(3, r.len()).parse_u64() {
            Some(n) => if n < 16 {
                16 + n as i64
            } else {
                -1i64
            },
            None => -1i64,
        };
    }
    return -1;
}

// The DWARF number of x86-64 register `r`: rax rdx rcx rbx rsi rdi rbp rsp r8..r15 rip xmm0..15; -1 for
// none.
const fn x64_dwarf(r: str) i64 {
    if r == "rip" {
        return 16;
    }
    let n = x64_reg_number(r);
    if n >= 16 {
        return n + 1;
    }
    return switch n {
        0 => 0i64,
        1 => 2i64,
        2 => 1i64,
        3 => 3i64,
        4 => 7i64,
        5 => 6i64,
        6 => 4i64,
        7 => 5i64,
        _ => n,
    };
}

// A reference of an inline template: its word, kind, name, addend and statement.
struct InlRef {
    pub(package) at: u32,
    pub(package) kind: u8,
    pub(package) name: String,
    pub(package) addend: i64,
    pub(package) stmt: u32,
}

// ---- wasm ----

// A function of a wasm module-level block: its symbol's name, locals, code and the references to
// resolve once every `.functype` is known.
struct WasmFn {
    pub(package) name: String,
    pub(package) locals: Vector<u8>,
    pub(package) code: Vector<u8>,
    pub(package) fixes: Vector<wa::Fix>,
}

// The type of a `.functype` name.
pub(package) struct WasmType {
    pub(package) name: String,
    pub(package) enc: Vector<u8>,
}

/// The relocation of reference `fx` at byte `off` of a wasm body in object `o`; `types` gives the
/// `.functype` of a name the object does not type yet. False with `err` set when the name has no type
/// a call needs, or the reference has no relocation.
pub(package) fn wasm_reloc(
    o: &mut wo::WObj,
    fx: &wa::Fix,
    off: u32,
    types: &Vector<WasmType>,
    rel: &mut wo::WRel,
    err: &mut String,
) bool {
    let name = fx.name.as_str();
    let mut ty: i64 = -1;
    for k in 0..types.len() {
        if types[k].name.as_str() == name {
            ty = o.type_index(&types[k].enc);
        }
    }
    *rel = wo::WRel { kind: fx.kind, off: off, sym: 0, addend: fx.addend as i32 };
    if fx.kind == w::R_FUNCTION_INDEX_LEB || fx.kind == w::R_MEMORY_ADDR_SLEB && ty >= 0 {
        // A function: called, or its table index taken.
        let s = o.sym(name, wo::K_FUNC);
        if o.syms[s as usize].kind != wo::K_FUNC {
            err.format_into("'{}' is no function", name);
            return false;
        }
        if ty >= 0 && o.syms[s as usize].def == wo::NONE {
            o.import_type(s, ty as u32);
        }
        if o.syms[s as usize].ty == wo::NONE {
            err.format_into("'{}' has no '.functype'", name);
            return false;
        }
        rel.sym = s;
        if fx.kind == w::R_MEMORY_ADDR_SLEB {
            rel.kind = w::R_TABLE_INDEX_SLEB;
            if fx.addend != 0 {
                err.format_into("'{}': a function's table index takes no addend", name);
                return false;
            }
        }
        return true;
    }
    if fx.kind == w::R_GLOBAL_INDEX_LEB {
        if name != "__stack_pointer" {
            err.format_into("'{}': the only global is '__stack_pointer'", name);
            return false;
        }
        rel.sym = o.sym(name, wo::K_GLOBAL);
        return true;
    }
    if fx.kind == w::R_MEMORY_ADDR_SLEB || fx.kind == w::R_MEMORY_ADDR_LEB {
        rel.sym = o.sym(name, wo::K_DATA);
        if o.syms[rel.sym as usize].kind != wo::K_DATA {
            err.format_into("'{}' is no data symbol", name);
            return false;
        }
        return true;
    }
    if fx.kind == w::R_TYPE_INDEX_LEB {
        let mut i: usize = 0;
        let mut txt = String::new();
        let mut enc = Vector::<u8>::new();
        if !wa::signature(name, &mut i, &mut txt, &mut enc) {
            err.format_into("bad signature '{}'", name);
            return false;
        }
        rel.sym = o.type_index(&enc);
        return true;
    }
    if fx.kind == w::R_TABLE_NUMBER_LEB {
        if name != "__indirect_function_table" {
            err.format_into("'{}': the only table is '__indirect_function_table'", name);
            return false;
        }
        rel.sym = o.sym(name, wo::K_TABLE);
        return true;
    }
    err.format_into("'{}': a reference without a relocation", name);
    return false;
}

// The rest of `s` after `n` bytes, trimmed.
const fn after(s: str, n: usize) str {
    return s.slice(n, s.len()).trim();
}

// The two comma-separated names of `s`.
const fn two_names<'a>(s: str<'a>, a: &mut str<'a>, b: &mut str<'a>) bool {
    let c = s.find_byte(b',');
    if c < 0 {
        return false;
    }
    *a = s.slice(0, c as usize).trim();
    *b = s.slice(c as usize + 1, s.len()).trim();
    return a.len() != 0 && b.len() != 0;
}

/// Assemble wasm module-level `text` (LLVM's syntax: `.functype`, `.import_module`, `.import_name`,
/// `.globl`, `.hidden`, functions from their label to `end_function`) into `o`. False with `err` set
/// when a statement does not assemble.
pub(package) fn wasm_module(o: &mut wo::WObj, text: str, err: &mut String) bool {
    let mut sts = Vector::<Stmt>::new();
    statements(text, true, &mut sts);
    let mut types = Vector::<WasmType>::new();
    let mut globals = Vector::<String>::new();
    let mut hidden = Vector::<String>::new();
    let mut imods = Vector::<(String, String)>::new();
    let mut inames = Vector::<(String, String)>::new();
    let mut fns = Vector::<WasmFn>::new();
    let mut open = false;
    for k in 0..sts.len() {
        let line = sts[k].line;
        for j in 0..sts[k].labels.len() {
            if open {
                err.format_into("line {}: a label inside a function", line);
                return false;
            }
            open = true;
            fns.push(
                WasmFn {
                    name: sts[k].labels[j].clone(),
                    locals: Vector::<u8>::new(),
                    code: Vector::<u8>::new(),
                    fixes: Vector::<wa::Fix>::new(),
                },
            );
        }
        let body = sts[k].body.as_str();
        if body.len() == 0 {
            continue;
        }
        if body.starts_with(".functype") {
            let rest = after(body, 9);
            let mut i: usize = 0;
            while i < rest.len() && rest.byte_at(i) != b' ' && rest.byte_at(i) != b'\t' && rest.byte_at(i) != b'(' {
                i += 1;
            }
            let name = rest.slice(0, i);
            let mut txt = String::new();
            let mut enc = Vector::<u8>::new();
            if name.len() == 0 || !wa::signature(rest, &mut i, &mut txt, &mut enc) || rest.slice(i, rest.len()).trim().len() != 0 {
                err.format_into("line {}: '.functype' takes a name and a signature", line);
                return false;
            }
            types.push(WasmType { name: String::from_str(name), enc: enc });
            continue;
        }
        if body.starts_with(".import_module") || body.starts_with(".import_name") {
            let modl = body.starts_with(".import_module");
            let mut a = "";
            let mut b2 = "";
            if !two_names(
                after(
                    body,
                    if modl {
                        14usize
                    } else {
                        12usize
                    },
                ),
                &mut a,
                &mut b2,
            ) {
                err.format_into("line {}: '{}' takes a symbol and a name", line, body);
                return false;
            }
            let e = (String::from_str(a), String::from_str(b2));
            if modl {
                imods.push(e);
            } else {
                inames.push(e);
            }
            continue;
        }
        if body.starts_with(".globl") || body.starts_with(".global") || body.starts_with(".hidden") {
            let n = String::from_str(
                after(
                    body,
                    if body.starts_with(".globl") || body.starts_with(".hidden") {
                        7usize
                    } else {
                        8usize
                    },
                ),
            );
            if body.starts_with(".hidden") {
                hidden.push(n);
            } else {
                globals.push(n);
            }
            continue;
        }
        if body.starts_with(".local") {
            if !open {
                err.format_into("line {}: '.local' outside a function", line);
                return false;
            }
            let mut it = after(body, 6).split(",");
            let f = fns.index_mut(fns.len() - 1);
            loop {
                let tn = switch it.next() {
                    Some(x) => x.trim(),
                    None => {
                        break;
                    },
                };
                let ty = switch tn {
                    "i32" => w::I32,
                    "i64" => w::I64,
                    "f32" => w::F32,
                    "f64" => w::F64,
                    "v128" => w::V128,
                    _ => 0u8,
                };
                if ty == 0 {
                    err.format_into("line {}: '{}' is no local type", line, tn);
                    return false;
                }
                f.locals.push(ty);
            }
            continue;
        }
        if body.byte_at(0) == b'.' {
            // Directives that change nothing in a wasm object.
            if body.starts_with(".type") || body.starts_with(".size") || body.starts_with(".text") || body.starts_with(
                ".section",
            ) || body.starts_with(".p2align") || body.starts_with(".globaltype") || body.starts_with(".file") || body.starts_with(
                ".ident",
            ) {
                continue;
            }
            err.format_into("line {}: the directive '{}' is not one this assembler takes", line, body);
            return false;
        }
        if !open {
            err.format_into("line {}: an instruction outside a function", line);
            return false;
        }
        let f = fns.index_mut(fns.len() - 1);
        let at = f.code.len() as u32;
        let mut fx = Vector::<wa::Fix>::new();
        let mut e = String::new();
        if !wa::assemble(body, &mut f.code, &mut fx, &mut e) {
            err.format_into("line {}: {}", line, e.as_str());
            return false;
        }
        for q in 0..fx.len() {
            let x = wa::Fix { kind: fx[q].kind, name: fx[q].name.clone(), addend: fx[q].addend, at: at + fx[q].at };
            f.fixes.push(x);
        }
        if body.trim() == "end_function" {
            open = false;
        }
    }
    if open {
        err.push_str("a function without its 'end_function'");
        return false;
    }
    // The functions into the object.
    for k in 0..fns.len() {
        let name = fns[k].name.as_str();
        let mut enc = Vector::<u8>::new();
        let mut found = false;
        for j in 0..types.len() {
            if types[j].name.as_str() == name {
                enc = types[j].enc.clone();
                found = true;
            }
        }
        if !found {
            err.format_into("the function '{}' has no '.functype'", name);
            return false;
        }
        let s = o.sym(name, wo::K_FUNC);
        if o.syms[s as usize].def != wo::NONE {
            err.format_into("the function '{}' is defined twice", name);
            return false;
        }
        let mut fl: u32 = 0;
        if !Asm::listed(&globals, name) {
            fl |= wo::F_LOCAL;
        }
        if Asm::listed(&hidden, name) {
            fl |= wo::F_HIDDEN;
        }
        let ty = o.type_index(&enc);
        let mut wf = wo::WFunc {
            sym: s,
            locals: fns[k].locals.clone(),
            code: fns[k].code.clone(),
            rels: Vector::<wo::WRel>::new(),
        };
        for q in 0..fns[k].fixes.len() {
            let mut rel = wo::WRel { kind: 0, off: 0, sym: 0, addend: 0 };
            if !wasm_reloc(o, &fns[k].fixes[q], fns[k].fixes[q].at, &types, &mut rel, err) {
                return false;
            }
            wf.rels.push(rel);
        }
        o.define_func(s, ty, fl, wf);
    }
    // The imports' modules and names, of the functions the object calls.
    for k in 0..o.syms.len() {
        let nm = String::from_str(o.name_of(k as u32));
        let y = o.syms[k];
        if y.kind != wo::K_FUNC || y.def != wo::NONE {
            continue;
        }
        for j in 0..types.len() {
            if types[j].name.as_str() == nm.as_str() && y.ty == wo::NONE {
                let ti = o.type_index(&types[j].enc);
                o.import_type(k as u32, ti);
            }
        }
        for j in 0..imods.len() {
            if imods[j].0.as_str() == nm.as_str() {
                let id = o.names.intern(&imods[j].1);
                o.syms.index_mut(k).imod = id;
            }
        }
        for j in 0..inames.len() {
            if inames[j].0.as_str() == nm.as_str() {
                let id = o.names.intern(&inames[j].1);
                o.syms.index_mut(k).iname = id;
            }
        }
    }
    return true;
}
