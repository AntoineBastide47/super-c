// The frozen C symbol-naming authority for the streaming backend: every symbol regenerates from
// the pools alone. Inputs are concrete, pool-local types under an empty substitution frame;
// resolution happens before naming, never inside it. Renders outside the frozen subset refuse
// (false) instead of guessing.
import ast::ast as *;
import ir::layout as lay;
import lexer::token as tok;
import module::loader as loader;
import ir::interp as iri;

// The C spelling of a builtin in declarations (usize is size_t, NOT uintptr_t; c32/c64 are the
// _Complex pair). "void" doubles as the fallback.
pub const fn bt_c_decl(b: BuiltinType) str<'static> {
    return switch b {
        BT_BOOL => "bool",
        BT_CHAR => "char",
        BT_I8 => "int8_t",
        BT_I16 => "int16_t",
        BT_I32 => "int32_t",
        BT_I64 => "int64_t",
        BT_ISIZE => "intptr_t",
        BT_U8 => "uint8_t",
        BT_U16 => "uint16_t",
        BT_U32 => "uint32_t",
        BT_U64 => "uint64_t",
        BT_USIZE => "size_t",
        BT_F32 => "float",
        BT_F64 => "double",
        BT_C32 => "float _Complex",
        BT_C64 => "double _Complex",
        BT_VALIST => "va_list",
        _ => "void",
    };
}

// Names an identifier cannot keep in C: keywords plus the <iso646.h> alternative-token macros
// (the runtime header includes it, so `and` would expand to `&&`).
/// True when `s` is a C keyword or a reserved C library identifier the emitter must rename.
pub const fn c_keyword(s: str) bool {
    if s.len() == 0 {
        return false;
    }
    let c0 = s.byte_at(0);
    if c0 == b'N' {
        return s == "NULL";
    }
    if c0 == b'_' {
        return s == "_Bool" || s == "_Complex" || s == "_Atomic" || s == "_Noreturn" || s == "_Generic" || s == "_Static_assert" || s == "_Thread_local";
    }
    if c0 == b'a' {
        return s == "auto" || s == "and" || s == "and_eq";
    }
    if c0 == b'b' {
        return s == "break" || s == "bool" || s == "bitand" || s == "bitor";
    }
    if c0 == b'c' {
        return s == "case" || s == "char" || s == "const" || s == "continue" || s == "compl";
    }
    if c0 == b'd' {
        return s == "default" || s == "do" || s == "double";
    }
    if c0 == b'e' {
        return s == "else" || s == "enum" || s == "extern";
    }
    if c0 == b'f' {
        return s == "float" || s == "for" || s == "false";
    }
    if c0 == b'g' {
        return s == "goto";
    }
    if c0 == b'i' {
        return s == "if" || s == "inline" || s == "int";
    }
    if c0 == b'l' {
        return s == "long";
    }
    if c0 == b'n' {
        return s == "not" || s == "not_eq";
    }
    if c0 == b'o' {
        return s == "or" || s == "or_eq";
    }
    if c0 == b'r' {
        return s == "register" || s == "restrict" || s == "return";
    }
    if c0 == b's' {
        return s == "short" || s == "signed" || s == "sizeof" || s == "static" || s == "struct" || s == "switch";
    }
    if c0 == b't' {
        return s == "typedef" || s == "true";
    }
    if c0 == b'u' {
        return s == "union" || s == "unsigned";
    }
    if c0 == b'v' {
        return s == "void" || s == "volatile";
    }
    if c0 == b'w' {
        return s == "while";
    }
    if c0 == b'x' {
        return s == "xor" || s == "xor_eq";
    }
    return false;
}

// Whether byte `k` of `s` is an uppercase letter, or a digit when `digit` is set.
const fn upper_at(s: str, k: usize, digit: bool) bool {
    if k >= s.len() {
        return false;
    }
    let c = s.byte_at(k);
    return c >= b'A' && c <= b'Z' || digit && c >= b'0' && c <= b'9';
}

// Whether `s` is `prefix` followed by an uppercase letter.
const fn prefix_upper(s: str, prefix: str) bool {
    return s.starts_with(prefix) && upper_at(s, prefix.len(), false);
}

// Whether byte `k` of `s` is a lowercase letter.
const fn lower_at(s: str, k: usize) bool {
    return k < s.len() && s.byte_at(k) >= b'a' && s.byte_at(k) <= b'z';
}

/// True when `s` is a macro of the standard headers every generated TU includes (super_rt.h pulls in
/// all of them), or falls in a macro family the C standard reserves for those headers: an emitted
/// identifier with that spelling would expand. Function-like macros count too (the <tgmath.h> math
/// names, the <math.h> classifiers), since a function symbol or a call through a field spells the
/// name before `(`.
pub const fn c_std_macro(s: str) bool {
    if s.len() == 0 {
        return false;
    }
    let c0 = s.byte_at(0);
    if c0 >= b'A' && c0 <= b'Z' {
        if c0 == b'E' {
            // <errno.h> codes, EOF, EXIT_SUCCESS and EXIT_FAILURE.
            return upper_at(s, 1, true);
        }
        if s.starts_with("INT") || s.starts_with("UINT") {
            // <stdint.h> and <limits.h> limits and constant macros.
            return s.ends_with("_MAX") || s.ends_with("_MIN") || s.ends_with("_C") || s.ends_with("_WIDTH");
        }
        if s.starts_with("PRI") || s.starts_with("SCN") {
            // <inttypes.h> format macros.
            return lower_at(s, 3) || s.len() > 3 && s.byte_at(3) == b'X';
        }
        if s.starts_with("M_") {
            // <math.h> constants (M_PI, M_2_PI, ...).
            return upper_at(s, 2, true);
        }
        // <signal.h>, <locale.h>, <fenv.h>, <math.h>, <float.h>, <time.h>, <stdatomic.h>, <pthread.h>
        // and <dlfcn.h> families.
        if prefix_upper(s, "SIG") || prefix_upper(s, "SIG_") || prefix_upper(s, "LC_") || prefix_upper(s, "FE_") {
            return true;
        }
        if prefix_upper(s, "FP_") || prefix_upper(s, "MATH_") || prefix_upper(s, "FLT_") || prefix_upper(s, "DBL_") {
            return true;
        }
        if prefix_upper(s, "LDBL_") || prefix_upper(s, "TIME_") || prefix_upper(s, "ATOMIC_") {
            return true;
        }
        if prefix_upper(s, "PTHREAD_") || prefix_upper(s, "RTLD_") {
            return true;
        }
        return s == "I" || s == "NAN" || s == "INFINITY" || s == "HUGE_VAL" || s == "HUGE_VALF" || s == "HUGE_VALL" || s == "CMPLX" || s == "CMPLXF" || s == "CMPLXL" || s == "CHAR_BIT" || s == "CHAR_MIN" || s == "CHAR_MAX" || s == "SCHAR_MIN" || s == "SCHAR_MAX" || s == "UCHAR_MAX" || s == "SHRT_MIN" || s == "SHRT_MAX" || s == "USHRT_MAX" || s == "LONG_MIN" || s == "LONG_MAX" || s == "ULONG_MAX" || s == "LLONG_MIN" || s == "LLONG_MAX" || s == "ULLONG_MAX" || s == "MB_LEN_MAX" || s == "MB_CUR_MAX" || s == "SIZE_MAX" || s == "PTRDIFF_MIN" || s == "PTRDIFF_MAX" || s == "WCHAR_MIN" || s == "WCHAR_MAX" || s == "WINT_MIN" || s == "WINT_MAX" || s == "WEOF" || s == "DECIMAL_DIG" || s == "BUFSIZ" || s == "FILENAME_MAX" || s == "FOPEN_MAX" || s == "L_tmpnam" || s == "TMP_MAX" || s == "SEEK_SET" || s == "SEEK_CUR" || s == "SEEK_END" || s == "RAND_MAX" || s == "CLOCKS_PER_SEC" || s == "ONCE_FLAG_INIT" || s == "TSS_DTOR_ITERATIONS";
    }
    if c0 == b'_' {
        return s == "_Complex_I" || s == "_Imaginary_I" || s == "_IOFBF" || s == "_IOLBF" || s == "_IONBF";
    }
    if c0 == b'a' {
        if s.starts_with("atomic_") {
            // <stdatomic.h> generic functions.
            return lower_at(s, 7);
        }
        return s == "acos" || s == "asin" || s == "atan" || s == "acosh" || s == "asinh" || s == "atanh" || s == "atan2" || s == "assert" || s == "alignas" || s == "alignof";
    }
    if c0 == b'c' {
        return s == "cos" || s == "cosh" || s == "cbrt" || s == "ceil" || s == "copysign" || s == "carg" || s == "cimag" || s == "conj" || s == "cproj" || s == "creal" || s == "complex" || s == "ckd_add" || s == "ckd_sub" || s == "ckd_mul";
    }
    if c0 == b'e' {
        return s == "exp" || s == "exp2" || s == "expm1" || s == "erf" || s == "erfc" || s == "errno";
    }
    if c0 == b'f' {
        return s == "fabs" || s == "fdim" || s == "floor" || s == "fma" || s == "fmax" || s == "fmin" || s == "fmod" || s == "frexp" || s == "fpclassify";
    }
    if c0 == b'h' {
        return s == "hypot";
    }
    if c0 == b'i' {
        return s == "ilogb" || s == "imaginary" || s == "isfinite" || s == "isinf" || s == "isnan" || s == "isnormal" || s == "isgreater" || s == "isgreaterequal" || s == "isless" || s == "islessequal" || s == "islessgreater" || s == "isunordered";
    }
    if c0 == b'k' {
        return s == "kill_dependency";
    }
    if c0 == b'l' {
        return s == "log" || s == "log10" || s == "log1p" || s == "log2" || s == "logb" || s == "ldexp" || s == "lgamma" || s == "llrint" || s == "llround" || s == "lrint" || s == "lround";
    }
    if c0 == b'm' {
        return s == "math_errhandling" || s.starts_with("memory_order_") && lower_at(s, 13);
    }
    if c0 == b'n' {
        return s == "nearbyint" || s == "nextafter" || s == "nexttoward" || s == "noreturn";
    }
    if c0 == b'o' {
        return s == "offsetof";
    }
    if c0 == b'p' {
        return s == "pow";
    }
    if c0 == b'r' {
        return s == "remainder" || s == "remquo" || s == "rint" || s == "round";
    }
    if c0 == b's' {
        if s.starts_with("stdc_") {
            // <stdbit.h> generic macros.
            return lower_at(s, 5);
        }
        return s == "sin" || s == "sinh" || s == "sqrt" || s == "scalbn" || s == "scalbln" || s == "signbit" || s == "stdin" || s == "stdout" || s == "stderr" || s == "static_assert";
    }
    if c0 == b't' {
        return s == "tan" || s == "tanh" || s == "tgamma" || s == "trunc" || s == "thread_local";
    }
    if c0 == b'v' {
        return s == "va_start" || s == "va_arg" || s == "va_end" || s == "va_copy";
    }
    return false;
}

// Function, object and type names the headers the emitted C includes (super_rt.h and __sc_fwd.h)
// declare at file scope: the C standard library plus the POSIX, BSD and GNU additions glibc and
// Apple's libc declare in those headers. Whitespace-separated; `Mangler::new` indexes them.
const C_LIB_NAMES: str<'static> = M"(cabs cabsf cabsl cacos cacosf cacosl cacosh cacoshf cacoshl carg cargf cargl casin casinf casinl
casinh casinhf casinhl catan catanf catanl catanh catanhf catanhl ccos ccosf ccosl ccosh ccoshf
ccoshl cexp cexpf cexpl cimag cimagf cimagl clog clogf clogl conj conjf conjl cpow cpowf cpowl cproj
cprojf cprojl creal crealf creall csin csinf csinl csinh csinhf csinhl csqrt csqrtf csqrtl ctan
ctanf ctanl ctanh ctanhf ctanhl
isalnum isalpha isblank iscntrl isdigit isgraph islower isprint ispunct isspace isupper isxdigit
tolower toupper isascii toascii isalnum_l isalpha_l isblank_l iscntrl_l isdigit_l isgraph_l
islower_l isprint_l ispunct_l isspace_l isupper_l isxdigit_l tolower_l toupper_l
dlopen dlsym dlclose dlerror dladdr Dl_info
feclearexcept fegetexceptflag feraiseexcept fesetexceptflag fetestexcept fegetround fesetround
fegetenv feholdexcept fesetenv feupdateenv fenv_t fexcept_t
imaxabs imaxdiv strtoimax strtoumax wcstoimax wcstoumax imaxdiv_t
setlocale localeconv lconv newlocale duplocale freelocale uselocale locale_t
acos acosf acosl asin asinf asinl atan atanf atanl atan2 atan2f atan2l cos cosf cosl sin sinf sinl
tan tanf tanl acosh acoshf acoshl asinh asinhf asinhl atanh atanhf atanhl cosh coshf coshl sinh
sinhf sinhl tanh tanhf tanhl exp expf expl exp2 exp2f exp2l expm1 expm1f expm1l frexp frexpf frexpl
ilogb ilogbf ilogbl ldexp ldexpf ldexpl log logf logl log10 log10f log10l log1p log1pf log1pl log2
log2f log2l logb logbf logbl modf modff modfl scalbn scalbnf scalbnl scalbln scalblnf scalblnl cbrt
cbrtf cbrtl fabs fabsf fabsl hypot hypotf hypotl pow powf powl sqrt sqrtf sqrtl erf erff erfl erfc
erfcf erfcl lgamma lgammaf lgammal tgamma tgammaf tgammal ceil ceilf ceill floor floorf floorl
nearbyint nearbyintf nearbyintl rint rintf rintl lrint lrintf lrintl llrint llrintf llrintl round
roundf roundl lround lroundf lroundl llround llroundf llroundl trunc truncf truncl fmod fmodf fmodl
remainder remainderf remainderl remquo remquof remquol copysign copysignf copysignl nan nanf nanl
nextafter nextafterf nextafterl nexttoward nexttowardf nexttowardl fdim fdimf fdiml fmax fmaxf fmaxl
fmin fminf fminl fma fmaf fmal float_t double_t j0 j1 jn y0 y1 yn lgamma_r gamma drem finite
significand scalb signgam
sched_yield sched_param sched_get_priority_max sched_get_priority_min sched_getparam sched_setparam
sched_getscheduler sched_setscheduler sched_rr_get_interval
signal raise sig_atomic_t kill killpg sigaction sigaddset sigdelset sigemptyset sigfillset
sigismember sigpending sigprocmask sigsuspend sigwait sigqueue sigaltstack siginterrupt sigset_t
siginfo_t stack_t sigval sigevent psignal psiginfo sighold sigignore sigpause sigrelse sigset
sigtimedwait sigwaitinfo pid_t uid_t ucontext_t mcontext_t
va_list
memory_order
size_t ptrdiff_t max_align_t wchar_t nullptr_t
FILE fpos_t off_t ssize_t remove rename tmpfile tmpnam fclose fflush fopen freopen setbuf setvbuf
fprintf fscanf printf scanf snprintf sprintf sscanf vfprintf vfscanf vprintf vscanf vsnprintf
vsprintf vsscanf fgetc fgets fputc fputs getc getchar putc putchar puts ungetc fread fwrite fgetpos
fseek fsetpos ftell rewind clearerr feof ferror perror gets stdin stdout stderr fdopen fileno popen
pclose getline getdelim dprintf vdprintf fmemopen open_memstream flockfile ftrylockfile funlockfile
getc_unlocked getchar_unlocked putc_unlocked putchar_unlocked fseeko ftello ctermid tempnam renameat
asprintf vasprintf fgetln funopen setbuffer setlinebuf
atof atoi atol atoll strtod strtof strtold strtol strtoll strtoul strtoull strfromd strfromf
strfroml rand srand aligned_alloc calloc free malloc realloc free_sized free_aligned_sized
memalignment abort atexit at_quick_exit exit _Exit getenv quick_exit system bsearch qsort abs labs
llabs div ldiv lldiv mblen mbtowc wctomb mbstowcs wcstombs div_t ldiv_t lldiv_t posix_memalign
setenv unsetenv putenv mkstemp mkdtemp mktemp realpath random srandom initstate setstate rand_r
drand48 erand48 lrand48 nrand48 mrand48 jrand48 srand48 seed48 lcong48 a64l l64a grantpt
posix_openpt ptsname unlockpt getsubopt ecvt fcvt gcvt valloc alloca arc4random arc4random_uniform
arc4random_buf reallocarray qsort_r getprogname setprogname
memcpy memmove memset memcmp memchr memccpy memset_explicit strcpy strncpy strcat strncat strcmp
strncmp strcoll strxfrm strchr strrchr strspn strcspn strpbrk strstr strtok strerror strlen strdup
strndup strnlen strtok_r strerror_r stpcpy stpncpy strsignal strcoll_l strxfrm_l strerror_l bcmp
bcopy bzero index rindex ffs ffsl ffsll strcasecmp strncasecmp strcasecmp_l strncasecmp_l strlcpy
strlcat strsep memmem strcasestr strnstr memset_s explicit_bzero
call_once once_flag
clock difftime mktime time timespec_get timespec_getres asctime ctime gmtime localtime strftime
clock_t time_t tm timespec timegm gmtime_r localtime_r asctime_r ctime_r nanosleep clock_gettime
clock_settime clock_getres clock_nanosleep clock_getcpuclockid strptime tzset tzname timezone
daylight getdate timer_create timer_delete timer_gettime timer_settime timer_getoverrun clockid_t
timer_t itimerspec strftime_l timelocal
mbrtoc16 c16rtomb mbrtoc32 c32rtomb mbrtoc8 c8rtomb char16_t char32_t char8_t mbstate_t
fwprintf fwscanf swprintf swscanf vfwprintf vfwscanf vswprintf vswscanf vwprintf vwscanf wprintf
wscanf fgetwc fgetws fputwc fputws fwide getwc getwchar putwc putwchar ungetwc wcstod wcstof wcstold
wcstol wcstoll wcstoul wcstoull wcscpy wcsncpy wmemcpy wmemmove wcscat wcsncat wcscmp wcscoll
wcsncmp wcsxfrm wmemcmp wcschr wcscspn wcspbrk wcsrchr wcsspn wcsstr wcstok wmemchr wcslen wmemset
wcsftime btowc wctob mbsinit mbrlen mbrtowc wcrtomb mbsrtowcs wcsrtombs wint_t wcsdup wcsnlen wcpcpy
wcpncpy wcscasecmp wcsncasecmp mbsnrtowcs wcsnrtombs open_wmemstream wcwidth wcswidth wcslcpy
wcslcat
iswalnum iswalpha iswblank iswcntrl iswdigit iswgraph iswlower iswprint iswpunct iswspace iswupper
iswxdigit iswctype wctype towlower towupper towctrans wctrans wctype_t wctrans_t)";

// Whether `s` falls in a family the included headers reserve for their declarations: <threads.h>
// `cnd_`, `mtx_`, `thrd_` and `tss_` and <pthread.h> `pthread_`, each followed by a lowercase
// letter, and the <stdint.h> `int*_t` and `uint*_t` typedefs.
const fn c_lib_family(s: str) bool {
    if s.ends_with("_t") && (s.starts_with("int") || s.starts_with("uint")) {
        return true;
    }
    if s.starts_with("pthread_") {
        return lower_at(s, 8);
    }
    if s.starts_with("thrd_") {
        return lower_at(s, 5);
    }
    return (s.starts_with("mtx_") || s.starts_with("cnd_") || s.starts_with("tss_")) && lower_at(s, 4);
}

// Byte offset right past the LAST `::` (0 for single-segment paths).
const fn path_base_start(path: str) usize {
    let n = path.len();
    let mut at: usize = 0;
    let mut i: usize = 0;
    while i + 1 < n {
        if path.byte_at(i) == b':' && path.byte_at(i + 1) == b':' {
            at = i + 2;
            i = i + 2;
        } else {
            i = i + 1;
        }
    }
    return at;
}

