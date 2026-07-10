#include "../__std/option.h"
#include "../__std/core.h"
#include "../__std/interfaces.h"
#include "../__std/range.h"
#include "../__std/slice.h"
#include "../__std/str.h"
#include "../__std/string.h"

_Static_assert(sizeof(Option__ptr_u8) == 16 && _Alignof(Option__ptr_u8) == 8, "super-c layout model mismatch: Option__ptr_u8");
_Static_assert(sizeof(Option__usize) == 16 && _Alignof(Option__usize) == 8, "super-c layout model mismatch: Option__usize");
_Static_assert(sizeof(Option__String__Global) == 32 && _Alignof(Option__String__Global) == 8, "super-c layout model mismatch: Option__String__Global");
_Static_assert(sizeof(Option__ptr_String__Global) == 16 && _Alignof(Option__ptr_String__Global) == 8, "super-c layout model mismatch: Option__ptr_String__Global");
_Static_assert(sizeof(Option__u32) == 8 && _Alignof(Option__u32) == 4, "super-c layout model mismatch: Option__u32");
_Static_assert(sizeof(Option__ptr_u32) == 16 && _Alignof(Option__ptr_u32) == 8, "super-c layout model mismatch: Option__ptr_u32");
_Static_assert(sizeof(Option__bool) == 8 && _Alignof(Option__bool) == 4, "super-c layout model mismatch: Option__bool");
_Static_assert(sizeof(Option__ptr_bool) == 16 && _Alignof(Option__ptr_bool) == 8, "super-c layout model mismatch: Option__ptr_bool");
_Static_assert(sizeof(Option__str) == 24 && _Alignof(Option__str) == 8, "super-c layout model mismatch: Option__str");
_Static_assert(sizeof(Option__ptr_str) == 16 && _Alignof(Option__ptr_str) == 8, "super-c layout model mismatch: Option__ptr_str");
_Static_assert(sizeof(Option__u64) == 16 && _Alignof(Option__u64) == 8, "super-c layout model mismatch: Option__u64");
_Static_assert(sizeof(Option__ptr_u64) == 16 && _Alignof(Option__ptr_u64) == 8, "super-c layout model mismatch: Option__ptr_u64");
_Static_assert(sizeof(Option__u16) == 8 && _Alignof(Option__u16) == 4, "super-c layout model mismatch: Option__u16");
_Static_assert(sizeof(Option__ptr_u16) == 16 && _Alignof(Option__ptr_u16) == 8, "super-c layout model mismatch: Option__ptr_u16");
_Static_assert(sizeof(Option__ptr_usize) == 16 && _Alignof(Option__ptr_usize) == 8, "super-c layout model mismatch: Option__ptr_usize");
_Static_assert(sizeof(Option__i64) == 16 && _Alignof(Option__i64) == 8, "super-c layout model mismatch: Option__i64");
_Static_assert(sizeof(Option__isize) == 16 && _Alignof(Option__isize) == 8, "super-c layout model mismatch: Option__isize");
_Static_assert(sizeof(Option__u8) == 8 && _Alignof(Option__u8) == 4, "super-c layout model mismatch: Option__u8");
_Static_assert(sizeof(Option__i32) == 8 && _Alignof(Option__i32) == 4, "super-c layout model mismatch: Option__i32");
_Static_assert(sizeof(Option__i16) == 8 && _Alignof(Option__i16) == 4, "super-c layout model mismatch: Option__i16");
_Static_assert(sizeof(Option__i8) == 8 && _Alignof(Option__i8) == 4, "super-c layout model mismatch: Option__i8");
_Static_assert(sizeof(Option__f64) == 16 && _Alignof(Option__f64) == 8, "super-c layout model mismatch: Option__f64");
_Static_assert(sizeof(Option__f32) == 8 && _Alignof(Option__f32) == 4, "super-c layout model mismatch: Option__f32");


