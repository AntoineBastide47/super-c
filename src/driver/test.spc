// The --test pipeline: collects every @test/@test_init/@test_free into a validated TestPlan (consumed by
// codegen's per-module wrapper emission), synthesizes the fork-per-test runner TU (build/__test_main.c),
// and compiles + runs the emitted build tree with $CC. test_build_and_run doubles as the `build`
// subcommand's link step when `out_bin` is set.
import stdio;
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
import build_system::objcache as ocache;
import build_system::build as bsys;

/// --test run options, forwarded to the generated runner.
pub struct TestOpts {
    pub enabled: bool,
    pub jobs: i32,
    pub no_fork: bool,
    pub quiet: bool,
    pub filter: *const char,
    pub shard: i32,
    pub shards: i32,
    pub timeout: i32, // seconds a test may run before it fails as timed out; 0: none; -1: DEFAULT_TEST_TIMEOUT
    pub durations: *const char, // the suite's duration file (`super-c test`: <test dir>/durations.tsv); null: none
    pub record: bool, // --test-record-durations: merge this run's durations into `durations`
}

/// The seconds a test may run when neither `--test-timeout` nor its `@test(timeout = N)` says otherwise.
pub const DEFAULT_TEST_TIMEOUT: i32 = 90;
/// One runnable @test. `wants` is a bitmask of the wrapper's arguments: 1 = fixture/receiver param,
/// 2 = global-env param. The suite fields are set only for suite-method tests taking `self`.
pub struct TestCase {
    pub mod: ModuleId,
    pub func: NodeId,
    pub should_panic: bool,
    pub timeout: u32, // `@test(timeout = N)` seconds; 0: the run's global timeout
    pub wants: u8,
    pub suite: DefId,
    pub suite_init: NodeId,
    pub suite_free: NodeId,
}
/// A per-(module, extended type) suite: its '@test_init' producer and optional '@test_free' teardown.
pub struct TestSuite {
    pub mod: ModuleId,
    pub ty: DefId,
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
    pub suites: Vector<TestSuite>,
    pub genv_mod: ModuleId,
    pub genv_init: NodeId,
    pub genv_free: NodeId,
    pub genv_type: DefId,
    pub ok: bool,
}
// A test-plan validation error, rendered with the compiler's usual source excerpt.
fn test_err(p: &mut loader::Package, m: ModuleId, sp: tok::Span, msg: str) {
    let src = p.modules[m as usize].source.as_str();
    let file = p.modules[m as usize].file.as_str();
    let mut errs = diag::Errors::new();
    errs.emit_span(sp, String::from_str(msg));
    errs.finalize(src, file);
    errs.log();
    p.ok = false;
}

// The plain struct/enum decl a type NODE names, or {0, NODE_NONE} (fixtures must be nominal + non-generic).
const fn test_type_decl(p: &loader::Package, am: ModuleId, tnode: NodeId) DefId {
    let none = DefId { module: 0, node: NODE_NONE };
    if tnode == NODE_NONE {
        return none;
    }
    let a = p.module_ast_const(am);
    let tk = unsafe (*a).at_const(tnode).kind;
    if tk != NodeKind::NODE_TYPE_PATH && tk != NodeKind::NODE_IDENTIFIER {
        return none;
    }
    let d = unsafe (*a).resolution_def(tnode);
    if d.node == NODE_NONE || d.module as usize >= p.modules.len() {
        return none;
    }
    let da = p.module_ast_const(d.module);
    let dk = unsafe (*da).at_const(d.node).kind;
    let gen = unsafe (*da).at_const(d.node).as_data.aggregate.generics;
    if dk != NodeKind::NODE_STRUCT && dk != NodeKind::NODE_ENUM || gen.len != 0 {
        return none;
    }
    return d;
}

// A function's single return type node (unwrapping a named return), or NODE_NONE.
const fn test_fn_ret_node(p: &loader::Package, am: ModuleId, fnode: NodeId) NodeId {
    let a = p.module_ast_const(am);
    let rets = unsafe (*a).at_const(fnode).as_data.function.returns;
    if rets.len != 1 {
        return NODE_NONE;
    }
    return unsafe (*a).slot_type_node(unsafe (*a).list(rets)[0]);
}

const fn test_fn_returns_nothing(p: &loader::Package, am: ModuleId, src: *const char, fnode: NodeId) bool {
    let a = p.module_ast_const(am);
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
    let a = p.module_ast_const(m);
    let sp = unsafe (*a).at_const(pnode).span;
    let tnode = unsafe (*a).at_const(pnode).as_data.parameter.ty;
    let tk = if tnode != NODE_NONE {
        unsafe (*a).at_const(tnode).kind;
    } else {
        NodeKind::NODE_NONE_KIND;
    };
    if tnode == NODE_NONE || tk != NodeKind::NODE_REFERENCE_TYPE {
        test_err(p, m, sp, "a '@test' parameter must be a reference to the module fixture or the global env");
        return 0;
    }
    let it = unsafe (*a).at_const(tnode).as_data.indirect_type;
    let d = test_type_decl(p, m, it.ty);
    if fx.node != NODE_NONE && d.module == fx.module && d.node == fx.node {
        return 1;
    }
    if genv.node != NODE_NONE && d.module == genv.module && d.node == genv.node {
        if it.qualifier == TypeQualifier::TYPE_QUAL_MUT {
            test_err(p, m, sp, "the global test env is shared: take it as '&', not '&mut'");
            return 0;
        }
        return 2;
    }
    test_err(p, m, sp, "this parameter matches neither the module's '@test_init' fixture nor the global env");
    return 0;
}

// The owner of every item that survives `platform_filter`, keyed `skey_mix(0, module << 32 | node)`: its
// extend node, or NODE_NONE at top level. The filter drops `@platform`/`@arch`-gated items from the item
// lists but leaves their attributes in the table, so a gated test (or one whose extend is gated) has no
// entry; the runner would otherwise call a function the emitter never wrote.
fn test_item_owners(p: &loader::Package) Map<u64, u64> {
    let mut owners = Map::<u64, u64>::new();
    for m in 0..p.modules.len() {
        if !p.modules[m].has_ast || p.modules[m].prelude {
            continue;
        }
        let a = p.module_ast_const(m as ModuleId);
        if unsafe (*a).attrs.len() == 0 {
            continue;
        }
        let items = unsafe (*a).at_const((*a).root).as_data.program.items;
        let ids = unsafe (*a).list(items);
        for i in 0..items.len {
            let iid = unsafe ids[i as usize];
            owners.insert(skey_mix(0, m as u64 << 32 | iid as u64), NODE_NONE);
            if unsafe (*a).at_const(iid).kind == NodeKind::NODE_EXTEND {
                let ed = unsafe (*a).at_const(iid).as_data.extend_def;
                let mids = unsafe (*a).list(ed.items);
                for j in 0..ed.items.len {
                    owners.insert(skey_mix(0, m as u64 << 32 | (unsafe mids[j as usize]) as u64), iid);
                }
            }
        }
    }
    return owners;
}

// `fnode`'s owner in `owners` (module `m`): its extend node, NODE_NONE at top level, -1 when gated out.
fn test_owner(owners: &Map<u64, u64>, m: ModuleId, fnode: NodeId) i64 {
    return switch owners.get(&skey_mix(0, m as u64 << 32 | fnode as u64)) {
        Some(v) => (*v) as i64,
        None => -1,
    };
}

