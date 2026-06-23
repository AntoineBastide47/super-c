// Direct coverage of types/hashmap.h (open-addressing with tombstones). Two instantiations: one
// with an identity hash to drive load-factor growth/rehash, one with a constant hash so every key
// lands in a single probe chain -- the worst case that exercises tombstone reuse and probing.

#include "test_harness.h"

static size_t id_hash(const uint32_t k) {
  return k;
}
static size_t zero_hash(const uint32_t k) {
  (void)k;
  return 0; // force every key into one collision chain
}
static bool u32_eq(const uint32_t a, const uint32_t b) {
  return a == b;
}

HM_DECLARE(uint32_t, int, IMap)
HM_DEFINE(uint32_t, int, IMap, id_hash, u32_eq)
HM_DECLARE(uint32_t, int, CMap)
HM_DEFINE(uint32_t, int, CMap, zero_hash, u32_eq)

static bool is_pow2(const size_t n) {
  return n != 0 && (n & (n - 1)) == 0;
}

static void test_basic(void) {
  IMap m = IMap_init();
  int v = -1;
  CHECK(!IMap_get(&m, 5, &v), "get on empty (cap==0) returns false");

  CHECK(IMap_insert(&m, 1, 10) && IMap_insert(&m, 2, 20), "inserts succeed");
  CHECK(IMap_get(&m, 1, &v) && v == 10, "get key 1");
  CHECK(IMap_get(&m, 2, &v) && v == 20, "get key 2");
  CHECK(!IMap_get(&m, 3, &v), "missing key returns false");

  const size_t len = m.len;
  CHECK(IMap_insert(&m, 1, 99) && m.len == len, "overwrite keeps len");
  CHECK(IMap_get(&m, 1, &v) && v == 99, "overwrite updates value");
  IMap_deinit(&m);
}

static void test_remove(void) {
  IMap m = IMap_init();
  IMap_insert(&m, 7, 70);
  IMap_insert(&m, 8, 80);
  int v = 0;
  CHECK(IMap_remove(&m, 7) && m.len == 1, "remove drops len");
  CHECK(!IMap_get(&m, 7, &v), "removed key is gone");
  CHECK(IMap_get(&m, 8, &v) && v == 80, "sibling survives removal");
  CHECK(!IMap_remove(&m, 7), "removing an absent key returns false");

  IMap empty = IMap_init();
  CHECK(!IMap_remove(&empty, 1), "remove on empty map returns false");
  IMap_deinit(&m);
  IMap_deinit(&empty);
}

static void test_grow_and_rehash(void) {
  IMap m = IMap_init();
  for (uint32_t k = 0; k < 100; k++)
    CHECK(IMap_insert(&m, k, (int)(k * 3)), "insert %u", k);
  CHECK(m.len == 100, "all 100 live, got %zu", m.len);
  CHECK(is_pow2(m.cap), "cap stays a power of two, got %zu", m.cap);
  CHECK(4 * m.used < 3 * m.cap, "load factor held under 0.75 after growth");
  for (uint32_t k = 0; k < 100; k++) {
    int v = -1;
    CHECK(IMap_get(&m, k, &v) && v == (int)(k * 3), "key %u survives rehash", k);
  }
  IMap_deinit(&m);
}

static void test_collision_chain_and_tombstone(void) {
  CMap m = CMap_init(); // all keys hash to slot 0
  CHECK(CMap_insert(&m, 10, 1) && CMap_insert(&m, 20, 2) && CMap_insert(&m, 30, 3), "chain inserts");
  int v = 0;
  CHECK(CMap_get(&m, 30, &v) && v == 3, "deep probe finds the third entry");
  CHECK(m.len == 3 && m.used == 3, "three live, no tombstones yet");

  CHECK(CMap_remove(&m, 20) && m.len == 2 && m.used == 3, "remove leaves a tombstone (used unchanged)");
  CHECK(!CMap_get(&m, 20, &v), "removed key not found");
  CHECK(CMap_get(&m, 30, &v) && v == 3, "probe still passes the tombstone to later entries");

  CHECK(CMap_insert(&m, 40, 4), "insert reuses the tombstone");
  CHECK(m.len == 3 && m.used == 3, "tombstone reused: used not double-counted (len %zu used %zu)", m.len, m.used);
  CHECK(CMap_get(&m, 40, &v) && v == 4, "reused-slot key retrievable");
  CMap_deinit(&m);
}

static void test_deinit(void) {
  IMap m = IMap_init();
  IMap_insert(&m, 1, 1);
  IMap_deinit(&m);
  CHECK(m.keys == NULL && m.vals == NULL && m.state == NULL && m.len == 0 && m.cap == 0, "deinit zeroes the map");
}

int main(void) {
  test_basic();
  test_remove();
  test_grow_and_rehash();
  test_collision_chain_and_tombstone();
  test_deinit();
  if (failures) {
    fprintf(stderr, "%d hashmap test failure%s\n", failures, failures == 1 ? "" : "s");
    return 1;
  }
  puts("hashmap tests passed");
  return 0;
}
