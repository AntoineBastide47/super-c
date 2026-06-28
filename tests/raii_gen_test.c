// Auto-generating deep-RAII stress suite. Rather than hand-writing fixed cases, this synthesizes a large
// matrix of programs over DEEPLY NESTED owning types -- arbitrary chains of Option / Result / Box wrapping
// a leaf Free type `Tr`, plus Vector aggregates of those chains -- and exercises every ownership operation
// the move analysis must get right: scope-exit free, by-value move-into-call, conditional move, binding
// reassignment, container deep-free, and DEEPLY NESTED switch in all three modes (move-out, borrow-peek,
// and free-elaboration of a bound-but-not-moved payload).
//
// Soundness oracle (no ordering model needed): `Tr::free` does `putchar(self.id)`, so each constructed
// tracker prints its unique id byte exactly when it is freed. The one true RAII invariant -- every value
// freed EXACTLY once -- becomes: the MULTISET of bytes printed == the multiset of ids constructed. A
// missing byte is a leak; a doubled byte is a double-free (which ASan also aborts on). The generated C is
// compiled under -fsanitize=undefined,address, so use-after-free / double-free abort the process and fail
// the exit-code check too. Together these catch all three RAII failure modes at every nesting depth.

#include "test_harness.h"
#include <stdarg.h>

// ---- bounded string builders (return the new end offset; always NUL-terminate) ----
static int ap(char *b, int at, int cap, const char *s) {
  int n = (int)strlen(s);
  if (at + n >= cap)
    n = cap - 1 - at;
  if (n < 0)
    n = 0;
  memcpy(b + at, s, (size_t)n);
  at += n;
  b[at] = '\0';
  return at;
}
static int apf(char *b, int at, int cap, const char *fmt, ...) {
  char tmp[4096];
  va_list va;
  va_start(va, fmt);
  vsnprintf(tmp, sizeof tmp, fmt, va);
  va_end(va);
  return ap(b, at, cap, tmp);
}

// A shape is a string over {'O','R','B'} = Option / Result<_,i32> / Box layers, ending in the leaf `Tr`.

// The Super-C TYPE for shape[p..], e.g. "OR" -> "Option<Result<Tr, i32>>".
static int ty(char *b, int at, int cap, const char *sh, int p) {
  if (!sh[p])
    return ap(b, at, cap, "Tr");
  if (sh[p] == 'O') {
    at = ap(b, at, cap, "Option<");
    at = ty(b, at, cap, sh, p + 1);
    return ap(b, at, cap, ">");
  }
  if (sh[p] == 'R') {
    at = ap(b, at, cap, "Result<");
    at = ty(b, at, cap, sh, p + 1);
    return ap(b, at, cap, ", i32>");
  }
  at = ap(b, at, cap, "Box<");
  at = ty(b, at, cap, sh, p + 1);
  return ap(b, at, cap, ">");
}

// A Super-C EXPRESSION building shape[p..] wrapping a single `Tr { id }`.
static int bld(char *b, int at, int cap, const char *sh, int p, int id) {
  if (!sh[p])
    return apf(b, at, cap, "Tr { id: %d }", id);
  char inner[1024];
  ty(inner, 0, sizeof inner, sh, p + 1);
  if (sh[p] == 'O')
    at = apf(b, at, cap, "Option::<%s>::Some(", inner);
  else if (sh[p] == 'R')
    at = apf(b, at, cap, "Result::<%s, i32>::Ok(", inner);
  else
    at = apf(b, at, cap, "Box::<%s>::new(", inner);
  at = bld(b, at, cap, sh, p + 1, id);
  return ap(b, at, cap, ")");
}

