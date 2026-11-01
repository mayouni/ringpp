# RingServ's library at work, on what needs no host native: the answers its
# host would get. RsCatalogLimits is in serv.ring and calls RsJoin in data.ring,
# a file admitted AFTER it -- the call reaches RsJoin only through the late link.
RppResidentBehaviour()

func RppResidentBehaviour
	? "limits: " + RsCatalogLimits([:min = 1, :max = 9, :of = "abc"])
	? "contracts: " + Contract("Shop", [:buy = [:in = [[:qty, [:type = "number", :min = 1]]]]])
	? "spec: " + len(RsContractSpec("shop", "buy"))
	? "check: [" + RsContractCheck("shop", "buy", [:qty = 0]) + "]"
	? "check ok: [" + RsContractCheck("shop", "buy", [:qty = 3]) + "]"
	aParts = RsSplitOn("a,b,,c", ",")
	? "split: " + len(aParts) + " " + aParts[3]
	aCfg = RsConfigParse("port: 8080" + nl + "app: shop" + nl + "workers: 2" + nl)
	for aPair in aCfg
		? "config: " + aPair[1] + " = " + aPair[2]
	next
	? "same: " + RsSame("x", "x") + RsSame(1, 2)
	ExpectTrue("one equals one", 1 = 1)
	ExpectTrue("one equals two", 1 = 2)
	? "failed: " + RsTestReport(0)
