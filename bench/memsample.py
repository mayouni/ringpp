# -*- coding: utf-8 -*-
"""Run a command and report its PEAK working set, sampled from outside.

Neither Ring nor Ring++ can report its own memory from inside a
program, and a finished process cannot be measured at all, so this polls
`PeakWorkingSet64` while the child runs and keeps the largest value seen.
The child must therefore do its work before exiting -- map200k.ring
holds its table through a million lookups, which is plenty.

    python bench/memsample.py <exe> <args...>

Prints the child's own output, then one line:  PEAK_WORKING_SET_MB <n>
"""
import subprocess, sys, time

try:
    import psutil
except ImportError:
    psutil = None


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd = sys.argv[1:]
    child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    peak = 0
    if psutil is not None:
        p = psutil.Process(child.pid)
        while child.poll() is None:
            try:
                info = p.memory_info()
                cur = getattr(info, 'peak_wset', None) or info.rss
                peak = max(peak, cur)
            except psutil.Error:
                break
            time.sleep(0.02)
    else:
        # Windows without psutil: poll through PowerShell, coarser but honest
        while child.poll() is None:
            q = subprocess.run(
                ['powershell', '-NoProfile', '-Command',
                 '(Get-Process -Id %d -ErrorAction SilentlyContinue).PeakWorkingSet64' % child.pid],
                capture_output=True, text=True)
            try:
                peak = max(peak, int(q.stdout.strip() or 0))
            except ValueError:
                pass
            time.sleep(0.1)
    out, _ = child.communicate()
    sys.stdout.write(out)
    print('PEAK_WORKING_SET_MB %.1f' % (peak / (1024.0 * 1024.0)))
    return child.returncode


if __name__ == '__main__':
    sys.exit(main())
