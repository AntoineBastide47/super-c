// Type rendering: a type as Super-C surface syntax, for diagnostics, hover and `TypeInfo.qualified_name`.
import lexer::token as tok;
import ast::ast as *;
import module::loader as loader;

// Whether module `m` is the prelude tuple module: its instances are tuples.
fn rt_tuple(pkg: *const loader::Package, m: ModuleId) bool {
    return pkg != null && unsafe (*pkg).modules[m as usize].path.as_str() == "__std::tuple";
}

// The Ast to read for module `m`'s decls when rendering against the current ast `a` (mirrors
// TypeChecker::mod_ast): foreign modules come from the package, the current one from `a` itself.
const fn rt_ast(pkg: *const loader::Package, a: *const Ast, m: ModuleId) *const Ast {
    if m != unsafe (*a).module {
        return unsafe &(*pkg).modules[m as usize].ast;
    }
    return a;
}
// Whether closure node `n` returns its body's value without a written result list: an expression
// body, or a block whose `return`s give one (`ClosureData.ret_infer`).
pub(module) const fn closure_body_ret(a: &Ast, n: NodeId) bool {
    return a.ext(n).closure.expr_body || a.ext(n).closure.ret_infer;
}

const fn rt_src(pkg: *const loader::Package, a: *const Ast, cur_src: str, m: ModuleId) str {
    if m != unsafe (*a).module {
        return unsafe (*pkg).modules[m as usize].source.as_str();
    }
    return cur_src;
}

// `fn(P, Q) R` from a function type's decl node. Reads the CACHED type of each parameter/return node
// rather than lowering (no checker here); an uncached slot renders `..`, so a signature never checked
// still names itself. Without this every function type printed as a bare "fn" and a mismatch between
// two of them read "expected 'fn', found 'fn'".
fn render_fn_sig_str(pkg: *const loader::Package, a: *const Ast, cur_src: str, ty: &Ty, out: &mut String) {
    if ty.fn_sig() {
        render_sig_str(pkg, a, cur_src, ty, out);
        return;
    }
    let ma = rt_ast(pkg, a, ty.module);
    let mut ps = NodeList { start: 0, len: 0 };
    let mut rs = NodeList { start: 0, len: 0 };
    if !unsafe (*ma).sig_lists(ty.as_data.decl, &mut ps, &mut rs) {
        out.push_str("fn");
        return;
    }
    out.push_str("fn(");
    for i in 0..ps.len {
        if i != 0 {
            out.push_str(", ");
        }
        render_slot_str(pkg, a, cur_src, ma, unsafe (*ma).list(ps)[i as usize], out);
    }
    out.push_str(")");
    let dn = unsafe (*ma).at_const(ty.as_data.decl);
    // A closure that lists no return and returns its body's value: the body's type is the return type.
    let bt = if dn.kind == NodeKind::NODE_CLOSURE && closure_body_ret(unsafe &*ma, ty.as_data.decl) && rs.len == 0 {
        unsafe (*ma).type_of(unsafe (*ma).ext(ty.as_data.decl).closure.body);
    } else {
        TYPE_NONE;
    };
    if rs.len == 1 {
        out.push_str(" ");
        render_slot_str(pkg, a, cur_src, ma, unsafe (*ma).list(rs)[0], out);
    } else if rs.len > 1 {
        // Several results in parentheses, as `render_sig_str` spells them.
        out.push_str(" (");
        for i in 0..rs.len {
            if i != 0 {
                out.push_str(", ");
            }
            render_slot_str(pkg, a, cur_src, ma, unsafe (*ma).list(rs)[i as usize], out);
        }
        out.push_str(")");
    } else if bt != TYPE_NONE && !(unsafe (*ma).type_at(bt).kind == TypeKind::TYPE_BUILTIN && unsafe (*ma).type_at(bt).as_data.builtin == BuiltinType::BT_VOID) {
        out.push_str(" ");
        render_type_str(pkg, ma, rt_src(pkg, a, cur_src, unsafe (*ma).module), bt, out);
    }
}

// Function-pointer type `ty` (pool `a`): `fn(P, ..) R`, `move fn(..)`, several results in parentheses.
fn render_sig_str(pkg: *const loader::Package, a: *const Ast, cur_src: str, ty: &Ty, out: &mut String) {
    let mut next: u8 = 0;
    let none = Vector::<String>::new();
    render_sig_lts(pkg, a, cur_src, ty, &none, &mut next, false, out);
}

