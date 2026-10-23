r"""Build Softanza's engine domains against Ring++'s backend of the engine
boundary -- from a COPY of the engine sources, never Mansour's tree.

    python bench/engine_copy.py                       copy + patch, all portable domains
    python bench/engine_copy.py stz_string stz_list   copy + patch these
    python bench/engine_copy.py --oracle              the engine the ORACLE hosts
                                                      (runtime/engine-oracle)
    python bench/engine_copy.py --official            his own build, to validate an
                                                      engine change on official Ring
    python bench/engine_copy.py --src=D:\GitHub\_wts\libraries\stzlib\engine --dst=runtime\engine-sec stz_string ...
                                                      another engine tree, beside the clock copy
    ONLY=stz_string,stz_list zig build -j2          (in the copy)

BUILD WITH HIS DEFAULT, ReleaseSafe -- no -Doptimize (2026-10-03). His
build.zig makes ReleaseSafe the default on purpose ("a clean panic beats
silent memory corruption"), every DLL in his tree is built so, and the
oracle hosts those. The copies were built ReleaseFast until then, so the two
sides of every comparison ran two different builds of the engine.
Interleaved, minima of five, ReleaseSafe costs whole tests x1.01-x1.08
(engine_millions 1.61 -> 1.72 s); the pattern that pays is a loop of
engine calls. Six batches at -j2, about 12 minutes cold.

What it does:
  1. libraries/stzlib/engine/ -> runtime/engine-copy (gitignored output),
     without zig-out and .zig-cache
  2. src/ring_api.zig := bench/ring_api_rpp.zig -- the second backend; it
     exports the same 37 names, so NO bridge file changes
  3. every listed domain's entry file gains rpp_init / rpp_abi_version,
     which hand the bridge's own table to the same registerAll through the
     entry's ringlib_init; two shapes of entry exist (an @export of the
     bridge's ringlib_init, or a local fn ringlib_init) and both are patched
  4. build.zig: the domain loops build only the names in the ONLY
     environment variable (comma-separated), so batches share one cache;
     addRing is a no-op (nothing references Ring's C API, and a sovereign
     build must not reach for ring.lib); three installs outside the loops
     (a sound studio, a combined static library, a data generator) are off.

Proved 2026-09-11: stz_string.dll built this way answers seven calls
byte-identically to Mansour's own build on the official Ring, loaded by
rnx through rpp_init (ABI 2). 75 of the 89 domains build -- the 74 whose
dependencies are utf8proc, pcre2 and snowball only, plus stz_reactor
(libuv + libcurl + mbedtls, ~380 third-party C files, 55 s), which took
the count of Softanza tests byte-identical to the oracle from 6 to 12.
The 14 left needed sqlite, ggml, wgpu, tree-sitter, glfw, RmlUi, miniaudio,
AccessKit or the platform speech engine, and were not attempted. Five of
them (sqlite, tree-sitter, and the reactor's libraries) turned out to be
vendored and built on 2026-09-13/14; the last nine on 2026-09-26 (item 6),
when every one of their dependencies turned out to be vendored too.

The engine source path is Mansour's tree, like gate.py's corpus: absent,
this says so and stops.
"""
import io, os, shutil, sys, time

SRC = r'D:\GitHub\stzlib\libraries\stzlib\engine'
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DST = os.path.join(ROOT, 'runtime', 'engine-copy')
BACKEND = os.path.join(HERE, 'ring_api_rpp.zig')

