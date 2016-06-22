import reggae;
import std.process;
import std.string;
import std.algorithm;
import std.array;
import std.path;
import std.range;
import std.file;


version(OSX) enum OS = "osx";
version(linux) enum OS = "linux";
version(FreeBSD) enum OS = "freebsd";
version(OpenBSD) enum OS = "openbsd";
version(Solaris) enum OS = "solaris";

static assert(is(typeof(OS)), "Unrecognized or unsupported OS");

version(X86) enum MODEL = "32";
version(X86_64) enum MODEL = "64";
static assert(is(typeof(MODEL)), "Cannot figure 32/64 model");


string MODEL_FLAG(string model = MODEL) {
    return "-m" ~ model;
}

auto shell(string cmd) {
    return executeShell(cmd).output.chomp;
}


enum PIC = "PIC" in userVars ? "-fPIC" : "";
enum INSTALL_DIR = "../install";
enum DRUNTIME_PATH = "../druntime";
enum ZIPFILE = "phobos.zip";
enum ROOT_OF_THEM_ALL = "generated";
// build with shared library support (default to true on supported platforms)
enum SHARED = userVars.get("SHARED", ["linux", "freebsd"].canFind(OS) ? true : false);
enum DMD = "../dmd/src/dmd";
enum DMDEXTRAFLAGS = userVars.get("DMDEXTRAFLAGS", "");


version(Windows) enum CC = "dmc";
else             enum CC = "cc";

version(Windows) enum DOTOBJ = ".obj";
else             enum DOTOBJ = ".o";

version(linux) enum LINKDL = "-L-ldl";
else           enum LINKDL = "";


// Default to a release built, override with -d BUILD=debug
enum BUILD = userVars.get("BUILD", "release");
enum CUSTOM_DRUNTIME = userVars.get("DRUNTIME", "") != "";


// DRUNTIME is a variable in posix.mak
static if(CUSTOM_DRUNTIME) {
    string DRUNTIME(string build = BUILD, string model = MODEL) @safe {
        return userVars["DRUNTIME"];
    }
} else {
    version(Windows)
        string DRUNTIME(string build = BUILD) @safe { return DRUNTIME_PATH ~ "/lib/druntime.lib"; }
    else {
        string DRUNTIME(string build = BUILD, string model = MODEL) @safe {
            return DRUNTIME_PATH ~ "/generated/" ~ OS ~ "/" ~ build ~ "/" ~ model ~ "/libdruntime.a";
        }
    }
}

version(Windows) {
    string DRUNTIMESO(string build = BUILD) { return ""; }
} else {
    string DRUNTIMESO(string build = BUILD, string model = MODEL) {
        return stripExtension(DRUNTIME(build, model)) ~ ".so.a";
    }
}

