# -*- coding: utf-8 -*-
"""Console probe -- contract gate 3, measured.

Three facts the terminal renderer's design depends on, none of which a
pipe can answer, so this runs as a child in a NEW console and writes its
answers to a file:

  1. VT_DEFAULT  is ENABLE_VIRTUAL_TERMINAL_PROCESSING already on in a
                 fresh console?  (if not, a pure-Ring renderer prints
                 literal escape characters there -- Ring 1.27 cannot
                 call SetConsoleMode)
  2. VT_ENABLE   can a process switch it on itself, with nothing external?
                 (what a Ring++ builtin would do)
  3. RAW_KEY     can one keystroke be read WITHOUT Enter?  Proven by
                 injecting a key into this console's own input buffer with
                 WriteConsoleInput and reading it back with
                 ReadConsoleInput -- the mechanism a `tui_key()` builtin
                 would use, exercised without a human at the keyboard.

Plus the host it landed in (WT_SESSION means Windows Terminal), the
buffer size, and whether cursor addressing calls succeed.

    python bench/console_probe.py --child <outfile>      (what the console runs)
    python bench/console_probe.py                        (launches both hosts)

The probe is Python because it MEASURES the OS; the primitive it argues
for is Zig, using these same kernel32 calls.
"""
import ctypes, ctypes.wintypes as W, json, os, subprocess, sys, time

K = ctypes.windll.kernel32
ENABLE_VT = 0x0004
ENABLE_LINE_INPUT = 0x0002
ENABLE_ECHO_INPUT = 0x0004
STD_IN, STD_OUT = -10, -11
KEY_EVENT = 0x0001


class KEY_EVENT_RECORD(ctypes.Structure):
    _fields_ = [('bKeyDown', W.BOOL), ('wRepeatCount', W.WORD),
                ('wVirtualKeyCode', W.WORD), ('wVirtualScanCode', W.WORD),
                ('UnicodeChar', W.WCHAR), ('dwControlKeyState', W.DWORD)]


class INPUT_RECORD(ctypes.Structure):
    _fields_ = [('EventType', W.WORD), ('Event', KEY_EVENT_RECORD)]


class COORD(ctypes.Structure):
    _fields_ = [('X', ctypes.c_short), ('Y', ctypes.c_short)]


class SMALL_RECT(ctypes.Structure):
    _fields_ = [('Left', ctypes.c_short), ('Top', ctypes.c_short),
                ('Right', ctypes.c_short), ('Bottom', ctypes.c_short)]


class CSBI(ctypes.Structure):
    _fields_ = [('dwSize', COORD), ('dwCursorPosition', COORD),
                ('wAttributes', W.WORD), ('srWindow', SMALL_RECT),
                ('dwMaximumWindowSize', COORD)]


def child(out):
    r = {'host': 'Windows Terminal' if os.environ.get('WT_SESSION') else 'conhost'}
    hout = K.GetStdHandle(STD_OUT)
    hin = K.GetStdHandle(STD_IN)

    mode = W.DWORD()
    r['vt_default'] = bool(K.GetConsoleMode(hout, ctypes.byref(mode))) and bool(mode.value & ENABLE_VT)
    r['out_mode_hex'] = hex(mode.value)
    r['vt_enable'] = bool(K.SetConsoleMode(hout, mode.value | ENABLE_VT))
    mode2 = W.DWORD()
    K.GetConsoleMode(hout, ctypes.byref(mode2))
    r['vt_after_enable'] = bool(mode2.value & ENABLE_VT)

    # raw key: turn off line and echo input, inject 'a', read one record
    imode = W.DWORD()
    K.GetConsoleMode(hin, ctypes.byref(imode))
    r['raw_mode_set'] = bool(K.SetConsoleMode(hin, imode.value & ~(ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT)))
    rec = INPUT_RECORD()
    rec.EventType = KEY_EVENT
    rec.Event.bKeyDown = True
    rec.Event.wRepeatCount = 1
    rec.Event.wVirtualKeyCode = 0x41
    rec.Event.UnicodeChar = 'a'
    written = W.DWORD()
    r['inject_ok'] = bool(K.WriteConsoleInputW(hin, ctypes.byref(rec), 1, ctypes.byref(written)))
    got = INPUT_RECORD()
    nread = W.DWORD()
    t0 = time.time()
    r['raw_read_ok'] = bool(K.ReadConsoleInputW(hin, ctypes.byref(got), 1, ctypes.byref(nread)))
    r['raw_read_ms'] = round((time.time() - t0) * 1000, 1)
    r['raw_key'] = got.Event.UnicodeChar if r['raw_read_ok'] and got.EventType == KEY_EVENT else None
    K.SetConsoleMode(hin, imode.value)

    csbi = CSBI()
    r['size_ok'] = bool(K.GetConsoleScreenBufferInfo(hout, ctypes.byref(csbi)))
    r['size'] = [csbi.srWindow.Right - csbi.srWindow.Left + 1, csbi.srWindow.Bottom - csbi.srWindow.Top + 1]
    r['cursor_ok'] = bool(K.SetConsoleCursorPosition(hout, COORD(0, 0)))

    with open(out, 'w', encoding='utf-8') as f:
        json.dump(r, f, indent=1)


def launch(label, prefix, out):
    if os.path.exists(out):
        os.remove(out)
    cmd = prefix + [sys.executable, os.path.abspath(__file__), '--child', out]
    try:
        subprocess.Popen(cmd)
    except OSError as e:
        return {'host': label, 'error': str(e)}
    for _ in range(100):
        if os.path.exists(out):
            time.sleep(0.2)
            with open(out, encoding='utf-8') as f:
                return json.load(f)
        time.sleep(0.1)
    return {'host': label, 'error': 'no result within 10 s'}


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == '--child':
        child(sys.argv[2])
        return 0
    here = os.path.dirname(os.path.abspath(__file__))
    runs = [
        ('conhost (forced)', ['conhost.exe'], os.path.join(here, '_probe_conhost.json')),
        ('Windows Terminal', ['wt.exe', '-w', 'new'], os.path.join(here, '_probe_wt.json')),
    ]
    results = [launch(l, p, o) for l, p, o in runs]
    keys = ['host', 'vt_default', 'vt_enable', 'vt_after_enable', 'raw_mode_set',
            'inject_ok', 'raw_read_ok', 'raw_key', 'raw_read_ms', 'size', 'cursor_ok', 'error']
    print('%-16s %-22s %-22s' % ('', runs[0][0], runs[1][0]))
    for k in keys:
        a, b = results[0].get(k), results[1].get(k)
        if a is None and b is None:
            continue
        print('%-16s %-22s %-22s' % (k, a, b))
    for l, p, o in runs:
        if os.path.exists(o):
            os.remove(o)
    return 0


if __name__ == '__main__':
    sys.exit(main())