PORTABLE = (
    'stk_string stk_datetime stk_file stk_locale stz_string stz_datetime stz_file stz_locale '
    'stz_regex stz_bytes stz_json stz_url stz_system stz_unicode stz_value stz_number stz_list '
    'stz_hashmap stz_table stz_random stz_csv stz_stats stz_graph stz_meta stz_text stz_yielder '
    'stz_uuid stz_codec stz_bits stz_html stz_tcp stz_fswatch stz_time stz_pool stz_resilience '
    'stz_histogram stz_tracectx stz_testsrv stz_geo stz_compress stz_solver stz_watch stz_perf '
    'stz_seclog stz_cache stz_stream stz_process stz_arith stz_profiler stz_embed stz_smallfn '
    'stz_numtheory stz_splitter stz_pattern stz_stringart stz_display stz_constraint stz_natlang '
    'stz_ccode stz_reactive stz_namedvars stz_adverb stz_timeline stz_gridnav stz_sectmerge '
    'stz_deepops stz_reaxis stz_softanzuter stz_similarity stz_validator stz_sequence stz_intseq '
    'stz_relations stz_statemachine '
    # stz_reactor needs libuv, libcurl and mbedtls -- all three vendored in
    # the engine tree, so it builds like the rest (+55 s). It carries the
    # reactor, the HTTP client and the process spawner, and 10 of the 34
    # assertion tests wait on it.
    'stz_reactor '
    # stz_db and stz_unidata need SQLITE, and sqlite is vendored in the
    # engine tree exactly as utf8proc, pcre2 and libuv are -- one
    # amalgamated C file compiled from source, reaching nothing outside.
    # They were in the "not attempted" list with ggml and wgpu, which do
    # need things that are not there; these two do not. Two of the 34
    # stop on stzenginedbopen (2026-09-13).
    'stz_db stz_unidata '
    # Three more whose dependencies are ALREADY VENDORED for domains we
    # build: crypto needs mbedtls and http needs libcurl (both compiled
    # for stz_reactor), polyglot needs tree-sitter. They sat in the "not
    # attempted" list beside ggml and wgpu, which genuinely are not here.
    'stz_crypto stz_http stz_polyglot '
    # ITEM 6, 2026-09-26: THE NINE THAT WERE NEVER ATTEMPTED. The note above
    # said they need "things that are not there", and it was wrong for every
    # one: ggml, glfw, RmlUi, HarfBuzz and miniaudio are vendored sources in
    # the engine tree, the speech engine is the OS's, and wgpu and AccessKit
    # are vendored PREBUILT runtimes that the domains load themselves.
    # Matrix alone held 499 of the assertions Ring++ was missing.
    'stz_matrix stz_neural stz_gpu stz_window stz_gui stz_a11y '
    'stz_sound stz_audiodev stz_voice').split()

RPP_A = """

// Ring++: the same table, through the same ringlib_init, over the second
// backend of ring_api.zig (ringpp/bench/ring_api_rpp.zig). Two exports.
const RPP = @import("ring_api.zig");
export fn rpp_init(h: *const RPP.HostApi) callconv(.c) c_int {
    RPP.setHost(h);
    var dummy: u8 = 0;
    ring_bridge.ringlib_init(@ptrCast(&dummy));
    return 0;
}
export fn rpp_abi_version() callconv(.c) u32 {
    return 3;
}
"""
RPP_B = RPP_A.replace('ring_bridge.ringlib_init(@ptrCast(&dummy));', 'ringlib_init(@ptrCast(&dummy));')


def rw(path):
    s = io.open(path, encoding='utf-8', newline='').read()
    return s, ('\r\n' if '\r\n' in s else '\n')


def save(path, s):
    io.open(path, 'w', encoding='utf-8', newline='').write(s)

NEURAL_OLD = "    const mem_size: usize = 128 * 1024 * 1024 + kv_len * n_new * n_head * n_layer * 24 + n_new * n_embd * n_layer * 64;"
NEURAL_NEW = (
    "    const mem_size_est: usize = 128 * 1024 * 1024 + kv_len * n_new * n_head * n_layer * 24 + n_new * n_embd * n_layer * 64;\n"
    "    // Ring++ copy only (K4, 2026-10-20): the estimate above is a few hundred KB short for Qwen2.5-1.5B on a 40-token prompt and 16 MB short at 512 tokens\n"
    "    // (ggml_new_object: needed 264244144, available 264048128) -- so the model cannot run at all. A quarter more.\n"
    "    const mem_size: usize = mem_size_est + mem_size_est / 4 + 1024 * 1024 * 1024;     // and a constant gigabyte: the estimate under-counts something that does not grow with the prompt "
    "(a 368-token prompt on the 1.5B was short by 1.1 MB even with a quarter more)")


