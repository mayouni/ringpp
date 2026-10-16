# -*- coding: utf-8 -*-
"""Gate for the four console builtins, with no human at the keyboard.

There is no Ring 1.27 side to A/B against -- Ring cannot read a raw key --
so the gate is the console probe's own trick turned on the builtins:

  1. launch `rnxc exec bench/tui.ring` in a NEW console;
  2. wait until the child has written its READY file -- it is then in
     raw mode and blocked in tui_key();
  3. from here (a process with no console of its own) AttachConsole to
     the child's console, open CONIN$ fresh -- after AttachConsole the
     process's cached std handle still points at the old pipe, which is
     why the first version of this delivered nothing -- and
     WriteConsoleInput three keystrokes: 'a', Enter, Up-arrow;
  4. read what tui_init / tui_size / tui_key x3 / tui_done wrote.

Expected:  init 1, a real size, key1 [a], key2 [<enter>], key3 [<up>].

    python bench/tui_probe.py
"""
import ctypes, ctypes.wintypes as W, os, subprocess, sys, time

K = ctypes.windll.kernel32
CREATE_NEW_CONSOLE = 0x00000010
KEY_EVENT = 0x0001
GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
FILE_SHARE_READ = 0x1
FILE_SHARE_WRITE = 0x2
OPEN_EXISTING = 3
INVALID = ctypes.c_void_p(-1).value


class KEY_EVENT_RECORD(ctypes.Structure):
    _fields_ = [('bKeyDown', W.BOOL), ('wRepeatCount', W.WORD),
                ('wVirtualKeyCode', W.WORD), ('wVirtualScanCode', W.WORD),
                ('UnicodeChar', W.WCHAR), ('dwControlKeyState', W.DWORD)]


class INPUT_RECORD(ctypes.Structure):
    _fields_ = [('EventType', W.WORD), ('Event', KEY_EVENT_RECORD)]


def key(vk, ch):
    r = INPUT_RECORD()
    r.EventType = KEY_EVENT
    r.Event.bKeyDown = True
    r.Event.wRepeatCount = 1
    r.Event.wVirtualKeyCode = vk
    r.Event.UnicodeChar = ch
    return r


def wait_for(path, seconds):
    for _ in range(int(seconds * 10)):
        if os.path.exists(path):
            return True
        time.sleep(0.1)
    return False


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    rnxc = os.path.join(root, 'zig-out', 'bin', 'rnxc.exe')
    out = os.path.join(here, '_tui_result.txt')
    ready = os.path.join(here, '_tui_ready.txt')
    for p in (out, ready):
        if os.path.exists(p):
            os.remove(p)

    child = subprocess.Popen([rnxc, 'exec', 'bench/tui.ring'], cwd=root,
                             creationflags=CREATE_NEW_CONSOLE)
    if not wait_for(ready, 15):
        child.kill()
        print('child never reached tui_key() -- no READY file in 15 s')
        return 1
    time.sleep(0.2)

    K.FreeConsole()
    if not K.AttachConsole(child.pid):
        print('AttachConsole failed: error %d' % K.GetLastError())
        child.kill()
        return 1
    K.CreateFileW.restype = ctypes.c_void_p
    hin = K.CreateFileW('CONIN$', GENERIC_READ | GENERIC_WRITE,
                        FILE_SHARE_READ | FILE_SHARE_WRITE, None, OPEN_EXISTING, 0, None)
    if hin is None or hin == INVALID:
        print('CONIN$ open failed: error %d' % K.GetLastError())
        child.kill()
        return 1
    n = W.DWORD()
    for label, rec in (('a', key(0x41, 'a')), ('Enter', key(0x0D, '\r')), ('Up', key(0x26, '\0'))):
        ok = K.WriteConsoleInputW(ctypes.c_void_p(hin), ctypes.byref(rec), 1, ctypes.byref(n))
        if not ok:
            print('WriteConsoleInput(%s) failed: error %d' % (label, K.GetLastError()))
        time.sleep(0.15)
    K.CloseHandle(ctypes.c_void_p(hin))
    K.FreeConsole()

    for _ in range(50):
        if child.poll() is not None:
            break
        time.sleep(0.1)
    if child.poll() is None:
        child.kill()
        print('child did not finish -- a key was not delivered')
    if not os.path.exists(out):
        print('no result file')
        return 1
    with open(out, encoding='utf-8') as f:
        txt = f.read()
    print(txt.rstrip())
    ok = ('init 1' in txt and 'key1 [a]' in txt and 'key2 [<enter>]' in txt
          and 'key3 [<up>]' in txt and 'TUI DONE' in txt)
    print('TUI GATE ' + ('PASS' if ok else 'FAIL'))
    for p in (out, ready):
        if os.path.exists(p):
            os.remove(p)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
