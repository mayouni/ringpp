//! `ringpp why <thing>` — the long form behind a short message.
//!
//! `ringpp check` has room for one line and one paragraph. That is enough to
//! act on and not enough to *understand*, and understanding is the point: a
//! programmer who is told "this leaks a VM stack slot" and nothing else has
//! been given a rule to obey rather than a fact about the machine.
//!
//! So `why` answers three kinds of question with one command:
//!
//!   ringpp why rpp/empty-catch     a rule `check` just printed
//!   ringpp why F-16                a FINDINGS entry
//!   ringpp why R4                  the Ring error code you actually saw
//!
//! The third is the one that earns the command. Ring reports `Error (R6)`,
//! `Error (R20)`, `Error (R4)` — codes that say nothing about the cause, on
//! code that contains no recursion and no obvious mistake. Every one of them
//! cost a day here before it was understood.
//!
//! **Every field below is grounded.** `evidence` names a program in `bench/`
//! that produces the number, and `hurts` names the pattern the fix makes
//! worse — because a fix with no stated cost has not been measured, it has
//! been believed. The tests at the bottom enforce both halves of that: no
//! rule `check` can emit may be missing here, and no citation may point at a
//! FINDINGS heading that does not exist.

const std = @import("std");

pub const Entry = struct {
    /// the rule id `check` prints, or "" for an entry reachable only by
    /// finding id / error code
    rule: []const u8 = "",
    /// FINDINGS ids, in citation order
    findings: []const []const u8,
    /// Ring error codes this explains — the user's actual starting point
    codes: []const []const u8 = &.{},
    title: []const u8,
    symptom: []const u8,
    cause: []const u8,
    fix: []const u8,
    /// a program under bench/ or tests/ that produces the numbers
    evidence: []const u8,
    /// the pattern this fix makes worse. Empty only where there is none.
    hurts: []const u8 = "",
    /// upstream state, where there is any
    upstream: []const u8 = "",
};

