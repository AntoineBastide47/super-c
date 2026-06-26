// Coverage of src/main.c, whose helpers are all static -> exercised by driving the built ./super-c
// binary as a subprocess: argument handling, derive_out_path (extension replace vs append), the
// file-not-found error path, and the REPL. The dev `test` target depends on $(BIN), so the binary
// exists when this runs.

#include "test_harness.h"

#include <unistd.h>

static char SC[4096];          // absolute path to ./super-c
static char DIR[] = "/tmp/sccliXXXXXX"; // sandbox for generated files

static int run_cmd(const char *cmd, char *out, const size_t cap) {
  FILE *p = popen(cmd, "r");
  if (!p)
    return -1;
  const size_t n = (out && cap) ? fread(out, 1, cap - 1, p) : 0;
  if (out && cap)
    out[n] = '\0';
  const int st = pclose(p);
  return WIFEXITED(st) ? WEXITSTATUS(st) : -1;
}

static void write_file(const char *path, const char *contents) {
  FILE *f = fopen(path, "w");
  if (f) {
    fputs(contents, f);
    fclose(f);
  }
}

static void test_compiles_file(void) {
  char spc[4160], out[4170], cmd[8320], buf[256];
  snprintf(spc, sizeof spc, "%s/prog.spc", DIR);
  snprintf(out, sizeof out, "%s/build/prog.c", DIR); // output goes to a flat build/ tree
  write_file(spc, "extern \"C\" { fn exit(code: i32) void; }\nfn main() i32 { exit(7); }\n");

  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  const int rc = run_cmd(cmd, buf, sizeof buf);
  CHECK(rc == 0, "compiling a valid file exits 0 (got %d): %s", rc, buf);
  CHECK(access(out, F_OK) == 0, "module .c is emitted under build/ -> %s", out);

  // the emitted C is real: the whole build/ tree compiles and runs with the program's exit code
  char ccmd[8320], crun[8320];
  char bin[4200];
  snprintf(bin, sizeof bin, "%s/prog.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror %s/build/*.c -o '%s' 2>&1", DIR, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "CLI output compiles: %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 7, "CLI output runs with the right exit code");
}

// A second module's enums used across the boundary: a value return, a payload-less match (bare variant
// arms resolved via the scrutinee's enum), a payload-bearing construction, and a payload match. Drives
// the full multi-file build/ tree (subdirs) through cc + run, locking in the cross-module variant codegen.
static void test_cross_module_enum(void) {
  char root[4112], dir[4128], spc[4170], cmd[8320], buf[256];
  snprintf(root, sizeof root, "%s/xm", DIR); // own project root so its build/ holds only these modules
  snprintf(dir, sizeof dir, "%s/lib", root);
  if (system((snprintf(cmd, sizeof cmd, "mkdir -p '%s'", dir), cmd))) { /* best-effort */
  }
  snprintf(spc, sizeof spc, "%s/lib.spc", dir);
  write_file(spc,
             "pub enum Color { Red, Green = 5, Blue }\n"
             "pub enum Box { Empty, Filled(i32) }\n"
             "pub fn red() Color { return Color::Red; }\n");
  snprintf(spc, sizeof spc, "%s/xm.spc", root);
  write_file(spc,
             "import lib::lib;\n"
             "extern \"C\" { fn exit(code: i32) void; }\n"
             "fn color_code(c: lib::lib::Color) i32 { return switch c { Red => 1, Green => 2, Blue => 3, }; }\n"
             "fn box_amt(b: lib::lib::Box) i32 { return switch b { Filled(n) => n, Empty => -1, }; }\n"
             "fn main() i32 { let c = lib::lib::red(); let b = lib::lib::Box::Filled(20);\n"
             "  exit(color_code(c) + box_amt(b)); }\n");

  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  const int rc = run_cmd(cmd, buf, sizeof buf);
  CHECK(rc == 0, "cross-module enum project compiles (got %d): %s", rc, buf);

  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/xm.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "cross-module enum C compiles: %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 21, "cross-module enum value/match/construct run correctly (1 + 20)");
}

// Write `root/rel` (creating parent dirs); `rel` may contain a subdirectory.
static void mkfile(const char *root, const char *rel, const char *content) {
  char path[4200], cmd[8400];
  snprintf(path, sizeof path, "%s/%s", root, rel);
  char dir[4200];
  snprintf(dir, sizeof dir, "%s", path);
  char *const slash = strrchr(dir, '/');
  if (slash) {
    *slash = '\0';
    snprintf(cmd, sizeof cmd, "mkdir -p '%s'", dir);
    if (system(cmd)) { /* best-effort */
    }
  }
  write_file(path, content);
}

// Compile `DIR/name/main.spc`, asserting a nonzero exit and a diagnostic containing `want`.
static void expect_fail(const char *name, const char *want) {
  char spc[4200], cmd[8400], buf[1024];
  snprintf(spc, sizeof spc, "%s/%s/main.spc", DIR, name);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  const int rc = run_cmd(cmd, buf, sizeof buf);
  CHECK(rc != 0, "%s: nonzero exit on bad program (got %d)", name, rc);
  CHECK_STR_CONTAINS(buf, want);
}

// Cross-module language features (Tier 1): a public const, a public type alias used as a type, qualified
// struct construction `mod::T { .. }`, and a local extension method on an imported type -- built and run.
static void test_module_features(void) {
  char root[4112], spc[4170], cmd[8320], buf[256];
  snprintf(root, sizeof root, "%s/feat", DIR);
  mkfile(root, "lib/lib.spc",
         "pub struct Vec2 { pub x: i32, pub y: i32 }\n"
         "pub type V = Vec2;\n"
         "pub const BASE: i32 = 100;\n"
         "pub fn mk(a: i32, b: i32) Vec2 { return Vec2 { x: a, y: b }; }\n");
  mkfile(root, "feat.spc",
         "import lib::lib;\n"
         "extern \"C\" { fn exit(code: i32) void; }\n"
         "extend lib::lib::Vec2 { fn sum(self: &lib::lib::Vec2) i32 { return self.x + self.y; } }\n"
         "fn main() i32 {\n"
         "  let v: lib::lib::V = lib::lib::Vec2 { x: 5, y: 7 };\n"
         "  let w = lib::lib::mk(1, 2);\n"
         "  exit(v.sum() + w.sum() + lib::lib::BASE); }\n");
  snprintf(spc, sizeof spc, "%s/feat.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "cross-module features compile: %s", buf);
  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/feat.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "cross-module features C compiles: %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 115, "const + alias + qualified construct + extension method run (12+3+100)");
}

// A7: a generic defined in one module, instantiated over a user struct held BY VALUE in another. The
// generic's module cannot see the user type's layout, so the owner-emits model would produce an
// incomplete-type field; instead the instance is re-homed to the user module via the generic's
// DECLARE/DEFINE macros. Exercises the re-homed struct, a non-generic method (unwrap_or), and a
// cross-pool generic method (map<U>). The -Werror compile is itself the placement proof -- an instance
// emitted in the owner with an incomplete `Bar` would fail to compile.
static void test_cross_module_generic_by_value(void) {
  char root[4112], spc[4170], cmd[8320], buf[256];
  snprintf(root, sizeof root, "%s/genbv", DIR);
  mkfile(root, "opt/opt.spc",
         "pub enum Opt<T> { Some(T), None }\n"
         "extend<T> Opt<T> {\n"
         "  pub fn unwrap_or(self: &Opt<T>, d: T) T { return switch self { Some(v) => v, None => d, }; }\n"
         "  pub fn map<U>(self: &Opt<T>, f: fn(T) U) Opt<U> {\n"
         "    return switch self { Some(v) => Opt::<U>::Some(f(v)), None => Opt::<U>::None, }; }\n"
         "}\n");
  mkfile(root, "genbv.spc",
         "import opt::opt;\n"
         "extern \"C\" { fn exit(code: i32) void; }\n"
         "struct Bar { pub x: i32 }\n"
         "fn bx(b: Bar) i32 { return b.x; }\n"
         "fn main() i32 {\n"
         "  let o = opt::opt::Opt::<Bar>::Some(Bar { x: 30 });\n"
         "  let a = o.unwrap_or(Bar { x: 0 }).x;\n" // 30 -- re-homed struct + non-generic method
         "  let m = o.map(bx).unwrap_or(0);\n"      // 30 -- cross-pool generic method map<i32>
         "  exit(a + m); }\n");                     // 60
  snprintf(spc, sizeof spc, "%s/genbv.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "cross-module generic over a user type compiles: %s", buf);

  // The instance is materialized in the USER module (its DECLARE macro is invoked in genbv's header),
  // not in the generic's owner module -- that is the whole point of the placement fix.
  char gcmd[8400];
  snprintf(gcmd, sizeof gcmd, "grep -q '_DECLARE(' '%s/build/genbv.h'", root);
  CHECK(run_cmd(gcmd, NULL, 0) == 0, "the generic instance is emitted in the user module's header");

  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/genbv.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "cross-module generic-by-value C compiles -Werror (no incomplete type): %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 60, "re-homed instance method + cross-pool map<U> run (30 + 30)");
}

// A `pub interface` declared in one module, then implemented over a local type via `extend T as
// mod::Iface` and consumed by a bounded generic in another module: the bound resolves across the import,
// the impl satisfies it, and the bounded call dispatches to the concrete method. Built -Werror and run.
static void test_cross_module_interface(void) {
  char root[4112], spc[4170], cmd[8320], buf[256];
  snprintf(root, sizeof root, "%s/iface", DIR);
  mkfile(root, "shapes.spc", "pub interface Area { fn area(self: *mut Self) i32; }\n");
  mkfile(root, "main.spc",
         "import shapes;\n"
         "extern \"C\" { fn exit(code: i32) void; }\n"
         "struct Sq { pub s: i32 }\n"
         "extend Sq as shapes::Area { fn area(self: *mut Self) i32 { return self.s * self.s; } }\n"
         "fn total<T: shapes::Area>(x: &mut T) i32 { return x.area(); }\n"
         "fn main() i32 { let mut q = Sq { s: 6 }; exit(total(&mut q)); }\n"); // 36
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "cross-module interface compiles: %s", buf);
  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/iface.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "cross-module interface C compiles -Werror: %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 36, "imported-interface bound dispatches to Sq::area (6*6)");
}

// The bundled `ffi/` bindings, imported by a C header's bare name (`import math;` -> ffi/math.spc, no
// `ffi::` prefix). Exercises the FFI path end-to-end: the ffi search root, a `pub` raw `extern "C"`
// binding emitted with its real unmangled C symbol (and no clashing prototype, since the std headers are
// already included), and a thin wrapper -- all compiled -Werror and run.
static void test_ffi_bindings(void) {
  char root[4112], spc[4170], cmd[8320], buf[256];
  snprintf(root, sizeof root, "%s/ffiuse", DIR);
  mkfile(root, "main.spc",
         "import math;\n"
         "import ctype;\n"
         "extern \"C\" { fn exit(code: i32) void; }\n"
         "fn main() i32 {\n"
         "  let s = math::sqrt(144.0) as i32;\n" // 12, raw binding via mod::f
         "  let mut acc = 0;\n"
         "  if ctype::is_digit(53) { acc = acc + 1; }\n"  // '5' -> +1, thin wrapper
         "  if ctype::is_alpha(53) { acc = acc + 10; }\n" // not alpha -> +0
         "  exit(s + acc);\n"                              // 13
         "}\n");
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "ffi bindings compile (bare `import math; import ctype;`): %s", buf);
  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/ffiuse.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' -lm 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "ffi C compiles + links -Werror (no proto clash): %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 13, "math::sqrt (12) + ctype::is_digit (1) run");
}

// Import forms + mangling: an alias import (`s::tag`), a glob import (bare `tag`), two modules with a
// same-named public function (module mangling must keep them distinct), and a module named like a C
// stdlib header (`string`) -- the relative-include build must not shadow <string.h>. Built with -Werror.
static void test_module_imports(void) {
  char root[4112], spc[4170], cmd[8320], buf[256];
  snprintf(root, sizeof root, "%s/imp", DIR);
  mkfile(root, "string.spc", "pub fn tag() i32 { return 10; }\n"); // collides with <string.h> by name
  mkfile(root, "math.spc", "pub fn tag() i32 { return 20; }\n");   // same fn name -> mangling disambiguates
  mkfile(root, "main.spc",
         "import string as s;\n"
         "import math as *;\n"
         "extern \"C\" { fn exit(code: i32) void; }\n"
         "fn main() i32 { exit(s::tag() + tag()); }\n");
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "alias+glob+stdlib-named modules compile: %s", buf);
  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/imp.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "import-forms C compiles (no <string.h> shadow): %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 30, "alias s::tag (10) + glob tag (20), mangled distinctly");
}