def neural_pool_patch():
    """THE POOL FIX LIVES IN THIS COPY ONLY (v22/k4/ENGINE_NOTES.md, prompt 55 to stzlib): the engine's estimate of the ggml pool is too small for Qwen2.5-1.5B, so the model cannot run.
    A refresh from the live tree used to drop it silently -- the first re-lay of the package after the handle table would have, and the local models (rung 5's agent runs) with it. Applied
    after every copy; a tree that has fixed the line itself is left alone."""
    p = os.path.join(DST, 'src', 'neural_gen.zig')
    if not os.path.exists(p):
        return
    s, nl = rw(p)
    old = NEURAL_OLD
    if s.count(old) == 1:
        save(p, s.replace(old, NEURAL_NEW.replace('\n', nl)))
        print('neural_gen.zig: the pool-size patch re-applied (the live tree still has the old estimate)')
    elif 'mem_size_est' in s:
        print('neural_gen.zig: already carries the pool-size fix')
    else:
        print('neural_gen.zig: the live tree changed this line -- the pool-size patch was NOT applied; check the 1.5B model still runs')


def linux_curl(patch):
    """LIBCURL ON LINUX (2026-10-17). His build.zig vendors libcurl for Windows
    only -- `addLibcurl` panics elsewhere, "POSIX needs a generated
    curl_config.h" -- so stz_http and stz_reactor did not build for Linux, and
    every Softanza program there printed two WARNING lines and had no HTTP
    client and no reactor (83 tests stop on it on the Linux oracle). This is
    the missing half, in the copy: bench/curl_config_linux.h laid out as
    vendor/curl-config/linux/curl_config.h, mbedTLS (vendored, 3.6) as curl's
    TLS where Windows uses Schannel, the GNU and nghttp2 definitions Linux
    needs, and mbedTLS's sources added to a curl domain off Windows (stz_http
    has none of its own). Windows compiles exactly what it compiled before.
    It is a change for HIS build.zig too; until he takes it, every flavour of
    the copy carries it."""
    cfg = os.path.join(DST, 'vendor', 'curl-config', 'linux')
    os.makedirs(cfg, exist_ok=True)
    shutil.copyfile(os.path.join(HERE, 'curl_config_linux.h'), os.path.join(cfg, 'curl_config.h'))
    patch('    if (os_tag != .windows) {\n'
          '        std.debug.panic("libcurl vendoring is currently Windows-only (POSIX needs a generated curl_config.h)", .{});\n'
          '    }\n',
          '    // Linux: a hand-written curl_config.h (vendor/curl-config/linux, its header\n'
          '    // says what it chooses) and mbedTLS for TLS where Windows uses Schannel --\n'
          '    // the domain loop adds mbedTLS\'s sources for a curl domain off Windows.\n'
          '    if (os_tag != .windows and os_tag != .linux) {\n'
          '        std.debug.panic("libcurl vendoring builds for Windows and Linux only (another POSIX needs its own curl_config.h)", .{});\n'
          '    }\n'
          '    const linux = os_tag == .linux;\n'
          '    if (linux) {\n'
          '        mod.addIncludePath(b.path("vendor/curl-config/linux"));\n'
          '        mod.addIncludePath(b.path("vendor/mbedtls/include"));\n'
          '    }\n')
    patch('    const flags = [_][]const u8{\n'
          '        "-DBUILDING_LIBCURL",\n'
          '        "-DCURL_STATICLIB",\n'
          '        "-DUSE_WINDOWS_SSPI",\n'
          '        "-DUSE_SCHANNEL",\n'
          '        "-DUSE_NGHTTP2",',
          '    const tls_flags: []const []const u8 = if (linux)\n'
          '        &.{ "-DHAVE_CONFIG_H", "-D_GNU_SOURCE" }\n'
          '    else\n'
          '        &.{ "-DUSE_WINDOWS_SSPI", "-DUSE_SCHANNEL" };\n'
          '    const head_flags = [_][]const u8{ "-DBUILDING_LIBCURL", "-DCURL_STATICLIB" };\n'
          '    const common_flags = [_][]const u8{\n'
          '        "-DUSE_NGHTTP2",')
    # the TLS definitions stay where they stood, so Windows compiles with the very same command line
    patch('    lib.addCSourceFiles(.{ .files = files.items, .flags = &flags });',
          '    lib.addCSourceFiles(.{ .files = files.items, .flags = std.mem.concat(b.allocator, []const u8, '
          '&.{ &head_flags, tls_flags, &common_flags }) catch @panic("oom") });')
    patch('    const ng_flags = [_][]const u8{ "-DNGHTTP2_STATICLIB", "-DBUILDING_NGHTTP2" };\n'
          '    lib.addCSourceFiles(.{ .files = ngfiles.items, .flags = &ng_flags });',
          '    // on Linux nghttp2 finds htons & co. and its clock only when told they exist\n'
          '    const ng_flags: []const []const u8 = if (linux)\n'
          '        &.{ "-DNGHTTP2_STATICLIB", "-DBUILDING_NGHTTP2", "-DHAVE_ARPA_INET_H=1", "-DHAVE_NETINET_IN_H=1", '
          '"-DHAVE_CLOCK_GETTIME=1", "-DHAVE_DECL_CLOCK_MONOTONIC=1" }\n'
          '    else\n'
          '        &.{ "-DNGHTTP2_STATICLIB", "-DBUILDING_NGHTTP2" };\n'
          '    lib.addCSourceFiles(.{ .files = ngfiles.items, .flags = ng_flags });')
    patch('    const win_libs = [_][]const u8{ "ws2_32", "crypt32", "secur32", "advapi32", "bcrypt", "normaliz" };\n'
          '    for (win_libs) |l| lib.linkSystemLibrary(l);\n'
          '}',
          '    if (linux) {\n'
          '        lib.linkSystemLibrary("pthread"); // the threaded resolver\n'
          '        return;\n'
          '    }\n'
          '    const win_libs = [_][]const u8{ "ws2_32", "crypt32", "secur32", "advapi32", "bcrypt", "normaliz" };\n'
          '    for (win_libs) |l| lib.linkSystemLibrary(l);\n'
          '}')
    patch('        if (dom.needs_libcurl) addLibcurl(mod, lib, b, target.result.os.tag);\n'
          '        if (dom.needs_mbedtls) addMbedtls(mod, lib, b, target.result.os.tag, false);\n',
          '        if (dom.needs_libcurl) addLibcurl(mod, lib, b, target.result.os.tag);\n'
          '        // off Windows, curl\'s TLS is mbedTLS, so a curl domain needs its sources too\n'
          '        if (dom.needs_mbedtls or (dom.needs_libcurl and target.result.os.tag != .windows))\n'
          '            addMbedtls(mod, lib, b, target.result.os.tag, false);\n')