Build _getBuild() {
    defaultOptions.cCompiler = CC;
    defaultOptions.dCompiler = DMD;


    // ROOT is a variable in posix.mak, but is a function here so the build can vary
    string ROOT(string build = BUILD, string model = MODEL) {
        return userVars.get("ROOT", ROOT_OF_THEM_ALL ~ "/" ~ OS ~ "/" ~ build ~ "/" ~ model);
    }

    // Documentation-related stuff
    enum DOCSRC = "../dlang.org";
    enum WEBSITE_DIR = "../web";
    enum DOC_OUTPUT_DIR = WEBSITE_DIR ~ "/phobos-prerelease";
    enum BIGDOC_OUTPUT_DIR = "/tmp";
    enum STDDOC = ["html.ddoc", "dlang.org.ddoc", "std_navbar-prerelease.ddoc",
                   "std.ddoc", "macros.ddoc", ".generated/modlist-prerelease.ddoc"].
        map!(a => DOCSRC ~ "/" ~ a).array;
    enum BIGSTDDOC = ["std_consolidated.ddoc", "macros.ddoc"].map!(a => DOCSRC ~ "/" ~ a).array;

    enum DDOC = DMD ~ " -conf= " ~ MODEL_FLAG ~ " -w -c -o- -version=StdDdoc -I" ~
        DRUNTIME_PATH ~ "/import " ~ DMDEXTRAFLAGS;

    string CFLAGS(string build = BUILD, string model = MODEL) {
        return MODEL_FLAG(model) ~ " -fPIC -DHAVE_UNISTD_H " ~ (build == "debug" ? "-g" : "-O3");
    }

    string DFLAGS(string build = BUILD, string model = MODEL) {
        auto flags = "-conf= -I" ~ DRUNTIME_PATH ~ "/import " ~ DMDEXTRAFLAGS ~ " -w -dip25 " ~ MODEL_FLAG(model) ~ " " ~ PIC;
        flags ~= build == "debug" ? " -g -debug" : " -O -release";
        return flags;
    }

    // Set LIB, the ultimate target
    version(Windows) {
        enum LIB = ROOT ~ "/phobos.lib";
    } else {
        enum LIB = ROOT ~ "/libphobos2.a";
        // 2.064.2 => libphobos2.so.0.64.2
        // 2.065 => libphobos2.so.0.65.0
        // MAJOR version is 0 for now, which means the ABI is still unstable
        enum MAJOR = "0";
        auto versionParts = readText("../dmd/VERSION").chomp.split(".");
        import std.conv: to;
        auto MINOR = versionParts[1].to!int.to!string;
        auto PATCH = versionParts[2].to!int.to!string;
        // SONAME doesn't use patch level (ABI compatible)
        auto SONAME = "libphobos2.so." ~ MAJOR ~ "." ~ MINOR;
        auto LIBSO = ROOT ~ "/" ~ SONAME ~ "." ~ PATCH;
    }

    auto MAIN = ROOT ~ "/emptymain.d";

    string[] P2MODULES(string[] packages)() {
        import std.meta;

        string[] ret;
        foreach(p; aliasSeqOf!packages) {
            mixin(`ret ~= PACKAGE_` ~ p.replace("/", "_") ~ `.map!(a => "` ~ p ~ `/" ~ a).array;`);
        }
        return ret;
    }

    // Packages in std. Just mention the package name here. The contents of package
    // xy/zz is in variable PACKAGE_xy_zz. This allows automation in iterating
    // packages and their modules.
    enum STD_PACKAGES = ["std"] ~
        ["algorithm", "container", "digest", "experimental/allocator",
         "experimental/allocator/building_blocks", "experimental/logger",
         "experimental/ndslice", "net", "experimental", "range", "regex"].
        map!(a => "std/" ~ a).array;

    // Modules broken down per package
    enum PACKAGE_std = ["array", "ascii", "base64", "bigint", "bitmanip",
                        "compiler", "complex", "concurrency",
                        "concurrencybase", "conv", "cstream", "csv",
                        "datetime", "demangle", "encoding", "exception",
                        "file", "format", "functional", "getopt", "json", "math",
                        "mathspecial", "meta", "mmfile", "numeric",
                        "outbuffer", "parallelism", "path", "process",
                        "random", "signals", "socket", "socketstream", "stdint",
                        "stdio", "stdiobase", "stream", "string", "system",
                        "traits", "typecons", "typetuple", "uni",
                        "uri", "utf", "uuid", "variant", "xml", "zip", "zlib"];

    enum PACKAGE_std_experimental = ["typecons"];
    enum PACKAGE_std_algorithm = ["comparison", "iteration", "mutation", "package", "searching", "setops", "sorting"];
    enum PACKAGE_std_container = ["array", "binaryheap", "dlist", "package", "rbtree", "slist", "util"];
    enum PACKAGE_std_digest = ["crc", "digest", "hmac", "md", "ripemd", "sha"];
    enum PACKAGE_std_experimental_logger = ["core", "filelogger", "nulllogger", "multilogger", "package"];
    enum PACKAGE_std_experimental_allocator = ["common", "gc_allocator", "mallocator",
                                               "mmap_allocator", "package", "showcase", "typed"];
    enum PACKAGE_std_experimental_allocator_building_blocks = ["affix_allocator", "allocator_list", "bucketizer",
        "fallback_allocator", "free_list", "free_tree", "bitmapped_block",
        "kernighan_ritchie", "null_allocator", "package", "quantizer",
        "region", "scoped_allocator", "segregator", "stats_collector"];
    enum PACKAGE_std_experimental_ndslice = ["package", "iteration", "selection", "slice"];
    enum PACKAGE_std_net = ["curl", "isemail"];
    enum PACKAGE_std_range = ["interfaces", "package", "primitives"];
    enum PACKAGE_std_regex = ["package"] ~
        ["generator", "ir", "parser", "backtracking", "kickstart", "tests", "thompson"].
        map!(a => "internal/" ~ a).array;

    // Modules in std (including those in packages)
    auto STD_MODULES = P2MODULES!STD_PACKAGES;

    // OS-specific D modules
    enum EXTRA_MODULES_LINUX = ["linux", "socket"].map!(a => "std/c/linux/" ~ a).array;
    enum EXTRA_MODULES_OSX = ["std/c/osx/socket"];
    enum EXTRA_MODULES_FREEBSD = ["std/c/freebsd/socket"];
    enum EXTRA_MODULES_WIN32 = ["com", "stat", "windows", "winsock"].map!(a => "std/c/windows/" ~ a).array ~
        ["charset", "iunknown", "syserror"].map!(a => "std/windows/" ~ a).array;

    // Other D modules that aren't under std/
    enum EXTRA_MODULES_COMMON = ["curl", "odbc/sql", "odbc/sqlext", "odbc/sqltypes",
                                 "odbc/sqlucode", "sqlite3", "zlib"].map!(a => "etc/c/" ~ a).array ~
        ["fenv", "locale", "math", "process", "stdarg", "stddef",
         "stdio", "stdlib", "string", "time", "wcharh"].map!(a => "std/c/" ~ a).array;

    auto EXTRA_DOCUMENTABLES = EXTRA_MODULES_LINUX ~ EXTRA_MODULES_WIN32 ~ EXTRA_MODULES_COMMON;
    auto SRC_DOCUMENTABLES = userVars.get("SRC_DOCUMENTABLES",
                                          ["index.d"] ~ STD_MODULES.map!(a => a ~ ".d").array ~ EXTRA_DOCUMENTABLES);


    enum EXTRA_MODULES_INTERNAL = ["std/internal/digest/sha_SSSE3"] ~
        ["biguintcore", "biguintnoasm", "biguintx86", "gammafunction", "errorfunction"].map!(a => "std/internal/math/" ~ a).array ~
        ["cstring", "processinit", "unicode_tables", "scopebuffer", "unicode_comp", "unicode_decomp",
         "unicode_grapheme", "unicode_norm"].map!(a => "std/internal/" ~ a).array ~
        "std/internal/test/dummyrange" ~
        "std/experimental/ndslice/internal" ~
        "std/algorithm/internal";

    auto EXTRA_MODULES = EXTRA_DOCUMENTABLES ~ EXTRA_MODULES_INTERNAL;

    // Aggregate all D modules relevant to this build
    auto D_MODULES = STD_MODULES ~ EXTRA_MODULES;

    // Add the .d suffix to the module names
    auto D_FILES = D_MODULES.map!(a => a ~ ".d").array;
    // Aggregate all D modules over all OSs (this is for the zip file)
    auto ALL_D_FILES = chain(STD_MODULES, EXTRA_MODULES_COMMON, EXTRA_MODULES_LINUX,
                             EXTRA_MODULES_OSX, EXTRA_MODULES_FREEBSD,
                             EXTRA_MODULES_WIN32, EXTRA_MODULES_INTERNAL).map!(a => a ~ ".d").array ~
        ["std/internal/windows/advapi32.d", "std/windows/registry.d", "std/c/linux/pthread.d",
         "std/c/linux/termios.d", "std/c/linux/tipc.d"];

    auto oldAllDFiles = chain(STD_MODULES, EXTRA_MODULES_COMMON, EXTRA_MODULES_LINUX,
                             EXTRA_MODULES_OSX, EXTRA_MODULES_FREEBSD,
                             EXTRA_MODULES_WIN32, EXTRA_MODULES_INTERNAL).map!(a => a ~ ".d").array ~
        ["std/internal/windows/advapi32.d", "std/windows/registry.d", "std/c/linux/pthread.d",
         "std/c/linux/termios.d", "std/c/linux/tipc.d"].array;
    sort(oldAllDFiles);
    auto newAllDFiles = objectFiles!(dSources).map!(a => a.dependenciesInProjectPath("")).join;
    sort(newAllDFiles);
    import std.conv;
    assert(oldAllDFiles == newAllDFiles, text("\n\nold:\n", oldAllDFiles, "\n\nnew:\n", newAllDFiles, "\n"));


    assert(ALL_D_FILES.length == 167, ALL_D_FILES.length.to!string);

    // C files to be part of the build
    enum C_MODULES = ["adler32", "compress", "crc32", "deflate", "gzclose", "gzlib",
                      "gzread", "gzwrite", "infback", "inffast", "inflate", "inftrees", "trees",
                      "uncompr", "zutil"].map!(a => "etc/c/zlib/" ~ a);

    string[] OBJS(string build = BUILD, string model = MODEL) {
        return C_MODULES.map!(a => ROOT(build, model) ~ "/" ~ a ~ DOTOBJ).array;
    }

    // Rules begin here

    // C objects, a pattern rule in the original makefile
    Target[] target_OBJS(string build = BUILD, string model = MODEL) {
        return C_MODULES.
            map!(a => Target("$project/" ~ ROOT(build, model) ~ "/" ~ a ~ DOTOBJ,
                             CC ~ " -c " ~ CFLAGS(build, model) ~ " $in -o $out",
                             Target(a ~ ".c"))).
            array;
    }

    Target target_LIB(string model = MODEL) {
        return Target("$project/" ~ LIB,
                      DMD ~ " " ~ DFLAGS(BUILD, model) ~ " -lib -of$out " ~ DRUNTIME(BUILD, model) ~ " " ~
                      chain(D_FILES, OBJS).join(" "),
                      target_OBJS(BUILD, model) ~
                      chain(ALL_D_FILES, [DRUNTIME(BUILD)]).map!(a => Target(a)).array);
    }

    // the makefile here rewrites PIC for the dll rule, which we can't do, so add it to the flags
    auto target_LIBSO = Target("$project/" ~ LIBSO,
                               DMD ~ " " ~ DFLAGS(BUILD) ~ " -fPIC -shared -debuglib= -defaultlib= -of$out -L-soname=" ~
                               chain([SONAME, DRUNTIMESO(BUILD), LINKDL], D_FILES, OBJS).join(" "),
                               target_OBJS(BUILD) ~
                               chain(ALL_D_FILES, [DRUNTIMESO(BUILD)]).map!(a => Target(a)).array);

    auto target_SONAME = Target("$project/" ~ ROOT ~ "/" ~ SONAME,
                                "ln -sf " ~ baseName(LIBSO) ~ " $out",
                                target_LIBSO);

    auto target_DLL = Target("$project/" ~ ROOT ~ "/libphobos2.so",
                             "ln -sf " ~ baseName(LIBSO) ~ " $out",
                             target_SONAME);

    version(OSX) {
        // Build fat library that combines the 32 bit and the 64 bit libraries
        auto fat = [Target("libphobos2.a",
                          "lipo " ~
                           ROOT_OF_THEM_ALL ~ "/osx/release/32/libphobos2.a \\\n" ~
                           ROOT_OF_THEM_ALL ~ "/osx/release/64/libphobos2.a \\\n" ~
                          "-create -output $out",
                           [target_LIB("32"), target_LIB("64")])];
    } else {
        Target[] fat; //nothing to see here
    }

    alias lib = target_LIB;
    alias dll = target_DLL;
    // the equivalent of all: lib dll
    auto all = SHARED ? [lib, dll] : [lib]; // the Makefile "all" targets

    Target druntimeTarget(string build) {
        static if(CUSTOM_DRUNTIME) {
            // We consider a custom-set DRUNTIME a sign they build druntime themselves
        } else {
            // This rule additionally produces $(DRUNTIMESO). Add a fake dependency
            // to always invoke druntime's make. Use FORCE instead of .PHONY to
            // avoid rebuilding phobos when $(DRUNTIME) didn't change.
            version(FreeBSD) enum make = "gmake";
            else             enum make = "make";
            auto command = make ~ " -C " ~ DRUNTIME_PATH ~
                " -f posix.mak MODEL=" ~ MODEL ~
                " DMD=" ~ DMD ~ " OS=" ~ OS ~ " BUILD=" ~ build;
            auto druntime = Target("$project/" ~ DRUNTIME(build), command);
            return SHARED ? Target("$project/" ~ DRUNTIMESO(build), command) : druntime;
        }
    }

    // Unittests
    Target[] createUnitTests(string build) {
        auto UT_D_OBJS = D_MODULES.map!(a => "$project/" ~ ROOT(build) ~ "/unittest/" ~ a ~ ".o").array;
        auto target_DRUNTIME = druntimeTarget(build);
        Target test_runner;

        if(!SHARED) {
            auto target_UT_D_OBJS = D_MODULES.
                map!(a => Target("$project/" ~ ROOT(build) ~ "/unittest/" ~ a ~ ".o",
                                 DMD ~ " " ~ DFLAGS(build) ~ " -unittest -c -of$out $in",
                                 target_DRUNTIME ~ [Target(a ~ ".d")])).array;

            test_runner = Target("$project/" ~ ROOT(build) ~ "/unittest/test_runner",
                                 DMD ~ " " ~ DFLAGS(build) ~ " -unittest -of$out " ~ DRUNTIME_PATH ~ "/src/test_runner.d " ~
                                 chain(UT_D_OBJS, OBJS(build), [DRUNTIME(build), LINKDL]).join(" ") ~ " -defaultlib= -debuglib=",
                                 target_UT_D_OBJS ~
                                 Target(DRUNTIME_PATH ~ "/src/test_runner.d") ~
                                 target_OBJS(build) ~
                                 target_DRUNTIME
                );
        } else {
            auto target_UT_D_OBJS = D_MODULES.
                map!(a => Target("$project/" ~ ROOT(build) ~ "/unittest/" ~ a ~ ".o",
                                 DMD ~ " " ~ DFLAGS(build) ~ " -fPIC -unittest -c -of$out $in",
                                 target_DRUNTIME ~ [Target(a ~ ".d")])).array;

            auto UT_LIBSO = "$project/" ~ ROOT(build) ~ "/unittest/libphobos2-ut.so";
            auto target_UT_LIBSO = Target(UT_LIBSO,
                                          DMD ~ " " ~ DFLAGS(build) ~ " -fPIC -shared -unittest -of$out " ~
                                          chain(UT_D_OBJS, OBJS(build), [DRUNTIMESO(build), LINKDL]).join(" ") ~
                                          " -defaultlib= -debuglib=",
                                          target_DRUNTIME ~ target_UT_D_OBJS ~ target_OBJS(build)
                );

            test_runner = Target("$project/" ~ ROOT(build) ~ "/unittest/test_runner",
                                 DMD ~ " " ~ DFLAGS(build) ~ " -of$out $in -L" ~ UT_LIBSO ~ " -defaultlib= -debuglib=",
                                 [target_UT_LIBSO, Target(DRUNTIME_PATH ~ "/src/test_runner.d")]);
        }

        // returns the module name given the src path
        string moduleName(in string fileName) { return fileName.replace("/", "."); }

        auto TIMELIMIT = shell("which timelimit 2>/dev/null || true") != "" ? "timelimit -t 60" : "";

        // target for batch unittests (using shared phobos library and test_runner)
        enum QUIET = userVars.get("QUIET", "");
        return D_MODULES.
            map!(a => Target.phony("unittest/" ~ a ~ ".run",
                                   QUIET ~ TIMELIMIT ~ " $in " ~ moduleName(a),
                                   [test_runner])).array;
    }

    auto unittest_debug = Target.phony("unittest-debug", "", createUnitTests("debug"));
    auto unittest_release = Target.phony("unittest-release", "", createUnitTests("release")) ;

    static if("BUILD" in userVars) { // BUILD_WAS_SPECIFIED
        // target for the batch unittests (using shared phobos library and test_runner)
        auto unittest_ = Target.phony("unittest", "", createUnitTests(BUILD));
    } else {
        auto unittest_ = Target.phony("unittest", "", [unittest_debug, unittest_release]);
    }

    // Target for quickly running a single unittest (using static phobos library).
    // For example: "make std/algorithm/mutation.test"
    // The mktemp business is needed so .o files don't clash in concurrent unittesting.
    auto unittestsModule = D_MODULES.
        map!(a => Target.phony(a ~ ".test",
                               "T=`mktemp -d /tmp/.dmd-run-test.XXXXXX` && \\\n" ~
                               DMD ~ " " ~ DFLAGS ~ " -main -unittest " ~ LIB ~ " -defaultlib= -debuglib= " ~
                               LINKDL ~ " -cov -run $in && \\\n" ~
                               "rm -rf $T",
                               [Target(a ~ ".d")],
                               [lib])).
        array;

    // Target for quickly unittesting all modules and packages within a package,
    // transitively. For example: "make std/algorithm.test"
    Target[] unittestsPackage;
    foreach(package_; STD_PACKAGES ~ ["etc", "etc/c"]) {
        auto entries = dirEntries(package_, SpanMode.breadth);
        auto targetNames = entries.map!(a => a.stripExtension ~ ".test").array;
        unittestsPackage ~= Target(package_ ~ ".test",
                                   "",
                                   unittestsModule.filter!(a => targetNames.canFind(a.rawOutputs[0])).array);
    }

    // More stuff
    auto gitzip = Target.phony("gitzip", "git archive --format=zip HEAD > " ~ ZIPFILE);
    auto zip = Target.phony("zip", "rm -f " ~ ZIPFILE ~ "; zip -r " ~ ZIPFILE ~ " . -x .git\\* -x generated\\*");

    version(OSX) enum lib_dir = "lib" ~ MODEL;
    else         enum lib_dir = "lib";

    auto installCommonCmd = "mkdir -p " ~ [INSTALL_DIR, OS, lib_dir].join("/") ~ "; " ~
        "cp " ~ LIB ~ " " ~ [INSTALL_DIR, OS, lib_dir].join("/") ~ "/; ";
    static if(SHARED)
        auto install = Target.phony("install",
                                    installCommonCmd ~
                                    "cp -P " ~ LIBSO ~ " " ~ [INSTALL_DIR, OS, lib_dir].join("/") ~ "/; " ~
                                    "ln -sf " ~ baseName(LIBSO) ~ [INSTALL_DIR, OS, lib_dir, "libphobos2.so"].join("/"));
    else
        auto install = Target.phony("install",
                                    installCommonCmd ~
                                    "mkdir -p " ~ INSTALL_DIR ~ "/src/phobos/etc; " ~
                                    "mkdir -p " ~ INSTALL_DIR ~ "/src/phobos/std; " ~
                                    "cp -r std/* " ~ INSTALL_DIR ~ "/src/phobos/std; " ~
                                    "cp -r etc/* " ~ INSTALL_DIR ~ "/src/phobos/etc; " ~
                                    "cp LICENSE_1_0.TXT " ~ INSTALL_DIR ~ "/phobos-LICENSE.txt");


    auto json = Target("$project/phobos.json",
                       DMD ~ " " ~ DFLAGS ~ " -o- -Xf$out $in",
                       ALL_D_FILES.map!(a => Target(a)).array);

    // html documentation
    // D file to html, e.g. std/conv.d -> std_conv.html
    // But "package.d" is special cased: std/range/package.d -> std_range.html
    string D2HTML(string str) {
        str = str.baseName == "package.d" ? str.dirName : str.stripExtension;
        return str.replace("/", "_") ~ ".html";
    }
    static assert(D2HTML("std/conv.d") == "std_conv.html");
    static assert(D2HTML("std/range/package.d") == "std_range.html");

    auto HTMLS = SRC_DOCUMENTABLES.map!(a => DOC_OUTPUT_DIR ~ "/" ~ D2HTML(a)).array;
    auto BIGHTMLS = SRC_DOCUMENTABLES.map!(a => BIGDOC_OUTPUT_DIR ~ "/" ~ D2HTML(a)).array;

    auto doc_output_dir = Target(DOC_OUTPUT_DIR ~ "/.", "mkdir -p $out", []);
    // For each module, define a rule e.g.:
    //  ../web/phobos/std_conv.html : std/conv.d $(STDDOC) ; ...
    auto htmls = SRC_DOCUMENTABLES.map!(a => Target(DOC_OUTPUT_DIR ~ "/" ~ D2HTML(a),
                                                    DDOC ~ " project.ddoc " ~ STDDOC.join(" ") ~ " -Df$out $in",
                                                    [Target(a)] ~ STDDOC.map!(a => Target(a)).array)).
        array;
    auto big_htmls = SRC_DOCUMENTABLES.map!(a => Target(BIGDOC_OUTPUT_DIR ~ "/" ~ D2HTML(a),
                                                        DDOC ~ " project.ddoc " ~ BIGSTDDOC.join(" ") ~ " -Df$out $in",
                                                        [Target(a)] ~ STDDOC.map!(a => Target(a)).array)).
        array;


    auto html = Target.phony("html",
                             "",
                             [doc_output_dir] ~
                             htmls ~
                             ("STYLECSS_TGT" in userVars ? [Target(userVars["STYLECSS_TGT"])] : []));
    auto allmod = Target.phony("allmod", "echo " ~ SRC_DOCUMENTABLES.join(" "));

    auto rsync_prerelease = Target.phony("rsync-prerelease",
                                         "rsync -avz " ~ DOC_OUTPUT_DIR ~
                                         "/ d-programming@digitalmars.com:data/phobos-prerelease/; " ~
                                         "rsync -avz " ~ WEBSITE_DIR ~
                                         "/ d-programming@digitalmars.com:data/phobos-prerelease/",
                                         [html]);
    auto html_consolidated = Target.phony("html_consolidated",

                                          DDOC ~ " -Df" ~ DOCSRC ~ "/std_consolidated_header.html " ~
                                          DOCSRC ~ "/std_consolidated_header.dd; " ~

                                          DDOC ~ " -Df" ~ DOCSRC ~ "/std_consolidated_footer.html " ~
                                          DOCSRC ~ "/std_consolidated_footer.dd; " ~

                                          "cat " ~ DOCSRC ~ "/std_consolidated_header.html " ~ BIGHTMLS.join(" ") ~ " " ~
                                          DOCSRC ~ "/std_consolidated_footer.html > " ~ DOC_OUTPUT_DIR ~ "/std_consolidated.html",
                                          big_htmls
                                          );
    auto changelog_html = Target("changelog.html", DMD ~ " -Df$out $in", Target("changelog.dd"));

    // test for undersired white spaces
    auto CWS_TOCHECK = ["posix.mak", "win32.mak", "win64.mak", "osmodel.mak"] ~ ALL_D_FILES ~ "index.d";
    auto checkwhitespace = Target.phony("checkwhitespace",
                                        DMD ~ " " ~ DFLAGS ~ " -defaultlib= -debuglib= " ~ LIB ~
                                        " -run ../dmd/src/checkwhitespace.d " ~ CWS_TOCHECK.join(" "),
                                        [target_LIB]);
    auto auto_tester_build = Target.phony("auto-tester-build", "", all ~ checkwhitespace);
    auto auto_tester_test  = Target.phony("auto-tester-test",  "", [unittest_]);

    auto targets = chain(newTargets,
                         chain(fat,
                               [unittest_, unittest_debug, unittest_release, gitzip, zip, install],
                               [json],
                               [html], htmls,
                               [allmod, rsync_prerelease, html_consolidated, changelog_html],
                               [checkwhitespace, auto_tester_build, auto_tester_test],
                               unittestsModule, unittestsPackage).
                         map!(a => optional(a))).array;

    return Build(targets);
}

