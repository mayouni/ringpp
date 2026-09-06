# The dynamic-call gate, split. loadlib registers native FUNCTIONS and
# cannot create a Ring VARIABLE, so it must not silence the variable rule;
# eval can, so an eval whose target cannot be read still must.
load "lib.ring"

$pLib = loadlib("nothing.dll")

func main
	o = new T
	? o.Go("ab")
