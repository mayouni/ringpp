# The same rule for a METHOD call: the frame reports the receiver's line,
# not the arguments' last line. Measured on 1.27.
o = new K
o.Go()
class K
    def Go
        This.Boom("a" +
                  "b" +
                  "c")
    def Boom p
        raise("from a three-line method call")
