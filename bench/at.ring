func UA1()
    o = new T
    return o.A1()

func UA2()
    o = new T
    n = o.A2()
    return n + o.@nCount

func UA3()
    o = new T
    n = o.A3(100)
    return n + o.@nCount

func UA4()
    o = new T
    return o.A4()

// UA6/UA7: WRITING another object's attribute, which UA2/UA3 only read.
// Both directions need the receiver's class PROVED -- `new T` here -- and
// where it is not proved they refuse, which is the whole safety of it.
// The Softanza shape this came from is a clone: every attribute of one
// object copied into another of the same class (StzOrgChartSimulationQ()._CloneChart).
func UA6()
	o = new T
	o.@nCount = 42
	return o.@nCount

func UA7()
	a = new T
	b = new T
	a.@nCount = 7
	b.@nCount = a.@nCount + 1
	return b.@nCount

class T
    @nCount = 7
    @nBare

    def A1()
        return @nCount

    def A2()
        @nCount = 99
        return @nCount

    def A3(pnCount)
        @nCount = @nCount + 1
        return @nCount

    def A4()
        @nBare = 3
        return @nBare + @nCount