/// A module basename with the module's index (sort key of the short-prefix table).
struct BaseIdx<'a> {
    pub key: str<'a>,
    pub idx: u32,
}

const fn base_idx_cmp(a: &BaseIdx, b: &BaseIdx) i32 {
    return a.key.cmp(&b.key);
}

/// The symbol-naming state of one emission: the substitution stack, memoized renders, and the
/// cross-TU use edges the writer prunes by.
pub struct Mangler {
    pub pkg: *const loader::Package,
    /// Prefixing is on only when the package holds more than one non-prelude module (the single-
    /// module build emits one standalone TU with bare names).
    pub mangle: bool,
    ph_global: loader::LookupHit,
    // Per-module short-prefix verdicts (1 = short), a pure function of the package's module path
    // list, so every TU agrees: `short_ok` points into `short_own` (filled on first use) or into
    // the table of the mangler `share_short` took it from, which outlives this one.
    short_own: Vector<u8>,
    short_ok: *const u8,
    /// Instance suffix appended to closure symbols while a generic body instance emits (closures
    /// hoist per instantiation; the bare name would collide across instances in one TU). Only the
    /// closures DECLARED IN that instance take it: `clos_ids` lists them; a concrete closure
    /// passed IN as a type argument keeps its unsuffixed name.
    pub clos_sfx: String,
    pub clos_ids: Vector<NodeId>,
    /// Substitution stack for per-instance spelling: generic-param decl -> a CONCRETE pool type
    /// (module + TypeId, usually the instance's anchor pool). Innermost binding wins.
    pub subs: Vector<MSub>,
    // Bumped on every change of `subs`: a spelling under an unchanged stack is the same text.
    subs_gen: u64,
    // The frames `hide_from` lifted off `subs` while a binding's payload is read under its own env.
    hidden: Vector<MSub>,
    /// Every TYPE_DYN whose C spelling was rendered: the backend drains this into `SC_DYN_<stem>`
    /// typedef blocks (the fat value + vtable types every dyn spelling presumes).
    pub dyn_reqs: Vector<DynReq>,
    /// Every array wrapper struct a pointer spelling named (`ptr_wraps`), once per mangler: the
    /// assembly defines each in its element's definition header.
    pub wrap_reqs: Vector<WrapReq>,
    wrap_seen: Set<u64>,
    /// Every result pack a spelling named (`ret_pack`), once per mangler: `elem` is its C name,
    /// `body` its typedef and definition. The assembly gives each its own definition header.
    pub pack_reqs: Vector<WrapReq>,
    pack_seen: Set<u64>,
    /// `@emit_macro` template mode: an UNRESOLVED generic param spells as its own name in C types
    /// and as `<paste>_SCM_<name>` in mangles (byte 1 marks a `##` for the template rewriter).
    pub macro_on: bool,
    /// Cross-TU spelling edges as two bit matrices (modpfx marks one per spelling, far too hot
    /// for a hashed set): one row per context (modules, the package-level row, then one per
    /// owner module's instance shard), one bit per owner module. `used_types` when the context
    /// spelled a type name of the owner (it needs the owner's complete types), `used_syms` for
    /// any other symbol (it needs the owner's prototypes); `um_word` reads them. A row takes
    /// its words on its first edge (an emitter shard fills a few of the 2n + 1 rows):
    /// `um_slot[row]` is 1 + the row's first word, 0 for a row with no edge.
    um_slot: Vector<u32>,
    used_types: Vector<u64>,
    used_syms: Vector<u64>,
    /// The aggregates each spelling context's C text uses, one log entry per record:
    /// `tn_row` is the context's row (as in `used_types`), `tn_key` the FNV of the C type name
    /// with bit 0 replaced: 1 when the text needs the complete type (a by-value spelling, a
    /// member access, a dereference, pointer arithmetic), 0 when only a pointer names it (the
    /// typedef line is enough). Unordered with repeats: the entries of one row form a set.
    /// Recorded only while `tn_on`.
    pub tn_key: Vector<u64>,
    pub tn_row: Vector<u32>,
    pub tn_on: bool,
    /// The build plans backend entries (`cbe::simd_enabled`): a vector of 2 to 16 bytes holds a C
    /// vector (`vec_pack`), so the C ABI passes it in one register. Without, the C has no vector
    /// extension.
    pub vec_regs: bool,
    tn_seen: Vector<u64>, // direct-mapped filter over (row, key): most spellings repeat a recent one
    tn_pre: Vector<u64>, // direct-mapped filter over (row, concrete pool type, kind): skips the name hash
    tn_memo: Map<u64, u64>, // (module, decl) or concrete (module, type) -> C name FNV
    tn_buf: String, // spelling scratch of the name keys
    ptr_depth: u32, // nesting of pointee spellings: a type spelled below a pointer needs no definition
    /// Nesting of the C type spellers: a module prefix spelled inside one names a type.
    pub type_depth: u32,
    /// Nesting of the symbol-segment spellers (`type_m`, `inst_name`, `dyn_stem`) outside a C
    /// type: a module prefix spelled inside one is part of a symbol name, not a C use of the
    /// type or symbol, so it records no edge (the enclosing symbol records its owner).
    seg_depth: u32,
    /// Spare declarator buffers for `fn_ptr_ctype` (one taken per nesting level, returned empty).
    fp_bufs: Vector<String>,
    /// The spelling context: a module id (its TU), `CTX_INST | owner` (owner's instance shard)
    /// or -1 (package-level text with no TU of its own).
    pub mark_ctx: i64,
    /// The impl fn `method_by_name` last resolved (node NONE when none): callers that must
    /// demand the instance body read it back (the return carries only the spelling).
    pub last_method_def: DefId,
    /// When set, every successful instance spelling records once (descriptor + the active subs
    /// env) so TU assembly can define aggregates the planner's closure never reached.
    pub agg_on: bool,
    pub agg_reqs: Vector<AggReq>,
    agg_seen: Map<u64, u64>,
    /// Frontier shard capture of instance-aggregate claims (1:1 with agg_reqs pushes).
    pub sh_on: bool,
    pub sh_agg_k: Vector<u64>,
    // Per module, fnode -> owning extend/interface, built on first query: symbol resolution asks
    // per CALL SITE, so membership must be a lookup, not a rescan of the module's item list.
    own_built: Vector<bool>,
    own_idx: Map<u64, u64>, // (module << 32 | fnode) -> (extend << 32 | interface)
    // Per module, owner -> its first `@c.export`/`@c.import` attribute index, built on first query for
    // the same reason: `sym_override` runs per symbol spelling.
    pin_built: Vector<bool>,
    pin_idx: Map<u64, u64>, // (module << 32 | owner) -> attribute index
    ovl_memo: Map<u64, u64>, // overload_count keyed by (cur, tmod, tdecl, name) hash
    // method_by_name misses keyed by (receiver decl or builtin, name) hash: callers probe for methods
    // that often do not exist (`free`, `eq`, `cmp`), and a miss scans every module's items.
    miss_memo: Set<u64>,
    // `conform_ext` answers for extends that apply to every instance: (decl, interface) key ->
    // module << 32 | extend node.
    conf_memo: Map<u64, u64>,
    // free_method answers keyed by declaration: every drop asks, and an answer scans the items.
    free_memo: Map<u64, u64>,
    last_edge: u64, // the spelling edge recorded last: spellings cluster, so most repeat it
    /// While on, spellings record no edge: the caller reads the text but the output never
    /// spells it (identifier reservation).
    pub no_edges: bool,
    /// Per-TU emission journal (driver/tuc): while on, every cross-TU-gated attempt the emitter
    /// makes is logged pre-dedup, so a later build can replay a module's side effects through the
    /// SAME gates without lowering its bodies. Off during replay and outside the seed loop.
    pub rec_on: bool,
    pub rec: Vector<RecEv>,
    /// Attempts already journaled, keyed (gate key, mark_ctx): a dup attempt must be replayable
    /// once per module (its first claimant may vanish), and never more.
    pub rec_dups: Set<u64>,
    /// Target layout service for ZST decisions (`is_zst`): storage elision is a pure function of
    /// final layout, never of syntax, so both manglers (TU and body emitters) answer identically.
    pub lay: lay::Svc,
    /// Substitution-free classification memo keyed (module << 32 | type): bit0 computed, bit1
    /// zero-sized, bit2 unit/never. One resolve+layout then serves every emission gate probe.
    zmemo: Map<u64, u64>,
    zenv: Vector<lay::LayoutEnv>, // layout_at scratch: one frame per visible binding
    lib_names: Set<str<'static>>, // C_LIB_NAMES, indexed
}

// RecEv kinds; the payload schema per kind is fixed by its recording site.
/// Journaled event kinds (RecEv.kind); the trailing phrases say which fields each kind uses.
pub const RK_CHUNK: u8 = 1; // s1 = TU chunk text (driver-recorded, replay re-derives the proto)
pub const RK_ENV: u8 = 2; // h = env name hash, s1 = env struct body
pub const RK_AUX: u8 = 3; // s1 = `_ret` typedef slice
pub const RK_EFWD: u8 = 4; // s1 = env forward-typedef slice
pub const RK_EDEF: u8 = 5; // h = env hash defined by this module (env_skip/env_hashes mark)
pub const RK_DEMAND: u8 = 6; // b/c = def, s1 = sym, s2 = sfx, subs; h = demand_seen key (0 = ungated)
pub const RK_GLUE: u8 = 7; // h = gate, a = em, d = ty, s1 = sym, subs = recorded env
pub const RK_STAT: u8 = 8; // h = gate, a = em, b/c = def, d = ty, s1 = sym
pub const RK_EXT: u8 = 9; // h = gate, s1 = extern prototype line
pub const RK_DYNREQ: u8 = 10; // a = pm, b = t (cem.dyn_request call)
pub const RK_DYNTAB: u8 = 11; // a = pm, b = dyn t, c = srm, d = srt, h = own flag, subs[0] = allocator (dyn_pair call)
pub const RK_TI: u8 = 12; // a = rm, b = rt (type_info descriptor request)
pub const RK_BLK: u8 = 13; // a/b = blocking callee DefId (blk_wrapper call)
pub const RK_AGG: u8 = 14; // h = gate, a = pm, b/c/d+xs = TyInstance, subs = spelling env
pub const RK_MDYN: u8 = 15; // a = pm, b = t (mangler dyn_reqs entry)
pub const RK_EDGE: u8 = 16; // xs = spelling row of this module, bit 15 = type edge (driver-recorded)
pub const RK_MAIN: u8 = 17; // a = main_argv (driver-recorded, module holds `main`)
pub const RK_ZST: u8 = 18; // a = alignment (ZST sentinel demand)
pub const RK_HEDGE: u8 = 19; // a = owner module, h = definition key of the embedded type (header edge)
pub const RK_TNEED: u8 = 20; // xs = type-need keys of this module's row as (low, high) word pairs (driver-recorded)
pub const RK_WRAP: u8 = 21; // h = wrapper name hash, s1 = element C name, s2 = wrapper definition
pub const RK_PACK: u8 = 22; // h = result pack name hash, s1 = its C name, s2 = its definition
/// `mark_ctx` of owner module `o`'s instance shard: `CTX_INST | o`.
pub const CTX_INST: i64 = 0x10000;

// FNV-1a of the bytes hashed into `h` followed by `s` (`fnv_more(x.hash(), s) == (x + s).hash()`).
const fn fnv_more(h: u64, s: str) u64 {
    let mut x = h;
    for k in 0..s.len() {
        x = (x ^ s.byte_at(k) as u64).wrapping_mul(0x100000001b3u64);
    }
    return x;
}

/// One journaled emission side effect. Fields are kind-specific (see RK_*); unused ones stay zero.
pub struct RecEv {
    pub kind: u8,
    pub a: u32,
    pub b: u32,
    pub c: u32,
    pub d: u32,
    pub h: u64,
    pub s1: String,
    pub s2: String,
    pub subs: Vector<MSub>,
    pub xs: Vector<u32>,
}

extend RecEv {
    /// An event of `kind` with every field zero or empty.
    pub fn blank(kind: u8) RecEv {
        return RecEv {
            kind: kind,
            a: 0,
            b: 0,
            c: 0,
            d: 0,
            h: 0,
            s1: String::new(),
            s2: String::new(),
            subs: Vector::<MSub>::new(),
            xs: Vector::<u32>::new(),
        };
    }
}

/// One recorded instance spelling: replaying `it` under `subs` re-derives the same C name.
pub struct AggReq {
    pub pm: ModuleId,
    pub it: TyInstance,
    pub subs: Vector<MSub>,
}

/// One dyn spelling site: the pool the TYPE_DYN lives in.
pub struct DynReq {
    pub pm: ModuleId,
    pub t: TypeId,
}

/// The wrapper struct of a pointee array of aggregates (`Mangler::ptr_wraps`): `name` (FNV `h`),
/// the C name of its innermost element `elem`, and its definition `body` (the struct and its
/// layout check).
pub struct WrapReq {
    pub h: u64,
    pub elem: String,
    pub body: String,
}

/// One substitution binding: param decl `(pm, pnode)` resolves to pool type `(am, at)`. `lim` is
/// the stack size when the binding's GROUP was pushed: the payload references that env, so its
/// resolution never consults this frame or its siblings (a param bound to a derived spelling of
/// itself substitutes exactly once).
pub struct MSub {
    pub pnode: NodeId,
    pub at: TypeId,
    pub lim: u32,
    pub pm: ModuleId,
    pub am: ModuleId,
}

/// A copy of the substitution chain `v`.
pub fn subs_copy(v: &Vector<MSub>) Vector<MSub> {
    // `reserve` (not an exact capacity) keeps the 8-slot growth minimum: the binds a snapshot
    // usually gets next fit without a second allocation.
    let mut out = Vector::<MSub>::new();
    out.reserve(v.len());
    for i in 0..v.len() {
        out.push(*v.at(i));
    }
    return out;
}