Option__ptr_u8 Option__ptr_u8__some(const uint8_t *const value) {
  return (Option__ptr_u8){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_u8 Option__ptr_u8__none(void) {
  return (Option__ptr_u8){ .tag = Option_None };
}

bool Option__ptr_u8__is_some(const Option__ptr_u8 *const self) {
  {
    const Option__ptr_u8 *const __sc0 = self;
    if ((*__sc0).tag == Option_Some) {
      return true;
    }
    else if ((*__sc0).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_u8__is_none(const Option__ptr_u8 *const self) {
  {
    const Option__ptr_u8 *const __sc1 = self;
    if ((*__sc1).tag == Option_Some) {
      return false;
    }
    else if ((*__sc1).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_u8 Option__ptr_u8__default_(void) {
  return Option__ptr_u8__none();
}

Option__usize Option__usize__some(size_t const value) {
  return (Option__usize){ .tag = Option_Some, .payload.Some = { value } };
}

Option__usize Option__usize__none(void) {
  return (Option__usize){ .tag = Option_None };
}

bool Option__usize__is_some(const Option__usize *const self) {
  {
    const Option__usize *const __sc2 = self;
    if ((*__sc2).tag == Option_Some) {
      return true;
    }
    else if ((*__sc2).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__usize__is_none(const Option__usize *const self) {
  {
    const Option__usize *const __sc3 = self;
    if ((*__sc3).tag == Option_Some) {
      return false;
    }
    else if ((*__sc3).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__usize Option__usize__default_(void) {
  return Option__usize__none();
}

void Option__usize__free(Option__usize *const self) {
  {
    Option__usize *const __sc4 = self;
    if ((*__sc4).tag == Option_Some) {
      const __auto_type v = &((*__sc4).payload.Some._0);
      usize__free(v);
    }
    else if ((*__sc4).tag == Option_None) {
      {
      }
    }
  }
}

Option__usize Option__usize__clone(const Option__usize *const self) {
  {
    const Option__usize *const __sc5 = self;
    if ((*__sc5).tag == Option_Some) {
      const __auto_type v = &((*__sc5).payload.Some._0);
      return (Option__usize){ .tag = Option_Some, .payload.Some = { usize__clone(v) } };
    }
    else if ((*__sc5).tag == Option_None) {
      return (Option__usize){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__usize__eq(const Option__usize *const self, const Option__usize *const other) {
  {
    const Option__usize *const __sc6 = self;
    if ((*__sc6).tag == Option_Some) {
      const __auto_type a = &((*__sc6).payload.Some._0);
      return ({
        bool __sc7;
        const Option__usize *const __sc8 = other;
        if ((*__sc8).tag == Option_Some) {
          const __auto_type b = &((*__sc8).payload.Some._0);
          __sc7 = usize__eq(a, b);
        }
        else if ((*__sc8).tag == Option_None) {
          __sc7 = false;
        }
        else { __builtin_unreachable(); }
        __sc7;
      });
    }
    else if ((*__sc6).tag == Option_None) {
      return Option__usize__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__usize__hash(const Option__usize *const self) {
  {
    const Option__usize *const __sc9 = self;
    if ((*__sc9).tag == Option_Some) {
      const __auto_type v = &((*__sc9).payload.Some._0);
      return ((usize__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc9).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__String__Global Option__String__Global__some(String__Global value) {
  return (Option__String__Global){ .tag = Option_Some, .payload.Some = { value } };
}

Option__String__Global Option__String__Global__none(void) {
  return (Option__String__Global){ .tag = Option_None };
}

bool Option__String__Global__is_some(const Option__String__Global *const self) {
  {
    const Option__String__Global *const __sc10 = self;
    if ((*__sc10).tag == Option_Some) {
      return true;
    }
    else if ((*__sc10).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__String__Global__is_none(const Option__String__Global *const self) {
  {
    const Option__String__Global *const __sc11 = self;
    if ((*__sc11).tag == Option_Some) {
      return false;
    }
    else if ((*__sc11).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__String__Global Option__String__Global__default_(void) {
  return Option__String__Global__none();
}

void Option__String__Global__free(Option__String__Global *const self) {
  {
    Option__String__Global *const __sc12 = self;
    if ((*__sc12).tag == Option_Some) {
      const __auto_type v = &((*__sc12).payload.Some._0);
      String__Global__free(v);
    }
    else if ((*__sc12).tag == Option_None) {
      {
      }
    }
  }
}

Option__String__Global Option__String__Global__clone(const Option__String__Global *const self) {
  {
    const Option__String__Global *const __sc13 = self;
    if ((*__sc13).tag == Option_Some) {
      const __auto_type v = &((*__sc13).payload.Some._0);
      return (Option__String__Global){ .tag = Option_Some, .payload.Some = { String__Global__clone(v) } };
    }
    else if ((*__sc13).tag == Option_None) {
      return (Option__String__Global){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__String__Global__eq(const Option__String__Global *const self, const Option__String__Global *const other) {
  {
    const Option__String__Global *const __sc14 = self;
    if ((*__sc14).tag == Option_Some) {
      const __auto_type a = &((*__sc14).payload.Some._0);
      return ({
        bool __sc15;
        const Option__String__Global *const __sc16 = other;
        if ((*__sc16).tag == Option_Some) {
          const __auto_type b = &((*__sc16).payload.Some._0);
          __sc15 = String__Global__eq(a, b);
        }
        else if ((*__sc16).tag == Option_None) {
          __sc15 = false;
        }
        else { __builtin_unreachable(); }
        __sc15;
      });
    }
    else if ((*__sc14).tag == Option_None) {
      return Option__String__Global__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__String__Global__hash(const Option__String__Global *const self) {
  {
    const Option__String__Global *const __sc17 = self;
    if ((*__sc17).tag == Option_Some) {
      const __auto_type v = &((*__sc17).payload.Some._0);
      return ((String__Global__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc17).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

String__Global Option__String__Global__fmt(const Option__String__Global *const self) {
  if (Option__String__Global__is_none(self)) {
    return String__Global__from_str((str){ (const uint8_t *)"None", sizeof("None") - 1 });
  }
  String__Global inner = ({
    String__Global __sc18;
    const Option__String__Global *const __sc19 = self;
    if ((*__sc19).tag == Option_Some) {
      const __auto_type v = &((*__sc19).payload.Some._0);
      __sc18 = String__Global__fmt(v);
    }
    else if ((*__sc19).tag == Option_None) {
      __sc18 = String__Global__new();
    }
    else { __builtin_unreachable(); }
    __sc18;
  });
  String__Global s = String__Global__from_str((str){ (const uint8_t *)"Some(", sizeof("Some(") - 1 });
  String__Global__push_string(&s, (&inner));
  String__Global__free(&inner);
  String__Global__push_str(&s, (str){ (const uint8_t *)")", sizeof(")") - 1 });
  return s;
}

Option__ptr_String__Global Option__ptr_String__Global__some(const String__Global *const value) {
  return (Option__ptr_String__Global){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_String__Global Option__ptr_String__Global__none(void) {
  return (Option__ptr_String__Global){ .tag = Option_None };
}

bool Option__ptr_String__Global__is_some(const Option__ptr_String__Global *const self) {
  {
    const Option__ptr_String__Global *const __sc20 = self;
    if ((*__sc20).tag == Option_Some) {
      return true;
    }
    else if ((*__sc20).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_String__Global__is_none(const Option__ptr_String__Global *const self) {
  {
    const Option__ptr_String__Global *const __sc21 = self;
    if ((*__sc21).tag == Option_Some) {
      return false;
    }
    else if ((*__sc21).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_String__Global Option__ptr_String__Global__default_(void) {
  return Option__ptr_String__Global__none();
}

Option__u32 Option__u32__some(uint32_t const value) {
  return (Option__u32){ .tag = Option_Some, .payload.Some = { value } };
}

Option__u32 Option__u32__none(void) {
  return (Option__u32){ .tag = Option_None };
}

bool Option__u32__is_some(const Option__u32 *const self) {
  {
    const Option__u32 *const __sc22 = self;
    if ((*__sc22).tag == Option_Some) {
      return true;
    }
    else if ((*__sc22).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__u32__is_none(const Option__u32 *const self) {
  {
    const Option__u32 *const __sc23 = self;
    if ((*__sc23).tag == Option_Some) {
      return false;
    }
    else if ((*__sc23).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__u32 Option__u32__default_(void) {
  return Option__u32__none();
}

void Option__u32__free(Option__u32 *const self) {
  {
    Option__u32 *const __sc24 = self;
    if ((*__sc24).tag == Option_Some) {
      const __auto_type v = &((*__sc24).payload.Some._0);
      u32__free(v);
    }
    else if ((*__sc24).tag == Option_None) {
      {
      }
    }
  }
}

Option__u32 Option__u32__clone(const Option__u32 *const self) {
  {
    const Option__u32 *const __sc25 = self;
    if ((*__sc25).tag == Option_Some) {
      const __auto_type v = &((*__sc25).payload.Some._0);
      return (Option__u32){ .tag = Option_Some, .payload.Some = { u32__clone(v) } };
    }
    else if ((*__sc25).tag == Option_None) {
      return (Option__u32){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__u32__eq(const Option__u32 *const self, const Option__u32 *const other) {
  {
    const Option__u32 *const __sc26 = self;
    if ((*__sc26).tag == Option_Some) {
      const __auto_type a = &((*__sc26).payload.Some._0);
      return ({
        bool __sc27;
        const Option__u32 *const __sc28 = other;
        if ((*__sc28).tag == Option_Some) {
          const __auto_type b = &((*__sc28).payload.Some._0);
          __sc27 = u32__eq(a, b);
        }
        else if ((*__sc28).tag == Option_None) {
          __sc27 = false;
        }
        else { __builtin_unreachable(); }
        __sc27;
      });
    }
    else if ((*__sc26).tag == Option_None) {
      return Option__u32__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__u32__hash(const Option__u32 *const self) {
  {
    const Option__u32 *const __sc29 = self;
    if ((*__sc29).tag == Option_Some) {
      const __auto_type v = &((*__sc29).payload.Some._0);
      return ((u32__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc29).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_u32 Option__ptr_u32__some(const uint32_t *const value) {
  return (Option__ptr_u32){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_u32 Option__ptr_u32__none(void) {
  return (Option__ptr_u32){ .tag = Option_None };
}

bool Option__ptr_u32__is_some(const Option__ptr_u32 *const self) {
  {
    const Option__ptr_u32 *const __sc30 = self;
    if ((*__sc30).tag == Option_Some) {
      return true;
    }
    else if ((*__sc30).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_u32__is_none(const Option__ptr_u32 *const self) {
  {
    const Option__ptr_u32 *const __sc31 = self;
    if ((*__sc31).tag == Option_Some) {
      return false;
    }
    else if ((*__sc31).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_u32 Option__ptr_u32__default_(void) {
  return Option__ptr_u32__none();
}

Option__bool Option__bool__some(bool const value) {
  return (Option__bool){ .tag = Option_Some, .payload.Some = { value } };
}

Option__bool Option__bool__none(void) {
  return (Option__bool){ .tag = Option_None };
}

bool Option__bool__is_some(const Option__bool *const self) {
  {
    const Option__bool *const __sc32 = self;
    if ((*__sc32).tag == Option_Some) {
      return true;
    }
    else if ((*__sc32).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__bool__is_none(const Option__bool *const self) {
  {
    const Option__bool *const __sc33 = self;
    if ((*__sc33).tag == Option_Some) {
      return false;
    }
    else if ((*__sc33).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__bool Option__bool__default_(void) {
  return Option__bool__none();
}

void Option__bool__free(Option__bool *const self) {
  {
    Option__bool *const __sc34 = self;
    if ((*__sc34).tag == Option_Some) {
      const __auto_type v = &((*__sc34).payload.Some._0);
      bool__free(v);
    }
    else if ((*__sc34).tag == Option_None) {
      {
      }
    }
  }
}

Option__bool Option__bool__clone(const Option__bool *const self) {
  {
    const Option__bool *const __sc35 = self;
    if ((*__sc35).tag == Option_Some) {
      const __auto_type v = &((*__sc35).payload.Some._0);
      return (Option__bool){ .tag = Option_Some, .payload.Some = { bool__clone(v) } };
    }
    else if ((*__sc35).tag == Option_None) {
      return (Option__bool){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__bool__eq(const Option__bool *const self, const Option__bool *const other) {
  {
    const Option__bool *const __sc36 = self;
    if ((*__sc36).tag == Option_Some) {
      const __auto_type a = &((*__sc36).payload.Some._0);
      return ({
        bool __sc37;
        const Option__bool *const __sc38 = other;
        if ((*__sc38).tag == Option_Some) {
          const __auto_type b = &((*__sc38).payload.Some._0);
          __sc37 = bool__eq(a, b);
        }
        else if ((*__sc38).tag == Option_None) {
          __sc37 = false;
        }
        else { __builtin_unreachable(); }
        __sc37;
      });
    }
    else if ((*__sc36).tag == Option_None) {
      return Option__bool__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__bool__hash(const Option__bool *const self) {
  {
    const Option__bool *const __sc39 = self;
    if ((*__sc39).tag == Option_Some) {
      const __auto_type v = &((*__sc39).payload.Some._0);
      return ((bool__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc39).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_bool Option__ptr_bool__some(const bool *const value) {
  return (Option__ptr_bool){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_bool Option__ptr_bool__none(void) {
  return (Option__ptr_bool){ .tag = Option_None };
}

bool Option__ptr_bool__is_some(const Option__ptr_bool *const self) {
  {
    const Option__ptr_bool *const __sc40 = self;
    if ((*__sc40).tag == Option_Some) {
      return true;
    }
    else if ((*__sc40).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_bool__is_none(const Option__ptr_bool *const self) {
  {
    const Option__ptr_bool *const __sc41 = self;
    if ((*__sc41).tag == Option_Some) {
      return false;
    }
    else if ((*__sc41).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_bool Option__ptr_bool__default_(void) {
  return Option__ptr_bool__none();
}

Option__str Option__str__some(str const value) {
  return (Option__str){ .tag = Option_Some, .payload.Some = { value } };
}

Option__str Option__str__none(void) {
  return (Option__str){ .tag = Option_None };
}

bool Option__str__is_some(const Option__str *const self) {
  {
    const Option__str *const __sc42 = self;
    if ((*__sc42).tag == Option_Some) {
      return true;
    }
    else if ((*__sc42).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__str__is_none(const Option__str *const self) {
  {
    const Option__str *const __sc43 = self;
    if ((*__sc43).tag == Option_Some) {
      return false;
    }
    else if ((*__sc43).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__str Option__str__default_(void) {
  return Option__str__none();
}

bool Option__str__eq(const Option__str *const self, const Option__str *const other) {
  {
    const Option__str *const __sc44 = self;
    if ((*__sc44).tag == Option_Some) {
      const __auto_type a = &((*__sc44).payload.Some._0);
      return ({
        bool __sc45;
        const Option__str *const __sc46 = other;
        if ((*__sc46).tag == Option_Some) {
          const __auto_type b = &((*__sc46).payload.Some._0);
          __sc45 = str__eq(a, b);
        }
        else if ((*__sc46).tag == Option_None) {
          __sc45 = false;
        }
        else { __builtin_unreachable(); }
        __sc45;
      });
    }
    else if ((*__sc44).tag == Option_None) {
      return Option__str__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__str__hash(const Option__str *const self) {
  {
    const Option__str *const __sc47 = self;
    if ((*__sc47).tag == Option_Some) {
      const __auto_type v = &((*__sc47).payload.Some._0);
      return ((str__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc47).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_str Option__ptr_str__some(const str *const value) {
  return (Option__ptr_str){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_str Option__ptr_str__none(void) {
  return (Option__ptr_str){ .tag = Option_None };
}

bool Option__ptr_str__is_some(const Option__ptr_str *const self) {
  {
    const Option__ptr_str *const __sc48 = self;
    if ((*__sc48).tag == Option_Some) {
      return true;
    }
    else if ((*__sc48).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_str__is_none(const Option__ptr_str *const self) {
  {
    const Option__ptr_str *const __sc49 = self;
    if ((*__sc49).tag == Option_Some) {
      return false;
    }
    else if ((*__sc49).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_str Option__ptr_str__default_(void) {
  return Option__ptr_str__none();
}

Option__u64 Option__u64__some(uint64_t const value) {
  return (Option__u64){ .tag = Option_Some, .payload.Some = { value } };
}

Option__u64 Option__u64__none(void) {
  return (Option__u64){ .tag = Option_None };
}

bool Option__u64__is_some(const Option__u64 *const self) {
  {
    const Option__u64 *const __sc50 = self;
    if ((*__sc50).tag == Option_Some) {
      return true;
    }
    else if ((*__sc50).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__u64__is_none(const Option__u64 *const self) {
  {
    const Option__u64 *const __sc51 = self;
    if ((*__sc51).tag == Option_Some) {
      return false;
    }
    else if ((*__sc51).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__u64 Option__u64__default_(void) {
  return Option__u64__none();
}

void Option__u64__free(Option__u64 *const self) {
  {
    Option__u64 *const __sc52 = self;
    if ((*__sc52).tag == Option_Some) {
      const __auto_type v = &((*__sc52).payload.Some._0);
      u64__free(v);
    }
    else if ((*__sc52).tag == Option_None) {
      {
      }
    }
  }
}

Option__u64 Option__u64__clone(const Option__u64 *const self) {
  {
    const Option__u64 *const __sc53 = self;
    if ((*__sc53).tag == Option_Some) {
      const __auto_type v = &((*__sc53).payload.Some._0);
      return (Option__u64){ .tag = Option_Some, .payload.Some = { u64__clone(v) } };
    }
    else if ((*__sc53).tag == Option_None) {
      return (Option__u64){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__u64__eq(const Option__u64 *const self, const Option__u64 *const other) {
  {
    const Option__u64 *const __sc54 = self;
    if ((*__sc54).tag == Option_Some) {
      const __auto_type a = &((*__sc54).payload.Some._0);
      return ({
        bool __sc55;
        const Option__u64 *const __sc56 = other;
        if ((*__sc56).tag == Option_Some) {
          const __auto_type b = &((*__sc56).payload.Some._0);
          __sc55 = u64__eq(a, b);
        }
        else if ((*__sc56).tag == Option_None) {
          __sc55 = false;
        }
        else { __builtin_unreachable(); }
        __sc55;
      });
    }
    else if ((*__sc54).tag == Option_None) {
      return Option__u64__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__u64__hash(const Option__u64 *const self) {
  {
    const Option__u64 *const __sc57 = self;
    if ((*__sc57).tag == Option_Some) {
      const __auto_type v = &((*__sc57).payload.Some._0);
      return ((u64__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc57).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_u64 Option__ptr_u64__some(const uint64_t *const value) {
  return (Option__ptr_u64){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_u64 Option__ptr_u64__none(void) {
  return (Option__ptr_u64){ .tag = Option_None };
}

bool Option__ptr_u64__is_some(const Option__ptr_u64 *const self) {
  {
    const Option__ptr_u64 *const __sc58 = self;
    if ((*__sc58).tag == Option_Some) {
      return true;
    }
    else if ((*__sc58).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_u64__is_none(const Option__ptr_u64 *const self) {
  {
    const Option__ptr_u64 *const __sc59 = self;
    if ((*__sc59).tag == Option_Some) {
      return false;
    }
    else if ((*__sc59).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_u64 Option__ptr_u64__default_(void) {
  return Option__ptr_u64__none();
}

Option__u16 Option__u16__some(uint16_t const value) {
  return (Option__u16){ .tag = Option_Some, .payload.Some = { value } };
}

Option__u16 Option__u16__none(void) {
  return (Option__u16){ .tag = Option_None };
}

bool Option__u16__is_some(const Option__u16 *const self) {
  {
    const Option__u16 *const __sc60 = self;
    if ((*__sc60).tag == Option_Some) {
      return true;
    }
    else if ((*__sc60).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__u16__is_none(const Option__u16 *const self) {
  {
    const Option__u16 *const __sc61 = self;
    if ((*__sc61).tag == Option_Some) {
      return false;
    }
    else if ((*__sc61).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__u16 Option__u16__default_(void) {
  return Option__u16__none();
}

void Option__u16__free(Option__u16 *const self) {
  {
    Option__u16 *const __sc62 = self;
    if ((*__sc62).tag == Option_Some) {
      const __auto_type v = &((*__sc62).payload.Some._0);
      u16__free(v);
    }
    else if ((*__sc62).tag == Option_None) {
      {
      }
    }
  }
}

Option__u16 Option__u16__clone(const Option__u16 *const self) {
  {
    const Option__u16 *const __sc63 = self;
    if ((*__sc63).tag == Option_Some) {
      const __auto_type v = &((*__sc63).payload.Some._0);
      return (Option__u16){ .tag = Option_Some, .payload.Some = { u16__clone(v) } };
    }
    else if ((*__sc63).tag == Option_None) {
      return (Option__u16){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__u16__eq(const Option__u16 *const self, const Option__u16 *const other) {
  {
    const Option__u16 *const __sc64 = self;
    if ((*__sc64).tag == Option_Some) {
      const __auto_type a = &((*__sc64).payload.Some._0);
      return ({
        bool __sc65;
        const Option__u16 *const __sc66 = other;
        if ((*__sc66).tag == Option_Some) {
          const __auto_type b = &((*__sc66).payload.Some._0);
          __sc65 = u16__eq(a, b);
        }
        else if ((*__sc66).tag == Option_None) {
          __sc65 = false;
        }
        else { __builtin_unreachable(); }
        __sc65;
      });
    }
    else if ((*__sc64).tag == Option_None) {
      return Option__u16__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__u16__hash(const Option__u16 *const self) {
  {
    const Option__u16 *const __sc67 = self;
    if ((*__sc67).tag == Option_Some) {
      const __auto_type v = &((*__sc67).payload.Some._0);
      return ((u16__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc67).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_u16 Option__ptr_u16__some(const uint16_t *const value) {
  return (Option__ptr_u16){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_u16 Option__ptr_u16__none(void) {
  return (Option__ptr_u16){ .tag = Option_None };
}

bool Option__ptr_u16__is_some(const Option__ptr_u16 *const self) {
  {
    const Option__ptr_u16 *const __sc68 = self;
    if ((*__sc68).tag == Option_Some) {
      return true;
    }
    else if ((*__sc68).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_u16__is_none(const Option__ptr_u16 *const self) {
  {
    const Option__ptr_u16 *const __sc69 = self;
    if ((*__sc69).tag == Option_Some) {
      return false;
    }
    else if ((*__sc69).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_u16 Option__ptr_u16__default_(void) {
  return Option__ptr_u16__none();
}

Option__ptr_usize Option__ptr_usize__some(const size_t *const value) {
  return (Option__ptr_usize){ .tag = Option_Some, .payload.Some = { value } };
}

Option__ptr_usize Option__ptr_usize__none(void) {
  return (Option__ptr_usize){ .tag = Option_None };
}

bool Option__ptr_usize__is_some(const Option__ptr_usize *const self) {
  {
    const Option__ptr_usize *const __sc70 = self;
    if ((*__sc70).tag == Option_Some) {
      return true;
    }
    else if ((*__sc70).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__ptr_usize__is_none(const Option__ptr_usize *const self) {
  {
    const Option__ptr_usize *const __sc71 = self;
    if ((*__sc71).tag == Option_Some) {
      return false;
    }
    else if ((*__sc71).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__ptr_usize Option__ptr_usize__default_(void) {
  return Option__ptr_usize__none();
}

Option__i64 Option__i64__some(int64_t const value) {
  return (Option__i64){ .tag = Option_Some, .payload.Some = { value } };
}

Option__i64 Option__i64__none(void) {
  return (Option__i64){ .tag = Option_None };
}

bool Option__i64__is_some(const Option__i64 *const self) {
  {
    const Option__i64 *const __sc72 = self;
    if ((*__sc72).tag == Option_Some) {
      return true;
    }
    else if ((*__sc72).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__i64__is_none(const Option__i64 *const self) {
  {
    const Option__i64 *const __sc73 = self;
    if ((*__sc73).tag == Option_Some) {
      return false;
    }
    else if ((*__sc73).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__i64 Option__i64__default_(void) {
  return Option__i64__none();
}

void Option__i64__free(Option__i64 *const self) {
  {
    Option__i64 *const __sc74 = self;
    if ((*__sc74).tag == Option_Some) {
      const __auto_type v = &((*__sc74).payload.Some._0);
      i64__free(v);
    }
    else if ((*__sc74).tag == Option_None) {
      {
      }
    }
  }
}

Option__i64 Option__i64__clone(const Option__i64 *const self) {
  {
    const Option__i64 *const __sc75 = self;
    if ((*__sc75).tag == Option_Some) {
      const __auto_type v = &((*__sc75).payload.Some._0);
      return (Option__i64){ .tag = Option_Some, .payload.Some = { i64__clone(v) } };
    }
    else if ((*__sc75).tag == Option_None) {
      return (Option__i64){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__i64__eq(const Option__i64 *const self, const Option__i64 *const other) {
  {
    const Option__i64 *const __sc76 = self;
    if ((*__sc76).tag == Option_Some) {
      const __auto_type a = &((*__sc76).payload.Some._0);
      return ({
        bool __sc77;
        const Option__i64 *const __sc78 = other;
        if ((*__sc78).tag == Option_Some) {
          const __auto_type b = &((*__sc78).payload.Some._0);
          __sc77 = i64__eq(a, b);
        }
        else if ((*__sc78).tag == Option_None) {
          __sc77 = false;
        }
        else { __builtin_unreachable(); }
        __sc77;
      });
    }
    else if ((*__sc76).tag == Option_None) {
      return Option__i64__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__i64__hash(const Option__i64 *const self) {
  {
    const Option__i64 *const __sc79 = self;
    if ((*__sc79).tag == Option_Some) {
      const __auto_type v = &((*__sc79).payload.Some._0);
      return ((i64__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc79).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__isize Option__isize__some(intptr_t const value) {
  return (Option__isize){ .tag = Option_Some, .payload.Some = { value } };
}

Option__isize Option__isize__none(void) {
  return (Option__isize){ .tag = Option_None };
}

bool Option__isize__is_some(const Option__isize *const self) {
  {
    const Option__isize *const __sc80 = self;
    if ((*__sc80).tag == Option_Some) {
      return true;
    }
    else if ((*__sc80).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__isize__is_none(const Option__isize *const self) {
  {
    const Option__isize *const __sc81 = self;
    if ((*__sc81).tag == Option_Some) {
      return false;
    }
    else if ((*__sc81).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__isize Option__isize__default_(void) {
  return Option__isize__none();
}

void Option__isize__free(Option__isize *const self) {
  {
    Option__isize *const __sc82 = self;
    if ((*__sc82).tag == Option_Some) {
      const __auto_type v = &((*__sc82).payload.Some._0);
      isize__free(v);
    }
    else if ((*__sc82).tag == Option_None) {
      {
      }
    }
  }
}

Option__isize Option__isize__clone(const Option__isize *const self) {
  {
    const Option__isize *const __sc83 = self;
    if ((*__sc83).tag == Option_Some) {
      const __auto_type v = &((*__sc83).payload.Some._0);
      return (Option__isize){ .tag = Option_Some, .payload.Some = { isize__clone(v) } };
    }
    else if ((*__sc83).tag == Option_None) {
      return (Option__isize){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__isize__eq(const Option__isize *const self, const Option__isize *const other) {
  {
    const Option__isize *const __sc84 = self;
    if ((*__sc84).tag == Option_Some) {
      const __auto_type a = &((*__sc84).payload.Some._0);
      return ({
        bool __sc85;
        const Option__isize *const __sc86 = other;
        if ((*__sc86).tag == Option_Some) {
          const __auto_type b = &((*__sc86).payload.Some._0);
          __sc85 = isize__eq(a, b);
        }
        else if ((*__sc86).tag == Option_None) {
          __sc85 = false;
        }
        else { __builtin_unreachable(); }
        __sc85;
      });
    }
    else if ((*__sc84).tag == Option_None) {
      return Option__isize__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__isize__hash(const Option__isize *const self) {
  {
    const Option__isize *const __sc87 = self;
    if ((*__sc87).tag == Option_Some) {
      const __auto_type v = &((*__sc87).payload.Some._0);
      return ((isize__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc87).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__u8 Option__u8__some(uint8_t const value) {
  return (Option__u8){ .tag = Option_Some, .payload.Some = { value } };
}

Option__u8 Option__u8__none(void) {
  return (Option__u8){ .tag = Option_None };
}

bool Option__u8__is_some(const Option__u8 *const self) {
  {
    const Option__u8 *const __sc88 = self;
    if ((*__sc88).tag == Option_Some) {
      return true;
    }
    else if ((*__sc88).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__u8__is_none(const Option__u8 *const self) {
  {
    const Option__u8 *const __sc89 = self;
    if ((*__sc89).tag == Option_Some) {
      return false;
    }
    else if ((*__sc89).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__u8 Option__u8__default_(void) {
  return Option__u8__none();
}

void Option__u8__free(Option__u8 *const self) {
  {
    Option__u8 *const __sc90 = self;
    if ((*__sc90).tag == Option_Some) {
      const __auto_type v = &((*__sc90).payload.Some._0);
      u8__free(v);
    }
    else if ((*__sc90).tag == Option_None) {
      {
      }
    }
  }
}

Option__u8 Option__u8__clone(const Option__u8 *const self) {
  {
    const Option__u8 *const __sc91 = self;
    if ((*__sc91).tag == Option_Some) {
      const __auto_type v = &((*__sc91).payload.Some._0);
      return (Option__u8){ .tag = Option_Some, .payload.Some = { u8__clone(v) } };
    }
    else if ((*__sc91).tag == Option_None) {
      return (Option__u8){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__u8__eq(const Option__u8 *const self, const Option__u8 *const other) {
  {
    const Option__u8 *const __sc92 = self;
    if ((*__sc92).tag == Option_Some) {
      const __auto_type a = &((*__sc92).payload.Some._0);
      return ({
        bool __sc93;
        const Option__u8 *const __sc94 = other;
        if ((*__sc94).tag == Option_Some) {
          const __auto_type b = &((*__sc94).payload.Some._0);
          __sc93 = u8__eq(a, b);
        }
        else if ((*__sc94).tag == Option_None) {
          __sc93 = false;
        }
        else { __builtin_unreachable(); }
        __sc93;
      });
    }
    else if ((*__sc92).tag == Option_None) {
      return Option__u8__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__u8__hash(const Option__u8 *const self) {
  {
    const Option__u8 *const __sc95 = self;
    if ((*__sc95).tag == Option_Some) {
      const __auto_type v = &((*__sc95).payload.Some._0);
      return ((u8__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc95).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__i32 Option__i32__some(int32_t const value) {
  return (Option__i32){ .tag = Option_Some, .payload.Some = { value } };
}

Option__i32 Option__i32__none(void) {
  return (Option__i32){ .tag = Option_None };
}

bool Option__i32__is_some(const Option__i32 *const self) {
  {
    const Option__i32 *const __sc96 = self;
    if ((*__sc96).tag == Option_Some) {
      return true;
    }
    else if ((*__sc96).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__i32__is_none(const Option__i32 *const self) {
  {
    const Option__i32 *const __sc97 = self;
    if ((*__sc97).tag == Option_Some) {
      return false;
    }
    else if ((*__sc97).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__i32 Option__i32__default_(void) {
  return Option__i32__none();
}

void Option__i32__free(Option__i32 *const self) {
  {
    Option__i32 *const __sc98 = self;
    if ((*__sc98).tag == Option_Some) {
      const __auto_type v = &((*__sc98).payload.Some._0);
      i32__free(v);
    }
    else if ((*__sc98).tag == Option_None) {
      {
      }
    }
  }
}

Option__i32 Option__i32__clone(const Option__i32 *const self) {
  {
    const Option__i32 *const __sc99 = self;
    if ((*__sc99).tag == Option_Some) {
      const __auto_type v = &((*__sc99).payload.Some._0);
      return (Option__i32){ .tag = Option_Some, .payload.Some = { i32__clone(v) } };
    }
    else if ((*__sc99).tag == Option_None) {
      return (Option__i32){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__i32__eq(const Option__i32 *const self, const Option__i32 *const other) {
  {
    const Option__i32 *const __sc100 = self;
    if ((*__sc100).tag == Option_Some) {
      const __auto_type a = &((*__sc100).payload.Some._0);
      return ({
        bool __sc101;
        const Option__i32 *const __sc102 = other;
        if ((*__sc102).tag == Option_Some) {
          const __auto_type b = &((*__sc102).payload.Some._0);
          __sc101 = i32__eq(a, b);
        }
        else if ((*__sc102).tag == Option_None) {
          __sc101 = false;
        }
        else { __builtin_unreachable(); }
        __sc101;
      });
    }
    else if ((*__sc100).tag == Option_None) {
      return Option__i32__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__i32__hash(const Option__i32 *const self) {
  {
    const Option__i32 *const __sc103 = self;
    if ((*__sc103).tag == Option_Some) {
      const __auto_type v = &((*__sc103).payload.Some._0);
      return ((i32__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc103).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__i16 Option__i16__some(int16_t const value) {
  return (Option__i16){ .tag = Option_Some, .payload.Some = { value } };
}

Option__i16 Option__i16__none(void) {
  return (Option__i16){ .tag = Option_None };
}

bool Option__i16__is_some(const Option__i16 *const self) {
  {
    const Option__i16 *const __sc104 = self;
    if ((*__sc104).tag == Option_Some) {
      return true;
    }
    else if ((*__sc104).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__i16__is_none(const Option__i16 *const self) {
  {
    const Option__i16 *const __sc105 = self;
    if ((*__sc105).tag == Option_Some) {
      return false;
    }
    else if ((*__sc105).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__i16 Option__i16__default_(void) {
  return Option__i16__none();
}

void Option__i16__free(Option__i16 *const self) {
  {
    Option__i16 *const __sc106 = self;
    if ((*__sc106).tag == Option_Some) {
      const __auto_type v = &((*__sc106).payload.Some._0);
      i16__free(v);
    }
    else if ((*__sc106).tag == Option_None) {
      {
      }
    }
  }
}

Option__i16 Option__i16__clone(const Option__i16 *const self) {
  {
    const Option__i16 *const __sc107 = self;
    if ((*__sc107).tag == Option_Some) {
      const __auto_type v = &((*__sc107).payload.Some._0);
      return (Option__i16){ .tag = Option_Some, .payload.Some = { i16__clone(v) } };
    }
    else if ((*__sc107).tag == Option_None) {
      return (Option__i16){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__i16__eq(const Option__i16 *const self, const Option__i16 *const other) {
  {
    const Option__i16 *const __sc108 = self;
    if ((*__sc108).tag == Option_Some) {
      const __auto_type a = &((*__sc108).payload.Some._0);
      return ({
        bool __sc109;
        const Option__i16 *const __sc110 = other;
        if ((*__sc110).tag == Option_Some) {
          const __auto_type b = &((*__sc110).payload.Some._0);
          __sc109 = i16__eq(a, b);
        }
        else if ((*__sc110).tag == Option_None) {
          __sc109 = false;
        }
        else { __builtin_unreachable(); }
        __sc109;
      });
    }
    else if ((*__sc108).tag == Option_None) {
      return Option__i16__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__i16__hash(const Option__i16 *const self) {
  {
    const Option__i16 *const __sc111 = self;
    if ((*__sc111).tag == Option_Some) {
      const __auto_type v = &((*__sc111).payload.Some._0);
      return ((i16__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc111).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__i8 Option__i8__some(int8_t const value) {
  return (Option__i8){ .tag = Option_Some, .payload.Some = { value } };
}

Option__i8 Option__i8__none(void) {
  return (Option__i8){ .tag = Option_None };
}

bool Option__i8__is_some(const Option__i8 *const self) {
  {
    const Option__i8 *const __sc112 = self;
    if ((*__sc112).tag == Option_Some) {
      return true;
    }
    else if ((*__sc112).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__i8__is_none(const Option__i8 *const self) {
  {
    const Option__i8 *const __sc113 = self;
    if ((*__sc113).tag == Option_Some) {
      return false;
    }
    else if ((*__sc113).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__i8 Option__i8__default_(void) {
  return Option__i8__none();
}

void Option__i8__free(Option__i8 *const self) {
  {
    Option__i8 *const __sc114 = self;
    if ((*__sc114).tag == Option_Some) {
      const __auto_type v = &((*__sc114).payload.Some._0);
      i8__free(v);
    }
    else if ((*__sc114).tag == Option_None) {
      {
      }
    }
  }
}

Option__i8 Option__i8__clone(const Option__i8 *const self) {
  {
    const Option__i8 *const __sc115 = self;
    if ((*__sc115).tag == Option_Some) {
      const __auto_type v = &((*__sc115).payload.Some._0);
      return (Option__i8){ .tag = Option_Some, .payload.Some = { i8__clone(v) } };
    }
    else if ((*__sc115).tag == Option_None) {
      return (Option__i8){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__i8__eq(const Option__i8 *const self, const Option__i8 *const other) {
  {
    const Option__i8 *const __sc116 = self;
    if ((*__sc116).tag == Option_Some) {
      const __auto_type a = &((*__sc116).payload.Some._0);
      return ({
        bool __sc117;
        const Option__i8 *const __sc118 = other;
        if ((*__sc118).tag == Option_Some) {
          const __auto_type b = &((*__sc118).payload.Some._0);
          __sc117 = i8__eq(a, b);
        }
        else if ((*__sc118).tag == Option_None) {
          __sc117 = false;
        }
        else { __builtin_unreachable(); }
        __sc117;
      });
    }
    else if ((*__sc116).tag == Option_None) {
      return Option__i8__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__i8__hash(const Option__i8 *const self) {
  {
    const Option__i8 *const __sc119 = self;
    if ((*__sc119).tag == Option_Some) {
      const __auto_type v = &((*__sc119).payload.Some._0);
      return ((i8__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc119).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__f64 Option__f64__some(double const value) {
  return (Option__f64){ .tag = Option_Some, .payload.Some = { value } };
}

Option__f64 Option__f64__none(void) {
  return (Option__f64){ .tag = Option_None };
}

bool Option__f64__is_some(const Option__f64 *const self) {
  {
    const Option__f64 *const __sc120 = self;
    if ((*__sc120).tag == Option_Some) {
      return true;
    }
    else if ((*__sc120).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__f64__is_none(const Option__f64 *const self) {
  {
    const Option__f64 *const __sc121 = self;
    if ((*__sc121).tag == Option_Some) {
      return false;
    }
    else if ((*__sc121).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__f64 Option__f64__default_(void) {
  return Option__f64__none();
}

void Option__f64__free(Option__f64 *const self) {
  {
    Option__f64 *const __sc122 = self;
    if ((*__sc122).tag == Option_Some) {
      const __auto_type v = &((*__sc122).payload.Some._0);
      f64__free(v);
    }
    else if ((*__sc122).tag == Option_None) {
      {
      }
    }
  }
}

Option__f64 Option__f64__clone(const Option__f64 *const self) {
  {
    const Option__f64 *const __sc123 = self;
    if ((*__sc123).tag == Option_Some) {
      const __auto_type v = &((*__sc123).payload.Some._0);
      return (Option__f64){ .tag = Option_Some, .payload.Some = { f64__clone(v) } };
    }
    else if ((*__sc123).tag == Option_None) {
      return (Option__f64){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__f64__eq(const Option__f64 *const self, const Option__f64 *const other) {
  {
    const Option__f64 *const __sc124 = self;
    if ((*__sc124).tag == Option_Some) {
      const __auto_type a = &((*__sc124).payload.Some._0);
      return ({
        bool __sc125;
        const Option__f64 *const __sc126 = other;
        if ((*__sc126).tag == Option_Some) {
          const __auto_type b = &((*__sc126).payload.Some._0);
          __sc125 = f64__eq(a, b);
        }
        else if ((*__sc126).tag == Option_None) {
          __sc125 = false;
        }
        else { __builtin_unreachable(); }
        __sc125;
      });
    }
    else if ((*__sc124).tag == Option_None) {
      return Option__f64__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__f64__hash(const Option__f64 *const self) {
  {
    const Option__f64 *const __sc127 = self;
    if ((*__sc127).tag == Option_Some) {
      const __auto_type v = &((*__sc127).payload.Some._0);
      return ((f64__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc127).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

Option__f32 Option__f32__some(float const value) {
  return (Option__f32){ .tag = Option_Some, .payload.Some = { value } };
}

Option__f32 Option__f32__none(void) {
  return (Option__f32){ .tag = Option_None };
}

bool Option__f32__is_some(const Option__f32 *const self) {
  {
    const Option__f32 *const __sc128 = self;
    if ((*__sc128).tag == Option_Some) {
      return true;
    }
    else if ((*__sc128).tag == Option_None) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__f32__is_none(const Option__f32 *const self) {
  {
    const Option__f32 *const __sc129 = self;
    if ((*__sc129).tag == Option_Some) {
      return false;
    }
    else if ((*__sc129).tag == Option_None) {
      return true;
    }
    else { __builtin_unreachable(); }
  }
}

Option__f32 Option__f32__default_(void) {
  return Option__f32__none();
}

void Option__f32__free(Option__f32 *const self) {
  {
    Option__f32 *const __sc130 = self;
    if ((*__sc130).tag == Option_Some) {
      const __auto_type v = &((*__sc130).payload.Some._0);
      f32__free(v);
    }
    else if ((*__sc130).tag == Option_None) {
      {
      }
    }
  }
}

Option__f32 Option__f32__clone(const Option__f32 *const self) {
  {
    const Option__f32 *const __sc131 = self;
    if ((*__sc131).tag == Option_Some) {
      const __auto_type v = &((*__sc131).payload.Some._0);
      return (Option__f32){ .tag = Option_Some, .payload.Some = { f32__clone(v) } };
    }
    else if ((*__sc131).tag == Option_None) {
      return (Option__f32){ .tag = Option_None };
    }
    else { __builtin_unreachable(); }
  }
}

bool Option__f32__eq(const Option__f32 *const self, const Option__f32 *const other) {
  {
    const Option__f32 *const __sc132 = self;
    if ((*__sc132).tag == Option_Some) {
      const __auto_type a = &((*__sc132).payload.Some._0);
      return ({
        bool __sc133;
        const Option__f32 *const __sc134 = other;
        if ((*__sc134).tag == Option_Some) {
          const __auto_type b = &((*__sc134).payload.Some._0);
          __sc133 = f32__eq(a, b);
        }
        else if ((*__sc134).tag == Option_None) {
          __sc133 = false;
        }
        else { __builtin_unreachable(); }
        __sc133;
      });
    }
    else if ((*__sc132).tag == Option_None) {
      return Option__f32__is_none(other);
    }
    else { __builtin_unreachable(); }
  }
}

uint64_t Option__f32__hash(const Option__f32 *const self) {
  {
    const Option__f32 *const __sc135 = self;
    if ((*__sc135).tag == Option_Some) {
      const __auto_type v = &((*__sc135).payload.Some._0);
      return ((f32__hash(v) * 0x100000001b3ULL) + 1ULL);
    }
    else if ((*__sc135).tag == Option_None) {
      return 0ULL;
    }
    else { __builtin_unreachable(); }
  }
}

