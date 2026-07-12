// --test mode: plan collection, runner synthesis, build+run. Split out of main.spc.
import stdio;
import stdlib;
import string as cstring;
import lexer::token as tok;
import lexer::lexer as lex;
import lexer::token_type as ltt;
import ast::ast as *;
import ast::parser as par;
import fmt::builder as fbld;
import driver_shim as shim;
import module::loader as loader;
import resolver::resolver as resolver;
import typechecker::typechecker as tc;
import consteval::consteval as ce;
import codegen::codegen as cg;
import utils::errors as diag;
import driver::util as *;

// --test options (mirrors src/main.c TestOpts).
pub struct TestOpts {
    pub enabled: bool,
    pub jobs: i32,
    pub no_fork: bool,
    pub filter: *const char,
}
// ---------------------------------------------------------------------------------------------------------
// --test mode: collect every @test/@test_init/@test_free into a runnable plan, then synthesize + build a
// fork-per-test runner. Ports src/main.c's test-plan machinery.
// ---------------------------------------------------------------------------------------------------------
pub struct TestCase {
    pub mod: ModuleId,
    pub func: NodeId,
    pub should_panic: bool,
    pub wants: u8,
    pub suite: DefId,
    pub suite_is_enum: bool,
    pub suite_init: NodeId,
    pub suite_free: NodeId,
}
pub struct TestSuite {
    pub mod: ModuleId,
    pub ty: DefId,
    pub is_enum: bool,
    pub init: NodeId,
    pub fre: NodeId,
}
pub struct TestPlan {
    pub cases: Vector<TestCase>,
    pub fx_init: Vector<NodeId>,
    pub fx_free: Vector<NodeId>,
    pub fx_type: Vector<DefId>,
    pub fx_is_enum: Vector<bool>,
    pub suites: Vector<TestSuite>,
    pub genv_mod: ModuleId,
    pub genv_init: NodeId,
    pub genv_free: NodeId,
    pub genv_type: DefId,
    pub genv_is_enum: bool,
    pub ok: bool,
}
extend TestPlan {
    pub fn new(count: usize) TestPlan {
        let mut pl = TestPlan {
            cases: Vector::<TestCase>::new(),
            fx_init: Vector::<NodeId>::new(),
            fx_free: Vector::<NodeId>::new(),
            fx_type: Vector::<DefId>::new(),
            fx_is_enum: Vector::<bool>::new(),
            suites: Vector::<TestSuite>::new(),
            genv_mod: 0,
            genv_init: NODE_NONE,
            genv_free: NODE_NONE,
            genv_type: DefId { module: 0, node: NODE_NONE },
            genv_is_enum: false,
            ok: true,
        };
        let m = if count != 0 {
            count;
        } else {
            1 as usize;
        };
        for i in 0..m {
            pl.fx_init.push(NODE_NONE);
            pl.fx_free.push(NODE_NONE);
            pl.fx_type.push(DefId { module: 0, node: NODE_NONE });
            pl.fx_is_enum.push(false);
        }
        return pl;
    }
}
extend TestPlan as Free {
    pub fn free(self: &mut Self) void {
        self.cases.free();
        self.fx_init.free();
        self.fx_free.free();
        self.fx_type.free();
        self.fx_is_enum.free();
        self.suites.free();
    }
}

// A test-plan validation error, rendered with the compiler's usual source excerpt.
fn test_err(p: &mut loader::Package, m: ModuleId, sp: tok::Span, msg: *const char) void {
    let src = p.modules[m as usize].source.as_str();
    let len = p.modules[m as usize].source.len();
    let file = p.modules[m as usize].file.as_str();
    let mut errs = diag::Errors::new();
    errs.emit(sp.start, sp.end - sp.start, String::from_cstr(msg));
    errs.finalize(src, file);
    errs.log();
    errs.free();
    p.ok = false;
}

// The plain struct/enum decl a type NODE names, or {0, NODE_NONE} (fixtures must be nominal + non-generic).
fn test_type_decl(p: &loader::Package, am: ModuleId, tnode: NodeId, is_enum: *mut bool) DefId {
    let none = DefId { module: 0, node: NODE_NONE };
    if tnode == NODE_NONE {
        return none;
    }
    let a = mod_ast_c(p, am);
    let tk = unsafe (*a).at_const(tnode).kind;
    if tk != NodeKind::NODE_TYPE_PATH && tk != NodeKind::NODE_IDENTIFIER {
        return none;
    }
    let d = unsafe (*a).resolution_def(tnode);
    if d.node == NODE_NONE || d.module as usize >= p.modules.len() {
        return none;
    }
    let da = mod_ast_c(p, d.module);
    let dk = unsafe (*da).at_const(d.node).kind;
    let gen = unsafe (*da).at_const(d.node).as_data.aggregate.generics;
    if dk != NodeKind::NODE_STRUCT && dk != NodeKind::NODE_ENUM || gen.len != 0 {
        return none;
    }
    unsafe *is_enum = dk == NodeKind::NODE_ENUM;
    return d;
}

