// The same six algorithms as algorithms.ring, for Android's own runtime.
//
//     javac -> d8 -> adb push -> dalvikvm -cp bench.dex Bench
//
// WHAT THIS COMPARISON IS, AND IS NOT.
//
// It is: the same work, the same phone, the same minute, on two runtimes
// that ship on that phone. Every CHECK value must match algorithms.ring
// exactly -- that is what makes the timings comparable at all, and it is
// asserted rather than hoped for.
//
// It is NOT a claim that one language is better than the other. ART is an
// optimising compiler with a JIT and ahead-of-time profiles; Ring's VM is a
// straightforward bytecode interpreter with no JIT at all. A compiler beating
// an interpreter is the expected result, not a discovery, and the interesting
// question is only HOW FAR apart they are and WHERE the gap widens.
//
// The no-JIT property is also exactly why the Ring VM runs on Android at all
// (FINDINGS F-36): it never asks the kernel for executable memory, so the
// seccomp filter that kills other portable runtimes never fires on it. The
// thing that costs Ring speed here is the thing that bought it the platform.

public class Bench {

    static final long MOD = 1000000007L;

    public static void main(String[] args) {
        int reps = 3;
        System.out.println("Java / ART algorithm suite");
        System.out.println("==============================================");
        System.out.println("");

        long best, t;
        long v = 0;

        best = -1;
        for (int r = 0; r < reps; r++) { t = now(); v = sieve(300000); best = keep(best, now() - t); }
        report("sieve", best, v);

        best = -1;
        for (int r = 0; r < reps; r++) { t = now(); v = matmul(80); best = keep(best, now() - t); }
        report("matmul", best, v);

        best = -1;
        for (int r = 0; r < reps; r++) { t = now(); v = fib(25); best = keep(best, now() - t); }
        report("fib", best, v);

        // Built exactly as the Ring file builds it: 1-based i, (i*7919) % 100003.
        int n = 8000;
        long[] data = new long[n];
        for (int i = 1; i <= n; i++) data[i - 1] = (i * 7919L) % 100003L;
        long[] sorted = null;
        best = -1;
        for (int r = 0; r < reps; r++) { t = now(); sorted = mergeSort(data); best = keep(best, now() - t); }
        for (int i = 1; i < sorted.length; i++)
            if (sorted[i] < sorted[i - 1]) throw new RuntimeException("unsorted at " + i);
        report("mergesort", best, sum32(sorted));

        best = -1;
        for (int r = 0; r < reps; r++) { t = now(); v = binSearchAll(sorted, 6000); best = keep(best, now() - t); }
        report("binsearch", best, v);

        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < 4000; i++) sb.append("the quick brown fox ");
        String big = sb.toString();
        best = -1;
        for (int r = 0; r < reps; r++) { t = now(); v = byteScan(big); best = keep(best, now() - t); }
        report("bytescan", best, v);

        System.out.println("");
        System.out.println("SUITE OK");
    }

    static long now() { return System.nanoTime(); }
    static long keep(long best, long ns) { return (best < 0 || ns < best) ? ns : best; }

    static void report(String name, long ns, long check) {
        System.out.println("CHECK " + name + " " + check);
        // Two decimals, formatted by hand so no locale can put a comma here
        // and break the campaign's parser on someone else's phone.
        long hundredths = (ns + 5000) / 10000;
        System.out.println("TIME  " + name + " " + (hundredths / 100) + "." +
                           (hundredths % 100 < 10 ? "0" : "") + (hundredths % 100));
    }

    static long sieve(int n) {
        byte[] flag = new byte[n + 1];
        long count = 0;
        for (int i = 2; i <= n; i++) {
            if (flag[i] == 0) {
                count++;
                for (long j = (long) i * i; j <= n; j += i) flag[(int) j] = 1;
            }
        }
        return count;
    }

    static long matmul(int n) {
        long[][] a = new long[n + 1][n + 1];
        long[][] b = new long[n + 1][n + 1];
        for (int i = 1; i <= n; i++)
            for (int j = 1; j <= n; j++) { a[i][j] = (i + j) % 7; b[i][j] = ((long) i * j) % 5; }
        long acc = 0;
        for (int i = 1; i <= n; i++) {
            long[] row = a[i];
            for (int j = 1; j <= n; j++) {
                long s = 0;
                for (int k = 1; k <= n; k++) s += row[k] * b[k][j];
                acc = (acc + s * (i + j)) % MOD;
            }
        }
        return acc;
    }

    static long fib(int n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

    static long[] mergeSort(long[] l) {
        if (l.length <= 1) return l;
        int mid = l.length / 2;
        long[] left = new long[mid], right = new long[l.length - mid];
        System.arraycopy(l, 0, left, 0, mid);
        System.arraycopy(l, mid, right, 0, l.length - mid);
        return merge(mergeSort(left), mergeSort(right));
    }

    static long[] merge(long[] a, long[] b) {
        long[] out = new long[a.length + b.length];
        int i = 0, j = 0, k = 0;
        while (i < a.length && j < b.length) out[k++] = (a[i] <= b[j]) ? a[i++] : b[j++];
        while (i < a.length) out[k++] = a[i++];
        while (j < b.length) out[k++] = b[j++];
        return out;
    }

    static long binSearchAll(long[] sorted, int queries) {
        long hits = 0;
        int n = sorted.length;
        for (int q = 1; q <= queries; q++) {
            long target = (q * 7919L) % (n * 2L);
            int lo = 1, hi = n;
            while (lo <= hi) {
                int mid = (lo + hi) / 2;
                if (sorted[mid - 1] == target) { hits++; break; }
                else if (sorted[mid - 1] < target) lo = mid + 1;
                else hi = mid - 1;
            }
        }
        return hits;
    }

    static long byteScan(String s) {
        long h = 0;
        for (int i = 0; i < s.length(); i++) h = (h * 131 + s.charAt(i)) % MOD;
        return h;
    }

    static long sum32(long[] l) {
        long h = 0;
        for (int i = 0; i < l.length; i++) h = (h * 31 + l[i]) % MOD;
        return h;
    }
}