// The suite type of a test item (span `sp`) in extend `ext`; {0, NODE_NONE} with an error emitted when
// the extend cannot hold a suite (a conformance or generic extend, or a target that is not a plain
// struct or enum) or when `global` marks a '(global)' fixture item there.
fn test_suite_type(p: &mut loader::Package, m: ModuleId, ext: NodeId, sp: tok::Span, global: bool) DefId {
    let none = DefId { module: 0, node: NODE_NONE };
    let ed = unsafe (*p.module_ast_const(m)).at_const(ext).as_data.extend_def;
    if ed.interface_type != NODE_NONE || ed.generics.len != 0 {
        test_err(p, m, sp, "test attributes are only allowed on methods of a non-generic inherent 'extend'");
        return none;
    }
    if global {
        test_err(p, m, sp, "'(global)' is not allowed on a method; declare the global pair at top level");
        return none;
    }
    let d = test_type_decl(p, m, ed.target_type);
    if d.node == NODE_NONE {
        test_err(p, m, sp, "a test suite's extend target must be a plain (non-generic) struct or enum");
    }
    return d;
}

// Whether `fnode` has the teardown shape `fn(&mut <want>)` returning nothing.
fn test_free_sig(p: &loader::Package, m: ModuleId, src: *const char, fnode: NodeId, want: DefId) bool {
    let a = p.module_ast_const(m);
    let params = unsafe (*a).at_const(fnode).as_data.function.params;
    if params.len != 1 || !test_fn_returns_nothing(p, m, src, fnode) {
        return false;
    }
    let pty = unsafe (*a).at_const(unsafe (*a).list(params)[0]).as_data.parameter.ty;
    if pty == NODE_NONE || unsafe (*a).at_const(pty).kind != NodeKind::NODE_REFERENCE_TYPE {
        return false;
    }
    let it = unsafe (*a).at_const(pty).as_data.indirect_type;
    let d = test_type_decl(p, m, it.ty);
    return it.qualifier == TypeQualifier::TYPE_QUAL_MUT && d.module == want.module && d.node == want.node;
}