// A function's single return type node (unwrapping a named return), or NODE_NONE.
fn test_fn_ret_node(p: &loader::Package, am: ModuleId, fnode: NodeId) NodeId {
    let a = mod_ast_c(p, am);
    let rets = unsafe (*a).at_const(fnode).as_data.function.returns;
    if rets.len != 1 {
        return NODE_NONE;
    }
    let r0 = unsafe (*a).list(rets)[0];
    let rn = unsafe (*a).at_const(r0);
    if rn.kind == NodeKind::NODE_PARAMETER {
        return rn.as_data.parameter.ty;
    }
    return r0;
}

fn test_fn_returns_nothing(p: &loader::Package, am: ModuleId, src: *const char, fnode: NodeId) bool {
    let a = mod_ast_c(p, am);
    let rets = unsafe (*a).at_const(fnode).as_data.function.returns;
    if rets.len == 0 {
        return true;
    }
    let rn = test_fn_ret_node(p, am, fnode);
    if rn == NODE_NONE {
        return false;
    }
    let n = unsafe (*a).at_const(rn);
    if n.kind != NodeKind::NODE_IDENTIFIER {
        return false;
    }
    let t = n.as_data.name.text;
    if t.end - t.start != 4 {
        return false;
    }
    return unsafe cstring::memcmp(src + t.start as usize, "void".ptr(), 4) == 0;
}

// Classify one @test parameter: 1 = fixture/receiver, 2 = global env, 0 with an error emitted.
fn test_param_bit(p: &mut loader::Package, m: ModuleId, pnode: NodeId, fx: DefId, genv: DefId) u8 {
    let a = mod_ast_c(p, m);
    let sp = unsafe (*a).at_const(pnode).span;
    let tnode = unsafe (*a).at_const(pnode).as_data.parameter.ty;
    let tk = if tnode != NODE_NONE {
        unsafe (*a).at_const(tnode).kind;
    } else {
        NodeKind::NODE_NONE_KIND;
    };
    if tnode == NODE_NONE || tk != NodeKind::NODE_REFERENCE_TYPE {
        test_err(
            p,
            m,
            sp,
            "a '@test' parameter must be a reference to the module fixture or the global env".ptr() as *const char,
        );
        return 0;
    }
    let it = unsafe (*a).at_const(tnode).as_data.indirect_type;
    let mut is_enum = false;
    let d = test_type_decl(p, m, it.ty, (&mut is_enum) as *mut bool);
    if fx.node != NODE_NONE && d.module == fx.module && d.node == fx.node {
        return 1;
    }
    if genv.node != NODE_NONE && d.module == genv.module && d.node == genv.node {
        if it.qualifier == TypeQualifier::TYPE_QUAL_MUT {
            test_err(p, m, sp, "the global test env is shared: take it as '&', not '&mut'".ptr() as *const char);
            return 0;
        }
        return 2;
    }
    test_err(
        p,
        m,
        sp,
        "this parameter matches neither the module's '@test_init' fixture nor the global env".ptr() as *const char,
    );
    return 0;
}

// The inherent, non-generic extend whose items contain `fnode`, or NODE_NONE. `*bad` is set when it IS a
// method but of a conformance/generic extend (not suite-able).
fn test_owner_extend(p: &loader::Package, am: ModuleId, fnode: NodeId, bad: *mut bool) NodeId {
    let a = mod_ast_c(p, am);
    let items = unsafe (*a).at_const((*a).root).as_data.program.items;
    let ids = unsafe (*a).list(items);
    for i in 0..items.len {
        let iid = unsafe ids[i as usize];
        if unsafe (*a).at_const(iid).kind == NodeKind::NODE_EXTEND {
            let ed = unsafe (*a).at_const(iid).as_data.extend_def;
            let mids = unsafe (*a).list(ed.items);
            for j in 0..ed.items.len {
                if unsafe mids[j as usize] == fnode {
                    unsafe *bad = ed.interface_type != NODE_NONE || ed.generics.len != 0;
                    return iid;
                }
            }
        }
    }
    return NODE_NONE;
}

// Index of the (module, type) suite in plan.suites, creating it when `create`; -1 when absent / no-create.
fn plan_suite_of(plan: &mut TestPlan, m: ModuleId, ty: DefId, is_enum: bool, create: bool) i32 {
    for i in 0..plan.suites.len() {
        let s = plan.suites.at(i);
        if s.mod == m && s.ty.module == ty.module && s.ty.node == ty.node {
            return i as i32;
        }
    }
    if !create {
        return -1;
    }
    plan.suites.push(TestSuite { mod: m, ty: ty, is_enum: is_enum, init: NODE_NONE, fre: NODE_NONE });
    return (plan.suites.len() - 1) as i32;
}