// Module-layer negative paths: cycles, missing modules, and using a non-public type/const/field across
// modules must each be a clear, nonzero-exit error.
static void test_module_errors(void) {
  char root[4150];
  snprintf(root, sizeof root, "%s/cyc", DIR);
  mkfile(root, "main.spc", "import a::a;\nfn main() i32 { return 0; }\n");
  mkfile(root, "a/a.spc", "import b::b;\npub fn f() i32 { return b::b::g(); }\n");
  mkfile(root, "b/b.spc", "import a::a;\npub fn g() i32 { return a::a::f(); }\n");
  expect_fail("cyc", "import cycle");

  snprintf(root, sizeof root, "%s/miss", DIR);
  mkfile(root, "main.spc", "import nope::nope;\nfn main() i32 { return 0; }\n");
  expect_fail("miss", "cannot open module");

  snprintf(root, sizeof root, "%s/privty", DIR);
  mkfile(root, "main.spc", "import lib::lib;\nfn use_it(p: lib::lib::Secret) i32 { return 0; }\nfn main() i32 { return 0; }\n");
  mkfile(root, "lib/lib.spc", "enum Secret { A, B }\npub fn ok() i32 { return 1; }\n");
  expect_fail("privty", "no public type");

  snprintf(root, sizeof root, "%s/privc", DIR);
  mkfile(root, "main.spc", "import lib::lib;\nfn main() i32 { return lib::lib::K; }\n");
  mkfile(root, "lib/lib.spc", "const K: i32 = 9;\n");
  expect_fail("privc", "no public");

  snprintf(root, sizeof root, "%s/privf", DIR);
  mkfile(root, "main.spc", "import lib::lib;\nfn main() i32 { let p = lib::lib::mk(); return p.x; }\n");
  mkfile(root, "lib/lib.spc", "pub struct P { x: i32 }\npub fn mk() P { return P { x: 5 }; }\n");
  expect_fail("privf", "is private");
}

