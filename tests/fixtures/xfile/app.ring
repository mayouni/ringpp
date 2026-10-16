# Cross-file arity: Helper lives in lib.ring, reached through the load
# graph. Ring's C22 (FINDINGS F-26) guarantees no other Helper can exist
# in this program, which is what makes the report certain.
load "lib.ring"
? Helper(1)