// Append function-pointer type `ty` with the lifetimes it names: a lifetime it takes from outside it
// as `outer` names it (else `'1`, `'2`, ..), its own groups as letters from `*next` on, under a
// `for<..>` when `binder`.
fn render_sig_lts(
    pkg: *const loader::Package,
    a: *const Ast,
    cur_src: str,
    ty: &Ty,
    outer: &Vector<String>,
    next: &mut u8,
    binder: bool,
    out: &mut String,
) {
    let mut cls = Vector::<u8>::new();
    let mut fl = Vector::<u8>::new();
    let mut nres: u32 = 0;
    if pkg != null && unsafe (*a).instance(ty.as_data.fnp.sig).lts != 0 {
        unsafe (*pkg).sig_classes(unsafe &*a, ty, &mut cls, &mut fl, &mut nres, &mut loader::Invariant {});
    }
    // The name at each position.
    let first = *next;
    let mut names = Vector::<String>::new();
    let mut letter = Vector::<u8>::new();
    letter.resize_default(LC_OUTER as usize);
    for k in 0..cls.len() {
        let c = cls[k];
        let mut nm = String::new();
        if c == LC_STATIC {
            nm.push_str("'static");
        } else if c >= LC_OUTER && c != LC_TOO_MANY {
            let g = (c - LC_OUTER) as usize;
            if g < outer.len() {
                nm.push_str(outer[g].as_str());
            } else {
                nm.push_byte(b'\'');
                nm.push_u64(g as u64 + 1);
            }
        } else if c >= LC_GROUP && c < LC_OUTER {
            if letter[c as usize] == 0 {
                letter.set(c as usize, *next + 1);
                *next = *next + 1;
            }
            lt_letter(&mut nm, letter[c as usize] - 1);
        }
        names.push(nm);
    }
    if (ty.qualifier & FN_MOVE) != 0 {
        out.push_str("move ");
    }
    if binder && *next != first {
        out.push_str("for<");
        for l in first..*next {
            if l != first {
                out.push_str(", ");
            }
            lt_letter(out, l);
        }
        out.push_str("> ");
    }
    out.push_str("fn(");
    let np = unsafe (*a).sig_len(ty, false);
    let nr = unsafe (*a).sig_len(ty, true);
    let mut pos = nres;
    for i in 0..np {
        if i != 0 {
            out.push_str(", ");
        }
        render_lt_type(pkg, a, cur_src, unsafe (*a).sig_at(ty, false, i), &names, &mut pos, out, 0, next);
    }
    out.push_str(")");
    pos = 0;
    for i in 0..nr {
        if i != 0 {
            out.push_str(", ");
        } else if nr > 1 {
            out.push_str(" (");
        } else {
            out.push_str(" ");
        }
        render_lt_type(pkg, a, cur_src, unsafe (*a).sig_at(ty, true, i), &names, &mut pos, out, 0, next);
    }
    if nr > 1 {
        out.push_str(")");
    }
}

// Append lifetime letter `l`: `'a` .. `'z`, then `'a26` ...
fn lt_letter(out: &mut String, l: u8) {
    out.push_byte(b'\'');
    out.push_byte(b'a' + l % 26);
    if l >= 26 {
        out.push_u64(l);
    }
}

// The lifetime positions of `t` (`Package::lt_count`), 0 without a package.
fn rt_lt_count(pkg: *const loader::Package, a: *const Ast, t: TypeId) u32 {
    if pkg == null {
        return 0;
    }
    return unsafe (*pkg).lt_count(unsafe &*a, t);
}

