/* Headroom kernels -- native side. Same algorithms, doubles like Ring. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double ms(clock_t a, clock_t b) {
    return (double)(b - a) * 1000.0 / (double)CLOCKS_PER_SEC;
}

int main(void) {
    clock_t t1, t2;

    /* K1 */
    {
        const long N = 20000000;
        double b = 3, s = 0;
        t1 = clock();
        for (long i = 1; i <= N; i++) s += (double)i * b;
        t2 = clock();
        printf("K1 native : %.1f ms   s=%.0f\n", ms(t1, t2), s);
    }

    /* K2 */
    {
        const long M = 1000000;
        double *a = malloc(M * sizeof(double));
        double *c = malloc(M * sizeof(double));
        double d = 0;
        const int R = 200;
        for (long i = 0; i < M; i++) { a[i] = (i + 1) * 0.5; c[i] = (i + 1) * 0.25; }
        t1 = clock();
        for (int r = 0; r < R; r++) { d = 0; for (long i = 0; i < M; i++) d += a[i] * c[i]; }
        t2 = clock();
        printf("K2 native : %.3f ms   d=%.0f   (%d reps)\n", ms(t1, t2) / R, d, R);
        free(a); free(c);
    }

    /* K3 */
    {
        const char *chunk = "1234,alpha,beta,gamma,42\n";
        size_t cl = strlen(chunk);
        size_t total = cl * 200000;
        char *big = malloc(total + 1);
        for (long i = 0; i < 200000; i++) memcpy(big + i * cl, chunk, cl);
        big[total] = 0;
        long n = 0;
        const int R = 200;
        t1 = clock();
        for (int r = 0; r < R; r++) { n = 0; for (size_t i = 0; i < total; i++) if (big[i] == ',') n++; }
        t2 = clock();
        printf("K3 native : %.3f ms   n=%ld   (bytes=%zu, %d reps)\n", ms(t1, t2) / R, n, total, R);
        free(big);
    }
    return 0;
}
