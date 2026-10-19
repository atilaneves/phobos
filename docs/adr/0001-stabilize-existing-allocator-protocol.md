---
status: accepted
---

# Stabilize the existing allocator protocol

Promote the entire existing composable `void[]` allocator package into current Phobos as a low-level allocation toolkit after resolving demonstrated correctness, soundness, and contradictory-contract defects. Each breaking change requires a minimal reproducer, violated documented contract, or equivalent regression test; API awkwardness and audit suspicion alone do not justify a break. Existing `NullAllocator` policy conventions therefore remain and must be documented clearly. Audit every `@trusted` boundary for soundness. The stable package is part of the `std` aggregate import. Sound `@safe` deallocation for arbitrary non-GC allocators is not a promise of this API and does not require adopting a new ownership-carrying block type; operations that cannot prevent dangling aliases remain `@system`.