pub const catalog = [_]Entry{
    .{
        .rule = "rpp/memcpy-string-dest",
        .findings = &.{ "F-1", "F-5" },
        .title = "memcpy() into a Ring string writes a copy and throws it away",
        .symptom = "The call returns normally, raises nothing, and the string is unchanged.",
        .cause = "RING_VM_STACK_PUSHCVAR (vm.h:230) byte-copies a string argument onto the VM stack. " ++
            "memcpy() therefore receives the address of a temporary that dies when the call returns. " ++
            "This is the one asymmetry the whole of Ring++ is built around: lists cross a call boundary " ++
            "by reference, strings cross by copy.",
        .fix = "Write through a pointer to the variable, not through the variable: " ++
            "memcpy(varptr(:name, \"char *\"), src, n). varptr resolves the name in the live frame, " ++
            "so the write lands on the original bytes.",
        .evidence = "bench/07_by_value_tax.ring — the copy costs ~2,200x a pointer write at 1 MB",
        .hurts = "Nothing, below the crossover. Above it the pointer route is strictly better; " ++
            "below ~512 bytes the varptr call (~790 ns) costs more than the copy it avoids, " ++
            "which is why RPP_MEMCPY_CROSSOVER exists rather than a blanket rule.",
    },
    .{
        .rule = "rpp/varptr-unknown-name",
        .findings = &.{ "F-2", "F-3" },
        .codes = &.{"R6"},
        .title = "varptr() takes a name resolved at run time, and an unknown name raises R6",
        .symptom = "Error (R6) : Variable is not a pointer — or, far worse, nothing at all, " ++
            "because a surrounding try/catch swallowed it and left a NULL pointer behind.",
        .cause = "varptr is not a compile-time operator. It looks the name up in the current scope " ++
            "and then in globals, at the moment of the call. A typo, a renamed attribute, or a " ++
            "variable that is only assigned on some paths all reach the same failure. On Ring " ++
            "1.27 there is a second cause: a name passed as a STRING must already be lower case. " ++
            "varptr(\"nTotal\") raises R6 while varptr(\"ntotal\") succeeds, for a variable that " ++
            "plainly exists. The :nTotal symbol form is unaffected — the scanner folds it. Fixed " ++
            "upstream on 2026-08-14, in varptr and three ring_state_* functions.",
        .fix = "Assign the variable before taking its address. Inside a class the attribute name " ++
            "carries its own sigil: varptr(\"@buffer\", \"char *\"), not varptr(:buffer, ...). " ++
            "If you build the name as a string, lower-case it first — correct on every version, " ++
            "since folding an already-folded name is a no-op.",
        .evidence = "bench/11_varptr_scope.ring; the case behaviour re-measured on 1.27 for F-3",
        .hurts = "This rule matches names case-insensitively, so it will NOT fire on " ++
            "varptr(\"cData\") in a file that assigns cData — which still raises R6 on 1.27. " ++
            "That false negative is deliberate: the case bug is fixed upstream and occurs exactly " ++
            "once across Softanza and Ring's own corpus, so a rule for it would cost more in " ++
            "noise than it returns.",
    },
    .{
        .rule = "rpp/varptr-in-loop",
        .findings = &.{"F-4"},
        .title = "varptr() costs ~790 ns — 12x an ordinary function call",
        .symptom = "A loop that looks like pointer code runs at name-lookup speed.",
        .cause = "Each call does a scope walk for the name and then builds a three-item Ring list " ++
            "to carry the C pointer. Both costs are per call. nullptr() is worse at ~520 ns for " ++
            "the same reason — it allocates a fresh list every time.",
        .fix = "Take the address once, outside the loop, and reuse it. That is exactly what " ++
            "RppBuffer's pScratch attribute is for.",
        .evidence = "bench/02_unit_costs.ring — 300,000 iterations, loop baseline subtracted",
        .hurts = "Caching an address is what makes F-22 possible: an object that caches a pointer " ++
            "to its own memory dangles the moment the object is copied, and Ring copies objects " ++
            "on assignment and on list insertion. Hoist out of the loop; do not hoist into an " ++
            "attribute unless the object can never be copied.",
    },
    .{
        .rule = "rpp/memcpy-nul-source",
        .findings = &.{"F-14"},
        .title = "memcpy() kills the process when the source string starts with a zero byte",
        .symptom = "The process vanishes. No error, no stack trace, no exit message, and " ++
            "try/catch cannot trap it.",
        .cause = "ring_vm_api_ispointer() uses strcmp() to test whether a string argument is the " ++
            "literal \"NULL\". Binary data whose first byte is 0 compares equal to the empty " ++
            "string on that path and is then treated as a NULL pointer. int2bytes(0), " ++
            "double2bytes() of a small number, and most packed binary all produce it.",
        .fix = "Pass the source as a pointer rather than as a string: " ++
            "setptr(pSrc, getptr(varptr(:cBytes, \"char *\"))) then memcpy(dst, pSrc, n). " ++
            "RppBuffer.Poke takes this route only for a leading-NUL or a literal \"NULL\", " ++
            "so the common case stays on the fast path.",
        .evidence = "bench/15_memcpy_nul_source.ring — four classes of string argument, exhaustive",
        .hurts = "The pointer route costs one extra setptr/getptr pair per call. Measured at " ++
            "~0.15 us, against a fatal crash — but it is why the guard is a branch on the first " ++
            "byte rather than an unconditional detour.",
        .upstream = "ring-lang/ring#1643 — closed unmerged, \"will revise/fix using PWCT\"",
    },
    .{
        .rule = "rpp/empty-catch",
        .findings = &.{"F-16"},
        .codes = &.{"R4"},
        .title = "An empty catch block leaks one VM stack slot per caught error",
        .symptom = "Error (R4) : Stack Overflow, from code containing no recursion at all. " ++
            "It arrives after roughly 1,003 caught errors, so it survives every small test and " ++
            "fails in the loop that runs all day.",
        .cause = "Ring pops the raised value only when something in the handler consumes it. " ++
            "An empty handler leaves it on the VM stack, which is RING_VM_STACK_SIZE (1004) deep.",
        .fix = "Put any statement in the handler. One assignment is enough. If the intent really " ++
            "is to ignore the error, ignore it explicitly: catch  bIgnored = TRUE  done.",
        .evidence = "bench/16_empty_catch_leak.ring — five arms, showing exactly which shape leaks",
        .hurts = "",
        .upstream = "ring-lang/ring#1644 — open. Reported as a behaviour, not a patch: " ++
            "ring_vm_catch() does restore nSP via ring_vm_restorestate(), and what puts the " ++
            "slot back was not isolated. Reporting beats guessing at a line.",
    },
    .{
        .rule = "rpp/method-shadows-builtin",
        .findings = &.{"F-17"},
        .codes = &.{"R20"},
        .title = "Inside a class, an unqualified call finds a method before the builtin",
        .symptom = "Error (R20) : Calling function with extra number of parameters — naming " ++
            "neither the method that was found nor the builtin that was meant.",
        .cause = "Method lookup precedes builtin lookup for an unqualified call in a class body. " ++
            "A method named Len, Copy or Find is legal and useful on its own; it only bites at " ++
            "the call site where the builtin was intended, and only when the arities differ. " ++
            "Equal arities fail silently instead, which is worse.",
        .fix = "Rename the method — RppBuffer's Len became Size for this reason — or qualify " ++
            "the call so the builtin is unambiguous.",
        .evidence = "tests/idioms.ring; the rule fires on an arity clash only, which cut 13 " ++
            "noisy hits to 11 real ones across 5,890 files",
        .hurts = "The arity test is what keeps the rule usable, and it is also what makes it " ++
            "incomplete: a same-arity shadow is invisible to this check. It is not a proof.",
        .upstream = "Deliberately not sent. Language design, not a defect.",
    },
    .{
        .rule = "rpp/substr-in-loop",
        .findings = &.{ "F-6", "F-8" },
        .title = "substr() copies the whole string before taking the slice",
        .symptom = "A slicing loop whose cost grows with the size of the string being sliced, " ++
            "not with the size of the slice.",
        .cause = "The string argument is copied onto the VM stack before substr sees it — the " ++
            "same F-1 asymmetry. The slice is then cheap and the copy is not.",
        .fix = "Hold the address once and read through it: ptr2str(pBase, nOff, nLen) is " ++
            "~0.09 us regardless of the string's size, against 12.5 us for substr on a 500 KB " ++
            "string.",
        .evidence = "bench/08_string_ops_tax.ring — minima over 7 repetitions",
        .hurts = "ptr2str gives no bounds check whatsoever: an offset past the end reads " ++
            "adjacent heap and returns it as data, with no error. Below a few KB substr is both " ++
            "faster in practice and safe, which is why this is a perf note and not an error.",
    },
    .{
        .rule = "rpp/genarray-in-loop",
        .findings = &.{ "F-9", "F-10", "F-19" },
        .title = "ringvm_genarray() pays for itself only when reads outnumber mutations",
        .symptom = "An index that was supposed to speed the loop up makes it up to 16x slower.",
        .cause = "genarray allocates an n-pointer array for O(1) access. Every structural " ++
            "mutation calls ring_list_clearcache_gc, which frees it — so a single append inside " ++
            "the loop rebuilds it on the next read, every round. This was Mahmoud's objection, " ++
            "and measuring it proved him right.",
        .fix = "Open the index after the mutations, not around them. RppIndexed is a phase " ++
            "object for exactly this reason: it refuses lists below RPP_INDEX_MIN_SIZE, and its " ++
            "Release() reports whether the list changed size during the phase.",
        .evidence = "bench/04_genarray_breakeven.ring and bench/17_list_build_shape.ring",
        .hurts = "Write-heavy code, by 10-16x. The break-even is roughly 10-20 random reads per " ++
            "mutation, on this machine — a provisional constant, not a law. F-19 corrects the " ++
            "earlier F-9/F-12 numbers: how a list was *built* decides its random-access cost, " ++
            "and two measurement traps made the first figures wrong. F-23 goes further — on a " ++
            "VM patched to generate the array itself, this advice is simply moot.",
    },
    .{
        .rule = "rpp/unparsed",
        .findings = &.{},
        .codes = &.{"C27"},
        .title = "The vendored grammar stopped here, so no rules were applied to this file",
        .symptom = "A note, never an error, and never a claim that your code is wrong.",
        .cause = "tree-sitter is a lens, not a judge (DESIGN_TOOLCHAIN section 5). The grammar " ++
            "is a third-party artefact that can lag Ring; when it disagrees with Ring, the " ++
            "grammar is the more likely to be wrong. Reporting \"your file is invalid\" on that " ++
            "basis would be a false positive on correct code — the one failure a linter must " ++
            "not have.",
        .fix = "Run `ring <file> -norun` to find out which side is wrong. If Ring accepts the " ++
            "file, this is a grammar bug for us to fix, not a problem with your code.",
        .evidence = "measured disagreement rate ~0.16% — 9 files of 5,566 across Softanza and " ++
            "Ring's own corpus, every disagreement adjudicated by ring -norun",
        .hurts = "Coverage. A file that does not parse is a file with no checking at all, and " ++
            "the note is the only thing that says so. Silence would read as a clean bill.",
        .upstream = "ysdragon/tree-sitter-ring#2 — open",
    },

    .{
        .rule = "rpp/type-hints-missing",
        .findings = &.{"F-24"},
        .codes = &.{"R24"},
        .title = "A return annotation is a variable read, and needs typehints.ring",
        .symptom = "Error (R24) : Using uninitialized variable: int — reported on a line " ++
            "that looks like a declaration, not like code.",
        .cause = "The two halves of an annotation are different mechanisms. In " ++
            "func Sum(int x, int y) the parameter types are a parser feature: stmt.c:1217 " ++
            "accepts and drops them, no library involved. In int func Sum(...) the return " ++
            "type is an ordinary expression statement reading a global named 'int', which " ++
            "only typehints.ring defines. load \"stdlib.ring\" does not supply it.",
        .fix = "Add load \"typehints.ring\", or drop the return annotation. Parameter " ++
            "annotations can stay either way — they cost nothing and need nothing.",
        .evidence = "bench/12_typehints_channel.ring, and the probes rerun for T2",
        .hurts = "Nothing at run time. The check is narrowed to Ring's fixed hint " ++
            "vocabulary, so 'MyClass func Foo' — also a variable read, also R24 without " ++
            "the library — is not reported. That is deliberate: Ring's one-line class form " ++
            "puts an attribute in the same position, and the first version reported R24 on " ++
            "correct code in Ring's own samples.",
        .upstream = "Deliberately not sent. Ring behaves as documented; the finding is " ++
            "that the two halves have different requirements.",
    },
    .{
        .rule = "rpp/type-arity",
        .findings = &.{"F-24"},
        .codes = &.{ "R19", "R20" },
        .title = "Ring does not check types, but it does check argument count — exactly",
        .symptom = "Error (R19) : Calling function with less number of parameters, or " ++
            "R20 with extra. Dormant until the path is first exercised, which is why it " ++
            "survives every test and fails in production.",
        .cause = "Ring has no default parameters and no overloading, so the count is exact " ++
            "and decidable from the source. This is the one thing about a call that a " ++
            "static checker can call an error rather than a warning.",
        .fix = "Match the definition. The usual shape is an alias that forgot to forward " ++
            "its parameter: func @IsContinuous() return IsContiguous() — where " ++
            "IsContiguous takes paList.",
        .evidence = "99 call sites in 46 functions across Softanza's 5,949 files, one " ++
            "across Ring's own 1,959 — all dormant; one confirmed end to end by running " ++
            "it, at stzListFunc.ring:7574",
        .hurts = "Coverage, in two places, both to stay certain. Calls inside a class body " ++
            "are not checked at all — an unqualified call there finds a method first " ++
            "(F-17) — and functions defined after the first class are not registered, " ++
            "because they are methods (F-21).",
    },
    .{
        .rule = "rpp/type-arg-mismatch",
        .findings = &.{"F-24"},
        .title = "A literal argument that contradicts the parameter's declared type",
        .symptom = "Nothing at run time. The call succeeds and the operators inside " ++
            "behave as the value's real type — Sum(\"a\",\"b\") on 'int x, int y' returns " ++
            "\"ab\", not 3.",
        .cause = "Parameter annotations are parsed and discarded. Ring never checks them, " ++
            "so the annotation is documentation that the compiler cannot keep honest. " ++
            "That is what level 1 checking is for (DESIGN_TOOLCHAIN section 3).",
        .fix = "Correct the call, or the annotation — whichever is lying.",
        .evidence = "verified against Ring 1.27 directly: the call runs and concatenates",
        .hurts = "Only literals are judged. A variable or an expression argument is left " ++
            "alone, because Ring is dynamically typed and its type at that point is " ++
            "genuinely unknown. Inference would find more and would also be wrong " ++
            "sometimes, which is a worse trade for a linter.",
    },
    .{
        .rule = "rpp/type-return-mismatch",
        .findings = &.{"F-24"},
        .title = "A returned literal that contradicts the declared return type",
        .symptom = "Nothing at run time. The function returns the literal, and the next " ++
            "reader believes the annotation.",
        .cause = "Same as the argument case: nothing is enforced, so the annotation and " ++
            "the code can disagree indefinitely.",
        .fix = "Correct whichever is wrong.",
        .evidence = "tests in src/types.zig, checked against Ring's actual behaviour",
        .hurts = "Only literal returns are judged, for the same reason as above.",
    },
    .{
        .rule = "rpp/type-not-a-hint",
        .findings = &.{"F-24"},
        .title = "That name is not in Ring's type-hint vocabulary",
        .symptom = "As a parameter type, nothing — it is parsed and discarded. As a " ++
            "return type it is Error (R24).",
        .cause = "The vocabulary is fixed by libraries/typehints/typehints.ring: char, " ++
            "unsigned, signed, int, short, long, float, double, void, byte, boolean, " ++
            "string, list, number, object. Note boolean, not bool — DESIGN_TOOLCHAIN " ++
            "section 3 itself writes bool, which is how this rule came to exist.",
        .fix = "Use the Ring name, or leave the parameter unannotated.",
        .evidence = "libraries/typehints/typehints.ring, read verbatim",
        .hurts = "It fires only on a short fixed list of near-misses, never on an " ++
            "unrecognised name in general — because typehints.ring also registers every " ++
            "class as a type, and the class may live in a file this run was not given. " ++
            "Reporting those would be a false-positive flood.",
    },

    // Not rules. Reachable by finding id or error code, because they are what
    // someone actually hits at 2am with only a code to search for.
    .{
        .rule = "",
        .findings = &.{"F-22"},
        .title = "Ring copies objects on assignment — a cached address inside one dangles",
        .symptom = "The process vanishes with no message, intermittently, long after the write " ++
            "that caused it. Or a view reads a snapshot and silently misses later writes.",
        .cause = "Objects are lists, and adding a list to a list copies it. aBufs + RppBuffer(64), " ++
            "oBuf = oOther and @aBuffers + [cId, oBuffer] all store a copy. If the object cached " ++
            "a pointer to its own memory in init(), the copy carries the *original's* address — " ++
            "and the original was a temporary that has died.",
        .fix = "In a class that owns memory, do not cache the address at all: re-derive it with " ++
            "varptr (~0.8 us) so a copy resolves its own attribute. Where a genuine reference is " ++
            "wanted, ref() is required and load-bearing: oBuf = ref(oBuffer).",
        .evidence = "tests/fuzz_bounds.ring — it survived 100,000 accesses before the allocator " ++
            "happened to reuse the block",
        .hurts = "Re-deriving costs a varptr per access: RppBuffer.Poke went from 5.8x to 6x raw " ++
            "memcpy. Still 66x faster than pure Ring on the patch case. Cheap, and correct by " ++
            "construction.",
        .upstream = "Deliberately not sent. Ring documents this in usingref.txt lines 35-36, " ++
            "and documents ref() as the remedy. The bug was mine, and it was not reading the " ++
            "chapter.",
    },
    .{
        .rule = "",
        .findings = &.{"F-21"},
        .title = "Every func after the first class becomes a method of that class",
        .symptom = "Calling Function without definition — for a function that is plainly " ++
            "defined, a few lines further down the file.",
        .cause = "Ring's file structure is positional. Once a class body opens, every subsequent " ++
            "func belongs to it.",
        .fix = "All functions before all classes. rpp/idioms.ring says so in its header for this " ++
            "reason.",
        .evidence = "rpp/idioms.ring — the restructuring that fixed it",
        .upstream = "Deliberately not sent. Documented file structure.",
    },
    .{
        .rule = "",
        .findings = &.{"F-18"},
        .title = "N and n are the same variable",
        .symptom = "A loop that runs zero times while reporting a clean pass.",
        .cause = "Ring identifiers are case-insensitive. A local n and a loop bound N are one " ++
            "variable, and the assignment that looked independent was not.",
        .fix = "Name them apart — nIters and nSz, not N and n. This is what the fuzz harness " ++
            "does now.",
        .evidence = "tests/fuzz_bounds.ring",
        .upstream = "Deliberately not sent. Documented case-insensitivity.",
    },
    .{
        .rule = "",
        .findings = &.{"F-20"},
        .title = "get and put cannot be method names",
        .symptom = "A syntax error at the method definition, not at the call.",
        .cause = "get and put are keywords and are not demotable to identifiers the way many " ++
            "Ring keywords are.",
        .fix = "RppSandbox uses Var() and SetVar() for this reason.",
        .evidence = "rpp/idioms.ring",
        .upstream = "Deliberately not sent. Documented keywords.",
    },
    .{
        .rule = "",
        .findings = &.{"F-23"},
        .title = "A gate that asserts a mechanism fails when someone fixes the problem properly",
        .symptom = "tests/idioms.ring failed on the *patched* VM and passed on the stock one.",
        .cause = "RppIndexed exists because random list access walks the linked list (F-19). " ++
            "RingScript's rlist.c patch calls ring_list_genarray_gc on random access, so the VM " ++
            "does from C what the idiom does from Ring: 467 ms baseline on stock against 4 ms " ++
            "there, and nothing left for the idiom to buy.",
        .fix = "Gate the outcome, not the mechanism. The test now asserts that a permuted pass " ++
            "over 20,000 rows is not quadratic, and accepts either route to it.",
        .evidence = "zig build conformance — docs/MATRIX.md, first two-row run",
        .hurts = "Nothing measurable. It is a warning about the shape of assertions: the layer " ++
            "above Ring cannot assume the layer below stayed still.",
    },
};