extend Mangler {
    /// A mangler over `pkg` (which must outlive it); prefixing is on iff the package holds more than
    /// one non-prelude module.
    pub fn new(pkg: *const loader::Package) Mangler {
        let p = unsafe &*pkg;
        let mut user_mods: usize = 0;
        for i in 0..p.modules.len() {
            if !p.modules.at(i).prelude {
                user_mods += 1;
            }
        }
        let mut lib_names = Set::<str<'static>>::new();
        let mut w: usize = 0;
        for i in 0..C_LIB_NAMES.len() + 1 {
            if i == C_LIB_NAMES.len() || C_LIB_NAMES.byte_at(i) == b' ' || C_LIB_NAMES.byte_at(i) == b'\n' {
                if i > w {
                    lib_names.insert(C_LIB_NAMES.slice(w, i));
                }
                w = i + 1;
            }
        }
        return Mangler {
            pkg: pkg,
            mangle: user_mods > 1,
            ph_global: p.prelude_lookup("Global", true),
            short_own: Vector::<u8>::new(),
            short_ok: null,
            subs: Vector::<MSub>::new(),
            subs_gen: 1,
            clos_sfx: String::new(),
            clos_ids: Vector::<NodeId>::new(),
            dyn_reqs: Vector::<DynReq>::new(),
            wrap_reqs: Vector::<WrapReq>::new(),
            wrap_seen: Set::<u64>::new(),
            pack_reqs: Vector::<WrapReq>::new(),
            pack_seen: Set::<u64>::new(),
            hidden: Vector::<MSub>::new(),
            macro_on: false,
            um_slot: Vector::<u32>::new(),
            used_types: Vector::<u64>::new(),
            used_syms: Vector::<u64>::new(),
            tn_key: Vector::<u64>::new(),
            tn_row: Vector::<u32>::new(),
            tn_on: false,
            vec_regs: false,
            tn_seen: Vector::<u64>::new(),
            tn_pre: Vector::<u64>::new(),
            tn_memo: Map::<u64, u64>::new(),
            tn_buf: String::new(),
            ptr_depth: 0,
            type_depth: 0,
            seg_depth: 0,
            fp_bufs: Vector::<String>::new(),
            mark_ctx: -1,
            last_method_def: DefId { module: 0, node: NODE_NONE },
            agg_on: false,
            sh_on: false,
            sh_agg_k: Vector::<u64>::new(),
            agg_reqs: Vector::<AggReq>::new(),
            agg_seen: Map::<u64, u64>::new(),
            own_built: Vector::<bool>::new(),
            own_idx: Map::<u64, u64>::new(),
            pin_built: Vector::<bool>::new(),
            pin_idx: Map::<u64, u64>::new(),
            ovl_memo: Map::<u64, u64>::new(),
            miss_memo: Set::<u64>::new(),
            conf_memo: Map::<u64, u64>::new(),
            free_memo: Map::<u64, u64>::new(),
            last_edge: 0xFFFFFFFFFFFFFFFFu64,
            no_edges: false,
            rec_on: false,
            rec: Vector::<RecEv>::new(),
            rec_dups: Set::<u64>::new(),
            lay: lay::Svc::new(pkg),
            zmemo: Map::<u64, u64>::new(),
            zenv: Vector::<lay::LayoutEnv>::new(),
            lib_names: lib_names,
        };
    }

    // The packed owner record of `fnode` (module `m`): extend node in the high half, interface
    // node in the low half, zero halves = not a member.
    fn owner_of(self: &mut Self, m: ModuleId, fnode: NodeId) u64 {
        if self.own_built.len() == 0 {
            self.own_built.resize_default(self.p().modules.len());
        }
        if !self.own_built[m as usize] {
            self.own_built.set(m as usize, true);
            let a = self.p().module_ast_const(m);
            let items = unsafe (*a).at_const((*a).root).as_data.program.items;
            for i in 0..items.len {
                let iid = unsafe (*a).list(items)[i as usize];
                let k = unsafe (*a).at_const(iid).kind;
                if k == NodeKind::NODE_EXTEND {
                    let ms = unsafe (*a).at_const(iid).as_data.extend_def.items;
                    for j in 0..ms.len {
                        let mid = unsafe (*a).list(ms)[j as usize];
                        self.own_idx.insert(skey_mix(0, m as u64 << 32 | mid as u64), iid as u64 << 32);
                    }
                } else if k == NodeKind::NODE_INTERFACE {
                    let ms = unsafe (*a).at_const(iid).as_data.interface_def.items;
                    for j in 0..ms.len {
                        let mid = unsafe (*a).list(ms)[j as usize];
                        self.own_idx.insert(skey_mix(0, m as u64 << 32 | mid as u64), iid);
                    }
                }
            }
        }
        let rec = switch self.own_idx.get(&skey_mix(0, m as u64 << 32 | fnode as u64)) {
            Some(v) => *v,
            None => 0u64,
        };
        return rec;
    }

    const fn p<'a>(self: &Self) &'a loader::Package {
        return unsafe &*self.pkg;
    }

    /// Bind a generic param for per-instance spelling; pop with `pop_subs` (LIFO frames).
    pub fn push_sub(self: &mut Self, pm: ModuleId, pnode: NodeId, am: ModuleId, at: TypeId) {
        let lim = self.subs.len() as u32;
        self.subs.push(MSub { pm: pm, pnode: pnode, am: am, at: at, lim: lim });
        self.subs_gen += 1;
    }
    /// Bind generics `gens` (declared in module `pm`) to the args of `it` (spelled in module `am`), up to
    /// the shorter of the two lists. Returns the binding count for pop_subs.
    pub fn push_generics(self: &mut Self, pm: ModuleId, gens: NodeList, am: ModuleId, it: &TyInstance) usize {
        let a = self.p().module_ast_const(pm);
        let mut n: u32 = 0;
        while n < gens.len && n as u8 < it.n {
            self.push_sub(pm, unsafe (*a).list(gens)[n as usize], am, unsafe it.args[n as usize]);
            n += 1;
        }
        return n as usize;
    }
    /// Re-push a recorded binding, keeping its env boundary (demand chains rebuild from index 0).
    pub fn push_msub(self: &mut Self, sb: MSub) {
        self.subs.push(sb);
        self.subs_gen += 1;
    }
    /// Pop the `n` most recent bindings. Panics: fewer than `n` bindings are active.
    pub fn pop_subs(self: &mut Self, n: usize) {
        self.subs.truncate(self.subs.len() - n);
        self.subs_gen += 1;
    }
    /// Drop every binding.
    pub fn clear_subs(self: &mut Self) {
        self.subs.truncate(0);
        self.subs_gen += 1;
    }

    /// Fold a canonical const-generic expression under the substitution stack: every referenced
    /// parameter must bind to a TYPE_CONST. The value's two's complement bits land in `out_val`, its
    /// integer type in `bt`. False when a parameter is unbound or non-const.
    pub fn fold_cexpr(self: &Self, pm: ModuleId, t: TypeId, out_val: &mut i64, bt: &mut BuiltinType) bool {
        return self.fold_cexpr_d(pm, t, out_val, bt, 0, self.subs.len());
    }
    /// Ground any const-valued payload (TYPE_CONST, expression, or bound param) below `lim`: its bits
    /// and integer type, as `fold_cexpr`.
    pub fn fold_cval_at(self: &Self, am: ModuleId, at: TypeId, out_val: &mut i64, bt: &mut BuiltinType, lim: usize) bool {
        let l = lim.min(self.subs.len());
        let y = *unsafe (*self.p().module_ast_const(am)).type_at(at);
        if y.kind == TypeKind::TYPE_CONST {
            *out_val = y.as_data.value;
            *bt = y.cbt();
            return true;
        }
        if y.kind == TypeKind::TYPE_CONST_EXPR {
            return self.fold_cexpr_d(am, at, out_val, bt, 0, l);
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            return self.fold_generic_d(&y, out_val, bt, 0, l);
        }
        return false;
    }

    // Ground a const-bound GENERIC param to its value (bits and integer type): frames innermost-first,
    // each matched frame's payload folding strictly below that frame's env boundary.
    fn fold_generic_d(self: &Self, y: &Ty, out_val: &mut i64, bt: &mut BuiltinType, depth: u32, lim: usize) bool {
        if depth > 8 {
            return false;
        }
        let mut k = lim;
        while k > 0 {
            k -= 1;
            let sb = *self.subs.at(k);
            if sb.pm != y.module || sb.pnode != y.as_data.decl {
                continue;
            }
            let kl = (sb.lim as usize).min(k);
            let by = *unsafe (*self.p().module_ast_const(sb.am)).type_at(sb.at);
            if by.kind == TypeKind::TYPE_CONST {
                *out_val = by.as_data.value;
                *bt = by.cbt();
                return true;
            }
            if by.kind == TypeKind::TYPE_CONST_EXPR {
                if self.fold_cexpr_d(sb.am, sb.at, out_val, bt, depth + 1, kl) {
                    return true;
                }
            } else if by.kind == TypeKind::TYPE_GENERIC {
                if self.fold_generic_d(&by, out_val, bt, depth + 1, kl) {
                    return true;
                }
            }
        }
        return false;
    }

    fn fold_cexpr_d(
        self: &Self,
        pm: ModuleId,
        t: TypeId,
        out_val: &mut i64,
        bt: &mut BuiltinType,
        depth: u32,
        lim: usize,
    ) bool {
        if depth > 8 {
            return false;
        }
        let a = self.p().module_ast_const(pm);
        let y = *unsafe (*a).type_at(t);
        let l = *unsafe (*a).const_lin_at(y.as_data.inst);
        let mut v = l.k;
        for i in 0..l.n {
            let c = unsafe l.c[i as usize];
            if c.is_zero() {
                continue;
            }
            let pd = unsafe l.p[i as usize];
            // Bindings try innermost-first with backtracking, but a frame's payload resolves only
            // through frames BELOW it (its env when pushed); a width bound to a derived
            // expression of itself must apply exactly once, grounding in the outer value.
            let mut bv: i64 = 0;
            let mut bb = BuiltinType::BT_COUNT;
            let mut got = false;
            let mut k = lim;
            while k > 0 && !got {
                k -= 1;
                let sb = *self.subs.at(k);
                if sb.pm != pd.module || sb.pnode != pd.node {
                    continue;
                }
                let kl = (sb.lim as usize).min(k);
                let mut rm = sb.am;
                let mut rt = sb.at;
                let mut env: usize = 0;
                if !self.resolve_from(sb.am, sb.at, &mut rm, &mut rt, 0, kl, &mut env) {
                    continue;
                }
                let by = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
                if by.kind == TypeKind::TYPE_CONST {
                    bv = by.as_data.value;
                    bb = by.cbt();
                    got = true;
                } else if by.kind == TypeKind::TYPE_CONST_EXPR {
                    if self.fold_cexpr_d(rm, rt, &mut bv, &mut bb, depth + 1, kl) {
                        got = true;
                    }
                }
            }
            if !got {
                // A term naming a module CONST (not a generic param): the evaluator has its value.
                let pa = self.p().module_ast_const(pd.module);
                if unsafe (*pa).at_const(pd.node).kind == NodeKind::NODE_CONST && self.p().cir != null {
                    let cev = unsafe &mut *(self.p().cir as *mut iri::Interp);
                    let cv = cev.eval(pd.module, unsafe (*pa).at_const(pd.node).as_data.const_def.value);
                    if cv.kind == iri::IV_INT && lin_acc(&mut v, c, iri::iv_exact(&cv)) {
                        continue;
                    }
                }
                return false;
            }
            if !lin_acc(&mut v, c, cval_exact(bv, bb)) {
                return false;
            }
        }
        let mut r = i128::zero();
        if !l.finish(v, lay::target_for(self.p().arch).ptr == 4, &mut r) {
            return false;
        }
        *out_val = cval_bits(r);
        *bt = l.to;
        return true;
    }

    /// Innermost-wins resolution of `(pm, t)` through the substitution stack: TYPE_GENERIC hops to
    /// its binding's pool; anything else stays put. Returns false when an unbound param remains.
    pub fn resolve(self: &Self, pm: ModuleId, t: TypeId, rm: &mut ModuleId, rt: &mut TypeId) bool {
        let mut env: usize = 0;
        return self.resolve_from(pm, t, rm, rt, 0, self.subs.len(), &mut env);
    }

    /// `resolve`, also giving the stack size `env` the result's own params resolve under: a
    /// binding's payload references the env it was pushed in, never its own frame or later ones.
    pub fn resolve_env(self: &Self, pm: ModuleId, t: TypeId, rm: &mut ModuleId, rt: &mut TypeId, env: &mut usize) bool {
        return self.resolve_from(pm, t, rm, rt, 0, self.subs.len(), env);
    }

    /// Lift the frames from `env` up off the stack while the resolved payload `(rm, rt)` is read, so
    /// a param bound to a derived spelling of itself (`T := W<T>`) substitutes once instead of
    /// forever. A concrete payload names no param and moves nothing. Returns the mark `unhide` takes.
    pub fn hide_from(self: &mut Self, env: usize, rm: ModuleId, rt: TypeId) usize {
        let h0 = self.hidden.len();
        if env < self.subs.len() && !unsafe (*self.p().module_ast_const(rm)).type_concrete(rt) {
            for i in env..self.subs.len() {
                self.hidden.push(*self.subs.at(i));
            }
            self.subs.truncate(env);
            self.subs_gen += 1;
        }
        return h0;
    }

    /// Restore the frames `hide_from` lifted at mark `h0`.
    pub fn unhide(self: &mut Self, h0: usize) {
        for i in h0..self.hidden.len() {
            self.subs.push(*self.hidden.at(i));
        }
        if h0 < self.hidden.len() {
            self.subs_gen += 1;
        }
        self.hidden.truncate(h0);
    }

    /// `(pm, t)` with every generic parameter substituted through the stack, as a concrete type
    /// interned into pool `dm`. False when a parameter stays unbound, or for a type shape a value
    /// never names (a field projection over parameters).
    pub fn ground(self: &mut Self, pm: ModuleId, t: TypeId, dm: ModuleId, out: &mut TypeId) bool {
        return self.ground_l(pm, t, dm, self.subs.len(), out, 0);
    }

    /// `ground` reading only the frames below `lim`. An associated type (`T::Output`) grounds to its
    /// conformance's type (`Package::assoc_norm`).
    fn ground_l(self: &Self, pm: ModuleId, t: TypeId, dm: ModuleId, lim: usize, out: &mut TypeId, depth: u32) bool {
        if depth > 16 {
            return false;
        }
        let pa = self.p().module_ast_const(pm);
        let da = self.p().module_ast_const(dm) as *mut Ast;
        let y = *unsafe (*pa).type_at(t);
        if unsafe (*pa).type_concrete(t) {
            *out = unsafe (*da).reintern(unsafe &*pa, t);
            return true;
        }
        let mut cv: i64 = 0;
        let mut bt = BuiltinType::BT_COUNT;
        if y.kind == TypeKind::TYPE_GENERIC && self.fold_generic_d(&y, &mut cv, &mut bt, 0, lim) || y.kind == TypeKind::TYPE_CONST_EXPR && self.fold_cexpr_d(
            pm,
            t,
            &mut cv,
            &mut bt,
            0,
            lim,
        ) {
            *out = unsafe (*da).const_value(cv, bt);
            return true;
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            let mut rm: ModuleId = 0;
            let mut rt = TYPE_NONE;
            let mut env: usize = 0;
            if !self.resolve_from(pm, t, &mut rm, &mut rt, 0, lim, &mut env) {
                return false;
            }
            return self.ground_l(rm, rt, dm, env, out, depth + 1);
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_SLICE || y.arr_like() {
            let mut e = TYPE_NONE;
            if !self.ground_l(pm, y.as_data.elem, dm, lim, &mut e, depth + 1) {
                return false;
            }
            if y.arr_sym() {
                let mut lt = TYPE_NONE;
                if !self.ground_l(pm, y.as_data.arr.len, dm, lim, &mut lt, depth + 1) {
                    return false;
                }
                *out = unsafe (*da).intern_array(y.kind, e, lt);
                return true;
            }
            let mut nt = y;
            nt.as_data.elem = e;
            *out = unsafe (*da).intern_type(nt);
            return true;
        }
        if y.kind == TypeKind::TYPE_INSTANCE || y.kind == TypeKind::TYPE_ASSOC || y.kind == TypeKind::TYPE_DYN || y.fn_sig() {
            let mut it = *unsafe (*pa).instance(y.rec());
            if y.kind == TypeKind::TYPE_DYN && it.decl == NODE_NONE {
                return false; // a `dyn fn` over parameters
            }
            for i in 0..it.n {
                let mut g = TYPE_NONE;
                if !self.ground_l(pm, unsafe it.args[i as usize], dm, lim, &mut g, depth + 1) {
                    return false;
                }
                unsafe it.args[i as usize] = g;
            }
            if y.kind == TypeKind::TYPE_ASSOC {
                return self.p().assoc_norm(dm, &it, out, depth + 1);
            }
            *out = if y.fn_sig() {
                unsafe (*da).intern_sig_rec(&it, y.qualifier);
            } else if y.kind == TypeKind::TYPE_DYN {
                unsafe (*da).intern_dyn(it.module, it.decl, &it.args[0], it.n, y.qualifier);
            } else {
                unsafe (*da).intern_instance(it.module, it.decl, &it.args[0], it.n);
            };
            return true;
        }
        return false;
    }

    /// Substitution-free-memoized classification behind `is_zst`/`erased`: one resolve + one
    /// (cached) layout query per (module, type). Instance emission (subs active) bypasses the memo:
    /// the same pool TypeId legitimately resolves differently per instantiation.
    pub fn zclass(self: &mut Self, pm: ModuleId, t: TypeId) u64 {
        let memoable = self.subs.len() == 0;
        // Mixed key: the map hashes u64 identically, and unmixed (module << 32 | type) keys
        // collide across modules in the masked low bits (probe chains grow with module count).
        let key = skey_mix(0, pm as u64 << 32 | t as u64);
        if memoable {
            switch self.zmemo.get(&key) {
                Some(v) => {
                    return *v;
                },
                None => {},
            };
        }
        let mut rm = pm;
        let mut rt = t;
        let mut env: usize = 0;
        let bound = self.resolve_env(pm, t, &mut rm, &mut rt, &mut env);
        if !bound {
            rm = pm;
            rt = t;
        }
        let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        let mut v: u64 = 1;
        if y.kind == TypeKind::TYPE_NEVER || y.kind == TypeKind::TYPE_BUILTIN && y.as_data.builtin == BuiltinType::BT_VOID {
            v = v | 4;
        } else if bound && y.kind != TypeKind::TYPE_BUILTIN && y.kind != TypeKind::TYPE_POINTER && y.kind != TypeKind::TYPE_REFERENCE && y.kind != TypeKind::TYPE_FUNCTION && y.kind != TypeKind::TYPE_DYN {
            let lo = self.layout_at(rm, rt, env);
            if lo.ok && lo.size == 0 {
                v = v | 2;
            }
        }
        if memoable {
            self.zmemo.insert(key, v);
        }
        return v;
    }

    /// Layout of `(pm, t)` under the substitution stack; not-ok when a parameter stays unbound.
    pub fn layout_sub(self: &mut Self, pm: ModuleId, t: TypeId) lay::Layout {
        let mut rm = pm;
        let mut rt = t;
        let mut env: usize = 0;
        if !self.resolve_env(pm, t, &mut rm, &mut rt, &mut env) {
            return lay::Layout { ok: false, unbound: true };
        }
        return self.layout_at(rm, rt, env);
    }

    // Layout of resolved `(rm, rt)` under the bindings below `env`. Each binding becomes one
    // layout frame whose lookup continues at the binding below it and whose payload reads under
    // the frames below its `lim`, the env `resolve_from` reads it in.
    fn layout_at(self: &mut Self, rm: ModuleId, rt: TypeId, env: usize) lay::Layout {
        if env == 0 || unsafe (*self.p().module_ast_const(rm)).type_concrete(rt) {
            return self.lay.layout(rm, rt);
        }
        self.zenv.clear();
        self.zenv.reserve(env);
        for i in 0..env {
            let sb = self.subs.at(i);
            let mut fr = lay::LayoutEnv {
                parent: null,
                penv: null,
                pmod: sb.pm,
                params: &sb.pnode,
                argm: sb.am,
                args: [0; 8],
                n: 1,
            };
            fr.args[0] = sb.at;
            self.zenv.push(fr);
        }
        for i in 1..env {
            let below: *const lay::LayoutEnv = self.zenv.at(i - 1);
            self.zenv[i].parent = below;
            let mut l = self.subs.at(i).lim as usize;
            if l > i {
                l = i;
            }
            if l > 0 {
                let pe: *const lay::LayoutEnv = self.zenv.at(l - 1);
                self.zenv[i].penv = pe;
            }
        }
        let head: *const lay::LayoutEnv = self.zenv.at(env - 1);
        let r = self.lay.layout_of(rm, rt, head, 0);
        // The layout frames bind parameters only: a type naming an associated type (`W<T::Output>`)
        // lays out grounded.
        let mut g = TYPE_NONE;
        if !r.ok && self.ground(rm, rt, rm, &mut g) {
            return self.lay.layout(rm, g);
        }
        return r;
    }

    /// Final-layout zero-sized test under the active substitution env (storage elision is a pure
    /// function of layout, never syntax). Scalar and pointer kinds can never be zero-sized, so
    /// only aggregate-shaped types pay for resolution and a (cached) layout query. The answer is
    /// an ABI decision every emission site must agree on: it is deterministic per concrete type,
    /// and unresolvable/unlayoutable types uniformly answer material.
    pub fn is_zst(self: &mut Self, pm: ModuleId, t: TypeId) bool {
        if t == TYPE_NONE || self.macro_on {
            // Macro templates keep unresolved params: no per-instance layout exists.
            return false;
        }
        let k = unsafe (*self.p().module_ast_const(pm)).type_at(t).kind;
        if k == TypeKind::TYPE_BUILTIN || k == TypeKind::TYPE_POINTER || k == TypeKind::TYPE_REFERENCE || k == TypeKind::TYPE_FUNCTION || k == TypeKind::TYPE_DYN {
            return false;
        }
        return (self.zclass(pm, t) & 2) != 0;
    }

    /// Fold const-generic param `(pm, pnode)` through its bindings, innermost first, to its value's
    /// bits and integer type; false when no binding grounds it.
    pub fn fold_param(self: &Self, pm: ModuleId, pnode: NodeId, out: &mut i64, bt: &mut BuiltinType) bool {
        let mut k = self.subs.len();
        while k > 0 {
            k -= 1;
            let sb = *self.subs.at(k);
            if sb.pm == pm && sb.pnode == pnode && self.fold_cval_at(sb.am, sb.at, out, bt, (sb.lim as usize).min(k)) {
                return true;
            }
        }
        return false;
    }

    /// The element count of array type `y` (pool `pm`) under the active substitutions: its length,
    /// or its symbolic length folded through the bound const arguments; -1 when that does not fold.
    pub fn arr_len(self: &Self, pm: ModuleId, y: &Ty) i64 {
        if !y.arr_sym() {
            return y.as_data.arr.len;
        }
        // A count's bits are its value; anything past u32, negative or above i64::MAX, is no length.
        let mut v: i64 = 0;
        let mut bt = BuiltinType::BT_COUNT;
        if !self.fold_cval_at(pm, y.as_data.arr.len, &mut v, &mut bt, self.subs.len()) || v < 0 || v > 0xFFFFFFFFi64 {
            return -1;
        }
        return v;
    }

    // Innermost-wins WITH BACKTRACKING: merged demand chains can bind one param both to a sibling
    // generic (a cycle that never grounds) and, further out, to the real concrete type; when the
    // innermost route dead-ends, the next-outer binding of the same param is tried. A matched
    // frame's payload resolves only through frames BELOW it (its env when pushed), so a param
    // bound to a derived spelling of itself substitutes exactly once.
    fn resolve_from(
        self: &Self,
        pm: ModuleId,
        t: TypeId,
        rm: &mut ModuleId,
        rt: &mut TypeId,
        guard: u32,
        lim: usize,
        env: &mut usize,
    ) bool {
        let y = *unsafe (*self.p().module_ast_const(pm)).type_at(t);
        if y.kind == TypeKind::TYPE_ASSOC {
            // `T::Output`: the conformance's type, grounded (`assoc_norm`).
            let mut g = TYPE_NONE;
            if !self.ground_l(pm, t, pm, lim, &mut g, 0) {
                return false;
            }
            *rm = pm;
            *rt = g;
            *env = lim;
            return true;
        }
        if y.kind != TypeKind::TYPE_GENERIC {
            *rm = pm;
            *rt = t;
            *env = lim;
            return true;
        }
        if guard > 16 {
            return false;
        }
        let mut i = lim;
        while i > 0 {
            i -= 1;
            let sb = *self.subs.at(i);
            if sb.pm == y.module && sb.pnode == y.as_data.decl {
                let il = (sb.lim as usize).min(i);
                if self.resolve_from(sb.am, sb.at, rm, rt, guard + 1, il, env) {
                    return true;
                }
            }
        }
        return false;
    }

    // A module mangles as its last path segment alone when no other non-prelude module shares that
    // basename; collisions keep the full form for every involved module.
    fn short_pfx(self: &mut Self, m: ModuleId) bool {
        return unsafe self.short_table()[m as usize] != 0;
    }

    /// The short-prefix verdict of every module, by module index; sorting the basenames settles all
    /// of them at once.
    pub fn short_table(self: &mut Self) *const u8 {
        if self.short_ok != null {
            return self.short_ok;
        }
        let p = unsafe &*self.pkg;
        let n = p.modules.len();
        let mut kv = Vector::<BaseIdx>::with_capacity(n);
        for i in 0..n {
            let path = p.modules.at(i).path.as_str();
            kv.push(BaseIdx { key: path.slice(path_base_start(path), path.len()), idx: i as u32 });
        }
        kv.sort_by(base_idx_cmp);
        self.short_own.resize_default(n);
        let mut g: usize = 0;
        while g < n {
            // One group of equal basenames: a member is short when it has a path prefix and no
            // other member is a non-prelude module.
            let mut e = g;
            let mut users: usize = 0;
            while e < n && kv[e].key == kv[g].key {
                users += (!p.modules.at(kv[e].idx as usize).prelude) as usize;
                e += 1;
            }
            for k in g..e {
                let md = p.modules.at(kv[k].idx as usize);
                let others = users - (!md.prelude) as usize;
                self.short_own.set(kv[k].idx as usize, (path_base_start(md.path.as_str()) != 0 && others == 0) as u8);
            }
            g = e;
        }
        self.short_ok = self.short_own.as_ptr();
        return self.short_ok;
    }

    /// Take the short-prefix table of `from` (which must outlive this mangler) instead of computing
    /// it again.
    pub fn share_short(self: &mut Self, from: &mut Mangler) {
        self.short_ok = from.short_table();
    }

    /// Record the cross-TU edge for module `enc` (a module id, bit 15 set when the spelling
    /// was a type name) exactly as spelling it would (replay path for memoized renders and the
    /// per-TU cache).
    pub fn mark_used(self: &mut Self, enc: ModuleId) {
        let m = enc & 0x7FFF;
        let ty = (enc & 0x8000) != 0;
        if m as i64 != self.mark_ctx {
            let src = if self.mark_ctx < 0 {
                65534u64;
            } else {
                self.mark_ctx as u64;
            };
            let edge = src << 32 | enc as u64;
            if edge != self.last_edge {
                self.last_edge = edge;
                self.um_set(src, m, ty);
            }
        }
    }

    /// The matrix row of spelling context `src`: modules, then the package-level row (65534),
    /// then one row per owner module's instance shard.
    pub const fn um_row(self: &Self, src: u64) usize {
        let n = self.p().modules.len();
        if src == 65534u64 {
            return n;
        }
        if src >= CTX_INST as u64 {
            return n + 1 + (src - CTX_INST as u64) as usize;
        }
        return src as usize;
    }

    /// Words per matrix row.
    pub const fn um_w(self: &Self) usize {
        return (self.p().modules.len() + 63) / 64;
    }

    // The first word of row `r`, which takes zeroed words on first use.
    fn um_take(self: &mut Self, r: usize) usize {
        if self.um_slot.len() == 0 {
            self.um_slot.resize_default(2 * self.p().modules.len() + 1);
        }
        if self.um_slot[r] == 0 {
            let at = self.used_types.len();
            self.um_slot.set(r, at as u32 + 1);
            self.used_types.resize_default(at + self.um_w());
            self.used_syms.resize_default(at + self.um_w());
        }
        return (self.um_slot[r] - 1) as usize;
    }

    // The first word of row `r`; none when the row has no edge.
    const fn um_at(self: &Self, r: usize) Option<usize> {
        if self.um_slot.len() == 0 || self.um_slot[r] == 0 {
            return Option::<usize>::None;
        }
        return Option::Some((self.um_slot[r] - 1) as usize);
    }

    fn um_set(self: &mut Self, src: u64, dst: ModuleId, ty: bool) {
        if self.p().modules.len() == 0 {
            return;
        }
        let r = self.um_row(src);
        let i = self.um_take(r) + dst as usize / 64;
        let bit = 1u64 << (dst as u64 & 63);
        if ty {
            self.used_types.set(i, self.used_types[i] | bit);
        } else {
            self.used_syms.set(i, self.used_syms[i] | bit);
        }
    }

    /// Frontier merge: absorb shard `o`'s cross-TU row for TU `m` and its instance-aggregate
    /// requests (first module-order claimant wins, matching the serial loop).
    /// The used-mods row is an idempotent OR: absorbed once per shard, outside any demand range.
    pub fn sh_merge_um(self: &mut Self, o: &mut Mangler, m: u64) {
        let r0 = self.um_row(m) as u32;
        self.tn_take(o, r0, r0 + 1);
        self.um_or_row(o, r0 as usize);
    }

    // OR row `r` of shard `o` into this mangler's row `r`.
    fn um_or_row(self: &mut Self, o: &Mangler, r: usize) {
        if let Some(src) = o.um_at(r) {
            let dst = self.um_take(r);
            for k in 0..self.um_w() {
                self.used_types.set(dst + k, self.used_types[dst + k] | o.used_types[src + k]);
                self.used_syms.set(dst + k, self.used_syms[dst + k] | o.used_syms[src + k]);
            }
        }
    }

    // Append shard `o`'s type-need entries of the rows in `[lo, hi)` to this mangler's.
    fn tn_take(self: &mut Self, o: &Mangler, lo: u32, hi: u32) {
        for i in 0..o.tn_key.len() {
            let r = o.tn_row[i];
            if r >= lo && r < hi {
                self.tn_key.push(o.tn_key[i]);
                self.tn_row.push(r);
            }
        }
    }

    /// Frontier merge: absorb every package-level and instance-shard row of shard `o`.
    pub fn sh_merge_inst(self: &mut Self, o: &Mangler) {
        let n0 = self.p().modules.len() as u32;
        self.tn_take(o, n0, 2 * n0 + 1);
        for r in n0 as usize..o.um_slot.len() {
            self.um_or_row(o, r);
        }
    }

    /// Word `k` of context `src`'s row: bit `d` is set when the context spelled a type name (`ty`)
    /// or another symbol owned by module `k * 64 + d`.
    pub const fn um_word(self: &Self, src: u64, k: usize, ty: bool) u64 {
        return switch self.um_at(self.um_row(src)) {
            Some(i) => pick(ty, self.used_types[i + k], self.used_syms[i + k]),
            None => 0u64,
        };
    }

    /// Record in the current context's row that its C text uses the aggregate whose C name has
    /// FNV `h`: complete (`def`) or through a pointer only (see `tn_key`).
    pub fn need_name(self: &mut Self, h: u64, def: bool) {
        if !self.tn_on || self.no_edges {
            return;
        }
        let src = if self.mark_ctx < 0 {
            65534u64;
        } else {
            self.mark_ctx as u64;
        };
        let row = self.um_row(src);
        let k = h & 0xFFFFFFFFFFFFFFFEu64 | def as u64;
        let mix = k ^ (row as u64 + 1).wrapping_mul(0x9E3779B97F4A7C15u64);
        if self.tn_seen.len() == 0 {
            self.tn_seen.resize_default(1024);
        }
        let slot = (mix >> 54) as usize;
        if self.tn_seen[slot] == mix {
            return;
        }
        self.tn_seen.set(slot, mix);
        self.tn_key.push(k);
        self.tn_row.push(row as u32);
    }

    // True when the current context recently recorded the aggregate `(pm, t)` of the same kind
    // (`def`) under spelling state `g`: 0 for a concrete type (its name, and so its key, is a
    // function of the pool type alone), else the substitution generation. Records the query
    // otherwise. The caller checked `tn_on` and `no_edges`.
    fn tn_recent(self: &mut Self, pm: ModuleId, t: TypeId, def: bool, g: u64) bool {
        if self.tn_pre.len() == 0 {
            self.tn_pre.resize_default(1024);
        }
        let row = if self.mark_ctx < 0 {
            0xFFFFu64;
        } else {
            self.mark_ctx as u64;
        };
        let mr = ((row << 1 | def as u64) + 1).wrapping_mul(0x9E3779B97F4A7C15u64);
        let mt = (pm as u64 << 32 | t as u64).wrapping_mul(0xC2B2AE3D27D4EB4Fu64);
        let mix = mr ^ mt ^ g.wrapping_mul(0x165667B19E3779F9u64);
        let slot = (mix >> 54) as usize;
        if self.tn_pre[slot] == mix {
            return true;
        }
        self.tn_pre.set(slot, mix);
        return false;
    }

    /// Record that the current context needs the complete definition of `(pm, t)`: the text
    /// uses a value of it without spelling its type (a member access through a pointer, a
    /// dereference, a call result used in place).
    pub fn need_ty(self: &mut Self, pm: ModuleId, t: TypeId) {
        if !self.tn_on || self.no_edges || t == TYPE_NONE {
            return;
        }
        let y = *unsafe (*self.p().module_ast_const(pm)).type_at(t);
        // An instance's name is a function of the pool type and the substitutions.
        let fixed = y.concrete && (y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM);
        if (fixed || y.kind == TypeKind::TYPE_INSTANCE) && self.tn_recent(
            pm,
            t,
            true,
            pick(y.concrete, 0, self.subs_gen),
        ) {
            return;
        }
        let h = self.def_key(pm, t);
        if h != 0 {
            self.need_name(h, true);
        }
    }

    /// The FNV of the C name whose definition a by-value use of `(pm, t)` needs under the active
    /// substitutions (an aggregate, an instance, an array's element, a capturing closure's
    /// environment), spelled with no side effect; 0 when it has none (a C header defines it,
    /// or it is no aggregate).
    pub fn def_key(self: &mut Self, pm: ModuleId, t: TypeId) u64 {
        let mut rm = pm;
        let mut rt = t;
        if !self.resolve(pm, t, &mut rm, &mut rt) {
            return 0;
        }
        let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        if y.kind == TypeKind::TYPE_ARRAY {
            return self.def_key(rm, y.as_data.arr.elem);
        }
        if y.kind == TypeKind::TYPE_SIMD {
            // A vector's definition is its pack (`vec_pack`), named as its symbol segment.
            let mut nm = String::new();
            let ne = replace(&mut self.no_edges, true);
            let ok = self.type_m(rm, rt, &mut nm);
            self.no_edges = ne;
            return pick(ok, nm.as_str().hash(), 0u64);
        }
        let mut key: u64 = 0;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return self.decl_key(y.module, y.as_data.decl);
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            if y.concrete {
                key = 1u64 << 62 | rm as u64 << 32 | rt as u64;
            }
        } else if y.kind == TypeKind::TYPE_FUNCTION {
            let cf = unsafe (*self.p().module_ast_const(y.module)).closure_fact(y.as_data.decl);
            if cf == null || unsafe (&*cf).ncaps == 0 {
                return 0;
            }
            key = 1u64 << 61 | y.module as u64 << 32 | y.as_data.decl as u64;
        } else {
            return 0;
        }
        if key != 0 {
            switch self.tn_memo.get(&key) {
                Some(h) => {
                    return *h;
                },
                None => {},
            };
        }
        // Spell the name with no side effect: no use edge, no aggregate request.
        let agg = self.agg_on;
        let ne = self.no_edges;
        self.agg_on = false;
        self.no_edges = true;
        let mut nm = replace(&mut self.tn_buf, String::new());
        nm.clear();
        let mut ok = true;
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*self.p().module_ast_const(rm)).instance(y.as_data.inst);
            ok = self.inst_name(rm, &it, &mut nm);
        } else {
            self.closure_sym(y.module, y.as_data.decl, &mut nm);
            nm.push_str("_env");
        }
        self.no_edges = ne;
        self.agg_on = agg;
        let h = if ok {
            nm.as_str().hash();
        } else {
            0u64;
        };
        self.tn_buf = nm;
        if ok && key != 0 {
            self.tn_memo.insert(key, h);
        }
        return h;
    }

    // `def_key` of the non-generic aggregate `decl` of module `m` (0 for an extern one).
    fn decl_key(self: &mut Self, m: ModuleId, decl: NodeId) u64 {
        let dn = *unsafe (*self.p().module_ast_const(m)).at_const(decl);
        if dn.as_data.aggregate.is_extern {
            return 0;
        }
        let key = 1u64 << 63 | m as u64 << 32 | decl as u64;
        return switch self.tn_memo.get(&key) {
            Some(v) => *v,
            None => {
                let ne = self.no_edges;
                self.no_edges = true;
                let mut nm = replace(&mut self.tn_buf, String::new());
                nm.clear();
                self.qualified(m, dn.as_data.aggregate.name, &mut nm);
                self.no_edges = ne;
                let h9 = nm.as_str().hash();
                self.tn_buf = nm;
                self.tn_memo.insert(key, h9);
                h9;
            },
        };
    }

    /// The module whose complete type definitions a by-value use of `t` needs: an aggregate's
    /// declaring module, a generic instance's declaring module, an array's element owner, a
    /// capturing closure's module (its env struct is the value); -1 for everything else.
    pub fn owner_dep(self: &mut Self, pm: ModuleId, t: TypeId) i32 {
        let mut rm = pm;
        let mut rt = t;
        if !self.resolve(pm, t, &mut rm, &mut rt) {
            return -1;
        }
        let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            return y.module;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            return unsafe (*self.p().module_ast_const(rm)).instance(y.as_data.inst).module;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            return self.owner_dep(rm, y.as_data.arr.elem);
        }
        if y.kind == TypeKind::TYPE_FUNCTION {
            let cf = unsafe (*self.p().module_ast_const(y.module)).closure_fact(y.as_data.decl);
            if cf != null && unsafe (&*cf).ncaps != 0 {
                return y.module;
            }
        }
        return -1;
    }

    /// Merge a parallel shard's aggregate requests `[a0, a1)` and dyn requests `[d0, d1)` from `o`
    /// into this mangler (the master), deduplicating through the shared gates.
    pub fn sh_merge_range(self: &mut Self, o: &mut Mangler, a0: usize, a1: usize, d0: usize, d1: usize) {
        for i in a0..a1 {
            let k = o.sh_agg_k[i];
            let fresh = switch self.agg_seen.get(&k) {
                Some(_v) => false,
                None => true,
            };
            if fresh {
                self.agg_seen.insert(k, 1);
                let ar = o.agg_reqs.index_mut(i);
                let moved = replace(
                    ar,
                    AggReq { pm: 0, it: TyInstance { module: 0, decl: NODE_NONE, n: 0 }, subs: Vector::<MSub>::new() },
                );
                self.agg_reqs.push(moved);
            }
        }
        for i in d0..d1 {
            self.dyn_reqs.push(*o.dyn_reqs.at(i));
        }
    }

    /// Append module `m`'s symbol prefix (empty for a single-module build) and record the cross-TU
    /// use edge when a mark context is active: a type edge inside a C type spelling, none inside
    /// a symbol segment, else a symbol edge.
    pub fn modpfx(self: &mut Self, m: ModuleId, out: &mut String) {
        let ty = self.type_depth != 0;
        let enc = if ty {
            m | 0x8000;
        } else {
            m;
        };
        let rec = !self.no_edges && (ty || self.seg_depth == 0);
        if m as i64 != self.mark_ctx && rec {
            // A cross-TU symbol spelling: record the (spelling TU -> owner module) edge so the
            // writer can prune TUs no KEPT TU references (65534 = the shared instance TU) and
            // give the TU the owner's type or prototype header.
            let src = if self.mark_ctx < 0 {
                65534u64;
            } else {
                self.mark_ctx as u64;
            };
            let edge = src << 32 | enc as u64;
            if edge != self.last_edge {
                self.last_edge = edge;
                self.um_set(src, m, ty);
            }
        }
        if !self.mangle || self.p().modules.at(m as usize).prelude {
            return;
        }
        let path = self.p().modules.at(m as usize).path.as_str();
        let n = path.len();
        let mut i: usize = 0;
        if self.short_pfx(m) {
            i = path_base_start(path);
        }
        while i < n {
            if path.byte_at(i) == b':' && i + 1 < n && path.byte_at(i + 1) == b':' {
                out.push_str("__");
                i += 2;
            } else {
                out.push_byte(path.byte_at(i));
                i += 1;
            }
        }
        out.push_str("__");
    }

    /// The identifier at `s` in module `m`'s source, suffixed with one `_` when it is a C keyword or
    /// a standard-header macro name.
    pub fn ident(self: &mut Self, m: ModuleId, s: tok::Span, out: &mut String) {
        let src = self.p().modules.at(m as usize).source.as_str();
        let txt = src.slice(s.start as usize, s.end as usize);
        out.push_str(txt);
        if c_keyword(txt) || c_std_macro(txt) {
            out.push_str("_");
        }
    }

    /// An extern name as C spells it: the declared symbol, suffixed only when it is a C keyword. A
    /// standard-header macro of that name stays, since C code naming the symbol sees the same macro.
    pub fn c_ident(self: &mut Self, m: ModuleId, s: tok::Span, out: &mut String) {
        let src = self.p().modules.at(m as usize).source.as_str();
        let txt = src.slice(s.start as usize, s.end as usize);
        out.push_str(txt);
        if c_keyword(txt) {
            out.push_str("_");
        }
    }

    /// `<modpfx><Ident>` where the ident is `name_node`'s name span in its owner module.
    pub fn qualified(self: &mut Self, owner: ModuleId, name_node: NodeId, out: &mut String) {
        let st = out.len();
        self.modpfx(owner, out);
        let bare = out.len() == st;
        let s = unsafe (*self.p().module_ast_const(owner)).at_const(name_node).as_data.name.text;
        self.ident(owner, s, out);
        if bare {
            self.lib_escape(out, st);
        }
    }

    // Suffix one `_` to the unprefixed file-scope symbol `out[st..]` when a header the emitted C
    // includes declares that name: the symbol would redeclare it.
    fn lib_escape(self: &Self, out: &mut String, st: usize) {
        let sym = out.as_str().slice(st, out.len());
        if c_lib_family(sym) || self.lib_names.contains(&sym) {
            out.push_str("_");
        }
    }

    /// `<modpfx>closure_<node>` (`closure_b<index>` for a closure of the body arena): a hoisted
    /// closure's C symbol (generic-instantiation suffixes are appended by the caller that knows the
    /// instantiation).
    pub fn closure_sym(self: &mut Self, m: ModuleId, id: NodeId, out: &mut String) {
        self.modpfx(m, out);
        if Ast::in_body(id) {
            out.push_str("closure_b");
            out.push_u64(id & NODE_BODY_MASK);
        } else {
            out.push_str("closure_");
            out.push_u64(id);
        }
        if self.clos_sfx.len() != 0 {
            for i in 0..self.clos_ids.len() {
                if *self.clos_ids.at(i) == id {
                    out.push_string(&self.clos_sfx);
                    break;
                }
            }
        }
    }

    /// The symbol-alphabet spelling of pool type `(pm, t)`, as a symbol segment (see `seg_depth`;
    /// `type_name` spells a C type name). False when `t` is outside the frozen subset (symbolic,
    /// or a form not yet frozen); `out` may then hold a partial spelling the caller must discard.
    pub fn type_m(self: &mut Self, pm: ModuleId, t: TypeId, out: &mut String) bool {
        self.seg_depth += 1;
        let r = self.type_m_i(pm, t, out);
        self.seg_depth -= 1;
        return r;
    }

    /// `type_m` for a C type name the output spells: records type edges.
    pub fn type_name(self: &mut Self, pm: ModuleId, t: TypeId, out: &mut String) bool {
        self.type_depth += 1;
        let r = self.type_m(pm, t, out);
        self.type_depth -= 1;
        return r;
    }

    fn type_m_i(self: &mut Self, pm: ModuleId, t: TypeId, out: &mut String) bool {
        let a = self.p().module_ast_const(pm);
        let y = *unsafe (*a).type_at(t);
        if y.kind == TypeKind::TYPE_BUILTIN {
            out.push_str(bt_name(y.as_data.builtin));
            return true;
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            let nm = unsafe (*self.p().module_ast_const(y.module)).at_const(y.as_data.decl).as_data.aggregate.name;
            self.qualified(y.module, nm, out);
            return true;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            // `&T` and `&mut T` are distinct C types (`const T*` vs `T*`), so they mangle apart.
            let mut is_const = y.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8;
            if y.kind == TypeKind::TYPE_REFERENCE {
                is_const = y.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8;
            }
            out.push_str(if_s(is_const, "ptr_", "ptrm_"));
            return self.type_m(pm, y.as_data.elem, out);
        }
        if y.kind == TypeKind::TYPE_SLICE {
            out.push_str("slice_");
            return self.type_m(pm, y.as_data.elem, out);
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            let n = self.arr_len(pm, &y);
            if n >= 0 {
                out.push_str("arr");
                out.push_u64(n as u64);
                out.push_str("_");
            } else if self.macro_on {
                out.push_str("arr_");
            } else {
                return false;
            }
            return self.type_m(pm, y.as_data.arr.elem, out);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*a).instance(y.as_data.inst);
            return self.inst_name(pm, &it, out);
        }
        if y.is_vec() {
            // `__sc_v<N>_<lane>` and `__sc_mask<N>`: the runtime's reserved prefix, which no user type
            // spells.
            let n = self.arr_len(pm, &y);
            if n < 0 {
                return false;
            }
            out.push_str(if_s(y.kind == TypeKind::TYPE_SIMD, "__sc_v", "__sc_mask"));
            out.push_u64(n as u64);
            if y.kind == TypeKind::TYPE_MASK {
                return true;
            }
            out.push_str("_");
            return self.type_m(pm, y.as_data.arr.elem, out);
        }
        if y.fn_sig() {
            // `fn[m]<params>[r[<results>]]`, then each result and parameter: a signature's
            // spelling, whatever wrote it.
            let nr = unsafe (*a).sig_len(&y, true);
            let np = unsafe (*a).sig_len(&y, false);
            out.push_str(if_s((y.qualifier & FN_MOVE) != 0, "fnm", "fn"));
            out.push_u64(np);
            if nr != 0 {
                out.push_str("r");
                if nr != 1 {
                    out.push_u64(nr);
                }
            }
            for i in 0..nr + np {
                out.push_str("_");
                let st = if i < nr {
                    unsafe (*a).sig_at(&y, true, i);
                } else {
                    unsafe (*a).sig_at(&y, false, i - nr);
                };
                if !self.type_m(pm, st, out) {
                    return false;
                }
            }
            return true;
        }
        if y.kind == TypeKind::TYPE_FUNCTION {
            let cf = unsafe (*self.p().module_ast_const(y.module)).closure_fact(y.as_data.decl);
            if cf != null && unsafe (&*cf).is_closure {
                self.closure_sym(y.module, y.as_data.decl, out);
                return true;
            }
            if cf == null && unsafe (*self.p().module_ast_const(y.module)).at_const(y.as_data.decl).kind == NodeKind::NODE_FUNCTION {
                self.qualified(
                    y.module,
                    unsafe (*self.p().module_ast_const(y.module)).at_const(y.as_data.decl).as_data.function.name,
                    out,
                );
                return true;
            }
            out.push_str("fnt");
            out.push_u64(y.module);
            out.push_str("_");
            out.push_u64(y.as_data.decl);
            return true;
        }
        if y.kind == TypeKind::TYPE_CONST {
            push_cval(out, y.as_data.value, y.cbt());
            return true;
        }
        if y.kind == TypeKind::TYPE_FIELD_PROJECTION {
            // Reaching the mangler unresolved is an upstream bug; the distinctive symbol makes the
            // C error name the problem (mirrors the established emitter).
            out.push_str("__sc_unresolved_field_projection_");
            out.push_u64(y.as_data.proj.binder);
            return true;
        }
        if y.kind == TypeKind::TYPE_DYN {
            if y.qualifier == TypeQualifier::TYPE_QUAL_MUT as u8 {
                out.push_str("dynm_");
            } else if y.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8 {
                out.push_str("dyn_");
            } else {
                out.push_str("dynb_");
            }
            return self.dyn_stem(pm, &y, out);
        }
        if y.kind == TypeKind::TYPE_GENERIC || y.kind == TypeKind::TYPE_ASSOC {
            // Const-bound params fold HERE: each frame's payload grounds strictly below its own
            // env boundary (resolve-then-fold would re-apply the frame on its own payload).
            let mut cv: i64 = 0;
            let mut bt = BuiltinType::BT_COUNT;
            if y.kind == TypeKind::TYPE_GENERIC && self.fold_generic_d(&y, &mut cv, &mut bt, 0, self.subs.len()) {
                push_cval(out, cv, bt);
                return true;
            }
            let mut rm: ModuleId = 0;
            let mut rt = TYPE_NONE;
            let mut env: usize = 0;
            if self.resolve_env(pm, t, &mut rm, &mut rt, &mut env) {
                let h0 = self.hide_from(env, rm, rt);
                let ok = self.type_m(rm, rt, out);
                self.unhide(h0);
                return ok;
            }
            if self.macro_on && y.kind == TypeKind::TYPE_GENERIC {
                out.push_byte(1);
                out.push_str("_SCM_");
                self.generic_param_name(&y, out);
                return true;
            }
            // Unbound params never name symbols.
            return false;
        }
        if y.kind == TypeKind::TYPE_CONST_EXPR {
            let mut v: i64 = 0;
            let mut bt = BuiltinType::BT_COUNT;
            if !self.fold_cexpr(pm, t, &mut v, &mut bt) {
                return false;
            }
            push_cval(out, v, bt);
            return true;
        }
        if y.kind == TypeKind::TYPE_OPAQUE {
            // Each opaque type by its name: two register types (`@c.value`) differ in every symbol.
            let da = self.p().module_ast_const(y.module);
            out.push_str("o");
            self.ident(
                y.module,
                unsafe (*da).at_const(unsafe (*da).at_const(y.as_data.decl).as_data.type_alias.name).as_data.name.text,
                out,
            );
            return true;
        }
        out.push_str("v");
        return true;
    }

    // The source name of the generic-param decl behind an unresolved TYPE_GENERIC.
    fn generic_param_name(self: &mut Self, y: &Ty, out: &mut String) {
        let da = self.p().module_ast_const(y.module);
        let pn = unsafe (*da).at_const(y.as_data.decl);
        self.ident(y.module, unsafe (*da).at_const(pn.as_data.generic_param.name).as_data.name.text, out);
    }

    /// True when `(pm, t)` is the prelude `Global` allocator type (the trailing-arg elision rule).
    pub const fn is_global(self: &Self, pm: ModuleId, t: TypeId) bool {
        let y = *unsafe (*self.p().module_ast_const(pm)).type_at(t);
        return y.kind == TypeKind::TYPE_STRUCT && y.module == self.ph_global.mid && y.as_data.decl == self.ph_global.node;
    }

    /// The dyn family's shared stem: the qualified interface (or the structural `dynfn` signature
    /// spelling), then each instance argument, deliberately NOT resolved.
    pub fn dyn_stem(self: &mut Self, pm: ModuleId, dy: &Ty, out: &mut String) bool {
        self.seg_depth += 1;
        let r = self.dyn_stem_i(pm, dy, out);
        self.seg_depth -= 1;
        return r;
    }

    fn dyn_stem_i(self: &mut Self, pm: ModuleId, dy: &Ty, out: &mut String) bool {
        let a = self.p().module_ast_const(pm);
        let it = *unsafe (*a).instance(dy.as_data.inst);
        if it.decl == NODE_NONE {
            // A `dyn fn`: its signature's spelling.
            out.push_str("dyn");
            return self.type_m(pm, it.args[0], out);
        }
        let da = self.p().module_ast_const(it.module);
        self.qualified(it.module, unsafe (*da).at_const(it.decl).as_data.interface_def.name, out);
        return self.args_m(pm, &it, it.n, out);
    }

    /// Append `__<arg>` for the first `n` args of `it`; false when an arg has no spelling.
    pub fn args_m(self: &mut Self, pm: ModuleId, it: &TyInstance, n: u8, out: &mut String) bool {
        for i in 0..n {
            out.push_str("__");
            if !self.type_m(pm, unsafe it.args[i as usize], out) {
                return false;
            }
        }
        return true;
    }
    // A non-capturing function value's C declarator: `<ret> (*<decl>)(<params>)`. Reads the
    // declaring pool directly; pool-parametric spelling needs no reintern. A void return spells straight
    // into `out`; any other return wraps the declarator, which is built in a pooled buffer.
    fn fn_ptr_ctype(self: &mut Self, pm: ModuleId, y: &Ty, decl: str, out: &mut String) bool {
        // A function-pointer type reads its signature record in its own pool `pm`; a function or
        // closure item its declaration (or recorded facts) in its declaring module.
        let sm = if y.fn_sig() {
            pm;
        } else {
            y.module;
        };
        let fa = self.p().module_ast_const(sm);
        let cf = unsafe (*fa).closure_fact(y.as_data.decl);
        let nr = sig_len(fa, y, cf, true);
        if nr > 1 {
            // Several results return one result pack (`ret_pack`), as the functions do; the
            // declarator needs only its typedef.
            let mut tys = Vector::<TypeId>::new();
            for i in 0..nr {
                tys.push(sig_ty(fa, y, cf, true, i));
            }
            let st = out.len();
            let pd = replace(&mut self.ptr_depth, 1);
            let mut ok = self.ret_pack(sm, &tys, out);
            self.ptr_depth = pd;
            if ok {
                out.push_str(" ");
                ok = self.fn_ptr_decl(sm, fa, y, cf, decl, out);
            }
            if !ok {
                out.truncate(st);
            }
            return ok;
        }
        let mut rty = TYPE_NONE;
        if nr == 1 {
            rty = sig_ty(fa, y, cf, true, 0);
        }
        if nr == 1 && self.arr_result(sm, rty) {
            // A fixed array returns in its carrier (`ret_pack`), as the functions return it.
            let mut tys = Vector::<TypeId>::new();
            tys.push(rty);
            let st = out.len();
            let pd = replace(&mut self.ptr_depth, 1);
            let mut ok = self.ret_pack(sm, &tys, out);
            self.ptr_depth = pd;
            if ok {
                out.push_str(" ");
                ok = self.fn_ptr_decl(sm, fa, y, cf, decl, out);
            }
            if !ok {
                out.truncate(st);
            }
            return ok;
        }
        if rty == TYPE_NONE || self.is_zst(sm, rty) {
            let st = out.len();
            out.push_str("void ");
            if !self.fn_ptr_decl(sm, fa, y, cf, decl, out) {
                out.truncate(st);
                return false;
            }
            return true;
        }
        let mut inner = switch self.fp_bufs.pop() {
            Some(b) => b,
            None => String::new(),
        };
        let ok = self.fn_ptr_decl(sm, fa, y, cf, decl, &mut inner) && self.ctype(sm, rty, inner.as_str(), out);
        inner.truncate(0);
        self.fp_bufs.push(inner);
        return ok;
    }

    // `(*<decl>)(<params>)` of function value type `y` into `dst`. Zero-sized by-value params take no
    // slot (must match every lowered sig).
    fn fn_ptr_decl(
        self: &mut Self,
        sm: ModuleId,
        fa: *const Ast,
        y: &Ty,
        cf: *const ClosureFact,
        decl: str,
        dst: &mut String,
    ) bool {
        dst.push_str("(*");
        dst.push_str(decl);
        dst.push_str(")(");
        let st = dst.len();
        for i in 0..sig_len(fa, y, cf, false) {
            let pty = sig_ty(fa, y, cf, false, i);
            if self.is_zst(sm, pty) {
                continue;
            }
            if dst.len() != st {
                dst.push_str(", ");
            }
            if !self.ctype(sm, pty, "", dst) {
                return false;
            }
        }
        if dst.len() == st {
            dst.push_str("void");
        }
        dst.push_str(")");
        return true;
    }

    /// A `@c.export`/`@c.import` symbol pin: the attribute string verbatim. False when `owner`
    /// carries neither.
    pub fn sym_override(self: &mut Self, m: ModuleId, owner: NodeId, out: &mut String) bool {
        if self.pin_built.len() == 0 {
            self.pin_built.resize_default(self.p().modules.len());
        }
        let a = self.p().module_ast_const(m);
        if !self.pin_built[m as usize] {
            self.pin_built.set(m as usize, true);
            for i in 0..unsafe (*a).attrs.len() {
                let at = unsafe (*a).attrs.at(i);
                let k = skey_mix(0, m as u64 << 32 | at.owner as u64);
                let pin = at.kind == AttrKind::ATTR_EXPORT as u8 || at.kind == AttrKind::ATTR_IMPORT as u8;
                if pin && !self.pin_idx.contains_key(&k) {
                    self.pin_idx.insert(k, i as u64);
                }
            }
        }
        let ai: i64 = switch self.pin_idx.get(&skey_mix(0, m as u64 << 32 | owner as u64)) {
            Some(v) => (*v) as i64,
            None => -1,
        };
        if ai < 0 {
            return false;
        }
        let at = unsafe (*a).attrs.at(ai as usize);
        let src = self.p().modules.at(m as usize).source.as_str();
        out.push_str(src.slice(at.str_span.start as usize, at.str_span.end as usize));
        return true;
    }

    // The number of `from`/`try_from` (or same-named) methods across all extends targeting
    // (tmod, tdecl), scanning the target's module then `cur`: the two-module
    // compromise for overload counting without a package-wide walk. `name` is a span in `nmod`.
    fn overload_count(self: &mut Self, cur: ModuleId, tmod: ModuleId, tdecl: NodeId, nmod: ModuleId, name: tok::Span) i32 {
        let ntxt = self.p().modules.at(nmod as usize).source.as_str().slice(name.start as usize, name.end as usize);
        let mut key = 0xcbf29ce484222325u64;
        key = (key ^ cur as u64).wrapping_mul(1099511628211u64);
        key = (key ^ tmod as u64).wrapping_mul(1099511628211u64);
        key = (key ^ tdecl as u64).wrapping_mul(1099511628211u64);
        for i in 0..ntxt.len() {
            key = (key ^ ntxt.byte_at(i) as u64).wrapping_mul(1099511628211u64);
        }
        let hit = switch self.ovl_memo.get(&key) {
            Some(v) => (*v) as i64,
            None => (-1) as i64,
        };
        if hit >= 0 {
            return hit as i32;
        }
        let mut n: i32 = 0;
        let mut ns = 2;
        if tmod == cur {
            ns = 1;
        }
        for s in 0..ns {
            let mut m = tmod;
            if s == 1 {
                m = cur;
            }
            let a = self.p().module_ast_const(m);
            let msrc = self.p().modules.at(m as usize).source.as_str();
            let items = unsafe (*a).at_const((*a).root).as_data.program.items;
            for i in 0..items.len {
                let iid = unsafe (*a).list(items)[i as usize];
                let it = unsafe (*a).at_const(iid);
                if it.kind != NodeKind::NODE_EXTEND || it.as_data.extend_def.target_type == NODE_NONE {
                    continue;
                }
                let tg = unsafe (*a).resolution_def(it.as_data.extend_def.target_type);
                if tg.module != tmod || tg.node != tdecl {
                    continue;
                }
                let ms = it.as_data.extend_def.items;
                for j in 0..ms.len {
                    let mid = unsafe (*a).list(ms)[j as usize];
                    let mn = unsafe (*a).at_const(mid);
                    if mn.kind != NodeKind::NODE_FUNCTION {
                        continue;
                    }
                    let s2 = unsafe (*a).at_const(mn.as_data.function.name).as_data.name.text;
                    if msrc.slice(s2.start as usize, s2.end as usize) == ntxt {
                        n += 1;
                    }
                }
            }
        }
        self.ovl_memo.insert(key, n as u64);
        return n;
    }

    // Collision-conditional conformance suffix: when several extends of one target define the same
    // method name through different interface instantiations, the symbol carries the interface
    // name and its type arguments. `from`/`try_from` keep the param-derived conv suffix instead.
    fn iface_suffix(self: &mut Self, fm: ModuleId, fnode: NodeId, out: &mut String) bool {
        let ext = (self.owner_of(fm, fnode) >> 32) as NodeId;
        let a = self.p().module_ast_const(fm);
        if ext == NODE_NONE {
            return true;
        }
        let ity = unsafe (*a).at_const(ext).as_data.extend_def.interface_type;
        if ity == NODE_NONE {
            return true;
        }
        let name = unsafe (*a).at_const(unsafe (*a).at_const(fnode).as_data.function.name).as_data.name.text;
        let src = self.p().modules.at(fm as usize).source.as_str();
        let ntxt = src.slice(name.start as usize, name.end as usize);
        if ntxt == "from" || ntxt == "try_from" {
            return true;
        }
        let tg = unsafe (*a).resolution_def(unsafe (*a).at_const(ext).as_data.extend_def.target_type);
        if tg.node == NODE_NONE || self.overload_count(fm, tg.module, tg.node, fm, name) < 2 {
            return true;
        }
        let tr = unsafe (*a).resolution_def(ity);
        if tr.node == NODE_NONE {
            return true;
        }
        out.push_str("__");
        let inm = unsafe (*self.p().module_ast_const(tr.module)).at_const(tr.node).as_data.interface_def.name;
        self.ident(tr.module, unsafe (*self.p().module_ast_const(tr.module)).at_const(inm).as_data.name.text, out);
        if unsafe (*a).at_const(ity).kind != NodeKind::NODE_TYPE_PATH {
            return true;
        }
        let args = unsafe (*a).at_const(ity).as_data.type_path.args;
        for i in 0..args.len {
            let aid = unsafe (*a).list(args)[i as usize];
            if unsafe (*a).at_const(aid).kind == NodeKind::NODE_LIFETIME {
                continue;
            }
            let t = unsafe (*a).type_of(aid);
            if t == TYPE_NONE {
                continue;
            }
            out.push_str("__");
            if !self.type_m(fm, t, out) {
                return false;
            }
        }
        return true;
    }

    /// The C symbol of function `fnode` (module `fm`) with resolved extend target `target`
    /// (`target.node == NODE_NONE` = free function): pin | `[modpfx][Target__]name[suffix]`.
    pub fn fn_sym(self: &mut Self, fm: ModuleId, fnode: NodeId, target: DefId, out: &mut String) bool {
        if self.sym_override(fm, fnode, out) {
            return true;
        }
        let a = self.p().module_ast_const(fm);
        let fname = unsafe (*a).at_const(unsafe (*a).at_const(fnode).as_data.function.name).as_data.name.text;
        if unsafe (*a).at_const(fnode).as_data.function.is_extern() {
            // An extern function IS its C symbol: never prefixed, never suffixed.
            self.c_ident(fm, fname, out);
            return true;
        }
        let src = self.p().modules.at(fm as usize).source.as_str();
        let ftxt = src.slice(fname.start as usize, fname.end as usize);
        let is_main = target.node == NODE_NONE && ftxt == "main";
        let st = out.len();
        if !is_main {
            self.modpfx(fm, out);
        }
        let bare = !is_main && target.node == NODE_NONE && out.len() == st;
        if target.node != NODE_NONE {
            let bb = self.p().builtin_of_decl(target.module, target.node);
            if bb >= 0 {
                out.push_str(bt_name(bb as BuiltinType));
            } else if !self.spec_inst_name(fm, fnode, target, out) {
                let dn = unsafe (*self.p().module_ast_const(target.module)).at_const(target.node);
                let mut nm = dn.as_data.aggregate.name;
                if dn.kind == NodeKind::NODE_TYPE_ALIAS {
                    nm = dn.as_data.type_alias.name;
                }
                self.ident(
                    target.module,
                    unsafe (*self.p().module_ast_const(target.module)).at_const(nm).as_data.name.text,
                    out,
                );
            }
            out.push_str("__");
        }
        self.ident(fm, fname, out);
        if bare {
            self.lib_escape(out, st);
        }
        let params = unsafe (*a).at_const(fnode).as_data.function.params;
        let is_conv = ftxt == "from" || ftxt == "try_from";
        if is_conv && target.node != NODE_NONE && params.len != 0 {
            if self.overload_count(fm, target.module, target.node, fm, fname) < 2 {
                return true;
            }
            let p0 = unsafe (*a).list(params)[0];
            let p0ty = unsafe (*a).type_of(unsafe (*a).at_const(p0).as_data.parameter.ty);
            if p0ty == TYPE_NONE {
                return true;
            }
            out.push_str("__");
            return self.type_m(fm, p0ty, out);
        }
        if target.node != NODE_NONE {
            return self.iface_suffix(fm, fnode, out);
        }
        return true;
    }

    /// Spell into `out` the instance a non-generic extend of method `fnode` (module `fm`) writes as its
    /// target (`extend P<u8>`), so two such extends of one declaration name distinct functions, as the
    /// methods of generic extends spell their receiver's instance. False when the extend is generic or
    /// its target `target` names no instance.
    fn spec_inst_name(self: &mut Self, fm: ModuleId, fnode: NodeId, target: DefId, out: &mut String) bool {
        let ext = (self.owner_of(fm, fnode) >> 32) as NodeId;
        if ext == NODE_NONE {
            return false;
        }
        let a = self.p().module_ast_const(fm);
        let ed = unsafe (*a).at_const(ext).as_data.extend_def;
        let pat = unsafe (*a).type_of(ed.target_type);
        if ed.generics.len != 0 || pat == TYPE_NONE || unsafe (*a).type_at(pat).kind != TypeKind::TYPE_INSTANCE {
            return false;
        }
        let it = *unsafe (*a).instance(unsafe (*a).type_at(pat).as_data.inst);
        if it.module != target.module || it.decl != target.node {
            return false;
        }
        return self.inst_name(fm, &it, out);
    }

    /// The resolved extend target of method `fnode` in module `m`, or `node == NODE_NONE` when the
    /// function is free-standing. Plan-time item scan.
    pub fn method_target(self: &mut Self, m: ModuleId, fnode: NodeId) DefId {
        let ext = (self.owner_of(m, fnode) >> 32) as NodeId;
        if ext == NODE_NONE {
            return DefId { module: m, node: NODE_NONE };
        }
        let a = self.p().module_ast_const(m);
        if unsafe (*a).at_const(ext).as_data.extend_def.target_type == NODE_NONE {
            return DefId { module: m, node: NODE_NONE };
        }
        return unsafe (*a).resolution_def(unsafe (*a).at_const(ext).as_data.extend_def.target_type);
    }

    /// The extend owning `fnode` (NODE_NONE when free-standing).
    pub fn extend_of(self: &mut Self, m: ModuleId, fnode: NodeId) NodeId {
        return (self.owner_of(m, fnode) >> 32) as NodeId;
    }

    /// The interface declaring member `fnode` (its default body emits per conforming type), or
    /// NODE_NONE when the function is not an interface member.
    pub fn in_interface(self: &mut Self, m: ModuleId, fnode: NodeId) NodeId {
        return (self.owner_of(m, fnode) & 0xFFFFFFFF) as NodeId;
    }

    /// Does the extend that owns `fnode` declare generic parameters (its methods emit per receiver
    /// instance, outside the frozen non-generic symbol families)?
    pub fn in_generic_extend(self: &mut Self, m: ModuleId, fnode: NodeId) bool {
        let ext = (self.owner_of(m, fnode) >> 32) as NodeId;
        if ext == NODE_NONE {
            return false;
        }
        return unsafe (*self.p().module_ast_const(m)).at_const(ext).as_data.extend_def.generics.len != 0;
    }

    /// The C symbol of const/static item `cnode` (module `m`): top-level items spell their qualified
    /// name, associated consts `<m prefix><Target>__<NAME>`; module `m` defines both.
    pub fn const_sym(self: &mut Self, m: ModuleId, cnode: NodeId, out: &mut String) bool {
        if self.sym_override(m, cnode, out) {
            return true;
        }
        let a = self.p().module_ast_const(m);
        if unsafe (*a).at_const(cnode).kind == NodeKind::NODE_CONST && unsafe (*a).at_const(cnode).as_data.const_def.is_extern {
            // An extern-block static binds the C symbol the header declares.
            self.c_ident(
                m,
                unsafe (*a).at_const(unsafe (*a).at_const(cnode).as_data.const_def.name).as_data.name.text,
                out,
            );
            return true;
        }
        let tgt = self.method_target(m, cnode);
        if tgt.node == NODE_NONE {
            self.qualified(m, unsafe (*a).at_const(cnode).as_data.const_def.name, out);
            if unsafe (*a).at_const(cnode).as_data.const_def.is_local {
                // Another body may declare a constant of the same name.
                out.push_str("__l");
                out.push_u64(cnode);
            }
            return true;
        }
        // The declaring module prefixes the symbol and owns its definition (the spelling records
        // the edge to it).
        self.modpfx(m, out);
        let bb = self.p().builtin_of_decl(tgt.module, tgt.node);
        if bb >= 0 {
            out.push_str(bt_name(bb as BuiltinType));
        } else if !self.spec_inst_name(m, cnode, tgt, out) {
            // A specialized extend (`extend P<u8>`) names its instance, as its methods do: disjoint
            // extends may each define the constant.
            let dn = unsafe (*self.p().module_ast_const(tgt.module)).at_const(tgt.node);
            let mut nm = dn.as_data.aggregate.name;
            if dn.kind == NodeKind::NODE_TYPE_ALIAS {
                nm = dn.as_data.type_alias.name;
            }
            self.ident(tgt.module, unsafe (*self.p().module_ast_const(tgt.module)).at_const(nm).as_data.name.text, out);
        }
        out.push_str("__");
        self.ident(m, unsafe (*a).at_const(unsafe (*a).at_const(cnode).as_data.const_def.name).as_data.name.text, out);
        return true;
    }

    /// The C symbol of the method named `mname` extending resolved aggregate `(rm, rt)`, when one
    /// exists: instance receivers spell `<InstName>__<m>`, concrete ones the frozen fn symbol.
    pub fn method_by_name(self: &mut Self, rm: ModuleId, rt: TypeId, mname: str, out: &mut String) bool {
        let mut tg = DefId { module: 0, node: NODE_NONE };
        let md = self.find_method(rm, rt, mname, &mut tg);
        self.last_method_def = md;
        if md.node == NODE_NONE {
            return false;
        }
        let mut it = TyInstance {};
        if unsafe (*self.p().module_ast_const(rm)).targs_of(rt, &mut it) {
            if !self.inst_name(rm, &it, out) {
                return false;
            }
            out.push_str("__");
            out.push_str(mname);
            // The instance body's prototype lives in the method's module.
            self.mark_used(md.module);
            return true;
        }
        return self.fn_sym(md.module, md.node, tg, out);
    }

    /// `method_by_name` restricted to the methods extend `ext` of module `em` itself defines: the
    /// method a chosen conformance provides when several conformances define `mname`.
    pub fn method_in_ext(
        self: &mut Self,
        rm: ModuleId,
        rt: TypeId,
        em: ModuleId,
        ext: NodeId,
        mname: str,
        out: &mut String,
    ) bool {
        let ea = self.p().module_ast_const(em);
        let esrc = self.p().modules.at(em as usize).source.as_str();
        let ms = unsafe (*ea).at_const(ext).as_data.extend_def.items;
        let mut md = DefId { module: 0, node: NODE_NONE };
        for j in 0..ms.len {
            let mid = unsafe (*ea).list(ms)[j as usize];
            let mn = unsafe (*ea).at_const(mid);
            if mn.kind != NodeKind::NODE_FUNCTION {
                continue;
            }
            let s2 = unsafe (*ea).at_const(mn.as_data.function.name).as_data.name.text;
            if esrc.slice(s2.start as usize, s2.end as usize) == mname {
                md = DefId { module: em, node: mid };
                break;
            }
        }
        if md.node == NODE_NONE {
            return false;
        }
        self.last_method_def = md;
        let mut it = TyInstance {};
        // A generic extend's method emits per receiver instance; a concrete extend's has its own symbol.
        if unsafe (*ea).at_const(ext).as_data.extend_def.generics.len != 0 && unsafe (*self.p().module_ast_const(rm)).targs_of(
            rt,
            &mut it,
        ) {
            if !self.inst_name(rm, &it, out) {
                return false;
            }
            out.push_str("__");
            out.push_str(mname);
            self.mark_used(md.module);
            return true;
        }
        let tg = unsafe (*ea).resolution_def(unsafe (*ea).at_const(ext).as_data.extend_def.target_type);
        return self.fn_sym(md.module, md.node, tg, out);
    }

    /// The method named `mname` extending resolved aggregate `(rm, rt)` (node NONE when none), and
    /// in `tg` the declaration its extend targets. Spells nothing, so a query that only asks whether
    /// the method exists records no use edge and no aggregate request.
    pub fn find_method(self: &mut Self, rm: ModuleId, rt: TypeId, mname: str, tg: &mut DefId) DefId {
        let none = DefId { module: 0, node: NODE_NONE };
        let a = self.p().module_ast_const(rm);
        let y = *unsafe (*a).type_at(rt);
        let mut dm = y.module;
        let mut dd = NODE_NONE;
        let mut it = TyInstance { module: 0, decl: NODE_NONE, n: 0 };
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            dd = y.as_data.decl;
        } else if unsafe (*a).targs_of(rt, &mut it) {
            dm = it.module;
            dd = it.decl;
        }
        if dd == NODE_NONE && y.kind != TypeKind::TYPE_BUILTIN {
            return none;
        }
        let mut miss_key = if dd == NODE_NONE {
            1u64 << 63 | y.as_data.builtin as u64;
        } else {
            dm as u64 << 32 | dd as u64;
        };
        for i in 0..mname.len() {
            miss_key = (miss_key ^ mname.byte_at(i) as u64).wrapping_mul(1099511628211u64);
        }
        miss_key = skey_mix(0, miss_key);
        if self.miss_memo.contains(&miss_key) {
            return none;
        }
        if dd == NODE_NONE {
            // Builtin receivers: their extends usually live in the prelude, but any module
            // may extend a builtin (std::parallel's AtomicOps conformances do).
            let bt = y.as_data.builtin as i32;
            for pm2 in 0..self.p().modules.len() {
                if !self.p().modules.at(pm2).has_ast {
                    continue;
                }
                let pa = self.p().module_ast_const(pm2 as ModuleId);
                let pits = unsafe (*pa).at_const((*pa).root).as_data.program.items;
                let psrc = self.p().modules.at(pm2).source.as_str();
                for i2 in 0..pits.len {
                    let iid2 = unsafe (*pa).list(pits)[i2 as usize];
                    let it2 = unsafe (*pa).at_const(iid2);
                    if it2.kind != NodeKind::NODE_EXTEND || it2.as_data.extend_def.target_type == NODE_NONE {
                        continue;
                    }
                    let tg2 = unsafe (*pa).resolution_def(it2.as_data.extend_def.target_type);
                    if tg2.node == NODE_NONE || self.p().builtin_of_decl(tg2.module, tg2.node) != bt {
                        continue;
                    }
                    let ms2 = it2.as_data.extend_def.items;
                    for j2 in 0..ms2.len {
                        let mid2 = unsafe (*pa).list(ms2)[j2 as usize];
                        let mn2 = unsafe (*pa).at_const(mid2);
                        if mn2.kind != NodeKind::NODE_FUNCTION {
                            continue;
                        }
                        let s3 = unsafe (*pa).at_const(mn2.as_data.function.name).as_data.name.text;
                        if psrc.slice(s3.start as usize, s3.end as usize) == mname {
                            *tg = tg2;
                            return DefId { module: pm2 as ModuleId, node: mid2 };
                        }
                    }
                }
            }
            self.miss_memo.insert(miss_key);
            return none;
        }
        // Extends may live in ANY module (a downstream module extending a foreign type): the
        // decl's own module first (the overwhelmingly common case), then the rest. An extend whose
        // target this instance does not match is skipped, and then a miss is not memoized.
        let mut skipped = false;
        let mut xm: i64 = 0 - 1;
        while xm < self.p().modules.len() as i64 {
            let em2 = if xm < 0 {
                dm;
            } else {
                xm as ModuleId;
            };
            xm += 1;
            if xm > 0 && em2 == dm {
                // Already scanned first.
                continue;
            }
            if !self.p().modules.at(em2 as usize).has_ast {
                continue;
            }
            let da = self.p().module_ast_const(em2);
            let items = unsafe (*da).at_const((*da).root).as_data.program.items;
            let dsrc = self.p().modules.at(em2 as usize).source.as_str();
            for i in 0..items.len {
                let iid = unsafe (*da).list(items)[i as usize];
                let itn = unsafe (*da).at_const(iid);
                if itn.kind != NodeKind::NODE_EXTEND || itn.as_data.extend_def.target_type == NODE_NONE {
                    continue;
                }
                let tgi = unsafe (*da).resolution_def(itn.as_data.extend_def.target_type);
                if tgi.module != dm || tgi.node != dd {
                    continue;
                }
                let ms = itn.as_data.extend_def.items;
                for j in 0..ms.len {
                    let mid = unsafe (*da).list(ms)[j as usize];
                    let mn = unsafe (*da).at_const(mid);
                    if mn.kind != NodeKind::NODE_FUNCTION {
                        continue;
                    }
                    let s2 = unsafe (*da).at_const(mn.as_data.function.name).as_data.name.text;
                    if dsrc.slice(s2.start as usize, s2.end as usize) != mname {
                        continue;
                    }
                    if it.decl != NODE_NONE && !self.ext_applies_inst(em2, iid, rm, &it) {
                        skipped = true;
                        continue;
                    }
                    *tg = DefId { module: dm, node: dd };
                    return DefId { module: em2, node: mid };
                }
            }
        }
        if !skipped {
            self.miss_memo.insert(miss_key);
        }
        return none;
    }

    /// The extend conforming resolved aggregate `(rm, rt)` to interface `iface` that applies to it,
    /// with its module in `em`; NODE_NONE when none does.
    pub fn conform_ext(self: &mut Self, rm: ModuleId, rt: TypeId, iface: DefId, em: &mut ModuleId) NodeId {
        let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        let mut it = TyInstance { module: y.module, decl: NODE_NONE, n: 0 };
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            it.decl = y.as_data.decl;
        } else if !unsafe (*self.p().module_ast_const(rm)).targs_of(rt, &mut it) {
            return NODE_NONE;
        }
        let key = skey_mix(
            skey_mix(0, it.module as u64 << 32 | it.decl as u64),
            iface.module as u64 << 32 | iface.node as u64,
        );
        switch self.conf_memo.get(&key) {
            Some(v) => {
                *em = (*v >> 32) as ModuleId;
                return (*v) as NodeId;
            },
            None => {},
        };
        for xm in 0..self.p().modules.len() {
            if !self.p().modules.at(xm).has_ast {
                continue;
            }
            let da = self.p().module_ast_const(xm as ModuleId);
            let items = unsafe (*da).at_const((*da).root).as_data.program.items;
            for i in 0..items.len {
                let iid = unsafe (*da).list(items)[i as usize];
                let ed = unsafe (*da).at_const(iid).as_data.extend_def;
                if unsafe (*da).at_const(iid).kind != NodeKind::NODE_EXTEND || ed.interface_type == NODE_NONE {
                    continue;
                }
                let ir = unsafe (*da).resolution_def(ed.interface_type);
                let tg = unsafe (*da).resolution_def(ed.target_type);
                if ir.module != iface.module || ir.node != iface.node || tg.module != it.module || tg.node != it.decl {
                    continue;
                }
                let pat = unsafe (*da).type_of(ed.target_type);
                if ext_is_identity(unsafe &*da, pat, unsafe &*da, xm as ModuleId, iid) {
                    self.conf_memo.insert(key, xm as u64 << 32 | iid as u64);
                } else if it.n == 0 || !self.ext_applies_inst(xm as ModuleId, iid, rm, &it) {
                    continue;
                }
                *em = xm as ModuleId;
                return iid;
            }
        }
        return NODE_NONE;
    }

    /// Whether extend `ext` of module `em` applies to instance `it` (arguments in pool `rm`, resolved
    /// through the substitution stack): every argument its target constrains matches (`xarg_of`).
    pub fn ext_applies_inst(self: &mut Self, em: ModuleId, ext: NodeId, rm: ModuleId, it: &TyInstance) bool {
        let ea = self.p().module_ast_const(em);
        let pat = unsafe (*ea).type_of(unsafe (*ea).at_const(ext).as_data.extend_def.target_type);
        if ext_is_identity(unsafe &*ea, pat, unsafe &*ea, em, ext) {
            return true;
        }
        let mut pi = TyInstance {};
        let _ = unsafe (*ea).targs_of(pat, &mut pi);
        let gens = unsafe (*ea).at_const(ext).as_data.extend_def.generics;
        let np = ext_arity(unsafe &*ea, ext, pi.n);
        if np > it.n {
            return false;
        }
        for j in 0..np {
            let pj = unsafe pi.args[j as usize];
            let x = xarg_of(unsafe &*ea, pj, unsafe &*ea, em, gens);
            if x.kind == XA_FIXED {
                let mut g = TYPE_NONE;
                if !self.ground(rm, unsafe it.args[j as usize], rm, &mut g) || g != pj {
                    return false;
                }
            } else if x.kind == XA_FORM {
                let mut v: i64 = 0;
                let mut vbt = BuiltinType::BT_COUNT;
                let mut q = i128::zero();
                let bt = self.p().const_param_bt(em, unsafe (*ea).list(gens)[x.par as usize]);
                if !self.fold_cval_at(rm, unsafe it.args[j as usize], &mut v, &mut vbt, self.subs.len()) || !xarg_solve(
                    &x,
                    cval_exact(v, vbt),
                    bt,
                    lay::target_for(self.p().arch).ptr == 4,
                    &mut q,
                ) {
                    return false;
                }
            } else if x.kind != XA_PARAM {
                return false;
            }
        }
        return true;
    }

    /// The `free` method the first extend of declaration `(dm, dd)` in its own module that has one
    /// defines, or NODE_NONE; `ext` receives that extend.
    pub fn free_method(self: &mut Self, dm: ModuleId, dd: NodeId, ext: &mut NodeId) NodeId {
        let key = skey_mix(0, dm as u64 << 32 | dd as u64);
        switch self.free_memo.get(&key) {
            Some(v) => {
                *ext = (*v >> 32) as NodeId;
                return (*v & 0xFFFFFFFFu64) as NodeId;
            },
            None => {},
        };
        let mid = self.free_method_scan(dm, dd, ext);
        self.free_memo.insert(key, (*ext) as u64 << 32 | mid as u64);
        return mid;
    }

    fn free_method_scan(self: &Self, dm: ModuleId, dd: NodeId, ext: &mut NodeId) NodeId {
        *ext = NODE_NONE;
        let da = self.p().module_ast_const(dm);
        let items = unsafe (*da).at_const((*da).root).as_data.program.items;
        let dsrc = self.p().modules.at(dm as usize).source.as_str();
        for i in 0..items.len {
            let iid = unsafe (*da).list(items)[i as usize];
            let itn = unsafe (*da).at_const(iid);
            if itn.kind != NodeKind::NODE_EXTEND || itn.as_data.extend_def.target_type == NODE_NONE {
                continue;
            }
            let tg = unsafe (*da).resolution_def(itn.as_data.extend_def.target_type);
            if tg.module != dm || tg.node != dd {
                continue;
            }
            let ms = itn.as_data.extend_def.items;
            for j in 0..ms.len {
                let mid = unsafe (*da).list(ms)[j as usize];
                let mn = unsafe (*da).at_const(mid);
                if mn.kind != NodeKind::NODE_FUNCTION {
                    continue;
                }
                let s2 = unsafe (*da).at_const(mn.as_data.function.name).as_data.name.text;
                if dsrc.slice(s2.start as usize, s2.end as usize) == "free" {
                    *ext = iid;
                    return mid;
                }
            }
        }
        return NODE_NONE;
    }

    /// The destructor call target for resolved aggregate type `(rm, rt)`: the user `free` method
    /// when one extends the declaration and `user` is set, else the derived per-TU glue
    /// `<name>__free__d`. The caller clears `user` for an instance the `free` extend's bounds do
    /// not cover.
    pub fn free_target(self: &mut Self, rm: ModuleId, rt: TypeId, user: bool, out: &mut String) bool {
        let a = self.p().module_ast_const(rm);
        let y = *unsafe (*a).type_at(rt);
        if y.kind == TypeKind::TYPE_FUNCTION {
            // A closure dropped without ever being called: no user `free` can extend a closure, so
            // its destructor is always the derived env glue (which frees the owning captures).
            let cf = unsafe (*self.p().module_ast_const(y.module)).closure_fact(y.as_data.decl);
            if cf == null || !unsafe (&*cf).is_closure {
                return false;
            }
            if !self.type_m(rm, rt, out) {
                return false;
            }
            out.push_str("__free__d");
            self.mark_used(y.module);
            return true;
        }
        let mut dm = y.module;
        let mut dd = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            dd = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*a).instance(y.as_data.inst);
            dm = it.module;
            dd = it.decl;
        }
        if dd == NODE_NONE {
            return false;
        }
        let mut ext = NODE_NONE;
        let mid = if user {
            self.free_method(dm, dd, &mut ext);
        } else {
            NODE_NONE;
        };
        if mid != NODE_NONE {
            if y.kind == TypeKind::TYPE_INSTANCE {
                let it2 = *unsafe (*a).instance(y.as_data.inst);
                if !self.inst_name(rm, &it2, out) {
                    return false;
                }
                out.push_str("__free");
                self.mark_used(dm);
                return true;
            }
            return self.fn_sym(dm, mid, DefId { module: dm, node: dd }, out);
        }
        if !self.type_m(rm, rt, out) {
            return false;
        }
        out.push_str("__free__d");
        self.mark_used(dm);
        return true;
    }

    /// The C constant naming variant `variant` of enum `decl` in module `m`: RAW source spans
    /// (deliberately no keyword suffix, unlike the enum's own typedef name), suffixed with one `_`
    /// when the joined name is a standard-header macro (`EXIT` + `SUCCESS`); extern enums use the
    /// header's bare variant constant.
    pub fn enum_tag(self: &mut Self, m: ModuleId, decl: NodeId, variant: NodeId, out: &mut String) {
        let a = self.p().module_ast_const(m);
        let src = self.p().modules.at(m as usize).source.as_str();
        let vs = unsafe (*a).at_const(unsafe (*a).at_const(variant).as_data.variant.name).as_data.name.text;
        if unsafe (*a).at_const(decl).as_data.aggregate.is_extern {
            out.push_str(src.slice(vs.start as usize, vs.end as usize));
            return;
        }
        if self.tn_on && unsafe (*a).at_const(decl).as_data.aggregate.generics.len == 0 {
            // The constant is an enumerator of the enum's definition.
            let h = self.decl_key(m, decl);
            if h != 0 {
                self.need_name(h, true);
            }
        }
        let start = out.len();
        self.modpfx(m, out);
        let es = unsafe (*a).at_const(unsafe (*a).at_const(decl).as_data.aggregate.name).as_data.name.text;
        out.push_str(src.slice(es.start as usize, es.end as usize));
        out.push_str("_");
        out.push_str(src.slice(vs.start as usize, vs.end as usize));
        if c_std_macro(out.as_str().slice(start, out.len())) {
            out.push_str("_");
        }
        self.lib_escape(out, start);
    }

    // `<base><sep><decl>` where the separator is empty for an empty or `[`-leading declarator.
    fn join_decl(self: &mut Self, base: str, decl: str, out: &mut String) {
        out.push_str(base);
        if decl.len() != 0 && decl.byte_at(0) != b'[' {
            out.push_str(" ");
        }
        out.push_str(decl);
    }

    /// The full C declarator `<type> <decl>` of pool type `(pm, t)`, including east-const on pointer-to-pointer and array/function spirals. False when
    /// `t` needs an unfrozen family (dyn value types, non-capturing fn pointers).
    pub fn ctype(self: &mut Self, pm: ModuleId, t: TypeId, decl: str, out: &mut String) bool {
        self.type_depth += 1;
        let r = self.ctype_i(pm, t, decl, out);
        self.type_depth -= 1;
        return r;
    }

    fn ctype_i(self: &mut Self, pm: ModuleId, t: TypeId, decl: str, out: &mut String) bool {
        let a = self.p().module_ast_const(pm);
        let y = *unsafe (*a).type_at(t);
        if y.kind == TypeKind::TYPE_BUILTIN {
            self.join_decl(bt_c_decl(y.as_data.builtin), decl, out);
            return true;
        }
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            // Base spellings go straight into `out`, then the declarator follows (join_decl with an
            // empty base): no temporary per spelling on this path.
            let dn = unsafe (*self.p().module_ast_const(y.module)).at_const(y.as_data.decl);
            if dn.as_data.aggregate.is_extern {
                if !self.sym_override(y.module, y.as_data.decl, out) {
                    self.c_ident(
                        y.module,
                        unsafe (*self.p().module_ast_const(y.module)).at_const(dn.as_data.aggregate.name).as_data.name.text,
                        out,
                    );
                }
            } else {
                let st = out.len();
                self.qualified(y.module, dn.as_data.aggregate.name, out);
                if self.tn_on && !self.no_edges && !self.tn_recent(pm, t, self.ptr_depth == 0, 0) {
                    self.need_name(out.as_str().slice(st, out.len()).hash(), self.ptr_depth == 0);
                }
            }
            self.join_decl("", decl, out);
            return true;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
            self.ptr_depth += 1;
            let ok = self.ctype_ptr(pm, &y, decl, out);
            self.ptr_depth -= 1;
            return ok;
        }
        if y.kind == TypeKind::TYPE_SLICE {
            self.join_decl("SCslice", decl, out);
            return true;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            let n = self.arr_len(pm, &y);
            if n < 0 {
                return false;
            }
            let mut inner = String::new();
            if n != 0 {
                inner.push_str(decl);
                inner.push_str("[");
                inner.push_u64(n as u64);
                inner.push_str("]");
                return self.arr_elem_ctype(pm, y.as_data.elem, inner.as_str(), out);
            }
            // A zero-length array is zero-sized: no value, member or parameter of it is declared.
            // A macro template, which has no layout to elide by, spells it as a pointer.
            inner.push_str("*");
            inner.push_str(decl);
            self.ptr_depth += 1;
            let ok = self.ctype(pm, y.as_data.elem, inner.as_str(), out);
            self.ptr_depth -= 1;
            return ok;
        }
        if y.kind == TypeKind::TYPE_MASK {
            // Lane `i` is bit `i` of the smallest unsigned integer that holds the lanes.
            let n = self.arr_len(pm, &y);
            if n < 0 {
                return false;
            }
            self.join_decl(
                if n <= 8 {
                    "uint8_t";
                } else if n <= 16 {
                    "uint16_t";
                } else if n <= 32 {
                    "uint32_t";
                } else {
                    "uint64_t";
                },
                decl,
                out,
            );
            return true;
        }
        if y.kind == TypeKind::TYPE_SIMD {
            let st = out.len();
            if !self.vec_pack(pm, t, &y, out) {
                out.truncate(st);
                return false;
            }
            self.join_decl("", decl, out);
            return true;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*a).instance(y.as_data.inst);
            let st = out.len();
            if !self.inst_name(pm, &it, out) {
                out.truncate(st);
                return false;
            }
            if self.tn_on && !self.no_edges && !self.tn_recent(
                pm,
                t,
                self.ptr_depth == 0,
                pick(y.concrete, 0, self.subs_gen),
            ) {
                self.need_name(out.as_str().slice(st, out.len()).hash(), self.ptr_depth == 0);
            }
            self.join_decl("", decl, out);
            return true;
        }
        if y.kind == TypeKind::TYPE_OPAQUE {
            // An opaque handle is spelled as C spells it: the `@c.import` pin when present (headers
            // that only declare the TAG need `struct x` written out), else the source name.
            if !self.sym_override(y.module, y.as_data.decl, out) {
                let dn = unsafe (*self.p().module_ast_const(y.module)).at_const(y.as_data.decl);
                self.c_ident(
                    y.module,
                    unsafe (*self.p().module_ast_const(y.module)).at_const(dn.as_data.type_alias.name).as_data.name.text,
                    out,
                );
            }
            self.join_decl("", decl, out);
            return true;
        }
        if y.kind == TypeKind::TYPE_FUNCTION {
            let cf = unsafe (*self.p().module_ast_const(y.module)).closure_fact(y.as_data.decl);
            if cf != null && unsafe (&*cf).ncaps != 0 {
                let st = out.len();
                self.closure_sym(y.module, y.as_data.decl, out);
                if self.tn_on {
                    self.need_name(fnv_more(out.as_str().slice(st, out.len()).hash(), "_env"), self.ptr_depth == 0);
                }
                self.join_decl("_env", decl, out);
                return true;
            }
            // A function pointer's result and parameters need no definition to declare it.
            self.ptr_depth += 1;
            let ok = self.fn_ptr_ctype(pm, &y, decl, out);
            self.ptr_depth -= 1;
            return ok;
        }
        return self.ctype_rest(pm, t, &y, decl, out);
    }

    // The element `(pm, t)` of an array declarator `decl`: C needs it complete even below a pointer.
    fn arr_elem_ctype(self: &mut Self, pm: ModuleId, t: TypeId, decl: str, out: &mut String) bool {
        let pd = replace(&mut self.ptr_depth, 0);
        let ok = self.ctype(pm, t, decl, out);
        self.ptr_depth = pd;
        return ok;
    }

    // The pointer or reference `y` (of pool `pm`) around `decl`: the pointee spelling, east-const
    // placement, pointer-to-array spirals.
    fn ctype_ptr(self: &mut Self, pm: ModuleId, y: &Ty, decl: str, out: &mut String) bool {
        let mut elm = pm;
        let mut elt = y.as_data.elem;
        if !self.resolve(pm, y.as_data.elem, &mut elm, &mut elt) {
            elm = pm;
            // Unbound param: fall through to the void spelling.
            elt = y.as_data.elem;
        }
        let el = *unsafe (*self.p().module_ast_const(elm)).type_at(elt);
        let mut cp = y.qualifier == TypeQualifier::TYPE_QUAL_CONST as u8;
        if y.kind == TypeKind::TYPE_REFERENCE {
            cp = y.qualifier != TypeQualifier::TYPE_QUAL_MUT as u8;
        }
        if el.kind == TypeKind::TYPE_ARRAY && self.is_zst(elm, elt) {
            // A zero-sized array (zero length, or zero-sized elements) has no C type: a pointer to
            // one spells as a bare data pointer (never dereferenced; arithmetic on it is folded).
            if cp {
                out.push_str("const ");
            }
            out.push_str("void *");
            out.push_str(decl);
            return true;
        }
        if el.kind == TypeKind::TYPE_ARRAY && self.ptr_wraps(elm, elt) {
            if cp {
                out.push_str("const ");
            }
            if !self.wrap_name(elm, elt, out) {
                return false;
            }
            out.push_str(" *");
            out.push_str(decl);
            return true;
        }
        if el.kind == TypeKind::TYPE_ARRAY && self.arr_len(elm, &el) > 0 {
            // Pointer-to-fixed-array spirals: `(*decl)[N]`. The element takes no qualifier: C11
            // converts no pointer to an array into one to an array of differently qualified
            // elements, so `&a` could not initialize a `*const [T; N]`.
            let mut inner = String::new();
            inner.push_str("(*");
            inner.push_str(decl);
            inner.push_str(")[");
            inner.push_u64(self.arr_len(elm, &el) as u64);
            inner.push_str("]");
            return self.arr_elem_ctype(elm, el.as_data.arr.elem, inner.as_str(), out);
        }
        let mut inner = String::new();
        let mut el_ptr = el.kind == TypeKind::TYPE_POINTER || el.kind == TypeKind::TYPE_REFERENCE;
        if el.kind == TypeKind::TYPE_FUNCTION {
            // A function value spells as a function pointer unless it is a closure environment.
            let cf = unsafe (*self.p().module_ast_const(el.module)).closure_fact(el.as_data.decl);
            el_ptr = cf == null || unsafe (&*cf).ncaps == 0;
        }
        if cp && el_ptr {
            // The element is itself a pointer: `const` must qualify the POINTER (east:
            // `char *const *`), not its pointee (an illegal second-level qualifier).
            inner.push_str("const *");
        } else {
            inner.push_str("*");
        }
        inner.push_str(decl);
        if cp && !el_ptr {
            let st = out.len();
            let ok = self.ctype(elm, elt, inner.as_str(), out);
            if !out.as_str().slice(st, out.len()).starts_with("const ") {
                out.insert_str(st, "const ");
            }
            return ok;
        }
        let ok = self.ctype(elm, elt, inner.as_str(), out);
        return ok;
    }

    /// Whether a pointer to array `(pm, t)` spells as a pointer to its wrapper struct
    /// (`wrap_name`): the array has a positive length at every level and its innermost element is
    /// a struct, union, enum with payloads or generic instance the emitter defines. C needs the
    /// element complete to declare an array of it, even below a pointer, and inside the definition
    /// of a self or mutually recursive aggregate it is not; a pointer to an incomplete struct is
    /// legal C. The wrapper has the array's size, alignment and layout, so pointer arithmetic
    /// and the ABI are the array pointer's, and every access reads the array member `e`.
    pub fn ptr_wraps(self: &mut Self, pm: ModuleId, t: TypeId) bool {
        let mut rm = pm;
        let mut rt = t;
        let mut env: usize = 0;
        if !self.resolve_env(pm, t, &mut rm, &mut rt, &mut env) {
            return false;
        }
        let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        if y.kind != TypeKind::TYPE_ARRAY || self.arr_len(rm, &y) <= 0 {
            return false;
        }
        let h0 = self.hide_from(env, rm, rt);
        let r = !self.is_zst(rm, y.as_data.arr.elem) && self.agg_elem(rm, y.as_data.arr.elem);
        self.unhide(h0);
        return r;
    }

    // Spell the wrapper struct name of pointee array `(pm, t)` (`ptr_wraps`) into `out`:
    // `<element>__a<N>` with one `_<M>` per inner dimension, and record the use (the typedef
    // only) and, once per mangler, the definition request.
    fn wrap_name(self: &mut Self, pm: ModuleId, t: TypeId, out: &mut String) bool {
        // The array spelled around a marker declarator gives the element name and the dimensions:
        // `Node @[3][2]`. Neither spelling is text the output uses: no edge, no type need.
        let ne = replace(&mut self.no_edges, true);
        let mut arr = String::new();
        let ok = self.ctype(pm, t, "@", &mut arr);
        let mut body = String::new();
        let mut ok2 = ok;
        let mut at: usize = 0;
        if ok {
            let a = arr.as_str();
            while a.byte_at(at) != b'@' {
                at += 1;
            }
        }
        let st = out.len();
        if ok {
            let a = arr.as_str();
            let mut e = at;
            while e > 0 && a.byte_at(e - 1) == b' ' {
                e -= 1;
            }
            out.push_str(a.slice(0, e));
            out.push_str("__a");
            for k in at + 2..a.len() {
                let c = a.byte_at(k);
                if c == b']' {
                    continue;
                }
                out.push_byte(
                    if c == b'[' {
                        b'_';
                    } else {
                        c;
                    },
                );
            }
        }
        let h = out.as_str().slice(st, out.len()).hash();
        if ok && !self.wrap_seen.contains(&h) {
            self.wrap_seen.insert(h);
            let nm = out.as_str().slice(st, out.len());
            body.push_str("struct ");
            body.push_str(nm);
            body.push_str(" {\n  ");
            ok2 = self.ctype(pm, t, "e", &mut body);
            body.push_str(";\n};\n");
            let lo = self.layout_sub(pm, t);
            if lo.ok {
                body.push_str("_Static_assert(sizeof(");
                body.push_str(nm);
                body.push_str(") == ");
                body.push_u64(lo.size);
                body.push_str(" && _Alignof(");
                body.push_str(nm);
                body.push_str(") == ");
                body.push_u64(lo.align);
                body.push_str(", \"super-c layout model mismatch: ");
                body.push_str(nm);
                body.push_str("\");\n");
            }
            let el = arr.as_str().slice(0, at);
            self.wrap_reqs.push(WrapReq { h: h, elem: String::from_str(el.trim()), body: body });
        }
        // Journaled once per module, gate hit or not: the first claimant may vanish.
        if ok2 && self.rec_on && self.rec_dup_once(h ^ 21) {
            for k in 0..self.wrap_reqs.len() {
                if self.wrap_reqs[k].h == h {
                    let mut ev = RecEv::blank(RK_WRAP);
                    ev.h = h;
                    ev.s1 = self.wrap_reqs[k].elem.clone();
                    ev.s2 = self.wrap_reqs[k].body.clone();
                    self.rec.push(ev);
                    break;
                }
            }
        }
        self.no_edges = ne;
        if ok2 && self.tn_on && !self.no_edges {
            self.need_name(h, false);
        }
        return ok2;
    }

    /// The C type results `tys` (pool `pm`) return in when C cannot return them as they are: the
    /// result pack `__sc_ret<n>` with `__<type>` per result for several results, `__sc_reta__<type>`
    /// for one fixed array (C returns no array). One C struct per result list, so a function and
    /// every function pointer with those results share it. Members `_<i>` hold the stored results (a
    /// zero-sized one has none), `_a` the array; with none stored the spelling is `void`. The
    /// definition is requested once per mangler (`pack_reqs`) and the spelling records the need of
    /// the current context (by value at pointer depth 0). False when a result has no spelling.
    pub fn ret_pack(self: &mut Self, pm: ModuleId, tys: &Vector<TypeId>, out: &mut String) bool {
        let arr = tys.len() == 1;
        let mut stored: u32 = 0;
        for i in 0..tys.len() {
            if !self.is_zst(pm, tys[i]) {
                stored += 1;
            }
        }
        if stored == 0 {
            out.push_str("void");
            return true;
        }
        let st = out.len();
        let ne = replace(&mut self.no_edges, true);
        if arr {
            out.push_str("__sc_reta");
        } else {
            out.push_str("__sc_ret");
            out.push_u64(tys.len() as u64);
        }
        let mut ok = true;
        for i in 0..tys.len() {
            out.push_str("__");
            if !self.type_m(pm, tys[i], out) {
                ok = false;
                break;
            }
        }
        let h = out.as_str().slice(st, out.len()).hash();
        if ok && !self.pack_seen.contains(&h) {
            let nm = String::from_str(out.as_str().slice(st, out.len()));
            let mut body = String::from_str("typedef struct ");
            body.push_string(&nm);
            body.push_str(" ");
            body.push_string(&nm);
            body.push_str(";\nstruct ");
            body.push_string(&nm);
            body.push_str(" {\n");
            let pd = replace(&mut self.ptr_depth, 0);
            for i in 0..tys.len() {
                if !ok {
                    break;
                }
                if self.is_zst(pm, tys[i]) {
                    continue;
                }
                let mut mn = String::from_str("_");
                if arr {
                    mn.push_str("a");
                } else {
                    mn.push_u64(i as u64);
                }
                body.push_str("  ");
                ok = self.ctype(pm, tys[i], mn.as_str(), &mut body);
                body.push_str(";\n");
            }
            self.ptr_depth = pd;
            body.push_str("};\n");
            if ok {
                self.pack_seen.insert(h);
                self.pack_reqs.push(WrapReq { h: h, elem: nm, body: body });
            }
        }
        self.no_edges = ne;
        if !ok {
            out.truncate(st);
            return false;
        }
        self.pack_use(h);
        return true;
    }

    /// The C struct of vector `t` (`y`, pool `pm`): `__sc_v<N>_<lane>`, defined once per mangler as a
    /// pack (`pack_reqs`, `vec_def`).
    fn vec_pack(self: &mut Self, pm: ModuleId, t: TypeId, y: &Ty, out: &mut String) bool {
        let n = self.arr_len(pm, y);
        let st = out.len();
        let ne = replace(&mut self.no_edges, true);
        let ok = n > 0 && self.type_m(pm, t, out);
        self.no_edges = ne;
        if !ok {
            return false;
        }
        let nm = String::from_str(out.as_str().slice(st, out.len()));
        let lo = self.layout_sub(pm, t);
        return lo.ok && self.vec_def(pm, y.as_data.arr.elem, nm.as_str(), n as u64, lo.size, lo.align);
    }

    /// The pack of vector struct `nm`, `n` lanes of `elem` (pool `pm`) in `size` bytes aligned to
    /// `align`: `_Alignas(A) <lane> l[N]`. Under `vec_regs`, a vector of 2 to 16 bytes whose alignment
    /// is its size holds `<lane> l __attribute__((vector_size(S)))` instead, so the C ABI passes it in
    /// one vector register, not lane by lane (an aggregate of floats is a homogeneous aggregate, of
    /// integers two words); its lanes have no address: code that takes one spells `((T *)&v)[i]`. A
    /// wider one of 16-byte chunks also names them, `c[k]` in a union with `l`: a split operation
    /// reads and writes its chunks in place.
    fn vec_def(self: &mut Self, pm: ModuleId, elem: TypeId, nm: str, n: u64, size: u64, align: u64) bool {
        let h = nm.hash();
        if !self.pack_seen.contains(&h) {
            let reg = self.vec_regs && n >= 2 && size <= 16 && align == size;
            let k = size / 16;
            let wide = self.vec_regs && size > 16 && size % 16 == 0 && align == 16 && n % k == 0 && n / k >= 2;
            let mut el = String::new();
            let mut lane = String::from_str("l");
            if !reg {
                lane.format_into("[{}]", n);
            }
            if !self.ctype(pm, elem, lane.as_str(), &mut el) {
                return false;
            }
            if reg {
                el.format_into(" __attribute__((vector_size({})))", size);
            } else {
                el.insert_str(0, format("_Alignas({}) ", align).as_str());
            }
            if wide {
                // `__sc_v<N>_<lane>` -> `__sc_v<N/k>_<lane>`, its 16-byte chunk.
                let mut cn = format("__sc_v{}", n / k);
                cn.push_str(nm.slice(6 + nm.slice(6, nm.len()).find("_") as usize, nm.len()));
                if !self.vec_def(pm, elem, cn.as_str(), n / k, 16, 16) {
                    return false;
                }
                el = format("union {{\n    {};\n    {} c[{}];\n  }}", el.as_str(), cn.as_str(), k);
            }
            // The lane check (`ir::CHECK_LANES`) names its index and lane count; every TU that
            // indexes a vector needs the vector complete, so its definition carries the helper.
            let body = format(
                "typedef struct {} {};\nstruct {} {{\n  {};\n}};\n_Static_assert(sizeof({}) == {} && _Alignof({}) == {}, \"super-c layout model mismatch: {}\");\n{}",
                nm,
                nm,
                nm,
                el.as_str(),
                nm,
                size,
                nm,
                align,
                nm,
                LANE_CHECK_C,
            );
            self.pack_seen.insert(h);
            self.pack_reqs.push(WrapReq { h: h, elem: String::from_str(nm), body: body });
        }
        self.pack_use(h);
        return true;
    }

    // Journal pack `h` (`pack_reqs`) and record the current context's need of its definition.
    fn pack_use(self: &mut Self, h: u64) {
        // Journaled once per module, gate hit or not: the first claimant may vanish.
        if self.rec_on && self.rec_dup_once(h ^ 22) {
            for k in 0..self.pack_reqs.len() {
                if self.pack_reqs[k].h == h {
                    let mut ev = RecEv::blank(RK_PACK);
                    ev.h = h;
                    ev.s1 = self.pack_reqs[k].elem.clone();
                    ev.s2 = self.pack_reqs[k].body.clone();
                    self.rec.push(ev);
                    break;
                }
            }
        }
        if self.tn_on && !self.no_edges {
            self.need_name(h, self.ptr_depth == 0);
        }
    }

    /// Whether result `(pm, t)` is a fixed array of positive length: C returns it in its carrier
    /// (`ret_pack`).
    pub fn arr_result(self: &mut Self, pm: ModuleId, t: TypeId) bool {
        let mut rm = pm;
        let mut rt = t;
        if t == TYPE_NONE || !self.resolve(pm, t, &mut rm, &mut rt) {
            return false;
        }
        let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
        return y.kind == TypeKind::TYPE_ARRAY && self.arr_len(rm, &y) > 0;
    }

    /// `ret_pack` of the results of function value type `(pm, t)` (a function pointer, function
    /// item or closure type, or a `dyn fn`, behind references), spelled by value. False when the
    /// type is none of those or C returns its results as they are.
    pub fn fn_ret_pack(self: &mut Self, pm: ModuleId, t: TypeId, out: &mut String) bool {
        let mut rm = pm;
        let mut rt = t;
        for _ in 0..8 {
            if !self.resolve(rm, rt, &mut rm, &mut rt) {
                return false;
            }
            let y = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
            if y.kind == TypeKind::TYPE_REFERENCE || y.kind == TypeKind::TYPE_POINTER {
                rt = y.as_data.elem;
                continue;
            }
            if y.kind == TypeKind::TYPE_DYN {
                let it = *unsafe (*self.p().module_ast_const(rm)).instance(y.as_data.inst);
                if it.decl != NODE_NONE {
                    return false;
                }
                rt = it.args[0];
                continue;
            }
            if y.kind != TypeKind::TYPE_FUNCTION {
                return false;
            }
            let sm = if y.fn_sig() {
                rm;
            } else {
                y.module;
            };
            let fa = self.p().module_ast_const(sm);
            let cf = unsafe (*fa).closure_fact(y.as_data.decl);
            let nr = sig_len(fa, &y, cf, true);
            if nr == 0 || nr == 1 && !self.arr_result(sm, sig_ty(fa, &y, cf, true, 0)) {
                return false;
            }
            let mut tys = Vector::<TypeId>::new();
            for i in 0..nr {
                tys.push(sig_ty(fa, &y, cf, true, i));
            }
            let pd = replace(&mut self.ptr_depth, 0);
            let ok = self.ret_pack(sm, &tys, out);
            self.ptr_depth = pd;
            return ok;
        }
        return false;
    }

    /// Record result pack request `rq` unless one of its name is recorded (a shard merge, a
    /// journal replay).
    pub fn pack_take(self: &mut Self, rq: WrapReq) {
        if !self.pack_seen.contains(&rq.h) {
            self.pack_seen.insert(rq.h);
            self.pack_reqs.push(rq);
        }
    }

    /// Record wrapper request `rq` unless one of its name is recorded (a shard merge, a journal
    /// replay).
    pub fn wrap_take(self: &mut Self, rq: WrapReq) {
        if !self.wrap_seen.contains(&rq.h) {
            self.wrap_seen.insert(rq.h);
            self.wrap_reqs.push(rq);
        }
    }

    // Whether array element `(pm, t)`, through nested arrays of positive length, is a struct,
    // union, enum with payloads or generic instance the emitter defines.
    fn agg_elem(self: &mut Self, pm: ModuleId, t: TypeId) bool {
        let mut rm = pm;
        let mut rt = t;
        let mut env: usize = 0;
        if !self.resolve_env(pm, t, &mut rm, &mut rt, &mut env) {
            return false;
        }
        let a = self.p().module_ast_const(rm);
        let y = *unsafe (*a).type_at(rt);
        if y.kind == TypeKind::TYPE_INSTANCE {
            return true;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            if self.arr_len(rm, &y) <= 0 {
                return false;
            }
            let h0 = self.hide_from(env, rm, rt);
            let r = self.agg_elem(rm, y.as_data.arr.elem);
            self.unhide(h0);
            return r;
        }
        if y.kind != TypeKind::TYPE_STRUCT && y.kind != TypeKind::TYPE_ENUM {
            return false;
        }
        let da = self.p().module_ast_const(y.module);
        if unsafe (*da).at_const(y.as_data.decl).as_data.aggregate.is_extern {
            return false;
        }
        return y.kind == TypeKind::TYPE_STRUCT || unsafe (*da).enum_has_payload(y.as_data.decl);
    }

    // The remaining kinds of `(pm, t)` (`y`): dyn fat values, generic parameters, `void`.
    fn ctype_rest(self: &mut Self, pm: ModuleId, t: TypeId, y: &Ty, decl: str, out: &mut String) bool {
        if y.kind == TypeKind::TYPE_DYN {
            let st = out.len();
            let ok = self.dyn_stem(pm, y, out);
            if !ok {
                out.truncate(st);
            } else {
                self.join_decl("__dyn", decl, out);
                self.dyn_reqs.push(DynReq { pm: pm, t: t });
                if self.rec_on {
                    let mut ev = RecEv::blank(RK_MDYN);
                    ev.a = pm;
                    ev.b = t;
                    self.rec.push(ev);
                }
            }
            return ok;
        }
        if y.kind == TypeKind::TYPE_GENERIC || y.kind == TypeKind::TYPE_ASSOC {
            let mut rm: ModuleId = 0;
            let mut rt = TYPE_NONE;
            let mut env: usize = 0;
            if self.resolve_env(pm, t, &mut rm, &mut rt, &mut env) {
                let h0 = self.hide_from(env, rm, rt);
                let ok = self.ctype(rm, rt, decl, out);
                self.unhide(h0);
                return ok;
            }
            if self.macro_on && y.kind == TypeKind::TYPE_GENERIC {
                self.generic_param_name(y, out);
                self.join_decl("", decl, out);
                return true;
            }
        }
        // TYPE_NEVER, TYPE_ERROR, unbound TYPE_GENERIC and every remaining kind spell as `void`.
        self.join_decl("void", decl, out);
        return true;
    }

    /// `<Qualified>[__<arg>...]` with trailing prelude-Global (default allocator) args elided:
    /// `String<Global>` -> `String`, `Vector<T, Global>` -> `Vector__T`. A symbol segment unless
    /// inside a C type spelling (`inst_type_name`).
    pub fn inst_name(self: &mut Self, pm: ModuleId, it: &TyInstance, out: &mut String) bool {
        self.seg_depth += 1;
        let r = self.inst_name_i(pm, it, out);
        self.seg_depth -= 1;
        return r;
    }

    /// `inst_name` for a C type name the output spells: records type edges.
    pub fn inst_type_name(self: &mut Self, pm: ModuleId, it: &TyInstance, out: &mut String) bool {
        self.type_depth += 1;
        let r = self.inst_name(pm, it, out);
        self.type_depth -= 1;
        return r;
    }

    fn inst_name_i(self: &mut Self, pm: ModuleId, it: &TyInstance, out: &mut String) bool {
        let base9 = out.len();
        let nm = unsafe (*self.p().module_ast_const(it.module)).at_const(it.decl).as_data.aggregate.name;
        self.qualified(it.module, nm, out);
        let mut ne = it.n;
        while ne > 0 {
            let mut gm = pm;
            let mut gt = unsafe it.args[(ne - 1) as usize];
            if !self.resolve(pm, gt, &mut gm, &mut gt) {
                break;
            }
            let y = *unsafe (*self.p().module_ast_const(gm)).type_at(gt);
            if self.ph_global.node != NODE_NONE && y.kind == TypeKind::TYPE_STRUCT && y.module == self.ph_global.mid && y.as_data.decl == self.ph_global.node {
                ne -= 1;
            } else {
                break;
            }
        }
        if !self.args_m(pm, it, ne, out) {
            return false;
        }
        // A vector's or mask's anchor names its methods only: its storage is not the struct.
        if self.agg_on && self.p().tt.deref().vec_of(it.module, it.decl, &it.args[0]).kind == TypeKind::TYPE_ERROR {
            let h9 = out.as_str().slice(base9, out.len()).hash();
            let new9 = switch self.agg_seen.get(&h9) {
                Some(_v) => false,
                None => true,
            };
            if new9 {
                self.agg_seen.insert(h9, 1);
                let sn9 = subs_copy(&self.subs);
                self.agg_reqs.push(AggReq { pm: pm, it: *it, subs: sn9 });
                if self.sh_on {
                    self.sh_agg_k.push(h9);
                }
            }
            if self.rec_on && self.rec_dup_once(h9 ^ 14) {
                let mut ev = RecEv::blank(RK_AGG);
                ev.h = h9;
                ev.a = pm;
                ev.b = it.module;
                ev.c = it.decl;
                ev.d = it.n;
                for k9 in 0..it.n {
                    ev.xs.push(unsafe it.args[k9 as usize]);
                }
                ev.subs = subs_copy(&self.subs);
                self.rec.push(ev);
            }
        }
        return true;
    }

    /// One journaled dup attempt per (gate key, current module): true the first time only.
    pub fn rec_dup_once(self: &mut Self, k: u64) bool {
        let mixed = k.wrapping_mul(1099511628211u64) ^ self.mark_ctx as u64;
        if self.rec_dups.contains(&mixed) {
            return false;
        }
        self.rec_dups.insert(mixed);
        return true;
    }

    /// Journal replay of one recorded instance-spelling attempt: the same agg_seen gate the live
    /// spelling ran, so first-claimant order across cached and re-emitted modules stays exact.
    pub fn tuc_replay_agg(self: &mut Self, ev: &RecEv) {
        let hit = switch self.agg_seen.get(&ev.h) {
            Some(_v) => true,
            None => false,
        };
        if hit {
            return;
        }
        self.agg_seen.insert(ev.h, 1);
        let mut it = TyInstance { module: ev.b as ModuleId, decl: ev.c, n: ev.d as u8 };
        for k in 0..it.n {
            unsafe it.args[k as usize] = ev.xs[k as usize];
        }
        let sn = subs_copy(&ev.subs);
        self.agg_reqs.push(AggReq { pm: ev.a as ModuleId, it: it, subs: sn });
    }
}

