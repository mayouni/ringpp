# Two reactors spawn at the same moment. A exits at once; B lives ~3 s.
# If B inherits A's stdout pipe, A's job is ready only when B exits.
# usage: <runtime> spawn_race.ring <path of stz_reactor.dll>
# bench/spawn_race.py runs it on the three runtimes, each with its own build.
loadlib(sysargv[len(sysargv)])
r1 = StzEngineReactorCreate()
r2 = StzEngineReactorCreate()
cA = "C:\Windows\System32\cmd.exe" + char(10) + "/c" + char(10) + "echo a"
cB = "C:\Windows\System32\PING.EXE" + char(10) + "-n" + char(10) + "4" + char(10) + "127.0.0.1"
for t = 1 to 3
	jA = StzEngineReactorSubmitSpawn(r1, cA)
	t0 = clock()
	c = StzEngineReactorSpawnAwait(r1, jA, 6000)
	? "control " + t + ": A alone ready after " + floor((clock() - t0) * 1000 / clockspersecond()) + " ms"
next
nLate = 0
for t = 1 to 8
	jA = StzEngineReactorSubmitSpawn(r1, cA)
	jB = StzEngineReactorSubmitSpawn(r2, cB)
	t0 = clock()
	c = StzEngineReactorSpawnAwait(r1, jA, 6000)
	ms = floor((clock() - t0) * 1000 / clockspersecond())
	if ms > 1500  nLate++  ok
	? "trial " + t + ": A ready after " + ms + " ms"
	StzEngineReactorSpawnAwait(r2, jB, 8000)
next
? "A held open by B: " + nLate + " of 8"
StzEngineReactorDestroy(r1)
StzEngineReactorDestroy(r2)
