//! `ringpp build --target android` — a signed APK from a Ring program.
//!
//! ## The one target that is not toolchain-free
//!
//! Every other `--target` costs nothing: the runtime stub is prebuilt by
//! phase B2 and `ringpp build` only has to copy it. Android cannot work that
//! way. An APK is a signed archive with a *binary* manifest, and nothing but
//! Google's own `aapt2` produces that format. So this target needs an Android
//! SDK and a JDK, and this file says so out loud rather than letting the
//! command look free and fail late.
//!
//! What it still does NOT need, which is the whole point:
//!
//!   no NDK          the VM is phase B2's static musl binary. It is already
//!                   an Android-compatible arm64 executable and asks nothing
//!                   of bionic (FINDINGS F-36).
//!   no Qt           and so no Qt Creator, and no project to open by hand
//!   no Gradle       the chain below is what Gradle would drive anyway
//!   no JNI          the VM is a process, not a library. There is no binding
//!                   layer to generate, and nothing to keep in sync.
//!   no C compiler   `ring -go` emits bytecode; nothing here compiles C
//!
//! ## The chain
//!
//!   aapt2 link    manifest + assets -> base.apk (this is the binary-XML step)
//!   javac         the generated Activity
//!   jar cf        classes -> classes.jar, so d8 takes one input and this
//!                 file never has to walk a directory tree
//!   d8            classes.jar -> classes.dex
//!   jar uf        classes.dex and lib/<abi>/libring.so into base.apk
//!   zipalign      4-byte, page-aligned
//!   apksigner     v2/v3
//!
//! `jar uf` is used rather than a ZIP writer written here, and that choice
//! was verified before it was made: `resources.arsc` must stay STORED or
//! Android 11+ refuses the install outright, and appending with `jar` was
//! measured to leave its compression method untouched.
//!
//! ## Two things Android will not forgive
//!
//! The VM ships as `lib/<abi>/libring.so`. It is an executable and not a
//! shared library, but the name is not cosmetic: Android extracts and marks
//! executable *only* files matching `lib*.so`. And `extractNativeLibs="true"`
//! is what makes it appear on the filesystem at all — without it the VM stays
//! inside the APK as a compressed entry and cannot be run as a process.
//!
//! Both were learned the expensive way in an earlier project and are encoded
//! here so nobody pays for them twice.

const std = @import("std");
const builtin = @import("builtin");

/// Below this, apksigner also does v1 (jar) signing and the archive grows a
/// META-INF manifest per entry. 24 is also the first API level where running
/// a bundled executable from nativeLibraryDir is dependable.
const MIN_SDK = "24";
const TARGET_SDK = "34";

/// The bytecode is copied into the APK under a fixed name, so the generated
/// Java below is a constant with nothing interpolated into its body.
const ASSET = "app.ringo";

pub const Options = struct {
    entry: []const u8,
    entry_base: []const u8,
    ringo_bytes: []const u8,
    out: []const u8,
    package: ?[]const u8 = null,
    label: ?[]const u8 = null,
    sdk: ?[]const u8 = null,
    jdk: ?[]const u8 = null,
    keystore: ?[]const u8 = null,
    app_version: ?[]const u8 = null,
    runtime_dir: ?[]const u8 = null,
    ring_used: []const u8 = "",
};

fn exists(p: []const u8) bool {
    std.fs.cwd().access(p, .{}) catch return false;
    return true;
}

/// Numeric, component-wise, so `9.0.0` never sorts above `35.0.0` the way a
/// plain string compare would.
fn dottedGreater(x: []const u8, y: []const u8) bool {
    var ix = std.mem.splitScalar(u8, x, '.');
    var iy = std.mem.splitScalar(u8, y, '.');
    while (true) {
        const nx = ix.next();
        const ny = iy.next();
        if (nx == null and ny == null) return false;
        const vx = if (nx) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;
        const vy = if (ny) |s| std.fmt.parseInt(u64, s, 10) catch 0 else 0;
        if (vx != vy) return vx > vy;
    }
}