static void test_extensionless_appends(void) {
  char in[4160], out[4170], cmd[8320];
  snprintf(in, sizeof in, "%s/noext", DIR);
  snprintf(out, sizeof out, "%s/build/noext.c", DIR);
  write_file(in, "fn main() i32 { }\n");
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, in);
  run_cmd(cmd, NULL, 0);
  CHECK(access(out, F_OK) == 0, "an extensionless input still produces build/<stem>.c -> %s", out);
}

static void test_missing_file(void) {
  char cmd[8320], buf[256];
  snprintf(cmd, sizeof cmd, "%s '%s/does_not_exist.spc' 2>&1", SC, DIR);
  const int rc = run_cmd(cmd, buf, sizeof buf);
  CHECK(rc != 0, "a missing input file is a nonzero exit (got %d)", rc);
  CHECK_STR_CONTAINS(buf, "does_not_exist.spc"); // perror prints the path
}

static void test_usage(void) {
  char cmd[8320], buf[256];
  snprintf(cmd, sizeof cmd, "%s a b 2>&1", SC);
  const int rc = run_cmd(cmd, buf, sizeof buf);
  CHECK(rc == 1, "argc > 2 exits 1 (got %d)", rc);
  CHECK_STR_CONTAINS(buf, "Usage");
}

