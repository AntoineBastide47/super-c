# Object formats and linkers

## The object model

A backend fills `codegen::obj::Obj` (`src/codegen/obj.spc`) in terms every format shares: section kinds
and named sections, symbols (defined in a section, or undefined), relocations whose kind is the
instruction set's (`R_*` of its encoder), per-function call frame rows and line rows. Names are C names:
the writer adds the format's prefix (Mach-O's `_`).

## An object writer

Models: `src/target/macho.spc`, `src/target/elf.spc`, `src/target/coff.spc`, `src/target/wasmobj.spc`.
A writer:

- lays out one section per non-empty kind and per named section (`-ffunction-sections` and
  `-fdata-sections` split code and data per symbol; COFF uses COMDAT sections). A part of a code
  section takes its symbol's own alignment and begins at the fill bytes the symbol's definition put
  before it (`ob::Obj::define_led`, `OSym.al`, `OSym.lead`, `ob::Part.al`; ELF and COFF): one function
  aligned to 64 bytes does not align the others. A symbol with no alignment of its own (an assembler
  label) and a part of data take the section's;
- writes a weak definition (`ob::SF_WEAK`: Mach-O `N_WEAK_DEF`, ELF `STB_WEAK`, a COFF COMDAT section
  of selection `ANY`, wasm `WASM_SYM_BINDING_WEAK`): each object's copy of data no unit owns (a string
  literal) is one when the data splits (`ob::copy_flags`), so the link keeps one copy and drops the
  others' sections;
- maps each relocation kind to the format's type, with the addend where the format keeps it (ELF
  `.rela`, Mach-O and COFF in the section bytes);
- writes the symbol table in the format's order (locals first where the format needs it);
- writes the unwind data from the call frame rows: `.eh_frame` (ELF), compact unwind (Mach-O),
  `.xdata` and `.pdata` (COFF);
- places thread-local variables as the format's TLS model needs (Mach-O descriptors in
  `__thread_vars`, ELF `STT_TLS` in `.tdata` or `.tbss`, COFF `.tls$`);
- attaches the DWARF 4 sections `src/codegen/dwarf.spc` builds (`attach`); wasm takes them as custom
  sections;
- lays the object out before it writes a byte (each section's offset, the string tables and headers
  at their counts), then writes `out` once at its size (Mach-O, ELF, COFF), each relocation's
  addend straight into it: a body buffer grown by doubling and copied into `out` cost the ELF writer
  about 110 MiB per self-build, and per-section byte copies, names and relocation buffers cost the
  COFF writer about 150 MiB.

Check it with the platform's own tools on the test objects (the system linker links them, `objdump` or
`otool` reads them) and with `tests/codegen/debug_info_test.spc`, which also checks that debug
information leaves the code bytes unchanged.

## A linker

Models: `src/link/macho.spc`, `src/link/elf.spc`, `src/link/pe.spc`, `src/link/wasm.spc`;
`src/link/ar.spc` archives and takes their members for any linker (`take_members`, over `Members`),
`src/link/tbd.spc` reads Apple's text stubs, `src/link/util.spc` holds the file helpers (`read_input`),
the undefined-symbol report every linker gives (`Missing`) and `Mem`, the objects a build hands its link
in memory (`link_args`' `mem`: the ones it just wrote, read from there, not from their files). The byte
writers the object writers and the linkers share (`w16`, `w32`, `w64`, `w32be`, `uleb`, `sleb`, `put_str`,
`put_padded`, `pad`) are in `codegen::obj`. `link::link::link_args` takes the C compiler's link command (`-o`, `-l`, `-L`,
`-framework`, `-shared`, `--sysroot=`, `-Wl,` flags), so a build has one link command; it returns
NOT_SERVED for a flag or input it does not handle.

A linker:

1. reads the objects and the archives' members that define a needed symbol, and the system's shared
   libraries for their exported names (and versions, ELF);
2. resolves symbols: one definition each, weak rules, undefined ones bound to a library or an error;
3. lays out the image: segments, sections merged by kind, alignment, the entry point's start code.
   arm64 (Mach-O and ELF, `keep_code`): once a code section's address is known, each input section of
   it (a function, under `-ffunction-sections` or Mach-O's split at symbols) moves forward by the
   fewest bytes after which no 4096-byte boundary falls inside a function of at most 128 bytes or a
   loop of at most 128 bytes (`link::util::keep_pad`, which finds the loops by their backward
   branches): code that holds one runs a cycle late each pass (Apple M-series: 4 cycles in place of 3
   for a 5-instruction function or a 7-instruction loop; boundaries of 64 to 2048 bytes cost nothing).
   The padding is between functions and never runs; it adds about 0.1% to the compiler's code.
   The ELF link also keeps lines of 64 bytes (`lu::KEEP_LINE`): an input section that fits one line
   and would hold a boundary between two moves to the next line (Neoverse N2: such a function runs 6%
   slower; a loop shows no cost, so the link scans none); a move off a page boundary then keeps the
   place in the line. The Mach-O link keeps no lines: Apple's processors show no cost below 4096 bytes.
   x86-64: the code generator places the functions, not the link (`Package.fit_lines`, see
   [code-generator.md](code-generator.md));
4. applies the relocations, relaxing where the format allows (ELF GOT and TLS relaxations);
5. binds imports: stubs and GOT or import address table slots, dynamic relocations for pointers in data;
6. writes unwind tables, the symbol table and debug sections unless stripped, and the format's extras
   (Mach-O exports trie, chained fixups and ad-hoc signature; PE base relocations and exception table).

The output is a function of the inputs alone: no timestamps, a fixed order everywhere. The archiver is
deterministic the same way. `tests/codegen/link_test.spc` links C static libraries, import libraries and
`-ffunction-sections` output; extend it for a new format.

## Dispatch

`src/target/native.spc` names the format per pair: `own_linker` returns a `LINK_*` value,
`obj_kind` the archive's object format. `link_args` in `src/link/link.spc` routes a `LINK_*` value to its
linker. A new format adds a value, a branch in each, and its writer and linker modules.
