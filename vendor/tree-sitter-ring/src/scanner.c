/**
 * External scanner for the Ring language.
 *
 * Emits context-sensitive tokens: FUNC_PARAM_IDENT (first param of
 * `func name param`), SUBSCRIPT_OPEN (`[`), CALL_LPAREN (`(`),
 * DEMOTED_IDENT (to/in/from/step at identifier position), CLASS_FROM
 * (`from` adjacent to class name), and for-loop keywords (to/in/step).
 *
 * Newline rule (mirrors ring_parser_mixer, expr.c:931+): a newline ends
 * the statement, UNLESS a mixer chain is open. Ring skips the EndLine
 * after the closers `)`/`]` (`RING_PARSER_IGNORENEWLINE`), so
 * `f()` + newline + `[0]` and `a[1]` + newline + `[2]` continue the
 * chain; a plain identifier + newline rewinds to the EndLine
 * (expr.c:414-421), so `a` + newline + `[0]` starts a new list-literal
 * statement. The scanner cannot see the anonymous `)`/`]`, so it
 * approximates via persistent state: the newline is skipped only when the
 * last token IT emitted was `[` or `(` (a chain is open).
 */

#include "tree_sitter/parser.h"
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

enum TokenType {
  FUNC_PARAM_IDENT,
  SUBSCRIPT_OPEN,
  DEMOTED_IDENT,
  CLASS_FROM,
  KW_FOR_TO,
  KW_FOR_IN,
  KW_FOR_STEP,
  CALL_LPAREN,
  FUNC_PARAM_OPEN,
};

/* Ring keywords (RING_KEYWORDS in language/include/scanner.h) — a keyword
 * is never a function parameter. Counter-guarded keywords (ok/but/on/case/
 * off/catch/done/again/else/other) are NOT in the demotion set; they stay
 * keywords for the whole extent of their enclosing construct. */
static const char *RING_KEYWORDS[] = {
    "if",
    "to",
    "or",
    "and",
    "not",
    "for",
    "foreach",
    "new",
    "func",
    "from",
    "next",
    "load",
    "else",
    "see",
    "while",
    "ok",
    "class",
    "return",
    "but",
    "end",
    "give",
    "bye",
    "exit",
    "try",
    "catch",
    "done",
    "switch",
    "on",
    "other",
    "off",
    "in",
    "loop",
    "package",
    "import",
    "private",
    "step",
    "do",
    "again",
    "call",
    "elseif",
    "put",
    "get",
    "case",
    "def",
    "endfunc",
    "endclass",
    "endpackage",
    "endif",
    "endfor",
    "endwhile",
    "endswitch",
    "endtry",
    "function",
    "endfunction",
    "break",
    "continue",
    "this",
    "self",
    "super",
    "main",
    "init",
    "operator",
    "bracestart",
    "braceexpreval",
    "braceerror",
    "bracenewline",
    "braceend",
    "ringvm_see",
    "ringvm_give",
    "ringvm_errorhandler",
    "changeringkeyword",
    "changeringoperator",
    "loadsyntax",
    "enablehashcomments",
    "disablehashcomments",
};

#define RING_KEYWORDS_COUNT (sizeof(RING_KEYWORDS) / sizeof(RING_KEYWORDS[0]))
#define MAX_PARAM_LEN 32

enum {
  LAST_NONE = 0,
  LAST_WORD = 1,
  LAST_SUBSCRIPT = 2,
  LAST_CALL = 3,
};

typedef struct {
  unsigned char last;
} ScannerState;

void *tree_sitter_ring_external_scanner_create() {
  ScannerState *s = malloc(sizeof(ScannerState));
  if (s) {
    s->last = LAST_NONE;
  }
  return s;
}

void tree_sitter_ring_external_scanner_destroy(void *payload) { free(payload); }

unsigned tree_sitter_ring_external_scanner_serialize(void *payload,
                                                     char *buffer) {
  ScannerState *s = payload;
  buffer[0] = (char)s->last;
  return 1;
}

void tree_sitter_ring_external_scanner_deserialize(void *payload,
                                                   const char *buffer,
                                                   unsigned length) {
  ScannerState *s = payload;
  if (length >= 1) {
    s->last = (unsigned char)buffer[0];
  }
}

