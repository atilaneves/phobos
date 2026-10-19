# Static review: allocator trusted boundaries

Scope: `/home/atila/coding/d/dlang/phobos/std/experimental/allocator`, all 24 modules. Read the applicable `/home/atila/coding/d/AGENTS.md`, `allocators.md`, protocol documentation, trusted declarations and their surrounding implementations/callers. This checkout reports branch `master`; the requested `fix-region-copy-reset-safety` changes are not in this working tree. Region copying and bulk-reset problems are treated as known work, not new findings. No production files were changed, no compiler tests or memory-invalid programs were run.

## Principal conclusions

The annotations are not ready for blanket stabilization. Several public trusted operations construct slices using facts about allocation provenance, qualifiers, or arithmetic that their types and runtime checks do not establish. Explicit deallocation being system is appropriate, but does not make all allocation/expansion/resolution operations automatically safe.

A prose precondition that a buffer came from the allocator is a valid allocator-protocol requirement. It is not a sufficient memory-safety argument for an operation callable from safe code when ordinary safe slices can violate that precondition. Findings below distinguish ordinary protocol misuse from the trusted boundary accepting it. No finding asserts that a runtime exploit was executed.

## Findings established by source inspection

### High: expansion trusts allocation provenance supplied by callers

* `building_blocks/bitmapped_block.d:1127` (single-block `expand`): only checks null and `delta + b.length <= blockSize`; reconstructs `b.ptr[0 .. newLength]` without confirming the slice belongs to this heap or has the corresponding backing extent. A safe caller can provide an ordinary unrelated small slice. This is a concrete missing validation at a public trusted boundary, although the input violates the documented allocator protocol. Overflow in the addition is also unchecked.
* `building_blocks/bitmapped_block.d:644`, `:655`, `:663` (multiblock `expand`/`expandImpl`): checking pointer difference modulo block size establishes alignment, not membership. The equal-rounded-block-count fast path reconstructs the slice without consulting control bits or checking containment. Other paths index bookkeeping using the supplied address. Shared locking protects metadata access, but does not establish input provenance.
* `building_blocks/bucketizer.d:111` and `:119`: `expand` assumes that a length identifies an allocated bucket. Its trusted reslice accepts arbitrary memory of an eligible length; the range assertion is only a length constraint, and disappears with disabled assertions.
* `building_blocks/quantizer.d:108`, `:121`, `:128`, `:133`: `expand` infers physical capacity from the rounding function and caller-supplied length, then trusts reslices. No membership proof is performed. The initial fast path does not even call the parent. This can infer safe-callable expansion even with a parent that has no safe expansion primitive.
* `building_blocks/region.d:1029` (SbrkRegion `expand`): the `delta <= slack` path at `:1040` expands any nonnull supplied slice without proving it belongs to the sbrk allocation. `_brkInitial`/`_brkCurrent` assertions only establish that the allocator has previously allocated something.
* `gc_allocator.d:38` and forwarding `:230`: no check that `b.ptr` is an allocation base or that the supplied length/offset fits the allocation. `GC.sizeOf(b.ptr)` is treated as capacity measured from `b.ptr`, and only asserted nonzero. The exact behavior for interior pointers depends on druntime's implementation, so the interior-pointer overrun case needs a regression test; the missing input proof itself is visible statically. `b.length + delta` is unchecked.

Action: narrow these operations to system unless full arbitrary-safe-input validation can be established. A coarse range-based `owns` alone is not enough for shortened/interior slices or allocations that share one backing slab. Where preserving safe expansion is intended, specify and validate the exact allocation start and capacity and use checked arithmetic. Test both unrelated slices and sub-slices of legitimate allocations; do not just test matching allocator happy paths.

### High: GC internal-pointer resolution removes const/immutable and exposes typed storage as mutable bytes

`gc_allocator.d:78` (`GCAllocator.resolveInternalPointer`) casts `const void*` to mutable and returns `r[0 .. GC.sizeOf(r)]` as `void[]`. `GCHeapMallocator.resolveInternalPointer` at `:242` inherits it. An input can point into GC-managed immutable or const data, supplied through the normal implicit qualifier conversions; the GC lookup proves GC membership, not permission to mutate it. Even independently of qualifiers, resolving a pointer into a GC allocation containing typed references yields writable byte access to the complete object representation. The runtime range check does not prove that exposing such access is sound.

This is distinct from deallocation and cannot be cured by removing GCAllocator.deallocate/reallocate. The generic protocol at `building_blocks/package.d:107` documents a `void*` input, whereas actual declarations accept `const void*`; this discrepancy deserves correction whichever policy is chosen. Given the existing mutable-output protocol, making resolution system is the straightforward boundary correction. A qualifier-preserving result alone also needs careful consideration of typed-object representation.