// Collect + validate every @test/@test_init/@test_free in the package into a runnable plan.
pub fn test_plan_build(p: &mut loader::Package, plan: &mut TestPlan) void {
    let n = p.modules.len();
    // Pass 1: fixture producers/teardowns (module, suite, and global).
    for m in 0..n {
        if !p.modules[m].has_ast || p.modules[m].prelude {
            continue;
        }
        let src = p.modules[m].source.as_str().ptr() as *const char;
        let nattr = unsafe (*mod_ast_c(p, m as ModuleId)).attrs.len();
        for ai in 0..nattr {
            let at = unsafe (*mod_ast_c(p, m as ModuleId)).attrs[ai];
            if at.kind != AttrKind::ATTR_TEST_INIT as u8 && at.kind != AttrKind::ATTR_TEST_FREE as u8 {
                continue;
            }
            let sp = unsafe (*mod_ast_c(p, m as ModuleId)).at_const(at.owner).span;
            let mut bad_ext = false;
            let ext = test_owner_extend(p, m as ModuleId, at.owner, (&mut bad_ext) as *mut bool);
            if ext != NODE_NONE && bad_ext {
                test_err(
                    p,
                    m as ModuleId,
                    sp,
                    "test attributes are only allowed on methods of a non-generic inherent 'extend'".ptr() as *const char,
                );
                continue;
            }
            let mut target = DefId { module: 0, node: NODE_NONE };
            let mut target_is_enum = false;
            if ext != NODE_NONE {
                if at.arg != 0 {
                    test_err(
                        p,
                        m as ModuleId,
                        sp,
                        "'(global)' is not allowed on a method; declare the global pair at top level".ptr() as *const char,
                    );
                    continue;
                }
                let tt = unsafe (*mod_ast_c(p, m as ModuleId)).at_const(ext).as_data.extend_def.target_type;
                target = test_type_decl(p, m as ModuleId, tt, (&mut target_is_enum) as *mut bool);
                if target.node == NODE_NONE {
                    test_err(
                        p,
                        m as ModuleId,
                        sp,
                        "a test suite's extend target must be a plain (non-generic) struct or enum".ptr() as *const char,
                    );
                    continue;
                }
            }
            if at.kind == AttrKind::ATTR_TEST_INIT as u8 {
                let plen = unsafe (*mod_ast_c(p, m as ModuleId)).at_const(at.owner).as_data.function.params.len;
                if plen != 0 {
                    test_err(p, m as ModuleId, sp, "'@test_init' takes no parameters".ptr() as *const char);
                    continue;
                }
                let mut is_enum = false;
                let ret = test_fn_ret_node(p, m as ModuleId, at.owner);
                let d = test_type_decl(p, m as ModuleId, ret, (&mut is_enum) as *mut bool);
                if d.node == NODE_NONE {
                    test_err(
                        p,
                        m as ModuleId,
                        sp,
                        "'@test_init' must return a plain (non-generic) struct or enum fixture".ptr() as *const char,
                    );
                    continue;
                }
                if ext != NODE_NONE {
                    if d.module != target.module || d.node != target.node {
                        test_err(
                            p,
                            m as ModuleId,
                            sp,
                            "a suite '@test_init' method must return the extended type itself".ptr() as *const char,
                        );
                        continue;
                    }
                    let si = plan_suite_of(plan, m as ModuleId, target, target_is_enum, true);
                    if plan.suites[si as usize].init != NODE_NONE {
                        test_err(
                            p,
                            m as ModuleId,
                            sp,
                            "duplicate suite '@test_init' (one per type per module)".ptr() as *const char,
                        );
                        continue;
                    }
                    plan.suites[si as usize].init = at.owner;
                } else if at.arg != 0 {
                    if plan.genv_init != NODE_NONE {
                        test_err(
                            p,
                            m as ModuleId,
                            sp,
                            "duplicate '@test_init(global)' (one per test tree)".ptr() as *const char,
                        );
                        continue;
                    }
                    plan.genv_mod = m as ModuleId;
                    plan.genv_init = at.owner;
                    plan.genv_type = d;
                    plan.genv_is_enum = is_enum;
                } else {
                    if plan.fx_init[m] != NODE_NONE {
                        test_err(p, m as ModuleId, sp, "duplicate '@test_init' (one per module)".ptr() as *const char);
                        continue;
                    }
                    plan.fx_init[m] = at.owner;
                    plan.fx_type[m] = d;
                    plan.fx_is_enum[m] = is_enum;
                }
            } else {
                if ext == NODE_NONE {
                    continue;
                }
                let mut ok = false;
                let params = unsafe (*mod_ast_c(p, m as ModuleId)).at_const(at.owner).as_data.function.params;
                if params.len == 1 && test_fn_returns_nothing(p, m as ModuleId, src, at.owner) {
                    let p0 = unsafe (*mod_ast_c(p, m as ModuleId)).list(params)[0];
                    let pty = unsafe (*mod_ast_c(p, m as ModuleId)).at_const(p0).as_data.parameter.ty;
                    let ptk = if pty != NODE_NONE {
                        unsafe (*mod_ast_c(p, m as ModuleId)).at_const(pty).kind;
                    } else {
                        NodeKind::NODE_NONE_KIND;
                    };
                    if pty != NODE_NONE && ptk == NodeKind::NODE_REFERENCE_TYPE {
                        let it = unsafe (*mod_ast_c(p, m as ModuleId)).at_const(pty).as_data.indirect_type;
                        let mut ie = false;
                        let d = test_type_decl(p, m as ModuleId, it.ty, (&mut ie) as *mut bool);
                        ok = it.qualifier == TypeQualifier::TYPE_QUAL_MUT && d.module == target.module && d.node == target.node;
                    }
                }
                if !ok {
                    test_err(
                        p,
                        m as ModuleId,
                        sp,
                        "a suite '@test_free' must be 'fn(self: &mut <the extended type>)' returning nothing".ptr() as *const char,
                    );
                    continue;
                }
                let si = plan_suite_of(plan, m as ModuleId, target, target_is_enum, true);
                if plan.suites[si as usize].fre != NODE_NONE {
                    test_err(p, m as ModuleId, sp, "duplicate suite '@test_free'".ptr() as *const char);
                    continue;
                }
                plan.suites[si as usize].fre = at.owner;
            }
        }
    }
    // Top-level @test_free, after every init is known.
    for m in 0..n {
        if !p.modules[m].has_ast || p.modules[m].prelude {
            continue;
        }
        let src = p.modules[m].source.as_str().ptr() as *const char;
        let nattr = unsafe (*mod_ast_c(p, m as ModuleId)).attrs.len();
        for ai in 0..nattr {
            let at = unsafe (*mod_ast_c(p, m as ModuleId)).attrs[ai];
            if at.kind != AttrKind::ATTR_TEST_FREE as u8 {
                continue;
            }
            let mut be = false;
            if test_owner_extend(p, m as ModuleId, at.owner, (&mut be) as *mut bool) != NODE_NONE {
                continue;
            }
            let sp = unsafe (*mod_ast_c(p, m as ModuleId)).at_const(at.owner).span;
            let global = at.arg != 0;
            let want = if global {
                plan.genv_type;
            } else {
                plan.fx_type[m];
            };
            let has_init = if global {
                plan.genv_init;
            } else {
                plan.fx_init[m];
            };
            if has_init == NODE_NONE || global && plan.genv_mod != m as ModuleId {
                test_err(
                    p,
                    m as ModuleId,
                    sp,
                    if global {
                        "'@test_free(global)' has no matching '@test_init(global)' in this module".ptr() as *const char;
                    } else {
                        "'@test_free' has no matching '@test_init' in this module".ptr() as *const char;
                    },
                );
                continue;
            }
            let mut ok = false;
            let params = unsafe (*mod_ast_c(p, m as ModuleId)).at_const(at.owner).as_data.function.params;
            if params.len == 1 && test_fn_returns_nothing(p, m as ModuleId, src, at.owner) {
                let p0 = unsafe (*mod_ast_c(p, m as ModuleId)).list(params)[0];
                let pty = unsafe (*mod_ast_c(p, m as ModuleId)).at_const(p0).as_data.parameter.ty;
                let ptk = if pty != NODE_NONE {
                    unsafe (*mod_ast_c(p, m as ModuleId)).at_const(pty).kind;
                } else {
                    NodeKind::NODE_NONE_KIND;
                };
                if pty != NODE_NONE && ptk == NodeKind::NODE_REFERENCE_TYPE {
                    let it = unsafe (*mod_ast_c(p, m as ModuleId)).at_const(pty).as_data.indirect_type;
                    let mut ie = false;
                    let d = test_type_decl(p, m as ModuleId, it.ty, (&mut ie) as *mut bool);
                    ok = it.qualifier == TypeQualifier::TYPE_QUAL_MUT && d.module == want.module && d.node == want.node;
                }
            }
            if !ok {
                test_err(
                    p,
                    m as ModuleId,
                    sp,
                    if global {
                        "'@test_free(global)' must be 'fn(&mut <fixture>)' returning nothing".ptr() as *const char;
                    } else {
                        "'@test_free' must be 'fn(&mut <fixture>)' returning nothing".ptr() as *const char;
                    },
                );
                continue;
            }
            if global {
                if plan.genv_free != NODE_NONE {
                    test_err(p, m as ModuleId, sp, "duplicate '@test_free(global)'".ptr() as *const char);
                    continue;
                }
                plan.genv_free = at.owner;
            } else {
                if plan.fx_free[m] != NODE_NONE {
                    test_err(p, m as ModuleId, sp, "duplicate '@test_free' (one per module)".ptr() as *const char);
                    continue;
                }
                plan.fx_free[m] = at.owner;
            }
        }
    }
    // A suite teardown without a producer is an error.
    for si in 0..plan.suites.len() {
        let s = plan.suites[si];
        if s.init == NODE_NONE && s.fre != NODE_NONE {
            let sp = unsafe (*mod_ast_c(p, s.mod)).at_const(s.fre).span;
            test_err(
                p,
                s.mod,
                sp,
                "a suite '@test_free' has no matching '@test_init' method on this type in this module".ptr() as *const char,
            );
        }
    }
    // Pass 2: the tests themselves.
    for m in 0..n {
        if !p.modules[m].has_ast || p.modules[m].prelude {
            continue;
        }
        let src = p.modules[m].source.as_str().ptr() as *const char;
        let nattr = unsafe (*mod_ast_c(p, m as ModuleId)).attrs.len();
        for ai in 0..nattr {
            let at = unsafe (*mod_ast_c(p, m as ModuleId)).attrs[ai];
            if at.kind != AttrKind::ATTR_TEST as u8 {
                continue;
            }
            let sp = unsafe (*mod_ast_c(p, m as ModuleId)).at_const(at.owner).span;
            let mut bad_ext = false;
            let ext = test_owner_extend(p, m as ModuleId, at.owner, (&mut bad_ext) as *mut bool);
            if ext != NODE_NONE && bad_ext {
                test_err(
                    p,
                    m as ModuleId,
                    sp,
                    "test attributes are only allowed on methods of a non-generic inherent 'extend'".ptr() as *const char,
                );
                continue;
            }
            let mut suite = DefId { module: 0, node: NODE_NONE };
            let mut suite_is_enum = false;
            if ext != NODE_NONE {
                let tt = unsafe (*mod_ast_c(p, m as ModuleId)).at_const(ext).as_data.extend_def.target_type;
                suite = test_type_decl(p, m as ModuleId, tt, (&mut suite_is_enum) as *mut bool);
                if suite.node == NODE_NONE {
                    test_err(
                        p,
                        m as ModuleId,
                        sp,
                        "a test suite's extend target must be a plain (non-generic) struct or enum".ptr() as *const char,
                    );
                    continue;
                }
            }
            if !test_fn_returns_nothing(p, m as ModuleId, src, at.owner) {
                test_err(p, m as ModuleId, sp, "a '@test' function returns nothing".ptr() as *const char);
                continue;
            }
            let nmnode = unsafe (*mod_ast_c(p, m as ModuleId)).at_const(at.owner).as_data.function.name;
            let nmsp = unsafe (*mod_ast_c(p, m as ModuleId)).at_const(nmnode).as_data.name.text;
            if ext == NODE_NONE && nmsp.end - nmsp.start == 4 && unsafe cstring::memcmp(
                src + nmsp.start as usize,
                "main".ptr(),
                4,
            ) == 0 {
                test_err(
                    p,
                    m as ModuleId,
                    sp,
                    "'main' cannot be a '@test' (it is replaced by the test runner)".ptr() as *const char,
                );
                continue;
            }
            let params = unsafe (*mod_ast_c(p, m as ModuleId)).at_const(at.owner).as_data.function.params;
            if params.len > 2 {
                test_err(
                    p,
                    m as ModuleId,
                    sp,
                    "a '@test' function takes at most the fixture (or 'self') and the global env".ptr() as *const char,
                );
                continue;
            }
            let fx = if ext != NODE_NONE {
                suite;
            } else {
                plan.fx_type[m];
            };
            let genv_ty = if plan.genv_init != NODE_NONE {
                plan.genv_type;
            } else {
                DefId { module: 0, node: NODE_NONE };
            };
            let mut wants: u8 = 0;
            let mut bad = false;
            let mut k: u32 = 0;
            while k < params.len && !bad {
                let pid = unsafe (*mod_ast_c(p, m as ModuleId)).list(params)[k as usize];
                let bit = test_param_bit(p, m as ModuleId, pid, fx, genv_ty);
                if bit == 0 {
                    bad = true;
                } else if (wants & bit) != 0 {
                    test_err(p, m as ModuleId, sp, "duplicate '@test' parameter kind".ptr() as *const char);
                    bad = true;
                } else if bit == 1 && (wants & 2) != 0 {
                    test_err(
                        p,
                        m as ModuleId,
                        sp,
                        "the fixture ('self') parameter must come before the global env".ptr() as *const char,
                    );
                    bad = true;
                }
                wants = wants | bit;
                k = k + 1;
            }
            if bad {
                continue;
            }
            let mut suite_init = NODE_NONE;
            let mut suite_free = NODE_NONE;
            if ext != NODE_NONE && (wants & 1) != 0 {
                let si2 = plan_suite_of(plan, m as ModuleId, suite, suite_is_enum, false);
                if si2 < 0 || plan.suites[si2 as usize].init == NODE_NONE {
                    test_err(
                        p,
                        m as ModuleId,
                        sp,
                        "no '@test_init' method on this type in this module produces the receiver".ptr() as *const char,
                    );
                    continue;
                }
                suite_init = plan.suites[si2 as usize].init;
                suite_free = plan.suites[si2 as usize].fre;
            }
            let case_suite = if ext != NODE_NONE && (wants & 1) != 0 {
                suite;
            } else {
                DefId { module: 0, node: NODE_NONE };
            };
            plan.cases.push(
                TestCase {
                    mod: m as ModuleId,
                    func: at.owner,
                    should_panic: at.arg != 0,
                    wants: wants,
                    suite: case_suite,
                    suite_is_enum: suite_is_enum,
                    suite_init: suite_init,
                    suite_free: suite_free,
                },
            );
        }
    }
    let pok = p.ok;
    plan.ok = plan.ok && pok;
}

