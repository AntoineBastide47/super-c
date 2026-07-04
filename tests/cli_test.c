// Coverage of src/main.c, whose helpers are all static -> exercised by driving the built ./super-c
// binary as a subprocess: argument handling, derive_out_path (extension replace vs append), and the
// file-not-found error path. The dev `test` target depends on $(BIN), so the binary exists when this runs.

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

static bool read_file(const char *path, char *out, const size_t cap) {
  FILE *const fp = fopen(path, "rb");
  if (!fp)
    return false;
  const size_t n = fread(out, 1, cap - 1, fp);
  out[n] = '\0';
  fclose(fp);
  return true;
}

static void test_compiles_file(void) {
  char spc[4160], out[4170], cmd[8320], buf[256];
  snprintf(spc, sizeof spc, "%s/prog.spc", DIR);
  snprintf(out, sizeof out, "%s/build/prog.c", DIR); // output goes to a flat build/ tree
  write_file(spc, "extern \"C\" { fn exit(code: i32) void; }\nfn main() i32 { unsafe exit(7); }\n");

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

// --const-eval end-to-end: folded static_assert (true passes, false errors AT SUPER-C level with our
// span), folded designated indices (a `const` item index would otherwise emit invalid C), folded
// sizeof over the computed layout, [T; N] as a generic type argument, and the layout-verification
// _Static_asserts landing in the generated C and PASSING under -Werror on this target.
static void test_const_eval_flag(void) {
  char root[4112], spc[4170], out[4180], cmd[8320], buf[512];
  snprintf(root, sizeof root, "%s/ce", DIR);
  if (system((snprintf(cmd, sizeof cmd, "mkdir -p '%s'", root), cmd))) { /* best-effort */
  }
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  write_file(
      spc,
      "extern \"C\" { fn exit(code: i32) void; }\n"
      "const K: i32 = 2;\n"
      "struct Pt { pub x: i32, pub y: u8 }\n"
      "struct Wrap<T> { pub v: T }\n"
      "static_assert(sizeof(Pt) == 8, \"padded to 8\");\n"
      "static_assert(K * 2 == 4, \"folds\");\n"
      "static_assert(sizeof(Wrap<[i32; 4]>) == 16, \"array arg layout\");\n"
      "fn main() i32 {\n"
      "  let a: [i32; 2 + 2] = [[K] = 30, [K + 1] = 10, [1 - 1] = 2];\n"
      "  let w = Wrap::<[i32; 4]> { v: [1, 2, 3, 4] };\n"
      "  unsafe exit(a[2] + a[3] + a[0] + w.v[3] + (sizeof((i32, bool)) as i32));\n"
      "}\n");
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "--const-eval compiles (got): %s", buf);
  snprintf(out, sizeof out, "%s/build/main.c", root);
  char gc[8192];
  CHECK(read_file(out, gc, sizeof gc), "generated main.c exists");
  CHECK(strstr(gc, "[2] = 30") != NULL, "const designator index folded into the C output");
  CHECK(strstr(gc, "_Static_assert(sizeof(Pt) == 8") != NULL, "layout verification assert emitted");
  char bin[4200];
  snprintf(bin, sizeof bin, "%s/ce.bin", DIR);
  snprintf(cmd, sizeof cmd, "cc -std=c11 -Wall -Wextra -Werror %s/build/*.c %s/build/__std/*.c -o '%s' 2>&1", root,
           root, bin);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "--const-eval output compiles -Werror (layout asserts hold): %s", buf);
  snprintf(cmd, sizeof cmd, "'%s'", bin);
  CHECK(run_cmd(cmd, NULL, 0) == 54, "const-eval program runs (30+10+2+4+8)");

  // a folded-FALSE static_assert is a SUPER-C error (with our span), not a downstream C error
  write_file(spc, "static_assert(1 + 1 == 3, \"nope\");\nfn main() i32 { return 0; }\n");
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) != 0, "folded-false static_assert fails the build");
  CHECK(strstr(buf, "static assertion failed") != NULL, "and names the failure: %s", buf);
  // the budget flags parse (with size suffixes) and tiny budgets keep plain folding working
  snprintf(cmd, sizeof cmd, "%s --const-eval-steps=4096 --const-eval-memory=1M '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) != 0, "tiny budgets still fold scalar asserts");
  CHECK(strstr(buf, "static assertion failed") != NULL, "same failure under tiny budgets: %s", buf);
  snprintf(cmd, sizeof cmd, "%s --const-eval '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) != 0, "the retired --const-eval flag is rejected with usage");
  CHECK(strstr(buf, "Usage:") != NULL, "and prints usage: %s", buf);
}

// Implicit CTFE under --const-eval: a call with folded arguments RUNS at compile time (recursion,
// loops, switch values, compound assignment), so static_asserts prove it and call sites emit the
// literal; a pure call in statement position disappears. Unfoldable callees (floats here) and
// budget blowups degrade to runtime calls -- and the compile stays fast (a hang fails this lane).
static void test_ctfe(void) {
  char root[4112], spc[4170], out[4180], cmd[8320], buf[512];
  snprintf(root, sizeof root, "%s/ctfe", DIR);
  if (system((snprintf(cmd, sizeof cmd, "mkdir -p '%s'", root), cmd))) { /* best-effort */
  }
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  write_file(spc,
             "extern \"C\" { fn rand() i32; }\n"
             "fn fib(n: i32) i32 {\n"
             "  if n < 2 { return n; }\n"
             "  return fib(n - 1) + fib(n - 2);\n"
             "}\n"
             "fn collatz(mut n: u64) i32 {\n"
             "  let mut c = 0;\n"
             "  while n != 1 { n = switch n % 2 { 0 => n / 2, _ => 3 * n + 1 }; c += 1; }\n"
             "  return c;\n"
             "}\n"
             "fn half(x: f64) f64 { return x / 2.0; }\n"
             "fn late() i32 { return unsafe rand(); }\n"
             "static_assert(fib(20) == 6_765, \"ctfe\");\n"
             "static_assert(collatz(27) == 111, \"loops fold\");\n"
             "static_assert(half(3.0) == 1.5, \"floats fold\");\n"
             "fn main() i32 {\n"
             "  fib(9);\n"
             "  let x = fib(10) - 47;\n"
             "  if late() < 0 { return 1; }\n"
             "  return x;\n"
             "}\n");
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "CTFE program compiles (got): %s", buf);
  snprintf(out, sizeof out, "%s/build/main.c", root);
  char gc[16384];
  CHECK(read_file(out, gc, sizeof gc), "generated main.c exists");
  CHECK(strstr(gc, "_Static_assert(true, \"ctfe\")") != NULL, "fib(20) ran at compile time");
  CHECK(strstr(gc, "_Static_assert(true, \"loops fold\")") != NULL, "collatz(27) ran at compile time");
  CHECK(strstr(gc, "_Static_assert(true, \"floats fold\")") != NULL, "float CTFE ran at compile time");
  CHECK(strstr(gc, "x = 8;") != NULL, "the call site folded to its value");
  CHECK(strstr(gc, "fib(10") == NULL && strstr(gc, "fib(9") == NULL, "no interpreted call survives in main");
  CHECK(strstr(gc, "late()") != NULL, "an un-intercepted extern callee stays a runtime call");
  char bin[4200];
  snprintf(bin, sizeof bin, "%s/ctfe.bin", DIR);
  snprintf(cmd, sizeof cmd, "cc -std=c11 -Wall -Wextra -Werror %s/build/*.c -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "CTFE output compiles -Werror: %s", buf);
  snprintf(cmd, sizeof cmd, "'%s'", bin);
  CHECK(run_cmd(cmd, NULL, 0) == 8, "CTFE program runs (55 - 47)");

  // a callee that blows the step budget bails to a runtime call instead of hanging the compiler
  write_file(spc,
             "fn spin() i32 {\n"
             "  let mut i = 0;\n"
             "  while true { i += 1; if i > 100_000_000 { return i; } }\n"
             "  return 0;\n"
             "}\n"
             "fn main() i32 { if spin() > 0 { return 3; } return 4; }\n");
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "budget blowup still compiles: %s", buf);
  CHECK(read_file(out, gc, sizeof gc), "generated main.c exists");
  CHECK(strstr(gc, "spin()") != NULL, "over-budget callee stays a runtime call");

  // --const-eval-steps starves CTFE: an assert that needs execution now reports the budget
  // (a LOOP burns real steps; recursive fib would be rescued by the call memo below)
  write_file(spc,
             "fn burn() i32 { let mut i = 0; while i < 1_000_000 { i += 1; } return i; }\n"
             "static_assert(burn() == 1_000_000, \"needs execution\");\n"
             "fn main() i32 { return 0; }\n");
  snprintf(cmd, sizeof cmd, "%s --const-eval-steps=4096 '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) != 0, "a starved assert fails the build");
  CHECK(strstr(buf, "step budget exceeded") != NULL, "and blames the budget: %s", buf);

  // the (fn, args) call memo (Zig-style): naive fib(40) is ~2.7 BILLION invocations un-cached,
  // 41 distinct (fn, n) pairs cached -- it must fold comfortably inside a 100k-step budget
  write_file(spc,
             "fn fib(n: i32) i32 { if n < 2 { return n; } return fib(n - 1) + fib(n - 2); }\n"
             "static_assert(fib(40) == 102_334_155, \"memoized\");\n"
             "fn main() i32 { return 0; }\n");
  snprintf(cmd, sizeof cmd, "%s --const-eval-steps=100000 '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "memoized fib(40) folds under a small budget: %s", buf);
  CHECK(read_file(out, gc, sizeof gc), "generated main.c exists");
  CHECK(strstr(gc, "_Static_assert(true, \"memoized\")") != NULL, "the call cache collapsed the recursion");

  // raw strings are CTFE-visible: hash-delimited content (with an interior quote) folds like any literal
  write_file(spc,
             "const G: str = r#\"say \"hi\"\"#;\n"
             "static_assert(G.len() == 8, \"raw folds\");\n"
             "fn main() i32 { return 0; }\n");
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "raw-string CTFE compiles: %s", buf);
  CHECK(read_file(out, gc, sizeof gc), "generated main.c exists");
  CHECK(strstr(gc, "_Static_assert(true, \"raw folds\")") != NULL, "raw string len folded at compile time");
}

// CTFE over aggregates and the abstract heap: structs + methods + operator/extend dispatch, local
// arrays, generic types, intercepted malloc/free with typed pointer views, payload enums through
// switch, and a full std Vector round trip (with_capacity/push/Index/len/free) -- all executed by
// the interpreter. Also locks the two diagnostics upgrades: a static_assert may precede its callee
// (deferred to a package-level re-check) and a would-be runtime trap reports its reason.
static void test_ctfe_memory(void) {
  char root[4112], spc[4170], out[4180], cmd[8320], buf[512];
  snprintf(root, sizeof root, "%s/ctfeh", DIR);
  if (system((snprintf(cmd, sizeof cmd, "mkdir -p '%s'", root), cmd))) { /* best-effort */
  }
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  write_file(spc,
             "static_assert(vec_sum() == 44, \"deferred: asserts may precede their callee\");\n"
             "struct Pt { x: i32, y: i32 }\n"
             "extend Pt {\n"
             "  pub fn mag2(self: &Pt) i32 { return self.x * self.x + self.y * self.y; }\n"
             "  pub fn shift(self: &mut Pt, dx: i32) { self.x += dx; }\n"
             "  pub fn make(x: i32, y: i32) Pt { return Pt { x: x, y: y }; }\n"
             "}\n"
             "extern \"C\" { fn malloc(size: usize) *mut void; fn free(ptr: *mut void) void; }\n"
             "fn structs() i32 {\n"
             "  let mut p = Pt::make(3, 4);\n"
             "  p.shift(1);\n"
             "  let a: [i32; 4] = [[1] = p.mag2(), 1];\n"
             "  let mut s = 0;\n"
             "  for v in a { s += v; }\n"
             "  return s;\n"
             "}\n"
             "static_assert(structs() == 33, \"aggregates fold\");\n"
             "fn heap() i32 {\n"
             "  let p = unsafe malloc(2 * sizeof(i64)) as *mut i64;\n"
             "  unsafe p[0] = 40;\n"
             "  unsafe p[1] = unsafe p[0] + 2;\n"
             "  let r = unsafe p[1];\n"
             "  unsafe free(p as *mut void);\n"
             "  return (r as i32);\n"
             "}\n"
             "static_assert(heap() == 42, \"the abstract heap folds\");\n"
             "fn opt(k: i32) i32 {\n"
             "  let o = if k > 0 { Option::<i32>::Some(k); } else { Option::<i32>::None; };\n"
             "  return switch o { Some(v) => v + 1, None => -1, };\n"
             "}\n"
             "static_assert(opt(4) == 5 && opt(-4) == -1, \"payload enums fold\");\n"
             "fn vec_sum() i32 {\n"
             "  let mut x = Vector::<i32>::with_capacity(2);\n"
             "  x.push(7);\n"
             "  x.push(35);\n"
             "  let s = x[0] + x[1] + (x.len() as i32);\n"
             "  x.free();\n"
             "  return s;\n"
             "}\n"
             "fn main() i32 { return structs() + heap() - 75 + vec_sum() - 44; }\n");
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "heap CTFE program compiles (got): %s", buf);
  snprintf(out, sizeof out, "%s/build/main.c", root);
  char gc[32768];
  CHECK(read_file(out, gc, sizeof gc), "generated main.c exists");
  CHECK(strstr(gc, "_Static_assert(true, \"deferred: asserts may precede their callee\")") != NULL,
        "an assert ABOVE its callee folds via the package-level re-check");
  CHECK(strstr(gc, "_Static_assert(true, \"aggregates fold\")") != NULL, "structs/arrays/methods fold");
  CHECK(strstr(gc, "_Static_assert(true, \"the abstract heap folds\")") != NULL, "malloc/free fold");
  CHECK(strstr(gc, "_Static_assert(true, \"payload enums fold\")") != NULL, "Option + switch folds");
  char bin[4200];
  snprintf(bin, sizeof bin, "%s/ctfeh.bin", DIR);
  snprintf(cmd, sizeof cmd, "cc -std=c11 -Wall -Wextra -Werror %s/build/*.c %s/build/__std/*.c -o '%s' 2>&1", root,
           root, bin);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "heap CTFE output compiles -Werror: %s", buf);
  snprintf(cmd, sizeof cmd, "'%s'", bin);
  CHECK(run_cmd(cmd, NULL, 0) == 0, "heap CTFE program runs (everything folded to 0)");

  // a would-be runtime trap inside a required-const context reports its REASON at Super-C level
  write_file(spc,
             "fn div0(n: i32) i32 { return 10 / n; }\n"
             "static_assert(div0(0) == 1, \"traps\");\n"
             "fn main() i32 { return 0; }\n");
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) != 0, "a trapping assert fails the build");
  CHECK(strstr(buf, "division by zero") != NULL, "and names the trap: %s", buf);

  // use-after-free is caught by the abstract heap, with the same reporting
  write_file(spc,
             "extern \"C\" { fn malloc(size: usize) *mut void; fn free(ptr: *mut void) void; }\n"
             "fn uaf() i32 {\n"
             "  let p = unsafe malloc(sizeof(i32)) as *mut i32;\n"
             "  unsafe p[0] = 1;\n"
             "  unsafe free(p as *mut void);\n"
             "  return unsafe p[0];\n"
             "}\n"
             "static_assert(uaf() == 1, \"uaf\");\n"
             "fn main() i32 { return 0; }\n");
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) != 0, "use-after-free fails the build");
  CHECK(strstr(buf, "use after free") != NULL, "and names it: %s", buf);
}