/// Collect + validate every @test/@test_init/@test_free in the package into a runnable plan.
pub fn test_plan_build(p: &mut loader::Package, plan: &mut TestPlan) {
    let n = p.modules.len();
    let owners = test_item_owners(p);
    // Pass 1: fixture producers/teardowns (module, suite, and global).
    for m in 0..n {
        if !p.modules[m].has_ast || p.modules[m].prelude {
            continue;
        }
        let src = p.modules[m].source.as_str().ptr() as *const char;
        let nattr = unsafe (*p.module_ast_const(m as ModuleId)).attrs.len();
        for ai in 0..nattr {
            let at = unsafe (*p.module_ast_const(m as ModuleId)).attrs[ai];
            if at.kind != AttrKind::ATTR_TEST_INIT as u8 && at.kind != AttrKind::ATTR_TEST_FREE as u8 {
                continue;
            }
            let own = test_owner(&owners, m as ModuleId, at.owner);
            if own < 0 {
                continue; // gated out for this target
            }
            let ext = own as NodeId;
            let sp = unsafe (*p.module_ast_const(m as ModuleId)).at_const(at.owner).span;
            let mut target = DefId { module: 0, node: NODE_NONE };
            if ext != NODE_NONE {
                target = test_suite_type(p, m as ModuleId, ext, sp, at.arg != 0);
                if target.node == NODE_NONE {
                    continue;
                }
            }
            if at.kind == AttrKind::ATTR_TEST_INIT as u8 {
                let plen = unsafe (*p.module_ast_const(m as ModuleId)).at_const(at.owner).as_data.function.params.len;
                if plen != 0 {
                    test_err(p, m as ModuleId, sp, "'@test_init' takes no parameters");
                    continue;
                }
                let ret = test_fn_ret_node(p, m as ModuleId, at.owner);
                let d = test_type_decl(p, m as ModuleId, ret);
                if d.node == NODE_NONE {
                    test_err(
                        p,
                        m as ModuleId,
                        sp,
                        "'@test_init' must return a plain (non-generic) struct or enum fixture",
                    );
                    continue;
                }
                if ext != NODE_NONE {
                    if d.module != target.module || d.node != target.node {
                        test_err(
                            p,
                            m as ModuleId,
                            sp,
                            "a suite '@test_init' method must return the extended type itself",
                        );
                        continue;
                    }
                    let si = plan.suite_of(m as ModuleId, target, true);
                    if plan.suites[si as usize].init != NODE_NONE {
                        test_err(p, m as ModuleId, sp, "duplicate suite '@test_init' (one per type per module)");
                        continue;
                    }
                    plan.suites[si as usize].init = at.owner;
                } else if at.arg != 0 {
                    if plan.genv_init != NODE_NONE {
                        test_err(p, m as ModuleId, sp, "duplicate '@test_init(global)' (one per test tree)");
                        continue;
                    }
                    plan.genv_mod = m as ModuleId;
                    plan.genv_init = at.owner;
                    plan.genv_type = d;
                } else {
                    if plan.fx_init[m] != NODE_NONE {
                        test_err(p, m as ModuleId, sp, "duplicate '@test_init' (one per module)");
                        continue;
                    }
                    plan.fx_init[m] = at.owner;
                    plan.fx_type[m] = d;
                }
            } else {
                if ext == NODE_NONE {
                    continue;
                }
                if !test_free_sig(p, m as ModuleId, src, at.owner, target) {
                    test_err(
                        p,
                        m as ModuleId,
                        sp,
                        "a suite '@test_free' must be 'fn(self: &mut <the extended type>)' returning nothing",
                    );
                    continue;
                }
                let si = plan.suite_of(m as ModuleId, target, true);
                if plan.suites[si as usize].fre != NODE_NONE {
                    test_err(p, m as ModuleId, sp, "duplicate suite '@test_free'");
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
        let nattr = unsafe (*p.module_ast_const(m as ModuleId)).attrs.len();
        for ai in 0..nattr {
            let at = unsafe (*p.module_ast_const(m as ModuleId)).attrs[ai];
            if at.kind != AttrKind::ATTR_TEST_FREE as u8 || test_owner(&owners, m as ModuleId, at.owner) != NODE_NONE as i64 {
                continue; // gated out, or a suite method
            }
            let sp = unsafe (*p.module_ast_const(m as ModuleId)).at_const(at.owner).span;
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
                        "'@test_free(global)' has no matching '@test_init(global)' in this module";
                    } else {
                        "'@test_free' has no matching '@test_init' in this module";
                    },
                );
                continue;
            }
            if !test_free_sig(p, m as ModuleId, src, at.owner, want) {
                test_err(
                    p,
                    m as ModuleId,
                    sp,
                    if global {
                        "'@test_free(global)' must be 'fn(&mut <fixture>)' returning nothing";
                    } else {
                        "'@test_free' must be 'fn(&mut <fixture>)' returning nothing";
                    },
                );
                continue;
            }
            if global {
                if plan.genv_free != NODE_NONE {
                    test_err(p, m as ModuleId, sp, "duplicate '@test_free(global)'");
                    continue;
                }
                plan.genv_free = at.owner;
            } else {
                if plan.fx_free[m] != NODE_NONE {
                    test_err(p, m as ModuleId, sp, "duplicate '@test_free' (one per module)");
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
            let sp = unsafe (*p.module_ast_const(s.mod)).at_const(s.fre).span;
            test_err(
                p,
                s.mod,
                sp,
                "a suite '@test_free' has no matching '@test_init' method on this type in this module",
            );
        }
    }
    // Pass 2: the tests themselves.
    for m in 0..n {
        if !p.modules[m].has_ast || p.modules[m].prelude {
            continue;
        }
        let src = p.modules[m].source.as_str().ptr() as *const char;
        let nattr = unsafe (*p.module_ast_const(m as ModuleId)).attrs.len();
        for ai in 0..nattr {
            let at = unsafe (*p.module_ast_const(m as ModuleId)).attrs[ai];
            if at.kind != AttrKind::ATTR_TEST as u8 {
                continue;
            }
            let own = test_owner(&owners, m as ModuleId, at.owner);
            if own < 0 {
                continue; // gated out for this target
            }
            let ext = own as NodeId;
            let sp = unsafe (*p.module_ast_const(m as ModuleId)).at_const(at.owner).span;
            let mut suite = DefId { module: 0, node: NODE_NONE };
            if ext != NODE_NONE {
                suite = test_suite_type(p, m as ModuleId, ext, sp, false);
                if suite.node == NODE_NONE {
                    continue;
                }
            }
            if !test_fn_returns_nothing(p, m as ModuleId, src, at.owner) {
                test_err(p, m as ModuleId, sp, "a '@test' function returns nothing");
                continue;
            }
            let nmnode = unsafe (*p.module_ast_const(m as ModuleId)).at_const(at.owner).as_data.function.name;
            let nmsp = unsafe (*p.module_ast_const(m as ModuleId)).at_const(nmnode).as_data.name.text;
            if ext == NODE_NONE && nmsp.end - nmsp.start == 4 && unsafe cstring::memcmp(
                src + nmsp.start as usize,
                "main".ptr(),
                4,
            ) == 0 {
                test_err(p, m as ModuleId, sp, "'main' cannot be a '@test' (it is replaced by the test runner)");
                continue;
            }
            let params = unsafe (*p.module_ast_const(m as ModuleId)).at_const(at.owner).as_data.function.params;
            if params.len > 2 {
                test_err(
                    p,
                    m as ModuleId,
                    sp,
                    "a '@test' function takes at most the fixture (or 'self') and the global env",
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
                let pid = unsafe (*p.module_ast_const(m as ModuleId)).list(params)[k as usize];
                let bit = test_param_bit(p, m as ModuleId, pid, fx, genv_ty);
                if bit == 0 {
                    bad = true;
                } else if (wants & bit) != 0 {
                    test_err(p, m as ModuleId, sp, "duplicate '@test' parameter kind");
                    bad = true;
                } else if bit == 1 && (wants & 2) != 0 {
                    test_err(p, m as ModuleId, sp, "the fixture ('self') parameter must come before the global env");
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
                let si2 = plan.suite_of(m as ModuleId, suite, false);
                if si2 < 0 || plan.suites[si2 as usize].init == NODE_NONE {
                    test_err(
                        p,
                        m as ModuleId,
                        sp,
                        "no '@test_init' method on this type in this module produces the receiver",
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
                    should_panic: (at.arg & TEST_SHOULD_PANIC) != 0,
                    timeout: at.arg >> TEST_TIMEOUT_SHIFT,
                    wants: wants,
                    suite: case_suite,
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
#include <errno.h>
#include <signal.h>
/* A failing test aborts: its report adds the thread's last error code, which a failed open, spawn or
   write the test made often explains (errno is reset when the test starts; a code may still predate
   the failure). Then the default action runs: POSIX re-raises SIGABRT, Windows exits with code 3. */
static void sc_runner_abort(int sig) {
  const int e = errno;
  if (e != 0) fprintf(stderr, "  last errno: %d (%s)\n", e, strerror(e));
  fflush(stderr);
  signal(sig, SIG_DFL);
}
#ifdef _WIN32
#include <direct.h>
#include <io.h>
#include <process.h>
#include <stdint.h>
#include <windows.h>
#define sc_environ _environ
#define sc_getcwd _getcwd
#define sc_chdir _chdir
#define sc_setenv(n, v) _putenv_s(n, v)
#define sc_unsetenv(n) _putenv_s(n, "")
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
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>
#if defined(__APPLE__)
#include <libproc.h>
#elif defined(__linux__)
#include <dirent.h>
#endif
extern char **environ;
#define sc_environ environ
#define sc_getcwd getcwd
#define sc_chdir chdir
#define sc_setenv(n, v) setenv(n, v, 1)
#define sc_unsetenv(n) unsetenv(n)
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
/* Timeout diagnostics. Each test's capture file is a named file, and the test's process carries its path in
   SC_TEST_DIAG, which every process it starts inherits: the runtime of every Super-C program in the tree
   answers SIGURG by appending its own threads' stacks there (__sc_diag_install, super_rt), and a library
   chains its state dump in front (std's reactor). Past a test's deadline the runner asks each process
   of the test's tree in turn, adds the kernel's view of each thread on Linux, then kills the whole tree
   SC_DIAG_GRACE seconds later. SIGURG is ignored by default: cc, ld and the like are left running. */
#define SC_DIAG_GRACE 3
#define SC_DIAG_TREE 64
void __sc_diag_install(void);
/* A named capture file in $TMPDIR (else /tmp), opened for reading and writing; its path in `path`. */
static FILE *sc_cap_open(char *path, size_t n) {
  const char *d = getenv("TMPDIR");
  snprintf(path, n, "%s/sc-test-XXXXXX", d != NULL && d[0] != 0 ? d : "/tmp");
  const int fd = mkstemp(path);
  if (fd < 0) return NULL;
  /* Every writer appends (the test, and the dumps the runner asks for), so none overwrites another. */
  (void)fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_APPEND);
  FILE *f = fdopen(fd, "w+b");
  if (f == NULL) {
    close(fd);
    remove(path);
  }
  return f;
}
/* The process tree under `root`, root first, breadth first: at most SC_DIAG_TREE processes. */
static int sc_tree(pid_t root, pid_t *out) {
  int n = 0;
  out[n++] = root;
  for (int k = 0; k < n && n < SC_DIAG_TREE; k++) {
#if defined(__APPLE__)
    pid_t kids[SC_DIAG_TREE];
    const int nk = proc_listchildpids(out[k], kids, (int)sizeof kids); /* a count of pids, not bytes */
    for (int i = 0; i < nk && i < SC_DIAG_TREE && n < SC_DIAG_TREE; i++) out[n++] = kids[i];
#elif defined(__linux__)
    DIR *d = opendir("/proc");
    if (d == NULL) break;
    struct dirent *e;
    while ((e = readdir(d)) != NULL && n < SC_DIAG_TREE) {
      const pid_t p = (pid_t)atoi(e->d_name);
      if (p <= 0) continue;
      char sp[64], buf[512];
      snprintf(sp, sizeof sp, "/proc/%d/stat", (int)p);
      FILE *f = fopen(sp, "rb");
      if (f == NULL) continue;
      const size_t got = fread(buf, 1, sizeof buf - 1, f);
      fclose(f);
      buf[got] = 0;
      const char *rp = strrchr(buf, 41); /* the last close paren: the command name may hold spaces and parens */
      int ppid = 0;
      if (rp != NULL && sscanf(rp + 1, " %*c %d", &ppid) == 1 && ppid == (int)out[k]) out[n++] = p;
    }
    closedir(d);
#endif
  }
  return n;
}
/* Ask every process of the test's tree for its dump, one after the other, into the capture file at
   `path`; on Linux append each thread's state and kernel wait channel too. */
static void sc_diag_request(pid_t root, const char *path, unsigned limit) {
  FILE *cap = fopen(path, "ab");
  if (cap != NULL) {
    fprintf(cap, "\n--- the test ran past its timeout (%u s): the state of each of its processes\n", limit);
    fclose(cap);
  }
  pid_t tree[SC_DIAG_TREE];
  const int n = sc_tree(root, tree);
  struct timespec pause = { 0, 400000000 };
  for (int k = 0; k < n; k++) {
    kill(tree[k], SIGURG);
    nanosleep(&pause, NULL);
  }
#if defined(__linux__)
  cap = fopen(path, "ab");
  if (cap == NULL) return;
  for (int k = 0; k < n; k++) {
    char tp[64], comm[64] = "";
    snprintf(tp, sizeof tp, "/proc/%d/comm", (int)tree[k]);
    FILE *f = fopen(tp, "rb");
    if (f != NULL) {
      if (fgets(comm, sizeof comm, f) == NULL) comm[0] = 0;
      fclose(f);
      comm[strcspn(comm, "\n")] = 0;
    }
    fprintf(cap, "--- kernel: process %d (%s), thread state and wait channel\n", (int)tree[k], comm);
    snprintf(tp, sizeof tp, "/proc/%d/task", (int)tree[k]);
    DIR *d = opendir(tp);
    if (d == NULL) continue;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
      const int tid = atoi(e->d_name);
      if (tid <= 0) continue;
      char sp[96], st[512] = "", wc[96] = "";
      snprintf(sp, sizeof sp, "/proc/%d/task/%d/stat", (int)tree[k], tid);
      f = fopen(sp, "rb");
      if (f != NULL) {
        if (fgets(st, sizeof st, f) == NULL) st[0] = 0;
        fclose(f);
      }
      snprintf(sp, sizeof sp, "/proc/%d/task/%d/wchan", (int)tree[k], tid);
      f = fopen(sp, "rb");
      if (f != NULL) {
        if (fgets(wc, sizeof wc, f) == NULL) wc[0] = 0;
        fclose(f);
      }
      const char *rp = strrchr(st, 41); /* the last close paren, as above */
      fprintf(cap, "  %d %c %s\n", tid, rp != NULL && rp[1] == ' ' ? rp[2] : '?', wc[0] ? wc : "-");
    }
    closedir(d);
  }
  fclose(cap);
#endif
}
/* Kill the test's whole tree: a hung grandchild would otherwise outlive the run. */
static void sc_kill_tree(pid_t root) {
  pid_t tree[SC_DIAG_TREE];
  const int n = sc_tree(root, tree);
  for (int k = n - 1; k >= 0; k--) kill(tree[k], SIGKILL);
}
/* The parent's tick: SIGALRM every second while a timeout applies, without SA_RESTART, so wait(2) returns
   and the runner checks the deadlines. */
static void sc_runner_tick(int sig) {
  (void)sig;
  alarm(1);
}
static double sc_runner_now(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec + (double)t.tv_nsec / 1e9;
}
#endif
/* A token the runner cannot hand back would shrink the process tree's budget for good: stop, and say why. */
static void sc_runner_give_back(void) {
  if (sc_runner_jobserver_release()) return;
  fprintf(stderr, "test runner: cannot return a jobserver token\n");
  exit(101);
}

)".ptr() as *const char;
}

// The runner helpers both platforms share: name filter, environment and working-directory
// snapshots for the in-process leg, capture reading and the failure report. The includes map the
// sc_environ/sc_getcwd/sc_chdir/sc_setenv/sc_unsetenv names to each platform's C runtime.
const fn test_runner_common() *const char {
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
  char *d = sc_getcwd(NULL, 0);
  if (!d) { perror("getcwd"); exit(101); }
  return d;
}
static int sc_chdir_back(const char *d) { return sc_chdir(d); }
static char **sc_env_snapshot(void) {
  int n = 0;
  while (sc_environ[n]) n++;
  char **snap = malloc(((size_t)n + 1) * sizeof *snap);
  if (!snap) { perror("malloc"); exit(101); }
  for (int i = 0; i < n; i++) snap[i] = sc_strdup(sc_environ[i]);
  snap[n] = NULL;
  return snap;
}
static void sc_env_restore(char **snap) {
  /* unsetting a variable compacts the environment, so the index only advances past kept entries */
  for (int i = 0; sc_environ[i];) {
    const char *eq = strchr(sc_environ[i], '=');
    const size_t nl = eq ? (size_t)(eq - sc_environ[i]) : strlen(sc_environ[i]);
    int keep = 0;
    for (int k = 0; snap[k] && !keep; k++) keep = !strncmp(snap[k], sc_environ[i], nl) && snap[k][nl] == '=';
    if (keep) { i++; continue; }
    char *name = sc_strdup(sc_environ[i]);
    name[nl] = 0;
    sc_unsetenv(name);
    free(name);
  }
  for (int k = 0; snap[k]; k++) {
    char *eq = strchr(snap[k], '=');
    if (eq) {
      *eq = 0;
      const char *cur = getenv(snap[k]);
      if (!cur || strcmp(cur, eq + 1)) sc_setenv(snap[k], eq + 1);
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
/* Test durations, one `<seconds>\t<name>` line per test (`#` starts a comment): read by `--weights` to
   balance the shards, merged by `--record` with what this run measured (sc_dur, -1: not run). */
static double sc_dur[SC_NTESTS > 0 ? SC_NTESTS : 1];
static double sc_known[SC_NTESTS > 0 ? SC_NTESTS : 1];
static int sc_index_cmp(const void *a, const void *b) {
  return strcmp(SC_TESTS[*(const int *)a].name, SC_TESTS[*(const int *)b].name);
}
/* Fill sc_known from `path` (-1 for a test the file does not name); 0 when the file cannot be read. */
static int sc_read_durations(const char *path) {
  for (int i = 0; i < SC_NTESTS; i++) sc_known[i] = -1;
  FILE *f = path ? fopen(path, "rb") : NULL;
  if (!f) return 0;
  static int by_name[SC_NTESTS > 0 ? SC_NTESTS : 1];
  for (int i = 0; i < SC_NTESTS; i++) by_name[i] = i;
  qsort(by_name, (size_t)SC_NTESTS, sizeof by_name[0], sc_index_cmp);
  char line[1024];
  while (fgets(line, sizeof line, f)) {
    if (line[0] == '#') continue;
    char *tab = strchr(line, '\t');
    if (!tab) continue;
    *tab = 0;
    char *name = tab + 1;
    name[strcspn(name, "\r\n")] = 0;
    int lo = 0, hi = SC_NTESTS - 1;
    while (lo <= hi) {
      const int mid = (lo + hi) / 2;
      const int c = strcmp(SC_TESTS[by_name[mid]].name, name);
      if (c == 0) { sc_known[by_name[mid]] = atof(line); break; }
      if (c < 0) lo = mid + 1; else hi = mid - 1;
    }
  }
  fclose(f);
  return 1;
}
static int sc_weight_cmp_desc(const void *a, const void *b) {
  const int x = *(const int *)a, y = *(const int *)b;
  if (sc_known[x] != sc_known[y]) return sc_known[x] < sc_known[y] ? 1 : -1;
  return x - y;
}
/* The tests of shard `shard` of `shards` among those `filter` matches, in table order. Without durations
   the matches are dealt round-robin; with them (`weights`, a file sc_read_durations reads) each match, the
   longest first, goes to the shard with the least time so far (ties: the lowest shard), and a test the
   file does not name counts as the median known duration. Every shard computes the same assignment. */
static int sc_select(const char *filter, int shard, int shards, const char *weights, int *sel) {
  static int m[SC_NTESTS > 0 ? SC_NTESTS : 1];
  int nm = 0;
  for (int i = 0; i < SC_NTESTS; i++)
    if (sc_match(SC_TESTS[i].name, filter)) m[nm++] = i;
  int nsel = 0;
  if (shards <= 1 || !sc_read_durations(weights)) {
    for (int k = 0; k < nm; k++)
      if (k % shards == shard - 1) sel[nsel++] = m[k];
    return nsel;
  }
  static double known[SC_NTESTS > 0 ? SC_NTESTS : 1];
  int nk = 0;
  for (int k = 0; k < nm; k++)
    if (sc_known[m[k]] >= 0) known[nk++] = sc_known[m[k]];
  double median = 1;
  if (nk > 0) {
    for (int a = 1; a < nk; a++) /* insertion sort: at most one pass per run */
      for (int b = a; b > 0 && known[b - 1] > known[b]; b--) {
        const double t = known[b];
        known[b] = known[b - 1];
        known[b - 1] = t;
      }
    median = known[nk / 2];
  }
  for (int k = 0; k < nm; k++)
    if (sc_known[m[k]] < 0) sc_known[m[k]] = median;
  qsort(m, (size_t)nm, sizeof m[0], sc_weight_cmp_desc);
  double *load = calloc((size_t)shards, sizeof *load);
  if (!load) { perror("calloc"); exit(101); }
  static unsigned char mine[SC_NTESTS > 0 ? SC_NTESTS : 1];
  for (int k = 0; k < nm; k++) {
    int best = 0;
    for (int s = 1; s < shards; s++)
      if (load[s] < load[best]) best = s;
    load[best] += sc_known[m[k]];
    mine[m[k]] = best == shard - 1;
  }
  free(load);
  for (int i = 0; i < SC_NTESTS; i++)
    if (sc_match(SC_TESTS[i].name, filter) && mine[i]) sel[nsel++] = i;
  return nsel;
}
/* Merge this run's durations into `path`: a test that ran gets its new time, one that did not keeps its
   old one, and a name the suite no longer has is dropped. Written whole through a temp file, sorted by
   name so the file diffs line by line. */
static void sc_write_durations(const char *path) {
  sc_read_durations(path);
  static int by_name[SC_NTESTS > 0 ? SC_NTESTS : 1];
  for (int i = 0; i < SC_NTESTS; i++) by_name[i] = i;
  qsort(by_name, (size_t)SC_NTESTS, sizeof by_name[0], sc_index_cmp);
  char tmp[4096];
  snprintf(tmp, sizeof tmp, "%s.tmp", path);
  FILE *f = fopen(tmp, "wb");
  if (!f) { perror(tmp); return; }
  fprintf(f, "# super-c test --test-record-durations: seconds per test, read to balance --test-shard\n");
  for (int k = 0; k < SC_NTESTS; k++) {
    const int i = by_name[k];
    const double s = sc_dur[i] >= 0 ? sc_dur[i] : sc_known[i];
    if (s >= 0) fprintf(f, "%.2f\t%s\n", s, SC_TESTS[i].name);
  }
  if (fclose(f) != 0) { perror(tmp); remove(tmp); return; }
  remove(path); /* rename over an existing file fails on Windows */
  if (rename(tmp, path) != 0) perror(path);
}
/* The slowest tests of a forked run, longest first: what a timeout (`--timeout`, `@test(timeout = N)`)
   must leave room for on the machine that ran them. */
#define SC_SLOWEST 5
static int sc_slow_test[SC_SLOWEST];
static double sc_slow_secs[SC_SLOWEST];
static int sc_slow_n;
static void sc_note_duration(int ti, double secs) {
  sc_dur[ti] = secs;
  int k;
  if (sc_slow_n < SC_SLOWEST) k = sc_slow_n++;
  else if (secs <= sc_slow_secs[SC_SLOWEST - 1]) return;
  else k = SC_SLOWEST - 1;
  while (k > 0 && sc_slow_secs[k - 1] < secs) {
    sc_slow_test[k] = sc_slow_test[k - 1];
    sc_slow_secs[k] = sc_slow_secs[k - 1];
    k--;
  }
  sc_slow_test[k] = ti;
  sc_slow_secs[k] = secs;
}
static void sc_report_slowest(void) {
  if (sc_slow_n == 0) return;
  printf("\nslowest tests:\n");
  for (int k = 0; k < sc_slow_n; k++) printf("  %7.2f s  %s\n", sc_slow_secs[k], SC_TESTS[sc_slow_test[k]].name);
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
)".ptr() as *const char;
}

// The fixed part of the generated test runner: option parsing, fork-per-test isolation with a waitpid job
// pool bounded by the inherited process-tree jobserver, an in-process fallback (--no-fork), substring
// selection, per-test reporting, and the exit code.
// Each forked child writes to its own capture file, so a test's output is attributed to that test rather
// than interleaved with the pool's. The captured text is replayed only for tests that fail, in a
// `failures:` section after the run; `--quiet` also drops the per-test `ok` lines.
const fn test_runner_main_posix() *const char {
    return M"(/* One line on how a failed test's process ended, from its wait status. */
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
  signal(SIGABRT, sc_runner_abort);
  int jobs = 0, no_fork = 0, quiet = 0, shard = 1, shards = 1, timeout = 0;
  const char *filter = NULL, *weights = NULL, *record = NULL;
  for (int i = 1; i < argc; i++) {
    if (!strncmp(argv[i], "--jobs=", 7)) jobs = atoi(argv[i] + 7);
    else if (!strcmp(argv[i], "--no-fork")) no_fork = 1;
    else if (!strcmp(argv[i], "--quiet")) quiet = 1;
    else if (!strncmp(argv[i], "--timeout=", 10)) timeout = atoi(argv[i] + 10);
    else if (!strncmp(argv[i], "--weights=", 10)) weights = argv[i] + 10;
    else if (!strncmp(argv[i], "--record=", 9)) record = argv[i] + 9;
    else if (!strncmp(argv[i], "--filter=", 9)) filter = argv[i] + 9;
    else if (!strncmp(argv[i], "--shard=", 8)) {
      char tail;
      if (sscanf(argv[i] + 8, "%d/%d%c", &shard, &shards, &tail) != 2 || shard < 1 || shard > shards) {
        fprintf(stderr, "invalid test shard: expected K/N with 1 <= K <= N\n");
        return 2;
      }
    } else { /* a misspelled option must not quietly run the whole suite */
      fprintf(stderr, "unknown test runner argument '%s': expected --filter=S, --shard=K/N, --jobs=N, --timeout=S, --weights=F, --record=F, --quiet or --no-fork\n", argv[i]);
      return 2;
    }
  }
  if (jobs < 1) jobs = sc_runner_ncpu();
  int sel[SC_NTESTS > 0 ? SC_NTESTS : 1];
  for (int i = 0; i < SC_NTESTS; i++) sc_dur[i] = -1;
  const int nsel = sc_select(filter, shard, shards, weights, sel);
  if (shards > 1)
    printf("running %d test%s (shard %d/%d)\n", nsel, nsel == 1 ? "" : "s", shard, shards);
  else
    printf("running %d test%s\n", nsel, nsel == 1 ? "" : "s");
  void *genv = NULL;
  if (nsel > 0) genv = sc_genv_init();
  int passed = 0, failed = 0, skipped = 0, ticking = 0;
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
      errno = 0;
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
    /* Each child's deadline: its own `@test(timeout = N)`, else the run's --timeout (0: none). */
    double start_of[SC_NTESTS > 0 ? SC_NTESTS : 1];
    char *cpath_of[SC_NTESTS > 0 ? SC_NTESTS : 1];
    double diag_of[SC_NTESTS > 0 ? SC_NTESTS : 1];
    unsigned limit_of[SC_NTESTS > 0 ? SC_NTESTS : 1];
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
        char cpath[1024];
        FILE *cap = sc_cap_open(cpath, sizeof cpath);
        if (!cap) {
          if (token) sc_runner_give_back();
          perror("mkstemp");
          return 101;
        }
        const pid_t pid = fork();
        if (pid == 0) {
          if (dup2(fileno(cap), 1) < 0 || dup2(fileno(cap), 2) < 0) { perror("dup2"); _exit(101); }
          struct sigaction dfl;
          memset(&dfl, 0, sizeof dfl);
          sigemptyset(&dfl.sa_mask);
          dfl.sa_handler = SIG_DFL;
          sigaction(SIGALRM, &dfl, NULL); /* the parent's tick */
          sc_setenv("SC_TEST_DIAG", cpath);
          __sc_diag_install();
          sc_lk_fork_child_reset();
          errno = 0;
          SC_TESTS[sel[next]].fn(genv);
          fflush(NULL);
          sc_lk_report_now();
          fflush(NULL);
          _exit(0);
        }
        if (pid < 0) {
          if (token) sc_runner_give_back();
          perror("fork");
          return 101;
        }
        pid_of[next] = pid;
        cap_of[next] = cap;
        cpath_of[next] = sc_strdup(cpath);
        token_of[next] = token;
        start_of[next] = sc_runner_now();
        diag_of[next] = 0;
        limit_of[next] = SC_TESTS[sel[next]].timeout ? SC_TESTS[sel[next]].timeout : (unsigned)(timeout > 0 ? timeout : 0);
        if (limit_of[next] && !ticking) {
          struct sigaction sa;
          memset(&sa, 0, sizeof sa);
          sigemptyset(&sa.sa_mask);
          sa.sa_handler = sc_runner_tick; /* no SA_RESTART: the tick interrupts wait(2) */
          sigaction(SIGALRM, &sa, NULL);
          alarm(1);
          ticking = 1;
        }
        next++;
        active++;
      }
      /* Past its deadline a child is asked for its state (diag_of > 0), then killed SC_DIAG_GRACE seconds
         later (diag_of < 0); either way it has timed out, also when it ends inside the grace. */
      const double now = sc_runner_now();
      for (int k = 0; k < next; k++) {
        if (pid_of[k] < 0 || !limit_of[k] || diag_of[k] < 0) continue;
        if (diag_of[k] == 0 && now - start_of[k] >= limit_of[k]) {
          sc_diag_request(pid_of[k], cpath_of[k], limit_of[k]);
          diag_of[k] = sc_runner_now();
        } else if (diag_of[k] > 0 && now - diag_of[k] >= SC_DIAG_GRACE) {
          sc_kill_tree(pid_of[k]);
          diag_of[k] = -1;
        }
      }
      int st = 0;
      const pid_t done = wait(&st);
      if (done < 0) {
        if (errno == EINTR) continue;
        perror("wait");
        return 101;
      }
      int ti = -1;
      FILE *cap = NULL;
      int token = 0;
      unsigned timed_out = 0;
      double began = 0;
      char *cpath = NULL;
      for (int k = 0; k < next; k++)
        if (pid_of[k] == done) {
          ti = sel[k];
          began = start_of[k];
          cpath = cpath_of[k];
          cap = cap_of[k];
          token = token_of[k];
          timed_out = diag_of[k] != 0 ? limit_of[k] : 0; /* past its deadline, killed or not */
          pid_of[k] = -1;
          break;
        }
      if (ti < 0) continue; /* a child the global env started, not a test */
      active--;
      if (shared) {
        if (token) {
          sc_runner_give_back();
        } else {
          implicit_available = 1;
        }
      }
      sc_note_duration(ti, sc_runner_now() - began);
      const int crashed = !(WIFEXITED(st) && WEXITSTATUS(st) == 0);
      if (timed_out) {
        printf("test %s ... FAILED (timed out)\n", SC_TESTS[ti].name);
        char why[64];
        snprintf(why, sizeof why, "timed out after %u s", timed_out);
        fail_test[failed] = ti;
        fail_out[failed] = sc_slurp(cap);
        fail_why[failed] = sc_strdup(why);
        failed++;
      } else if (crashed == SC_TESTS[ti].should_panic) {
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
      remove(cpath);
      free(cpath);
      fflush(stdout);
    }
  }
  if (ticking) alarm(0);
  if (genv) sc_genv_free(genv);
  if (failed) sc_report_failures(failed, fail_test, fail_out, fail_why);
  sc_report_slowest();
  if (record) sc_write_durations(record);
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
    return M"(/* One line on how a failed test's process ended, from its exit code. */
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
  signal(SIGABRT, sc_runner_abort);
  const char *filter = NULL, *capture = NULL, *weights = NULL, *record = NULL;
  int run_one = -1, no_fork = 0, quiet = 0, jobs = 0, shard = 1, shards = 1, timeout = 0;
  for (int i = 1; i < argc; i++) {
    if (!strncmp(argv[i], "--run-one=", 10)) run_one = atoi(argv[i] + 10);
    else if (!strncmp(argv[i], "--capture=", 10)) capture = argv[i] + 10;
    else if (!strncmp(argv[i], "--jobs=", 7)) jobs = atoi(argv[i] + 7);
    else if (!strcmp(argv[i], "--no-fork")) no_fork = 1;
    else if (!strcmp(argv[i], "--quiet")) quiet = 1;
    else if (!strncmp(argv[i], "--timeout=", 10)) timeout = atoi(argv[i] + 10);
    else if (!strncmp(argv[i], "--weights=", 10)) weights = argv[i] + 10;
    else if (!strncmp(argv[i], "--record=", 9)) record = argv[i] + 9;
    else if (!strncmp(argv[i], "--filter=", 9)) filter = argv[i] + 9;
    else if (!strncmp(argv[i], "--shard=", 8)) {
      char tail;
      if (sscanf(argv[i] + 8, "%d/%d%c", &shard, &shards, &tail) != 2 || shard < 1 || shard > shards) {
        fprintf(stderr, "invalid test shard: expected K/N with 1 <= K <= N\n");
        return 2;
      }
    } else { /* a misspelled option must not quietly run the whole suite */
      fprintf(stderr, "unknown test runner argument '%s': expected --filter=S, --shard=K/N, --jobs=N, --timeout=S, --weights=F, --record=F, --quiet or --no-fork\n", argv[i]);
      return 2;
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
    errno = 0;
    SC_TESTS[run_one].fn(genv);
    if (genv) sc_genv_free(genv);
    return 0;
  }
  int sel[SC_NTESTS > 0 ? SC_NTESTS : 1];
  for (int i = 0; i < SC_NTESTS; i++) sc_dur[i] = -1;
  const int nsel = sc_select(filter, shard, shards, weights, sel);
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
      errno = 0;
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
    /* Each child's deadline, as on POSIX; a late child is terminated (no state dump: no signals here). */
    ULONGLONG running_start[MAXIMUM_WAIT_OBJECTS];
    unsigned running_limit[MAXIMUM_WAIT_OBJECTS];
    int running_late[MAXIMUM_WAIT_OBJECTS];
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
          if (token) sc_runner_give_back();
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
        running_start[active] = GetTickCount64();
        running_limit[active] = SC_TESTS[i].timeout ? SC_TESTS[i].timeout : (unsigned)(timeout > 0 ? timeout : 0);
        running_late[active] = 0;
        active++;
      }
      if (active == 0) continue;
      int limited = 0;
      for (int k = 0; k < active; k++) limited |= running_limit[k] != 0;
      const DWORD w = WaitForMultipleObjects((DWORD)active, running, FALSE, limited ? 1000 : INFINITE);
      if (w == WAIT_TIMEOUT) {
        const ULONGLONG now = GetTickCount64();
        for (int k = 0; k < active; k++)
          if (running_limit[k] && !running_late[k] && now - running_start[k] >= (ULONGLONG)running_limit[k] * 1000) {
            TerminateProcess(running[k], 1);
            running_late[k] = 1;
          }
        continue;
      }
      const DWORD slot = w - WAIT_OBJECT_0;
      if (w == WAIT_FAILED || slot >= (DWORD)active) {
        fprintf(stderr, "WaitForMultipleObjects failed (error %lu)\n", (unsigned long)GetLastError());
        return 101;
      }
      DWORD code = 1;
      GetExitCodeProcess(running[slot], &code);
      CloseHandle(running[slot]);
      const int ti = running_test[slot];
      const int token = running_token[slot];
      const unsigned timed_out = running_late[slot] ? running_limit[slot] : 0;
      sc_note_duration(ti, (double)(GetTickCount64() - running_start[slot]) / 1000.0);
      running[slot] = running[active - 1]; /* the pool is unordered: backfill from the end */
      running_test[slot] = running_test[active - 1];
      running_token[slot] = running_token[active - 1];
      running_start[slot] = running_start[active - 1];
      running_limit[slot] = running_limit[active - 1];
      running_late[slot] = running_late[active - 1];
      active--;
      if (shared) {
        if (token) {
          sc_runner_give_back();
        } else {
          implicit_available = 1;
        }
      }
      const int crashed = (code != 0);
      char cappath[MAX_PATH];
      sc_cap_path(cappath, sizeof cappath, tmpdir, ti);
      if (!timed_out && crashed == SC_TESTS[ti].should_panic) {
        if (!quiet) printf("test %s ... ok%s\n", SC_TESTS[ti].name, SC_TESTS[ti].should_panic ? " (panicked as expected)" : "");
        passed++;
      } else {
        printf("test %s ... FAILED%s\n", SC_TESTS[ti].name, timed_out ? " (timed out)" : SC_TESTS[ti].should_panic ? " (expected a panic)" : "");
        FILE *cap = fopen(cappath, "rb");
        fail_test[failed] = ti;
        fail_out[failed] = sc_slurp(cap);
        if (timed_out) {
          char why[64];
          snprintf(why, sizeof why, "timed out after %u s", timed_out);
          fail_why[failed] = sc_strdup(why);
        } else {
          fail_why[failed] = sc_why_win(code, SC_TESTS[ti].should_panic);
        }
        if (cap) fclose(cap);
        failed++;
      }
      remove(cappath);
      fflush(stdout);
    }
  }
  if (genv) sc_genv_free(genv);
  if (failed) sc_report_failures(failed, fail_test, fail_out, fail_why);
  sc_report_slowest();
  if (record) sc_write_durations(record);
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
        "/* generated by super-c --test */\n#if defined(__linux__) && !defined(_GNU_SOURCE)\n#define _GNU_SOURCE\n#endif\n#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)\n#define _DARWIN_C_SOURCE\n#endif\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n".ptr() as *const char,
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
        "\ntypedef void (*sc_test_fn)(void *);\nstatic const struct { const char *name; sc_test_fn fn; int should_panic; unsigned timeout; } SC_TESTS[] = {\n".ptr() as *const char,
        f,
    );
    for ci in 0..plan.cases.len() {
        let tc = plan.cases[ci];
        let a = p.module_ast_const(tc.mod);
        let nmnode = unsafe (*a).at_const(tc.func).as_data.function.name;
        let nm = unsafe (*a).at_const(nmnode).as_data.name.text;
        let modpath = p.modules[tc.mod as usize].path.as_str();
        let msrc = p.modules[tc.mod as usize].source.as_str().ptr() as *const char;
        unsafe stdio::fprintf(f, "  { \"%.*s::".ptr() as *const char, modpath.len() as i32, modpath.ptr());
        if tc.suite.node != NODE_NONE {
            let sa = p.module_ast_const(tc.suite.module);
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
            "%.*s\", __sc_test_w_%u_%u, %d, %uu },\n".ptr() as *const char,
            (nm.end - nm.start) as i32,
            unsafe (msrc + nm.start as usize),
            tc.mod as u32,
            tc.func,
            spflag,
            tc.timeout,
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
    unsafe stdio::fputs(test_runner_common(), f);
    unsafe stdio::fputs("#ifdef _WIN32\n".ptr() as *const char, f);
    unsafe stdio::fputs(test_runner_main_win(), f);
    unsafe stdio::fputs("#else\n".ptr() as *const char, f);
    unsafe stdio::fputs(test_runner_main_posix(), f);
    unsafe stdio::fputs("#endif\n".ptr() as *const char, f);
    unsafe stdio::fclose(f);
    return Option::<String>::Some(path);
}

/// Append the `@c.link` flags of the `__ldflags` file `path` (one flag string per line, split on
/// whitespace) to `args`; a missing file adds nothing.
pub fn push_ldflags(args: &mut Vector<String>, path: str) {
    let lf = loader::read_file(path);
    if lf.is_none() {
        return;
    }
    let body = lf.unwrap();
    let s = body.as_str();
    let mut a: usize = 0;
    for b in 0..s.len() + 1 {
        if b == s.len() || s[b] == b'\n' {
            split_args(args, s.slice(a, b));
            a = b + 1;
        }
    }
}

/// Compile the emitted build tree with $CC. When `out_bin` is set (the `build` subcommand) the program is
/// linked to that path and nothing runs; otherwise it links `<gen_root>/__tests` and runs it as the test
/// runner, forwarding `topts`' options. With the object cache on, each unit compiles on its own with the
/// compile side of the profile's flags (`ccflags`) through the script namespace
/// (`objcache::compile_units`), so a unit another script build already compiled is copied, and the
/// link takes the objects with the whole flag set (`cflags`); with it off (SC_NO_CACHE) one command
/// compiles and links. Returns the compile's or the runner's exit code.
pub fn test_build_and_run(
    p: &loader::Package,
    topts: *const TestOpts,
    keep: &Vector<String>,
    out_bin: str,
    cflags: str,
    ccflags: str,
    target: i32,
) i32 {
    // A cross target brings its own compiler: $CC on the host would build a host binary while the front end
    // gated items on `--target=`, with no diagnostic.
    let sdk = target_sdk(target);
    let ccs = resolve_cc(p.cc.as_str(), sdk);
    let root = p.gen_root.as_str();
    // No shell anywhere: the compile is an argv child, so paths pass through verbatim (spaces, quotes,
    // non-ASCII) while flag strings are split on whitespace. The runner is named with an explicit `.exe`
    // on Windows so running it below never depends on the spawn filling the extension in.
    let exe = if unsafe shim::sc_host_platform() == 0 {
        ".exe";
    } else {
        "";
    };
    let what = if out_bin.len() != 0 {
        "build";
    } else {
        "test build";
    };
    let base = "-std=c11 -D_POSIX_C_SOURCE=200809L -funsigned-char -ffp-contract=off -Werror=incompatible-pointer-types";
    // The cross triple comes first so the profile's flags (empty for a bare build) can override it.
    let mut fl = String::new();
    push_sdk_flags(&mut fl, sdk, p.arch, p.features);
    let mut pfl = String::from_str(base);
    pfl.push_str(fl.as_str());
    pfl.push_byte(b' ');
    pfl.push_str(ccflags);
    if !bsys::features_accepted(loader::dirname_of(root), ccs.as_str(), pfl.as_str(), target, p.arch, p.features) {
        return 1;
    }
    let mut args = Vector::<String>::new();
    split_args(&mut args, ccs.as_str());
    let croot = ocache::object_cache_dir();
    let mut objs = Vector::<String>::new();
    if croot.len() != 0 {
        let mut ccv = Vector::<String>::new();
        split_args(&mut ccv, ccs.as_str());
        let mut cfv = Vector::<String>::new();
        split_args(&mut cfv, base);
        split_args(&mut cfv, fl.as_str());
        split_args(&mut cfv, ccflags);
        let mut units = Vector::<String>::new();
        for i in 0..keep.len() {
            let cf = keep[i].as_str();
            if cf.len() > 2 && cf.ends_with(".c") {
                units.push(String::from_str(cf));
            }
        }
        let ns = ocache::script_ns(croot.as_str());
        let crc = ocache::compile_units(&ccv, &cfv, root, &units, ns.as_str(), &mut objs);
        if crc != 0 {
            eprintln("super-c: {} failed ({})", what, ccs.as_str());
            return 1;
        }
    }
    split_args(&mut args, base);
    split_args(&mut args, fl.as_str());
    split_args(&mut args, cflags);
    // The link-only SDK libs ride along on the command that links.
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
    if croot.len() != 0 {
        for i in 0..objs.len() {
            args.push(objs.at(i).clone());
        }
    } else {
        for i in 0..keep.len() {
            let cf = keep[i].as_str();
            if cf.len() > 2 && cf.ends_with(".c") {
                args.push(String::from_str(cf));
            }
        }
    }
    let ldpath = build_out_path(root, "__ldflags", "");
    push_ldflags(&mut args, ldpath.as_str());
    let brc = exec_args(&mut args, null);
    if brc != 0 {
        eprintln("super-c: {} failed ({})", what, ccs.as_str());
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
    if unsafe (*topts).jobs > 0 {
        let mut jb = Buf64 {};
        unsafe stdio::snprintf(&mut jb[0], 64, "--jobs=%d".ptr() as *const char, unsafe (*topts).jobs);
        run.push(String::from_cstr(&jb[0]));
    }
    if unsafe (*topts).no_fork {
        run.push(String::from_str("--no-fork"));
    }
    if unsafe (*topts).quiet {
        run.push(String::from_str("--quiet"));
    }
    if unsafe (*topts).filter != null {
        let mut fs = String::from_str("--filter=");
        fs.push_str(str::from_cstr(unsafe (*topts).filter));
        run.push(fs);
    }
    let mut tb = Buf64 {};
    let tsec = if unsafe (*topts).timeout < 0 {
        DEFAULT_TEST_TIMEOUT;
    } else {
        unsafe (*topts).timeout;
    };
    unsafe stdio::snprintf(&mut tb[0], 64, "--timeout=%d".ptr() as *const char, tsec);
    run.push(String::from_cstr(&tb[0]));
    let dur = unsafe (*topts).durations;
    if dur != null {
        // The shards balance by the recorded durations when the file exists; a recording run writes it.
        if unsafe shim::sc_mtime(dur) != 0 {
            let mut w = String::from_str("--weights=");
            w.push_str(str::from_cstr(dur));
            run.push(w);
        }
        if unsafe (*topts).record {
            let mut r = String::from_str("--record=");
            r.push_str(str::from_cstr(dur));
            run.push(r);
        }
    }
    if unsafe (*topts).shards > 0 {
        let mut sb = Buf64 {};
        unsafe stdio::snprintf(
            &mut sb[0],
            64,
            "--shard=%d/%d".ptr() as *const char,
            unsafe (*topts).shard,
            unsafe (*topts).shards,
        );
        run.push(String::from_cstr(&sb[0]));
    }
    unsafe shim::sc_jobserver_release_claim();
    let rrc = exec_args(&mut run, null);
    if rrc < 0 {
        eprintln("super-c: cannot run the test runner '{}'", bin);
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
            suites: Vector::<TestSuite>::new(),
            genv_mod: 0,
            genv_init: NODE_NONE,
            genv_free: NODE_NONE,
            genv_type: DefId { module: 0, node: NODE_NONE },
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
        }
        return pl;
    }

    // Index of the (module, type) suite in plan.suites, creating it when `create`; -1 when absent / no-create.
    fn suite_of(self: &mut Self, m: ModuleId, ty: DefId, create: bool) i32 {
        for i in 0..self.suites.len() {
            let s = self.suites.at(i);
            if s.mod == m && s.ty.module == ty.module && s.ty.node == ty.node {
                return i as i32;
            }
        }
        if !create {
            return -1;
        }
        self.suites.push(TestSuite { mod: m, ty: ty, init: NODE_NONE, fre: NODE_NONE });
        return (self.suites.len() - 1) as i32;
    }
}
