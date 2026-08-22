### P1 gate — the compatibility surface, verified by behaviour.
### Prints one line per row and ends with PROBE OK or PROBE FAILED.

load "../ringpp.ring"

func main
	RppProbeAll()
	RppReport()
	? ""
	if RppOk()
		? "PROBE OK — " + len(RPP_PROBES) + " rows on this Ring"
	else
		? "PROBE FAILED — a HARD row did not hold; Ring++ is not supported here"
	ok
