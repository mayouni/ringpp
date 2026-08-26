package org.softanza.ringpp.demo;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Bundle;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;

/**
 * The whole Android side of running Ring.
 *
 * There is no JNI, no binding layer and no generated glue. The Ring VM is an
 * ordinary executable that Android has already unpacked for us, and this
 * class does three things: find it, hand it the bytecode, and show what it
 * printed. That is the entire integration.
 */
public class MainActivity extends Activity {

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);

        TextView out = new TextView(this);
        out.setTypeface(Typeface.MONOSPACE);
        out.setTextSize(12.5f);
        out.setPadding(28, 40, 28, 40);
        out.setTextIsSelectable(true);
        out.setBackgroundColor(Color.WHITE);
        out.setTextColor(Color.parseColor("#1c2126"));

        ScrollView scroll = new ScrollView(this);
        scroll.setBackgroundColor(Color.WHITE);
        scroll.addView(out);
        setContentView(scroll);

        out.setText(runRing());
    }

    private String runRing() {
        StringBuilder sb = new StringBuilder();
        try {
            // Android unpacked lib/<abi>/libring.so to here and made it
            // executable. Asking for the path rather than assuming one keeps
            // this correct on every ABI the APK carries.
            String vm = getApplicationInfo().nativeLibraryDir + "/libring.so";

            // Assets are entries inside the APK, not files. The VM needs a
            // real path, so the bytecode is copied out once into the app's
            // private directory -- which is also somewhere it may write.
            File home = getFilesDir();
            File code = new File(home, "app.ringo");
            copyAsset("app.ringo", code);

            sb.append("device : ").append(android.os.Build.MODEL).append('\n');
            sb.append("abi    : ").append(android.os.Build.SUPPORTED_ABIS[0]).append('\n');
            sb.append("android: ").append(android.os.Build.VERSION.RELEASE)
              .append("  (API ").append(android.os.Build.VERSION.SDK_INT).append(")\n");
            sb.append("vm     : ").append(new File(vm).length()).append(" bytes\n");
            sb.append("─────────────────────────────────\n\n");

            ProcessBuilder pb = new ProcessBuilder(vm, code.getAbsolutePath());
            pb.directory(home);              // so the program's own file I/O lands somewhere writable
            pb.redirectErrorStream(true);
            Process p = pb.start();

            BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()));
            String line;
            while ((line = r.readLine()) != null) {
                sb.append(line).append('\n');
            }
            int exit = p.waitFor();

            sb.append("\n─────────────────────────────────\n");
            sb.append(exit == 0 ? "exit 0 — the VM ran clean" : "exit " + exit);
        } catch (Exception e) {
            // Shown rather than logged: on a phone there is no console to read.
            sb.append("\nFAILED: ").append(e.toString());
        }
        return sb.toString();
    }

    private void copyAsset(String name, File dest) throws IOException {
        InputStream in = null;
        OutputStream out = null;
        try {
            in = getAssets().open(name);
            out = new FileOutputStream(dest);
            byte[] buf = new byte[8192];
            int n;
            while ((n = in.read(buf)) > 0) {
                out.write(buf, 0, n);
            }
        } finally {
            if (out != null) out.close();
            if (in != null) in.close();
        }
    }
}
