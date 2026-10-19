---
status: accepted
---

# Separate GC lifetime policies

`GCAllocator` will represent automatically reclaimed GC allocation and therefore will not expose individual `deallocate` or moving `reallocate`. A separate `GCHeapMallocator` will preserve the explicitly managed, GC-scanned heap use case, keeping the two incompatible lifetime policies visible in their types.