/// Ring error codes carry no cause, so this is often the only handle a user
/// has. Kept as its own lookup rather than folded into the rule ids because
/// the code is what they *saw*.
fn matchesCode(e: Entry, q: []const u8) bool {
    for (e.codes) |c| if (std.ascii.eqlIgnoreCase(c, q)) return true;
    return false;
}

fn matchesFinding(e: Entry, q: []const u8) bool {
    for (e.findings) |f| if (std.ascii.eqlIgnoreCase(f, q)) return true;
    return false;
}

fn matchesRule(e: Entry, q: []const u8) bool {
    if (e.rule.len == 0) return false;
    if (std.ascii.eqlIgnoreCase(e.rule, q)) return true;
    // accept the bare form: `why empty-catch` as well as `why rpp/empty-catch`
    if (std.mem.startsWith(u8, e.rule, "rpp/")) {
        return std.ascii.eqlIgnoreCase(e.rule["rpp/".len..], q);
    }
    return false;
}

pub fn run(w: anytype, query: ?[]const u8) !u8 {
    const q = query orelse {
        try list(w);
        return 0;
    };

    var hits: usize = 0;
    for (catalog) |e| {
        if (matchesRule(e, q) or matchesFinding(e, q) or matchesCode(e, q)) {
            if (hits > 0) try w.print("\n", .{});
            try print(w, e);
            hits += 1;
        }
    }
    if (hits > 0) return 0;

    // `ringpp why <function>` — "why is this function not compiled" — is the
    // other half of this command, specified in docs/CLI.md and arriving with
    // T4. Until there is a compiler to report on, say so plainly rather than
    // pretending the name was a typo.
    if (looksLikeIdentifier(q)) {
        try w.print("ringpp why: '{s}' is not a rule, a finding, or a Ring error code.\n\n", .{q});
        try w.print("If you meant \"why is this function not compiled\" — that half of\n", .{});
        try w.print("`why` needs the compiler, and arrives with T4 (docs/CLI.md).\n", .{});
        try w.print("Today `why` explains diagnostics; `ringpp why` lists what it knows.\n", .{});
        return 1;
    }

    try w.print("ringpp why: nothing known about '{s}'\n\n", .{q});
    try w.print("Ask by rule (rpp/empty-catch), by finding (F-16), or by the Ring\n", .{});
    try w.print("error code you actually saw (R4). `ringpp why` alone lists them all.\n", .{});
    return 1;
}