// A nested switch over an O/R chain. mode: 0 move the leaf Tr out (yields Tr); 1 free-elaboration -- read
// the leaf id without moving it, so the Tr is freed at the arm (yields i32); 2 borrow-peek through `&` --
// read the leaf id through references, leaving the scrutinee owned (yields i32). The dead None/Err arms are
// never taken (every value is built Some/Ok) but must still type-check, so they yield a throwaway.
static int sw(char *b, int at, int cap, const char *sh, int p, const char *var, int mode, int top) {
  if (!sh[p])
    return mode == 0 ? ap(b, at, cap, var) : apf(b, at, cap, "%s.id", var);
  char nv[48];
  snprintf(nv, sizeof nv, "%s_%d", var, p);
  const char *pfx = (mode == 2 && top) ? "&" : ""; // borrow only at the outermost scrutinee
  const char *dead = mode == 0 ? "Tr { id: 0 }" : "0";
  if (sh[p] == 'O')
    at = apf(b, at, cap, "switch %s%s { Some(%s) => ", pfx, var, nv);
  else
    at = apf(b, at, cap, "switch %s%s { Ok(%s) => ", pfx, var, nv);
  at = sw(b, at, cap, sh, p + 1, nv, mode, 0);
  return apf(b, at, cap, sh[p] == 'O' ? ", None => %s, }" : ", Err(_) => %s, }", dead);
}

enum { OP_FREE, OP_CALL, OP_COND_T, OP_COND_F, OP_REASSIGN, OP_VECTOR, OP_VPOP, OP_SW_MOVE, OP_SW_FREE, OP_SW_PEEK };

static int id_need(int op) {
  if (op == OP_REASSIGN || op == OP_VPOP)
    return 2;
  if (op == OP_VECTOR)
    return 3;
  return 1;
}

typedef struct {
  char sh[12];
  int op;
} Work;

enum { MAX_SWITCH_DEPTH = 6, MAX_GENERAL_DEPTH = 5, MAX_WORKS = 4096 };

