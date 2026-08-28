//! Every function plain `ring.exe` registers at startup — the names a bare
//! call can reach with NO load, NO loadlib and NO eval anywhere in sight.
//!
//! Extracted 2026-08-28 from Ring 1.27's own registration calls:
//!
//!     grep -rhoE 'RING_API_REGISTER\s*\(\s*"[^"]+"' language/src/*.c
//!
//! 258 names, all already lower-case in the source (verified — Ring folds
//! identifiers, F-18, so a case-insensitive caller still lands on these).
//! This is the CORE set only, deliberately: functions from stdlib.ring
//! arrive as ordinary definitions through `load` and are seen by the load
//! graph; functions from extensions arrive through loadlib, whose presence
//! suppresses the undefined-function rule entirely. Regenerate against a
//! newer Ring with the grep above; the count changing is the signal to look.

const std = @import("std");

pub const names = [_][]const u8{
    "acos", "add", "addattribute", "adddays", "addmethod", "ascii",
    "asin", "assert", "atan", "atan2", "attributes", "binarysearch",
    "bytes2double", "bytes2float", "bytes2int", "callgarbagecollector", "callgc", "ceil",
    "cfunctions", "char", "chdir", "checkoverflow", "classes", "classname",
    "clearerr", "clock", "clockspersecond", "closelib", "copy", "cos",
    "cosh", "currentdir", "date", "dec", "decimals", "del",
    "diffdays", "dir", "direxists", "double2bytes", "eval", "exefilename",
    "exefolder", "exp", "fabs", "fclose", "feof", "ferror",
    "fexists", "fflush", "fgetc", "fgetpos", "fgets", "filename",
    "find", "float2bytes", "floor", "fopen", "fputc", "fputs",
    "fread", "freopen", "fseek", "fsetpos", "ftell", "functions",
    "fwrite", "getarch", "getattribute", "getchar", "getfilesize", "getnumber",
    "getpathtype", "getpointer", "getptr", "getstring", "globals", "hex",
    "hex2str", "importpackage", "input", "insert", "int2bytes", "intvalue",
    "isalnum", "isalpha", "isandroid", "isattribute", "iscfunction", "isclass",
    "iscntrl", "isdigit", "isfreebsd", "isfunction", "isglobal", "isgraph",
    "islinux", "islist", "islocal", "islower", "ismacosx", "ismethod",
    "ismsdos", "isnull", "isnumber", "isobject", "ispackage", "ispackageclass",
    "ispointer", "isprint", "isprivateattribute", "isprivatemethod", "ispunct", "isspace",
    "isstring", "isunix", "isupper", "iswindows", "iswindows64", "isxdigit",
    "left", "len", "lines", "list", "list2str", "loadlib",
    "locals", "log", "log10", "lower", "max", "memcpy",
    "memorycopy", "mergemethods", "methods", "min", "murmur3hash", "newlist",
    "nofprocessors", "nothing", "nullpointer", "nullptr", "number", "obj2ptr",
    "object2pointer", "objectid", "optionalfunc", "packageclasses", "packagename", "packages",
    "parentclassname", "perror", "pointer2object", "pointer2string", "pointercompare", "pow",
    "prevfilename", "print", "print2str", "ptr2obj", "ptr2str", "ptrcmp",
    "puts", "raise", "random", "randomize", "read", "ref",
    "refcount", "reference", "remove", "rename", "reverse", "rewind",
    "right", "ring_give", "ring_see", "ring_state_delete", "ring_state_filetokens", "ring_state_findvar",
    "ring_state_init", "ring_state_main", "ring_state_mainfile", "ring_state_new", "ring_state_newvar", "ring_state_resume",
    "ring_state_runcode", "ring_state_runcodeatins", "ring_state_runfile", "ring_state_runobjectfile", "ring_state_scannererror", "ring_state_setvar",
    "ring_state_stringtokens", "ringvm_callfunc", "ringvm_calllist", "ringvm_cfunctionslist", "ringvm_classeslist", "ringvm_codelist",
    "ringvm_evalinscope", "ringvm_fileslist", "ringvm_functionslist", "ringvm_genarray", "ringvm_give", "ringvm_hideerrormsg",
    "ringvm_info", "ringvm_ismempool", "ringvm_memorylist", "ringvm_packageslist", "ringvm_passerror", "ringvm_ringolists",
    "ringvm_runcode", "ringvm_scopescount", "ringvm_see", "ringvm_settrace", "ringvm_tracedata", "ringvm_traceevent",
    "ringvm_tracefunc", "ringvm_translatecfunction", "ringvm_writeringo", "setattribute", "setpointer", "setptr",
    "shutdown", "sin", "sinh", "sort", "space", "sqrt",
    "srandom", "str2hex", "str2hexcstyle", "str2list", "strcmp", "string",
    "substr", "swap", "sysget", "sysset", "syssleep", "system",
    "sysunset", "tan", "tanh", "tempfile", "tempname", "time",
    "timelist", "trim", "type", "ungetc", "unsigned", "upper",
    "uptime", "variablepointer", "varptr", "version", "windowsnl", "write",
};

/// `lowname` must already be lower-cased, which is how every caller in
/// types.zig holds names.
pub fn isBuiltin(lowname: []const u8) bool {
    // 258 entries: linear scan is ~microseconds and runs once per UNRESOLVED
    // call, which a healthy file has none of. Not worth a hash table.
    for (names) |n| {
        if (std.mem.eql(u8, n, lowname)) return true;
    }
    return false;
}

test "spot checks against Ring 1.27" {
    try std.testing.expect(isBuiltin("len"));
    try std.testing.expect(isBuiltin("substr"));
    try std.testing.expect(isBuiltin("ringvm_genarray"));
    try std.testing.expect(!isBuiltin("sysargv")); // a VARIABLE, not a function
    try std.testing.expect(!isBuiltin("nosuchfn"));
}
