"""The probes behind the site's issues reference (site/issues.html): one small Ring program per issue, run on official Ring 1.27
and on Ring++, each from its own empty folder. `python bench/site_issues_probes.py` writes runtime/site-src/issue_runs.json --
stdout, the first lines of stderr and the exit code of each side -- which bench/site_issues.py renders.

The program the page SHOWS is the program that RAN, comments included: its `#-->` lines say what each runtime prints, and
site_issues.py refuses to render a page whose comments disagree with what was measured. Names are written out (`aHash`, `oPrice`,
`Money`), never single letters."""
import json, os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RING = os.environ.get('RING_OFFICIAL') or r'D:\ring127\bin\ring.exe'
RNXC = os.environ.get('RNXC') or os.path.join(ROOT, 'zig-out', 'bin', 'rnxc.exe')
OUT = os.path.join(ROOT, 'runtime', 'site-src', 'issue_runs.json')

# key: (program, how Ring++ is asked -- 'run' or 'check')
PROBES = {
    'object_operand': ('''# Two prices: one in a variable, one inside a list
oPrice  = new Money { nAmount = 10 }
aPrices = [ new Money { nAmount = 5 } ]

# Add them: the class tells Ring how to add two Money objects
oTotal = oPrice + aPrices[1]
? oTotal.nAmount
#--> Ring 1.27: nothing at all -- the program ends here, exit code 1,
#    with no error message, and no try/catch can stop it
#--> Ring++: 15

? "done"

class Money
	nAmount = 0

	func operator cOp, oOther
		oSum = new Money
		oSum.nAmount = nAmount + oOther.nAmount
		return oSum''', 'run'),

    'empty_catch': ('''# Try something that fails, 3,000 times, and ignore the failure
for nTry = 1 to 3000
	try
		raise("a failure we expect")
	catch
		# nothing to do: the failure is expected
	done
next

? "3,000 failures handled"
#--> Ring 1.27: Error (R4) : Stack Overflow -- every empty catch
#    leaves one slot behind, until there is no room left
#--> Ring++: 3,000 failures handled''', 'run'),

    'hash_read': ('''# A hash list with two entries
aHash = [ :a = 1, :b = 2 ]

# Read an entry that does not exist
nValue = aHash[:c]

# How many entries are there now?
? len(aHash)
#--> Ring 1.27: 3 -- reading :c silently ADDED it to the list
#--> Ring++: 2 -- a read never writes''', 'run'),

    'method_global': ('''# A variable of the program
cName = "Mansour"

# An object whose method uses a variable with the same name
oGreeter = new Greeter
oGreeter.Greet()

# Is the program's variable unchanged?
? cName
#--> Ring 1.27: a visitor -- the method silently overwrote it
#--> Ring++: Mansour -- a method's variables are its own

class Greeter
	def Greet()
		cName = "a visitor"''', 'run'),

    'switch2': ('''nDay = 7

switch nDay
on 6, 7
	? "weekend"
other
	? "weekday"
off
#--> Ring 1.27: weekday -- `on 6, 7` is accepted,
#    but only its first value is ever compared
#--> Ring++: weekend''', 'run'),

    'range_str': ('''# A range of numbers is a list
aNumbers = 1:3
? type(aNumbers)
#--> LIST, on both

# A range of two strings that are not single letters
xRange = "1":"12"
? type(xRange)
#--> Ring 1.27: STRING -- no list, and no error
#--> Ring++: Bad parameter type! -- the operator says it cannot do this''', 'run'),

    'true': ('''# TRUE is a constant of the language... or is it?
TRUE = 0

if TRUE
	? "TRUE is true"
else
	? "TRUE is false now"
ok
#--> Ring 1.27: TRUE is false now
#--> Ring++: refuses the first line, before anything runs''', 'run'),

    'keyword': ('''# Rename the keyword `see` to `show`, from this line on
ChangeRingKeyword see show

show "the keyword see is now spelt show"
#--> Ring 1.27: accepts it, silently, for the rest of the file
#--> Ring++: refuses it, by name''', 'run'),

    'loopvar': ('''func Main
	for nIndex = 1 to 5
		# the loop's work
	next

	# What is nIndex once the loop is over?
	nAfter = nIndex
	? nAfter
	#--> Ring 1.27: 6 -- a value the loop never took
	#--> Ring++: refuses the read -- the variable belongs to its loop''', 'run'),

    'undefined': ('''? "Starting the payroll"
SendPayslips()
#--> Ring 1.27: prints the first line, then fails on the second
#--> Ring++: `rnxc check` reports it before anything runs''', 'check'),
}


def run(cmd, code):
    d = tempfile.mkdtemp(prefix='issue_')
    try:
        with open(os.path.join(d, 'p.ring'), 'w', encoding='utf-8', newline='\n') as f:
            f.write(code + '\n')
        try:
            r = subprocess.run(cmd + ['p.ring'], cwd=d, capture_output=True, timeout=60,
                               env=dict(os.environ, RNXC_NOCACHE='1'))
            out, err, code_ = r.stdout, r.stderr, r.returncode
        except subprocess.TimeoutExpired as e:
            out, err, code_ = e.stdout or b'', b'<timeout>', 'timeout'
        text = out.decode('utf-8', 'replace').replace('\r', '').rstrip('\n')
        errs = [l for l in err.decode('utf-8', 'replace').replace('\r', '').split('\n')
                if l.strip() and not l.startswith(('files ', 'running the top level', 'TOP LEVEL', 'note:', '      '))]
        return {'out': text, 'err': errs[:4], 'exit': code_}
    finally:
        shutil.rmtree(d, ignore_errors=True)


def main():
    res = {'ring': RING, 'rnxc': RNXC, 'runs': {}}
    for k, (code, how) in PROBES.items():
        a = run([RING], code)
        b = run([RNXC, 'check'] if how == 'check' else [RNXC], code)
        res['runs'][k] = {'code': code, 'how': how, 'ring': a, 'ringpp': b}
        print('%-16s Ring: %-38s | Ring++: %s' % (k, (a['out'] or ' '.join(a['err']))[:38].replace('\n', ' / '),
                                                 (b['out'] or ' '.join(b['err']))[:70].replace('\n', ' / ')))
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w', encoding='utf-8') as f:
        json.dump(res, f, indent=1, ensure_ascii=False)
    print('wrote', OUT)


if __name__ == '__main__':
    sys.exit(main())
