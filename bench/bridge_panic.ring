# What a program printed before a native library panicked must survive the
# panic. Run by bench/abort_flush.py, never by exec.py: the oracle cannot
# host a Ring++ bridge, and the process is meant to die.

if LoadLib("./rppbridge.so") = NULL
	? "PANIC PROBE FAIL: the bridge did not load"
	bye
ok

? "before 1"
? "before 2"
? "before 3: " + BridgeAdd(2, 40)
BridgePanic()
? "after the panic -- never printed"