/// Highest-versioned subdirectory of `dir`, optionally after stripping a
/// fixed prefix (`android-34` -> `34`). Returns the full path.
///
/// Prereleases are considered only when nothing else is installed. This
/// machine had `36.1.0-rc1` sitting above `36.0.0`, and picking the newest
/// number alone would silently build every user's APK with a release
/// candidate of the build tools — a difference nobody asked for and nobody
/// would see until something behaved oddly.
fn newestSubdir(a: std.mem.Allocator, dir: []const u8, prefix: []const u8) ?[]const u8 {
    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return null;
    defer d.close();
    var best: ?[]const u8 = null;
    var best_pre = true;
    var it = d.iterate();
    while (it.next() catch null) |e| {
        if (e.kind != .directory) continue;
        if (!std.mem.startsWith(u8, e.name, prefix)) continue;
        const ver = e.name[prefix.len..];
        if (ver.len == 0 or ver[0] < '0' or ver[0] > '9') continue;
        const pre = std.mem.indexOfScalar(u8, ver, '-') != null;
        const better = best == null or
            (best_pre and !pre) or
            (best_pre == pre and dottedGreater(ver, best.?[prefix.len..]));
        if (!better) continue;
        best = a.dupe(u8, e.name) catch continue;
        best_pre = pre;
    }
    const b = best orelse return null;
    return std.fs.path.join(a, &.{ dir, b }) catch null;
}

const Run = struct { ok: bool, out: []u8, err: []u8 };

fn run(gpa: std.mem.Allocator, w: anytype, argv: []const []const u8) !bool {
    const r = std.process.Child.run(.{
        .allocator = gpa,
        .argv = argv,
        .max_output_bytes = 8 * 1024 * 1024,
    }) catch |e| {
        try w.print("  FAILED to launch {s}: {s}\n", .{ argv[0], @errorName(e) });
        return false;
    };
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    const failed = switch (r.term) {
        .Exited => |c| c != 0,
        else => true,
    };
    if (failed) {
        try w.print("\nringpp build: this step failed —\n  ", .{});
        for (argv) |x| try w.print("{s} ", .{x});
        try w.print("\n", .{});
        if (r.stderr.len > 0) try w.print("{s}\n", .{tail(r.stderr, 3000)});
        if (r.stdout.len > 0) try w.print("{s}\n", .{tail(r.stdout, 2000)});
    }
    return !failed;
}

fn tail(s: []const u8, n: usize) []const u8 {
    return if (s.len <= n) s else s[s.len - n ..];
}

/// A Java package the compiler will accept, derived from the entry name.
/// Anything that is not a lowercase letter or digit becomes `_`, and a
/// leading digit gets a letter in front of it.
fn derivePackage(a: std.mem.Allocator, base: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8){};
    try buf.appendSlice(a, "org.ringpp.");
    if (base.len == 0 or (base[0] >= '0' and base[0] <= '9')) try buf.append(a, 'a');
    for (base) |c| {
        const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
        try buf.append(a, if ((lower >= 'a' and lower <= 'z') or (lower >= '0' and lower <= '9')) lower else '_');
    }
    return buf.items;
}

fn xmlEscape(a: std.mem.Allocator, s: []const u8) ![]const u8 {
    var b = std.ArrayList(u8){};
    for (s) |c| switch (c) {
        '&' => try b.appendSlice(a, "&amp;"),
        '<' => try b.appendSlice(a, "&lt;"),
        '>' => try b.appendSlice(a, "&gt;"),
        '"' => try b.appendSlice(a, "&quot;"),
        else => try b.append(a, c),
    };
    return b.items;
}

