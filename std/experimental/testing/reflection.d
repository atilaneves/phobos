module std.experimental.testing.reflection;

import std.experimental.testing.attrs;
import std.experimental.testing.uda;
import std.traits: fullyQualifiedName, isSomeString;
import std.typetuple: Filter;

/**
 * Unit test function type.
 */
alias void function() TestFunction;

/**
 * Unit test data
 */
struct TestData {
    string name;
    TestFunction testFunction;
    bool hidden;
    bool shouldFail;
    bool singleThreaded;
}


/**
Finds all test cases (functions, classes, built-in unittest blocks)
Template parameters are module symbols or their string representation.
Examples:
-----
import my.test.module;
auto testData = allTestData!(my.test.module, "other.test.module");
-----
*/
TestData[] allTestData(MODULES...)() @safe pure nothrow
{
    TestData[] testData;

    foreach(module_; MODULES) {
        static if(is(typeof(module_)) && isSomeString!(typeof(module_)))
        {
            //string, generate the code
            mixin("import " ~ module_ ~ ";");
            testData ~= moduleTestData!(mixin(module_));
        }
        else
        {
            //module symbol, just add normally
            testData ~= moduleTestData!(module_);
        }
    }

    return testData;
}

/**
Finds all built-in unittest blocks in the given module_.
Params:
  module_ = The module to reflect on. Can be a symbol or a string.
Returns: An array of TestData structs
*/
TestData[] moduleTestData(alias module_)() @safe pure nothrow {

    // Return a name for a unittest block. If no @Name UDA is found a name is
    // created automatically, else the UDA is used.
    string unittestName(alias test, int index)() @safe nothrow {
        mixin("import " ~ fullyQualifiedName!module_ ~ ";"); //so it's visible

        enum isName(alias T) = is(typeof(T)) && is(typeof(T) == Name);
        alias names = Filter!(isName, __traits(getAttributes, test));
        static assert(names.length == 0 || names.length == 1,
                      "Found multiple Name UDAs on unittest");
        enum prefix = fullyQualifiedName!module_ ~ ".";

        static if(names.length == 1) {
            return prefix ~ names[0].value;
        } else {
            import std.conv;
            return prefix ~ "unittest" ~ index.to!string;
        }
    }

    TestData[] testData;
    foreach(index, test; __traits(getUnitTests, module_)) {
        testData ~= TestData(unittestName!(test, index),
                             &test,
                             HasAttribute!(test, HiddenTest),
                             HasAttribute!(test, ShouldFail),
                             HasAttribute!(test, SingleThreaded),
                             );
    }
    return testData;
}
