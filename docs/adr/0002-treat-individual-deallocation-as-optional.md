---
status: accepted
---

# Treat individual deallocation as optional

An allocator without `deallocate` does not support individual deallocation, so generic components must not call it. Absence alone promises neither automatic reclamation nor a leak: components that require immediate individual reclamation must constrain their allocator accordingly, while other lifetime strategies may reclaim storage automatically, in bulk, or through a parent owner.

The dynamic `IAllocator` adapter preserves its documented fixed-interface representation of this rule: a missing static `deallocate` becomes a dynamic method that returns `false`. The `dispose` helper requires individual deallocation and therefore rejects allocators without `deallocate` instead of silently performing destruction without fulfilling its deallocation contract.
