# Bundled popt fallback removed for staleness — a current-vendor alternative exists

**Fork issue:** [wiki-mod/distcc-ng#63](https://github.com/wiki-mod/distcc-ng/issues/63)
**Fixed by:** [wiki-mod/distcc-ng#170](https://github.com/wiki-mod/distcc-ng/pull/170)
**Upstream location:** `configure.ac`, `Makefile.in`, `popt/` (removed)
**Checked against upstream commit:** [`3873de0`](https://github.com/distcc/distcc/commit/3873de06d935e89b759b3a1e9de64daa92aed356) ("rm popt tree and references to it from configure", `master`, checked 2026-07-17)
**Searched upstream issues/PRs for:** `popt`, `libpopt`, `bundled popt`, `popt fallback`, `configure popt` — no reopening attempt or fallback proposal found, open or closed.

## Note on scope: this entry is different from the others in this folder

Every other entry here documents a bug this fork found and fixed that is
**still live** in upstream's current source. This one is not that — upstream
deliberately *removed* the bundled `popt/` tree, a conscious maintenance
decision, not an oversight. This entry instead documents that **the reason
for that removal doesn't have to be permanent**, since this fork found a
low-maintenance way to keep the fallback without the original downside.
Included per this folder's broader purpose (leave upstream a citable,
evidence-backed record to evaluate on their own initiative), not because
it's a "bug."

## What upstream did, and why (inferred from the commit itself)

Upstream's `configure.ac` previously had a hard requirement:

```
PKG_CHECK_MODULES(POPT, [popt >= 1.7])
```

with a bundled `popt/` directory as a fallback for platforms lacking a
system-packaged `popt`. Commit `3873de0` removed the entire `popt/` tree
and every reference to it from `configure.ac`/`Makefile.in`, leaving the
hard system-`popt` requirement with no fallback at all. The commit message
gives no elaborate rationale, but the bundled tree it removed was, by its
own `README.popt`, "a perfectly ordinary copy of libpopt 1.7" — a frozen
snapshot from roughly 1998–2001. Carrying a 20+-year-old, unmaintained
vendor copy indefinitely is a real, legitimate maintenance cost, and a
reasonable reason to drop it rather than keep updating a stale fork of a
third-party library by hand.

The practical effect of the removal: `configure` now fails outright on any
system without a packaged `popt` (minimal containers, embedded/
cross-compilation environments, older or unusual distros) — there is no
degraded-but-working path.

## This fork's alternative: vendor the real, current upstream project

Rather than reviving the same frozen 1998–2001 snapshot upstream removed
(which would just reintroduce the exact staleness problem that motivated
the removal), this fork vendors from `popt`'s own actual, currently
maintained project —
[`rpm-software-management/popt`](https://github.com/rpm-software-management/popt)
— pinned to its `popt-1.19-release` tag (2022-06-07), the same license
family (MIT) as before:

```
# configure.ac (this fork)
PKG_CHECK_MODULES([POPT], [popt >= 1.7], [have_system_popt=yes], [have_system_popt=no])

AC_ARG_WITH([system-popt],
  [AS_HELP_STRING([--with-system-popt], [require system libpopt, error if missing])],
  [...])
AC_ARG_WITH([system-popt], ... [--without-system-popt] ...)

AM_CONDITIONAL([BUILD_POPT], [test "x$have_system_popt" = xno -o "x$with_system_popt" = xno])
```

```
# Makefile.in (this fork) — only linked in when the fallback is chosen
if BUILD_POPT
POPT_OBJS = popt/popt.o popt/poptparse.o popt/popthelp.o popt/poptconfig.o
endif
```

A dedicated CI job (`popt_vendor_check`) compiles the vendored `popt/*.c`
directly under this project's own `-Wall -Wextra -Werror` and checks a
version marker, specifically to catch a future accidental regression back
to a stale vendor copy — the exact failure mode that made the original
1998–2001 snapshot a maintenance burden in the first place.

## Empirical verification

Real CI proof, not just a diff read: a GitHub Actions job deliberately
without a system-packaged `libpopt` installed builds this fork's `distccd`
against the vendored popt 1.19, then runs the resulting binary for real:

```
$ ./distccd --help
distccd 3.5.2-NG x86_64-pc-linux-gnu
...
    --jobs, -j LIMIT           maximum tasks at any time
    -p, --port PORT            TCP port to listen on
    --listen ADDRESS           IP address to listen on
    -N, --nice LEVEL           lower priority, 20=most nice
```

The job asserts (via pattern match on the real output, not just exit code)
that all of `--jobs`, `--nice`, `--listen`, `--daemon`, `--log-file`,
`--allow`, `--user`, and `--port` are present and correctly parsed — a real,
functioning `distccd` built entirely without any system `popt` package.

## Why this might be relevant to upstream

If upstream ever wants a fallback for `popt`-less platforms again without
reintroducing the original staleness problem, tracking a real upstream
project's tagged releases (rather than a one-time frozen copy) is a viable
low-maintenance path — this fork's `configure.ac`/CI-job approach above is
a working, empirically-verified example of it.
