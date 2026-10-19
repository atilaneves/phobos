---
status: accepted
---

# Forward experimental allocator imports without warnings

After promotion, the old `std.experimental.allocator.*` modules will remain as warning-free public-import shims. Deprecation will be considered separately after ecosystem migration because immediate warnings would unnecessarily break projects that compile with deprecations as errors.
