#!/bin/sh
# distcc-ng (https://github.com/wiki-mod/distcc-ng)
#
# Dev-convenience wrapper around the real build+test verification steps:
# ./autogen.sh, ./configure, make, make check. This does NOT replace any
# of those, or test/testdistcc.py (the project's actual comfychair-based
# test suite) -- it is purely an invocation/reporting convenience layer on
# top of the already-correct machinery, so a caller doesn't have to
# hand-type the same four commands and then manually tail/grep the log
# for a pass/fail verdict every time (issue #238).
#
# Usage:
#   scripts/run-tests.sh                                   # run in cwd
#   scripts/run-tests.sh /path/to/worktree                 # run there
#   scripts/run-tests.sh /path/to/worktree --without-zstd   # extra args
#                                                            # are forwarded
#                                                            # verbatim to
#                                                            # ./configure
#
# Exit status: 0 only if autogen/configure/make all succeeded with no
# compiler warnings, make check ran, and zero comfychair test cases
# reported FAIL. Non-zero (with a message naming the exact failing step)
# otherwise.

set -eu

log() {
    printf '[run-tests] %s\n' "$*"
}

fail() {
    printf '[run-tests] ERROR: %s\n' "$*" >&2
    exit 1
}

# The first argument is a worktree path unless it looks like a configure
# flag (starts with "-"), in which case there is no path argument and
# every argument is forwarded to ./configure -- matching how a caller
# would naturally write "run-tests.sh --without-zstd" from inside an
# already-checked-out worktree.
worktree="."
if [ $# -gt 0 ]; then
    case "$1" in
        -*) : ;;
        *)
            worktree="$1"
            shift
            ;;
    esac
fi

[ -d "$worktree" ] || fail "worktree path '$worktree' does not exist or is not a directory"
[ -x "$worktree/autogen.sh" ] || fail "'$worktree/autogen.sh' not found or not executable -- is this a distcc-ng checkout?"

cd "$worktree"
worktree="$(pwd)"
log "operating in $worktree"

# Per-step logs are kept (not auto-deleted) so a failure -- or a later
# question about a NOTRUN reason -- can be re-inspected after this script
# exits, without having to reproduce the run to get the output back.
logdir="$(mktemp -d "${TMPDIR:-/tmp}/distcc-ng-run-tests.XXXXXX")"
log "step logs will be kept in $logdir"

# Runs one build step, capturing its combined stdout+stderr to a per-step
# log file, and fails fast with a message naming the exact step (not just
# "something failed") on a non-zero exit code -- the whole point of this
# script is to avoid a caller having to guess which of several steps broke
# from a single long, scrolled-off terminal log.
run_step() {
    step_name="$1"
    shift
    step_log="$logdir/$step_name.log"
    log "running: $step_name ($*)"
    if ! "$@" >"$step_log" 2>&1; then
        step_status=$?
        printf '[run-tests] ERROR: step "%s" failed (exit %s) -- last 40 lines of %s:\n' "$step_name" "$step_status" "$step_log" >&2
        tail -n 40 "$step_log" >&2
        exit 1
    fi
    # AGENTS.md rule 31: warnings are errors. ./configure already turns a
    # real C compiler warning into a hard build failure via WERROR_CFLAGS
    # (configure.ac's Werror handling, substituted into every $(CC)
    # invocation in Makefile.in) by default, unless --disable-Werror was
    # explicitly requested -- so this step already would have failed above
    # for that case. This second, independent grep exists for the one path
    # WERROR_CFLAGS does not reach: include_server/setup.py builds the
    # include-server's C extension through Python's own distutils/
    # setuptools, which does not inherit Makefile.in's WERROR_CFLAGS at
    # all, so a warning there would otherwise print but not fail the build.
    if grep -qi 'warning:' "$step_log"; then
        printf '[run-tests] ERROR: step "%s" emitted a compiler warning (warnings are errors, AGENTS.md rule 31) -- matching line(s) from %s:\n' "$step_name" "$step_log" >&2
        grep -i 'warning:' "$step_log" >&2
        exit 1
    fi
    log "step \"$step_name\" OK -- log: $step_log"
}