auto newTargets() {
    auto all = chain(staticPhobos!(BUILD, MODEL), [dynamicPhobos!(BUILD, MODEL)]);
    auto defaultTargets = all.map!createTopLevelTarget;
    Target[] foo;
    auto optionalTargets = foo.map!optional;
    return chain(defaultTargets, optionalTargets);
}

// Target[] fatLib() {
//     version(OSX) {
//         return fatLibMac();
//     } else {
//         return []; // nothing to see here
//     }
// }


// Target fatLibMac() {
//     // Build fat library that combines the 32 bit and the 64 bit libraries
//     return Target("libphobos2.a",
//                    "lipo " ~
//                    ROOT_OF_THEM_ALL ~ "/osx/release/32/libphobos2.a \\\n" ~
//                    ROOT_OF_THEM_ALL ~ "/osx/release/64/libphobos2.a \\\n" ~
//                    "-create -output $out",
//                    [target_LIB("32"), target_LIB("64")]);
// }

// DRUNTIME is a variable in posix.mak


private Target[] staticPhobos(string build, string model)() {
    import std.path;

    version(Windows) {
        enum fileName = "phobos.lib";
    } else {
        enum fileName = "libphobos2.a";
    }

    auto path = inGeneratedDir(build, model, fileName);
    auto cmd = [DMD, dflags(build, model), "-lib", "-of$out", "$in"].join(" ");
    auto dependencies = chain(cObjs!(build, model),
                              [staticRuntime(build, model)],
                              sourcesToTargets!dSources);
    return [Target(path, cmd, dependencies)];
}

