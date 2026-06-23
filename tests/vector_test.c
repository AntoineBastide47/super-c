// Direct coverage of types/vector.{h,c}: the generic VEC_DECLARE/VEC_DEFINE machinery plus the
// three prebuilt instantiations (U32_Vec, String_Vec and the otherwise-unused-in-src Bool_Vec).

#include "test_harness.h"

VEC_DECLARE(int, Int_Vec)
VEC_DEFINE(int, Int_Vec)

static bool lt(const int item, void *ctx) {
  return item < *(const int *)ctx;
}

static void test_init_and_reserve(void) {
  Int_Vec v = Int_Vec_init();
  CHECK(v.data == NULL && v.len == 0 && v.cap == 0, "init is zeroed");

  CHECK(Int_Vec_reserve(&v, 1) && v.cap == 8, "first reserve allocates 8, got cap %zu", v.cap);
  CHECK(Int_Vec_reserve(&v, 9) && v.cap == 16, "growth doubles to 16, got cap %zu", v.cap);
  const size_t before = v.cap;
  CHECK(Int_Vec_reserve(&v, 5) && v.cap == before, "reserve <= cap is a no-op");
  CHECK(Int_Vec_reserve(&v, 100) && v.cap == 128, "doubles past the requested size, got cap %zu", v.cap);
  CHECK(v.len == 0, "reserve never changes len");
  VEC_DEINIT(v);
}

static void test_push_pop(void) {
  Int_Vec v = Int_Vec_init();
  for (int i = 0; i < 20; i++)
    CHECK(Int_Vec_push(&v, i * i), "push %d", i);
  CHECK(v.len == 20, "len after 20 pushes, got %zu", v.len);
  CHECK(v.data[7] == 49, "stored value preserved");

  int out = -1;
  CHECK(Int_Vec_pop(&v, &out) && out == 361 && v.len == 19, "pop returns the last element (LIFO)");
  Int_Vec empty = Int_Vec_init();
  CHECK(!Int_Vec_pop(&empty, &out), "pop on empty returns false");
  VEC_DEINIT(v);
  VEC_DEINIT(empty);
}

static void test_partition_point(void) {
  Int_Vec v = Int_Vec_init();
  for (int i = 0; i < 10; i++)
    Int_Vec_push(&v, i); // sorted 0..9

  int t = 5;
  CHECK(Int_Vec_partition_point(&v, lt, &t) == 5, "midpoint: 5 elements satisfy `< 5`");
  t = 100;
  CHECK(Int_Vec_partition_point(&v, lt, &t) == v.len, "all-true returns len");
  t = 0;
  CHECK(Int_Vec_partition_point(&v, lt, &t) == 0, "all-false returns 0");

  Int_Vec empty = Int_Vec_init();
  CHECK(Int_Vec_partition_point(&empty, lt, &t) == 0, "empty returns 0");
  VEC_DEINIT(v);
  VEC_DEINIT(empty);
}

static void test_prebuilt(void) {
  U32_Vec u = U32_Vec_init();
  U32_Vec_push(&u, 0xDEADBEEFu);
  uint32_t uo = 0;
  CHECK(U32_Vec_pop(&u, &uo) && uo == 0xDEADBEEFu, "U32_Vec round-trip");
  VEC_DEINIT(u);

  String_Vec s = String_Vec_init();
  String_Vec_push(&s, "alpha");
  String_Vec_push(&s, "beta");
  CHECK(s.len == 2 && strcmp(s.data[0], "alpha") == 0, "String_Vec stores pointers");
  VEC_DEINIT(s);

  Bool_Vec b = Bool_Vec_init(); // unused in src/, exercised here
  Bool_Vec_push(&b, true);
  Bool_Vec_push(&b, false);
  bool bo = false;
  CHECK(b.len == 2 && b.data[0] == true, "Bool_Vec stores values");
  CHECK(Bool_Vec_pop(&b, &bo) && bo == false, "Bool_Vec pop");
  VEC_DEINIT(b);
}

static void test_deinit(void) {
  Int_Vec v = Int_Vec_init();
  Int_Vec_push(&v, 1);
  VEC_DEINIT(v);
  CHECK(v.data == NULL && v.len == 0 && v.cap == 0, "VEC_DEINIT nulls and zeroes");

  Int_Vec w = Int_Vec_init();
  Int_Vec_push(&w, 1);
  VEC_DEINIT_REF(&w);
  CHECK(w.data == NULL && w.len == 0 && w.cap == 0, "VEC_DEINIT_REF nulls and zeroes");
}

int main(void) {
  test_init_and_reserve();
  test_push_pop();
  test_partition_point();
  test_prebuilt();
  test_deinit();
  if (failures) {
    fprintf(stderr, "%d vector test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("vector tests passed");
  return 0;
}
