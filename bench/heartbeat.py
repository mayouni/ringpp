"""Is this machine fit to MEASURE right now? -- and a heartbeat for a long pass (Windows).

    python bench/heartbeat.py                    one reading: the CPU's actual speed, the battery, the indicator
    python bench/heartbeat.py <pass-log> <min>   every 180 s for <min> minutes, appended to runtime/ckpt-heartbeat.log,
                                                 with the last progress line of <pass-log>; stops when the log ends

The number that decides is % PROCESSOR PERFORMANCE -- the counter Task Manager's "Speed" is computed from -- read under
load (two threads spin while it is sampled). Over 100 is the chip at or above its nominal clock; this laptop reads
176-219 at full speed. UNDER 100 IS A THROTTLE, and a pass taken under one records the throttle: on 2026-10-18 the
firmware held the CPU at 19% (about 0.4 GHz) from ~21:40 to 00:10 while the charger was plugged in but not recognised --
kernels 12x slower, an oracle run 40 s where it takes 8 -- so the 90 s cap and every timing assertion in Ring's saved
answers would have read the machine, not Ring. Nothing per-process lifts it (SetProcessInformation's power-throttling
opt-out was measured: 2,449 against 2,323 ms, noise). The pattern of that night: the cap held while the charger fed the
machine, full speed came back at 00:11 as the battery began to fall (a power cut), and from 01:10 the battery rose again
and the readings fell to 48-110 -- so with that charger the machine measures only on its battery, and the durable fix
is a charger it recognises. Windows' own power indicator is NOT the test: it read "offline"
through the throttle, through the full-speed hour after it, and while Mansour's charger was feeding the battery. The
battery level is the second number: falling ~2.5 points a minute under a three-job fill means the machine is on its
battery, whatever the indicator says, and a chunk should not start below ~40%.

Counter names are localized (this machine's are French), so the counter is added by its ENGLISH name
(PdhAddEnglishCounterW). CallNtPowerInformation's CurrentMhz is no use here: it reports the nominal 2,200 MHz
throughout a hardware throttle.
"""
import ctypes, ctypes.wintypes as wt, io, os, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(os.path.dirname(HERE), 'runtime', 'ckpt-heartbeat.log')
pdh = ctypes.WinDLL('pdh')


class FMT(ctypes.Structure):
    _fields_ = [('CStatus', wt.DWORD), ('pad', wt.DWORD), ('doubleValue', ctypes.c_double)]


class SPS(ctypes.Structure):
    _fields_ = [('AC', ctypes.c_ubyte), ('Flag', ctypes.c_ubyte), ('Pct', ctypes.c_ubyte), ('Sys', ctypes.c_ubyte),
                ('Life', wt.DWORD), ('Full', wt.DWORD)]


_q, _h = ctypes.c_void_p(), ctypes.c_void_p()
pdh.PdhOpenQueryW(None, None, ctypes.byref(_q))
pdh.PdhAddEnglishCounterW(_q, r'\Processor Information(_Total)\% Processor Performance', None, ctypes.byref(_h))


def cpu_performance(spin=True):
    """% Processor Performance over two seconds -- with two threads spinning, so an idle core parked low on purpose
    does not read as a throttle. A pass already loading the machine passes spin=False."""
    stop = [False]

    def busy():
        x = 0
        while not stop[0]:
            x += 1
    ts = [threading.Thread(target=busy) for _ in range(2 if spin else 0)]
    for t in ts:
        t.start()
    time.sleep(0.5 if spin else 0)
    pdh.PdhCollectQueryData(_q)
    time.sleep(2)
    pdh.PdhCollectQueryData(_q)
    stop[0] = True
    for t in ts:
        t.join()
    v = FMT()
    pdh.PdhGetFormattedCounterValue(_h, 0x200, None, ctypes.byref(v))
    return v.doubleValue


def power():
    s = SPS()
    ctypes.windll.kernel32.GetSystemPowerStatus(ctypes.byref(s))
    return s.Pct, 'AC' if s.AC == 1 else 'offline'


def last_line(log):
    try:
        lines = [l.rstrip() for l in io.open(log, encoding='utf-8', errors='replace') if l.strip()]
        return lines[-1][:110] if lines else '(empty)'
    except OSError:
        return '(no log yet)'


def reading(p, pct, ind):
    return 'cpu %3.0f%%%s  battery %d%%  indicator %s' % (p, '  THROTTLED' if p < 100 else '', pct, ind)


def main():
    if len(sys.argv) < 3:
        p = cpu_performance()
        pct, ind = power()
        print(reading(p, pct, ind))
        print('fit to measure' if p >= 100 else 'NOT fit to measure: the CPU runs under its nominal clock')
        return 0 if p >= 100 else 1
    log, minutes = sys.argv[1], float(sys.argv[2])
    end = time.time() + minutes * 60
    while True:
        p = cpu_performance(spin=False)
        pct, ind = power()
        line = '%s  %s  | %s' % (time.strftime('%H:%M:%S'), reading(p, pct, ind), last_line(log))
        print(line, flush=True)
        with io.open(OUT, 'a', encoding='utf-8') as f:
            f.write(line + '\n')
        tail = last_line(log)
        if time.time() > end or tail.startswith(('fill complete', 'the tree', 'THE SNAPSHOT', 'Traceback', 'EXIT')) \
                or 'budget stopped' in tail or 'Error' in tail:
            return 0
        time.sleep(178)


if __name__ == '__main__':
    sys.exit(main())