// D source files
alias dSources = Sources!(["std", "etc"],
                          Files(),
                          Filter!(a => a.extension == ".d" && !a.canFind("linuxextern") && !a.canFind("test/uda.d")));


private Target staticRuntime(string build, string model) @safe {
    static if(CUSTOM_DRUNTIME) {
        return Target(CUSTOM_DRUNTIME);
        // We consider a custom-set DRUNTIME a sign they build druntime themselves
    } else {
        // This rule additionally produces $(DRUNTIMESO). Add a fake dependency
        // to always invoke druntime's make. Use FORCE instead of .PHONY to
        // avoid rebuilding phobos when $(DRUNTIME) didn't change.
        version(FreeBSD) enum make = "gmake";
        else             enum make = "make";
        auto command = [make, "-C", DRUNTIME_PATH, "-f", "posix.mak", "MODEL=" ~ model,
                        "DMD=" ~ DMD, "OS=" ~ OS, "BUILD=" ~ build].join(" ") ~
            "  # FORCE phony druntime build";
        auto druntime = Target("$project/" ~ staticRuntimeFileName(build, model),
                               command);
        return SHARED
            ? Target("$project/" ~ dynamicRuntimeFileName(build, model),
                     command)
            : druntime;
    }
}

static if(CUSTOM_DRUNTIME) {
    string staticRuntimeFileName(string build, string model) @safe {
        return userVars["DRUNTIME"];
    }
} else {
    version(Windows)
        string staticRuntimeFileName(string build, string model) @safe { return DRUNTIME_PATH ~ "/lib/druntime.lib"; }
    else {
        string staticRuntimeFileName(string build, string model) @safe {
            import std.path;
            return buildPath(DRUNTIME_PATH, "generated", OS, build, model, "libdruntime.a");
        }
    }
}

