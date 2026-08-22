/* Ring++ probe: what would tree-sitter-ring actually give `ringpp check`?
 * Parses a Ring file and reports:
 *   - parse time and whether the tree has errors
 *   - every function with its parameters and their type annotations
 *   - a walk cost, so we know what a whole-project scan would cost
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "tree_sitter/api.h"

const TSLanguage *tree_sitter_ring(void);

static char *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *b = (char *)malloc((size_t)n + 1);
    size_t got = fread(b, 1, (size_t)n, f);
    b[got] = 0;
    fclose(f);
    *len = got;
    return b;
}

static int reported = 0;
static int count_errors2(TSNode n, const char *src);
static int count_errors2(TSNode n, const char *src) {
    int k = 0;
    if (ts_node_is_error(n) || ts_node_is_missing(n)) {
        k++;
        if (src && reported < 3) {
            reported++;
            TSPoint p = ts_node_start_point(n);
            uint32_t a = ts_node_start_byte(n), b = ts_node_end_byte(n);
            uint32_t l = b - a; if (l > 90) l = 90;
            char buf[96];
            memcpy(buf, src + a, l); buf[l] = 0;
            for (uint32_t i = 0; i < l; i++) if (buf[i] == '\n' || buf[i] == '\r') { buf[i] = 0; break; }
            printf("    %s at line %u col %u: >>%s<<\n",
                   ts_node_is_missing(n) ? "MISSING" : "ERROR", p.row + 1, p.column + 1, buf);
        }
    }
    uint32_t c = ts_node_child_count(n);
    for (uint32_t i = 0; i < c; i++) k += count_errors2(ts_node_child(n, i), src);
    return k;
}

static int nodes = 0;
static void walk(TSNode n, const char *src, int depth, int show) {
    nodes++;
    const char *type = ts_node_type(n);
    if (show && strcmp(type, "function_definition") == 0) {
        TSNode name = ts_node_child_by_field_name(n, "name", 4);
        TSNode plist = ts_node_child_by_field_name(n, "parameters", 10);
        char nm[128] = "?";
        if (!ts_node_is_null(name)) {
            uint32_t a = ts_node_start_byte(name), b = ts_node_end_byte(name);
            uint32_t l = b - a; if (l > 127) l = 127;
            memcpy(nm, src + a, l); nm[l] = 0;
        }
        TSPoint p = ts_node_start_point(n);
        printf("  func %-24s  line %u\n", nm, p.row + 1);
        if (!ts_node_is_null(plist)) {
            uint32_t c = ts_node_named_child_count(plist);
            for (uint32_t i = 0; i < c; i++) {
                TSNode par = ts_node_named_child(plist, i);
                if (strcmp(ts_node_type(par), "typed_parameter") == 0) {
                    TSNode t = ts_node_child_by_field_name(par, "type", 4);
                    TSNode v = ts_node_child_by_field_name(par, "name", 4);
                    char ts[64] = "", vs[64] = "";
                    uint32_t a1 = ts_node_start_byte(t), b1 = ts_node_end_byte(t);
                    uint32_t a2 = ts_node_start_byte(v), b2 = ts_node_end_byte(v);
                    uint32_t l1 = b1 - a1; if (l1 > 63) l1 = 63;
                    uint32_t l2 = b2 - a2; if (l2 > 63) l2 = 63;
                    memcpy(ts, src + a1, l1); ts[l1] = 0;
                    memcpy(vs, src + a2, l2); vs[l2] = 0;
                    TSPoint pp = ts_node_start_point(par);
                    printf("        TYPED  %-10s %-16s  (line %u, col %u)\n",
                           ts, vs, pp.row + 1, pp.column + 1);
                } else {
                    uint32_t a = ts_node_start_byte(par), b = ts_node_end_byte(par);
                    char vs[64]; uint32_t l = b - a; if (l > 63) l = 63;
                    memcpy(vs, src + a, l); vs[l] = 0;
                    printf("        plain  %s\n", vs);
                }
            }
        }
    }
    uint32_t c = ts_node_child_count(n);
    for (uint32_t i = 0; i < c; i++) walk(ts_node_child(n, i), src, depth + 1, show);
}

int main(int argc, char **argv) {
    if (argc < 2) { printf("usage: tsprobe <file.ring> [--quiet|--sexp]\n"); return 2; }
    int sexp = (argc > 2 && strcmp(argv[2], "--sexp") == 0);
    int show = (argc < 3 || strcmp(argv[2], "--quiet") != 0) && !sexp;

    size_t len = 0;
    char *src = slurp(argv[1], &len);
    if (!src) { printf("cannot read %s\n", argv[1]); return 2; }

    TSParser *p = ts_parser_new();
    ts_parser_set_language(p, tree_sitter_ring());

    clock_t t1 = clock();
    TSTree *tree = ts_parser_parse_string(p, NULL, src, (uint32_t)len);
    clock_t t2 = clock();

    TSNode root = ts_node_named_child_count(ts_tree_root_node(tree)) >= 0
                      ? ts_tree_root_node(tree) : ts_tree_root_node(tree);
    int errs = count_errors2(root, src);
    if (sexp) {
        char *s = ts_node_string(root);
        printf("%s\n", s);
        free(s);
    }
    nodes = 0;
    clock_t t3 = clock();
    walk(root, src, 0, show);
    clock_t t4 = clock();

    printf("%-46s %7zu B  parse %6.2f ms  walk %6.2f ms  nodes %6d  errors %d\n",
           argv[1], len,
           (double)(t2 - t1) * 1000.0 / CLOCKS_PER_SEC,
           (double)(t4 - t3) * 1000.0 / CLOCKS_PER_SEC,
           nodes, errs);

    ts_tree_delete(tree);
    ts_parser_delete(p);
    free(src);
    return errs ? 1 : 0;
}

