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
enum ROOT_OF_THEM_ALL = "generated";
// build with shared library support (default to true on supported platforms)
enum SHARED = userVars.get("SHARED", ["linux", "freebsd"].canFind(OS) ? true : false);
enum DMD = "../dmd/src/dmd";
enum DMDEXTRAFLAGS = userVars.get("DMDEXTRAFLAGS", "");

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


private Build _getBuild() {
    return Build(chain(defaultTargets.map!createTopLevelTarget,
                       optionalTargets.map!optional));
}

private auto defaultTargets() {
    return chain(staticPhobos!(BUILD, MODEL), dynamicPhobos!(BUILD, MODEL));
}

private auto optionalTargets() {
    return chain(unitTestTargets, autoTesterTargets, zipTargets, installTargets, fatTargets, jsonTargets,
                 htmlTargets, miscTargets, singleModuleUnitTestTargets);
}

private auto autoTesterTargets() {
    return [Target.phony("auto-tester-build", "", defaultTargets.array ~ miscTargets.front),
            Target.phony("auto-tester-test",  "", [unitTestTargets.front])];
}

private Target[] miscTargets() {
    auto allmod = Target.phony("allmod", "echo " ~ sourceDocumentables.join(" "));
    auto rsync_prerelease = Target.phony("rsync-prerelease",
                                         "rsync -avz " ~ DOC_OUTPUT_DIR ~
                                         "/ d-programming@digitalmars.com:data/phobos-prerelease/; " ~
                                         "rsync -avz " ~ WEBSITE_DIR ~
                                         "/ d-programming@digitalmars.com:data/phobos-prerelease/",
                                         htmlTargets);

    auto staticLib = staticPhobos!(BUILD, MODEL)[0].expandOutputs(options.projectPath)[0];
    // test for undersired white spaces
    auto cwsToCheck = chain(["../dmd/src/checkwhitespace.d",
                             "posix.mak",
                             "win32.mak",
                             "win64.mak",
                             "osmodel.mak",
                             "index.d"].map!(a => Target(a)),
                            sourcesToTargets!allDSources);
    auto cwsCmd = [DMD, dflags(BUILD, MODEL), "-defaultlib=", "-debuglib=", staticLib, "-run", "$in"].join(" ");
    auto checkwhitespace = Target.phony("checkwhitespace",
                                        cwsCmd,
                                        cwsToCheck,
                                        staticPhobos!(BUILD, MODEL));

    return [checkwhitespace, allmod, rsync_prerelease];
}

private auto unitTestTargets() {
    auto unittest_debug = Target.phony("unittest-debug", "", unitTests!("debug", MODEL));
    auto unittest_release = Target.phony("unittest-release", "", unitTests!("release", MODEL));

    static if("BUILD" in userVars) // BUILD_WAS_SPECIFIED
        auto unitTestDependencies = unitTests!(BUILD);
    else
        auto unitTestDependencies = [unittest_debug, unittest_release];

    auto unittest_ = Target.phony("unittest", "", unitTestDependencies);

    return [unittest_, unittest_debug, unittest_release];
}

private auto singleModuleUnitTestTargets() {
    // staticLib is needed because the command has to split apart both of
    // its dependencies
    auto staticLib = staticPhobos!(BUILD, MODEL)[0].expandOutputs(options.projectPath)[0];
    auto command = [DMD, dflags(BUILD, MODEL), "-main", "-unittest", staticLib,
                    "-defaultlib=", "-debuglib=", LINKDL, "-cov", "-run", "$in"].join(" ");

    string testTarget(string fileName) {
        return fileName.stripExtension.replace("/", ".") ~ ".test";
    }

    return sourcesToTargets!dSources
        .map!(a => Target.phony(testTarget(a.expandOutputs("")[0]),
                                command,
                                [a],
                                staticPhobos!(BUILD, MODEL)));
}


private auto zipTargets() {
    // More stuff
    enum ZIPFILE = "phobos.zip";
    auto gitzip = Target.phony("gitzip", "git archive --format=zip HEAD > " ~ ZIPFILE);
    auto zip = Target.phony("zip", "rm -f " ~ ZIPFILE ~ "; zip -r " ~ ZIPFILE ~ " . -x .git\\* -x generated\\*");
    return [gitzip, zip];
}