// Emit one scenario's function(s) into `prog`, its call line into `calls`, and the id bytes it constructs
// into `exp`. Each freed id appears once in `exp`; the program returns ids (or 0) so no local goes unused.
static void emit_scenario(char *prog, int *pat, int pcap, char *calls, int *cat, int ccap, char *exp, int *eat,
                          int ecap, int *idc, int sc, const Work *w) {
  char T[1024];
  ty(T, 0, sizeof T, w->sh, 0);
  int id0 = 48 + (*idc)++, id1 = 0, id2 = 0;
  if (id_need(w->op) >= 2)
    id1 = 48 + (*idc)++;
  if (id_need(w->op) >= 3)
    id2 = 48 + (*idc)++;
  *eat = ap(exp, *eat, ecap, (char[]){(char)id0, 0});
  if (id1)
    *eat = ap(exp, *eat, ecap, (char[]){(char)id1, 0});
  if (id2)
    *eat = ap(exp, *eat, ecap, (char[]){(char)id2, 0});

  char e0[2048], e1[2048], e2[2048], s_[4096];
  bld(e0, 0, sizeof e0, w->sh, 0, id0);
  switch (w->op) {
    case OP_FREE: // scope-exit auto-free of a deeply nested owner
      *pat = apf(prog, *pat, pcap, "fn sc%d() i32 { let v = %s; return 0; }\n", sc, e0);
      *cat = apf(calls, *cat, ccap, "  acc = acc + sc%d();\n", sc);
      break;
    case OP_CALL: // move the whole nested value by value into a consumer that frees it
      *pat = apf(prog, *pat, pcap, "fn c%d(v: %s) i32 { return 0; }\n", sc, T);
      *pat = apf(prog, *pat, pcap, "fn sc%d() i32 { return c%d(%s); }\n", sc, sc, e0);
      *cat = apf(calls, *cat, ccap, "  acc = acc + sc%d();\n", sc);
      break;
    case OP_COND_T: // conditional move: true path moves into the consumer...
    case OP_COND_F: // ...false path leaves it to free at scope exit (flag-guarded free)
      *pat = apf(prog, *pat, pcap, "fn c%d(v: %s) i32 { return 0; }\n", sc, T);
      *pat = apf(prog, *pat, pcap,
                 "fn sc%d(flag: bool) i32 { let mut acc = 0; let v = %s; if flag { acc = c%d(v); } return acc; }\n", sc,
                 e0, sc);
      *cat = apf(calls, *cat, ccap, "  acc = acc + sc%d(%s);\n", sc, w->op == OP_COND_T ? "true" : "false");
      break;
    case OP_REASSIGN: // reassigning a Free binding frees the old value; the new frees at scope exit
      bld(e1, 0, sizeof e1, w->sh, 0, id1);
      *pat = apf(prog, *pat, pcap, "fn sc%d() i32 { let mut v = %s; v = %s; return 0; }\n", sc, e0, e1);
      *cat = apf(calls, *cat, ccap, "  acc = acc + sc%d();\n", sc);
      break;
    case OP_VECTOR: // a Vector of nested owners deep-frees every element at scope exit
      bld(e1, 0, sizeof e1, w->sh, 0, id1);
      bld(e2, 0, sizeof e2, w->sh, 0, id2);
      *pat = apf(prog, *pat, pcap,
                 "fn sc%d() i32 { let mut vec = Vector::<%s>::new(); vec.push(%s); vec.push(%s); vec.push(%s); return "
                 "0; }\n",
                 sc, T, e0, e1, e2);
      *cat = apf(calls, *cat, ccap, "  acc = acc + sc%d();\n", sc);
      break;
    case OP_VPOP: // pop moves one element out (an Option<nested>); both it and the remainder free once
      bld(e1, 0, sizeof e1, w->sh, 0, id1);
      *pat = apf(prog, *pat, pcap,
                 "fn sc%d() i32 { let mut vec = Vector::<%s>::new(); vec.push(%s); vec.push(%s); let popped = "
                 "vec.pop(); return 0; }\n",
                 sc, T, e0, e1);
      *cat = apf(calls, *cat, ccap, "  acc = acc + sc%d();\n", sc);
      break;
    case OP_SW_MOVE: // nested switch moves the leaf Tr out; it frees at scope exit
      sw(s_, 0, sizeof s_, w->sh, 0, "v", 0, 1);
      *pat = apf(prog, *pat, pcap, "fn sc%d() i32 { let v = %s; let t = %s; return t.id; }\n", sc, e0, s_);
      *cat = apf(calls, *cat, ccap, "  acc = acc + sc%d();\n", sc);
      break;
    case OP_SW_FREE: // nested switch binds-but-doesn't-move the leaf -> free elaboration at the deep arm
      sw(s_, 0, sizeof s_, w->sh, 0, "v", 1, 1);
      *pat = apf(prog, *pat, pcap, "fn sc%d() i32 { let v = %s; return %s; }\n", sc, e0, s_);
      *cat = apf(calls, *cat, ccap, "  acc = acc + sc%d();\n", sc);
      break;
    case OP_SW_PEEK: // nested borrow-peek; the scrutinee stays owned and frees at scope exit
      sw(s_, 0, sizeof s_, w->sh, 0, "v", 2, 1);
      *pat = apf(prog, *pat, pcap, "fn sc%d() i32 { let v = %s; let r = %s; return r; }\n", sc, e0, s_);
      *cat = apf(calls, *cat, ccap, "  acc = acc + sc%d();\n", sc);
      break;
    default:
      break;
  }
}

static int chcmp(const void *a, const void *b) {
  return (int)(*(const unsigned char *)a) - (int)(*(const unsigned char *)b);
}

// Codegen + compile + run one batch program; assert exit 0 (ASan-clean) and that the freed-byte multiset
// equals the constructed-id multiset (order-independent: sort both, compare).
static void gen_run(const char *name, const char *src, const char *exp_ids) {
  ScResult r = sc_compile(name, src, ST_CODEGEN);
  CHECK(r.errors == 0, "%s: codegen error: %s", name, r.first);
  if (r.errors || !r.code) {
    ast_free(&r.ast);
    free(r.code);
    th_rmtree(r.build_dir);
    return;
  }
  char out[8192];
  int ec = -1;
  if (sc_run_built(r.build_dir, out, sizeof out, &ec) != 0)
    CHECK(false, "%s: generated C failed to compile/run:\n%s\n----- C -----\n%s", name, out, r.code);
  else {
    CHECK(ec == 0, "%s: expected exit 0, got %d (double-free / use-after-free?)\n----- C -----\n%s", name, ec, r.code);
    char a[8192], b[256];
    snprintf(a, sizeof a, "%s", out);
    snprintf(b, sizeof b, "%s", exp_ids);
    qsort(a, strlen(a), 1, chcmp);
    qsort(b, strlen(b), 1, chcmp);
    CHECK(strcmp(a, b) == 0,
          "%s: free multiset mismatch\n  expected(sorted): %s\n  got(sorted):      %s\n----- C -----\n%s", name, b, a,
          r.code);
  }
  ast_free(&r.ast);
  free(r.code);
  th_rmtree(r.build_dir);
}