The same general concern applies to safe-callable internal-pointer resolvers in `building_blocks/bitmapped_block.d:2330` and private `package.d:3706` when exported through adapters/compositions. Unlike the GC resolver, those rely on allocator metadata and their exact safe construction paths need compile checks before claiming the same end-to-end counterexample.

### High in release builds: shared Region allocation does not reject size-rounding overflow

`building_blocks/region.d:1541` (`SharedBorrowedRegion.allocate`) and `:1587` (`alignedAllocate`) compute `rounded = goodAllocSize(n)`, then check pointer wraparound using `rounded`, but return a slice of original length `n`. With alignment greater than one, an extreme input can round to zero. The common helper `common.d:194` asserts `result >= n`, which aborts in assertion-enabled builds; the protection is absent in release builds. A zero increment can pass CAS while a huge original-length slice is returned. Nonshared allocation at `region.d:428` explicitly rejects `rounded < n`, demonstrating the missing counterpart. SharedRegion forwards into this implementation at `:1256` and `:1293`.

This uses an integer allocation request, not a foreign pointer or protocol-violating buffer. It is independent of the known Region copy/reset defects. Add an unconditional overflow guard before cursor arithmetic to both shared paths and verify debug and release boundary behavior with valid allocator setup.

### Medium: internal-pointer bitmap allocateAll has an extent mismatch

`building_blocks/bitmapped_block.d:2278` (`BitmappedBlockWithInternalPointers.allocateAll`) carves one 8-byte object-start bitmap, initializes all 64 bits to zero, and marks one start bit. `resolveInternalPointer` at `:2344` takes `j = find1(i + 1)` and returns a slice ending at `blockSize * j` with no clamp to payload or the allocateAll result. `BitVector.find1` at `:2619` returns its bit length when no next start exists. Thus the resolver treats the allocation as extending to bitmap capacity (64 blocks) regardless of its actual byte extent. For a backing heap with fewer than 64 blocks, the computed upper bound can exceed backing storage; for larger heaps it can underreport and fail lookups beyond block 63. Exact public safe-callability of allocateAll depends on inferred attributes and must be checked before labeling this a demonstrated all-safe defect. The source-level mismatch needs correction regardless.

A separate empty-state issue at `:2332`: the out-of-range guard only executes if `_heap._payload` is nonempty, after which `&_heap._payload[0]` is used unconditionally. A default/empty heap can therefore cause a bounds failure instead of returning no. This is a correctness issue, not by itself proof of memory corruption with bounds checks enabled.

## Additional audit questions requiring compile tests or stronger evidence

* `package.d:1206`, `:1690`, `:1849`, `:1889`, `:1901`, `:1919`: exceptional cleanup and moving reallocation are trusted based on purity of constructors/postblits/destructors. The comments assume purity proves no references escaped. Pure functions may mutate objects reachable through mutable parameters; inspect constructor arguments and element references before treating this as a complete escape argument. Do not change the API on this suspicion alone. Optional deallocation fixes already scheduled in allocators.md should address unconditional capability calls separately.
* `package.d:3048`, `:3277`: public `CAllocatorImpl.decRef` and shared counterpart trust manual reference count discipline and can release their own storage. Determine whether direct invocation on a live adapter, repeated calls, and exposed `impl`/`rc` state can be made from safe code. Normal RCI ownership may justify internal use; it does not automatically justify a public trusted method. The shared function also forces a deallocate delegate's attributes.
* `package.d:1070` returns an unshared `ref RCISharedAllocator` to process-global state through a trusted cast. The allocator methods may synchronize, but the wrapper's assignment/refcount pointer itself needs a thread-safety argument. Review concurrent setter/getter and lifetime semantics.
* Stateful BitmappedBlock, KRRegion, FreeList, FreeTree, AllocatorList, AlignedBlockList and AscendingPageAllocator may be copied depending on instantiation. Do not extrapolate the known Region proof automatically: inspect postblits/destructors and demonstrate the relevant alias/reuse condition for each before proposing breaking changes.
* AffixAllocator.resolveInternalPointer at `:219` reconstructs prefix/suffix extents assuming the parent resolves exactly the allocator's own affixed allocation. GCAllocator resolves any GC allocation, including unrelated ones. Verify composition with unrelated pointers, undersized blocks, suffix alignment and shortened/interior buffers. Its owns at `:212` intentionally constructs a hypothetical parent slice; it must not let metadata-reading parent owns implementations trust that slice unchecked.

## Per-module boundary inventory and coverage