bool tree_sitter_ring_external_scanner_scan(void *payload, TSLexer *lexer,
                                            const bool *valid_symbols) {
  ScannerState *s = payload;
  /*
   * Subscript `[` and call `(`: skip spaces/tabs always. Newlines are
   * skipped only when a mixer chain is open — i.e. when the previous
   * scanner-emitted token was itself `[` or `(` (ring_parser_mixer,
   * expr.c:931+ ignores the EndLine after `]`/`)`; after a plain
   * identifier + newline the call mix is refused because a rewind
   * restores the EndLine, ending the statement). The anonymous closer
   * token is invisible here, so the previous-`[`/`(` approximation is
   * what restores Ring's asymmetry.
   */
  /* `had_leading_ws` is computed before the paren/chain probe runs: that
   * probe skips spaces/tabs to reach a `(` or `[`, which would otherwise
   * hide the adjacency needed by FUNC_PARAM_IDENT / CLASS_FROM below. */
  bool had_leading_ws = lexer->lookahead == ' ' || lexer->lookahead == '\t';
  if (valid_symbols[SUBSCRIPT_OPEN] || valid_symbols[CALL_LPAREN] ||
      valid_symbols[FUNC_PARAM_OPEN]) {
    while (lexer->lookahead == ' ' || lexer->lookahead == '\t' ||
           lexer->lookahead == '\r') {
      lexer->advance(lexer, true);
    }
    /* Skip newlines only while a chain is open: the loop is gated on the
     * chain tokens being valid here — the function-name state never
     * skips a newline, even when s->last is stale (the `)` closer of an
     * earlier call is invisible to the scanner, so LAST_CALL can leak
     * through keyword scans; without this gate `func name` + newline
     * would swallow the next line as a parameter). */
    while ((valid_symbols[SUBSCRIPT_OPEN] || valid_symbols[CALL_LPAREN]) &&
           (s->last == LAST_SUBSCRIPT || s->last == LAST_CALL) &&
           lexer->lookahead == '\n') {
      lexer->advance(lexer, true);
      while (lexer->lookahead == ' ' || lexer->lookahead == '\t' ||
             lexer->lookahead == '\r') {
        lexer->advance(lexer, true);
      }
    }
    if (lexer->lookahead == ';') {
      return false;
    }
    /* `func name (` — the parameter list opener. Emitted only in the
     * parser state right after a function name, so a parenthesized
     * expression can never masquerade as (or compete with) the
     * parameter list (ring_parser always treats the `(` after the
     * function name as the parameter list opener). */
    if (valid_symbols[FUNC_PARAM_OPEN] && lexer->lookahead == '(') {
      lexer->advance(lexer, false);
      lexer->mark_end(lexer);
      lexer->result_symbol = FUNC_PARAM_OPEN;
      s->last = LAST_CALL;
      return true;
    }
    if (valid_symbols[SUBSCRIPT_OPEN] && lexer->lookahead == '[') {
      lexer->advance(lexer, false);
      lexer->mark_end(lexer);
      lexer->result_symbol = SUBSCRIPT_OPEN;
      s->last = LAST_SUBSCRIPT;
      return true;
    }
    if (valid_symbols[CALL_LPAREN] && lexer->lookahead == '(') {
      lexer->advance(lexer, false);
      lexer->mark_end(lexer);
      lexer->result_symbol = CALL_LPAREN;
      s->last = LAST_CALL;
      return true;
    }
  }

  /* Keyword demotion, no-paren parameters, the `class ... from` parent
   * marker and the for-loop keywords share one probe: all decide from the
   * same word, so it is read exactly once. Returning early from one branch
   * before the other ran would starve whichever external token was also
   * valid in this state (DEMOTED_IDENT and FUNC_PARAM_IDENT are both valid
   * right after `func name␣`; CLASS_FROM and DEMOTED_IDENT right after
   * `class name␣`; KW_FOR_* and DEMOTED_IDENT at a for-loop bound). */
  if (!valid_symbols[DEMOTED_IDENT] && !valid_symbols[FUNC_PARAM_IDENT] &&
      !valid_symbols[CLASS_FROM] && !valid_symbols[KW_FOR_TO] &&
      !valid_symbols[KW_FOR_IN] && !valid_symbols[KW_FOR_STEP]) {
    return false;
  }
  /* FUNC_PARAM_IDENT requires the parameter to be separated from the
   * function name by at least one space/tab, on the same statement (no
   * newline/';' in between); CLASS_FROM requires the same adjacency to the
   * class name (a newline in between demotes `from` to a plain attribute —
   * Ring checks for the parent class name immediately after the class name
   * without skipping the EndLine) */
  bool crossed_newline = false;
  while (lexer->lookahead == ' ' || lexer->lookahead == '\t' ||
         lexer->lookahead == '\n' || lexer->lookahead == '\r' ||
         lexer->lookahead == ';') {
    if (lexer->lookahead == '\n' || lexer->lookahead == '\r' ||
        lexer->lookahead == ';') {
      crossed_newline = true;
    }
    lexer->advance(lexer, true);
  }

  /* Consume the identifier-shaped word, remembering its (lower-cased) text
   * to test it against keywords. Buffering stops past MAX_PARAM_LEN: longer
   * names can never collide with a keyword, so the keyword check is simply
   * skipped (lKeyword=false) */
  char buf[MAX_PARAM_LEN + 1];
  unsigned len = 0;
  bool lKeyword = true;
  while (!lexer->eof(lexer)) {
    int32_t c = lexer->lookahead;
    /* Stop at operators/whitespace/delimiters */
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == ';' ||
        c == '"' || c == '\'' || c == '`' || c == '#' || c == '+' || c == '-' ||
        c == '*' || c == '/' || c == '%' || c == '.' || c == '(' || c == ')' ||
        c == '=' || c == ',' || c == '!' || c == '>' || c == '<' || c == '[' ||
        c == ']' || c == ':' || c == '{' || c == '}' || c == '&' || c == '|' ||
        c == '~' || c == '^' || c == '?' || c == 0) {
      break;
    }
    if (lKeyword) {
      if (len < MAX_PARAM_LEN) {
        buf[len++] = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : (char)c;
      } else {
        lKeyword = false;
      }
    }
    lexer->advance(lexer, false);
  }
  if (len == 0) {
    return false;
  }
  /* A word ended the previous statement, so no mixer chain is open */
  s->last = LAST_WORD;

  bool bDemotable = false;
  bool bFrom = false;
  if (lKeyword) {
    buf[len] = '\0';
    bFrom = len == 4 && strcmp(buf, "from") == 0;
    bDemotable =
        (len == 2 && (strcmp(buf, "to") == 0 || strcmp(buf, "in") == 0)) ||
        (len == 4 && (strcmp(buf, "from") == 0 || strcmp(buf, "step") == 0));
  }

  /* `class B from A`: the parent marker must win over demotion when it is
   * adjacent to the class name; a newline in between means the `from`
   * starts a plain attribute statement (Ring checks for the parent name
   * without skipping the EndLine, so `class B` + newline + `from = 1` is a
   * class with a `from` attribute) */
  if (valid_symbols[CLASS_FROM] && bFrom && !crossed_newline) {
    lexer->mark_end(lexer);
    lexer->result_symbol = CLASS_FROM;
    return true;
  }

  /* for-loop keywords: at the end of a loop bound expression the parser
   * expects `to`/`in`/`step` — but a demoted identifier is equally valid
   * there (a brace-less loop body is allowed, so an identifier statement
   * can legally follow the bound). The keyword must win this race:
   * Ring's for-statement branch checks for these keywords explicitly
   * before any identifier look at the token. The for-keyword slots expose
   * the keywords as external tokens precisely so the scanner can see them
   * in valid_symbols and let the keyword win. */
  if (lKeyword && bDemotable) {
    if ((valid_symbols[KW_FOR_TO] && len == 2 && strcmp(buf, "to") == 0) ||
        (valid_symbols[KW_FOR_IN] && len == 2 && strcmp(buf, "in") == 0) ||
        (valid_symbols[KW_FOR_STEP] && len == 4 && strcmp(buf, "step") == 0)) {
      lexer->mark_end(lexer);
      lexer->result_symbol =
          valid_symbols[KW_FOR_TO] && len == 2 && strcmp(buf, "to") == 0
              ? KW_FOR_TO
          : valid_symbols[KW_FOR_IN] && len == 2 && strcmp(buf, "in") == 0
              ? KW_FOR_IN
              : KW_FOR_STEP;
      return true;
    }
  }

  if (valid_symbols[FUNC_PARAM_IDENT] && had_leading_ws && !crossed_newline) {
    if (lKeyword && !bDemotable) {
      /* A (non-demotable) keyword can never be a parameter (e.g. in
       * `func one see "one" + nl`, `see` starts the body) */
      for (unsigned x = 0; x < RING_KEYWORDS_COUNT; x++) {
        if (strcmp(buf, RING_KEYWORDS[x]) == 0) {
          return false;
        }
      }
    }
    lexer->mark_end(lexer);
    lexer->result_symbol = FUNC_PARAM_IDENT;
    return true;
  }

  /* Ring demotes the keywords to/in/from/step back to identifiers whenever
   * the parser is at an identifier position (ring_parser_processkeywords,
   * called from ring_parser_isidentifier — which the parameter list parser
   * also calls, so even `func f(to)` / `func f to` get parameters named
   * `to`). DEMOTED_IDENT is valid in exactly those identifier positions,
   * so matching the word here mirrors the runtime behaviour — the keyword
   * slots of `for`/`class` never see this token as valid, which keeps the
   * keywords intact there. A word longer than the keyword keeps the full
   * identifier (`fromR` ≠ `from`): the boundary check comes from comparing
   * the whole word. */
  if (valid_symbols[DEMOTED_IDENT] && bDemotable) {
    lexer->mark_end(lexer);
    lexer->result_symbol = DEMOTED_IDENT;
    return true;
  }

  return false;
}