static void test_repl(void) {
  char cmd[8320], buf[512];
  // a line then `exit`: the REPL must process input, print its prompts, and terminate
  snprintf(cmd, sizeof cmd, "cd '%s' && printf 'fn main() i32 {}\\nexit\\n' | '%s' 2>/dev/null", DIR, SC);
  const int rc = run_cmd(cmd, buf, sizeof buf);
  CHECK(rc == 0, "REPL exits 0 on `exit` (got %d)", rc);
  CHECK_STR_CONTAINS(buf, "> "); // the prompt is printed
}

static void test_error_exit_code(void) {
  char spc[4160], out[4170], cmd[8320], buf[256];
  snprintf(spc, sizeof spc, "%s/bad.spc", DIR);
  snprintf(out, sizeof out, "%s/build/bad.c", DIR);
  write_file(spc, "fn main() i32 { let x: bool = 1; }\n"); // a type error
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  const int rc = run_cmd(cmd, buf, sizeof buf);
  CHECK(access(out, F_OK) != 0, "no output file is written when compilation fails");
  CHECK_STR_CONTAINS(buf, "mismatched types"); // the diagnostic is reported
  CHECK(rc != 0, "CLI exits nonzero on a compile error (got %d)", rc);
}

int main(void) {
  if (!getcwd(SC, sizeof SC - 16)) {
    fprintf(stderr, "cli_test: getcwd failed\n");
    return 1;
  }
  strcat(SC, "/super-c");
  if (access(SC, X_OK) != 0) {
    fprintf(stderr, "cli_test: %s not found (build the binary first)\n", SC);
    return 1;
  }
  if (!mkdtemp(DIR)) {
    fprintf(stderr, "cli_test: mkdtemp failed\n");
    return 1;
  }

  test_compiles_file();
  test_cross_module_enum();
  test_module_features();
  test_cross_module_generic_by_value();
  test_cross_module_interface();
  test_ffi_bindings();
  test_module_imports();
  test_module_errors();
  test_extensionless_appends();
  test_missing_file();
  test_usage();
  test_repl();
  test_error_exit_code();

  char rm[4128];
  snprintf(rm, sizeof rm, "rm -rf '%s'", DIR);
  if (system(rm)) { /* best-effort cleanup */
  }

  if (failures) {
    fprintf(stderr, "%d cli test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("cli tests passed");
  return 0;
}
