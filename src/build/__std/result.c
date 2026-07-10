#include "../__std/result.h"
#include "../__std/core.h"
#include "../__std/interfaces.h"
#include "../__std/option.h"
#include "../__std/range.h"
#include "../__std/slice.h"
#include "../__std/str.h"
#include "../__std/string.h"

_Static_assert(sizeof(Result__usize__usize) == 16 && _Alignof(Result__usize__usize) == 8, "super-c layout model mismatch: Result__usize__usize");


bool Result__usize__usize__is_ok(const Result__usize__usize *const self) {
  {
    const Result__usize__usize *const __sc0 = self;
    if ((*__sc0).tag == Result_Ok) {
      return true;
    }
    else if ((*__sc0).tag == Result_Err) {
      return false;
    }
    else { __builtin_unreachable(); }
  }
}

void Result__usize__usize__free(Result__usize__usize *const self) {
  {
    Result__usize__usize *const __sc1 = self;
    if ((*__sc1).tag == Result_Ok) {
      const __auto_type v = &((*__sc1).payload.Ok._0);
      usize__free(v);
    }
    else if ((*__sc1).tag == Result_Err) {
      const __auto_type e = &((*__sc1).payload.Err._0);
      (void)(e);
    }
  }
}

Result__usize__usize Result__usize__usize__clone(const Result__usize__usize *const self) {
  {
    const Result__usize__usize *const __sc2 = self;
    if ((*__sc2).tag == Result_Ok) {
      const __auto_type v = &((*__sc2).payload.Ok._0);
      return (Result__usize__usize){ .tag = Result_Ok, .payload.Ok = { usize__clone(v) } };
    }
    else if ((*__sc2).tag == Result_Err) {
      const __auto_type e = &((*__sc2).payload.Err._0);
      return (Result__usize__usize){ .tag = Result_Err, .payload.Err = { usize__clone(e) } };
    }
    else { __builtin_unreachable(); }
  }
}

bool Result__usize__usize__eq(const Result__usize__usize *const self, const Result__usize__usize *const other) {
  {
    const Result__usize__usize *const __sc3 = self;
    if ((*__sc3).tag == Result_Ok) {
      const __auto_type a = &((*__sc3).payload.Ok._0);
      return ({
        bool __sc4;
        const Result__usize__usize *const __sc5 = other;
        if ((*__sc5).tag == Result_Ok) {
          const __auto_type b = &((*__sc5).payload.Ok._0);
          __sc4 = usize__eq(a, b);
        }
        else if ((*__sc5).tag == Result_Err) {
          __sc4 = false;
        }
        else { __builtin_unreachable(); }
        __sc4;
      });
    }
    else if ((*__sc3).tag == Result_Err) {
      const __auto_type a = &((*__sc3).payload.Err._0);
      return ({
        bool __sc6;
        const Result__usize__usize *const __sc7 = other;
        if ((*__sc7).tag == Result_Ok) {
          __sc6 = false;
        }
        else if ((*__sc7).tag == Result_Err) {
          const __auto_type b = &((*__sc7).payload.Err._0);
          __sc6 = usize__eq(a, b);
        }
        else { __builtin_unreachable(); }
        __sc6;
      });
    }
    else { __builtin_unreachable(); }
  }
}

