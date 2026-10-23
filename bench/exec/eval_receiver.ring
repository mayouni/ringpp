# F-92, measured on both 1.27 builds. A bare call inside eval, in a
# method, resolves on the RECEIVER's class -- Softanza's StzObjectQ().IfQ
# evals 'NumberOfItems() > 2' on whatever subclass it was called on --
# and a call BY NAME reaches functions, never a method. Ring++ resolved on
# the class that DEFINES the method holding the eval, then took a method
# of the same name from any class as if it were a function.

a = new Two
b = new Three
? "1 subclass method  : " + a.Ask("Size() > 2")
? "2 another subclass : " + b.Ask("Size() > 2")
? "3 the same again   : " + a.Ask("Size() > 2") + " " + b.Ask("Size() > 2")
? "4 global function  : " + a.Ask("Helper() = 7")
? "5 call by name     : " + ByName("Size")
? "6 call by name, fn : " + ByName("Helper")
? "done"

func Helper
	return 7

func ByName(cName)
	try
		return "" + call cName()
	catch
		return cCatchError
	done

class Base
	def Ask(cCond)
		_bOk_ = 0
		try
			eval("_bOk_ = (" + cCond + ")")
		catch
			return cCatchError
		done
		return "" + _bOk_

class Two from Base
	def Size
		return 2

class Three from Base
	def Size
		return 3
