/*
	Ring++ — the RingPM package manifest.

	Install:
		ringpm install ringpp

	Use, from anywhere:
		load "ringpp.ring"

	The library half is PURE RING and depends on nothing but Ring itself:
	no extension to compile, no DLL, no toolchain, no other package. It is
	relocatable -- rpp/*.ring are loaded relative to ringpp.ring, so the
	package works wherever RingPM puts it. Verified by loading it from an
	unrelated drive with an unrelated working directory.

	The `ringpp` CLI (type checking, static analysis, `why`) SHIPS WITH THE
	PACKAGE as one prebuilt binary per platform (~4 MB, made with Zig). The
	user runs it and compiles nothing -- no C compiler, no clang, no
	toolchain is required or suggested, ever. The Zig source is in the
	repository for anyone who wants to adapt the CLI; only they need the
	Zig compiler.

	Five binaries ship: Windows x64, Linux x64 and arm64 (static musl, so
	one file runs on any Linux), macOS x64 and arm64. Windows and Linux x64
	were EXECUTED against the fixtures and agree rule-for-rule; the other
	three are compiled and format-checked but have not been run, because
	the build machine cannot run them. bin/README.md carries that table --
	the distinction is kept visible rather than rounded up to "supported".
*/

aPackageInfo = [
	:name		= "Ring++",
	:description	= "Safe, measured access to Ring's low-level surface: " +
			  "pointer-backed buffers and views, a list index phase, " +
			  "and a sub-state sandbox. Every facility rests on a " +
			  "primitive Ring already provides.",
	:folder		= "ringpp",
	:developer	= "Mansour Ayouni",
	:email		= "kalidianow@gmail.com",
	:license	= "MIT License",
	:version	= "0.1.0",
	:ringversion	= "1.27",

	:files		= [
		"ringpp.ring",
		"rpp/core.ring",
		"rpp/idioms.ring",
		"rpp/probe.ring",
		"README.md",
		"LICENSE",
		"bin/README.md",
		"docs/FINDINGS.md",
		"docs/CASE-TYPE-SAFETY.md",
		"docs/VM-CONTRACT.md",
		"docs/DESIGN.md",
		"examples/README.md",
		"examples/01-patch-a-large-buffer/example.ring",
		"examples/01-patch-a-large-buffer/README.md",
		"examples/02-pass-a-large-value/example.ring",
		"examples/02-pass-a-large-value/README.md",
		"examples/03-random-access-a-big-list/example.ring",
		"examples/03-random-access-a-big-list/README.md",
		"examples/04-slice-a-large-string/example.ring",
		"examples/04-slice-a-large-string/README.md",
		"examples/05-scan-a-file-without-copying/example.ring",
		"examples/05-scan-a-file-without-copying/README.md",
		"examples/06-a-binary-record-codec/example.ring",
		"examples/06-a-binary-record-codec/README.md",
		"examples/07-run-generated-ring-safely/example.ring",
		"examples/07-run-generated-ring-safely/README.md",
		"examples/08-where-ringpp-loses/example.ring",
		"examples/08-where-ringpp-loses/README.md",
		"tests/probe_smoke.ring",
		"tests/buffer.ring",
		"tests/idioms.ring",
		"tests/fuzz_bounds.ring",
		"tests/name_collision.ring"
	],

	# The CLI binary, per platform. RingPM installs the right list for the
	# host; both architectures are shipped per OS because the manifest has
	# no arch dimension, and picking the wrong one is a clear error message
	# while shipping neither is a broken install. See bin/README.md for
	# which file is which, and how far each one is verified.
	:windowsfiles	= [
		"bin/win64/ringpp.exe"
	],
	:ubuntufiles	= [
		"bin/linux-x64/ringpp",
		"bin/linux-arm64/ringpp"
	],
	:macosfiles	= [
		"bin/macos-x64/ringpp",
		"bin/macos-arm64/ringpp"
	],

	# Nothing. That is deliberate and worth stating: Ring++ is independent
	# of Softanza and of every other package.
	:libs		= [],

	# Runs the behavioural probe, which is the only honest thing to do on
	# install: it checks that THIS Ring still satisfies the assumptions the
	# library is built on (varptr write-through, address stability, ptr2str
	# slicing, packing round-trips, byte order, genarray, sub-states) and
	# names any row that changed. See rpp/probe.ring and docs/DESIGN.md §5.
	:run		= "ring tests/probe_smoke.ring",

	:setup		= "",
	:remove		= "",

	:providerusername = "mansourayouni",
	:website	= "https://github.com/mansourayouni/ringpp",
	:branch		= "main"
]
