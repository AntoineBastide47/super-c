// The --test pipeline: collects every @test/@test_init/@test_free into a validated TestPlan (consumed by
// codegen's per-module wrapper emission), synthesizes the fork-per-test runner TU (build/__test_main.c),
// and compiles + runs the emitted build tree with $CC. test_build_and_run doubles as the `build`
// subcommand's link step when `out_bin` is set.
import stdio;
import stdlib;
import string as cstring;
import lexer::token as tok;
import lexer::lexer as lex;
import ast::ast as *;
import ast::parser as par;
import fmt::builder as fbld;
import driver_shim as shim;
import module::loader as loader;
import resolver::resolver as resolver;
import typechecker::typechecker as tc;
import utils::errors as diag;
import driver::util as *;

/// --test run options, forwarded to the generated runner.
pub struct TestOpts {
    pub enabled: bool,
    pub jobs: i32,
    pub no_fork: bool,
    pub quiet: bool,
    pub filter: *const char,
    pub shard: i32,
    pub shards: i32,
}
/// One runnable @test. `wants` is a bitmask of the wrapper's arguments: 1 = fixture/receiver param,
/// 2 = global-env param. The suite fields are set only for suite-method tests taking `self`.
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
/// A per-(module, extended type) suite: its '@test_init' producer and optional '@test_free' teardown.
pub struct TestSuite {
    pub mod: ModuleId,
    pub ty: DefId,
    pub is_enum: bool,
    pub init: NodeId,
    pub fre: NodeId,
}
/// The package-wide plan: all cases, the per-module fixture tables (indexed by ModuleId), the suites, and
/// the at-most-one global env pair. `ok` goes false when any validation error was reported.
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
// A test-plan validation error, rendered with the compiler's usual source excerpt.
fn test_err(p: &mut loader::Package, m: ModuleId, sp: tok::Span, msg: *const char) {
    let src = p.modules[m as usize].source.as_str();
    let file = p.modules[m as usize].file.as_str();
    let mut errs = diag::Errors::new();
    errs.emit(sp.start, sp.end - sp.start, String::from_cstr(msg));
    errs.finalize(src, file);
    errs.log();
    p.ok = false;
}

// The plain struct/enum decl a type NODE names, or {0, NODE_NONE} (fixtures must be nominal + non-generic).
const fn test_type_decl(p: &loader::Package, am: ModuleId, tnode: NodeId, is_enum: &mut bool) DefId {
    let none = DefId { module: 0, node: NODE_NONE };
    if tnode == NODE_NONE {
        return none;
    }
    let a = p.module_ast_const(am);
    let tk = a.at_const(tnode).kind;
    if tk != NodeKind::NODE_TYPE_PATH && tk != NodeKind::NODE_IDENTIFIER {
        return none;
    }
    let d = a.resolution_def(tnode);
    if d.node == NODE_NONE || d.module as usize >= p.modules.len() {
        return none;
    }
    let da = p.module_ast_const(d.module);
    let dk = da.at_const(d.node).kind;
    let gen = da.at_const(d.node).as_data.aggregate.generics;
    if dk != NodeKind::NODE_STRUCT && dk != NodeKind::NODE_ENUM || gen.len != 0 {
        return none;
    }
    *is_enum = dk == NodeKind::NODE_ENUM;
    return d;
}

// A function's single return type node (unwrapping a named return), or NODE_NONE.
const fn test_fn_ret_node(p: &loader::Package, am: ModuleId, fnode: NodeId) NodeId {
    let a = p.module_ast_const(am);
    let rets = a.at_const(fnode).as_data.function.returns;
    if rets.len != 1 {
        return NODE_NONE;
    }
    let r0 = unsafe a.list(rets)[0];
    let rn = a.at_const(r0);
    if rn.kind == NodeKind::NODE_PARAMETER {
        return rn.as_data.parameter.ty;
    }
    return r0;
}

