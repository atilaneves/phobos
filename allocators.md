# Promoting `std.experimental.allocator` to `std.allocator`

Status: design approved; implementation in progress. `GCHeapMallocator` merged
in [PR #11084](https://github.com/dlang/phobos/pull/11084)
(commit `3d56c7412`, August 19, 2026). Region safety fixes and GC lifetime API changes are proceeding on separate
branches. Breaking merges remain gated on the compatibility release below.

## Goal

Promote the complete existing allocator package into current Phobos as a
stable, low-level, composable allocation toolkit. The promotion stabilizes the
existing `void[]` protocol after resolving demonstrated soundness and contract
defects; it does not redesign the package as a universal ownership abstraction.

The package's composable building blocks are part of the product. All 24
modules move to the stable namespace, not merely the concrete GC, malloc, and
mmap allocators.

## Design decisions

### Keep the existing protocol

Arbitrary non-GC deallocation cannot generally be made soundly `@safe` while
the allocator receives a freely aliasable `void[]`. Such operations remain
`@system`. Full allocator-aware `@safe` plus `@nogc`, ownership-carrying
`Block` values, and language ownership features are outside this promotion.

This choice is recorded in
[ADR 0001](docs/adr/0001-stabilize-existing-allocator-protocol.md).

### Individual deallocation is optional

In the static protocol, absence of `deallocate` means only that individual
deallocation is unavailable. It promises neither automatic collection nor a
leak: storage may instead be reclaimed automatically, in bulk, or by a parent
owner. A component that requires immediate individual reclamation must require
that capability.

The fixed dynamic `IAllocator` interface remains unchanged. Its documented
adapter maps a missing static `deallocate` to a dynamic call returning `false`.
`dispose` continues to mean both destruction and individual deallocation and
therefore does not accept an allocator without `deallocate`.

This choice is recorded in
[ADR 0002](docs/adr/0002-treat-individual-deallocation-as-optional.md).

### Separate the two GC lifetime policies

`GCAllocator` represents automatically reclaimed GC storage. Remove its
`deallocate` and moving `reallocate` methods. Retain non-moving `expand` only
if its `@trusted` implementation passes the safety audit.

`GCHeapMallocator` was added first in PR #11084. It preserves the explicitly managed,
GC-scanned malloc heap use case, including manual deallocation and
reallocation. The name and implementation follow Paul Backus's prior
PR to preserve continuity with the earlier review.

This choice is recorded in
[ADR 0003](docs/adr/0003-separate-gc-lifetime-policies.md).

### Allocation state is noncopyable

Allocator values that own backing storage, advance a cursor, manage an
intrusive structure, or contain synchronization state must not be copyable.
Copying such values can duplicate ownership, produce overlapping mutable
allocations, corrupt shared structures, or copy a lock without preserving its
protection.

Every breaking change needs evidence. The current tree already contains
explicit Region TODOs and concrete all-`@safe` reproductions for both copying a
`BorrowedRegion` and resetting it with `deallocateAll`; both can produce
overlapping live mutable arrays. Apply the same proof standard to other
stateful allocators before disabling their copy constructors. Storage-reusing
operations remain `@system` whenever live aliases cannot be ruled out.

This choice is recorded in
[ADR 0005](docs/adr/0005-make-allocation-state-noncopyable.md).

### Do not redesign working APIs for cleanliness alone

Existing uses of `NullAllocator` as a template policy remain. In particular,
this promotion does not split KRRegion or BitmappedBlock into new borrowed
types and does not replace AllocatorList's self-bookkeeping convention. Their
special meanings should be documented more clearly, but unconventional API
shape alone does not justify ecosystem breakage.

Further breaking safety fixes require a minimal reproducer, a violated
documented contract, or an equivalent regression test. Audit suspicion is a
reason to investigate, not by itself a reason to change the API.

## Required changes before promotion

1. **Completed:** Add `GCHeapMallocator` as the migration target for explicitly
   managed, GC-scanned storage (PR #11084).
2. Fix proven allocation-state copying and storage-reuse soundness defects,
   with regression tests.
3. Remove `GCAllocator.deallocate` and `GCAllocator.reallocate`.
4. Propagate optional deallocation correctly through generic helpers and
   composed allocators. A wrapper must not blindly call a parent capability
   that is absent.
5. Make exceptional cleanup in `make` and related helpers conditional on the
   availability of individual deallocation. Keep `dispose` constrained to
   allocators that provide it.
6. Audit every public `@trusted` boundary. Retain `@trusted` only where its
   preconditions are enforced and its safety argument is documented; otherwise
   narrow it or use `@system`.

Ordinary correctness bugs that do not require a breaking contract change are
not promotion blockers and may be fixed normally afterward.

## Pull request sequence

Use small, dependency-ordered pull requests against the experimental package:

1. **Merged:** Add `GCHeapMallocator` without changing `GCAllocator`
   ([PR #11084](https://github.com/dlang/phobos/pull/11084)).
2. **In progress, separate branch:** Region copy/reuse safety fixes are on
   `fix-region-copy-reset-safety` at
   `445c4640397e243817b5130106331f57f7b89c6e` (also pushed to origin).
   Assess other stateful allocators separately using the same evidence standard.
3. **Implemented and independently reviewed here:** Remove the two
   `GCAllocator` methods and propagate optional individual deallocation.
   Astra found no must-fix defects; the separate Sol 6.1 fixer pass added
   the suggested exception regression coverage and passed both compiler suites.
   See [implementation handoff](docs/allocator-gc-lifetime-handoff.md) and
   [independent review](docs/allocator-gc-api-review.md).
   Steps 2 and 3 may proceed in parallel.
4. Submit any additional safety-audit fixes separately, each with concrete
   evidence.
5. Promote the package in a final, predominantly mechanical PR.

Before merging breaking changes, verify the `stdx-allocator` v4.0.0 tag, its
DUB availability, and the release announcement. The compatibility snapshot
[PR #39](https://github.com/dlang-community/stdx-allocator/pull/39) is merged;
the [release request #42](https://github.com/dlang-community/stdx-allocator/issues/42)
is pending. These gates have not been verified by this implementation.

The [safety audit](docs/allocator-safety-audit.md) is a static investigation,
not proof that its proposed fixes are correct or tested.

The design decision is already approved by the project decision-maker. PR
review evaluates implementation correctness and does not serve as a new design
approval gate.

## Namespace promotion

Create canonical implementations under `std/allocator/`, preserving all 24
module boundaries and the existing public-import topology. Rewrite module
declarations, imports, Ddoc references, and source links to the stable
namespace.

Retain all corresponding `std/experimental/allocator/` modules as
warning-free public-import shims. Do not add `deprecated` attributes during
the promotion: as with the logger promotion, immediate warnings would break
projects that compile with deprecations as errors. Any later deprecation is a
separate decision after ecosystem migration.

This compatibility choice is recorded in
[ADR 0004](docs/adr/0004-forward-experimental-allocator-imports-without-warnings.md).

The promotion PR also:

- updates the explicit Makefile package and module lists while retaining the
  experimental shim lists;
- changes the internal `std.checkedint` dependency to the stable namespace;
- adds `std.allocator` to `std/package.d` so it participates in `import std`;
- updates `.dscanner.ini`, `CODEOWNERS`, Ddoc links, and source paths;
- adds a changelog entry;
- gives `index.dd` curated entries for the package, concrete allocators,
  `typed`, `showcase`, and the `building_blocks` umbrella rather than 24 flat
  entries.

The removed `phobos:allocator`/`stdx.allocator` DUB subpackage is not revived.
Its remaining dead smoke-test artifact can be removed separately.

## Verification gate

Before promotion, require:

- targeted unittests for every canonical allocator module;
- full debug and release unittests;
- public documentation/example tests, style checks, and HTML generation;
- library, JSON, installation, and package-list build checks;
- smoke tests for every stable import, every old forwarding import with
  deprecations treated as errors, mixed old/new imports, and `import std`;
- the normal Linux, Alpine, macOS, Windows, and FreeBSD CI matrix.

Safety changes additionally require:

- positive compile tests for APIs intentionally callable from `@safe`;
- negative compile tests for deallocation, moving reallocation, disposal, and
  storage reuse that must remain `@system`;
- noncopyability assertions for allocator state proven unsafe to copy;
- behavioral alias/reuse regressions, because compiler attribute tests alone
  do not prove semantic soundness;
- adversarial tests for retained `@trusted` operations such as expansion and
  internal-pointer resolution.

## Explicit non-goals

- A new ownership-carrying `Block` protocol.
- Universal allocator-aware `@safe` and `@nogc` containers.
- Phobos 3 allocator design.
- Redesigning `NullAllocator` policy conventions without a demonstrated bug.
- Fixing every open allocator issue before promotion.
- Immediately deprecating the experimental namespace.
- Recreating the former `stdx.allocator` package.

## Prior work

- [PR #8554](https://github.com/dlang/phobos/pull/8554), closed unmerged:
  remove `GCAllocator.deallocate` and `reallocate` and adapt generic clients.
- [PR #8555](https://github.com/dlang/phobos/pull/8555), closed unmerged: add
  `GCHeapMallocator`.
- [PR #8574](https://github.com/dlang/phobos/pull/8574), merged: replace
  Region's `NullAllocator` sentinel with BorrowedRegion variants. This is useful
  precedent but is not a mandate to redesign all remaining sentinel uses.
- [Paul Backus's allocator design note](https://gist.github.com/pbackus/29c520bc4e1f4aa075c9171db791d234):
  a fuller ownership-carrying redesign, intentionally outside this promotion.
- Logger promotion commit `e113440df`: precedent for canonical stable modules
  plus warning-free experimental forwarding shims.

The qualified-array `dispose` defect formerly tracked as #9824 is fixed at the
current checkout (`55bfa46fc`) and is not an open promotion blocker.
