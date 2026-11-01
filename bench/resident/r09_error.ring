# Its top level stops on an error nothing catches; the program carries on.
? "r09: before"
raise("r09 stops here")
? "r09: never"