/// A bare Ring identifier: no separator, no leading digit, not `X-12`.
fn looksLikeIdentifier(q: []const u8) bool {
    if (q.len == 0) return false;
    if (!std.ascii.isAlphabetic(q[0])) return false;
    for (q) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    // R4 / R20 / C27 are a letter then digits — those are error codes, and an
    // unknown one should say "nothing known", not offer to compile it.
    var digits_only_after_first = q.len > 1;
    for (q[1..]) |c| {
        if (!std.ascii.isDigit(c)) digits_only_after_first = false;
    }
    return !digits_only_after_first;
}

fn print(w: anytype, e: Entry) !void {
    // header: what you asked about, and every other handle onto it
    if (e.rule.len > 0) {
        try w.print("{s}\n", .{e.rule});
    } else {
        try w.print("{s}\n", .{e.findings[0]});
    }
    try w.print("{s}\n\n", .{e.title});

    try field(w, "Symptom", e.symptom);
    try field(w, "Cause", e.cause);
    try field(w, "Fix", e.fix);
    try field(w, "Evidence", e.evidence);
    if (e.hurts.len > 0) try field(w, "Cost", e.hurts);
    if (e.upstream.len > 0) try field(w, "Upstream", e.upstream);

    // the citations last, so they read as where-to-go-next
    if (e.findings.len > 0) {
        var ids: [128]u8 = undefined;
        var n: usize = 0;
        for (e.findings, 0..) |f, i| {
            if (i > 0) {
                @memcpy(ids[n..][0..2], ", ");
                n += 2;
            }
            @memcpy(ids[n..][0..f.len], f);
            n += f.len;
        }
        // a separate buffer: formatting into the one being read is aliasing
        var line: [192]u8 = undefined;
        try field(w, "See", try std.fmt.bufPrint(&line, "docs/FINDINGS.md {s}", .{ids[0..n]}));
    }
}

