// The frozen C symbol-naming authority for the streaming backend: every symbol regenerates from
// the pools alone. Inputs are concrete, pool-local types under an empty substitution frame;
// resolution happens before naming, never inside it. Renders outside the frozen subset refuse
// (false) instead of guessing.
import ast::ast as *;
import ir::layout as lay;
import lexer::token as tok;
import lexer::token_type as tt;
import module::loader as loader;
import ir::interp as iri;

// The mangle spelling of a builtin ("void" doubles as the not-a-scalar fallback).
const fn bt_mangle(b: BuiltinType) str<'static> {
    if b == BuiltinType::BT_BOOL {
        return "bool";
    }
    if b == BuiltinType::BT_CHAR {
        return "char";
    }
    if b == BuiltinType::BT_I8 {
        return "i8";
    }
    if b == BuiltinType::BT_I16 {
        return "i16";
    }
    if b == BuiltinType::BT_I32 {
        return "i32";
    }
    if b == BuiltinType::BT_I64 {
        return "i64";
    }
    if b == BuiltinType::BT_ISIZE {
        return "isize";
    }
    if b == BuiltinType::BT_U8 {
        return "u8";
    }
    if b == BuiltinType::BT_U16 {
        return "u16";
    }
    if b == BuiltinType::BT_U32 {
        return "u32";
    }
    if b == BuiltinType::BT_U64 {
        return "u64";
    }
    if b == BuiltinType::BT_USIZE {
        return "usize";
    }
    if b == BuiltinType::BT_F32 {
        return "f32";
    }
    if b == BuiltinType::BT_F64 {
        return "f64";
    }
    if b == BuiltinType::BT_C32 {
        return "c32";
    }
    if b == BuiltinType::BT_C64 {
        return "c64";
    }
    if b == BuiltinType::BT_VALIST {
        return "va_list";
    }
    return "void";
}

// The C spelling of a builtin in declarations (usize is size_t, NOT uintptr_t; c32/c64 are the
// _Complex pair). "void" doubles as the fallback.
const fn bt_c_decl(b: BuiltinType) str<'static> {
    if b == BuiltinType::BT_BOOL {
        return "bool";
    }
    if b == BuiltinType::BT_CHAR {
        return "char";
    }
    if b == BuiltinType::BT_I8 {
        return "int8_t";
    }
    if b == BuiltinType::BT_I16 {
        return "int16_t";
    }
    if b == BuiltinType::BT_I32 {
        return "int32_t";
    }
    if b == BuiltinType::BT_I64 {
        return "int64_t";
    }
    if b == BuiltinType::BT_ISIZE {
        return "intptr_t";
    }
    if b == BuiltinType::BT_U8 {
        return "uint8_t";
    }
    if b == BuiltinType::BT_U16 {
        return "uint16_t";
    }
    if b == BuiltinType::BT_U32 {
        return "uint32_t";
    }
    if b == BuiltinType::BT_U64 {
        return "uint64_t";
    }
    if b == BuiltinType::BT_USIZE {
        return "size_t";
    }
    if b == BuiltinType::BT_F32 {
        return "float";
    }
    if b == BuiltinType::BT_F64 {
        return "double";
    }
    if b == BuiltinType::BT_C32 {
        return "float _Complex";
    }
    if b == BuiltinType::BT_C64 {
        return "double _Complex";
    }
    if b == BuiltinType::BT_VALIST {
        return "va_list";
    }
    return "void";
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

