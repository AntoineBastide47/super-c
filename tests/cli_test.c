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
  char spc[4160], out[4160], cmd[8320], buf[256];
  snprintf(spc, sizeof spc, "%s/prog.spc", DIR);
  snprintf(out, sizeof out, "%s/prog.c", DIR);
  write_file(spc, "extern \"C\" { fn exit(code: i32) void; }\nfn main() i32 { exit(7); }\n");

  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, spc);
  const int rc = run_cmd(cmd, buf, sizeof buf);
  CHECK(rc == 0, "compiling a valid file exits 0 (got %d): %s", rc, buf);
  CHECK(access(out, F_OK) == 0, "derive_out_path replaced .spc with .c -> %s", out);

  // the emitted C is real: it compiles and runs with the program's exit code
  char ccmd[8320], crun[8320];
  char bin[4200];
  snprintf(bin, sizeof bin, "%s/prog.bin", DIR);
  snprintf(ccmd, sizeof ccmd, "cc -std=c11 -Wall -Wextra -Werror '%s' -o '%s' 2>&1", out, bin);
  CHECK(run_cmd(ccmd, buf, sizeof buf) == 0, "CLI output compiles: %s", buf);
  snprintf(crun, sizeof crun, "'%s'", bin);
  CHECK(run_cmd(crun, NULL, 0) == 7, "CLI output runs with the right exit code");
}

static void test_extensionless_appends(void) {
  char in[4160], out[4160], cmd[8320];
  snprintf(in, sizeof in, "%s/noext", DIR);
  snprintf(out, sizeof out, "%s/noext.c", DIR);
  write_file(in, "fn main() i32 { }\n");
  snprintf(cmd, sizeof cmd, "%s '%s' 2>&1", SC, in);
  run_cmd(cmd, NULL, 0);
  CHECK(access(out, F_OK) == 0, "derive_out_path appended .c to an extensionless input -> %s", out);
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
  char spc[4160], out[4160], cmd[8320], buf[256];
  snprintf(spc, sizeof spc, "%s/bad.spc", DIR);
  snprintf(out, sizeof out, "%s/bad.c", DIR);
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
