# Sort, selection and heaps: Super-C against libc++

`run.sh` builds `sort.cpp` (libc++ through `$CXX`, default `clang++ -O2 -std=c++20`) and `sort.spc` (the
`release` profile), runs both and prints one row per lane: the mean of the faster half of the runs in ns
per element, each run on a fresh copy of its input, and the ratio Super-C / libc++. A lane whose result
checksums differ is FAILED: the two sides did not do the same work (selection compares only the selected
element, which is all `nth_element` promises).

| Lane | Super-C | libc++ |
| --- | --- | --- |
| `sort` | `Vector::sort` (pattern-defeating quicksort) | `std::sort` |
| `sort_by` | `sort_by` with a comparator closure | `std::sort` with a lambda |
| `stable` | `sort_stable` (a radix sort for integers in their natural order) | `std::stable_sort` (a radix sort for integers with `std::less`) |
| `stable_by` | `sort_stable_by` with a comparator | `std::stable_sort` with a lambda |
| `select` | `select_nth_unstable(n / 2)` | `std::nth_element` at the middle |
| `heap` | `heapify` then `sort_heap` | `std::make_heap` then `std::sort_heap` |

Inputs: uniform random `u64`, ascending, descending, 16 distinct values, and a sawtooth of period 1000,
at 1000, 100000 and 1000000 elements. Run it on an idle machine: other builds move the 1000-element
lanes by more than the differences between the sides.

```sh
bench/compare/sort/run.sh
SUPERC=path/to/super-c CXX=g++ bench/compare/sort/run.sh
```

`sort_stable_in_place` has no libc++ lane: libc++ falls back to its buffer-free merge only when its
temporary buffer cannot be allocated.
