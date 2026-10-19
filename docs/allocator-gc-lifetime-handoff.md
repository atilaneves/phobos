# GC lifetime API implementation handoff

Implemented on `allocator-gc-lifetime-api`, based on `a27939075`.
Implementation, independent Astra review, and the separate Sol 6.1 fixer pass
are complete. No push or merge was performed by these workers.

## Implemented behavior

- `GCAllocator` no longer declares individual `deallocate` or moving
  `reallocate`. Its allocation, nonmoving expansion, and resolution APIs remain.
- `GCHeapMallocator` implements manual GC freeing and moving reallocation
  directly. Its forwarding implementation is stateless, allowing composed
  allocators to use its existing shared global instance.
- Constructor and array construction failure cleanup individually releases
  storage only if the static allocator provides `deallocate`. Already
  constructed array elements are destroyed regardless of that capability.
- `dispose`, multidimensional disposal, and typed disposal require individual
  deallocation. `ScopedAllocator` explicitly requires a parent with this
  capability because its documented purpose requires scope-exit release.
- `StatsCollector` forwards the parent's optional capability instead of
  synthesizing a method that always fails and subtracts storage statistics.
- Affix allocation failure, allocator-list bookkeeping cleanup, adaptive free
  list trimming, contiguous free list fallback, and dynamic adapter lifetime
  cleanup respect the parent's optional deallocation capability. Free lists
  still provide their own individual reuse capability.
- The fixed dynamic interfaces retain `deallocate` and return `false` for an
  underlying static allocator without that method.
- Generic `common.reallocate` retains its existing allocation-and-copy fallback;
  old storage remains subject to the allocator's lifetime policy. No claim of
  automatic collection or permanent leaking follows from the absent method.

Required exception-cleanup coverage exposed directly related defects in
`makeArray`: the forward path destroyed a pointer rather than its element and
counted an element before construction succeeded; the input path could destroy
an unconstructed extra element. Both paths now count successful constructions
before advancing the input range. These fixes are covered by destructor-count
checks against throwing copies.

## Validation

Run from this worktree's root. Tested on Linux x86_64 with installed DMD
2.113.0 and LDC 1.43.0 (DMD frontend 2.113.0). The repository has no DUB manifest,
so the inherited `dub build` instruction is replaced with direct compiler
commands targeting the real Phobos source files.

```sh
dmd -i -unittest -version=StdUnittest -preview=dip1000 -main \
  -of=/tmp/allocator-all-test \
  std/experimental/allocator/*.d \
  std/experimental/allocator/building_blocks/*.d
/tmp/allocator-all-test

ldc2 -i -unittest -d-version=StdUnittest -preview=dip1000 -main \
  -of=/tmp/allocator-all-test-ldc \
  std/experimental/allocator/*.d \
  std/experimental/allocator/building_blocks/*.d
/tmp/allocator-all-test-ldc

git diff --check
```

Both builds and runs pass. Runtime reports `23 modules passed unittests`:
all 24 source files are supplied, but `building_blocks/package.d` only imports
other modules and has no unittest block. The normal DMD build without DIP1000
also passed before the final coverage additions.

Coverage includes an allocator backed by caller-owned storage with no
`deallocate`, successful construction, constructor failure, copy failure in
all array construction paths, exact destructor counts, disposal rejection,
typed disposal rejection, shrinking to empty, generic copying reallocation
that preserves the old allocation, wrapper capability propagation, short
`AffixAllocator.allocateAll`, adaptive and contiguous free list reuse,
stateful and stateless dynamic adapters, shared adapter cleanup, and explicit
GCHeapMallocator reallocation/data preservation/freeing. Existing allocation
coverage using GCAllocator remains; tests requiring manual release use
GCHeapMallocator.

## Independent review and fixer completion

Astra reviewed implementation HEAD `23df32829fddb205b8f18d2d0313688bb54b4087`
against baseline `a27939075` and found no must-fix defects. The historical
[review report](allocator-gc-api-review.md) retains its original findings and
verification limits.

The separate Sol 6.1 fixer pass accepted Astra's optional regression-test
suggestion. A permanent `makeArray` test now uses a range whose `popFront`
throws after the first element is constructed. Both the sized forward path
and the input-only path must destroy exactly one element and call the counting
manual allocator's `deallocate` exactly once. Existing throwing-copy coverage
checks a different failure point. No further production changes were needed.

The fixer rebuilt and ran the full combined allocator suite from this worktree
with both compilers using these exact commands:

```sh
dmd -i -unittest -version=StdUnittest -preview=dip1000 -main \
  -of=/tmp/allocator-fixer-test \
  std/experimental/allocator/*.d \
  std/experimental/allocator/building_blocks/*.d
/tmp/allocator-fixer-test

ldc2 -i -unittest -d-version=StdUnittest -preview=dip1000 -main \
  -of=/tmp/allocator-fixer-test-ldc \
  std/experimental/allocator/*.d \
  std/experimental/allocator/building_blocks/*.d
/tmp/allocator-fixer-test-ldc

git diff --check
```

Both runs reported `23 modules passed unittests`; whitespace checks passed.
These commands explicitly compile this branch's sources, including package.d,
rather than relying on an installed Phobos allocator module.

## Boundaries and remaining gates

- `GCAllocator.expand` remains unchanged. The static safety audit identifies
  missing allocation-base/extent proof and unchecked growth arithmetic. Its
  forwarding GCHeapMallocator method shares that concern. Mutable output from
  `resolveInternalPointer` and existing adapter trust boundaries also remain
  separate audit work; this branch does not claim to resolve them.
- The preserved `allocator-safety-audit.md` is a static investigation copied
  unchanged from the main checkout, not a completed proof/test report. Line
  numbers refer to its original snapshot.
- Region copying/reset changes remain on `fix-region-copy-reset-safety` at
  `445c4640397e243817b5130106331f57f7b89c6e`, also pushed at that SHA. No Region
  implementation changes are included here. Both efforts may proceed in
  parallel.
- Before any breaking merge, verify the stdx-allocator v4.0.0 tag, DUB release,
  and announcement. Compatibility snapshot PR #39 is merged; release request
  https://github.com/dlang-community/stdx-allocator/issues/42 is pending.
- Full platform/compiler CI and namespace promotion are deferred.
