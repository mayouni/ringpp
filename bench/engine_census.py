# -*- coding: utf-8 -*-
r"""The engine boundary, measured.

Softanza's engine is 92 DLLs of Zig. Each one is a Ring EXTENSION: it
exports ringlib_init and speaks Ring's C API -- so rnxc, which is not
Ring's VM, cannot host any of them. This scan says what that boundary is
made of, so the way across can be priced rather than guessed:

  * every bridge file imports ONE module, engine/src/ring_api.zig, as `R`,
    and calls Ring's API only through it -- so `R` is the whole boundary;
  * how many of R's names carry scalars and handles (the 4-type ABI in
    src/native.zig already does), and how many carry Ring LISTS (an ABI
    extension);
  * how many bridges use only the first kind.

    python bench/engine_census.py            (needs D:\GitHub\stzlib)

Measured 2026-09-09: 88 bridges, 2,495 registered names, 37 R names --
19 scalar/handle (942 sites), 17 list (818 sites), 1 alias; 67 bridges
scalar-only, 21 with list traffic.
"""
import io, os, re, sys, collections

E = os.environ.get('STZ_ENGINE') or r'D:\GitHub\stzlib\libraries\stzlib\engine\src'
SCALAR = {'ring_vm_api_getnumber', 'ring_vm_api_retnumber', 'ring_vm_api_getstring',
          'ring_vm_api_getstringsize', 'ring_vm_api_retstring', 'ring_vm_api_retstring2',
          'ring_vm_api_getcpointer', 'ring_vm_api_retcpointer', 'ring_vm_api_paracount',
          'ring_vm_api_isstring', 'ring_vm_api_isnumber', 'ring_vm_api_ispointer',
          'ring_vm_error', 'ring_vm_funcregister2', 'ring_string_size',
          'getHandle', 'retHandle', 'releaseHandle', 'resolveHandle', 'releaseSlot',
          'storeHandle', 'registerAll', 'Reg', 'RingString'}
LIST = {'ring_vm_api_retlist', 'ring_vm_api_newlist', 'ring_vm_api_getlist', 'ring_vm_api_islist',
        'ring_list_adddouble', 'ring_list_addstring2', 'ring_list_addint', 'ring_list_addstring',
        'ring_list_getitem_gc', 'ring_list_getlist_gc', 'ring_list_gettype_gc', 'ring_list_newlist',
        'ring_list_isnumber_gc', 'ring_list_islist_gc', 'ring_list_isstring_gc',
        'ring_item_getnumber', 'ringListSize', 'ringItemStringPtr', 'ringItemStringSize',
        'RingList', 'gl', 'il'}


def main():
    if not os.path.isdir(E):
        print('SKIP  engine not present at', E)
        return 0
    files = sorted(f for f in os.listdir(E) if f.startswith('ring_bridge') and f.endswith('.zig'))
    use = collections.Counter(); regs = 0; scalar_only = 0; listy = 0; bypass = collections.Counter()
    for f in files:
        s = io.open(os.path.join(E, f), encoding='utf-8', errors='replace').read()
        regs += len(re.findall(r'\.name\s*=\s*"', s))
        h = collections.Counter(re.findall(r'\bR\.([A-Za-z_0-9]+)\b', s)); use.update(h)
        # A bridge reaching Ring's API NOT through R would be a second
        # boundary. Measured 2026-09-09: none does -- zero bridges declare an
        # extern of their own, all 88 alias from R (`const g = R.ring_vm_api_
        # getnumber;`) and R declares the API as `pub extern fn`. The bare
        # calls counted here are those aliases, called by their alias name.
        raw = re.findall(r'(?<!R\.)\b(ring_vm_api_[a-z_0-9]+|ring_list_[a-z_0-9]+)\s*\(', s)
        raw = [x for x in raw if not re.search(r'fn\s+' + re.escape(x) + r'\s*\(', s)]  # not its own wrappers
        bypass.update(raw)
        if re.search(r'^\s*(pub\s+)?extern\s+fn\s+ring_', s, re.M):
            print('!! %s declares its own extern of Ring\'s API -- a second boundary' % f)
        if any(k in LIST for k in h): listy += 1
        else: scalar_only += 1
    sc = sum(v for k, v in use.items() if k in SCALAR); li = sum(v for k, v in use.items() if k in LIST)
    other = {k: v for k, v in use.items() if k not in SCALAR and k not in LIST}
    print('bridges            %d' % len(files))
    print('registered names   %d' % regs)
    print('R names used       %d  (scalar/handle %d, list %d, other %d %s)' % (
        len(use), len([k for k in use if k in SCALAR]), len([k for k in use if k in LIST]), len(other), other or ''))
    print('R call sites       scalar/handle %d, list %d' % (sc, li))
    print('bridges            scalar-only %d, with list traffic %d' % (scalar_only, listy))
    print('R names called through a local alias (still R, not a bypass): %s' % (dict(bypass.most_common(5)) or 'none'))
    print()
    print('list names, by use: ' + ', '.join('%s=%d' % kv for kv in use.most_common() if kv[0] in LIST))
    return 0


if __name__ == '__main__':
    sys.exit(main())