private auto installTargets() {
    version(OSX) enum lib_dir = "lib" ~ MODEL;
    else         enum lib_dir = "lib";

    auto LIB = staticPhobos!(BUILD, MODEL)[0].expandOutputs("")[0];
    auto installCommonCmd = "mkdir -p " ~ [INSTALL_DIR, OS, lib_dir].join("/") ~ "; " ~
        "cp " ~ LIB ~ " " ~ [INSTALL_DIR, OS, lib_dir].join("/") ~ "/; ";
    static if(SHARED) {
        auto LIBSO = dynamicPhobos!(BUILD, MODEL)[0].expandOutputs("")[0];
        auto install = Target.phony("install",
                                    installCommonCmd ~
                                    "cp -P " ~ LIBSO ~ " " ~ [INSTALL_DIR, OS, lib_dir].join("/") ~ "/; " ~
                                    "ln -sf " ~ baseName(LIBSO) ~ [INSTALL_DIR, OS, lib_dir, "libphobos2.so"].join("/"));
    }
    else
        auto install = Target.phony("install",
                                    installCommonCmd ~
                                    "mkdir -p " ~ INSTALL_DIR ~ "/src/phobos/etc; " ~
                                    "mkdir -p " ~ INSTALL_DIR ~ "/src/phobos/std; " ~
                                    "cp -r std/* " ~ INSTALL_DIR ~ "/src/phobos/std; " ~
                                    "cp -r etc/* " ~ INSTALL_DIR ~ "/src/phobos/etc; " ~
                                    "cp LICENSE_1_0.TXT " ~ INSTALL_DIR ~ "/phobos-LICENSE.txt");
    return [install];
}

private Target[] jsonTargets() {
    auto jsonFile = Target("$project/phobos.json",
                           [DMD, dflags(BUILD, MODEL), "-o-", "-Xf$out", "$in"].join(" "),
                           sourcesToTargets!allDSources);
    return [Target.phony("json", "", [jsonFile])];
}

private Target[] fatTargets() {
    version(OSX) {
        // Build fat library that combines the 32 bit and the 64 bit libraries
        auto fat = [
            Target("libphobos2.a",
                   "lipo $in -create -output $out" ~
                   [Target(inGeneratedDir("release", "32", libphobos2.a)),
                    Target(inGeneratedDir("release", "64", libphobos2.a))])
        ];
    } else {
        Target[] fat; //nothing to see here
    }

    return fat;
}

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
                              [runtime(build, model)],
                              sourcesToTargets!allDSources);
    return [Target(path, cmd, dependencies)];
}

// D source files
alias allDSources = Sources!(["std", "etc"],
                          Files(),
                          Filter!(a => a.extension == ".d" && !a.canFind("linuxextern") && !a.canFind("test/uda.d")));

// the only difference between ALL_D_FILES (allDSources here) and D_MODULES (dSources)
// is the removal of the FreeBSD and OSX socket modules
alias dSources = Sources!(["std", "etc"],
                          Files(),
                          Filter!(a => a.extension == ".d"
                              && !a.canFind("linuxextern")
                              && !a.canFind("test/uda.d")
                              && !a.canFind("std/c/freebsd/socket")
                              && !a.canFind("std/c/osx/socket")));


private Target runtime(string build, string model) @safe {
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

private string staticRuntimeFileName(string build, string model) @safe {
    static if(CUSTOM_DRUNTIME) {
        return userVars["DRUNTIME"];
    } else {
        version(Windows)
            return DRUNTIME_PATH ~ "/lib/druntime.lib";
        else {
            import std.path;
            return buildPath(DRUNTIME_PATH, "generated", OS, build, model, "libdruntime.a");
        }
    }

}

private string dynamicRuntimeFileName(string build, string model) @safe {
    version(Windows)
        return "";
    else
        return stripExtension(DRUNTIME(build, model)) ~ ".so.a";
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


private Target[] dynamicPhobos(string build, string model)() {
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
                                  [runtime(build, model)],
                                  sourcesToTargets!allDSources);

        auto phobos = Target(patchName, cmd, dependencies);

        auto fstLink = Target(soName,
                              "ln -sf " ~ baseName(patchName) ~ " $out",
                              phobos);

        auto sndLink = Target(inGeneratedDir(build, model, "libphobos2.so"),
                              "ln -sf " ~ baseName(soName) ~ " $out",
                              fstLink);

        return [sndLink];
    }
}

private string inGeneratedDir(string build, string model, string fileName) {
    import std.path;
    return buildPath("$project", "generated", OS, build, model, fileName);
}


private auto /*Range!Target*/ unitTests(string build, string model)() {
    enum commonFlags = [dflags(build, model), "-defaultlib=", "-debuglib=", "-unittest"];

    static if(SHARED)
        enum compilerFlags = commonFlags ~ "-fPIC" ~ "-shared";
     else
        enum compilerFlags = commonFlags;

    alias dlangObjs = objectFiles!(dSources,
                                   Flags(compilerFlags.join(" ")));
    enum testRunnerBin = inGeneratedDir(build, model, buildPath("unittest", "test_runner"));
    enum testRunnerSrc = Target(buildPath(DRUNTIME_PATH, "src", "test_runner.d"));
    enum compilerCommand = ([DMD] ~ compilerFlags ~ ["-of$out", "$in"]).join(" ");
    auto dependencies = dlangObjs ~ cObjs!(build, model) ~ runtime(build, model);

    static if (SHARED) {
        // build shared unittest phobos library first
        enum libPath = inGeneratedDir(build, model, buildPath("unittest", "libphobos2-ut.so"));
        auto lib = Target(libPath, compilerCommand, dependencies);
        // build test_runner and link it to dynamic unittest phobos
        auto test_runner = Target(testRunnerBin,
                                  [DMD, dflags(build, model), "-defaultlib=", "-debuglib=", "-of$out", "-L" "$in"].join(" "),
                                  [lib] ~ testRunnerSrc);
    } else {
        // compile everything at once in unittest mode
        auto test_runner = Target(testRunnerBin, compilerCommand, [testRunnerSrc] ~ dependencies);
    }

    auto dModules = dlangObjs
        .map!(a => a.dependenciesInProjectPath(""))
        .join
        .map!relativePath
        .map!(a => a.replace("/", "."))
        .map!stripExtension
        ;

    enum QUIET = userVars.get("QUIET", "");
    auto TIMELIMIT = shell("which timelimit 2>/dev/null || true") != "" ? "timelimit -t 60" : "";
    return dModules.map!(a => Target.phony("unittest/" ~ a ~ ".run",
                                           QUIET ~ TIMELIMIT ~ " $in " ~ a,
                                           [test_runner]));
}


