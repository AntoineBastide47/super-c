// The --test pipeline: collects every @test/@test_init/@test_free into a validated TestPlan (consumed by
// codegen's per-module wrapper emission), writes the test table and the `main` that hands it to the
// runner (build/__test_main.c; the runner is std/rt/test.spc), and compiles + runs the emitted build tree
// with $CC. test_build_and_run doubles as the `build`
// subcommand's link step when `out_bin` is set.
import stdio;
import target::table as tgt;
import time;
import string as cstring;
import lexer::token as tok;
import lexer::lexer as lex;
import ast::ast as *;
import ast::parser as par;
import fmt::builder as fbld;
import driver_shim as shim;
import std::platform::fs;
import std::platform::env;
import module::loader as loader;
import resolver::resolver as resolver;
import typechecker::typechecker as tc;
import utils::errors as diag;
import driver::util as *;
import build_system::objcache as ocache;
import build_system::build as bsys;
import build_system::manifest as bman;

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
    pub durations: *const char, // the duration file: --test-durations, else (`super-c test`) <test dir>/durations.tsv; null: none
    pub record: bool, // --test-record-durations: merge this run's durations into `record_to`, else `durations`
    pub record_to: *const char, // --test-record-durations=F: F; null: `durations`
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
            if ext == NODE_NONE && p.is_entry(m as ModuleId, at.owner) {
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

/// Write build/__test_main.c: extern wrapper prototypes, the test table (display names `module::fn` or
/// `module::Type::method`, wrappers, `should_panic` flags, timeouts), the global-env hooks (stubs when
/// absent), and the `main` that hands them to the runner (`sc_test_main`, std/rt/test.spc), published with
/// `publish_file` (`fresh`: this build rewrote it). Returns the path (ownership to the caller /
/// keep-list), or None when the file cannot be written.
pub fn write_test_main(p: &mut loader::Package, plan: &TestPlan, fresh: &mut bool) Option<String> {
    let mut path = build_out_path(p.gen_root.as_str(), "__test_main", ".c");
    let mut o = String::from_str("/* generated by super-c --test */\n");
    for ci in 0..plan.cases.len() {
        let tc = plan.cases[ci];
        o.format_into("extern void __sc_test_w_{}_{}(void *);\n", tc.mod as u32, tc.func);
    }
    o.push_str("\nstatic const char *const SC_NAMES[] = {\n");
    for ci in 0..plan.cases.len() {
        let tc = plan.cases[ci];
        let a = p.module_ast_const(tc.mod);
        let nmnode = unsafe (*a).at_const(tc.func).as_data.function.name;
        let nm = unsafe (*a).at_const(nmnode).as_data.name.text;
        o.push_str("  \"");
        o.push_str(p.modules[tc.mod as usize].path.as_str());
        o.push_str("::");
        if tc.suite.node != NODE_NONE {
            let sa = p.module_ast_const(tc.suite.module);
            let snmn = unsafe (*sa).at_const(tc.suite.node).as_data.aggregate.name;
            let snm = unsafe (*sa).at_const(snmn).as_data.name.text;
            o.push_str(p.modules[tc.suite.module as usize].source.as_str().slice(snm.start as usize, snm.end as usize));
            o.push_str("::");
        }
        o.push_str(p.modules[tc.mod as usize].source.as_str().slice(nm.start as usize, nm.end as usize));
        o.push_str("\",\n");
    }
    o.push_str("};\nstatic void (*const SC_FNS[])(void *) = {\n");
    for ci in 0..plan.cases.len() {
        let tc = plan.cases[ci];
        o.format_into("  __sc_test_w_{}_{},\n", tc.mod as u32, tc.func);
    }
    o.push_str("};\nstatic const unsigned char SC_PANICS[] = {");
    for ci in 0..plan.cases.len() {
        o.format_into(" {},", plan.cases[ci].should_panic as i32);
    }
    o.push_str(" };\nstatic const unsigned SC_TIMEOUTS[] = {");
    for ci in 0..plan.cases.len() {
        o.format_into(" {}u,", plan.cases[ci].timeout);
    }
    o.push_str(" };\n\n");
    if plan.genv_init != NODE_NONE {
        o.push_str(
            "extern void *__sc_test_genv_init(void);\nextern void __sc_test_genv_free(void *);\nstatic void *sc_genv_init(void) { return __sc_test_genv_init(); }\nstatic void sc_genv_free(void *p) { __sc_test_genv_free(p); }\n",
        );
    } else {
        o.push_str("static void *sc_genv_init(void) { return 0; }\nstatic void sc_genv_free(void *p) { (void)p; }\n");
    }
    o.format_into(
        "\nint sc_test_main(int argc, char **argv, unsigned n, const void *names, const void *fns, const void *panics, const void *timeouts, void *(*genv_init)(void), void (*genv_free)(void *));\nint main(int argc, char **argv) {{\n  return sc_test_main(argc, argv, {}u, SC_NAMES, SC_FNS, SC_PANICS, SC_TIMEOUTS, sc_genv_init, sc_genv_free);\n}}\n",
        plan.cases.len(),
    );
    let rc = publish_file(path.as_str(), o.as_str());
    if rc < 0 {
        unsafe stdio::perror(path.cstr());
        return Option::<String>::None;
    }
    *fresh = rc == 1;
    return Option::<String>::Some(path);
}

/// Append the `@link` flags of the `__ldflags` file `path` (one flag string per line, split on
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

/// Compile `units` (the emitted tree's C files to compile) with $CC. When `out_bin` is set (the `build` subcommand) the program is
/// linked to that path and nothing runs; otherwise it links `<gen_root>/__tests` and runs it as the test
/// runner, forwarding `topts`' options. With the object cache on, each unit compiles on its own with the
/// compile side of the profile's flags (`ccflags`) through the script namespace
/// (`objcache::compile_units`), so a unit another script build already compiled is copied, and the
/// link takes the objects with the whole flag set (`cflags`); with it off (SC_NO_CACHE) one command
/// compiles and links. Returns the compile's or the runner's exit code.
pub fn test_build_and_run(
    p: &loader::Package,
    topts: *const TestOpts,
    units: &Vector<String>,
    out_bin: str,
    cflags: str,
    ccflags: str,
    target: i32,
) i32 {
    // A cross target brings its own compiler: $CC on the host would build a host binary while the front end
    // gated items on `--target=`, with no diagnostic.
    let root = p.gen_root.as_str();
    let ccs = ocache::direct_cc(resolve_cc(p.cc.as_str(), target, p.arch), target, root);
    // No shell anywhere: the compile is an argv child, so paths pass through verbatim (spaces, quotes,
    // non-ASCII) while flag strings are split on whitespace. The runner is named with an explicit `.exe`
    // on Windows so running it below never depends on the spawn filling the extension in.
    let exe = tgt::os(unsafe shim::sc_host_platform()).exe_suffix;
    let what = if out_bin.len() != 0 {
        "build";
    } else {
        "test build";
    };
    // The base C flags and the fixed rules after them, as a manifest build's compile has them.
    let mut basev = String::new();
    bsys::push_c_base(
        &mut basev,
        if p.cstd.len() != 0 {
            p.cstd.as_str();
        } else {
            bman::DEFAULT_CSTD;
        },
        target,
    );
    let base = basev.as_str();
    // The cross triple comes first so the profile's flags (empty for a bare build) can override it.
    let mut fl = String::new();
    push_sdk_flags(&mut fl, target, p.arch, p.features);
    let mut pfl = String::from_str(base);
    pfl.push_str(fl.as_str());
    pfl.push_byte(b' ');
    pfl.push_str(ccflags);
    let mut late = String::new();
    // The link-only SDK libs ride along on the command that links.
    let mut ll = String::new();
    push_sdk_libs(&mut ll, target);
    if !bsys::features_accepted(
        loader::dirname_of(root),
        ccs.as_str(),
        pfl.as_str(),
        bsys::profile_lto(p.profile.as_str()),
        target,
        p.arch,
        p.features,
        &mut fl,
        &mut late,
        &mut ll,
    ) {
        return 1;
    }
    let mut args = Vector::<String>::new();
    split_args(&mut args, ccs.as_str());
    let croot = ocache::object_cache_dir("");
    let mut objs = Vector::<String>::new();
    if croot.len() != 0 {
        let mut ccv = Vector::<String>::new();
        split_args(&mut ccv, ccs.as_str());
        let mut cfv = Vector::<String>::new();
        split_args(&mut cfv, base);
        split_args(&mut cfv, fl.as_str());
        split_args(&mut cfv, ccflags);
        split_args(&mut cfv, late.as_str());
        let ns = ocache::script_ns(croot.as_str());
        let crc = ocache::compile_units(&ccv, &cfv, root, units, ns.as_str(), &mut objs);
        if crc != 0 {
            eprintln("super-c: {} failed ({})", what, ccs.as_str());
            return 1;
        }
    }
    split_args(&mut args, base);
    split_args(&mut args, fl.as_str());
    split_args(&mut args, cflags);
    split_args(&mut args, late.as_str());
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
    let first = args.len();
    if croot.len() != 0 {
        for i in 0..objs.len() {
            args.push(objs.at(i).clone());
        }
    } else {
        for i in 0..units.len() {
            args.push(units.at(i).clone());
        }
    }
    let n = args.len() - first;
    let ldpath = build_out_path(root, "__ldflags", "");
    push_ldflags(&mut args, ldpath.as_str());
    let rsp = loader::join2(root, "__link.rsp");
    let fit = bsys::fit_cmdline(&mut args, first, n, rsp.as_str(), bsys::cmdline_max());
    let brc = if fit < 0 {
        1;
    } else {
        exec_args(&args, "");
    };
    if fit > 0 {
        let _ = fs::unlink(rsp.as_str());
    }
    if brc != 0 {
        eprintln("super-c: {} failed ({})", what, ccs.as_str());
        return 1;
    }
    if bsys::profile_strip(p.profile.as_str(), target) {
        let mut st = Vector::<String>::new();
        st.push(String::from_str("strip"));
        st.push(outp.clone());
        let src = exec_args(&st, "");
        if src != 0 {
            eprintln("super-c: strip failed (exit {}): '{}'", src, outp.as_str());
            return 1;
        }
    }
    bsys::sweep(null, time::now(), false);
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
        run.push(String::from_str(str::from_cbuf(jb.as_slice())));
    }
    if unsafe (*topts).no_fork {
        run.push(String::from_str("--no-fork"));
    }
    if unsafe (*topts).quiet {
        run.push(String::from_str("--quiet"));
    }
    if unsafe (*topts).filter != null {
        let mut fs = String::from_str("--filter=");
        fs.push_str(unsafe str::from_cstr((*topts).filter));
        run.push(fs);
    }
    let mut tb = Buf64 {};
    let tsec = if unsafe (*topts).timeout < 0 {
        DEFAULT_TEST_TIMEOUT;
    } else {
        unsafe (*topts).timeout;
    };
    unsafe stdio::snprintf(&mut tb[0], 64, "--timeout=%d".ptr() as *const char, tsec);
    run.push(String::from_str(str::from_cbuf(tb.as_slice())));
    let dur = unsafe (*topts).durations;
    // The shards balance by the recorded durations when the file exists.
    if dur != null && file_mtime(unsafe str::from_cstr(dur)) != 0 {
        let mut w = String::from_str("--weights=");
        w.push_str(unsafe str::from_cstr(dur));
        run.push(w);
    }
    // A recording run merges its times into its own file when given one, else into the durations file.
    let rec = if unsafe (*topts).record_to != null {
        unsafe (*topts).record_to;
    } else {
        dur;
    };
    if unsafe (*topts).record && rec != null {
        let mut r = String::from_str("--record=");
        r.push_str(unsafe str::from_cstr(rec));
        run.push(r);
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
        run.push(String::from_str(str::from_cbuf(sb.as_slice())));
    }
    unsafe shim::sc_jobserver_release_claim();
    // The LIR check covers the bundle this build lowered; a compile a test runs is a build of its own.
    let _ = unsafe env::unset("SC_LIR");
    let rrc = exec_args(&run, "");
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