// The last CTFE surface: `?` early return (both paths), array->slice coercion, range indexing
// into a Vector (an untyped NODE_RANGE builds a prelude Range value), struct-payload variants
// constructed and destructured by struct patterns, &CONST, interface DEFAULT method bodies
// (Self bound to the concrete receiver), and Map/Set (hashing, memset-zeroed bitmaps, deep
// generic substitution for `Option<&V>` receivers).
static void test_ctfe_gaps(void) {
  char root[4112], spc[4170], out[4180], cmd[8320], buf[512];
  snprintf(root, sizeof root, "%s/ctfeg", DIR);
  if (system((snprintf(cmd, sizeof cmd, "mkdir -p '%s'", root), cmd))) { /* best-effort */
  }
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  write_file(spc,
             "const K: i32 = 40;\n"
             "fn check(k: i32) Result<i32, i32> {\n"
             "  if k < 0 { return Result::<i32, i32>::Err(-1); }\n"
             "  return Result::<i32, i32>::Ok(k + 1);\n"
             "}\n"
             "fn step1(k: i32) Result<i32, i32> {\n"
             "  let v = check(k)?;\n"
             "  return Result::<i32, i32>::Ok(v * 2);\n"
             "}\n"
             "fn g1(k: i32) i32 { return switch step1(k) { Ok(v) => v, Err(e) => e, }; }\n"
             "static_assert(g1(20) == 42 && g1(-5) == -1, \"try both paths\");\n"
             "fn g2() i32 {\n"
             "  let a: [i32; 5] = [1, 2, 3, 4, 5];\n"
             "  let s: []i32 = a;\n"
             "  let mut x = Vector::<i32>::with_capacity(4);\n"
             "  x.push(10); x.push(20); x.push(30);\n"
             "  let w = x[1..3];\n"
             "  let r = (s.len() as i32) + s.get(4) + w.get(0) + w.get(1) + (w.len() as i32);\n"
             "  x.free();\n"
             "  return r;\n"
             "}\n"
             "static_assert(g2() == 62, \"slices + range indexing\");\n"
             "enum Shape { Dot, Rect { w: i32, h: i32 }, }\n"
             "fn g3(w: i32, h: i32) i32 {\n"
             "  let s = Shape::Rect { w: w, h: h };\n"
             "  let p = &K;\n"
             "  return switch s { Dot => 0, Rect { w, h } => w * h + *p, };\n"
             "}\n"
             "static_assert(g3(6, 7) == 82, \"struct patterns + &const\");\n"
             "interface Doubler {\n"
             "  fn base(self: &Self) i32;\n"
             "  fn twice(self: &Self) i32 { return self.base() * 2; }\n"
             "}\n"
             "struct G { pub v: i32 }\n"
             "extend G as Doubler { pub fn base(self: &G) i32 { return self.v; } }\n"
             "fn g4() i32 { let g = G { v: 21 }; return g.twice(); }\n"
             "static_assert(g4() == 42, \"interface default body\");\n"
             "fn g5() i32 {\n"
             "  let mut m = Map::<i32, i32>::new();\n"
             "  m.insert(1, 40);\n"
             "  m.insert(2, 60);\n"
             "  let v = switch m.get(&1) { Some(x) => *x, None => -1, };\n"
             "  let mut s = Set::<i32>::new();\n"
             "  s.insert(7);\n"
             "  s.insert(7);\n"
             "  let r = v + (m.len() as i32) + (s.len() as i32);\n"
             "  m.free();\n"
             "  s.free();\n"
             "  return r;\n"
             "}\n"
             "static_assert(g5() == 43, \"Map and Set fold\");\n"
             "fn main() i32 { return g1(20) - 42 + g2() - 62 + g3(6, 7) - 82 + g4() - 42 + g5() - 43; }\n");
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "gap program compiles (got): %s", buf);
  snprintf(out, sizeof out, "%s/build/main.c", root);
  char gc[32768];
  CHECK(read_file(out, gc, sizeof gc), "generated main.c exists");
  CHECK(strstr(gc, "_Static_assert(true, \"try both paths\")") != NULL, "? folds both ways");
  CHECK(strstr(gc, "_Static_assert(true, \"slices + range indexing\")") != NULL, "slices fold");
  CHECK(strstr(gc, "_Static_assert(true, \"struct patterns + &const\")") != NULL, "struct patterns fold");
  CHECK(strstr(gc, "_Static_assert(true, \"interface default body\")") != NULL, "interface defaults fold");
  CHECK(strstr(gc, "_Static_assert(true, \"Map and Set fold\")") != NULL, "Map/Set fold");
  char bin[4200];
  snprintf(bin, sizeof bin, "%s/ctfeg.bin", DIR);
  snprintf(cmd, sizeof cmd, "cc -std=c11 -Wall -Wextra -Werror %s/build/*.c %s/build/__std/*.c -o '%s' 2>&1", root,
           root, bin);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "gap program compiles -Werror: %s", buf);
  snprintf(cmd, sizeof cmd, "'%s'", bin);
  CHECK(run_cmd(cmd, NULL, 0) == 0, "gap program runs (everything folded to 0)");
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
             "  unsafe exit(color_code(c) + box_amt(b)); }\n");

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
         "  unsafe exit(v.sum() + w.sum() + lib::lib::BASE); }\n");
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