const JAVA_BODY =
    \\
    \\import android.app.Activity;
    \\import android.graphics.Color;
    \\import android.graphics.Typeface;
    \\import android.os.Bundle;
    \\import android.widget.ScrollView;
    \\import android.widget.TextView;
    \\
    \\import java.io.BufferedReader;
    \\import java.io.File;
    \\import java.io.FileOutputStream;
    \\import java.io.IOException;
    \\import java.io.InputStream;
    \\import java.io.InputStreamReader;
    \\import java.io.OutputStream;
    \\
    \\/**
    \\ * Generated by `ringpp build --target android`. Edits here are lost on the
    \\ * next build.
    \\ *
    \\ * This is the whole Android side of running Ring: no JNI, no binding layer,
    \\ * no generated glue. The VM is an ordinary executable that Android has
    \\ * already unpacked, and this class finds it, hands it the bytecode, and
    \\ * shows what it printed.
    \\ */
    \\public class MainActivity extends Activity {
    \\
    \\    @Override
    \\    protected void onCreate(Bundle state) {
    \\        super.onCreate(state);
    \\
    \\        TextView out = new TextView(this);
    \\        out.setTypeface(Typeface.MONOSPACE);
    \\        out.setTextSize(12.5f);
    \\        out.setPadding(28, 40, 28, 40);
    \\        out.setTextIsSelectable(true);
    \\        out.setBackgroundColor(Color.WHITE);
    \\        out.setTextColor(Color.parseColor("#1c2126"));
    \\
    \\        ScrollView scroll = new ScrollView(this);
    \\        scroll.setBackgroundColor(Color.WHITE);
    \\        scroll.addView(out);
    \\        setContentView(scroll);
    \\
    \\        out.setText(runRing());
    \\    }
    \\
    \\    private String runRing() {
    \\        StringBuilder sb = new StringBuilder();
    \\        try {
    \\            // Android unpacked lib/<abi>/libring.so to here and marked it
    \\            // executable. Asking for the path rather than assuming one keeps
    \\            // this correct on every ABI the APK carries.
    \\            String vm = getApplicationInfo().nativeLibraryDir + "/libring.so";
    \\
    \\            // Assets are entries inside the APK, not files. The VM needs a
    \\            // real path, so the bytecode is copied out once into the app's
    \\            // private directory, which is also somewhere it may write.
    \\            File home = getFilesDir();
    \\            File code = new File(home, "app.ringo");
    \\            copyAsset("app.ringo", code);
    \\
    \\            sb.append("device : ").append(android.os.Build.MODEL).append('\n');
    \\            sb.append("abi    : ").append(android.os.Build.SUPPORTED_ABIS[0]).append('\n');
    \\            sb.append("android: ").append(android.os.Build.VERSION.RELEASE)
    \\              .append("  (API ").append(android.os.Build.VERSION.SDK_INT).append(")\n");
    \\            sb.append("vm     : ").append(new File(vm).length()).append(" bytes\n");
    \\            sb.append("---------------------------------\n\n");
    \\
    \\            ProcessBuilder pb = new ProcessBuilder(vm, code.getAbsolutePath());
    \\            pb.directory(home);   // so the program's own file I/O lands somewhere writable
    \\            pb.redirectErrorStream(true);
    \\            Process p = pb.start();
    \\
    \\            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
    \\            String line;
    \\            while ((line = r.readLine()) != null) {
    \\                sb.append(line).append('\n');
    \\            }
    \\            int exit = p.waitFor();
    \\
    \\            sb.append("\n---------------------------------\n");
    \\            sb.append(exit == 0 ? "exit 0 - the VM ran clean" : "exit " + exit);
    \\        } catch (Exception e) {
    \\            // Shown rather than logged: on a phone there is no console to read.
    \\            sb.append("\nFAILED: ").append(e.toString());
    \\        }
    \\        return sb.toString();
    \\    }
    \\
    \\    private void copyAsset(String name, File dest) throws IOException {
    \\        InputStream in = null;
    \\        OutputStream out = null;
    \\        try {
    \\            in = getAssets().open(name);
    \\            out = new FileOutputStream(dest);
    \\            byte[] buf = new byte[8192];
    \\            int n;
    \\            while ((n = in.read(buf)) > 0) {
    \\                out.write(buf, 0, n);
    \\            }
    \\        } finally {
    \\            if (out != null) out.close();
    \\            if (in != null) in.close();
    \\        }
    \\    }
    \\}
    \\