// Append type `t` with the lifetime names `names` at its positions, from `*pos` on, and advance
// `*pos` past them (`Package::lt_walk` order; `depth` its depth there). A function type in it names
// its own lifetimes from `*next` on.
fn render_lt_type(
    pkg: *const loader::Package,
    a: *const Ast,
    cur_src: str,
    t: TypeId,
    names: &Vector<String>,
    pos: &mut u32,
    out: &mut String,
    depth: u32,
    next: &mut u8,
) {
    let n = if depth > 16 {
        0;
    } else {
        rt_lt_count(pkg, a, t);
    };
    let mut named = false;
    for k in *pos..(*pos + n).min(names.len() as u32) {
        named = named || names[k as usize].len() != 0;
    }
    let y = *unsafe (*a).type_at(t);
    let k = y.kind;
    let dsig = if k == TypeKind::TYPE_DYN {
        unsafe (*a).dyn_fn_sig(&y);
    } else {
        TYPE_NONE;
    };
    if !named && !y.fn_sig() && dsig == TYPE_NONE {
        render_type_str(pkg, a, cur_src, t, out);
        *pos = *pos + n;
        return;
    }
    if k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_SLICE {
        out.push_str(
            if k == TypeKind::TYPE_SLICE {
                "[]";
            } else {
                "&";
            },
        );
        render_lt_name(names, pos, out, false);
        if k == TypeKind::TYPE_REFERENCE && y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
            out.push_str("mut ");
        }
        render_lt_type(pkg, a, cur_src, y.as_data.elem, names, pos, out, depth + 1, next);
    } else if k == TypeKind::TYPE_POINTER {
        out.push_str(
            if y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                "*mut ";
            } else if y.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 {
                "*const ";
            } else {
                "*";
            },
        );
        render_lt_type(pkg, a, cur_src, y.as_data.elem, names, pos, out, depth + 1, next);
    } else if k == TypeKind::TYPE_ARRAY {
        out.push_str("[");
        render_lt_type(pkg, a, cur_src, y.as_data.arr.elem, names, pos, out, depth + 1, next);
        out.push_str("; ");
        if y.arr_sym() {
            render_type_str(pkg, a, cur_src, y.as_data.arr.len, out);
        } else {
            out.push_u64(y.as_data.arr.len);
        }
        out.push_str("]");
    } else if k == TypeKind::TYPE_STRUCT || k == TypeKind::TYPE_ENUM {
        render_type_str(pkg, a, cur_src, t, out);
        out.push_str("<");
        for i in 0..n {
            if i != 0 {
                out.push_str(", ");
            }
            render_lt_name(names, pos, out, true);
        }
        out.push_str(">");
    } else if y.fn_sig() {
        render_lt_fn(pkg, a, cur_src, &y, names, pos, out, next);
    } else if k == TypeKind::TYPE_INSTANCE || k == TypeKind::TYPE_DYN {
        let mut it = *unsafe (*a).instance(y.as_data.inst);
        if k == TypeKind::TYPE_INSTANCE {
            let _ = unsafe (*a).targs_of(t, &mut it);
        }
        if k == TypeKind::TYPE_INSTANCE && rt_tuple(pkg, it.module) {
            out.push_str("(");
            for i in 0..it.n {
                if i != 0 {
                    out.push_str(", ");
                }
                render_lt_type(pkg, a, cur_src, unsafe it.args[i as usize], names, pos, out, depth + 1, next);
            }
            out.push_str(")");
            return;
        }
        let ma = rt_ast(pkg, a, it.module);
        if k == TypeKind::TYPE_DYN {
            if y.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 {
                out.push_str("Box<");
            } else {
                out.push_str("&");
                render_lt_name(names, pos, out, false);
                if y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                    out.push_str("mut ");
                }
            }
            out.push_str("dyn ");
            if dsig != TYPE_NONE {
                render_lt_fn(pkg, a, cur_src, unsafe (*a).type_at(dsig), names, pos, out, next);
                if y.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 {
                    out.push_str(">");
                }
                return;
            }
        }
        let nm = if k == TypeKind::TYPE_DYN {
            unsafe (*ma).at_const(unsafe (*ma).ext_name(it.decl)).as_data.name.text;
        } else {
            unsafe (*ma).at_const(unsafe (*ma).ext_name(it.decl)).as_data.name.text;
        };
        out.push_str(rt_src(pkg, a, cur_src, it.module).slice(nm.start as usize, nm.end as usize));
        let nlt = unsafe (*pkg).decl_nlt(unsafe &*a, it.module, it.decl);
        if nlt + it.n as u32 != 0 {
            out.push_str("<");
            for i in 0..nlt {
                if i != 0 {
                    out.push_str(", ");
                }
                render_lt_name(names, pos, out, true);
            }
            for i in 0..it.n {
                if nlt + i as u32 != 0 {
                    out.push_str(", ");
                }
                render_lt_type(pkg, a, cur_src, unsafe it.args[i as usize], names, pos, out, depth + 1, next);
            }
            out.push_str(">");
        }
        if k == TypeKind::TYPE_DYN && y.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 {
            out.push_str(">");
        }
    }
}

