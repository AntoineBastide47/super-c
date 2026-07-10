#include "../__std/slice.h"
#include "../__std/core.h"
#include "../__std/option.h"
#include "../__std/range.h"
#include "../__std/str.h"

_Static_assert(sizeof(Slice__u8) == 16 && _Alignof(Slice__u8) == 8, "super-c layout model mismatch: Slice__u8");
_Static_assert(sizeof(Slice__u32) == 16 && _Alignof(Slice__u32) == 8, "super-c layout model mismatch: Slice__u32");
_Static_assert(sizeof(SliceMut__u32) == 16 && _Alignof(SliceMut__u32) == 8, "super-c layout model mismatch: SliceMut__u32");
_Static_assert(sizeof(Slice__bool) == 16 && _Alignof(Slice__bool) == 8, "super-c layout model mismatch: Slice__bool");
_Static_assert(sizeof(SliceMut__bool) == 16 && _Alignof(SliceMut__bool) == 8, "super-c layout model mismatch: SliceMut__bool");
_Static_assert(sizeof(Slice__str) == 16 && _Alignof(Slice__str) == 8, "super-c layout model mismatch: Slice__str");
_Static_assert(sizeof(SliceMut__str) == 16 && _Alignof(SliceMut__str) == 8, "super-c layout model mismatch: SliceMut__str");
_Static_assert(sizeof(SliceMut__u8) == 16 && _Alignof(SliceMut__u8) == 8, "super-c layout model mismatch: SliceMut__u8");
_Static_assert(sizeof(Slice__u64) == 16 && _Alignof(Slice__u64) == 8, "super-c layout model mismatch: Slice__u64");
_Static_assert(sizeof(SliceMut__u64) == 16 && _Alignof(SliceMut__u64) == 8, "super-c layout model mismatch: SliceMut__u64");
_Static_assert(sizeof(Slice__u16) == 16 && _Alignof(Slice__u16) == 8, "super-c layout model mismatch: Slice__u16");
_Static_assert(sizeof(SliceMut__u16) == 16 && _Alignof(SliceMut__u16) == 8, "super-c layout model mismatch: SliceMut__u16");
_Static_assert(sizeof(Slice__usize) == 16 && _Alignof(Slice__usize) == 8, "super-c layout model mismatch: Slice__usize");
_Static_assert(sizeof(SliceMut__usize) == 16 && _Alignof(SliceMut__usize) == 8, "super-c layout model mismatch: SliceMut__usize");


size_t Slice__u8__len(const Slice__u8 *const self) {
  return self->len;
}

const uint8_t *Slice__u8__as_ptr(const Slice__u8 *const self) {
  return self->ptr;
}

