#!/usr/bin/env bash
# Minimal assertions. Sourced by each test file.
TESTS_RUN=0; TESTS_FAILED=0
ok()   { TESTS_RUN=$((TESTS_RUN+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { TESTS_RUN=$((TESTS_RUN+1)); TESTS_FAILED=$((TESTS_FAILED+1))
         printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n       actual:   %s\n' "$1" "$2" "$3"; }
is()   { [[ "$2" == "$3" ]] && ok "$1" || fail "$1" "$3" "$2"; }
# Subshells, deliberately: the functions under test call die(), which exits.
# Run in the caller's shell and one expected failure ends the whole file, which
# is how the first version of this harness silently stopped after 16 assertions.
succeeds() { if ( "${@:2}" ) >/dev/null 2>&1; then ok "$1"; else fail "$1" "exit 0" "non-zero"; fi; }
fails()    { if ( "${@:2}" ) >/dev/null 2>&1; then fail "$1" "non-zero" "exit 0"; else ok "$1"; fi; }
finish()   { printf '  -- %d assertions, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"; exit $(( TESTS_FAILED > 0 )); }