version(Windows) {
    string dynamicRuntimeFileName(string build, string model) @safe { return ""; }
} else {
    string dynamicRuntimeFileName(string build, string model) @safe {
        return stripExtension(DRUNTIME(build, model)) ~ ".so.a";
    }
}

private Target dynamicRuntime(string build, string model) {
    return Target(dynamicRuntimeFileName(build, model));
}

private string dflags(string build, string model) {
    auto flags = "-conf= -I" ~ DRUNTIME_PATH ~ "/import " ~ DMDEXTRAFLAGS ~ " -w -dip25 " ~ MODEL_FLAG(model) ~ " " ~ PIC;
    flags ~= build == "debug" ? " -g -debug" : " -O -release";
    return flags;
}

// C source files
alias cSources = Sources!(Dirs(["etc/c/zlib"]),
                          Files(),
                          Filter!(a => !a.canFind("example") && !a.canFind("minigzip")));

// C objects, a pattern rule in the original makefile
private Target[] cObjs(string build, string model)() {
    enum buildFlag = build == "debug" ? "-g" : "-O3";
    enum flags = ["-c", "-m" ~ model, "-fPIC", "-DHAVE_UNISTD_H", buildFlag].join(" ");
    return objectFiles!(cSources, Flags(flags));
}


private Target dynamicPhobos(string build, string model)() {
    // Set LIB, the ultimate target
    version(Windows) {
        assert(0);
    } else {
        // 2.064.2 => libphobos2.so.0.64.2
        // 2.065 => libphobos2.so.0.65.0
        // MAJOR version is 0 for now, which means the ABI is still unstable
        enum MAJOR = "0";
        auto versionParts = readText("../dmd/VERSION").chomp.split(".");
        import std.conv: to;
        auto minor = versionParts[1].to!int.to!string;
        auto patch = versionParts[2].to!int.to!string;
        // soName doesn't use patch level (ABI compatible)
        auto soName = inGeneratedDir(build, model, "libphobos2.so." ~ MAJOR ~ "." ~ minor);
        auto patchName = soName ~ "." ~ patch;

        auto cmd = [DMD, dflags(build, model), "-fPIC", "-shared",
                    "-debuglib=", "-defaultlib=", "-of$out",
                    "-L-soname=" ~ soName, LINKDL, "$in"].join(" ");

        auto dependencies = chain(cObjs!(build, model),
                                  [dynamicRuntime(build, model)],
                                  sourcesToTargets!dSources);

        auto phobos = Target(patchName, cmd, dependencies);

        auto fstLink = Target(soName,
                              "ln -sf " ~ baseName(patchName) ~ " $out",
                              phobos);

        auto sndLink = Target(inGeneratedDir(build, model, "libphobos2.so"),
                              "ln -sf " ~ baseName(soName) ~ " $out",
                              fstLink);

        return sndLink;
    }
}

private string inGeneratedDir(string build, string model, string fileName) {
    import std.path;
    return buildPath("$project", "generated", OS, build, model, fileName);
}