// The longest label ("Evidence", "Upstream") is 8 characters, so the pad must
// be 9 or the label runs into its own text.
const label_pad = 9;
const label_w = 2 + label_pad;
const wrap_w = 68;

fn field(w: anytype, name: []const u8, text: []const u8) !void {
    try w.print("  {s: <[1]}", .{ name, label_pad });
    var it = std.mem.tokenizeAny(u8, text, " \n\r\t");
    var col: usize = 0;
    var first = true;
    while (it.next()) |word| {
        if (!first and col + word.len + 1 > wrap_w) {
            try w.print("\n", .{});
            for (0..label_w) |_| try w.print(" ", .{});
            col = 0;
        } else if (!first) {
            try w.print(" ", .{});
            col += 1;
        }
        try w.print("{s}", .{word});
        col += word.len;
        first = false;
    }
    try w.print("\n\n", .{});
}

fn list(w: anytype) !void {
    try w.print("ringpp why <rule | finding | Ring error code>\n\n", .{});
    try w.print("Rules that `ringpp check` can print:\n\n", .{});
    for (catalog) |e| {
        if (e.rule.len == 0) continue;
        try w.print("  {s: <28}", .{e.rule});
        try printHandles(w, e);
    }
    try w.print("\nAlso explained — traps with no rule, because a linter cannot see them:\n\n", .{});
    for (catalog) |e| {
        if (e.rule.len > 0) continue;
        // a finding id alone tells you nothing about whether to open it
        try w.print("  {s: <10}{s}\n", .{ e.findings[0], truncate(e.title, 62) });
    }
    try w.print("\nExample:  ringpp why R4\n", .{});
}