// The fixed part of the generated test runner: option parsing, fork-per-test isolation with a waitpid job
// pool, an in-process fallback (--no-fork), substring selection, per-test reporting, and the exit code.
// Platform-specific headers the generated test runner needs. POSIX forks + reaps (unistd/sys/wait);
// Windows spawns one subprocess per test (process.h/_spawnv, stdint.h/intptr_t).
@platform(!windows)
fn test_runner_includes() *const char {
    return "#include <unistd.h>\n#include <sys/wait.h>\n\n".ptr() as *const char;
}
@platform(windows)
fn test_runner_includes() *const char {
    return "#include <process.h>\n#include <stdint.h>\n\n".ptr() as *const char;
}

@platform(!windows)
fn test_runner_main() *const char {
    return r#"static int sc_match(const char *name, const char *filter) {
  return !filter || strstr(name, filter) != NULL;
}
int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0); /* forked children must not inherit (and re-flush) buffered lines */
  int jobs = 0, no_fork = 0;
  const char *filter = NULL;
  for (int i = 1; i < argc; i++) {
    if (!strncmp(argv[i], "--jobs=", 7)) jobs = atoi(argv[i] + 7);
    else if (!strcmp(argv[i], "--no-fork")) no_fork = 1;
    else if (!strncmp(argv[i], "--filter=", 9)) filter = argv[i] + 9;
  }
  if (jobs < 1) { long n = sysconf(_SC_NPROCESSORS_ONLN); jobs = n > 0 ? (int)n : 1; }
  int sel[SC_NTESTS > 0 ? SC_NTESTS : 1];
  int nsel = 0;
  for (int i = 0; i < SC_NTESTS; i++)
    if (sc_match(SC_TESTS[i].name, filter)) sel[nsel++] = i;
  printf("running %d test%s\n", nsel, nsel == 1 ? "" : "s");
  void *genv = NULL;
  if (nsel > 0) genv = sc_genv_init();
  int passed = 0, failed = 0, skipped = 0;
  if (no_fork) {
    for (int k = 0; k < nsel; k++) {
      const int i = sel[k];
      if (SC_TESTS[i].should_panic) {
        printf("test %s ... skipped (should_panic needs fork)\n", SC_TESTS[i].name);
        skipped++;
        continue;
      }
      SC_TESTS[i].fn(genv);
      printf("test %s ... ok\n", SC_TESTS[i].name);
      passed++;
    }
  } else {
    pid_t pid_of[SC_NTESTS > 0 ? SC_NTESTS : 1];
    int active = 0, next = 0;
    while (next < nsel || active > 0) {
      while (active < jobs && next < nsel) {
        const pid_t pid = fork();
        if (pid == 0) { SC_TESTS[sel[next]].fn(genv); _exit(0); }
        if (pid < 0) { perror("fork"); return 101; }
        pid_of[next++] = pid;
        active++;
      }
      int st = 0;
      const pid_t done = wait(&st);
      if (done < 0) break;
      active--;
      int ti = -1;
      for (int k = 0; k < next; k++)
        if (pid_of[k] == done) { ti = sel[k]; pid_of[k] = -1; break; }
      if (ti < 0) continue;
      const int crashed = !(WIFEXITED(st) && WEXITSTATUS(st) == 0);
      if (crashed == SC_TESTS[ti].should_panic) {
        printf("test %s ... ok%s\n", SC_TESTS[ti].name, SC_TESTS[ti].should_panic ? " (panicked as expected)" : "");
        passed++;
      } else {
        printf("test %s ... FAILED%s\n", SC_TESTS[ti].name, SC_TESTS[ti].should_panic ? " (expected a panic)" : "");
        failed++;
      }
      fflush(stdout);
    }
  }
  if (genv) sc_genv_free(genv);
  if (skipped)
    printf("\n%d passed, %d failed, %d skipped\n", passed, failed, skipped);
  else
    printf("\n%d passed, %d failed\n", passed, failed);
  return failed > 100 ? 100 : failed;
}
"#.ptr() as *const char;
}