#define TR_PRE                                                                                                          \
  "extern \"C\" { fn exit(code: i32) void; fn putchar(c: i32) i32; }\n"                                                 \
  "struct Tr { pub id: i32 }\n"                                                                                         \
  "extend Tr as Free { fn free(self: &mut Tr) { putchar(self.id); } }\n"

#define ID_CAP 70 // ids map to bytes 48.. ; keep them printable (<127)

// Assemble accumulated scenarios into one program (respecting the per-program id budget) and run it.
static void flush(const Work *works, int *wi, int nworks, int batch) {
  static char prog[1 << 19];
  char calls[16384], exp[256];
  int at = ap(prog, 0, sizeof prog, TR_PRE);
  int cat = 0, eat = 0, idc = 0, sc = 0;
  calls[0] = exp[0] = '\0';
  while (*wi < nworks && idc + id_need(works[*wi].op) <= ID_CAP) {
    emit_scenario(prog, &at, sizeof prog, calls, &cat, sizeof calls, exp, &eat, sizeof exp, &idc, sc, &works[*wi]);
    sc++;
    (*wi)++;
  }
  at = apf(prog, at, sizeof prog,
           "fn main() i32 { let mut acc = 0;\n%s  if acc == 2147483647 { putchar(33); }\n  exit(0); }\n", calls);
  char name[64];
  snprintf(name, sizeof name, "raii-gen batch %d (%d scenarios)", batch, sc);
  gen_run(name, prog, exp);
}

static void add(Work *w, int *n, const char *sh, int op) {
  if (*n >= MAX_WORKS) {
    CHECK(false, "raii-gen work buffer too small: %d >= %d", *n, MAX_WORKS);
    return;
  }
  snprintf(w[*n].sh, sizeof w[*n].sh, "%s", sh);
  w[*n].op = op;
  (*n)++;
}

static void add_shape_ops(Work *w, int *n, const char *sh, const int *ops, int nops) {
  for (int i = 0; i < nops; i++)
    add(w, n, sh, ops[i]);
}

static void add_all_shapes_rec(Work *w, int *n, char *sh, int at, int max_depth, const char *alphabet, int alphabet_len,
                               const int *ops, int nops) {
  if (at > 0) {
    sh[at] = '\0';
    add_shape_ops(w, n, sh, ops, nops);
  }
  if (at == max_depth)
    return;
  for (int i = 0; i < alphabet_len; i++) {
    sh[at] = alphabet[i];
    add_all_shapes_rec(w, n, sh, at + 1, max_depth, alphabet, alphabet_len, ops, nops);
  }
}

static void add_all_shapes(Work *w, int *n, int max_depth, const char *alphabet, const int *ops, int nops) {
  char sh[12];
  add_all_shapes_rec(w, n, sh, 0, max_depth, alphabet, (int)strlen(alphabet), ops, nops);
}

static void test_raii_generated(void) {
  static Work works[MAX_WORKS];
  int n = 0;

  const int genops[] = {OP_FREE, OP_CALL, OP_COND_T, OP_COND_F, OP_REASSIGN, OP_VECTOR, OP_VPOP};
  const int swops[] = {OP_SW_MOVE, OP_SW_FREE, OP_SW_PEEK};

  // Exhaustive bounded matrix:
  //   * switch behavior over every O/R chain through depth 6
  //   * general ownership behavior over every O/R/B chain through depth 5
  add_all_shapes(works, &n, MAX_SWITCH_DEPTH, "OR", swops, (int)(sizeof swops / sizeof *swops));
  add_all_shapes(works, &n, MAX_GENERAL_DEPTH, "ORB", genops, (int)(sizeof genops / sizeof *genops));

  int wi = 0, batch = 0;
  while (wi < n)
    flush(works, &wi, n, batch++);
}

int main(void) {
  test_raii_generated();
  if (failures) {
    fprintf(stderr, "%d raii-gen test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("raii-gen tests passed");
  return 0;
}
