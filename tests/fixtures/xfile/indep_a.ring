# indep_a and indep_b both define Mine() with DIFFERENT arities and
# neither loads the other: two independent programs sharing a directory.
# Nothing may be reported about either -- the scan root is not a program.
func Mine p
    return p