// Windows has no fork(); isolate each test in its own subprocess (`self --run-one=<i>`) so should_panic
// and crashing tests are caught via the child's exit code. Serial (no job pool); @test_init(global) reruns
// per test (fresh process) rather than once — same isolation, minor repeated setup.
@platform(windows)
fn test_runner_main() *const char {
    return r#"static int sc_match(const char *name, const char *filter) {
  return !filter || strstr(name, filter) != NULL;
}
int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0);
  const char *filter = NULL;
  int run_one = -1;
  for (int i = 1; i < argc; i++) {
    if (!strncmp(argv[i], "--run-one=", 10)) run_one = atoi(argv[i] + 10);
    else if (!strncmp(argv[i], "--filter=", 9)) filter = argv[i] + 9;
    /* --jobs / --no-fork accepted for CLI parity; Windows always runs serial subprocesses */
  }
  if (run_one >= 0) { /* child: run exactly one test in-process, exit status reports crash/panic */
    void *genv = sc_genv_init();
    SC_TESTS[run_one].fn(genv);
    if (genv) sc_genv_free(genv);
    return 0;
  }
  int sel[SC_NTESTS > 0 ? SC_NTESTS : 1];
  int nsel = 0;
  for (int i = 0; i < SC_NTESTS; i++)
    if (sc_match(SC_TESTS[i].name, filter)) sel[nsel++] = i;
  printf("running %d test%s\n", nsel, nsel == 1 ? "" : "s");
  int passed = 0, failed = 0;
  for (int k = 0; k < nsel; k++) {
    const int i = sel[k];
    char idbuf[24];
    snprintf(idbuf, sizeof idbuf, "--run-one=%d", i);
    const char *const args[] = { argv[0], idbuf, NULL };
    const intptr_t rc = _spawnv(_P_WAIT, argv[0], args);
    const int crashed = (rc != 0);
    if (crashed == SC_TESTS[i].should_panic) {
      printf("test %s ... ok%s\n", SC_TESTS[i].name, SC_TESTS[i].should_panic ? " (panicked as expected)" : "");
      passed++;
    } else if (SC_TESTS[i].should_panic) {
      printf("test %s ... FAILED (expected a panic)\n", SC_TESTS[i].name);
      failed++;
    } else {
      printf("test %s ... FAILED\n", SC_TESTS[i].name);
      failed++;
    }
    fflush(stdout);
  }
  printf("\n%d passed, %d failed\n", passed, failed);
  return failed > 100 ? 100 : failed;
}
"#.ptr() as *const char;
}

