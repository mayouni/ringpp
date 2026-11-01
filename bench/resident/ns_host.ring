# D31, HAROSERVER'S NAMESPACES, ON THE RESIDENT VM. An app admitted with admitapp(cApp, cSource, aExports) is a
# namespace of its own: its functions, classes and globals are `app::Name`; its code finds its own names first and the
# base's after; another app reaches it only through what it exports, spelt `app.Name`; the base (this host) reaches an
# app's names as `app::Name` -- the host owns its apps. Run with `rnxc resident ns_host.ring`. Ring has no namespaces to
# compare with, so expect_ns.txt is golden.
? "host: start"
$nTotal = 1
$nBaseOnly = 42

# two apps define the same names -- Echo, Hello, a global $nTotal -- and neither meets the other, nor the base
cShop = "$nTotal = 10" + nl +
	"func Echo x" + nl + tab + "return 'shop:' + x" + nl +
	"func Hello" + nl + tab + "return Echo('hi')" + nl +
	"func Total" + nl + tab + "return $nTotal" + nl +
	"func Loud x" + nl + tab + "return Shout(x)" + nl +
	"func BaseOnly" + nl + tab + "return $nBaseOnly" + nl +
	"func HasEcho" + nl + tab + "return isfunction('Echo')" + nl
? "admit shop: " + admitapp("shop", cShop, ["Hello"])
cBank = "$nTotal = 20" + nl +
	"func Echo x" + nl + tab + "return 'bank:' + x" + nl +
	"func Hello" + nl + tab + "return Echo('hi')" + nl +
	"func Total" + nl + tab + "return $nTotal" + nl
? "admit bank: " + admitapp("bank", cBank, [])
? "base Echo: " + Echo("x")
? "shop Hello: " + Run("shop::Hello")
? "bank Hello: " + Run("bank::Hello")
? "totals: base " + $nTotal + ", shop " + Run("shop::Total") + ", bank " + Run("bank::Total")
? "shop falls back to the base: " + Run1("shop::Loud", "quiet") + ", reads " + Run("shop::BaseOnly")
? "isfunction: in shop " + Run("shop::HasEcho") + ", in the base " + isfunction("Hello")
? "by its public name: " + Run("shop.Hello")
Fails("bank exports nothing: ", "bank.Hello")

# another app's class and function, only through its exports
cLedger = "func Sum a, b" + nl + tab + "return a + b" + nl +
	"func Hidden" + nl + tab + "return 'hidden'" + nl +
	"class Entry" + nl + tab + "@nAmount = 0" + nl +
	tab + "func init n" + nl + tab + tab + "@nAmount = n" + nl +
	tab + "func Amount" + nl + tab + tab + "return @nAmount" + nl
? "admit ledger: " + admitapp("ledger", cLedger, ["Entry", "Sum"])
cReport = "func Make n" + nl + tab + "o = new ledger.Entry(n)" + nl + tab + "return o.Amount()" + nl +
	"func Tot" + nl + tab + "return ledger.Sum(2, 3)" + nl +
	"func Peek" + nl + tab + "return ledger.Hidden()" + nl +
	"func Sneak" + nl + tab + "cN = 'ledger::Hidden'" + nl + tab + "return call cN()" + nl +
	"func Kind" + nl + tab + "o = new ledger.Entry(1)" + nl + tab + "return classname(o)" + nl
? "admit report: " + admitapp("report", cReport, [])
? "report makes a ledger entry: " + Run1("report::Make", 7)
? "report sums through ledger: " + Run("report::Tot")
? "the entry's class: " + Run("report::Kind")
Fails("an unexported function: ", "report::Peek")
Fails("another app's own name, by string: ", "report::Sneak")

# late: an app reached before it is admitted, and a name an app reaches before anything defines it
? "admit early: " + admitapp("early", "func Ask" + nl + tab + "return nexus.Ping()" + nl, [])
Fails("before nexus: ", "early::Ask")
? "admit nexus: " + admitapp("nexus", "func Ping" + nl + tab + "return 'pong'" + nl, ["Ping"])
? "after nexus: " + Run("early::Ask")
? "admit late: " + admitapp("late", "func L1" + nl + tab + "return Later(3)" + nl, [])
Fails("before any Later: ", "late::L1")
? "admit the base's Later: " + admitcode("later", "func Later n" + nl + tab + "return n * 100" + nl)
? "late falls back to the base: " + Run("late::L1")
? "admit late's own Later: " + admitapp("late", "func Later n" + nl + tab + "return n + 1" + nl, [])
? "late finds its own first: " + Run("late::L1")

# an app's class takes its app's parent before the base's
cZoo = "class Animal" + nl + tab + "func Sound" + nl + tab + tab + "return 'zoo animal'" + nl +
	"class Dog from Animal" + nl + tab + "func Bark" + nl + tab + tab + "return This.Sound()" + nl
? "admit zoo: " + admitapp("zoo", cZoo, ["Dog"])
oDog = new zoo.Dog
? "zoo's Dog: " + oDog.Bark() + " (" + classname(oDog) + ")"
oA = new Animal
? "the base's Animal: " + oA.Sound()

# replaced within its app, the other app untouched
? "replace shop: " + replaceapp("shop", "func Echo x" + nl + tab + "return 'SHOP:' + x" + nl)
? "shop Hello now: " + Run("shop::Hello") + ", bank Hello: " + Run("bank::Hello")

# refused, each with the program as it was
TryAdmit("an export naming nothing: ", "bad", "func X" + nl + tab + "return 1" + nl, ["Y"])
TryAdmit("a name that is no identifier: ", "9bad", "func X" + nl + tab + "return 1" + nl, [])
TryAdmit("shop defines Echo again: ", "shop", "func Echo x" + nl + tab + "return x" + nl, [])
try
	releasecode("late")
	? "never printed"
catch
	? "an app's admission: " + cCatchError
done
? "host: done"

func Run cName
	return call cName()

func Run1 cName, x
	return call cName(x)

func Fails cWhat, cName
	try
		Run(cName)
		? cWhat + "never printed"
	catch
		? cWhat + cCatchError
	done

func TryAdmit cWhat, cApp, cCode, aExports
	try
		admitapp(cApp, cCode, aExports)
		? cWhat + "never printed"
	catch
		? cWhat + cCatchError
	done

func Echo x
	return "base:" + x

func Shout x
	return upper(x)

class Animal
	func Sound
		return "base animal"
