module std.experimental.testing.tests.module_with_attrs;

import std.experimental.testing.attrs;

@HiddenTest("foo")
@ShouldFail("bar")
@SingleThreaded
void testAttrs() {
}