run_step autogen ./autogen.sh
run_step configure ./configure PYTHON=python3 "$@"
# Deliberately not passing a CFLAGS override (e.g. CFLAGS='-Wall -Werror')
# to this step: Makefile.in's "CFLAGS = @CFLAGS@ ..." assignment (line 18)
# overrides an inherited environment CFLAGS unconditionally, so an env-var
# override here would silently no-op; and a literal "make CFLAGS=..."
# command-line override would instead *replace* configure's own, richer
# warning set (-Wshadow, -Wcast-align, -Wstrict-prototypes, -Wuninitialized,
# etc. -- configure.ac's WERROR_CFLAGS block) with a narrower one, which
# would weaken this check rather than strengthen it (AGENTS.md rule 35).
# ./configure's own default (-Werror unless --disable-Werror) is already
# the same behavior CI relies on -- see .github/workflows/c-build.yml's
# "make" step, which also does not pass a CFLAGS override.
run_step make make

# make check is run directly (not through run_step) because its own exit
# status alone is not the full story: this script's job is to parse its
# output into a concise summary, and that parse has to happen whether
# make check exited 0 or not, so the raw log needs to survive either way.
check_log="$logdir/make_check.log"
log "running: make check (the real test suite -- test/testdistcc.py; not replaced by this script)"
check_status=0
make check >"$check_log" 2>&1 || check_status=$?
cat "$check_log"

if grep -qi 'warning:' "$check_log"; then
    printf '[run-tests] ERROR: make check emitted a compiler warning (warnings are errors, AGENTS.md rule 31) -- matching line(s) from %s:\n' "$check_log" >&2
    grep -i 'warning:' "$check_log" >&2
    exit 1
fi

# Parse comfychair's actual result-line format (test/comfychair.py's
# runtest(): "%-30s" % test_name printed with a trailing separator space,
# immediately followed on the same line by one of OK / FAIL /
# "NOTRUN, <reason>" / INTERRUPT) rather than any assumed "Name: RESULT"
# colon-delimited shape -- confirmed by reading test/comfychair.py's
# source directly rather than guessing from the reporting convention used
# elsewhere (e.g. .github/workflows/c-build.yml's own grep for
# "<CaseName> OK" / "<CaseName> NOTRUN" uses the same space-delimited
# shape, not a colon).
ok_count=$(grep -cE '^[A-Za-z0-9_]+[[:space:]]+OK[[:space:]]*$' "$check_log" || true)
notrun_count=$(grep -cE '^[A-Za-z0-9_]+[[:space:]]+NOTRUN,' "$check_log" || true)
failed_lines=$(grep -E '^[A-Za-z0-9_]+[[:space:]]+FAIL[[:space:]]*$' "$check_log" || true)
failed_count=0
if [ -n "$failed_lines" ]; then
    failed_count=$(printf '%s\n' "$failed_lines" | wc -l | tr -d ' ')
fi

log "make check summary: OK=$ok_count NOTRUN=$notrun_count FAILED=$failed_count"

# A summary reporting 0/0/0 would look clean but actually means the parser
# didn't match anything -- e.g. the log format changed, or make check never
# reached test/testdistcc.py at all. Reporting that as a pass would be
# exactly the "suppress a real failure signal to make a check look green"
# outcome AGENTS.md rule 66 forbids; treat it as a hard failure instead.
if [ "$((ok_count + notrun_count + failed_count))" -eq 0 ]; then
    fail "parsed zero comfychair result lines out of make check's output -- treating this as a hard failure rather than silently reporting an all-zero summary (see $check_log)"
fi

if [ "$failed_count" -gt 0 ]; then
    printf '[run-tests] FAILED test case(s):\n' >&2
    printf '%s\n' "$failed_lines" | sed -E 's/^([A-Za-z0-9_]+)[[:space:]]+FAIL[[:space:]]*$/  - \1/' >&2
fi

if [ "$check_status" -ne 0 ] || [ "$failed_count" -gt 0 ]; then
    fail "make check reported failure (exit $check_status, $failed_count FAILED case(s)) -- full log: $check_log"
fi

log "all steps passed: autogen, configure, make, make check (OK=$ok_count NOTRUN=$notrun_count FAILED=0)"
exit 0