def main():
    # --src=<engine dir> --dst=<copy dir> (2026-10-22): build ANOTHER engine tree (a worktree of the library, a branch) beside the clock copy
    # without touching it. Seed <dst>/.zig-cache from runtime/engine-copy first and only what changed is compiled.
    global SRC, DST
    for a in sys.argv[1:]:
        if a.startswith('--src='):
            SRC = a[6:]
        elif a.startswith('--dst='):
            DST = a[6:]
    if not os.path.isdir(SRC):
        print('SKIP engine copy: no engine tree at ' + SRC)
        return 0
    # --oracle (item 8, 2026-09-28): the ENGINE THE ORACLE HOSTS, for a
    # platform where Mansour's tree has no build of it (Linux). His real
    # ring_api.zig -- Ring's C API -- and no entry patches; Ring's headers
    # from vendor/ring-vm; and on Linux NO `-lring`: the oracle is one binary
    # that exports Ring's API (tests/b2_runtimes.ps1, --export-dynamic), so
    # the symbols resolve at dlopen, as its own zip extension's do.
    #
    # --official (2026-10-03): HIS OWN BUILD, from a copy, for one purpose --
    # validating an engine change on the official Ring 1.27, which loads
    # libraries that import Ring's API from its ring.dll. His ring_api.zig,
    # his addRing and his discovery of a Ring installation, all unchanged, so
    # this flavour REACHES D:\Ring127 at build time by design; nothing else
    # uses it, and the oracle never loads it.
    oracle = '--oracle' in sys.argv
    official = '--official' in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if oracle:
        DST = os.path.join(ROOT, 'runtime', 'engine-oracle')
    if official:
        oracle = True
        DST = os.path.join(ROOT, 'runtime', 'engine-official')
    domains = args or PORTABLE
    t0 = time.time()
    # A RE-COPY KEEPS THE BUILD. Deleting the copy whole deleted its zig
    # cache and its built DLLs with it, so refreshing the sources cost a
    # rebuild of every domain; zig's cache is keyed on content, so keeping
    # it is safe and a refresh rebuilds only what changed.
    # zig-out-linux too: the Linux build (item 8) lives beside the Windows one,
    # and the first re-copy after it existed deleted all 81 libraries.
    KEEP = ('.zig-cache', 'zig-out', 'zig-out-linux')
    if os.path.exists(DST):
        for name in os.listdir(DST):
            if name in KEEP:
                continue
            p = os.path.join(DST, name)
            if os.path.isdir(p):
                shutil.rmtree(p)
            else:
                os.remove(p)
    n = 0
    for root, dirs, files in os.walk(SRC):
        dirs[:] = [d for d in dirs if d not in ('zig-out', '.zig-cache', 'nul')]
        rel = os.path.relpath(root, SRC)
        out = os.path.join(DST, rel) if rel != '.' else DST
        os.makedirs(out, exist_ok=True)
        for f in files:
            if f == 'nul':
                continue
            try:
                shutil.copyfile(os.path.join(root, f), os.path.join(out, f))
                n += 1
            except OSError as e:
                print('  skip', rel, f, e)
    print('copied %d files in %.0f s' % (n, time.time() - t0))
    if not oracle:
        shutil.copyfile(BACKEND, os.path.join(DST, 'src', 'ring_api.zig'))
        neural_pool_patch()

    patched, skipped = [], []
    for dom in ([] if oracle else domains):
        entry = os.path.join(DST, 'src', dom + '_entry.zig')
        if not os.path.exists(entry):
            skipped.append((dom, 'no entry file'))
            continue
        s, nl = rw(entry)
        if '@export(&ring_bridge.ringlib_init, .{ .name = "ringlib_init" });' in s:
            s = s.rstrip('\r\n') + RPP_A.replace('\n', nl) + nl
        elif 'fn ringlib_init(' in s:
            s = s.rstrip('\r\n') + RPP_B.replace('\n', nl) + nl
        else:
            skipped.append((dom, 'no ringlib_init in the entry'))
            continue
        save(entry, s)
        patched.append(dom)
    print('entries patched: %d' % len(patched))
    for d, why in skipped:
        print('  skipped %-18s %s' % (d, why))

    bz = os.path.join(DST, 'build.zig')
    s, nl = rw(bz)

    def patch(old, new, count=1):
        nonlocal s
        old = old.replace('\n', nl)
        new = new.replace('\n', nl)
        assert s.count(old) == count, (s.count(old), old[:60])
        s = s.replace(old, new)

    patch('pub fn build(b: *std.Build) void {',
          '/// Ring++: only the domains named in the ONLY environment variable\n'
          '/// (comma-separated) are built, so batches share one cache.\n'
          'fn wanted(b: *std.Build, name: []const u8) bool {\n'
          '    const only = std.process.getEnvVarOwned(b.allocator, "ONLY") catch return false;\n'
          '    var it = std.mem.splitScalar(u8, only, \',\');\n'
          '    while (it.next()) |o| if (std.mem.eql(u8, std.mem.trim(u8, o, " "), name)) return true;\n'
          '    return false;\n'
          '}\n\n'
          'pub fn build(b: *std.Build) void {')
    patch('    for (core_domains) |dom| {\n', '    for (core_domains) |dom| {\n        if (!wanted(b, dom.name)) continue;\n')
    patch('    for (base_domains) |dom| {\n', '    for (base_domains) |dom| {\n        if (!wanted(b, dom.name)) continue;\n')
    for old in ('        b.installArtifact(studio);', '    b.installArtifact(static_lib);', '    b.installArtifact(gen_refdata);'):
        patch(old, old.replace('b.installArtifact', 'if (false) b.installArtifact'))
    try:
        linux_curl(patch)
    except AssertionError as e:      # another tree's build.zig (a worktree, a branch): its libcurl block is not the one this patch was written against; only a LINUX build needs it
        print('linux libcurl patch skipped: the build.zig of this tree differs (%s) -- Windows builds do not need it' % (e.args[0],))
    if official:
        save(bz, s)
        print('build.zig: ONLY from the environment, extra installs off; addRing and '
              'the Ring installation search are HIS -- this flavour links D:\\Ring127')
        print('copy at: ' + DST)
        return 0
    # THE ORACLE FLAVOUR ON WINDOWS LINKS THE ORACLE (2026-10-03). A PE
    # library must NAME the module its imports come from, and his own build
    # links an installation's ring.lib, which names ring.dll. The oracle is
    # ONE binary, ring.exe, with no ring.dll beside it -- so hosting his
    # engine, it resolved ring.dll through the PATH and mapped
    # D:\Ring127\bin\ring.dll into the process: every engine call ran Ring's
    # API out of the official installation, and with D:\Ring127 off the PATH
    # the oracle could not load the engine at all (R38). Measured, by listing
    # the modules of a running oracle. The oracle's own import library,
    # runtime/win64/libring.a (tests/b2_runtimes.ps1), names ring.exe, as the
    # zip extension's link already does.
    oracle_lib = os.path.join(ROOT, 'runtime', 'win64').replace(chr(92), '/')
    patch('fn addRing(b: *std.Build, mod: *std.Build.Module, lib: *std.Build.Step.Compile, ring_dir: []const u8) void {\n'
          '    mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/language/include", .{ring_dir}) });\n'
          '    lib.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{ring_dir}) });\n'
          '    lib.linkSystemLibrary("ring");\n'
          '}',
          ('fn addRing(b: *std.Build, mod: *std.Build.Module, lib: *std.Build.Step.Compile, ring_dir: []const u8) void {\n'
           '    // the oracle flavour: Ring\'s headers. On ELF no `-lring` -- the\n'
           '    // symbols resolve from the oracle binary itself when it dlopens the\n'
           '    // library. On Windows the ORACLE\'s import library, which names\n'
           '    // ring.exe -- never an installation\'s ring.dll.\n'
           '    mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/language/include", .{ring_dir}) });\n'
           '    if (lib.rootModuleTarget().os.tag == .windows) {\n'
           '        lib.addLibraryPath(.{ .cwd_relative = "' + oracle_lib + '" });\n'
           '        lib.linkSystemLibrary("ring");\n'
           '    }\n'
           '}') if oracle else
          ('fn addRing(b: *std.Build, mod: *std.Build.Module, lib: *std.Build.Step.Compile, ring_dir: []const u8) void {\n'
           '    // Ring++: nothing references Ring\'s C API, and a sovereign build\n'
           '    // must not reach for ring.lib.\n'
           '    _ = b;\n'
           '    _ = mod;\n'
           '    _ = lib;\n'
           '    _ = ring_dir;\n'
           '}'))
    # THE BUILD REACHED FOR A RING INSTALLATION, and nothing links it: the
    # engine reads RING_VERSION_MINOR from <ring>/language/include/state.h,
    # and discoverRingDir found D:\Ring127 through the PATH -- so the build
    # printed "building against Ring dir='D:\Ring127'", and on a machine
    # without Ring it would panic. The vendored VM carries that header
    # (vendor/ring-vm/include/state.h, hashed), so the copy gets it in the
    # layout the build expects and the search is replaced (2026-09-26).
    hdr = os.path.join(DST, '_ring_headers', 'language', 'include')
    os.makedirs(hdr, exist_ok=True)
    inc = os.path.join(ROOT, 'vendor', 'ring-vm', 'include')
    # the oracle flavour compiles against Ring's API, so it takes every header
    for h in (sorted(os.listdir(inc)) if oracle else ['state.h']):
        if h.endswith('.h'):
            shutil.copyfile(os.path.join(inc, h), os.path.join(hdr, h))
    patch('orelse (discoverRingDir(b) orelse {',
          'orelse (@as(?[]const u8, "_ring_headers") orelse {')
    save(bz, s)
    print('build.zig: ONLY from the environment; addRing a no-op; extra installs off; '
          'Ring headers from vendor/ring-vm, no installation searched')
    print('copy at: ' + DST)
    print('build:   cd ' + DST + ' && ONLY=' + ','.join(domains[:3]) + ',... zig build -j2   (his default, ReleaseSafe)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
