module std.experimental.testing.tests.module_with_tests;

import std.experimental.testing.attrs;


unittest {
    //1st block
    assert(true);
}

unittest {
    //2nd block
    assert(true);
}

@Name("myUnitTest")
unittest {
    assert(true);
}
