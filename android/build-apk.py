#!/usr/bin/env python3
"""Build an APK that runs a Ring program — without Gradle, Qt, or the NDK.

    python android/build-apk.py

The chain is aapt2 -> javac -> d8 -> zip -> zipalign -> apksigner, which is
what Gradle would drive anyway. Keeping it explicit means every input to the
APK is visible in one readable file, and the only Android requirement is a
standard SDK: no NDK, because the Ring VM is already compiled by phase B2 as
a static musl binary and needs nothing from Android's own libc (F-36).

Sources of the recipe: Ring++'s own runtime stubs for the VM, and the
Gradle-free packaging approach proven in the Restolean boitier.
"""
import os, shutil, subprocess, sys, zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
WORK = HERE / "build"
OUT_APK = HERE / "ringpp-demo.apk"

SDK = Path(os.environ.get("ANDROID_HOME",
      Path(os.environ["LOCALAPPDATA"]) / "Android" / "Sdk"))
JDK = Path(os.environ.get("JAVA_HOME", r"C:\Program Files\Java\jdk-17"))
RING = Path(os.environ.get("RING_HOME", r"D:\ring127")) / "bin" / "ring.exe"

MIN_SDK, TARGET_SDK = 24, 34

# The VM, one per ABI. arm64-v8a is every modern phone; x86_64 is the
# emulator. Both come straight from runtime/, unmodified.
ABIS = {
    "arm64-v8a": ROOT / "runtime" / "linux-arm64" / "ring",
    "x86_64":    ROOT / "runtime" / "linux-x64"   / "ring",
}


def first(paths, what):
    for p in paths:
        if p.exists():
            return p
    sys.exit(f"not found: {what}\n  looked in:\n    " +
             "\n    ".join(str(p) for p in paths))


BT = first([SDK / "build-tools" / v for v in ("35.0.0", "36.0.0", "34.0.0")],
           "Android SDK build-tools")
PLATFORM = first([SDK / "platforms" / v / "android.jar"
                  for v in ("android-34", "android-36", "android-35")],
                 "android.jar")

AAPT2    = BT / "aapt2.exe"
ZIPALIGN = BT / "zipalign.exe"
D8       = BT / "lib" / "d8.jar"
APKSIGN  = BT / "lib" / "apksigner.jar"
JAVA     = JDK / "bin" / "java.exe"
JAVAC    = JDK / "bin" / "javac.exe"
KEYTOOL  = JDK / "bin" / "keytool.exe"
KEYSTORE = HERE / "debug.jks"


def run(cmd, **kw):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, **kw)
    if r.returncode != 0:
        print("FAILED:", " ".join(str(c) for c in cmd))
        print(r.stdout[-3000:])
        print(r.stderr[-3000:])
        sys.exit(1)
    return r


def step(n, msg):
    print(f"  [{n}] {msg}")


def main():
    for p in (AAPT2, ZIPALIGN, D8, APKSIGN, JAVA, JAVAC, PLATFORM, RING):
        if not Path(p).exists():
            sys.exit(f"missing tool: {p}")

    if WORK.exists():
        shutil.rmtree(WORK)
    (WORK / "assets").mkdir(parents=True)
    (WORK / "classes").mkdir(parents=True)
    (WORK / "dex").mkdir(parents=True)

    # 1 -- Ring compiles its own program to bytecode. No C compiler anywhere.
    step(1, "ring -go   (bytecode, no C compiler)")
    src = HERE / "app.ring"
    run([RING, src.name, "-go"], cwd=HERE)
    ringo = HERE / "app.ringo"
    if not ringo.exists():
        sys.exit("ring -go produced no app.ringo")
    shutil.copy(ringo, WORK / "assets" / "app.ringo")
    print(f"        app.ringo  {ringo.stat().st_size} bytes")

    # 2 -- the envelope: manifest + assets, no resources to compile
    step(2, "aapt2 link (manifest + assets)")
    base = WORK / "base.apk"
    run([AAPT2, "link",
         "-I", PLATFORM,
         "--manifest", HERE / "AndroidManifest.xml",
         "-A", WORK / "assets",
         "--min-sdk-version", MIN_SDK,
         "--target-sdk-version", TARGET_SDK,
         "-o", base])

    # 3 -- Java -> class -> dex
    step(3, "javac + d8 (the Activity)")
    javas = list((HERE / "src").rglob("*.java"))
    # -encoding UTF-8 is not optional: without it javac reads the source in
    # the system codepage and every non-ASCII character reaches the phone as
    # mojibake. Seen on the first real-device run, box-drawing rules came out
    # as "â€œâ€".
    run([JAVAC, "-source", "8", "-target", "8", "-nowarn", "-encoding", "UTF-8",
         "-classpath", PLATFORM, "-d", WORK / "classes", *javas])
    classes = list((WORK / "classes").rglob("*.class"))
    run([JAVA, "-cp", D8, "com.android.tools.r8.D8",
         "--lib", PLATFORM, "--min-api", MIN_SDK,
         "--output", WORK / "dex", *classes])

    # 4 -- the VM per ABI, plus the dex, into the APK
    #      lib*.so is not decoration: Android extracts and chmod +x only those
    step(4, "add classes.dex and the VM for each ABI")
    with zipfile.ZipFile(base, "a", zipfile.ZIP_DEFLATED) as z:
        z.write(WORK / "dex" / "classes.dex", "classes.dex")
        for abi, vm in ABIS.items():
            if not vm.exists():
                print(f"        SKIP {abi}: no stub at {vm}")
                continue
            z.write(vm, f"lib/{abi}/libring.so")
            print(f"        lib/{abi}/libring.so  {vm.stat().st_size} bytes")

    # 5 -- align, then sign
    step(5, "zipalign + apksigner")
    aligned = WORK / "aligned.apk"
    run([ZIPALIGN, "-f", "-p", "4", base, aligned])

    if not KEYSTORE.exists():
        print("        creating a debug keystore (first run only)")
        run([KEYTOOL, "-genkeypair", "-keystore", KEYSTORE,
             "-storepass", "ringpp", "-keypass", "ringpp",
             "-alias", "ringpp", "-keyalg", "RSA", "-keysize", "2048",
             # '+' separates AVAs in an RDN, so "Ring++" must be escaped or
             # keytool reads it as three empty fields and refuses.
             "-validity", "10000", "-dname", r"CN=Ring\+\+ demo, O=Softanza"])

    run([JAVA, "-jar", APKSIGN, "sign",
         "--ks", KEYSTORE, "--ks-pass", "pass:ringpp", "--key-pass", "pass:ringpp",
         "--out", OUT_APK, aligned])

    size = OUT_APK.stat().st_size
    print(f"\n  built  {OUT_APK.name}   {size/1024/1024:.1f} MB")
    print( "  install:  adb install -r android/ringpp-demo.apk")
    print( "  launch :  adb shell am start -n org.softanza.ringpp.demo/.MainActivity")


if __name__ == "__main__":
    main()
