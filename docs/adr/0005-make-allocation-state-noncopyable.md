---
status: accepted
---

# Make allocation state noncopyable

Allocator values that own storage, advance an allocation cursor, manage an intrusive structure, or contain synchronization state are noncopyable. Copying such a value duplicates authority over the same backing memory and can cause overlapping mutable allocations, double release, corruption, or ineffective locking; storage-reusing operations likewise remain `@system` when live aliases cannot be ruled out.
