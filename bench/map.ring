// The map type (charter §6 item 7), A/B'd against Ring 1.27. Everything
// here agrees with Ring except M10, which is the one REGISTERED
// divergence -- a read never writes -- and is named in ab-known.txt.
//
// Measured on 1.27 before any of this was built: keys compare
// case-insensitively; symbol keys are stored lowercased; a hash is
// indexable as an ordered list of pairs; writing a new key appends;
// writing an existing key updates in place; a missing key reads as "".

func M1()
	h = [ :name = "ali", :age = 30 ]
	return h["name"]

func M2()
	h = [ :name = "ali", :age = 30 ]
	k = "na" + "me"
	return h[k]

func M3()
	h = [ :name = "ali" ]
	return h["NAME"]

func M4()
	h = [ :name = "ali", :age = 30 ]
	return h[2][1] + "=" + h[2][2]

func M5()
	h = [ :name = "ali" ]
	h["name"] = "amina"
	return h["name"] + " " + len(h)

func M6()
	h = [ :name = "ali" ]
	h["city"] = "Niamey"
	return h["city"] + " " + len(h)

func M7()
	h = [ :b = 2, :a = 1 ]
	return h[1][1]

func M8()
	// the value of a missing key is "" on both sides
	h = [ :name = "ali" ]
	v = h["missing"]
	return "[" + v + "]"

func M9()
	// past HINDEX_MIN, so the index is what answers
	h = []
	for i = 1 to 12
		h + [ "k" + i, i * 10 ]
	next
	return h["k7"] + h["K12"]

func M10()
	// THE DIVERGENCE: Ring inserts the missing key on a read (len 2),
	// Ring++ does not (len 1). Registered in ab-known.txt.
	h = [ :name = "ali" ]
	v = h["missing"]
	return len(h)

func M11()
	// a positional overwrite of a PAIR drops the index; the keyed read
	// after it must still be right
	h = []
	for i = 1 to 12
		h + [ "k" + i, i ]
	next
	v0 = h["k3"]
	h[3] = [ "zz", 99 ]
	return h["zz"] + h["k4"]

func M12()
	// deleting a pair shifts positions; the keyed read after it must
	// still be right
	h = []
	for i = 1 to 12
		h + [ "k" + i, i ]
	next
	v0 = h["k9"]
	del(h, 2)
	return h["k9"] + h["k12"]

func M13()
	return Lookup([ :x = 7, :y = 8 ], "y")

func Lookup(h, k)
	return h[k]