// The parameter (`ret` false) or return (`ret` true) list length of function value type `y`: a closure's
// from its recorded facts `cf` (its syntax may be released), anything else's from its declaration.
const fn sig_len(fa: *const Ast, y: &Ty, cf: *const ClosureFact, ret: bool) u32 {
    if y.fn_sig() {
        return unsafe (*fa).sig_len(y, ret);
    }
    if cf != null {
        let c = unsafe &*cf;
        return if ret {
            c.nrets;
        } else {
            c.nparams;
        };
    }
    return sig_list(fa, y, ret).len;
}

// The declared parameter or return list of function or function type `y`.
const fn sig_list(fa: *const Ast, y: &Ty, ret: bool) NodeList {
    let mut ps = NodeList { start: 0, len: 0 };
    let mut rs = NodeList { start: 0, len: 0 };
    let _ = unsafe (*fa).sig_lists(y.as_data.decl, &mut ps, &mut rs);
    return if ret {
        rs;
    } else {
        ps;
    };
}

// Type `i` of that list. An unannotated parameter takes the type recorded on the parameter itself.
fn sig_ty(fa: *const Ast, y: &Ty, cf: *const ClosureFact, ret: bool, i: u32) TypeId {
    if y.fn_sig() {
        return unsafe (*fa).sig_at(y, ret, i);
    }
    if cf != null {
        let c = unsafe &*cf;
        let k = if ret {
            c.ncaps + c.nparams + i;
        } else {
            c.ncaps + i;
        };
        return unsafe (*fa).caps_of(cf)[k as usize].ty;
    }
    let id = unsafe (*fa).list(sig_list(fa, y, ret))[i as usize];
    let n = unsafe (*fa).at_const(id);
    if n.kind == NodeKind::NODE_PARAMETER && (ret || n.as_data.parameter.ty != NODE_NONE) {
        return unsafe (*fa).type_of(n.as_data.parameter.ty);
    }
    return unsafe (*fa).type_of(id);
}