// Write build/__test_main.c: extern wrapper prototypes, the test table (display names `module::fn` or
// `module::Type::method`), the global-env hooks (stubs when absent), and the fixed runner. Returns the
// path (ownership to the caller / keep-list), or null.
pub fn write_test_main(p: &mut loader::Package, plan: &TestPlan) Option<String> {
    let mut path = build_out_path(p.root_dir.as_str(), "__test_main", ".c");
    let f = open_out(path.as_str());
    if f == null {
        unsafe stdio::perror(path.cstr());
        return Option::<String>::None;
    }
    unsafe stdio::fputs(
        "/* generated by super-c --test */\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n".ptr() as *const char,
        f,
    );
    unsafe stdio::fputs(test_runner_includes(), f);
    for ci in 0..plan.cases.len() {
        let tc = plan.cases[ci];
        unsafe stdio::fprintf(
            f,
            "extern void __sc_test_w_%u_%u(void *);\n".ptr() as *const char,
            tc.mod as u32,
            tc.func,
        );
    }
    unsafe stdio::fputs(
        "\ntypedef void (*sc_test_fn)(void *);\nstatic const struct { const char *name; sc_test_fn fn; int should_panic; } SC_TESTS[] = {\n".ptr() as *const char,
        f,
    );
    for ci in 0..plan.cases.len() {
        let tc = plan.cases[ci];
        let a = mod_ast_c(p, tc.mod);
        let nmnode = unsafe (*a).at_const(tc.func).as_data.function.name;
        let nm = unsafe (*a).at_const(nmnode).as_data.name.text;
        let modpath = p.modules[tc.mod as usize].path.as_str();
        let msrc = p.modules[tc.mod as usize].source.as_str().ptr() as *const char;
        unsafe stdio::fprintf(f, "  { \"%.*s::".ptr() as *const char, modpath.len() as i32, modpath.ptr());
        if tc.suite.node != NODE_NONE {
            let sa = mod_ast_c(p, tc.suite.module);
            let snmn = unsafe (*sa).at_const(tc.suite.node).as_data.aggregate.name;
            let snm = unsafe (*sa).at_const(snmn).as_data.name.text;
            let ssrc = p.modules[tc.suite.module as usize].source.as_str().ptr() as *const char;
            unsafe stdio::fprintf(
                f,
                "%.*s::".ptr() as *const char,
                (snm.end - snm.start) as i32,
                unsafe (ssrc + snm.start as usize),
            );
        }
        let spflag = if tc.should_panic {
            1 as i32;
        } else {
            0 as i32;
        };
        unsafe stdio::fprintf(
            f,
            "%.*s\", __sc_test_w_%u_%u, %d },\n".ptr() as *const char,
            (nm.end - nm.start) as i32,
            unsafe (msrc + nm.start as usize),
            tc.mod as u32,
            tc.func,
            spflag,
        );
    }
    unsafe stdio::fprintf(f, "};\nenum { SC_NTESTS = %zu };\n\n".ptr() as *const char, plan.cases.len());
    if plan.genv_init != NODE_NONE {
        unsafe stdio::fputs(
            "extern void *__sc_test_genv_init(void);\nextern void __sc_test_genv_free(void *);\nstatic void *sc_genv_init(void) { return __sc_test_genv_init(); }\nstatic void sc_genv_free(void *p) { __sc_test_genv_free(p); }\n\n".ptr() as *const char,
            f,
        );
    } else {
        unsafe stdio::fputs(
            "static void *sc_genv_init(void) { return NULL; }\nstatic void sc_genv_free(void *p) { (void)p; }\n\n".ptr() as *const char,
            f,
        );
    }
    unsafe stdio::fputs(test_runner_main(), f);
    unsafe stdio::fclose(f);
    return Option::<String>::Some(path);
}