/// Cut on a word boundary — a title chopped mid-word reads as corruption.
fn truncate(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var cut = max;
    while (cut > 0 and s[cut] != ' ') cut -= 1;
    return s[0..if (cut == 0) max else cut];
}

fn printHandles(w: anytype, e: Entry) !void {
    var shown = false;
    for (e.codes) |c| {
        try w.print("{s}{s}", .{ if (shown) ", " else "", c });
        shown = true;
    }
    for (e.findings) |f| {
        try w.print("{s}{s}", .{ if (shown) ", " else "", f });
        shown = true;
    }
    if (!shown) try w.print("(no other handle)", .{});
    try w.print("\n", .{});
}

// ---------------------------------------------------------------------------
// The tests are the reason this file can be trusted. Without them the catalog
// is a pile of prose that drifts away from both the checker and the findings
// document, and nobody notices until a citation points at nothing.

test "every rule the checker can emit has an entry here" {
    // Both rule-bearing modules. Adding a third and forgetting to list it
    // here would quietly reopen the drift this test exists to close, so the
    // count assertion at the end is a second line of defence.
    const sources = [_][]const u8{ @embedFile("check.zig"), @embedFile("types.zig") };
    var found: usize = 0;
    for (sources) |src| {
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, src, i, "\"rpp/")) |p| {
            const rest = src[p + 1 ..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse break;
            const rule = rest[0..end];
            i = p + 1 + end;
            found += 1;

            var ok = false;
            for (catalog) |e| {
                if (std.mem.eql(u8, e.rule, rule)) ok = true;
            }
            if (!ok) {
                std.debug.print("no `ringpp why` entry for rule: {s}\n", .{rule});
                return error.MissingWhyEntry;
            }
        }
    }
    try std.testing.expect(found >= 14);
}

test "every finding cited here exists as a heading in FINDINGS.md" {
    const doc = @embedFile("findings_md");
    for (catalog) |e| {
        for (e.findings) |f| {
            var buf: [32]u8 = undefined;
            const heading = try std.fmt.bufPrint(&buf, "### {s}.", .{f});
            if (std.mem.indexOf(u8, doc, heading) == null) {
                std.debug.print("citation points at no heading: {s}\n", .{f});
                return error.DanglingCitation;
            }
        }
    }
}

test "every entry is reachable by at least one query" {
    for (catalog) |e| {
        const reachable = e.rule.len > 0 or e.findings.len > 0 or e.codes.len > 0;
        try std.testing.expect(reachable);
    }
}

test "lookup accepts the bare rule form and is case-insensitive" {
    var hit = false;
    for (catalog) |e| {
        if (matchesRule(e, "empty-catch")) hit = true;
    }
    try std.testing.expect(hit);

    hit = false;
    for (catalog) |e| {
        if (matchesFinding(e, "f-16")) hit = true;
    }
    try std.testing.expect(hit);

    hit = false;
    for (catalog) |e| {
        if (matchesCode(e, "r4")) hit = true;
    }
    try std.testing.expect(hit);
}
