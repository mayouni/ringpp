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

	The `ringpp` CLI (check / why / ast) is a separate, optional Zig build
	and is deliberately NOT part of this package: a Ring package should not
	require a C toolchain to install. Build it from source when you want it.
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
		"docs/FINDINGS.md",
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
