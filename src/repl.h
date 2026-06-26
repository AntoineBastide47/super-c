#ifndef REPL_H
#define REPL_H

// Interactive read-eval-print loop. Reads (possibly multi-line) Super-C entries, accumulates the ones
// that compile into a growing session, recompiles the session after each entry, and serves `:`-prefixed
// meta-commands (`:help`, `:quit`, `:reset`, `:show`, `:save`, `:load`). `std_dir` locates the std
// prelude (see exe_std_dir in main.c). Returns 0 on a clean exit.
int repl_run(const char *std_dir);

#endif // REPL_H