const uint8_t *Slice__u8__index(const Slice__u8 *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__u8 Slice__u8__index_range(const Slice__u8 *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc0;
    if (r.inclusive) {
      __sc0 = (r.end + 1ULL);
    } else {
      __sc0 = r.end;
    }
    __sc0;
  });
  return (Slice__u8){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t Slice__u32__len(const Slice__u32 *const self) {
  return self->len;
}

const uint32_t *Slice__u32__as_ptr(const Slice__u32 *const self) {
  return self->ptr;
}

const uint32_t *Slice__u32__index(const Slice__u32 *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__u32 Slice__u32__index_range(const Slice__u32 *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc1;
    if (r.inclusive) {
      __sc1 = (r.end + 1ULL);
    } else {
      __sc1 = r.end;
    }
    __sc1;
  });
  return (Slice__u32){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__u32__len(const SliceMut__u32 *const self) {
  return self->len;
}

uint32_t *SliceMut__u32__as_mut_ptr(const SliceMut__u32 *const self) {
  return self->ptr;
}

const uint32_t *SliceMut__u32__index(const SliceMut__u32 *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__u32 SliceMut__u32__index_range(const SliceMut__u32 *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc2;
    if (r.inclusive) {
      __sc2 = (r.end + 1ULL);
    } else {
      __sc2 = r.end;
    }
    __sc2;
  });
  return (Slice__u32){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

uint32_t *SliceMut__u32__index_mut(SliceMut__u32 *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__u32 SliceMut__u32__index_range_mut(SliceMut__u32 *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc3;
    if (r.inclusive) {
      __sc3 = (r.end + 1ULL);
    } else {
      __sc3 = r.end;
    }
    __sc3;
  });
  return (SliceMut__u32){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t Slice__bool__len(const Slice__bool *const self) {
  return self->len;
}

const bool *Slice__bool__as_ptr(const Slice__bool *const self) {
  return self->ptr;
}

const bool *Slice__bool__index(const Slice__bool *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__bool Slice__bool__index_range(const Slice__bool *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc4;
    if (r.inclusive) {
      __sc4 = (r.end + 1ULL);
    } else {
      __sc4 = r.end;
    }
    __sc4;
  });
  return (Slice__bool){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__bool__len(const SliceMut__bool *const self) {
  return self->len;
}

bool *SliceMut__bool__as_mut_ptr(const SliceMut__bool *const self) {
  return self->ptr;
}

const bool *SliceMut__bool__index(const SliceMut__bool *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__bool SliceMut__bool__index_range(const SliceMut__bool *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc5;
    if (r.inclusive) {
      __sc5 = (r.end + 1ULL);
    } else {
      __sc5 = r.end;
    }
    __sc5;
  });
  return (Slice__bool){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

bool *SliceMut__bool__index_mut(SliceMut__bool *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__bool SliceMut__bool__index_range_mut(SliceMut__bool *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc6;
    if (r.inclusive) {
      __sc6 = (r.end + 1ULL);
    } else {
      __sc6 = r.end;
    }
    __sc6;
  });
  return (SliceMut__bool){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t Slice__str__len(const Slice__str *const self) {
  return self->len;
}

const str *Slice__str__as_ptr(const Slice__str *const self) {
  return self->ptr;
}

const str *Slice__str__index(const Slice__str *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__str Slice__str__index_range(const Slice__str *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc7;
    if (r.inclusive) {
      __sc7 = (r.end + 1ULL);
    } else {
      __sc7 = r.end;
    }
    __sc7;
  });
  return (Slice__str){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__str__len(const SliceMut__str *const self) {
  return self->len;
}

str *SliceMut__str__as_mut_ptr(const SliceMut__str *const self) {
  return self->ptr;
}

const str *SliceMut__str__index(const SliceMut__str *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__str SliceMut__str__index_range(const SliceMut__str *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc8;
    if (r.inclusive) {
      __sc8 = (r.end + 1ULL);
    } else {
      __sc8 = r.end;
    }
    __sc8;
  });
  return (Slice__str){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

str *SliceMut__str__index_mut(SliceMut__str *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__str SliceMut__str__index_range_mut(SliceMut__str *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc9;
    if (r.inclusive) {
      __sc9 = (r.end + 1ULL);
    } else {
      __sc9 = r.end;
    }
    __sc9;
  });
  return (SliceMut__str){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__u8__len(const SliceMut__u8 *const self) {
  return self->len;
}

uint8_t *SliceMut__u8__as_mut_ptr(const SliceMut__u8 *const self) {
  return self->ptr;
}

const uint8_t *SliceMut__u8__index(const SliceMut__u8 *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__u8 SliceMut__u8__index_range(const SliceMut__u8 *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc10;
    if (r.inclusive) {
      __sc10 = (r.end + 1ULL);
    } else {
      __sc10 = r.end;
    }
    __sc10;
  });
  return (Slice__u8){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

uint8_t *SliceMut__u8__index_mut(SliceMut__u8 *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__u8 SliceMut__u8__index_range_mut(SliceMut__u8 *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc11;
    if (r.inclusive) {
      __sc11 = (r.end + 1ULL);
    } else {
      __sc11 = r.end;
    }
    __sc11;
  });
  return (SliceMut__u8){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t Slice__u64__len(const Slice__u64 *const self) {
  return self->len;
}

const uint64_t *Slice__u64__as_ptr(const Slice__u64 *const self) {
  return self->ptr;
}

const uint64_t *Slice__u64__index(const Slice__u64 *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__u64 Slice__u64__index_range(const Slice__u64 *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc12;
    if (r.inclusive) {
      __sc12 = (r.end + 1ULL);
    } else {
      __sc12 = r.end;
    }
    __sc12;
  });
  return (Slice__u64){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__u64__len(const SliceMut__u64 *const self) {
  return self->len;
}

uint64_t *SliceMut__u64__as_mut_ptr(const SliceMut__u64 *const self) {
  return self->ptr;
}

const uint64_t *SliceMut__u64__index(const SliceMut__u64 *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__u64 SliceMut__u64__index_range(const SliceMut__u64 *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc13;
    if (r.inclusive) {
      __sc13 = (r.end + 1ULL);
    } else {
      __sc13 = r.end;
    }
    __sc13;
  });
  return (Slice__u64){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

uint64_t *SliceMut__u64__index_mut(SliceMut__u64 *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__u64 SliceMut__u64__index_range_mut(SliceMut__u64 *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc14;
    if (r.inclusive) {
      __sc14 = (r.end + 1ULL);
    } else {
      __sc14 = r.end;
    }
    __sc14;
  });
  return (SliceMut__u64){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t Slice__u16__len(const Slice__u16 *const self) {
  return self->len;
}

const uint16_t *Slice__u16__as_ptr(const Slice__u16 *const self) {
  return self->ptr;
}

const uint16_t *Slice__u16__index(const Slice__u16 *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__u16 Slice__u16__index_range(const Slice__u16 *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc15;
    if (r.inclusive) {
      __sc15 = (r.end + 1ULL);
    } else {
      __sc15 = r.end;
    }
    __sc15;
  });
  return (Slice__u16){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__u16__len(const SliceMut__u16 *const self) {
  return self->len;
}

uint16_t *SliceMut__u16__as_mut_ptr(const SliceMut__u16 *const self) {
  return self->ptr;
}

const uint16_t *SliceMut__u16__index(const SliceMut__u16 *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__u16 SliceMut__u16__index_range(const SliceMut__u16 *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc16;
    if (r.inclusive) {
      __sc16 = (r.end + 1ULL);
    } else {
      __sc16 = r.end;
    }
    __sc16;
  });
  return (Slice__u16){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

uint16_t *SliceMut__u16__index_mut(SliceMut__u16 *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__u16 SliceMut__u16__index_range_mut(SliceMut__u16 *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc17;
    if (r.inclusive) {
      __sc17 = (r.end + 1ULL);
    } else {
      __sc17 = r.end;
    }
    __sc17;
  });
  return (SliceMut__u16){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t Slice__usize__len(const Slice__usize *const self) {
  return self->len;
}

const size_t *Slice__usize__as_ptr(const Slice__usize *const self) {
  return self->ptr;
}

const size_t *Slice__usize__index(const Slice__usize *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__usize Slice__usize__index_range(const Slice__usize *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc18;
    if (r.inclusive) {
      __sc18 = (r.end + 1ULL);
    } else {
      __sc18 = r.end;
    }
    __sc18;
  });
  return (Slice__usize){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t SliceMut__usize__len(const SliceMut__usize *const self) {
  return self->len;
}

size_t *SliceMut__usize__as_mut_ptr(const SliceMut__usize *const self) {
  return self->ptr;
}

const size_t *SliceMut__usize__index(const SliceMut__usize *const self, size_t const i) {
  return (&self->ptr[i]);
}

Slice__usize SliceMut__usize__index_range(const SliceMut__usize *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc19;
    if (r.inclusive) {
      __sc19 = (r.end + 1ULL);
    } else {
      __sc19 = r.end;
    }
    __sc19;
  });
  return (Slice__usize){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

size_t *SliceMut__usize__index_mut(SliceMut__usize *const self, size_t const i) {
  return (&self->ptr[i]);
}

SliceMut__usize SliceMut__usize__index_range_mut(SliceMut__usize *const self, Range__usize const r) {
  const size_t hi = ({
    size_t __sc20;
    if (r.inclusive) {
      __sc20 = (r.end + 1ULL);
    } else {
      __sc20 = r.end;
    }
    __sc20;
  });
  return (SliceMut__usize){ .ptr = (self->ptr + r.start), .len = (hi - r.start) };
}