/// `a` when `c` holds, else `b`.
pub const fn if_s(c: bool, a: str<'static>, b: str<'static>) str<'static> {
    if c {
        return a;
    }
    return b;
}

// A const-generic argument as a symbol segment: its decimal digits, with `n` for a minus sign (a C
// identifier has no `-`; a position is const for every instance of its generic, so no type segment
// shares it).
fn push_cval(out: &mut String, v: i64, bt: BuiltinType) {
    if v < 0 && !bt_is_unsigned(bt) {
        out.push_str("n");
        out.push_u64((v as u64).wrapping_neg());
    } else {
        out.push_u64(v as u64);
    }
}

// The vector lane check (`ir::CHECK_LANES`): the index and the lane count in the trap; the range check
// of a vector load or store (`ir::CHECK_VEC`): the lane count, the start and the length; and a lane
// operation's trap. Every vector type's definition carries it, so a program without vectors has none.
const LANE_CHECK_C: str<'static> = M"(#ifndef SC_LANE_CHECK
#define SC_LANE_CHECK
static _Noreturn __attribute__((unused, cold, noinline)) void __sc_lane_oob(size_t __i, size_t __n) {
  char __m[96];
  snprintf(__m, sizeof __m, "index out of bounds: the index is %llu but the length is %llu", (unsigned long long)__i,
           (unsigned long long)__n);
  __sc_panic(__m);
}
static __attribute__((unused)) inline size_t __sc_lane(size_t __i, size_t __n) {
  if (__i >= __n) __sc_lane_oob(__i, __n);
  return __i;
}
static _Noreturn __attribute__((unused, cold, noinline)) void __sc_vec_oob(size_t __i, size_t __n, size_t __w) {
  char __m[128];
  snprintf(__m, sizeof __m, "index out of bounds: %llu lanes from %llu but the length is %llu", (unsigned long long)__w,
           (unsigned long long)__i, (unsigned long long)__n);
  __sc_panic(__m);
}
static __attribute__((unused)) inline size_t __sc_bounds_vec(size_t __i, size_t __n, size_t __w) {
  if (__i > __n || __w > __n - __i) __sc_vec_oob(__i, __n, __w);
  return __i;
}
/* A masked or gather access's trap: bit `i` of `__f` is set when active lane `i` is out of bounds; the
   lowest names itself and its element, `__x + i` from start `__x` (`__start`), or index `__x`. */