// Append function-pointer type `y` inside a rendered type: its positions there (`names` from `*pos`
// on) name the lifetimes it takes from outside it; one with no name is a lifetime of the enclosing
// type's own, named from `*next` on.
fn render_lt_fn(
    pkg: *const loader::Package,
    a: *const Ast,
    cur_src: str,
    y: &Ty,
    names: &Vector<String>,
    pos: &mut u32,
    out: &mut String,
    next: &mut u8,
) {
    let mut outer = Vector::<String>::new();
    let mut vs = Vector::<u32>::new();
    if pkg != null {
        unsafe (*pkg).sig_outer(unsafe &*a, y, &mut vs, 0, &mut loader::Invariant {});
    }
    for _ in 0..vs.len() {
        let mut nm = String::new();
        if (*pos) as usize < names.len() && names[(*pos) as usize].len() != 0 {
            nm.push_str(names[(*pos) as usize].as_str());
        } else {
            lt_letter(&mut nm, *next);
            *next = *next + 1;
        }
        outer.push(nm);
        *pos = *pos + 1;
    }
    render_sig_lts(pkg, a, cur_src, y, &outer, next, true, out);
}

// Append the lifetime name at position `*pos` of `names` and advance; an elided one is `'_` as an
// argument (`whole`), or nothing after `&` and `[]`. Not as an argument, a space follows a name.
fn render_lt_name(names: &Vector<String>, pos: &mut u32, out: &mut String, whole: bool) {
    let p = (*pos) as usize;
    *pos = *pos + 1;
    if p >= names.len() || names[p].len() == 0 {
        if whole {
            out.push_str("'_");
        }
        return;
    }
    out.push_str(names[p].as_str());
    if !whole {
        out.push_byte(b' ');
    }
}

// Text `w` on one line: each run of white space as one space.
pub(module) fn one_line(w: str) String {
    let mut s = String::new();
    let mut gap = false;
    for i in 0..w.len() {
        let c = w.byte_at(i);
        if c == b' ' || c == b'\n' || c == b'\t' || c == b'\r' {
            gap = true;
            continue;
        }
        if gap && s.len() != 0 {
            s.push_byte(b' ');
        }
        gap = false;
        s.push_byte(c);
    }
    return s;
}

// One parameter/return slot of a function type: the node is either a NODE_PARAMETER wrapping a type
// node or the type node itself. A type that names a lifetime renders as written (a type does not keep
// lifetime names).
fn render_slot_str(
    pkg: *const loader::Package,
    a: *const Ast,
    cur_src: str,
    ma: *const Ast,
    slot: NodeId,
    out: &mut String,
) {
    let tn = unsafe (*ma).slot_type_node(slot);
    let mut t = TYPE_NONE;
    if tn != NODE_NONE {
        t = unsafe (*ma).type_of(tn);
        let sp = unsafe (*ma).at_const(tn).span;
        let w = rt_src(pkg, a, cur_src, unsafe (*ma).module).slice(sp.start as usize, sp.end as usize);
        if t != TYPE_NONE && w.contains("'") {
            out.push_str(one_line(w).as_str());
            return;
        }
    }
    if t == TYPE_NONE {
        t = unsafe (*ma).type_of(slot);
    }
    if t == TYPE_NONE {
        out.push_str("..");
        return;
    }
    render_type_str(pkg, ma, rt_src(pkg, a, cur_src, unsafe (*ma).module), t, out);
}

// Append name span `s` of module `m`'s source.
fn rt_put_name(pkg: *const loader::Package, a: *const Ast, cur_src: str, m: ModuleId, s: tok::Span, out: &mut String) {
    out.push_str(rt_src(pkg, a, cur_src, m).slice(s.start as usize, s.end as usize));
}

