# Ring++'s zip shim: the Ring-side half of `ziplib.ring`, with the three
# LoadLib lines removed.
#
# Ring's own shim (vendor/ring-ext/ringzip/ziplib.ring, which the ORACLE
# still uses unchanged) opens with
#
#     if iswindows()  LoadLib("ring_libzip.dll") ...
#
# because that is how RING reaches a native: an extension DLL. Ring++ has
# the twelve names built in (src/zip.zig), so there is nothing to load --
# and until that was true, this line quietly found
# `D:\Ring127\bin\ring_libzip.dll` on the PATH, which is a reach outside the
# repository that commitment 1 forbids.
#
# Everything below is Ring's shim, character for character, because it is
# the API Softanza calls. `ring_libzip.rh` is not loaded because it is an
# EMPTY file in Ring's tree.

func zip_addfile oZip,cFile
	zip_entry_open(oZip,cFile)
	zip_entry_fwrite(oZip,cFile)
	zip_entry_close(oZip)

class zip

	func SetFileName cName
		cZipFileName = cName

	func GetFileName
		return cZipFileName

	func Open cMode
		oZip = zip_openfile(GetFileName(),cMode)

	func Close
		zip_close(oZip)

	func AddFile cFileName
		zip_addfile(oZip,cFileName)

	func ExtractAllFiles cFolder
		zip_extract_allfiles(GetFileName(),"myfolder")

	func FilesCount
		return zip_filescount(oZip)

	func GetFileNameByIndex nIndex
		return zip_getfilenamebyindex(oZip,nIndex)

	func NewEntry
		return new ZipEntry(oZip)

	private

		cZipFileName = ""
		oZip

class ZipEntry

	func init oZipPara
		oZip = oZipPara

	func Open cFileName
		zip_entry_open(oZip,cFileName)

	func WriteFile cFileName
		zip_entry_fwrite(oZip,cFileName)

	func WriteString cString
		zip_entry_write(oZip,cString)

	func Close
		zip_entry_close(oZip)

	private
		oZip