Counts below are lexical occurrences of `@trusted`, including private helpers, unittests, declarations emitted only for documentation, and forwarding wrappers. They are an inventory, not a count of distinct exposed APIs. Attribute inference means modules with zero occurrences can still inherit unsafe behavior from a parent or a called trusted helper.

| Module | Occurrences | Static review result |
|---|---:|---|
| package.d | 30 | Typed construction/array reslices and failure cleanup; process allocator cast; adapter decRef; private internal-pointer tree. Questions above. Test-only casts excluded from findings. |
| common.d | 0 | Rounding assertions and default reallocate/alignedReallocate. No direct trusted boundary; shared Region overflow depends on helper behavior. |
| typed.d | 0 | Typed dispatch/delegation; no newly identified direct trusted boundary. |
| showcase.d | 0 | Compositions/examples; inherits constituent contracts. |
| gc_allocator.d | 12 | Both GC policies; allocation extent straightforward, expansion and resolution need correction above. collect relies on GC lifetime guarantees. |
| mallocator.d | 5 | malloc/calloc/aligned allocation checked for failure; deallocation/moving reallocation system. Retain allocation trust subject to platform alignment/OS contracts. |
| mmap_allocator.d | 9 | OS allocation and errno/GetLastError wrappers; returned extent equals successful requested mapping; OS deallocation system. No new direct defect identified. |
| building_blocks/package.d | 0 | Protocol contract; expand requires same allocator, internal pointer signature discrepancy noted above. |
| building_blocks/affix_allocator.d | 6 | Lazy parent/function-attribute casts, reconstructed ownership/resolution/expansion. Composition questions above; raw prefix/suffix access remains unsafe by pointer operations. |
| building_blocks/allocator_list.d | 1 | Private assumeUnshared; shared wrapper locks around forwarding. Lock protects cast only if all access uses same lock; no new confirmed issue. |
| building_blocks/aligned_block_list.d | 0 | Pointer/bookkeeping paths and parent dispatch; no direct trusted declaration. |
| building_blocks/ascending_page_allocator.d | 0 | Page/cursor allocation and expansion paths; pointer manipulation remains inferred system; no direct trusted boundary. |
| building_blocks/bitmapped_block.d | 29 | Shared/nonshared allocation, bitmap extent helpers, owns, expand, internal-pointer resolver. Expansion finding and resolver extent issue above. |
| building_blocks/bucketizer.d | 2 | Aligned allocation reslice depends on parent's allocation postcondition; expansion provenance issue above. |
| building_blocks/fallback_allocator.d | 2 | Zero-fill casts on newly obtained allocation; sound if parent fulfills fresh valid extent contract. |
| building_blocks/free_list.d | 1 | Range-only owns pointer comparison; no direct memory dereference introduced by trusted closure. Copy/reuse requires separate evidence. |
| building_blocks/free_tree.d | 0 | Intrusive tree paths; no direct trusted boundary. Inherits parent expansion via aliasing. |
| building_blocks/kernighan_ritchie.d | 7 | Private Node payload/coalescing/splitting and public owns. Private casts depend on free-list invariants; public owns compares addresses only. Allocation/copy proof remains separate. |
| building_blocks/null_allocator.d | 0 | No storage produced/reused, constant no-op behavior. No new finding. |
| building_blocks/quantizer.d | 3 | All three trusted closures are expansion extent reconstruction; provenance finding above. |
| building_blocks/region.d | 31 | Borrowed/owning/shared variants, sbrk path; known copy/reset work excluded. Shared overflow and sbrk provenance finding above. |
| building_blocks/scoped_allocator.d | 1 | Trusted prefix length write after parent expansion; needs parent's expansion to establish that this is an affixed allocation. Destructor and raw intrusive bookkeeping otherwise unsafe; explicitly noncopyable. |
| building_blocks/segregator.d | 2 | Zero-fill closures on new parent blocks; no new direct defect given parent extent contract. |
| building_blocks/stats_collector.d | 0 | Counter/mixin forwarding; no direct trusted declaration, inherits parent trust and attribute inference. |

## Limits and recommended verification

This is a source review, not an exhaustive soundness proof of roughly 23,000 lines of templates and every supported OS/compiler configuration. No external web claims or issue histories were used. Inferred safety and D's exact qualifier/cast rules should be checked with positive/negative compile-only tests before assigning final API changes. Boundary cases should be tested on valid allocator setups and inspect results without dereferencing invalid memory. Debug and release behavior differ where assertions are the only guard. Runtime GC interior-pointer semantics and platform allocation guarantees need matching current druntime source review. Existing tests predominantly exercise valid allocator-owned buffers, so passing them would not resolve the arbitrary-safe-input concerns.