/// The symbol-naming state of one emission: the substitution stack, memoized renders, and the
/// cross-TU use edges the writer prunes by.
pub struct Mangler {
    pub pkg: *const loader::Package,
    /// Prefixing is on only when the package holds more than one non-prelude module (the single-
    /// module build emits one standalone TU with bare names).
    pub mangle: bool,
    ph_global: loader::LookupHit,
    // Per-module short-prefix verdict memo: 0 unknown / 1 full path / 2 short. A pure function of
    // the package's module path list, so every TU agrees.
    short_ok: Vector<u8>,
    /// Instance suffix appended to closure symbols while a generic body instance emits (closures
    /// hoist per instantiation; the bare name would collide across instances in one TU). Only the
    /// closures DECLARED IN that instance take it: `clos_ids` lists them; a concrete closure
    /// passed IN as a type argument keeps its unsuffixed name.
    pub clos_sfx: String,
    pub clos_ids: Vector<NodeId>,
    /// Substitution stack for per-instance spelling: generic-param decl -> a CONCRETE pool type
    /// (module + TypeId, usually the instance's anchor pool). Innermost binding wins.
    pub subs: Vector<MSub>,
    // The frames `hide_from` lifted off `subs` while a binding's payload is read under its own env.
    hidden: Vector<MSub>,
    /// Every TYPE_DYN whose C spelling was rendered: the backend drains this into `SC_DYN_<stem>`
    /// typedef blocks (the fat value + vtable types every dyn spelling presumes).
    pub dyn_reqs: Vector<DynReq>,
    /// `@emit_macro` template mode: an UNRESOLVED generic param spells as its own name in C types
    /// and as `<paste>_SCM_<name>` in mangles (byte 1 marks a `##` for the template rewriter).
    pub macro_on: bool,
    /// Cross-TU spelling edges as two bit matrices (modpfx marks one per spelling, far too hot
    /// for a hashed set): one row per context (modules, the package-level row, then one per
    /// owner module's instance shard), one bit per owner module. `used_types` when the context
    /// spelled a type name of the owner (it needs the owner's complete types), `used_syms` for
    /// any other symbol (it needs the owner's prototypes); `um_hit` is their union. Sized
    /// lazily on the first edge.
    pub used_types: Vector<u64>,
    pub used_syms: Vector<u64>,
    /// Nesting of the C type spellers: a module prefix spelled inside one names a type.
    pub type_depth: u32,
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
    last_edge: u64, // the spelling edge recorded last: spellings cluster, so most repeat it
    /// Spelling capture for memoized renders: while on, modpfx logs every module it spells so a
    /// cache hit can replay the spelling edges exactly (under the hit's own mark_ctx).
    pub edge_log_on: bool,
    pub edge_log: Vector<ModuleId>,
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
pub const RK_DYNTAB: u8 = 11; // a = pm, b = dyn t, c = srm, d = srt, h = own flag (dyn_pair call)
pub const RK_TI: u8 = 12; // a = rm, b = rt (type_info descriptor request)
pub const RK_BLK: u8 = 13; // a/b = blocking callee DefId (blk_wrapper call)
pub const RK_AGG: u8 = 14; // h = gate, a = pm, b/c/d+xs = TyInstance, subs = spelling env
pub const RK_MDYN: u8 = 15; // a = pm, b = t (mangler dyn_reqs entry)
pub const RK_EDGE: u8 = 16; // xs = spelling row of this module, bit 15 = type edge (driver-recorded)
pub const RK_MAIN: u8 = 17; // a = main_argv (driver-recorded, module holds `main`)
pub const RK_ZST: u8 = 18; // a = alignment (ZST sentinel demand)
pub const RK_HEDGE: u8 = 19; // a = owner module, d = embedded type (a's pool), c = env kind (header edge)
/// `mark_ctx` of owner module `o`'s instance shard: `CTX_INST | o`.
pub const CTX_INST: i64 = 0x10000;

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
            short_ok: Vector::<u8>::new(),
            subs: Vector::<MSub>::new(),
            clos_sfx: String::new(),
            clos_ids: Vector::<NodeId>::new(),
            dyn_reqs: Vector::<DynReq>::new(),
            hidden: Vector::<MSub>::new(),
            macro_on: false,
            used_types: Vector::<u64>::new(),
            used_syms: Vector::<u64>::new(),
            type_depth: 0,
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
            last_edge: 0xFFFFFFFFFFFFFFFFu64,
            edge_log_on: false,
            edge_log: Vector::<ModuleId>::new(),
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
            for _i in 0..self.p().modules.len() {
                self.own_built.push(false);
            }
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

    const fn p(self: &Self) &loader::Package {
        return unsafe &*self.pkg;
    }

    /// Bind a generic param for per-instance spelling; pop with `pop_subs` (LIFO frames).
    pub fn push_sub(self: &mut Self, pm: ModuleId, pnode: NodeId, am: ModuleId, at: TypeId) {
        let lim = self.subs.len() as u32;
        self.subs.push(MSub { pm: pm, pnode: pnode, am: am, at: at, lim: lim });
    }
    /// Re-push a recorded binding, keeping its env boundary (demand chains rebuild from index 0).
    pub fn push_msub(self: &mut Self, sb: MSub) {
        self.subs.push(sb);
    }
    /// Pop the `n` most recent bindings. Panics: fewer than `n` bindings are active.
    pub fn pop_subs(self: &mut Self, n: usize) {
        self.subs.truncate(self.subs.len() - n);
    }

    /// Fold a canonical const-generic expression under the substitution stack: every referenced
    /// parameter must bind to a TYPE_CONST. False when a parameter is unbound or non-const.
    pub fn fold_cexpr(self: &Self, pm: ModuleId, t: TypeId, out_val: &mut i64) bool {
        return self.fold_cexpr_d(pm, t, out_val, 0, self.subs.len());
    }
    /// Ground any const-valued payload (TYPE_CONST, expression, or bound param) below `lim`.
    pub fn fold_cval_at(self: &Self, am: ModuleId, at: TypeId, out_val: &mut i64, lim: usize) bool {
        let l = if lim < self.subs.len() {
            lim;
        } else {
            self.subs.len();
        };
        let y = *unsafe (*self.p().module_ast_const(am)).type_at(at);
        if y.kind == TypeKind::TYPE_CONST {
            *out_val = y.as_data.value;
            return true;
        }
        if y.kind == TypeKind::TYPE_CONST_EXPR {
            return self.fold_cexpr_d(am, at, out_val, 0, l);
        }
        if y.kind == TypeKind::TYPE_GENERIC {
            return self.fold_generic_d(&y, out_val, 0, l);
        }
        return false;
    }