;

/// arm64-v8a is every modern phone; x86_64 is the emulator. Both stubs come
/// straight out of `runtime/`, byte-identical to what the desktop Linux
/// targets ship — this is not a port, it is the same file under the name
/// Android insists on.
const Abi = struct { abi: []const u8, plat: []const u8 };
const ABIS = [_]Abi{
    .{ .abi = "arm64-v8a", .plat = "linux-arm64" },
    .{ .abi = "x86_64", .plat = "linux-x64" },
};

fn toolMissing(w: anytype, what: []const u8, where: []const u8) !u8 {
    try w.print("ringpp build --target android: could not find {s}.\n", .{what});
    try w.print("  looked: {s}\n\n", .{where});
    try w.print("  Android is the one target that needs a toolchain. It requires an\n", .{});
    try w.print("  Android SDK (build-tools + a platform android.jar) and a JDK 17+.\n", .{});
    try w.print("  It does NOT require the NDK, Qt, Gradle or a C compiler.\n\n", .{});
    try w.print("  Point at them with --sdk <dir> and --jdk <dir>, or set\n", .{});
    try w.print("  ANDROID_HOME and JAVA_HOME.\n", .{});
    return 1;
}

pub fn assemble(a: std.mem.Allocator, gpa: std.mem.Allocator, w: anytype, o: Options) !u8 {
    // ------------------------------------------------------------- toolchain
    const sdk = o.sdk orelse
        std.process.getEnvVarOwned(a, "ANDROID_HOME") catch
        std.process.getEnvVarOwned(a, "ANDROID_SDK_ROOT") catch blk: {
        const local = std.process.getEnvVarOwned(a, "LOCALAPPDATA") catch break :blk "";
        break :blk try std.fs.path.join(a, &.{ local, "Android", "Sdk" });
    };
    if (sdk.len == 0 or !exists(sdk))
        return toolMissing(w, "the Android SDK", if (sdk.len == 0) "$ANDROID_HOME, $ANDROID_SDK_ROOT" else sdk);

    const bt = newestSubdir(a, try std.fs.path.join(a, &.{ sdk, "build-tools" }), "") orelse
        return toolMissing(w, "Android SDK build-tools", try std.fs.path.join(a, &.{ sdk, "build-tools" }));
    const platdir = newestSubdir(a, try std.fs.path.join(a, &.{ sdk, "platforms" }), "android-") orelse
        return toolMissing(w, "an Android platform (android.jar)", try std.fs.path.join(a, &.{ sdk, "platforms" }));
    const android_jar = try std.fs.path.join(a, &.{ platdir, "android.jar" });
    if (!exists(android_jar)) return toolMissing(w, "android.jar", android_jar);

    const jdk = o.jdk orelse std.process.getEnvVarOwned(a, "JAVA_HOME") catch "";
    if (jdk.len == 0 or !exists(jdk)) return toolMissing(w, "a JDK", if (jdk.len == 0) "$JAVA_HOME" else jdk);

    const x = if (builtin.target.os.tag == .windows) ".exe" else "";
    const aapt2 = try std.fmt.allocPrint(a, "{s}{c}aapt2{s}", .{ bt, std.fs.path.sep, x });
    const zipalign = try std.fmt.allocPrint(a, "{s}{c}zipalign{s}", .{ bt, std.fs.path.sep, x });
    const d8_jar = try std.fs.path.join(a, &.{ bt, "lib", "d8.jar" });
    const signer_jar = try std.fs.path.join(a, &.{ bt, "lib", "apksigner.jar" });
    const javac = try std.fmt.allocPrint(a, "{s}{c}bin{c}javac{s}", .{ jdk, std.fs.path.sep, std.fs.path.sep, x });
    const java = try std.fmt.allocPrint(a, "{s}{c}bin{c}java{s}", .{ jdk, std.fs.path.sep, std.fs.path.sep, x });
    const jar = try std.fmt.allocPrint(a, "{s}{c}bin{c}jar{s}", .{ jdk, std.fs.path.sep, std.fs.path.sep, x });
    const keytool = try std.fmt.allocPrint(a, "{s}{c}bin{c}keytool{s}", .{ jdk, std.fs.path.sep, std.fs.path.sep, x });

    for ([_][]const u8{ aapt2, zipalign, d8_jar, signer_jar, javac, java, jar, keytool }) |t|
        if (!exists(t)) return toolMissing(w, std.fs.path.basename(t), t);

    // ----------------------------------------------------------------- stubs
    // Refuse before doing any work if no ABI can be served. A one-ABI APK is
    // a legitimate outcome and says so; a zero-ABI APK installs and then
    // fails on the phone, which is the failure this project does not ship.
    var abis = std.ArrayList(Abi){};
    var stubs = std.ArrayList([]const u8){};
    const self_dir = std.fs.selfExeDirPathAlloc(a) catch null;
    for (ABIS) |ab| {
        var cands = std.ArrayList([]const u8){};
        if (o.runtime_dir) |d| try cands.append(a, try std.fs.path.join(a, &.{ d, ab.plat, "ring" }));
        if (self_dir) |d| try cands.append(a, try std.fs.path.join(a, &.{ d, "runtime", ab.plat, "ring" }));
        try cands.append(a, try std.fs.path.join(a, &.{ "runtime", ab.plat, "ring" }));
        for (cands.items) |c| if (exists(c)) {
            try abis.append(a, ab);
            try stubs.append(a, c);
            break;
        };
    }
    if (abis.items.len == 0) {
        try w.print("ringpp build --target android: no Linux runtime stub found, and the\n", .{});
        try w.print("  Android VM is exactly that stub (F-36). Looked for runtime/linux-arm64/ring\n", .{});
        try w.print("  and runtime/linux-x64/ring beside ringpp and under ./runtime/.\n", .{});
        try w.print("  Build them (phase B2):  powershell -File tests\\b2_runtimes.ps1\n", .{});
        return 1;
    }

    // ------------------------------------------------------------- generate
    const pkg = o.package orelse try derivePackage(a, o.entry_base);
    const label = try xmlEscape(a, o.label orelse o.entry_base);
    const vname = o.app_version orelse "1.0";

    const work = try std.fs.path.join(a, &.{ o.out, "work" });
    std.fs.cwd().deleteTree(work) catch {};
    const dir_assets = try std.fs.path.join(a, &.{ work, "assets" });
    const dir_classes = try std.fs.path.join(a, &.{ work, "classes" });
    const dir_dex = try std.fs.path.join(a, &.{ work, "dex" });
    const dir_stage = try std.fs.path.join(a, &.{ work, "stage" });
    const pkg_path = try a.dupe(u8, pkg);
    for (pkg_path) |*c| if (c.* == '.') {
        c.* = std.fs.path.sep;
    };
    const dir_java = try std.fs.path.join(a, &.{ work, "java", pkg_path });
    for ([_][]const u8{ dir_assets, dir_classes, dir_dex, dir_stage, dir_java }) |d|
        try std.fs.cwd().makePath(d);

    try std.fs.cwd().writeFile(.{
        .sub_path = try std.fs.path.join(a, &.{ dir_assets, ASSET }),
        .data = o.ringo_bytes,
    });

    const manifest = try std.fmt.allocPrint(a,
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<!-- Generated by ringpp build for Android. Do not edit; rebuilding replaces it.
        \\     Two attributes here are load-bearing. extractNativeLibs makes Android
        \\     unpack lib/[abi]/libring.so onto the filesystem and mark it executable;
        \\     without it the VM stays inside the APK and cannot run as a process. -->
        \\<manifest xmlns:android="http://schemas.android.com/apk/res/android"
        \\    package="{s}"
        \\    android:versionCode="1"
        \\    android:versionName="{s}">
        \\  <application
        \\      android:label="{s}"
        \\      android:extractNativeLibs="true"
        \\      android:allowBackup="false">
        \\    <activity
        \\        android:name=".MainActivity"
        \\        android:exported="true"
        \\        android:label="{s}">
        \\      <intent-filter>
        \\        <action android:name="android.intent.action.MAIN" />
        \\        <category android:name="android.intent.category.LAUNCHER" />
        \\      </intent-filter>
        \\    </activity>
        \\  </application>
        \\</manifest>
        \\
    , .{ pkg, vname, label, label });
    const manifest_path = try std.fs.path.join(a, &.{ work, "AndroidManifest.xml" });
    try std.fs.cwd().writeFile(.{ .sub_path = manifest_path, .data = manifest });

    const java_src = try std.fs.path.join(a, &.{ dir_java, "MainActivity.java" });
    try std.fs.cwd().writeFile(.{
        .sub_path = java_src,
        .data = try std.fmt.allocPrint(a, "package {s};\n{s}", .{ pkg, JAVA_BODY }),
    });

    // ----------------------------------------------------------------- build
    const base_apk = try std.fs.path.join(a, &.{ work, "base.apk" });
    try w.print("  [1/6] aapt2 link   (manifest + bytecode)\n", .{});
    if (!try run(gpa, w, &.{ aapt2, "link", "-I", android_jar, "--manifest", manifest_path, "-A", dir_assets, "--min-sdk-version", MIN_SDK, "--target-sdk-version", TARGET_SDK, "-o", base_apk })) return 1;

    try w.print("  [2/6] javac        (the generated Activity)\n", .{});
    // -encoding UTF-8 is not optional: without it javac reads the source in
    // the system codepage, and on a phone the mojibake is the first thing you
    // see. Measured on a real device before this was generated code.
    if (!try run(gpa, w, &.{ javac, "-source", "8", "-target", "8", "-nowarn", "-encoding", "UTF-8", "-classpath", android_jar, "-d", dir_classes, java_src })) return 1;

    const classes_jar = try std.fs.path.join(a, &.{ work, "classes.jar" });
    if (!try run(gpa, w, &.{ jar, "cf", classes_jar, "-C", dir_classes, "." })) return 1;

    try w.print("  [3/6] d8           (dex)\n", .{});
    if (!try run(gpa, w, &.{ java, "-cp", d8_jar, "com.android.tools.r8.D8", "--lib", android_jar, "--min-api", MIN_SDK, "--output", dir_dex, classes_jar })) return 1;

    try w.print("  [4/6] pack         (dex + the VM per ABI)\n", .{});
    try std.fs.cwd().copyFile(try std.fs.path.join(a, &.{ dir_dex, "classes.dex" }), std.fs.cwd(), try std.fs.path.join(a, &.{ dir_stage, "classes.dex" }), .{});
    for (abis.items, stubs.items) |ab, stub| {
        const libdir = try std.fs.path.join(a, &.{ dir_stage, "lib", ab.abi });
        try std.fs.cwd().makePath(libdir);
        const dst = try std.fs.path.join(a, &.{ libdir, "libring.so" });
        try std.fs.cwd().copyFile(stub, std.fs.cwd(), dst, .{});
        const st = try std.fs.cwd().statFile(dst);
        try w.print("        lib/{s}/libring.so  {d} bytes\n", .{ ab.abi, st.size });
    }
    if (!try run(gpa, w, &.{ jar, "uf", base_apk, "-C", dir_stage, "." })) return 1;

    try w.print("  [5/6] zipalign\n", .{});
    const aligned = try std.fs.path.join(a, &.{ work, "aligned.apk" });
    if (!try run(gpa, w, &.{ zipalign, "-f", "-p", "4", base_apk, aligned })) return 1;

    try w.print("  [6/6] apksigner\n", .{});
    // The keystore lives in the output directory and is reused. A fresh key
    // every build would make `adb install -r` fail with a signature mismatch
    // on the second run, which reads as a broken app rather than a new key.
    const ks = o.keystore orelse try std.fs.path.join(a, &.{ o.out, "debug.jks" });
    if (!exists(ks)) {
        try w.print("        creating a debug keystore (first build only)\n", .{});
        if (!try run(gpa, w, &.{ keytool, "-genkeypair", "-keystore", ks, "-storepass", "ringpp", "-keypass", "ringpp", "-alias", "ringpp", "-keyalg", "RSA", "-keysize", "2048", "-validity", "10000", "-dname", "CN=ringpp debug, OU=ringpp build, O=Ring" })) return 1;
    }
    const apk = try std.fs.path.join(a, &.{ o.out, try std.fmt.allocPrint(a, "{s}.apk", .{o.entry_base}) });
    std.fs.cwd().deleteFile(apk) catch {};
    if (!try run(gpa, w, &.{ java, "-jar", signer_jar, "sign", "--ks", ks, "--ks-pass", "pass:ringpp", "--key-pass", "pass:ringpp", "--out", apk, aligned })) return 1;

    // -------------------------------------------------------------- manifest
    var mf = std.ArrayList(u8){};
    const mw = mf.writer(a);
    try mw.print("Ring++ build manifest - ringpp build --target android\n\n", .{});
    try mw.print("entry     : {s}\n", .{o.entry});
    try mw.print("package   : {s}\n", .{pkg});
    try mw.print("apk       : {s}\n", .{std.fs.path.basename(apk)});
    try mw.print("ring used : {s}\n", .{o.ring_used});
    try mw.print("sdk       : {s}\n", .{sdk});
    try mw.print("build-tls : {s}\n", .{std.fs.path.basename(bt)});
    try mw.print("platform  : {s}\n", .{std.fs.path.basename(platdir)});
    try mw.print("jdk       : {s}\n", .{jdk});
    try mw.print("min/target: API {s} / {s}\n\n", .{ MIN_SDK, TARGET_SDK });
    try mw.print("abis bundled:\n", .{});
    for (abis.items, stubs.items) |ab, stub| try mw.print("  {s:<12} {s}\n", .{ ab.abi, stub });
    if (abis.items.len < ABIS.len) {
        try mw.print("\n  NOT every ABI is present. This APK installs only on the ones\n", .{});
        try mw.print("  listed above. Build the missing B2 stub and rebuild.\n", .{});
    }
    try mw.print("\nThe VM is phase B2's static musl binary, byte-identical to the one\n", .{});
    try mw.print("the linux targets ship. No NDK, no Qt, no Gradle, no JNI (F-36).\n", .{});
    try mw.print("\ninstall:  adb install -r {s}\n", .{apk});
    try mw.print("launch :  adb shell am start -n {s}/.MainActivity\n", .{pkg});
    try std.fs.cwd().writeFile(.{
        .sub_path = try std.fs.path.join(a, &.{ o.out, "BUILD-MANIFEST.txt" }),
        .data = mf.items,
    });

    const st = try std.fs.cwd().statFile(apk);
    try w.print("\nbuilt  {s}   {d:.1} MB\n", .{ apk, @as(f64, @floatFromInt(st.size)) / (1024.0 * 1024.0) });
    try w.print("  package  {s}\n", .{pkg});
    try w.print("  abis     ", .{});
    for (abis.items) |ab| try w.print("{s} ", .{ab.abi});
    try w.print("\n\ninstall:  adb install -r {s}\n", .{apk});
    try w.print("launch :  adb shell am start -n {s}/.MainActivity\n", .{pkg});
    if (abis.items.len < ABIS.len)
        try w.print("\nNOTE: {d} of {d} ABIs bundled - see BUILD-MANIFEST.txt\n", .{ abis.items.len, ABIS.len });
    return 0;
}