/// The interface instance a `dyn` type `t` erases to, as written in a bound or a conformance:
/// `Mul<Simd<f32, 4>>`, `fn(i32) i32`, appended to `out`.
pub(package) fn render_iface_str(pkg: *const loader::Package, a: *const Ast, cur_src: str, t: TypeId, out: &mut String) {
    let ty = *unsafe (*a).type_at(t);
    rt_dyn_str(pkg, a, cur_src, &ty, out);
}

// Append the interface or function type `dyn` type `ty` erases to.
fn rt_dyn_str(pkg: *const loader::Package, a: *const Ast, cur_src: str, ty: &Ty, out: &mut String) {
    let ma = rt_ast(pkg, a, ty.module);
    let dsig = unsafe (*a).dyn_fn_sig(ty);
    if dsig != TYPE_NONE {
        render_type_str(pkg, a, cur_src, dsig, out);
        return;
    }
    let ddecl = unsafe (*a).dyn_decl_of(ty);
    let s = unsafe (*ma).at_const(unsafe (*ma).ext_name(ddecl)).as_data.name.text;
    rt_put_name(pkg, a, cur_src, ty.module, s, out);
    let di = *unsafe (*a).instance(ty.as_data.inst);
    if di.n == 0 {
        return;
    }
    // A generic interface names its arguments: `&dyn I<bool>`, never a bare `&dyn I`.
    out.push_str("<");
    for i in 0..di.n {
        if i != 0 {
            out.push_str(", ");
        }
        render_type_str(pkg, a, cur_src, unsafe di.args[i as usize], out);
    }
    out.push_str(">");
}

/// Render `tid` as Super-C surface syntax. The standalone form of TypeChecker::type_str: `a` is the
/// Ast owning the type pool (a checker's in-flight ast, or a module's held ast after the build),
/// `cur_src` that module's source, `pkg` the package for cross-module decl names (null falls back to
/// `a`/`cur_src` for everything). Also serves LSP hover, which renders from a fully built package.
pub(package) fn type_str_of(pkg: *const loader::Package, a: *const Ast, cur_src: str, tid: TypeId) String {
    let mut out = String::new();
    render_type_str(pkg, a, cur_src, tid, &mut out);
    return out;
}

/// Append `tid` as Super-C surface syntax to `out` (`type_str_of`).
pub(package) fn render_type_str(pkg: *const loader::Package, a: *const Ast, cur_src: str, tid: TypeId, out: &mut String) {
    render_ty(pkg, a, cur_src, false, tid, out);
}

/// Append `tid` (a type of module `a`) as `TypeInfo.qualified_name` spells it: `render_type_str`, with
/// the trailing generic arguments that equal their parameter's default dropped (`Vector<i32>`,
/// `Vector<i32, Arena>`).
pub(package) fn render_qualified_name(pkg: *const loader::Package, a: *const Ast, tid: TypeId, out: &mut String) {
    render_ty(pkg, a, unsafe (*pkg).modules[(*a).module as usize].source.as_str(), true, tid, out);
}

// Does argument `arg` (a type of `a`) equal the default of generic parameter `i` of declaration
// `decl` (of `ma`)? Only a default naming a non-generic struct or enum is compared; any other keeps
// its argument.
fn default_arg(ma: *const Ast, decl: NodeId, i: u32, a: *const Ast, arg: TypeId) bool {
    let gens = unsafe (*ma).ext(decl).aggregate.generics;
    if i >= gens.len || arg == TYPE_NONE {
        return false;
    }
    let dft = unsafe (*ma).ext(unsafe (*ma).list(gens)[i as usize]).generic_param.default_type;
    if dft == NODE_NONE {
        return false;
    }
    let d = unsafe (*ma).resolution_def(dft);
    let y = *unsafe (*a).type_at(arg);
    return d.node != NODE_NONE && (y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM) && y.module == d.module && y.as_data.decl == d.node;
}

