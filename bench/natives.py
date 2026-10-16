r"""Can Ring++ still reach for something of RING's to do its work?

    python bench/natives.py

This exists because it happened, and it happened QUIETLY. Softanza's file
layer loads `ziplib.ring`, whose first line is `LoadLib("ring_libzip.dll")`
-- Ring's own zip extension. Ring++ cannot host a Ring extension, so that
call failed, and the failure was answered with NULL, and the estate took its
fallback. Nobody looked for weeks. When the answer became Ring's own strict
R46 the whole wide clock went to ZERO on that one line, and the fix was to
write zip in Zig (`src/zip.zig`) and stop loading anything at all.

The inertia was not the zip code. It was ASSUMING that because Ring reaches
a native through a DLL, Ring++ must too. So this asks the three questions
that would have caught it on the day:

  1. Does rnxc SHIP a dynamic library? Commitment 5 says one binary. A DLL
     beside it is either an engine (not ours to ship) or a native that
     belongs INSIDE.

  2. Does anything rnxc ships CALL LoadLib? Every native rnxc needs is
     built in, so a load in our own tree is a reach we did not have to make.
     Comments are not calls -- the shim explains the line it removed.

  3. Does every library the estate WILL load carry `rpp_init`? One that
     carries `ringlib_init` instead is a Ring extension, and it will now
     stop the program with R46 rather than degrade in silence. Naming them
     here means finding them before a test does.

The third needs Softanza's engine build; without it, that check is SKIPPED
by name, as the rest of this project's gates are.
"""
import io
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SHIPPED = os.path.join(ROOT, 'zig-out')
sys.path.insert(0, HERE)
import clock34 as K

ENGINE = os.path.join(K.COPY, 'engine', 'zig-out', 'bin')
LIBEXT = ('.dll', '.so', '.dylib')

# RUNTIMES AN ENGINE DOMAIN LOADS ITSELF, never through the estate's LoadLib:
# they carry neither init symbol because they are neither a Ring extension
# nor one of ours -- they are what stz_gpu, stz_neural and stz_a11y call.
# Vendored PREBUILT in Softanza's engine tree (vendor/wgpu, vendor/accesskit),
# installed beside the domains by the engine's own build. Named here so a
# library carrying neither symbol is still a failure unless it is one of
# these (item 6, 2026-09-26).
ENGINE_RUNTIMES = {
    'wgpu_native.dll': 'the WebGPU runtime stz_gpu and stz_neural load by path',
    'accesskit.dll': 'the screen-reader bridge stz_a11y loads by path',
}


def strip_comments(line):
    """Ring's two comment forms. A LoadLib inside one is prose."""
    for mark in ('#', '//'):
        at = line.find(mark)
        if at >= 0:
            line = line[:at]
    return line


def shipped_libraries():
    out = []
    for dp, dn, fn in os.walk(SHIPPED):
        for f in fn:
            if f.lower().endswith(LIBEXT):
                out.append(os.path.relpath(os.path.join(dp, f), SHIPPED))
    return sorted(out)


def shipped_loads():
    out = []
    for dp, dn, fn in os.walk(SHIPPED):
        for f in fn:
            if not f.lower().endswith(('.ring', '.rh')):
                continue
            p = os.path.join(dp, f)
            try:
                text = io.open(p, encoding='utf-8', errors='replace').read()
            except OSError:
                continue
            for n, line in enumerate(text.split('\n'), 1):
                if 'loadlib' in strip_comments(line).lower():
                    out.append('%s:%d' % (os.path.relpath(p, SHIPPED), n))
    return out


def engine_libraries():
    """(ours, ring_abi, neither). A symbol an image EXPORTS is in it as
    plain bytes, which is enough to tell the two ABIs apart and needs no
    platform tooling."""
    ours, ring_abi, neither = [], [], []
    if not os.path.isdir(ENGINE):
        return None
    for f in sorted(os.listdir(ENGINE)):
        if not f.lower().endswith(LIBEXT):
            continue
        try:
            b = open(os.path.join(ENGINE, f), 'rb').read()
        except OSError:
            continue
        if b'rpp_init' in b:
            ours.append(f)
        elif b'ringlib_init' in b:
            ring_abi.append(f)
        elif f.lower() in ENGINE_RUNTIMES:
            continue
        else:
            neither.append(f)
    return ours, ring_abi, neither


def main():
    fails = []
    notes = []

    libs = shipped_libraries()
    if libs:
        fails.append('rnxc SHIPS %d dynamic librar(ies): %s'
                     % (len(libs), ', '.join(libs[:4])))
    else:
        notes.append('rnxc ships no dynamic library -- one binary, as commitment 5 says')

    loads = shipped_loads()
    if loads:
        fails.append('LoadLib is CALLED in what rnxc ships: %s' % ', '.join(loads[:4]))
    else:
        notes.append('nothing rnxc ships calls LoadLib -- every native it needs is built in')

    eng = engine_libraries()
    if eng is None:
        notes.append('SKIPPED the engine check: no build at ' + ENGINE)
    else:
        ours, ring_abi, neither = eng
        if ring_abi:
            fails.append('%d librar(ies) the estate loads carry ringlib_init, not rpp_init -- '
                         'a Ring extension, which now stops the program with R46: %s'
                         % (len(ring_abi), ', '.join(ring_abi[:4])))
        if neither:
            fails.append('%d librar(ies) carry NEITHER init symbol: %s'
                         % (len(neither), ', '.join(neither[:4])))
        if not ring_abi and not neither:
            notes.append('all %d engine libraries carry rpp_init -- none is a Ring extension' % len(ours))
        present = [r for r in sorted(ENGINE_RUNTIMES) if os.path.exists(os.path.join(ENGINE, r))]
        if present:
            notes.append('%d vendored runtime(s) the domains load themselves: %s'
                         % (len(present), ', '.join(present)))

    for n in notes:
        print('  ' + n)
    for f in fails:
        print('  FAIL ' + f)
    print()
    if fails:
        print('NATIVES FAIL   %d reach(es) of Ring\'s left in place' % len(fails))
        return 1
    print('NATIVES OK   nothing of Ring\'s is reached for')
    return 0


if __name__ == '__main__':
    sys.exit(main())
