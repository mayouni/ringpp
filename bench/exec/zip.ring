# ZIP, on Ring++'s own native ABI, with no C and no DLL.
#
# Ring reaches zip through `ring_libzip.dll`, a C extension wrapping
# kuba--/zip and miniz -- about ten thousand vendored lines that exist
# because a Ring native had to be C. `src/zip.zig` is the same twelve names
# over `src/native.zig`, built INTO rnxc, so nothing is loaded at all.
#
# What this pins is the API Softanza actually calls in stzZipFile.ring:
# openfile 'w' and 'r', addfile (entry_open + entry_fwrite + entry_close),
# close, filescount, getfilenamebyindex -- 1-BASED, as Ring's binding is --
# and extract_file.
#
# WHAT IT DOES NOT PIN, because the two runtimes cannot agree on it: the
# SIZE of the archive. Ring deflates through miniz; Ring++ STORES, because
# Zig 0.15.2's deflate compressor does not work (`flate.Compress.drain`
# ends in `@panic("TODO")` and `Compress.Simple` does not compile). Reading
# a deflated archive DOES work, so the two interoperate in both directions
# -- measured by hand, both ways, on 2026-09-19:
#
#     rnx writes (252 bytes, stored)    -> RING reads every entry back
#     RING writes (366 bytes, deflated) -> rnx reads every entry back
#
# and the sizes are not printed here for exactly that reason.

load "ziplib.ring"

cBig = "the first file, with enough text that a compressor would have something to chew on -- aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
write("zp_a.txt", cBig)
write("zp_b.txt", "second")

? "-- build an archive --"
oZip = zip_openfile("zp.zip", "w")
zip_addfile(oZip, "zp_a.txt")
zip_addfile(oZip, "zp_b.txt")
zip_close(oZip)
? "  the archive exists : " + fexists("zp.zip")

? ""
? "-- read it back --"
oZip = zip_openfile("zp.zip", "r")
? "  entries            : " + zip_filescount(oZip)
? "  the first          : " + zip_getfilenamebyindex(oZip, 1)
? "  the second         : " + zip_getfilenamebyindex(oZip, 2)
zip_close(oZip)

? ""
? "-- and the bytes survive the trip --"
? "  the short one      : [" + zip_extract_file("zp.zip", "zp_b.txt") + "]"
? "  the long one, len  : " + len(zip_extract_file("zp.zip", "zp_a.txt"))
? "  identical          : " + (zip_extract_file("zp.zip", "zp_a.txt") = cBig)
? "  a name not in it   : [" + zip_extract_file("zp.zip", "no_such_entry.txt") + "]"

remove("zp_a.txt")
remove("zp_b.txt")
remove("zp.zip")
? ""
? "done"