fn render_ty(pkg: *const loader::Package, a: *const Ast, cur_src: str, elide: bool, tid: TypeId, out: &mut String) {
    if tid == TYPE_NONE {
        // No type was ever assigned: there is nothing IN the value to render. Instance arguments
        // recover the parameter's NAME from their declaration below; a bare hole has no declaration.
        out.push_str("_");
        return;
    }
    let ty = *unsafe (*a).type_at(tid);
    if ty.kind == TypeKind::TYPE_ERROR {
        out.push_str("_");
    } else if ty.kind == TypeKind::TYPE_BUILTIN {
        out.push_str(bt_name(ty.as_data.builtin));
    } else if ty.kind == TypeKind::TYPE_NEVER {
        out.push_str("never");
    } else if ty.kind == TypeKind::TYPE_POINTER || ty.kind == TypeKind::TYPE_REFERENCE {
        out.push_str(pick(ty.kind == TypeKind::TYPE_POINTER, "*", "&"));
        if ty.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
            out.push_str("mut ");
        } else if ty.kind == TypeKind::TYPE_POINTER && ty.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 {
            // A bare `*T` and `*const T` are distinct types.
            out.push_str("const ");
        }
        render_ty(pkg, a, cur_src, elide, ty.as_data.elem, out);
    } else if ty.kind == TypeKind::TYPE_SLICE {
        out.push_str("[]");
        render_ty(pkg, a, cur_src, elide, ty.as_data.elem, out);
    } else if ty.kind == TypeKind::TYPE_ARRAY {
        out.push_str("[");
        render_ty(pkg, a, cur_src, elide, ty.as_data.arr.elem, out);
        out.push_str("; ");
        if ty.arr_sym() {
            render_ty(pkg, a, cur_src, elide, ty.as_data.arr.len, out);
        } else {
            out.push_u64(ty.as_data.arr.len);
        }
        out.push_str("]");
    } else if ty.kind == TypeKind::TYPE_STRUCT || ty.kind == TypeKind::TYPE_ENUM || ty.kind == TypeKind::TYPE_GENERIC {
        let ma = rt_ast(pkg, a, ty.module);
        let d = unsafe (*ma).at_const(ty.as_data.decl);
        let mut nm = unsafe (*ma).ext_name(ty.as_data.decl);
        if d.kind == NodeKind::NODE_GENERIC_PARAM {
            nm = unsafe (*ma).ext_name(ty.as_data.decl);
        }
        rt_put_name(pkg, a, cur_src, ty.module, unsafe (*ma).at_const(nm).as_data.name.text, out);
    } else if ty.kind == TypeKind::TYPE_OPAQUE {
        let ma = rt_ast(pkg, a, ty.module);
        let s = unsafe (*ma).at_const(unsafe (*ma).at_const(ty.as_data.decl).as_data.type_alias.name).as_data.name.text;
        rt_put_name(pkg, a, cur_src, ty.module, s, out);
    } else if ty.kind == TypeKind::TYPE_ASSOC {
        // `T::Output`: the projected type, then the associated type's name.
        let it = *unsafe (*a).instance(ty.as_data.inst);
        render_ty(pkg, a, cur_src, elide, it.args[0], out);
        out.push_str("::");
        let ma = rt_ast(pkg, a, it.module);
        let s = unsafe (*ma).at_const(unsafe (*ma).at_const(it.decl).as_data.type_alias.name).as_data.name.text;
        rt_put_name(pkg, a, cur_src, it.module, s, out);
    } else if ty.kind == TypeKind::TYPE_INSTANCE || ty.is_vec() {
        let mut it = TyInstance {};
        let _ = unsafe (*a).targs_of(tid, &mut it);
        if rt_tuple(pkg, it.module) {
            // A tuple shows as it is written: `(A, B)`.
            out.push_str("(");
            for i in 0..it.n {
                if i != 0 {
                    out.push_str(", ");
                }
                render_ty(pkg, a, cur_src, elide, unsafe it.args[i as usize], out);
            }
            out.push_str(")");
            return;
        }
        let ma = rt_ast(pkg, a, it.module);
        let s = unsafe (*ma).at_const(unsafe (*ma).ext_name(it.decl)).as_data.name.text;
        rt_put_name(pkg, a, cur_src, it.module, s, out);
        // A qualified name drops the trailing arguments that equal their parameter's default.
        let mut shown = it.n;
        while elide && shown > 0 && default_arg(ma, it.decl, shown - 1, a, unsafe it.args[(shown - 1) as usize]) {
            shown -= 1;
        }
        if shown == 0 {
            return;
        }
        out.push_str("<");
        for i in 0..shown {
            if i != 0 {
                out.push_str(", ");
            }
            let ai = unsafe it.args[i as usize];
            if ai == TYPE_NONE || unsafe (*a).type_at(ai).kind == TypeKind::TYPE_ERROR {
                // An argument inference never filled: name the declaration's own parameter;
                // `UInt<BITS>` says WHAT is undetermined, where `UInt<?>` said nothing.
                let gens = unsafe (*ma).ext(it.decl).aggregate.generics;
                if i as u32 < gens.len {
                    let gid = unsafe (*ma).list(gens)[i as usize];
                    let gn = unsafe (*ma).at_const(unsafe (*ma).ext_name(gid)).as_data.name.text;
                    rt_put_name(pkg, a, cur_src, it.module, gn, out);
                } else {
                    out.push_str("?");
                }
            } else {
                render_ty(pkg, a, cur_src, elide, ai, out);
            }
        }
        out.push_str(">");
    } else if ty.kind == TypeKind::TYPE_FUNCTION {
        render_fn_sig_str(pkg, a, cur_src, &ty, out);
    } else if ty.kind == TypeKind::TYPE_DYN {
        out.push_str(
            if ty.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                "&mut dyn ";
            } else if ty.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 {
                "&dyn ";
            } else {
                "Box<dyn ";
            },
        );
        rt_dyn_str(pkg, a, cur_src, &ty, out);
        if ty.qualifier == TypeQualifier::TYPE_QUAL_NONE as u8 {
            out.push_str(">");
        }
    } else if ty.kind == TypeKind::TYPE_CONST {
        // A concrete const argument prints its VALUE: `UInt<64>`, not `UInt<?>`; the number is the
        // whole point of the diagnostic.
        out.push_str(ty.cval().to_string().as_str());
    } else if ty.kind == TypeKind::TYPE_CONST_EXPR {
        // Printed from the canonical form rather than as written: two of these failing to match is the
        // one diagnostic this type produces, and the forms are what differ.
        let l = unsafe (*a).const_lin_at(ty.as_data.inst);
        let mut t = String::from_str("{");
        // A divisor covers the whole sum: `{(N + 63) / 64}`.
        let mut parts: u32 = pick(l.k.is_zero(), 0u32, 1u32);
        for i in 0..l.n {
            parts += pick(unsafe l.c[i as usize].is_zero(), 0u32, 1u32);
        }
        let paren = l.div_of() != i128::one() && parts > 1;
        if paren {
            t.push_str("(");
        }
        for i in 0..l.n {
            let c = unsafe &l.c[i as usize];
            if c.is_zero() {
                continue;
            }
            let pd = unsafe l.p[i as usize];
            let pa = rt_ast(pkg, a, pd.module);
            let ns = unsafe (*pa).at_const(unsafe (*pa).ext_name(pd.node)).as_data.name.text;
            if t.len() > pick(paren, 2usize, 1usize) {
                t.push_str(" + ");
            }
            if *c != i128::one() {
                t.format_into("{}", *c);
                t.push_str(" * ");
            }
            t.push_str(rt_src(pkg, a, cur_src, pd.module).slice(ns.start as usize, ns.end as usize));
        }
        if !l.k.is_zero() {
            t.push_str(" + ");
            t.format_into("{}", l.k);
        }
        if paren {
            t.push_str(")");
        }
        if l.div_of() != i128::one() {
            t.push_str(" / ");
            t.format_into("{}", l.div_of());
        }
        t.push_str("}");
        out.push_str(t.as_str());
    } else if ty.kind == TypeKind::TYPE_FIELD_PROJECTION {
        // The symbolic per-field type of a reflection loop: name it by what it projects, a field or
        // (a `variants` or `payloads` loop's) a payload.
        let pa = rt_ast(pkg, a, ty.module);
        let it = unsafe (*pa).ext(ty.as_data.proj.binder).for_stmt.iterable;
        let cs = unsafe (*pa).at_const(unsafe (*pa).at_const(it).as_data.call.callee).as_data.name.text;
        let cn = rt_src(pkg, a, cur_src, ty.module).slice(cs.start as usize, cs.end as usize);
        out.push_str(pick(cn == "variants" || cn == "payloads", "payload of ", "field of "));
        render_ty(pkg, a, cur_src, elide, ty.as_data.proj.owner, out);
    } else {
        out.push_str("?");
    }
}