private auto htmlTargets() {
    static assert(d2html("std/conv.d") == "std_conv.html");
    static assert(d2html("std/range/package.d") == "std_range.html");

    auto outputDir = Target(DOC_OUTPUT_DIR, "mkdir -p $out");

    enum stdDoc = ["html.ddoc", "dlang.org.ddoc", "std_navbar-prerelease.ddoc",
                   "std.ddoc", "macros.ddoc", ".generated/modlist-prerelease.ddoc"].
        map!(a => buildPath(DOCSRC, a)).array;

    // For each module, define a rule e.g.:
    //  ../web/phobos/std_conv.html : std/conv.d $(STDDOC) ; ...
    auto htmls = sourceDocumentables
        .map!(a => Target(buildPath(DOC_OUTPUT_DIR, d2html(a)),
                          chain([DDOC, "project.ddoc"], stdDoc,  ["-Df$out", "$in"]).join(" "),
                          chain([Target(a)], stdDoc.map!(a => Target(a)))));
    auto styles = "STYLECSS_TGT" in userVars ? [Target(userVars["STYLECSS_TGT"])] : [];
    auto html = Target.phony("html", "", chain([outputDir], htmls, styles));

    enum bigStdDoc = ["std_consolidated.ddoc", "macros.ddoc"].map!(a => buildPath(DOCSRC, a)).array;

    auto bigHtmls = sourceDocumentables
        .map!(a => Target(buildPath(BIGDOC_OUTPUT_DIR, d2html(a)),
                          chain([DDOC, "project.ddoc"], bigStdDoc,  ["-Df$out", "$in"]).join(" "),
                          chain([Target(a)], stdDoc.map!(a => Target(a)))));

    string ddToHtmlCmd(string fileName) {
        return [DDOC, "-Df", DOCSRC ~ "/" ~ fileName ~ ".html", DOCSRC ~ "/" ~ fileName ~ ".dd"].join(" ");
    }
    auto consolidatedCmd = [ddToHtmlCmd("std_consolidated_header"),
                            ddToHtmlCmd("std_consolidated_footer"),
                            ["cat $in > $out"].join(" ")].join("; ");
    auto consolidatedDependencies = chain([Target(DOCSRC ~ "/std_consolidated_header.dd"),
                                           Target(DOCSRC ~ "/std_consolidated_footer.dd")],
                                          bigHtmls);

    auto html_consolidated = Target.phony("html_consolidated", consolidatedCmd, consolidatedDependencies);


    auto changelog_html = Target("changelog.html", DMD ~ " -Df$out $in", Target("changelog.dd"));

    return [html, html_consolidated, changelog_html];
}

// D file to html, e.g. std/conv.d -> std_conv.html
// But "package.d" is special cased: std/range/package.d -> std_range.html
private string d2html(string str) {
     str = str.baseName == "package.d" ? str.dirName : str.stripExtension;
     return str.replace("/", "_") ~ ".html";
}

private auto /*Range!string*/ sourceDocumentables() {

    return chain(["index.d"],
                 // these regex/internal modules are probably a mistake
                 ["std/regex/internal/backtracking.d",
                  "std/regex/internal/generator.d",
                  "std/regex/internal/ir.d",
                  "std/regex/internal/kickstart.d",
                  "std/regex/internal/parser.d",
                  "std/regex/internal/tests.d",
                  "std/regex/internal/thompson.d"],
                 sourcesToTargets!allDSources
                 .map!(a => a.expandOutputs("")[0])
                 .filter!(a => !a.canFind("internal"))
                 .filter!(a => !["std/c/freebsd/socket.d",
                                 "std/c/linux/pthread.d",
                                 "std/c/linux/termios.d",
                                 "std/c/linux/tipc.d",
                                 "std/c/osx/socket.d",
                                 "std/windows/registry.d"].canFind(a))
        );
}

private auto htmlDocumentables(string dir) {
    return sourceDocumentables.map!(a => buildPath(dir, d2html(a)));
}
