# -*- coding: utf-8 -*-
"""Contract gate 7.2: two renderers, one model.

The widget-tree contract (ringpp docs/WIDGET-TREE-CONTRACT.md, 7.2) says
two renderers fed the same session must leave BYTE-IDENTICAL model state.
This is that gate, and it crosses runtimes on purpose:

    line renderer       ring.exe  examples/09.../example.ring   (the oracle: our build of Ring 1.27)
    keystroke renderer  rnxc exec examples/09.../keys.ring      (Ring++)

Each prints one `serial:` line -- the model and the event log serialised
by hand into a string -- and the two lines are compared as bytes. Both
sessions are scripted, so no console is touched and nothing is asked of a
person.

    python bench/tui72.py
"""
import os, subprocess, sys

RINGPP = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# The oracle: Ring 1.27's VM built from vendor/ring-vm by tests/b2_runtimes.ps1
# -- OUR build, not an installation upstream controls. RING=<path> in the
# environment overrides it, e.g. to compare against the official binary.
RING = os.environ.get('RING') or os.path.join(RINGPP, 'runtime', 'win64', 'ring.exe')
# every example that has both halves: a line-renderer example.ring for Ring
# 1.27 and a keystroke keys.ring for Ring++, printing one serial: line each
PAIRS = ['09-a-window-in-the-terminal', '10-a-form-with-choices',
         '11-a-table-to-choose-from', '12-the-ringpad-shell',
         '13-a-text-to-edit',
         '14-a-handler-in-place',
         '15-a-row-of-buttons']
HERE = os.path.dirname(os.path.abspath(__file__))
RNXC = os.path.join(os.path.dirname(HERE), 'zig-out', 'bin', 'rnxc.exe')


def serial_of(cmd, label, ex):
    # stdin closed: an UNSCRIPTED keys.ring then reads end-of-input at once
    # and closes, instead of waiting two minutes for a keyboard that is
    # not there -- which is what happened the first time a live edit was
    # left in the file.
    r = subprocess.run(cmd, cwd=ex, capture_output=True, text=True, encoding='utf-8', errors='replace',
                       timeout=120, stdin=subprocess.DEVNULL)
    out = r.stdout + r.stderr
    # a half may run extra sessions of its own (13's keystroke-only
    # session, judged by replay, contract 6.5) and report a failure in
    # them with a line starting KEYS FAIL; that is a failure here too.
    if 'KEYS FAIL' in out:
        bad = [l for l in out.split(chr(10)) if 'KEYS FAIL' in l][0].strip()
        print('%s reported: %s' % (label, bad))
        return None
    lines = [l.strip() for l in out.split('\n') if l.strip().startswith('serial:')]
    if not lines:
        tail = [l for l in out.split('\n') if l.strip()][-3:]
        print('%s printed no serial line; last output: %s' % (label, ' | '.join(tail)))
        return None
    return lines[0]


def main():
    bad = 0
    for name in PAIRS:
        ex = os.path.join(RINGPP, 'examples', name)
        a = serial_of([RING, 'example.ring'], name + ' / line renderer on Ring 1.27', ex)
        b = serial_of([RNXC, 'exec', 'keys.ring'], name + ' / keystroke renderer on Ring++', ex)
        # the browser renderer is pure Ring -- no console builtins, no
        # socket yet -- so it is run on 1.27 like the line renderer. That
        # it needs neither runtime's extras is part of what it proves.
        c = None
        has_web = os.path.exists(os.path.join(ex, 'web.ring'))
        if has_web:
            c = serial_of([RING, 'web.ring'], name + ' / browser renderer', ex)
        print(name)
        if a is None or b is None or (has_web and c is None):
            bad += 1
            continue
        print('  line renderer      (Ring 1.27): ' + a)
        print('  keystroke renderer (Ring++)   : ' + b)
        if has_web:
            print('  browser renderer   (model)    : ' + c)
        else:
            print('  browser renderer              : (none for this tree)')
        if a != b or (has_web and a != c):
            bad += 1
    same = 1 if bad == 0 else 0
    n_web = sum(1 for x in PAIRS
                if os.path.exists(os.path.join(RINGPP, 'examples', x, 'web.ring')))
    print('identical output : %d   (%d of %d trees, %d with three renderers)'
          % (same, len(PAIRS) - bad, len(PAIRS), n_web))
    return 0 if same else 1


if __name__ == '__main__':
    sys.exit(main())
