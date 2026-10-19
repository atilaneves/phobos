# GC lifetime API independent review

Reviewer: Astra. Reviewed `a279390756337f4e4cbee4607e6054f05f45fade` through
`23df32829fddb205b8f18d2d0313688bb54b4087` on
`allocator-gc-lifetime-api`, including implementation commit `1fc58a323`.

## Result

No must-fix findings identified in the implementation diff. No production files
were changed by this review. The accepted lifetime-policy design was treated as
the contract, not reopened for approval.

The removal of GCAllocator's two manual operations, GCHeapMallocator's direct
implementations and stateless forwarding, conditional exceptional cleanup,
disposal constraints, dynamic adapter behavior, and changed wrapper paths are
consistent with that contract. The makeArray construction-count changes address
real cleanup defects and are directly related to the requested exception
semantics. Existing region safety work and namespace promotion remain separate.

## Coverage and evidence

Read the applicable workspace instructions, `allocators.md`, accepted ADRs,
and implementation handoff. Inspected the complete allocator implementation
diff and relevant surrounding implementations/callers, including generic
reallocation, typed allocator selection, allocator-list bookkeeping, free-list
variants, affix allocation, stats forwarding, and both dynamic adapter classes.
Checked remaining parent deallocation call sites for capability guards and
reviewed inherited wrapper behavior to distinguish preexisting limitations from
regressions.

Independently built and ran the combined allocator tests:

```sh
dmd -i -unittest -version=StdUnittest -preview=dip1000 -main \
  -of=/tmp/allocator-astra-review-test \
  std/experimental/allocator/*.d \
  std/experimental/allocator/building_blocks/*.d
/tmp/allocator-astra-review-test
git diff --check
```

Build and execution passed: **23 modules passed unittests**. Whitespace check
passed.

Additional standalone behavioral checks in `/tmp/allocator-astra-focused.d`
passed with both DMD and LDC, explicitly compiling the branch's package module:

```sh
dmd -i -preview=dip1000 -of=/tmp/allocator-astra-focused \
  /tmp/allocator-astra-focused.d std/experimental/allocator/package.d
/tmp/allocator-astra-focused
ldc2 -i -preview=dip1000 -of=/tmp/allocator-astra-focused-ldc \
  /tmp/allocator-astra-focused.d std/experimental/allocator/package.d
/tmp/allocator-astra-focused-ldc
```

These checked a range whose `popFront` throws after successful element
construction, for both sized/forward and input-only paths. In each case the
one completed element was destroyed and a counting manual allocator freed
storage exactly once. A successful 20-element input-only range also exercised
GCAllocator's generic reallocation fallback across multiple growth steps.
Explicitly supplying package.d matters for a standalone probe: otherwise this
environment can link the installed Phobos module and test older behavior.

## Optional test improvement

**Low priority; not a correctness finding.**
`std/experimental/allocator/package.d:3994` and its surrounding new exception
tests cover constructor/postblit failure using an allocator without individual
deallocation. Keeping a small permanent test for throwing `popFront`, with a
counting deallocation-capable allocator, would also protect the newly changed
increment ordering at lines 1876–1879 and 1911–1929 and both sides of the
conditional cleanup. The independent probes above verify that behavior now.

## Limits

This was a focused implementation review, not a new whole-package safety audit.
No additional issue is asserted for the separately recorded GC expansion,
internal-pointer resolution, adapter trust boundaries, or Region copying/reuse
concerns. Optional-capability support across every possible user-defined
allocator composition has not been proven exhaustively. Full platform CI,
documentation builds, and compatibility-release publication gates were not
rerun or verified here. The implementation handoff records the earlier combined
LDC suite; this review independently reran the combined DMD suite and focused
behavioral checks on both compilers.