// Compile the emitted build tree with $CC. When `out_bin` is set (the `build` subcommand) the program is
// linked to that path and we return; otherwise it links `<root>/build/__tests` and runs it as the test
// runner, forwarding `topts`' options.
pub fn test_build_and_run(p: &loader::Package, topts: *const TestOpts, keep: &Vector<String>, out_bin: str) i32 {
    let mut cc = stdlib::getenv("CC");
    if cc == null || unsafe *cc == 0 as char {
        cc = "cc".ptr() as *const char;
    }
    let root = p.root_dir.as_str();
    let mut cmd = String::new();
    cmd.push_str(str::from_cstr(cc));
    if out_bin.len() != 0 {
        cmd.push_str(" -std=c11 -o '");
        cmd.push_str(out_bin);
        cmd.push_str("'");
    } else {
        cmd.push_str(" -std=c11 -o '");
        cmd.push_str(root);
        cmd.push_str("/build/__tests'");
    }
    for i in 0..keep.len() {
        let cf = keep[i].as_str();
        if cf.len() > 2 && cf.ends_with(".c") {
            cmd.push_str(" '");
            cmd.push_str(cf);
            cmd.push_str("'");
        }
    }
    // @c.link flags (one per line in build/__ldflags)
    let ldpath = build_out_path(root, "__ldflags", "");
    let lf = stdio::fopen(ldpath.as_str(), "rb");
    if lf != null {
        let mut line = PathBuf {};
        while unsafe stdio::fgets(&mut line[0], 4096, lf) != null {
            let ll = unsafe cstring::strlen(&line[0]);
            if ll > 0 && unsafe line[ll - 1] == '\n' as char {
                unsafe line[ll - 1] = 0 as char;
            }
            if unsafe line[0] != 0 as char {
                cmd.push_str(" ");
                cmd.push_str(str::from_cstr(&line[0]));
            }
        }
        unsafe stdio::fclose(lf);
    }
    let brc = stdlib::system(cmd.as_str());
    if brc != 0 {
        let mut what = "test build".ptr() as *const char;
        if out_bin.len() != 0 {
            what = "build".ptr() as *const char;
        }
        unsafe stdio::fprintf(stdio::stderr(), "super-c: %s failed (%s)\n".ptr() as *const char, what, cc);
        return 1;
    }
    if out_bin.len() != 0 {
        return 0;
    } // the `build` subcommand: linked the program, nothing to run
    let mut run = String::new();
    run.push_str("'");
    run.push_str(root);
    run.push_str("/build/__tests'");
    if unsafe (*topts).jobs > 0 {
        let mut jb = Buf64 {};
        unsafe stdio::snprintf(&mut jb[0], 64, " --jobs=%d".ptr() as *const char, unsafe (*topts).jobs);
        run.push_str(str::from_cstr(&jb[0]));
    }
    if unsafe (*topts).no_fork {
        run.push_str(" --no-fork");
    }
    if unsafe (*topts).filter != null {
        run.push_str(" '--filter=");
        run.push_str(str::from_cstr(unsafe (*topts).filter));
        run.push_str("'");
    }
    let rrc = stdlib::system(run.as_str());
    if rrc < 0 {
        return 1;
    }
    if unsafe shim::sc_wifexited(rrc) != 0 {
        return unsafe shim::sc_wexitstatus(rrc);
    }
    return 1;
}

// One module's test-plan slice, kept alive across codegen_emit (CgTestInfo holds a pointer into it).
