/* A stand-in for a generated Ring++ kernel: takes buffer handles and a
   length, returns a scalar. No C++ , no threads, no libc beyond stddef. */
#include <stddef.h>

double rpp_dot(const double *a, const double *b, long n) {
    double d = 0;
    for (long i = 0; i < n; i++) d += a[i] * b[i];
    return d;
}

long rpp_count_byte(const unsigned char *p, long n, unsigned char c) {
    long k = 0;
    for (long i = 0; i < n; i++) if (p[i] == c) k++;
    return k;
}

/* The Ring extension entry point every generated kernel must export.
   Declared by hand here so the probe does not need the Ring headers. */
void ringlib_init(void *pRingState) { (void)pRingState; }