    // Ground a const-bound GENERIC param to its value: frames innermost-first, each matched
    // frame's payload folding strictly below that frame's env boundary.
    fn fold_generic_d(self: &Self, y: &Ty, out_val: &mut i64, depth: u32, lim: usize) bool {
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
            let kl = if sb.lim as usize < k {
                sb.lim as usize;
            } else {
                k;
            };
            let by = *unsafe (*self.p().module_ast_const(sb.am)).type_at(sb.at);
            if by.kind == TypeKind::TYPE_CONST {
                *out_val = by.as_data.value;
                return true;
            }
            if by.kind == TypeKind::TYPE_CONST_EXPR {
                if self.fold_cexpr_d(sb.am, sb.at, out_val, depth + 1, kl) {
                    return true;
                }
            } else if by.kind == TypeKind::TYPE_GENERIC {
                if self.fold_generic_d(&by, out_val, depth + 1, kl) {
                    return true;
                }
            }
        }
        return false;
    }

    fn fold_cexpr_d(self: &Self, pm: ModuleId, t: TypeId, out_val: &mut i64, depth: u32, lim: usize) bool {
        if depth > 8 {
            return false;
        }
        let a = self.p().module_ast_const(pm);
        let y = *unsafe (*a).type_at(t);
        let l = *unsafe (*a).const_lin_at(y.as_data.inst);
        let mut v = l.k;
        for i in 0..l.n {
            let c = unsafe l.c[i as usize];
            if c == 0 {
                continue;
            }
            let pd = unsafe l.p[i as usize];
            // Bindings try innermost-first with backtracking, but a frame's payload resolves only
            // through frames BELOW it (its env when pushed); a width bound to a derived
            // expression of itself must apply exactly once, grounding in the outer value.
            let mut bv: i64 = 0;
            let mut got = false;
            let mut k = lim;
            while k > 0 && !got {
                k -= 1;
                let sb = *self.subs.at(k);
                if sb.pm != pd.module || sb.pnode != pd.node {
                    continue;
                }
                let kl = if sb.lim as usize < k {
                    sb.lim as usize;
                } else {
                    k;
                };
                let mut rm = sb.am;
                let mut rt = sb.at;
                let mut env: usize = 0;
                if !self.resolve_from(sb.am, sb.at, &mut rm, &mut rt, 0, kl, &mut env) {
                    continue;
                }
                let by = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
                if by.kind == TypeKind::TYPE_CONST {
                    bv = by.as_data.value;
                    got = true;
                } else if by.kind == TypeKind::TYPE_CONST_EXPR {
                    if self.fold_cexpr_d(rm, rt, &mut bv, depth + 1, kl) {
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
                    if cv.kind == iri::IV_INT {
                        v += cv.i * c;
                        continue;
                    }
                }
                return false;
            }
            v += bv * c;
        }
        if l.div_of() != 1 {
            let folded = ConstLin { k: v, n: 0, div: l.div };
            v = folded.value();
        }
        *out_val = v;
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
        }
        return h0;
    }

    /// Restore the frames `hide_from` lifted at mark `h0`.
    pub fn unhide(self: &mut Self, h0: usize) {
        for i in h0..self.hidden.len() {
            self.subs.push(*self.hidden.at(i));
        }
        self.hidden.truncate(h0);
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
            // A zero-length array of a sized element keeps its C member (see Layout.zarr).
            if lo.ok && lo.size == 0 && !lo.zarr {
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
        return self.lay.layout_of(rm, rt, head, 0);
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

    // Evaluate a symbolic `[T; expr]` length under the instance env: literals, + - * / % << >>
    // arithmetic, and params folded through the substitution stack (`(BITS + 63) / 64` = 2 at
    // BITS=128). The checker interns these fields at len 0, so the value only exists HERE.
    fn eval_len_expr(self: &mut Self, m: ModuleId, id: NodeId, out: &mut i64, depth: u32) bool {
        if depth > 8 {
            return false;
        }
        let da = self.p().module_ast_const(m);
        let n = unsafe (*da).at_const(id);
        if n.kind == NodeKind::NODE_LITERAL {
            let sp = n.span;
            let src = self.p().modules.at(m as usize).source.as_str();
            if sp.end as usize > src.len() || sp.end <= sp.start {
                return false;
            }
            let mut v: i64 = 0;
            let mut i = sp.start as usize;
            // Radix prefixes as the lexer accepts them: 0x, 0o, 0b (either case).
            let mut base: i64 = 10;
            if sp.end as usize - i > 2 && src.byte_at(i) == 48 {
                let p = src.byte_at(i + 1) | 32;
                if p == 120 {
                    base = 16;
                } else if p == 111 {
                    base = 8;
                } else if p == 98 {
                    base = 2;
                }
                if base != 10 {
                    i += 2;
                }
            }
            let mut any = false;
            while i < sp.end as usize {
                let ch = src.byte_at(i);
                if ch == 95 {
                    i += 1;
                    continue;
                }
                let mut d: i64 = 0 - 1;
                if ch >= 48 && ch <= 57 {
                    d = ch as i64 - 48;
                } else if base == 16 && (ch | 32) >= 97 && (ch | 32) <= 102 {
                    d = (ch | 32) as i64 - 87;
                }
                if d < 0 || d >= base {
                    // A width suffix ends the digits.
                    break;
                }
                v = v * base + d;
                any = true;
                i += 1;
            }
            if !any {
                return false;
            }
            *out = v;
            return true;
        }
        if n.kind == NodeKind::NODE_BINARY {
            let mut lv: i64 = 0;
            let mut rv: i64 = 0;
            if !self.eval_len_expr(m, n.as_data.binary.left, &mut lv, depth + 1) || !self.eval_len_expr(
                m,
                n.as_data.binary.right,
                &mut rv,
                depth + 1,
            ) {
                return false;
            }
            let opn = n.as_data.binary.op;
            if opn == tt::TokenType::Plus {
                *out = lv + rv;
            } else if opn == tt::TokenType::Minus {
                *out = lv - rv;
            } else if opn == tt::TokenType::Star {
                *out = lv * rv;
            } else if opn == tt::TokenType::Slash && rv != 0 {
                *out = lv / rv;
            } else if opn == tt::TokenType::Percent && rv != 0 {
                *out = lv % rv;
            } else if opn == tt::TokenType::LeftShift {
                *out = lv << rv;
            } else if opn == tt::TokenType::RightShift {
                *out = lv >> rv;
            } else {
                return false;
            }
            return true;
        }
        // An identifier naming a generic param folds through the env.
        let ld = unsafe (*da).resolution_def(id);
        if ld.node == NODE_NONE || unsafe (*self.p().module_ast_const(ld.module)).at_const(ld.node).kind != NodeKind::NODE_GENERIC_PARAM {
            return false;
        }
        let mut k9 = self.subs.len();
        while k9 > 0 {
            k9 -= 1;
            let sb = *self.subs.at(k9);
            if sb.pm != ld.module || sb.pnode != ld.node {
                continue;
            }
            let kl9 = if sb.lim as usize < k9 {
                sb.lim as usize;
            } else {
                k9;
            };
            if self.fold_cval_at(sb.am, sb.at, out, kl9) {
                return true;
            }
        }
        return false;
    }

    /// The element count of array member `fid` (a field, or a tuple member's type node) under the
    /// active substitution env; false when the length does not fold.
    pub fn field_arr_len(self: &mut Self, m: ModuleId, fid: NodeId, len_out: &mut u64) bool {
        let da = self.p().module_ast_const(m);
        let tn = if unsafe (*da).at_const(fid).kind == NodeKind::NODE_FIELD {
            unsafe (*da).at_const(fid).as_data.field.ty;
        } else {
            // Tuple member: the node is already the type annotation.
            fid;
        };
        if tn == NODE_NONE || unsafe (*da).at_const(tn).kind != NodeKind::NODE_ARRAY_TYPE {
            return false;
        }
        let ln = unsafe (*da).at_const(tn).as_data.array_type.length;
        if ln == NODE_NONE {
            return false;
        }
        // The length expression types as its const type (usize); its RESOLUTION names the
        // param decl, which the instance env binds (innermost first, with backtracking).
        if unsafe (*da).resolution_def(ln).node != NODE_NONE {
            let mut pv: i64 = 0;
            if self.eval_len_expr(m, ln, &mut pv, 0) {
                if pv < 0 {
                    return false;
                }
                *len_out = pv as u64;
                return true;
            }
        }
        let lty = unsafe (*da).type_of(ln);
        if lty == TYPE_NONE || unsafe (*da).type_at(lty).kind == TypeKind::TYPE_BUILTIN {
            // An arithmetic length expression carries no const record: evaluate it under the env.
            let mut ev: i64 = 0;
            if self.eval_len_expr(m, ln, &mut ev, 0) && ev >= 0 {
                *len_out = ev as u64;
                return true;
            }
            return false;
        }
        if unsafe (*da).type_at(lty).kind == TypeKind::TYPE_GENERIC {
            let mut rm = m;
            let mut rt = lty;
            if self.resolve(m, lty, &mut rm, &mut rt) {
                let ry = *unsafe (*self.p().module_ast_const(rm)).type_at(rt);
                if ry.kind == TypeKind::TYPE_CONST && ry.as_data.value >= 0 {
                    *len_out = ry.as_data.value as u64;
                    return true;
                }
            }
            return false;
        }
        if unsafe (*da).type_at(lty).kind == TypeKind::TYPE_CONST {
            let cv = unsafe (*da).type_at(lty).as_data.value;
            if cv >= 0 {
                *len_out = cv as u64;
                return true;
            }
            return false;
        }
        if unsafe (*da).type_at(lty).kind != TypeKind::TYPE_CONST_EXPR {
            return false;
        }
        let mut v: i64 = 0;
        if self.fold_cexpr(m, lty, &mut v) && v >= 0 {
            *len_out = v as u64;
            return true;
        }
        return false;
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
                let il = if sb.lim as usize < i {
                    sb.lim as usize;
                } else {
                    i;
                };
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
        if self.short_ok.len() == 0 {
            for _i in 0..self.p().modules.len() {
                self.short_ok.push(0u8);
            }
        }
        let cached = self.short_ok[m as usize];
        if cached != 0 {
            return cached == 2;
        }
        let path = self.p().modules.at(m as usize).path.as_str();
        let bs = path_base_start(path);
        let mut ok = bs != 0;
        if ok {
            let base = path.slice(bs, path.len());
            for o in 0..self.p().modules.len() {
                if o == m as usize || self.p().modules.at(o).prelude {
                    continue;
                }
                let op = self.p().modules.at(o).path.as_str();
                if op.slice(path_base_start(op), op.len()) == base {
                    ok = false;
                    break;
                }
            }
        }
        self.short_ok.set(m as usize, if_u8(ok, 2, 1));
        return ok;
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
    const fn um_row(self: &Self, src: u64) usize {
        let n = self.p().modules.len();
        if src == 65534u64 {
            return n;
        }
        if src >= CTX_INST as u64 {
            return n + 1 + (src - CTX_INST as u64) as usize;
        }
        return src as usize;
    }

    // Words per matrix row.
    const fn um_w(self: &Self) usize {
        return (self.p().modules.len() + 63) / 64;
    }

    fn um_set(self: &mut Self, src: u64, dst: ModuleId, ty: bool) {
        let n = self.p().modules.len();
        if n == 0 {
            return;
        }
        let w = self.um_w();
        if self.used_types.len() == 0 {
            self.used_types.resize_default((2 * n + 1) * w);
            self.used_syms.resize_default((2 * n + 1) * w);
        }
        let i = self.um_row(src) * w + dst as usize / 64;
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
        if o.used_types.len() == 0 {
            return;
        }
        let n = self.p().modules.len();
        let w = self.um_w();
        if self.used_types.len() == 0 {
            self.used_types.resize_default((2 * n + 1) * w);
            self.used_syms.resize_default((2 * n + 1) * w);
        }
        let r = self.um_row(m) * w;
        for i in r..r + w {
            self.used_types.set(i, self.used_types[i] | o.used_types[i]);
            self.used_syms.set(i, self.used_syms[i] | o.used_syms[i]);
        }
    }

    /// Frontier merge: absorb every package-level and instance-shard row of shard `o`.
    pub fn sh_merge_inst(self: &mut Self, o: &Mangler) {
        if o.used_types.len() == 0 {
            return;
        }
        let n = self.p().modules.len();
        let w = self.um_w();
        if self.used_types.len() == 0 {
            self.used_types.resize_default((2 * n + 1) * w);
            self.used_syms.resize_default((2 * n + 1) * w);
        }
        for i in n * w..(2 * n + 1) * w {
            self.used_types.set(i, self.used_types[i] | o.used_types[i]);
            self.used_syms.set(i, self.used_syms[i] | o.used_syms[i]);
        }
    }

    /// True when context `src` spelled a type name (`ty`) or another symbol owned by module `dst`.
    pub const fn um_hit_kind(self: &Self, src: u64, dst: usize, ty: bool) bool {
        if self.used_types.len() == 0 {
            return false;
        }
        let i = self.um_row(src) * self.um_w() + dst / 64;
        let bit = 1u64 << (dst as u64 & 63);
        if ty {
            return (self.used_types[i] & bit) != 0;
        }
        return (self.used_syms[i] & bit) != 0;
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

    /// True when TU `src` (65534 = the shared instance TU) spells a symbol owned by module `dst`.
    pub const fn um_hit(self: &Self, src: u64, dst: usize) bool {
        return self.um_hit_kind(src, dst, true) || self.um_hit_kind(src, dst, false);
    }

    /// Append module `m`'s symbol prefix (empty for a single-module build) and record the cross-TU
    /// use edge when a mark context is active.
    pub fn modpfx(self: &mut Self, m: ModuleId, out: &mut String) {
        let ty = self.type_depth != 0;
        let enc = if ty {
            m | 0x8000;
        } else {
            m;
        };
        if self.edge_log_on {
            self.edge_log.push(enc);
        }
        if m as i64 != self.mark_ctx {
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

    /// The symbol-alphabet spelling of pool type `(pm, t)`. False when `t` is outside the frozen
    /// subset (symbolic, or a form not yet frozen); `out` may then hold a partial spelling the
    /// caller must discard.
    pub fn type_m(self: &mut Self, pm: ModuleId, t: TypeId, out: &mut String) bool {
        self.type_depth += 1;
        let r = self.type_m_i(pm, t, out);
        self.type_depth -= 1;
        return r;
    }

    fn type_m_i(self: &mut Self, pm: ModuleId, t: TypeId, out: &mut String) bool {
        let a = self.p().module_ast_const(pm);
        let y = *unsafe (*a).type_at(t);
        if y.kind == TypeKind::TYPE_BUILTIN {
            out.push_str(bt_mangle(y.as_data.builtin));
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
            out.push_str(if_str(is_const, "ptr_", "ptrm_"));
            return self.type_m(pm, y.as_data.elem, out);
        }
        if y.kind == TypeKind::TYPE_SLICE {
            out.push_str("slice_");
            return self.type_m(pm, y.as_data.elem, out);
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            if y.as_data.arr.len != 0 {
                out.push_str("arr");
                out.push_u64(y.as_data.arr.len);
                out.push_str("_");
            } else {
                out.push_str("arr_");
            }
            return self.type_m(pm, y.as_data.arr.elem, out);
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*a).instance(y.as_data.inst);
            return self.inst_name(pm, &it, out);
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
            out.push_i64(y.as_data.value);
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
        if y.kind == TypeKind::TYPE_GENERIC {
            // Const-bound params fold HERE: each frame's payload grounds strictly below its own
            // env boundary (resolve-then-fold would re-apply the frame on its own payload).
            let mut cv: i64 = 0;
            if self.fold_generic_d(&y, &mut cv, 0, self.subs.len()) {
                out.push_i64(cv);
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
            if self.macro_on {
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
            if !self.fold_cexpr(pm, t, &mut v) {
                return false;
            }
            out.push_i64(v);
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
        let a = self.p().module_ast_const(pm);
        let it = *unsafe (*a).instance(dy.as_data.inst);
        let da = self.p().module_ast_const(it.module);
        let fn2 = unsafe (*da).at_const(it.decl);
        if fn2.kind != NodeKind::NODE_FUNCTION_TYPE {
            self.qualified(it.module, fn2.as_data.interface_def.name, out);
        } else {
            let ftp = fn2.as_data.function_type;
            out.push_str("dynfn");
            for i in 0..ftp.params.len {
                let pid = unsafe (*da).list(ftp.params)[i as usize];
                out.push_str("__");
                if !self.type_m(it.module, unsafe (*da).type_of(pid), out) {
                    return false;
                }
            }
            if ftp.returns.len == 1 {
                let r0 = unsafe (*da).list(ftp.returns)[0];
                let rn = unsafe (*da).at_const(r0);
                let mut tn = r0;
                if rn.kind == NodeKind::NODE_PARAMETER {
                    tn = rn.as_data.parameter.ty;
                }
                out.push_str("__r_");
                if !self.type_m(it.module, unsafe (*da).type_of(tn), out) {
                    return false;
                }
            }
        }
        for i in 0..it.n {
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
    fn fn_ptr_ctype(self: &mut Self, y: &Ty, decl: str, out: &mut String) bool {
        let fa = self.p().module_ast_const(y.module);
        let cf = unsafe (*fa).closure_fact(y.as_data.decl);
        let nr = sig_len(fa, y, cf, true);
        if nr > 1 {
            // Multi-return function pointers are unsupported everywhere.
            return false;
        }
        let mut rty = TYPE_NONE;
        if nr == 1 {
            rty = sig_ty(fa, y, cf, true, 0);
        }
        if rty == TYPE_NONE || self.is_zst(y.module, rty) {
            let st = out.len();
            out.push_str("void ");
            if !self.fn_ptr_decl(fa, y, cf, decl, out) {
                out.truncate(st);
                return false;
            }
            return true;
        }
        let mut inner = switch self.fp_bufs.pop() {
            Some(b) => b,
            None => String::new(),
        };
        let ok = self.fn_ptr_decl(fa, y, cf, decl, &mut inner) && self.ctype(y.module, rty, inner.as_str(), out);
        inner.truncate(0);
        self.fp_bufs.push(inner);
        return ok;
    }

    // `(*<decl>)(<params>)` of function value type `y` into `dst`. Zero-sized by-value params take no
    // slot (must match every lowered sig).
    fn fn_ptr_decl(self: &mut Self, fa: *const Ast, y: &Ty, cf: *const ClosureFact, decl: str, dst: &mut String) bool {
        dst.push_str("(*");
        dst.push_str(decl);
        dst.push_str(")(");
        let st = dst.len();
        for i in 0..sig_len(fa, y, cf, false) {
            let pty = sig_ty(fa, y, cf, false, i);
            if self.is_zst(y.module, pty) {
                continue;
            }
            if dst.len() != st {
                dst.push_str(", ");
            }
            if !self.ctype(y.module, pty, "", dst) {
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
            for _i in 0..self.p().modules.len() {
                self.pin_built.push(false);
            }
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
        let mut key = 1469598103934665603u64;
        key = (key ^ cur as u64) * 1099511628211u64;
        key = (key ^ tmod as u64) * 1099511628211u64;
        key = (key ^ tdecl as u64) * 1099511628211u64;
        for i in 0..ntxt.len() {
            key = (key ^ ntxt.byte_at(i) as u64) * 1099511628211u64;
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
    pub fn fn_sym(self: &mut Self, fm: ModuleId, fnode: NodeId, target: DefId, prefixed: bool, out: &mut String) bool {
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
        if prefixed && !is_main {
            self.modpfx(fm, out);
        }
        let bare = prefixed && !is_main && target.node == NODE_NONE && out.len() == st;
        if target.node != NODE_NONE {
            let bb = self.p().builtin_of_decl(target.module, target.node);
            if bb >= 0 {
                out.push_str(bt_mangle(bb as BuiltinType));
            } else {
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

    /// The generics list of the extend owning `fnode` (empty when free-standing).
    pub fn extend_generics(self: &mut Self, m: ModuleId, fnode: NodeId) NodeList {
        let ext = (self.owner_of(m, fnode) >> 32) as NodeId;
        if ext == NODE_NONE {
            return NodeList { start: 0, len: 0 };
        }
        return unsafe (*self.p().module_ast_const(m)).at_const(ext).as_data.extend_def.generics;
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

    /// The C symbol of const/static item `cnode` (module `m`) read from a TU of module `em`:
    /// top-level items spell their qualified name; associated consts are per-TU statics prefixed
    /// with the EMITTING module (the established reader/emitter agreement).
    pub fn const_sym(self: &mut Self, em: ModuleId, m: ModuleId, cnode: NodeId, out: &mut String) bool {
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
            return true;
        }
        self.modpfx(em, out);
        let bb = self.p().builtin_of_decl(tgt.module, tgt.node);
        if bb >= 0 {
            out.push_str(bt_mangle(bb as BuiltinType));
        } else {
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
        self.last_method_def = DefId { module: 0, node: NODE_NONE };
        let a = self.p().module_ast_const(rm);
        let y = *unsafe (*a).type_at(rt);
        let mut dm = y.module;
        let mut dd = NODE_NONE;
        if y.kind == TypeKind::TYPE_STRUCT || y.kind == TypeKind::TYPE_ENUM {
            dd = y.as_data.decl;
        } else if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*a).instance(y.as_data.inst);
            dm = it.module;
            dd = it.decl;
        }
        if dd == NODE_NONE && y.kind != TypeKind::TYPE_BUILTIN {
            return false;
        }
        let mut miss_key = if dd == NODE_NONE {
            1u64 << 63 | y.as_data.builtin as u64;
        } else {
            dm as u64 << 32 | dd as u64;
        };
        for i in 0..mname.len() {
            miss_key = (miss_key ^ mname.byte_at(i) as u64) * 1099511628211u64;
        }
        miss_key = skey_mix(0, miss_key);
        if self.miss_memo.contains(&miss_key) {
            return false;
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
                            self.last_method_def = DefId { module: pm2 as ModuleId, node: mid2 };
                            return self.fn_sym(pm2 as ModuleId, mid2, tg2, true, out);
                        }
                    }
                }
            }
            self.miss_memo.insert(miss_key);
            return false;
        }
        // Extends may live in ANY module (a downstream module extending a foreign type): the
        // decl's own module first (the overwhelmingly common case), then the rest.
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
                    if dsrc.slice(s2.start as usize, s2.end as usize) == mname {
                        self.last_method_def = DefId { module: em2, node: mid };
                        if y.kind == TypeKind::TYPE_INSTANCE {
                            let it2 = *unsafe (*a).instance(y.as_data.inst);
                            if !self.inst_name(rm, &it2, out) {
                                return false;
                            }
                            out.push_str("__");
                            out.push_str(mname);
                            // The instance body's prototype lives in the method's module.
                            self.mark_used(em2);
                            return true;
                        }
                        return self.fn_sym(em2, mid, DefId { module: dm, node: dd }, true, out);
                    }
                }
            }
        }
        self.miss_memo.insert(miss_key);
        return false;
    }

    /// The destructor call target for resolved aggregate type `(rm, rt)`: the user `free` method
    /// when one extends the declaration, else the derived per-TU glue `<name>__free__d`.
    pub fn free_target(self: &mut Self, rm: ModuleId, rt: TypeId, out: &mut String) bool {
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
        // Plan-time scan: a `free` method in any extend of the declaration (its own module).
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
                    if y.kind == TypeKind::TYPE_INSTANCE {
                        let it2 = *unsafe (*a).instance(y.as_data.inst);
                        if !self.inst_name(rm, &it2, out) {
                            return false;
                        }
                        out.push_str("__free");
                        self.mark_used(dm);
                        return true;
                    }
                    return self.fn_sym(dm, mid, DefId { module: dm, node: dd }, true, out);
                }
            }
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
                self.qualified(y.module, dn.as_data.aggregate.name, out);
            }
            self.join_decl("", decl, out);
            return true;
        }
        if y.kind == TypeKind::TYPE_POINTER || y.kind == TypeKind::TYPE_REFERENCE {
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
            if el.kind == TypeKind::TYPE_ARRAY && self.is_zst(elm, el.as_data.arr.elem) {
                // C forbids an array declarator over an incomplete element: a pointer to a
                // zero-sized-element array spells as a bare data pointer (never dereferenced).
                if cp {
                    out.push_str("const ");
                }
                out.push_str("void *");
                out.push_str(decl);
                return true;
            }
            if el.kind == TypeKind::TYPE_ARRAY && el.as_data.arr.len != 0 {
                // Pointer-to-fixed-array spirals: `(*decl)[N]`, const prefixing the element type.
                let mut inner = String::new();
                inner.push_str("(*");
                inner.push_str(decl);
                inner.push_str(")[");
                inner.push_u64(el.as_data.arr.len);
                inner.push_str("]");
                let st = out.len();
                let ok = self.ctype(elm, el.as_data.arr.elem, inner.as_str(), out);
                if cp && !out.as_str().slice(st, out.len()).starts_with("const ") {
                    out.insert_str(st, "const ");
                }
                return ok;
            }
            let mut inner = String::new();
            if cp && el.kind == TypeKind::TYPE_POINTER {
                // The element is itself a pointer: `const` must qualify the POINTER (east:
                // `char *const *`), not its pointee (an illegal second-level qualifier).
                inner.push_str("const *");
            } else {
                inner.push_str("*");
            }
            inner.push_str(decl);
            if cp && el.kind != TypeKind::TYPE_POINTER {
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
        if y.kind == TypeKind::TYPE_SLICE {
            self.join_decl("SCslice", decl, out);
            return true;
        }
        if y.kind == TypeKind::TYPE_ARRAY {
            let mut inner = String::new();
            if y.as_data.arr.len != 0 {
                inner.push_str(decl);
                inner.push_str("[");
                inner.push_u64(y.as_data.arr.len);
                inner.push_str("]");
            } else {
                inner.push_str("*");
                inner.push_str(decl);
            }
            let ok = self.ctype(pm, y.as_data.elem, inner.as_str(), out);
            return ok;
        }
        if y.kind == TypeKind::TYPE_INSTANCE {
            let it = *unsafe (*a).instance(y.as_data.inst);
            let st = out.len();
            if !self.inst_name(pm, &it, out) {
                out.truncate(st);
                return false;
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
                self.closure_sym(y.module, y.as_data.decl, out);
                self.join_decl("_env", decl, out);
                return true;
            }
            return self.fn_ptr_ctype(&y, decl, out);
        }
        if y.kind == TypeKind::TYPE_DYN {
            let st = out.len();
            let ok = self.dyn_stem(pm, &y, out);
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
        if y.kind == TypeKind::TYPE_GENERIC {
            let mut rm: ModuleId = 0;
            let mut rt = TYPE_NONE;
            let mut env: usize = 0;
            if self.resolve_env(pm, t, &mut rm, &mut rt, &mut env) {
                let h0 = self.hide_from(env, rm, rt);
                let ok = self.ctype(rm, rt, decl, out);
                self.unhide(h0);
                return ok;
            }
            if self.macro_on {
                self.generic_param_name(&y, out);
                self.join_decl("", decl, out);
                return true;
            }
        }
        // TYPE_NEVER, TYPE_ERROR, unbound TYPE_GENERIC and every remaining kind spell as `void`.
        self.join_decl("void", decl, out);
        return true;
    }

    /// `<Qualified>[__<arg>...]` with trailing prelude-Global (default allocator) args elided:
    /// `String<Global>` -> `String`, `Vector<T, Global>` -> `Vector__T`.
    pub fn inst_name(self: &mut Self, pm: ModuleId, it: &TyInstance, out: &mut String) bool {
        self.type_depth += 1;
        let r = self.inst_name_i(pm, it, out);
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
        for i in 0..ne {
            out.push_str("__");
            if !self.type_m(pm, unsafe it.args[i as usize], out) {
                return false;
            }
        }
        if self.agg_on {
            let s9 = out.as_str();
            let mut h9 = 1469598103934665603u64;
            for k9 in base9..s9.len() {
                h9 = (h9 ^ s9.byte_at(k9) as u64) * 1099511628211u64;
            }
            let new9 = switch self.agg_seen.get(&h9) {
                Some(_v) => false,
                None => true,
            };
            if new9 {
                self.agg_seen.insert(h9, 1);
                let mut sn9 = Vector::<MSub>::new();
                for k9 in 0..self.subs.len() {
                    sn9.push(*self.subs.at(k9));
                }
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
                for k9 in 0..self.subs.len() {
                    ev.subs.push(*self.subs.at(k9));
                }
                self.rec.push(ev);
            }
        }
        return true;
    }

    /// One journaled dup attempt per (gate key, current module): true the first time only.
    pub fn rec_dup_once(self: &mut Self, k: u64) bool {
        let mixed = k * 1099511628211u64 ^ self.mark_ctx as u64;
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
        let mut sn = Vector::<MSub>::new();
        for k in 0..ev.subs.len() {
            sn.push(*ev.subs.at(k));
        }
        self.agg_reqs.push(AggReq { pm: ev.a as ModuleId, it: it, subs: sn });
    }
}

// The parameter (`ret` false) or return (`ret` true) list length of function value type `y`: a closure's
// from its recorded facts `cf` (its syntax may be released), anything else's from its declaration.
fn sig_len(fa: *const Ast, y: &Ty, cf: *const ClosureFact, ret: bool) u32 {
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
fn sig_list(fa: *const Ast, y: &Ty, ret: bool) NodeList {
    let fnn = unsafe (*fa).at_const(y.as_data.decl);
    if fnn.kind == NodeKind::NODE_FUNCTION {
        return if ret {
            fnn.as_data.function.returns;
        } else {
            fnn.as_data.function.params;
        };
    }
    return if ret {
        fnn.as_data.function_type.returns;
    } else {
        fnn.as_data.function_type.params;
    };
}

// Type `i` of that list. An unannotated parameter takes the type recorded on the parameter itself.
fn sig_ty(fa: *const Ast, y: &Ty, cf: *const ClosureFact, ret: bool, i: u32) TypeId {
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

const fn if_str(c: bool, a: str<'static>, b: str<'static>) str<'static> {
    if c {
        return a;
    }
    return b;
}
const fn if_u8(c: bool, a: u8, b: u8) u8 {
    if c {
        return a;
    }
    return b;
}