const fn test_fn_returns_nothing(p: &loader::Package, am: ModuleId, src: *const char, fnode: NodeId) bool {
    let a = p.module_ast_const(am);
    let rets = a.at_const(fnode).as_data.function.returns;
    if rets.len == 0 {
        return true;
    }
    let rn = test_fn_ret_node(p, am, fnode);
    if rn == NODE_NONE {
        return false;
    }
    let n = a.at_const(rn);
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
    let a = p.module_ast_const(m);
    let sp = a.at_const(pnode).span;
    let tnode = a.at_const(pnode).as_data.parameter.ty;
    let tk = if tnode != NODE_NONE {
        a.at_const(tnode).kind;
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
    let it = a.at_const(tnode).as_data.indirect_type;
    let mut is_enum = false;
    let d = test_type_decl(p, m, it.ty, &mut is_enum);
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
fn test_owner_extend(p: &loader::Package, am: ModuleId, fnode: NodeId, bad: &mut bool) NodeId {
    let a = p.module_ast_const(am);
    let items = unsafe a.at_const(a.root).as_data.program.items;
    let ids = a.list(items);
    for i in 0..items.len {
        let iid = unsafe ids[i as usize];
        if a.at_const(iid).kind == NodeKind::NODE_EXTEND {
            let ed = a.at_const(iid).as_data.extend_def;
            let mids = a.list(ed.items);
            for j in 0..ed.items.len {
                if unsafe mids[j as usize] == fnode {
                    *bad = ed.interface_type != NODE_NONE || ed.generics.len != 0;
                    return iid;
                }
            }
        }
    }
    return NODE_NONE;
}

/// Collect + validate every @test/@test_init/@test_free in the package into a runnable plan.
pub fn test_plan_build(p: &mut loader::Package, plan: &mut TestPlan) {
    let n = p.modules.len();
    // Pass 1: fixture producers/teardowns (module, suite, and global).
    for m in 0..n {
        if !p.modules[m].has_ast || p.modules[m].prelude {
            continue;
        }
        let src = p.modules[m].source.as_str().ptr() as *const char;
        let nattr = unsafe p.module_ast_const(m as ModuleId).attrs.len();
        for ai in 0..nattr {
            let at = unsafe p.module_ast_const(m as ModuleId).attrs[ai];
            if at.kind != AttrKind::ATTR_TEST_INIT as u8 && at.kind != AttrKind::ATTR_TEST_FREE as u8 {
                continue;
            }
            let sp = p.module_ast_const(m as ModuleId).at_const(at.owner).span;
            let mut bad_ext = false;
            let ext = test_owner_extend(p, m as ModuleId, at.owner, &mut bad_ext);
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
                let tt = p.module_ast_const(m as ModuleId).at_const(ext).as_data.extend_def.target_type;
                target = test_type_decl(p, m as ModuleId, tt, &mut target_is_enum);
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
                let plen = p.module_ast_const(m as ModuleId).at_const(at.owner).as_data.function.params.len;
                if plen != 0 {
                    test_err(p, m as ModuleId, sp, "'@test_init' takes no parameters".ptr() as *const char);
                    continue;
                }
                let mut is_enum = false;
                let ret = test_fn_ret_node(p, m as ModuleId, at.owner);
                let d = test_type_decl(p, m as ModuleId, ret, &mut is_enum);
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
                    let si = plan.suite_of(m as ModuleId, target, target_is_enum, true);
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
                let params = p.module_ast_const(m as ModuleId).at_const(at.owner).as_data.function.params;
                if params.len == 1 && test_fn_returns_nothing(p, m as ModuleId, src, at.owner) {
                    let p0 = unsafe p.module_ast_const(m as ModuleId).list(params)[0];
                    let pty = p.module_ast_const(m as ModuleId).at_const(p0).as_data.parameter.ty;
                    let ptk = if pty != NODE_NONE {
                        p.module_ast_const(m as ModuleId).at_const(pty).kind;
                    } else {
                        NodeKind::NODE_NONE_KIND;
                    };
                    if pty != NODE_NONE && ptk == NodeKind::NODE_REFERENCE_TYPE {
                        let it = p.module_ast_const(m as ModuleId).at_const(pty).as_data.indirect_type;
                        let mut ie = false;
                        let d = test_type_decl(p, m as ModuleId, it.ty, &mut ie);
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
                let si = plan.suite_of(m as ModuleId, target, target_is_enum, true);
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
        let nattr = unsafe p.module_ast_const(m as ModuleId).attrs.len();
        for ai in 0..nattr {
            let at = unsafe p.module_ast_const(m as ModuleId).attrs[ai];
            if at.kind != AttrKind::ATTR_TEST_FREE as u8 {
                continue;
            }
            let mut be = false;
            if test_owner_extend(p, m as ModuleId, at.owner, &mut be) != NODE_NONE {
                continue;
            }
            let sp = p.module_ast_const(m as ModuleId).at_const(at.owner).span;
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
            let params = p.module_ast_const(m as ModuleId).at_const(at.owner).as_data.function.params;
            if params.len == 1 && test_fn_returns_nothing(p, m as ModuleId, src, at.owner) {
                let p0 = unsafe p.module_ast_const(m as ModuleId).list(params)[0];
                let pty = p.module_ast_const(m as ModuleId).at_const(p0).as_data.parameter.ty;
                let ptk = if pty != NODE_NONE {
                    p.module_ast_const(m as ModuleId).at_const(pty).kind;
                } else {
                    NodeKind::NODE_NONE_KIND;
                };
                if pty != NODE_NONE && ptk == NodeKind::NODE_REFERENCE_TYPE {
                    let it = p.module_ast_const(m as ModuleId).at_const(pty).as_data.indirect_type;
                    let mut ie = false;
                    let d = test_type_decl(p, m as ModuleId, it.ty, &mut ie);
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
            let sp = p.module_ast_const(s.mod).at_const(s.fre).span;
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
        let nattr = unsafe p.module_ast_const(m as ModuleId).attrs.len();
        for ai in 0..nattr {
            let at = unsafe p.module_ast_const(m as ModuleId).attrs[ai];
            if at.kind != AttrKind::ATTR_TEST as u8 {
                continue;
            }
            let sp = p.module_ast_const(m as ModuleId).at_const(at.owner).span;
            let mut bad_ext = false;
            let ext = test_owner_extend(p, m as ModuleId, at.owner, &mut bad_ext);
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
                let tt = p.module_ast_const(m as ModuleId).at_const(ext).as_data.extend_def.target_type;
                suite = test_type_decl(p, m as ModuleId, tt, &mut suite_is_enum);
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
            let nmnode = p.module_ast_const(m as ModuleId).at_const(at.owner).as_data.function.name;
            let nmsp = p.module_ast_const(m as ModuleId).at_const(nmnode).as_data.name.text;
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
            let params = p.module_ast_const(m as ModuleId).at_const(at.owner).as_data.function.params;
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
                let pid = unsafe p.module_ast_const(m as ModuleId).list(params)[k as usize];
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
                let si2 = plan.suite_of(m as ModuleId, suite, suite_is_enum, false);
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

// Headers the generated test runner needs: POSIX forks + reaps (unistd/sys/wait), Windows spawns a pool of
// subprocesses (process.h/_spawnv, stdint.h/intptr_t, windows.h to wait on their handles). Chosen by the C
// preprocessor rather than by `@platform`, because this text is compiled for the TARGET, which is not
// necessarily the platform this compiler is running on. It also keeps both runners in every build, so
// neither can rot unnoticed.
const fn test_runner_includes() *const char {
    return M"(void sc_lk_fork_child_reset(void);
void sc_lk_report_now(void);
#ifdef _WIN32
#include <direct.h>
#include <io.h>
#include <process.h>
#include <stdint.h>
#include <windows.h>
static HANDLE sc_runner_js;
static int sc_runner_jobserver_active(void) {
  if (sc_runner_js != NULL) return 1;
  const char *name = getenv("SC_JOBSERVER_SEMAPHORE");
  if (name == NULL || name[0] == '\0') return 0;
  sc_runner_js = OpenSemaphoreA(SEMAPHORE_MODIFY_STATE | SYNCHRONIZE, FALSE, name);
  return sc_runner_js != NULL;
}
static int sc_runner_jobserver_try_acquire(void) {
  return sc_runner_jobserver_active() && WaitForSingleObject(sc_runner_js, 0) == WAIT_OBJECT_0;
}
static int sc_runner_jobserver_release(void) {
  return sc_runner_jobserver_active() && ReleaseSemaphore(sc_runner_js, 1, NULL);
}
#else
#include <fcntl.h>
#include <unistd.h>
#include <sys/wait.h>
static int sc_runner_js_read = -1;
static int sc_runner_js_write = -1;
static int sc_runner_jobserver_active(void) {
  if (sc_runner_js_read >= 0 && sc_runner_js_write >= 0) return 1;
  const char *fds = getenv("SC_JOBSERVER_FDS");
  int r = -1;
  int w = -1;
  char tail = 0;
  if (fds == NULL || sscanf(fds, "%d,%d%c", &r, &w, &tail) != 2 || r < 0 || w < 0) return 0;
  if (fcntl(r, F_GETFL) < 0 || fcntl(w, F_GETFL) < 0) return 0;
  sc_runner_js_read = r;
  sc_runner_js_write = w;
  return 1;
}
static int sc_runner_jobserver_try_acquire(void) {
  char token = 0;
  return sc_runner_jobserver_active() && read(sc_runner_js_read, &token, 1) == 1;
}
static int sc_runner_jobserver_release(void) {
  const char token = '+';
  return sc_runner_jobserver_active() && write(sc_runner_js_write, &token, 1) == 1;
}
#endif

)".ptr() as *const char;
}

// The fixed part of the generated test runner: option parsing, fork-per-test isolation with a waitpid job
// pool bounded by the inherited process-tree jobserver, an in-process fallback (--no-fork), substring
// selection, per-test reporting, and the exit code.
// Each forked child writes to its own capture file, so a test's output is attributed to that test rather
// than interleaved with the pool's. The captured text is replayed only for tests that fail, in a
// `failures:` section after the run; `--quiet` also drops the per-test `ok` lines.
const fn test_runner_main_posix() *const char {
    return M"(static int sc_match(const char *name, const char *filter) {
  return !filter || strstr(name, filter) != NULL;
}
static char *sc_strdup(const char *s) {
  char *d = malloc(strlen(s) + 1);
  if (!d) { perror("malloc"); exit(101); }
  strcpy(d, s);
  return d;
}
/* The in-process leg has no per-test process, so it restores the environment itself: tests set
   compiler switches (SC_INLINE, SC_BCE, ...) and rely on the fork for isolation. */
extern char **environ;
static char *sc_getcwd_alloc(void) {
  char *d = getcwd(NULL, 0);
  if (!d) { perror("getcwd"); exit(101); }
  return d;
}
static int sc_chdir_back(const char *d) { return chdir(d); }
static char **sc_env_snapshot(void) {
  int n = 0;
  while (environ[n]) n++;
  char **snap = malloc(((size_t)n + 1) * sizeof *snap);
  if (!snap) { perror("malloc"); exit(101); }
  for (int i = 0; i < n; i++) snap[i] = sc_strdup(environ[i]);
  snap[n] = NULL;
  return snap;
}
static void sc_env_restore(char **snap) {
  /* unsetenv compacts environ, so the index only advances past kept entries */
  for (int i = 0; environ[i];) {
    const char *eq = strchr(environ[i], '=');
    const size_t nl = eq ? (size_t)(eq - environ[i]) : strlen(environ[i]);
    int keep = 0;
    for (int k = 0; snap[k] && !keep; k++) keep = !strncmp(snap[k], environ[i], nl) && snap[k][nl] == '=';
    if (keep) { i++; continue; }
    char *name = sc_strdup(environ[i]);
    name[nl] = 0;
    unsetenv(name);
    free(name);
  }
  for (int k = 0; snap[k]; k++) {
    char *eq = strchr(snap[k], '=');
    if (eq) {
      *eq = 0;
      const char *cur = getenv(snap[k]);
      if (!cur || strcmp(cur, eq + 1)) setenv(snap[k], eq + 1, 1);
    }
    free(snap[k]);
  }
  free(snap);
}
/* Everything the test wrote, as one owned NUL-terminated buffer (empty when it wrote nothing). */
static char *sc_slurp(FILE *f) {
  long n = 0;
  if (f && fseek(f, 0, SEEK_END) == 0) n = ftell(f);
  if (n < 0) n = 0;
  char *buf = malloc((size_t)n + 1);
  if (!buf) { perror("malloc"); exit(101); }
  size_t got = 0;
  if (f) { rewind(f); got = fread(buf, 1, (size_t)n, f); }
  buf[got] = 0;
  return buf;
}
/* The failures, together, after the run: each test's captured output under its own header, how the
   process ended, then the bare list of names. */
static void sc_report_failures(int nfail, const int *fail_test, char **fail_out, char **fail_why) {
  printf("\nfailures:\n");
  for (int k = 0; k < nfail; k++) {
    printf("\n---- %s ----\n", SC_TESTS[fail_test[k]].name);
    const size_t len = strlen(fail_out[k]);
    if (len > 0) {
      fwrite(fail_out[k], 1, len, stdout);
      if (fail_out[k][len - 1] != '\n') putchar('\n');
    }
    printf("%s\n", fail_why[k]);
    free(fail_out[k]);
    free(fail_why[k]);
  }
  printf("\nfailures:\n");
  for (int k = 0; k < nfail; k++) printf("    %s\n", SC_TESTS[fail_test[k]].name);
  fflush(stdout);
}
/* One line on how a failed test's process ended, from its wait status. */
static char *sc_why_posix(int st, int should_panic) {
  char buf[128];
  if (WIFSIGNALED(st)) snprintf(buf, sizeof buf, "terminated by signal %d (%s)", WTERMSIG(st), strsignal(WTERMSIG(st)));
  else if (WIFEXITED(st) && WEXITSTATUS(st) != 0) snprintf(buf, sizeof buf, "exited with code %d", WEXITSTATUS(st));
  else snprintf(buf, sizeof buf, "%s", should_panic ? "did not panic as expected" : "exited with code 0");
  return sc_strdup(buf);
}
/* Core count without feature-test-macro landmines: macOS hides _SC_NPROCESSORS_ONLN under strict
   _POSIX_C_SOURCE, so use the stable sysctl entry point there. */
static int sc_runner_ncpu(void) {
#if defined(__APPLE__)
  extern int sysctlbyname(const char *, void *, size_t *, void *, size_t);
  int v = 0;
  size_t l = sizeof v;
  if (sysctlbyname("hw.ncpu", &v, &l, NULL, 0) != 0 || v < 1) return 1;
  return v;
#else
  long n = sysconf(_SC_NPROCESSORS_ONLN);
  return n > 0 ? (int)n : 1;
#endif
}
int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0); /* forked children must not inherit (and re-flush) buffered lines */
  int jobs = 0, no_fork = 0, quiet = 0, shard = 1, shards = 1;
  const char *filter = NULL;
  for (int i = 1; i < argc; i++) {
    if (!strncmp(argv[i], "--jobs=", 7)) jobs = atoi(argv[i] + 7);
    else if (!strcmp(argv[i], "--no-fork")) no_fork = 1;
    else if (!strcmp(argv[i], "--quiet")) quiet = 1;
    else if (!strncmp(argv[i], "--filter=", 9)) filter = argv[i] + 9;
    else if (!strncmp(argv[i], "--shard=", 8)) {
      char tail;
      if (sscanf(argv[i] + 8, "%d/%d%c", &shard, &shards, &tail) != 2 || shard < 1 || shard > shards) {
        fprintf(stderr, "invalid test shard: expected K/N with 1 <= K <= N\n");
        return 2;
      }
    }
  }
  if (jobs < 1) jobs = sc_runner_ncpu();
  int sel[SC_NTESTS > 0 ? SC_NTESTS : 1];
  int nsel = 0, matched = 0;
  for (int i = 0; i < SC_NTESTS; i++)
    if (sc_match(SC_TESTS[i].name, filter) && matched++ % shards == shard - 1) sel[nsel++] = i;
  if (shards > 1)
    printf("running %d test%s (shard %d/%d)\n", nsel, nsel == 1 ? "" : "s", shard, shards);
  else
    printf("running %d test%s\n", nsel, nsel == 1 ? "" : "s");
  void *genv = NULL;
  if (nsel > 0) genv = sc_genv_init();
  int passed = 0, failed = 0, skipped = 0;
  int fail_test[SC_NTESTS > 0 ? SC_NTESTS : 1];
  char *fail_out[SC_NTESTS > 0 ? SC_NTESTS : 1];
  char *fail_why[SC_NTESTS > 0 ? SC_NTESTS : 1];
  if (no_fork) { /* in-process: nothing is captured, a failure ends the run where it happens */
    for (int k = 0; k < nsel; k++) {
      const int i = sel[k];
      if (SC_TESTS[i].should_panic) {
        if (!quiet) printf("test %s ... skipped (should_panic needs fork)\n", SC_TESTS[i].name);
        skipped++;
        continue;
      }
      char **env = sc_env_snapshot();
      char *cwd = sc_getcwd_alloc();
      SC_TESTS[i].fn(genv);
      sc_env_restore(env);
      if (sc_chdir_back(cwd) != 0) { perror("chdir"); return 101; }
      free(cwd);
      if (!quiet) printf("test %s ... ok\n", SC_TESTS[i].name);
      passed++;
    }
  } else {
    pid_t pid_of[SC_NTESTS > 0 ? SC_NTESTS : 1];
    FILE *cap_of[SC_NTESTS > 0 ? SC_NTESTS : 1];
    int token_of[SC_NTESTS > 0 ? SC_NTESTS : 1];
    int shared = sc_runner_jobserver_active();
    int implicit_available = 1;
    int active = 0, next = 0;
    while (next < nsel || active > 0) {
      while (active < jobs && next < nsel) {
        int token = 0;
        if (shared) {
          if (implicit_available) implicit_available = 0;
          else {
            token = sc_runner_jobserver_try_acquire();
            if (!token) break;
          }
        }
        FILE *cap = tmpfile();
        if (!cap) {
          if (token && !sc_runner_jobserver_release()) abort();
          perror("tmpfile");
          return 101;
        }
        const pid_t pid = fork();
        if (pid == 0) {
          if (dup2(fileno(cap), 1) < 0 || dup2(fileno(cap), 2) < 0) { perror("dup2"); _exit(101); }
          sc_lk_fork_child_reset();
          SC_TESTS[sel[next]].fn(genv);
          fflush(NULL);
          sc_lk_report_now();
          fflush(NULL);
          _exit(0);
        }
        if (pid < 0) {
          if (token && !sc_runner_jobserver_release()) abort();
          perror("fork");
          return 101;
        }
        pid_of[next] = pid;
        cap_of[next] = cap;
        token_of[next] = token;
        next++;
        active++;
      }
      int st = 0;
      const pid_t done = wait(&st);
      if (done < 0) break;
      active--;
      int ti = -1;
      FILE *cap = NULL;
      int token = 0;
      for (int k = 0; k < next; k++)
        if (pid_of[k] == done) { ti = sel[k]; cap = cap_of[k]; token = token_of[k]; pid_of[k] = -1; break; }
      if (ti < 0) continue;
      if (shared) {
        if (token) {
          if (!sc_runner_jobserver_release()) abort();
        } else {
          implicit_available = 1;
        }
      }
      const int crashed = !(WIFEXITED(st) && WEXITSTATUS(st) == 0);
      if (crashed == SC_TESTS[ti].should_panic) {
        if (!quiet) printf("test %s ... ok%s\n", SC_TESTS[ti].name, SC_TESTS[ti].should_panic ? " (panicked as expected)" : "");
        passed++;
      } else {
        printf("test %s ... FAILED%s\n", SC_TESTS[ti].name, SC_TESTS[ti].should_panic ? " (expected a panic)" : "");
        fail_test[failed] = ti;
        fail_out[failed] = sc_slurp(cap);
        fail_why[failed] = sc_why_posix(st, SC_TESTS[ti].should_panic);
        failed++;
      }
      fclose(cap);
      fflush(stdout);
    }
  }
  if (genv) sc_genv_free(genv);
  if (failed) sc_report_failures(failed, fail_test, fail_out, fail_why);
  if (skipped)
    printf("\n%d passed, %d failed, %d skipped\n", passed, failed, skipped);
  else
    printf("\n%d passed, %d failed\n", passed, failed);
  return failed > 100 ? 100 : failed;
}
)".ptr() as *const char;
}

// Windows has no fork(); isolate each test in its own subprocess (`self --run-one=<i> --capture=<file>`)
// so should_panic and crashing tests are caught via the child's exit code. The PARENT runs the global
// @test_init/@test_free pair once, exactly as POSIX does: that pair's output is the visible one, since
// every child's stdout goes to its capture file (deleted for passing tests). Each child then rebuilds a
// private env for its own test: no fork means the parent's pointer cannot cross the process boundary.
// The child redirects its own stdout and stderr into the capture file; the parent reads it back for a
// failed test and deletes it.
const fn test_runner_main_win() *const char {
    return M"(static int sc_match(const char *name, const char *filter) {
  return !filter || strstr(name, filter) != NULL;
}
static char *sc_strdup(const char *s) {
  char *d = malloc(strlen(s) + 1);
  if (!d) { perror("malloc"); exit(101); }
  strcpy(d, s);
  return d;
}
/* The in-process leg has no per-test process, so it restores the environment itself: tests set
   compiler switches (SC_INLINE, SC_BCE, ...) and rely on the fork for isolation. */
static char *sc_getcwd_alloc(void) {
  char *d = _getcwd(NULL, 0);
  if (!d) { perror("getcwd"); exit(101); }
  return d;
}
static int sc_chdir_back(const char *d) { return _chdir(d); }
static char **sc_env_snapshot(void) {
  int n = 0;
  while (_environ[n]) n++;
  char **snap = malloc(((size_t)n + 1) * sizeof *snap);
  if (!snap) { perror("malloc"); exit(101); }
  for (int i = 0; i < n; i++) snap[i] = sc_strdup(_environ[i]);
  snap[n] = NULL;
  return snap;
}
static void sc_env_restore(char **snap) {
  /* _putenv_s compacts _environ, so the index only advances past kept entries */
  for (int i = 0; _environ[i];) {
    const char *eq = strchr(_environ[i], '=');
    const size_t nl = eq ? (size_t)(eq - _environ[i]) : strlen(_environ[i]);
    int keep = 0;
    for (int k = 0; snap[k] && !keep; k++) keep = !strncmp(snap[k], _environ[i], nl) && snap[k][nl] == '=';
    if (keep) { i++; continue; }
    char *name = sc_strdup(_environ[i]);
    name[nl] = 0;
    _putenv_s(name, "");
    free(name);
  }
  for (int k = 0; snap[k]; k++) {
    char *eq = strchr(snap[k], '=');
    if (eq) {
      *eq = 0;
      const char *cur = getenv(snap[k]);
      if (!cur || strcmp(cur, eq + 1)) _putenv_s(snap[k], eq + 1);
    }
    free(snap[k]);
  }
  free(snap);
}
/* Everything the test wrote, as one owned NUL-terminated buffer (empty when it wrote nothing). */
static char *sc_slurp(FILE *f) {
  long n = 0;
  if (f && fseek(f, 0, SEEK_END) == 0) n = ftell(f);
  if (n < 0) n = 0;
  char *buf = malloc((size_t)n + 1);
  if (!buf) { perror("malloc"); exit(101); }
  size_t got = 0;
  if (f) { rewind(f); got = fread(buf, 1, (size_t)n, f); }
  buf[got] = 0;
  return buf;
}
/* The failures, together, after the run: each test's captured output under its own header, how the
   process ended, then the bare list of names. */
static void sc_report_failures(int nfail, const int *fail_test, char **fail_out, char **fail_why) {
  printf("\nfailures:\n");
  for (int k = 0; k < nfail; k++) {
    printf("\n---- %s ----\n", SC_TESTS[fail_test[k]].name);
    const size_t len = strlen(fail_out[k]);
    if (len > 0) {
      fwrite(fail_out[k], 1, len, stdout);
      if (fail_out[k][len - 1] != '\n') putchar('\n');
    }
    printf("%s\n", fail_why[k]);
    free(fail_out[k]);
    free(fail_why[k]);
  }
  printf("\nfailures:\n");
  for (int k = 0; k < nfail; k++) printf("    %s\n", SC_TESTS[fail_test[k]].name);
  fflush(stdout);
}
/* One line on how a failed test's process ended, from its exit code. */
static char *sc_why_win(DWORD code, int should_panic) {
  char buf[128];
  if (code != 0) snprintf(buf, sizeof buf, "exited with code %lu (0x%08lX)", (unsigned long)code, (unsigned long)code);
  else snprintf(buf, sizeof buf, "%s", should_panic ? "did not panic as expected" : "exited with code 0");
  return sc_strdup(buf);
}
/* The capture file of test `i` in this run: deterministic, so the parent can name it again at reap time. */
static void sc_cap_path(char *out, size_t cap, const char *tmpdir, int i) {
  snprintf(out, cap, "%ssc-test-%lu-%d.txt", tmpdir, (unsigned long)GetCurrentProcessId(), i);
}
/* Path to re-spawn: argv[0] is whatever the caller typed and need not name a file the loader can open
   (`./__tests` from a shell has no .exe), so ask the CRT for this image's real path and fall back only
   if it refuses. */
static const char *sc_self(const char *fallback) {
  char *p = NULL;
  return (_get_pgmptr(&p) == 0 && p && *p) ? p : fallback;
}
static int sc_runner_ncpu(void) {
  SYSTEM_INFO si;
  GetSystemInfo(&si);
  return si.dwNumberOfProcessors > 0 ? (int)si.dwNumberOfProcessors : 1;
}
int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IOLBF, 0);
  setvbuf(stderr, NULL, _IOFBF, BUFSIZ); /* keep each child's flushed diagnostic in one append */
  const char *filter = NULL, *capture = NULL;
  int run_one = -1, no_fork = 0, quiet = 0, jobs = 0, shard = 1, shards = 1;
  for (int i = 1; i < argc; i++) {
    if (!strncmp(argv[i], "--run-one=", 10)) run_one = atoi(argv[i] + 10);
    else if (!strncmp(argv[i], "--capture=", 10)) capture = argv[i] + 10;
    else if (!strncmp(argv[i], "--jobs=", 7)) jobs = atoi(argv[i] + 7);
    else if (!strcmp(argv[i], "--no-fork")) no_fork = 1;
    else if (!strcmp(argv[i], "--quiet")) quiet = 1;
    else if (!strncmp(argv[i], "--filter=", 9)) filter = argv[i] + 9;
    else if (!strncmp(argv[i], "--shard=", 8)) {
      char tail;
      if (sscanf(argv[i] + 8, "%d/%d%c", &shard, &shards, &tail) != 2 || shard < 1 || shard > shards) {
        fprintf(stderr, "invalid test shard: expected K/N with 1 <= K <= N\n");
        return 2;
      }
    }
  }
  if (jobs < 1) jobs = sc_runner_ncpu();
  /* WaitForMultipleObjects cannot watch more than this many handles at once. */
  if (jobs > MAXIMUM_WAIT_OBJECTS) jobs = MAXIMUM_WAIT_OBJECTS;
  if (run_one >= 0) { /* child: run exactly one test in-process, exit status reports crash/panic */
    if (capture) { /* both streams into the one file, UNBUFFERED: a panic aborts without flushing,
       and freopen resets stdout to full buffering (Windows has no line buffering at all), so any
       buffered output would die with the crashing test */
      if (!freopen(capture, "wb", stdout)) { perror(capture); return 101; }
      if (_dup2(_fileno(stdout), _fileno(stderr)) != 0) { perror("dup2"); return 101; }
      setvbuf(stdout, NULL, _IONBF, 0);
      setvbuf(stderr, NULL, _IONBF, 0);
    }
    void *genv = sc_genv_init();
    SC_TESTS[run_one].fn(genv);
    if (genv) sc_genv_free(genv);
    return 0;
  }
  int sel[SC_NTESTS > 0 ? SC_NTESTS : 1];
  int nsel = 0, matched = 0;
  for (int i = 0; i < SC_NTESTS; i++)
    if (sc_match(SC_TESTS[i].name, filter) && matched++ % shards == shard - 1) sel[nsel++] = i;
  if (shards > 1)
    printf("running %d test%s (shard %d/%d)\n", nsel, nsel == 1 ? "" : "s", shard, shards);
  else
    printf("running %d test%s\n", nsel, nsel == 1 ? "" : "s");
  /* The suite-level env lifecycle, in the parent as on POSIX: its teardown output is the one the
     run's caller sees. Children build their own env per test (no fork to inherit this one). */
  void *genv = NULL;
  if (nsel > 0) genv = sc_genv_init();
  int passed = 0, failed = 0, skipped = 0;
  int fail_test[SC_NTESTS > 0 ? SC_NTESTS : 1];
  char *fail_out[SC_NTESTS > 0 ? SC_NTESTS : 1];
  char *fail_why[SC_NTESTS > 0 ? SC_NTESTS : 1];
  if (no_fork) { /* in-process, same meaning as POSIX: no isolation, so no panic can be caught */
    for (int k = 0; k < nsel; k++) {
      const int i = sel[k];
      if (SC_TESTS[i].should_panic) {
        if (!quiet) printf("test %s ... skipped (should_panic needs fork)\n", SC_TESTS[i].name);
        skipped++;
        continue;
      }
      char **env = sc_env_snapshot();
      char *cwd = sc_getcwd_alloc();
      SC_TESTS[i].fn(genv);
      sc_env_restore(env);
      if (sc_chdir_back(cwd) != 0) { perror("chdir"); return 101; }
      free(cwd);
      if (!quiet) printf("test %s ... ok\n", SC_TESTS[i].name);
      passed++;
    }
  } else {
    char tmpdir[MAX_PATH];
    const DWORD tl = GetTempPathA(MAX_PATH, tmpdir);
    if (tl == 0 || tl >= MAX_PATH) { fprintf(stderr, "cannot locate the temp directory\n"); return 101; }
    /* A pool of subprocesses, `jobs` at a time -- the same shape as the POSIX fork pool: _P_NOWAIT hands
       back a process handle instead of blocking, and WaitForMultipleObjects reaps whichever finishes
       first. Serial spawning was what made this runner several times slower than its POSIX siblings. */
    HANDLE running[MAXIMUM_WAIT_OBJECTS];
    int running_test[MAXIMUM_WAIT_OBJECTS];
    int running_token[MAXIMUM_WAIT_OBJECTS];
    int shared = sc_runner_jobserver_active();
    int implicit_available = 1;
    int active = 0, next = 0;
    while (next < nsel || active > 0) {
      while (active < jobs && next < nsel) {
        int token = 0;
        if (shared) {
          if (implicit_available) implicit_available = 0;
          else {
            token = sc_runner_jobserver_try_acquire();
            if (!token) break;
          }
        }
        const int i = sel[next++];
        char idbuf[24];
        snprintf(idbuf, sizeof idbuf, "--run-one=%d", i);
        /* _spawnv joins the arguments with spaces and quotes nothing; the temp path may contain spaces. */
        char cappath[MAX_PATH];
        sc_cap_path(cappath, sizeof cappath, tmpdir, i);
        char capbuf[MAX_PATH + 16];
        snprintf(capbuf, sizeof capbuf, "--capture=\"%s\"", cappath);
        const char *self = sc_self(argv[0]);
        const char *const args[] = { self, idbuf, capbuf, NULL };
        const intptr_t ph = _spawnv(_P_NOWAIT, self, args);
        if (ph == -1) {
          if (token && !sc_runner_jobserver_release()) abort();
          if (shared && !token) implicit_available = 1;
          printf("test %s ... FAILED (could not start)\n", SC_TESTS[i].name);
          fail_test[failed] = i;
          fail_out[failed] = sc_strdup("");
          fail_why[failed] = sc_strdup("could not start");
          failed++;
          fflush(stdout);
          continue;
        }
        running[active] = (HANDLE)ph;
        running_test[active] = i;
        running_token[active] = token;
        active++;
      }
      if (active == 0) continue;
      const DWORD w = WaitForMultipleObjects((DWORD)active, running, FALSE, INFINITE);
      const DWORD slot = w - WAIT_OBJECT_0;
      if (w == WAIT_FAILED || slot >= (DWORD)active) break;
      DWORD code = 1;
      GetExitCodeProcess(running[slot], &code);
      CloseHandle(running[slot]);
      const int ti = running_test[slot];
      const int token = running_token[slot];
      running[slot] = running[active - 1]; /* the pool is unordered: backfill from the end */
      running_test[slot] = running_test[active - 1];
      running_token[slot] = running_token[active - 1];
      active--;
      if (shared) {
        if (token) {
          if (!sc_runner_jobserver_release()) abort();
        } else {
          implicit_available = 1;
        }
      }
      const int crashed = (code != 0);
      char cappath[MAX_PATH];
      sc_cap_path(cappath, sizeof cappath, tmpdir, ti);
      if (crashed == SC_TESTS[ti].should_panic) {
        if (!quiet) printf("test %s ... ok%s\n", SC_TESTS[ti].name, SC_TESTS[ti].should_panic ? " (panicked as expected)" : "");
        passed++;
      } else {
        printf("test %s ... FAILED%s\n", SC_TESTS[ti].name, SC_TESTS[ti].should_panic ? " (expected a panic)" : "");
        FILE *cap = fopen(cappath, "rb");
        fail_test[failed] = ti;
        fail_out[failed] = sc_slurp(cap);
        fail_why[failed] = sc_why_win(code, SC_TESTS[ti].should_panic);
        if (cap) fclose(cap);
        failed++;
      }
      remove(cappath);
      fflush(stdout);
    }
  }
  if (genv) sc_genv_free(genv);
  if (failed) sc_report_failures(failed, fail_test, fail_out, fail_why);
  if (skipped)
    printf("\n%d passed, %d failed, %d skipped\n", passed, failed, skipped);
  else
    printf("\n%d passed, %d failed\n", passed, failed);
  return failed > 100 ? 100 : failed;
}
)".ptr() as *const char;
}

/// Write build/__test_main.c: extern wrapper prototypes, the test table (display names `module::fn` or
/// `module::Type::method`), the global-env hooks (stubs when absent), and the fixed runner. Returns the
/// path (ownership to the caller / keep-list), or None when the file cannot be opened.
pub fn write_test_main(p: &mut loader::Package, plan: &TestPlan) Option<String> {
    let mut path = build_out_path(p.gen_root.as_str(), "__test_main", ".c");
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
        let a = p.module_ast_const(tc.mod);
        let nmnode = a.at_const(tc.func).as_data.function.name;
        let nm = a.at_const(nmnode).as_data.name.text;
        let modpath = p.modules[tc.mod as usize].path.as_str();
        let msrc = p.modules[tc.mod as usize].source.as_str().ptr() as *const char;
        unsafe stdio::fprintf(f, "  { \"%.*s::".ptr() as *const char, modpath.len() as i32, modpath.ptr());
        if tc.suite.node != NODE_NONE {
            let sa = p.module_ast_const(tc.suite.module);
            let snmn = sa.at_const(tc.suite.node).as_data.aggregate.name;
            let snm = sa.at_const(snmn).as_data.name.text;
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
    unsafe stdio::fputs("#ifdef _WIN32\n".ptr() as *const char, f);
    unsafe stdio::fputs(test_runner_main_win(), f);
    unsafe stdio::fputs("#else\n".ptr() as *const char, f);
    unsafe stdio::fputs(test_runner_main_posix(), f);
    unsafe stdio::fputs("#endif\n".ptr() as *const char, f);
    unsafe stdio::fclose(f);
    return Option::<String>::Some(path);
}

/// Compile the emitted build tree with $CC. When `out_bin` is set (the `build` subcommand) the program is
/// linked to that path and nothing runs; otherwise it links `<gen_root>/__tests` and runs it as the test
/// runner, forwarding `topts`' options. Returns the compile's or the runner's exit code.
pub fn test_build_and_run(
    p: &loader::Package,
    topts: *const TestOpts,
    keep: &Vector<String>,
    out_bin: str,
    cflags: str,
    target: i32,
) i32 {
    // A cross target brings its own compiler: $CC on the host would build a host binary while the front end
    // gated items on `--target=`, with no diagnostic.
    let sdk = target_sdk(target);
    let mut ccs = String::new();
    if sdk != 0 {
        sdk_cc(sdk, &mut ccs);
    }
    if ccs.len() == 0 {
        let env = stdlib::getenv("CC");
        if env != null && unsafe *env != 0 as char {
            ccs.push_str(str::from_cstr(env));
        } else {
            ccs.push_str("cc");
        }
    }
    let root = p.gen_root.as_str();
    // No shell anywhere: the compile is an argv child, so paths pass through verbatim (spaces, quotes,
    // non-ASCII) while flag strings are split on whitespace. The runner is named with an explicit `.exe`
    // on Windows so running it below never depends on the spawn filling the extension in.
    let exe = if unsafe shim::sc_host_platform() == 0 {
        ".exe";
    } else {
        "";
    };
    let mut args = Vector::<String>::new();
    split_args(&mut args, ccs.as_str());
    split_args(&mut args, "-std=c11 -D_POSIX_C_SOURCE=200809L");
    // The cross triple comes first so the profile's flags (`cflags`, empty for a bare build) can override it.
    let mut fl = String::new();
    push_sdk_flags(&mut fl, sdk, p.arch);
    split_args(&mut args, fl.as_str());
    split_args(&mut args, cflags);
    // One command compiles and links, so the link-only SDK libs ride along.
    let mut ll = String::new();
    push_sdk_libs(&mut ll, sdk);
    split_args(&mut args, ll.as_str());
    args.push(String::from_str("-o"));
    let mut outp = String::new();
    if out_bin.len() != 0 {
        outp.push_str(out_bin);
    } else {
        outp.push_str(root);
        outp.push_str("/__tests");
        outp.push_str(exe);
    }
    args.push(outp.clone());
    for i in 0..keep.len() {
        let cf = keep[i].as_str();
        if cf.len() > 2 && cf.ends_with(".c") {
            args.push(String::from_str(cf));
        }
    }
    // @c.link flags, one per line in build/__ldflags.
    let ldpath = build_out_path(root, "__ldflags", "");
    let lf = stdio::fopen(ldpath.as_str(), "rb");
    if lf != null {
        let mut line = PathBuf {};
        while unsafe stdio::fgets(&mut line[0], 4096, lf) != null {
            let ll2 = unsafe cstring::strlen(&line[0]);
            if ll2 > 0 && line[ll2 - 1] == '\n' as char {
                line[ll2 - 1] = 0 as char;
            }
            if line[0] != 0 as char {
                split_args(&mut args, str::from_cstr(&line[0]));
            }
        }
        unsafe stdio::fclose(lf);
    }
    let brc = exec_args(&mut args, null);
    if brc != 0 {
        let mut what = "test build".ptr() as *const char;
        if out_bin.len() != 0 {
            what = "build".ptr() as *const char;
        }
        unsafe stdio::fprintf(stdio::stderr(), "super-c: %s failed (%s)\n".ptr() as *const char, what, ccs.cstr());
        return 1;
    }
    // The `build` subcommand: the program is linked, nothing to run.
    if out_bin.len() != 0 {
        return 0;
    }
    return test_run_runner(topts, outp.as_str());
}

/// Run the linked test runner `bin` with the pool, fork, filter, quiet and shard options in `topts`.
/// Releases this process's jobserver slot first so the runner's test pool inherits it. Returns the
/// runner's exit code, or 1 when it could not be spawned.
pub fn test_run_runner(topts: *const TestOpts, bin: str) i32 {
    let mut run = Vector::<String>::new();
    run.push(String::from_str(bin));
    if unsafe topts.jobs > 0 {
        let mut jb = Buf64 {};
        unsafe stdio::snprintf(&mut jb[0], 64, "--jobs=%d".ptr() as *const char, unsafe topts.jobs);
        run.push(String::from_cstr(&jb[0]));
    }
    if unsafe topts.no_fork {
        run.push(String::from_str("--no-fork"));
    }
    if unsafe topts.quiet {
        run.push(String::from_str("--quiet"));
    }
    if unsafe topts.filter != null {
        let mut fs = String::from_str("--filter=");
        fs.push_str(str::from_cstr(unsafe topts.filter));
        run.push(fs);
    }
    if unsafe topts.shards > 0 {
        let mut sb = Buf64 {};
        unsafe stdio::snprintf(
            &mut sb[0],
            64,
            "--shard=%d/%d".ptr() as *const char,
            unsafe topts.shard,
            unsafe topts.shards,
        );
        run.push(String::from_cstr(&sb[0]));
    }
    unsafe shim::sc_jobserver_release_claim();
    let rrc = exec_args(&mut run, null);
    if rrc < 0 {
        return 1;
    }
    return rrc;
}

extend TestPlan {
    /// `count` is the package's module count: it sizes the per-module fixture tables (minimum 1).
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

    // Index of the (module, type) suite in plan.suites, creating it when `create`; -1 when absent / no-create.
    fn suite_of(self: &mut Self, m: ModuleId, ty: DefId, is_enum: bool, create: bool) i32 {
        for i in 0..self.suites.len() {
            let s = self.suites.at(i);
            if s.mod == m && s.ty.module == ty.module && s.ty.node == ty.node {
                return i as i32;
            }
        }
        if !create {
            return -1;
        }
        self.suites.push(TestSuite { mod: m, ty: ty, is_enum: is_enum, init: NODE_NONE, fre: NODE_NONE });
        return (self.suites.len() - 1) as i32;
    }
}