// The --test pipeline end to end: @test collection across modules, per-module @test_init/@test_free
// fixtures (RAII-freed), the @test_init(global) suite env, @test(should_panic), fork isolation of a
// failing assertion (later tests still run; failure count = exit code), --test-filter selection, and
// --test-no-fork (should_panic skipped). The generated assert message carries expression + values.
static void test_test_pipeline(void) {
  char root[4112], spc[4170], cmd[8500], buf[4096];
  snprintf(root, sizeof root, "%s/tpipe", DIR);
  mkfile(root, "env.spc",
         "pub struct Env { pub tag: String }\n"
         "@test_init(global)\n"
         "fn suite() Env { return Env { tag: String::from_str(\"suite\") }; }\n"
         "@test_free(global)\n"
         "fn suite_down(env: &mut Env) { eprintln(\"teardown {}\", env.tag.as_str()); }\n");
  mkfile(root, "main.spc",
         "import env;\n"
         "struct Fx { pub v: Vector<i32> }\n"
         "@test_init\n"
         "fn setup() Fx { let mut v = Vector::<i32>::new(); v.push(1); v.push(2); return Fx { v: v }; }\n"
         "@test\n"
         "fn drains(fx: &mut Fx, e: &env::Env) {\n"
         "  let mut s = 0;\n"
         "  while let Some(x) = fx.v.pop() { s += x; }\n"
         "  assert_eq(s, 3);\n"
         "  assert_eq(e.tag.len(), 5);\n"
         "}\n"
         "@test\n"
         "fn fails() { assert_eq(2 * 3, 7); }\n"
         "@test(should_panic)\n"
         "fn boom() { panic(\"boom\"); }\n"
         "struct Counter { pub n: i32 }\n" // a method suite: the receiver IS the fixture
         "extend Counter {\n"
         "  @test_init\n"
         "  fn setup() Counter { return Counter { n: 0 }; }\n"
         "  @test_free\n"
         "  fn teardown(self: &mut Counter) { assert(self.n >= 0, \"non-negative\"); }\n"
         "  pub fn bump(self: &mut Counter) { self.n += 1; }\n"
         "  @test\n"
         "  fn bumps(self: &mut Counter, e: &env::Env) {\n"
         "    self.bump();\n"
         "    assert_eq(self.n * e.tag.len() as i32, 5);\n"
         "  }\n"
         "}\n"
         "fn main() i32 { return 0; }\n");
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  snprintf(cmd, sizeof cmd, "%s --test '%s' 2>&1", SC, spc);
  const int rc = run_cmd(cmd, buf, sizeof buf);
  CHECK(rc == 1, "one failing test -> exit 1 (got %d): %s", rc, buf);
  CHECK_STR_CONTAINS(buf, "running 4 tests");
  CHECK_STR_CONTAINS(buf, "test main::drains ... ok");
  CHECK_STR_CONTAINS(buf, "test main::Counter::bumps ... ok"); // suite method: fixture-as-self + global env
  CHECK_STR_CONTAINS(buf, "test main::boom ... ok (panicked as expected)");
  CHECK_STR_CONTAINS(buf, "test main::fails ... FAILED");
  CHECK_STR_CONTAINS(buf, "assertion failed: `2 * 3 == 7`");
  CHECK_STR_CONTAINS(buf, "left:  6");
  CHECK_STR_CONTAINS(buf, "right: 7");
  CHECK_STR_CONTAINS(buf, "teardown suite");
  CHECK_STR_CONTAINS(buf, "3 passed, 1 failed");
  // --test-filter narrows selection; a fully passing selection exits 0.
  snprintf(cmd, sizeof cmd, "%s --test --test-filter=drains --test-jobs=2 '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "filtered run passes: %s", buf);
  CHECK_STR_CONTAINS(buf, "running 1 test");
  CHECK_STR_CONTAINS(buf, "1 passed, 0 failed");
  // --test-no-fork runs in-process and skips should_panic tests.
  snprintf(cmd, sizeof cmd, "%s --test --test-no-fork --test-filter=boom '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "no-fork skips should_panic: %s", buf);
  CHECK_STR_CONTAINS(buf, "skipped (should_panic needs fork)");
  // A normal (non---test) build of the same tree still compiles and runs its own main.
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "normal build of a tree with tests: %s", buf);
  char bin[4200], ccmd[8500];
  snprintf(bin, sizeof bin, "%s/tpipe.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "normal C build (tests not emitted): %s", buf);
  snprintf(cmd, sizeof cmd, "'%s'", bin);
  CHECK(run_cmd(cmd, NULL, 0) == 0, "the user's main is the entry point outside --test");
}

// A public `static mut` global: extern-declared in its module's header, defined once in the .c, and
// readable/assignable across modules (both through the owning module's functions and directly by path).
static void test_cross_module_static_mut(void) {
  char root[4112], spc[4170], cmd[8320], buf[512];
  snprintf(root, sizeof root, "%s/statics", DIR);
  mkfile(root, "state.spc",
         "pub static mut hits: i64 = 0;\n"
         "pub fn record() { hits += 1; }\n");
  mkfile(root, "main.spc",
         "import state;\n"
         "fn main() i32 {\n"
         "  state::record();\n"
         "  state::record();\n"
         "  state::hits += 3;\n"
         "  return (state::hits - 5) as i32;\n"
         "}\n");
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "cross-module static mut compiles: %s", buf);
  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/statics.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "static mut C compiles -Werror: %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 0, "writes from both modules land on the one definition");
}

// A7: a generic defined in one module, instantiated over a user struct held BY VALUE in another. The
// generic's module cannot see the user type's layout, so the owner-emits model would produce an
// incomplete-type field; instead the instance is re-homed to the user module and full-monomorphized
// there (the generic's template is sourced from its owner module). Exercises the re-homed struct, a
// non-generic method (unwrap_or), and a cross-pool generic method (map<U>). The -Werror compile is
// itself the placement proof -- an instance emitted in the owner with an incomplete `Bar` would fail.
static void test_cross_module_generic_by_value(void) {
  char root[4112], spc[4170], cmd[8320], buf[256];
  snprintf(root, sizeof root, "%s/genbv", DIR);
  mkfile(root, "opt/opt.spc",
         "pub enum Opt<T> { Some(T), None }\n"
         "extend<T> Opt<T> {\n"
         "  pub fn unwrap_or(self: &Opt<T>, d: T) T { return switch self { Some(v) => *v, None => d, }; }\n"
         "  pub fn map<U>(self: &Opt<T>, f: fn(T) U) Opt<U> {\n"
         "    return switch self { Some(v) => Opt::<U>::Some(f(*v)), None => Opt::<U>::None, }; }\n"
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
         "  unsafe exit(a + m); }\n");                     // 60
  snprintf(spc, sizeof spc, "%s/genbv.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "cross-module generic over a user type compiles: %s", buf);

  // The instance's concrete struct is materialized in the USER module's header (full-monomorphized there),
  // not in the generic's owner module -- that is the whole point of the placement fix.
  char gcmd[8400];
  snprintf(gcmd, sizeof gcmd, "grep -q 'struct opt__opt__Opt__genbv__Bar {' '%s/build/genbv.h'", root);
  CHECK(run_cmd(gcmd, NULL, 0) == 0, "the generic instance is full-monomorphized in the user module's header");

  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/genbv.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "cross-module generic-by-value C compiles -Werror (no incomplete type): %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 60, "re-homed instance method + cross-pool map<U> run (30 + 30)");
}

// A cross-module generic instance over a user type whose bounded extend calls a BOUND METHOD on the
// element (`extend<T: Clone> Bx<T> { fn dup() { ..self.v.clone().. } }` instantiated as `Bx<Bar>`). The
// instance is re-homed to the user module and full-monomorphized there; the bound call `self.v.clone()`
// dispatches through the subst (T -> Bar) to the concrete `Bar__clone`. Built -Werror and run -- this is
// what unblocks the container `Clone`/`Eq`/`Hash` conformances.
static void test_cross_module_generic_bound_dispatch(void) {
  char root[4112], spc[4170], cmd[8320], buf[256];
  snprintf(root, sizeof root, "%s/genbd", DIR);
  mkfile(root, "bx/bx.spc",
         "pub interface Clone { fn clone(self: &Self) Self; }\n"
         "pub struct Bx<T> { pub v: T }\n"
         "extend<T: Clone> Bx<T> {\n"
         "  pub fn dup(self: &Bx<T>) Bx<T> { return Bx::<T> { v: self.v.clone() }; }\n"
         "}\n");
  mkfile(root, "genbd.spc",
         "import bx::bx;\n"
         "extern \"C\" { fn exit(code: i32) void; }\n"
         "struct Bar { pub x: i32 }\n"
         "extend Bar as bx::bx::Clone { fn clone(self: &Self) Bar { return Bar { x: self.x }; } }\n"
         "fn main() i32 {\n"
         "  let b = bx::bx::Bx::<Bar> { v: Bar { x: 21 } };\n"
         "  let d = b.dup();\n" // deep-clones Bar via the bound dispatch
         "  unsafe exit(d.v.x + b.v.x); }\n"); // 42
  snprintf(spc, sizeof spc, "%s/genbd.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "cross-module generic with bound-method dispatch compiles: %s", buf);
  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/genbd.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "bound-dispatch generic C compiles -Werror: %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 42, "re-homed Bx<Bar>::dup dispatches self.v.clone() to Bar__clone (21+21)");
}

// `@emit_macro` on a generic type emits reusable C `DECLARE`/`DEFINE` templates into its own header (opt-in),
// so a plain-C consumer can instantiate the Super-C generic over its own C type. Super-C's own instances are
// still full-monomorphized; the templates are purely additive. Also checks the attribute is rejected on a
// non-generic type. (Macro reuse is lower-fidelity: the instance NAME must be the canonical `<Base>__<token>`.)
static void test_emit_macro_export(void) {
  char root[4112], spc[4170], cmd[8320], buf[256];
  snprintf(root, sizeof root, "%s/emac", DIR);
  mkfile(root, "emac.spc",
         "extern \"C\" { fn exit(code: i32) void; }\n"
         "@emit_macro\n"
         "pub struct Pair<T> { pub a: T, pub b: T }\n"
         "extend<T> Pair<T> { pub fn pick(self: &Pair<T>, second: bool) T { if second { return self.b; } return self.a; } }\n"
         "fn main() i32 { let p = Pair::<i32> { a: 3, b: 4 }; unsafe exit(p.pick(true) + p.a); }\n"); // 4 + 3
  snprintf(spc, sizeof spc, "%s/emac.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "@emit_macro generic compiles: %s", buf);

  char gcmd[8400]; // the opt-in templates land in the type's own header
  snprintf(gcmd, sizeof gcmd, "grep -q 'PAIR_DECLARE(' '%s/build/emac.h' && grep -q 'PAIR_DEFINE(' '%s/build/emac.h'",
           root, root);
  CHECK(run_cmd(gcmd, NULL, 0) == 0, "@emit_macro emits DECLARE/DEFINE templates in the header");

  char bin[4200], ccmd[8320], crun[8320]; // Super-C's own use full-monomorphizes and runs
  snprintf(bin, sizeof bin, "%s/emac.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "@emit_macro module C compiles -Werror: %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 7, "@emit_macro module runs (full-mono Pair<i32>)");

  // A plain-C consumer instantiates the template over its own C type (no Super-C compiler involved).
  mkfile(root, "cuser.c",
         "#include \"emac.h\"\n"
         "typedef struct { int n; } CT;\n"
         "PAIR_DECLARE(CT, CT, Pair__CT)\n"
         "PAIR_DEFINE(CT, CT, Pair__CT)\n"
         "int main(void) { Pair__CT p = { .a = { 5 }, .b = { 9 } };\n"
         "  return Pair__CT__pick(&p, 1).n == 9 ? 0 : 1; }\n");
  char cbin[4200], cc2[8460];
  snprintf(cbin, sizeof cbin, "%s/cuser.bin", DIR);
  snprintf(cc2, sizeof cc2, "cc -std=c11 -Wall -Wextra -Werror -I'%s/build' '%s/cuser.c' -o '%s' 2>&1", root, root, cbin);
  CHECK(run_cmd(cc2, buf, sizeof buf) == 0, "plain-C instantiates the @emit_macro template -Werror: %s", buf);
  char cr[4220];
  snprintf(cr, sizeof cr, "'%s'", cbin);
  CHECK(run_cmd(cr, NULL, 0) == 0, "plain-C reuse of the Super-C generic runs");

  // The attribute is rejected on a non-generic type.
  char bad[4170], bcmd[8320];
  mkfile(root, "bad.spc", "@emit_macro\npub struct Plain { pub a: i32 }\nfn main() i32 { return 0; }\n");
  snprintf(bad, sizeof bad, "%s/bad.spc", root);
  snprintf(bcmd, sizeof bcmd, "%s '%s' 2>&1", SC, bad);
  CHECK(run_cmd(bcmd, buf, sizeof buf) != 0, "@emit_macro on a non-generic is rejected");
  CHECK(strstr(buf, "generic struct or enum") != NULL, "the rejection names the constraint: %s", buf);
}

// Per-extend bound filtering: a generic with a bounded extension block (`extend<T: Marker> Wrap<T>`) plus an
// unbounded one, instantiated over a type that does NOT satisfy the bound. The bounded block's methods must
// not be specialized for it (their bodies would call an unprovided method -> an undefined symbol); only the
// unbounded block emits. This is what lets a stateful (non-Default) allocator skip a `Default`-bounded ctor.
static void test_per_extend_bound_filtering(void) {
  char root[4112], spc[4170], cmd[8320], buf[256];
  snprintf(root, sizeof root, "%s/pibf", DIR);
  mkfile(root, "pibf.spc",
         "extern \"C\" { fn exit(code: i32) void; }\n"
         "pub interface Marker { fn mark(self: &Self) i32; }\n"
         "pub struct Wrap<T> { pub v: T }\n"
         "extend<T> Wrap<T> { pub fn raw(self: &Wrap<T>) i32 { return 7; } }\n"
         "extend<T: Marker> Wrap<T> { pub fn marked(self: &Wrap<T>) i32 { return self.v.mark(); } }\n"
         "struct Plain { pub n: i32 }\n" // deliberately does NOT implement Marker
         "fn main() i32 { let w = Wrap::<Plain> { v: Plain { n: 5 } }; unsafe exit(w.raw()); }\n");
  snprintf(spc, sizeof spc, "%s/pibf.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "generic with an unsatisfied bounded block compiles: %s", buf);
  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/pibf.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "the unsatisfied bounded block emits nothing (no undefined ref): %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 7, "the unbounded method still runs");
}

// A non-Default allocator must still get all String<A> methods/conformances that only need an explicit or
// stored allocator. This is a CLI multi-file regression: the generated C must declare/emit the specialized
// String__RawAlloc methods and compile warning-clean without a sentinel `RawAlloc: Default` extension.
static void test_string_non_default_allocator(void) {
  char root[4112], spc[4170], cmd[8320], buf[1024];
  snprintf(root, sizeof root, "%s/strnd", DIR);
  mkfile(root, "main.spc",
         "extern \"C\" { fn malloc(n: usize) *mut void; fn realloc(p: *mut void, n: usize) *mut void; fn free(p: *mut void) void; fn exit(code: i32) void; }\n"
         "struct RawAlloc {}\n"
         "extend RawAlloc as Allocator {\n"
         "  fn alloc(self: &mut RawAlloc, n: usize, align: usize) *mut void { return unsafe malloc(n); }\n"
         "  fn realloc(self: &mut RawAlloc, p: *mut void, old_n: usize, n: usize, align: usize) *mut void { return unsafe realloc(p, n); }\n"
         "  fn dealloc(self: &mut RawAlloc, p: *mut void, n: usize, align: usize) void { unsafe free(p); }\n"
         "}\n"
         "fn main() i32 {\n"
         "  let a = RawAlloc {};\n"
         "  let mut s = String::<RawAlloc>::from_str_in(a, \"abcdefghijklmnopqrstuvwxyz\");\n"
         "  s.push_str(\"0123456789\");\n"
         "  let mut c = s.clone();\n"
         "  let mut f = s.fmt();\n"
         "  let ok = s.eq_str(\"abcdefghijklmnopqrstuvwxyz0123456789\") && s.cmp(&c) == 0 && s.hash() == c.hash() && f.len() == s.len();\n"
         "  f.free(); c.free(); s.free();\n"
         "  if ok { unsafe exit(42); } unsafe exit(1);\n"
         "}\n");
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "String<RawAlloc> without Default compiles: %s", buf);
  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/strnd.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "String<RawAlloc> generated C compiles -Werror: %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 42, "String<RawAlloc> construct/grow/clone/compare/hash/format/free works");
}

// Eager emission is allowed, but generated C must remain warning-clean under -Wunused-function: generic
// methods, inherited default methods and private functions may be omitted or explicitly marked unused.
static void test_warning_clean_unused_emission(void) {
  char root[4112], spc[4170], cmd[8320], buf[1024];
  snprintf(root, sizeof root, "%s/unused", DIR);
  mkfile(root, "main.spc",
         "extern \"C\" { fn exit(code: i32) void; }\n"
         "fn unused_private() i32 { return 99; }\n"
         "interface I { fn value(self: &Self) i32; fn unused_default(self: &Self) i32 { return 123; } }\n"
         "struct S { pub x: i32 }\n"
         "extend S as I { fn value(self: &Self) i32 { return self.x; } }\n"
         "struct Wrap<T> { pub v: T }\n"
         "extend<T> Wrap<T> {\n"
         "  fn get(self: &Self) T { return self.v; }\n"
         "  fn unused_method(self: &Self) T { return self.v; }\n"
         "}\n"
         "fn main() i32 { let s = S { x: 20 }; let w = Wrap::<i32> { v: 22 }; unsafe exit(s.value() + w.get()); }\n");
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "unused-emission regression source compiles: %s", buf);
  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/unused.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "unused generated functions are warning-clean: %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 42, "unused-emission regression program runs");
}

// A trivial app should not dump the whole std prelude tree. It may emit runtime support it actually uses,
// but unrelated heavy prelude modules such as Vector/Map/String should not be written.
static void test_prelude_output_is_demand_driven(void) {
  char root[4112], spc[4170], cmd[8320], buf[256];
  snprintf(root, sizeof root, "%s/simpleout", DIR);
  mkfile(root, "main.spc", "extern \"C\" { fn exit(code: i32) void; }\nfn main() i32 { unsafe exit(42); }\n");
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "trivial CLI source compiles: %s", buf);
  char path[4200];
  snprintf(path, sizeof path, "%s/build/__std/vector.c", root);
  CHECK(access(path, F_OK) != 0, "trivial output should not emit unused std vector.c");
  snprintf(path, sizeof path, "%s/build/__std/map.c", root);
  CHECK(access(path, F_OK) != 0, "trivial output should not emit unused std map.c");
  snprintf(path, sizeof path, "%s/build/__std/string.c", root);
  CHECK(access(path, F_OK) != 0, "trivial output should not emit unused std string.c");
  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/simpleout.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "trivial demand-driven output C compiles: %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 42, "trivial demand-driven output runs");
}

// Cross-module re-homed generic instances must discover by-value nested generic fields before emission.
// `Outer<Bar>` lives in the user module and contains `Inner<Bar>` by value; both specializations must be
// re-homed and emitted in dependency order, otherwise C sees an incomplete by-value field.
static void test_cross_module_nested_rehomed_instance(void) {
  char root[4112], spc[4170], cmd[8320], buf[1024];
  snprintf(root, sizeof root, "%s/nested", DIR);
  mkfile(root, "lib/lib.spc",
         "pub struct Inner<T> { pub value: T }\n"
         "pub struct Outer<T> { pub inner: Inner<T> }\n"
         "extend<T> Outer<T> { pub fn get(self: &Self) T { return self.inner.value; } }\n");
  mkfile(root, "main.spc",
         "import lib::lib;\n"
         "extern \"C\" { fn exit(code: i32) void; }\n"
         "struct Bar { pub x: i32 }\n"
         "fn main() i32 {\n"
         "  let o = lib::lib::Outer::<Bar> { inner: lib::lib::Inner::<Bar> { value: Bar { x: 42 } } };\n"
         "  unsafe exit(o.get().x);\n"
         "}\n");
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "cross-module nested generic source compiles: %s", buf);
  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/nested.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "cross-module nested generic generated C compiles -Werror: %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 42, "cross-module nested re-homed generic instance runs");
}

// A `pub interface` declared in one module, then implemented over a local type via `extend T as
// mod::Iface` and consumed by a bounded generic in another module: the bound resolves across the import,
// the extend satisfies it, and the bounded call dispatches to the concrete method. Built -Werror and run.
static void test_cross_module_interface(void) {
  char root[4112], spc[4170], cmd[8320], buf[256];
  snprintf(root, sizeof root, "%s/iface", DIR);
  mkfile(root, "shapes.spc", "pub interface Area { fn area(self: *mut Self) i32; }\n");
  mkfile(root, "main.spc",
         "import shapes;\n"
         "extern \"C\" { fn exit(code: i32) void; }\n"
         "struct Sq { pub s: i32 }\n"
         "extend Sq as shapes::Area { fn area(self: *mut Self) i32 { return unsafe (self.s * self.s); } }\n"
         "fn total<T: shapes::Area>(x: &mut T) i32 { return x.area(); }\n"
         "fn main() i32 { let mut q = Sq { s: 6 }; unsafe exit(total(&mut q)); }\n"); // 36
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

// Cross-module trait objects: a pub interface (with a default method) in one module, erased over a
// foreign type AND a local type in another; both modules erase (guarded typedefs must not collide),
// and the foreign default's synthesized `Circle__tag` must export for the user TU's glue. -Werror.
static void test_cross_module_dyn(void) {
  char root[4112], spc[4170], cmd[8320], buf[256];
  snprintf(root, sizeof root, "%s/dyn", DIR);
  mkfile(root, "shapes.spc",
         "pub interface Shape {\n"
         "    fn area(self: &Self) i32;\n"
         "    fn tag(self: &Self) i32 { return 7; }\n"
         "}\n"
         "pub struct Circle { pub r: i32 }\n"
         "extend Circle as Shape {\n"
         "    pub fn area(self: &Circle) i32 { return 3 * self.r * self.r; }\n"
         "}\n"
         "pub fn local_view(s: &dyn Shape) i32 { return s.area(); }\n");
  mkfile(root, "main.spc",
         "import shapes;\n"
         "extern \"C\" { fn exit(code: i32) void; }\n"
         "struct Sq { pub s: i32 }\n"
         "extend Sq as shapes::Shape {\n"
         "    pub fn area(self: &Sq) i32 { return self.s * self.s; }\n"
         "    pub fn tag(self: &Sq) i32 { return 4; }\n"
         "}\n"
         "fn total(a: &dyn shapes::Shape, b: &dyn shapes::Shape) i32 { return a.area() + b.area(); }\n"
         "fn main() i32 {\n"
         "    let c = shapes::Circle { r: 1 };\n"
         "    let q = Sq { s: 2 };\n"
         "    let d: &dyn shapes::Shape = &c;\n"          // foreign type + foreign interface
         "    let t = total(&c, &q);\n"                   // 3 + 4 = 7
         "    let u = shapes::local_view(&q);\n"          // 4 (the other module erases too)
         "    let w = d.tag() + q.tag();\n"               // 7 (foreign default) + 4 = 11
         "    unsafe exit(t + u + w + d.area());\n"       // 7 + 4 + 11 + 3 = 25
         "}\n");
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "cross-module dyn compiles: %s", buf);
  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/dyn.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "cross-module dyn C compiles -Werror: %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 25, "cross-module vtables dispatch (7+4+11+3)");
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
         "  let s = unsafe math::sqrt(144.0) as i32;\n" // 12, raw binding via mod::f
         "  let mut acc = 0;\n"
         "  if ctype::is_digit(53) { acc = acc + 1; }\n"  // '5' -> +1, thin wrapper
         "  if ctype::is_alpha(53) { acc = acc + 10; }\n" // not alpha -> +0
         "  unsafe exit(s + acc);\n"                              // 13
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
// stdlib header (`string`) -- the relative-include build must not shadow <string.h>. Imports are public
// (C-style): a glob import of a facade also exposes what the facade imports, and any transitively loaded
// module is reachable by its qualified path without a direct import. Built with -Werror.
static void test_module_imports(void) {
  char root[4112], spc[4170], cmd[8320], buf[256];
  snprintf(root, sizeof root, "%s/imp", DIR);
  mkfile(root, "string.spc", "pub fn tag() i32 { return 10; }\n"); // collides with <string.h> by name
  mkfile(root, "math.spc", "pub fn tag() i32 { return 20; }\n");   // same fn name -> mangling disambiguates
  mkfile(root, "deep.spc", "pub fn dtag() i32 { return 100; }\npub struct D { pub v: i32 }\n");
  mkfile(root, "facade.spc", "import deep;\n"); // re-exports deep through any glob of facade
  mkfile(root, "main.spc",
         "import string as s;\n"
         "import math as *;\n"
         "import facade as *;\n"
         "extern \"C\" { fn exit(code: i32) void; }\n"
         "fn main() i32 {\n"
         "  let d = D { v: deep::dtag() / 10 };\n" // D + dtag via the facade glob; deep:: qualified, unimported
         "  unsafe exit(s::tag() + tag() + dtag() + d.v);\n"
         "}\n");
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "alias+glob+facade+stdlib-named modules compile: %s", buf);
  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/imp.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "import-forms C compiles (no <string.h> shadow): %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 140, "alias (10) + glob (20) + facade-glob dtag (100) + deep::dtag/10 (10)");
}

// Cross-module interface DEFAULT methods: the interface (with bodied defaults) lives in its own module,
// conformances elsewhere. Covers the extend in the type's home (extern synth, called from a third module
// and through a dyn vtable), a LOCAL extension of an imported type (file-local synth), and a builtin
// target (`extend i32 as I` -- Self substitutes to the builtin). Built -Werror and run.
static void test_cross_module_defaults(void) {
  char root[4112], spc[4170], cmd[8320], buf[512];
  snprintf(root, sizeof root, "%s/xdflt", DIR);
  mkfile(root, "shapes.spc",
         "pub interface Shape {\n"
         "  fn area(self: &Self) i32;\n"
         "  fn double_area(self: &Self) i32 { return self.area() * 2; }\n"
         "  fn describe(self: &Self) i32 { return self.double_area() + 1; }\n"
         "}\n");
  mkfile(root, "circle.spc",
         "import shapes;\n"
         "pub struct Circle { pub r: i32 }\n"
         "extend Circle as shapes::Shape {\n"
         "  pub fn area(self: &Circle) i32 { return self.r * self.r * 3; }\n"
         "}\n");
  mkfile(root, "point.spc", "pub struct Point { pub x: i32 }\n");
  mkfile(root, "main.spc",
         "import circle;\n"
         "import shapes;\n"
         "import point;\n"
         "extend point::Point as shapes::Shape {\n" // local extension: synth defaults stay file-local
         "  pub fn area(self: &point::Point) i32 { return self.x; }\n"
         "}\n"
         "extend i32 as shapes::Shape {\n"
         "  pub fn area(self: &i32) i32 { return *self; }\n"
         "}\n"
         "fn dyn_describe(sh: &dyn shapes::Shape) i32 { return sh.describe(); }\n"
         "extern \"C\" { fn exit(code: i32) void; }\n"
         "fn main() i32 {\n"
         "  let c = circle::Circle { r: 2 };\n"  // describe = 2*2*3*2+1 = 25
         "  let p = point::Point { x: 5 };\n"    // describe = 5*2+1 = 11
         "  let n: i32 = 4;\n"                   // describe = 4*2+1 = 9
         "  unsafe exit(c.describe() + dyn_describe(&c) + p.describe() + n.describe());\n" // 25+25+11+9
         "}\n");
  snprintf(spc, sizeof spc, "%s/main.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "cross-module defaults compile: %s", buf);
  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/xdflt.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "cross-module-defaults C compiles -Werror: %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 70, "defaults dispatch: direct (25) + dyn (25) + local ext (11) + builtin (9)");
}

// Format conformances across the prelude, built as a multi-file tree: String/Vector/Option/Result render
// to a String. This exercises the prelude header-include graph -- a value type conforming to a prelude
// interface must NOT pull the interface module's header (that re-formed a cycle: interfaces -> result ->
// String-by-value). Built -Werror (the no-cycle proof) and run.
static void test_format_conformances(void) {
  char root[4112], spc[4170], cmd[8320], buf[256];
  snprintf(root, sizeof root, "%s/fmt", DIR);
  mkfile(root, "fmt.spc",
         "extern \"C\" { fn exit(code: i32) void; }\n"
         "fn main() i32 {\n"
         "  let mut v = Vector::<String>::new();\n"
         "  v.push(String::from_str(\"a\")); v.push(String::from_str(\"b\"));\n"
         "  let mut vs = v.fmt();\n"                                  // "[a, b]" (6)
         "  let o = Option::<String>::Some(String::from_str(\"x\"));\n"
         "  let mut os = o.fmt();\n"                                  // "Some(x)" (7)
         "  let r = Result::<String, String>::Ok(String::from_str(\"y\"));\n"
         "  let mut rs = r.fmt();\n"                                  // "Ok(y)" (5)
         "  unsafe exit(vs.len() as i32 + os.len() as i32 + rs.len() as i32); }\n"); // 18
  snprintf(spc, sizeof spc, "%s/fmt.spc", root);
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  CHECK(run_cmd(cmd, buf, sizeof buf) == 0, "Format conformances compile (no prelude header cycle): %s", buf);
  char bin[4200], ccmd[8320], crun[8320];
  snprintf(bin, sizeof bin, "%s/fmt.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror $(find '%s/build' -name '*.c') -o '%s' 2>&1", root, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "Format-conformance C compiles -Werror (no include cycle): %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 18, "Vector/Option/Result fmt render through the element's Format (6+7+5)");
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
  test_const_eval_flag();
  test_ctfe();
  test_ctfe_memory();
  test_ctfe_gaps();
  test_module_features();
  test_cross_module_static_mut();
  test_test_pipeline();
  test_cross_module_generic_by_value();
  test_cross_module_generic_bound_dispatch();
  test_emit_macro_export();
  test_per_extend_bound_filtering();
  test_string_non_default_allocator();
  test_warning_clean_unused_emission();
  test_prelude_output_is_demand_driven();
  test_cross_module_nested_rehomed_instance();
  test_cross_module_interface();
  test_cross_module_dyn();
  test_ffi_bindings();
  test_module_imports();
  test_cross_module_defaults();
  test_format_conformances();
  test_module_errors();
  test_extensionless_appends();
  test_missing_file();
  test_usage();
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
