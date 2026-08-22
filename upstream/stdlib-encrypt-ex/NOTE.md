# `encrypt_ex` and `decrypt_ex` in stdsecurity.ring call the wrong function

**Status: NOT SENT.** Standing rule — findings go to the Ring Google
Group and Mansour posts them himself, after reviewing the text.

## The finding

`libraries/stdlib/stdsecurity.ring`, lines 52 and 58:

```ring
Func encrypt_ex cString,cKey,cIV,cCipher
    return std_encrypt(cString,cKey,cIV,cCipher)     # 4 args

Func decrypt_ex cString,cKey,cIV,cCipher
    return std_decrypt(cString,cKey,cIV,cCipher)     # 4 args
```

`libraries/stdlib/stdfunctions.ring` defines:

```ring
Func std_encrypt cString,cKey,cIV              # line 470 — 3 parameters
Func std_encrypt_ex cString,cKey,cIV,cCipher   # line 473 — 4 parameters
Func std_decrypt cString,cKey,cIV              # line 476
Func std_decrypt_ex cString,cKey,cIV,cCipher   # line 479
```

The `_ex` wrappers call the **non-`_ex`** function with four arguments,
so both are dead on every call.

## Reproducer

```ring
load "stdlib.ring"
x = new security
? x.encrypt_ex("secret", "key1234567890123", "iv12345678901234", "AES-256-CBC")
```

```
Error (R20) : Calling function with extra number of parameters
```

Confirmed on Ring 1.27.0, Windows x64.

## The fix, if it is the one you want

One word on each line — `std_encrypt` → `std_encrypt_ex` at line 52, and
`std_decrypt` → `std_decrypt_ex` at line 58. Offered as illustration; the
shape of the change is yours.

## How it was found

Static cross-file arity checking over `ring127/libraries` (109 files).
The call is in `stdsecurity.ring`, the definition in `stdfunctions.ring`,
reached through `Load "stdfunctions.ring"` at line 5.

The check is certain rather than a guess because of a Ring behaviour we
measured first: a duplicate function name is `C22` at **load** time, so
within one load graph a resolving name has exactly one live definition.

Three errors were found across Ring's 1,959 files (`libraries`,
`applications`, `samples`), and no false positives. The third is
`applications/getquoteshistory/GetQuotesHistoryDraw.ring:3165`, which
calls `DrawDividendChart()` with no argument against the one-parameter
definition at line 3168.
