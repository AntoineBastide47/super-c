// Aggregator entry point for the self-hosted test suite. The actual @test functions live in
// selfhost/tests/*.spc; this file only exists because the compilation ROOT (root_dir) is the dir of
// the compiled file, and module imports resolve absolutely from there — so the tests must be reachable
// from a file sitting at selfhost/ root. `super-c --test` collects @test from every loaded module.
//   Run: super-c --test selfhost/run_tests.spc   (or `make selfhost-test`)
import tests::token_test;
import tests::lexer_test;
import tests::ast_test;
import tests::resolver_test;
import tests::errors_test;
import tests::vector_test;
import tests::map_test;
import tests::typechecker_test;
import tests::parser_test;
import tests::codegen_test;
import tests::borrow_gen_test;
import tests::codegen_run_test;
import tests::raii_gen_test;
import tests::cli_test;

fn main() i32 { return 0; }