static _Noreturn __attribute__((unused, cold, noinline)) void __sc_mem_oob(uint64_t __f, uint64_t __x, size_t __n, int __start) {
  unsigned __l = (unsigned)__builtin_ctzll(__f);
  char __m[160];
  if (__start)
    snprintf(__m, sizeof __m, "lane %u: index out of bounds: the index is %llu + %u but the length is %llu", __l,
             (unsigned long long)__x, __l, (unsigned long long)__n);
  else
    snprintf(__m, sizeof __m, "lane %u: index out of bounds: the index is %llu but the length is %llu", __l,
             (unsigned long long)__x, (unsigned long long)__n);
  __sc_panic(__m);
}
/* A vector operation's lane trap: bit `i` of `__f0` (failure `__m0`) or of `__f1` (failure `__m1`) is
   set when lane `i` fails; the lowest failing lane names itself. `__sc_lane_ovf` keeps an overflow
   failure only in a build that checks overflow (the scalar `+ - *` rule). */
static _Noreturn __attribute__((unused, cold, noinline)) void __sc_panic_lane(uint64_t __f0, uint64_t __f1, const char *__m0, const char *__m1) {
  unsigned __l = (unsigned)__builtin_ctzll(__f0 | __f1);
  char __m[128];
  snprintf(__m, sizeof __m, "lane %u: %s", __l, (__f0 >> __l & 1) ? __m0 : __m1);
  __sc_panic(__m);
}
#ifdef SC_ARITH_WRAP
#define __sc_lane_ovf(f) ((void)(f), 0)
#else
#define __sc_lane_ovf(f) (f)
#endif
/* A NaN with its quiet bit set: `min_num`/`max_num` of two NaNs. */
static __attribute__((unused)) inline float __sc_qnan_float(float __x) {
  union { float f; uint32_t u; } __v = { __x };
  __v.u |= 0x400000u;
  return __v.f;
}
static __attribute__((unused)) inline double __sc_qnan_double(double __x) {
  union { double f; uint64_t u; } __v = { __x };
  __v.u |= 0x8000000000000ull;
  return __v.f;
}
#define __sc_qnan(x) _Generic((x), float: __sc_qnan_float, double: __sc_qnan_double)(x)
/* An accumulator's lane loop unrolls by eight at most: the accumulators stay in memory. */
#if defined(__clang__)
#define __SC_LANES _Pragma("clang loop unroll_count(8)")
#elif defined(__GNUC__)
#define __SC_LANES _Pragma("GCC unroll 8")
#else
#define __SC_LANES
#endif
#endif
)";
