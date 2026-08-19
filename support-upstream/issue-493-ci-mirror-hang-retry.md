# `c-build.yml`'s `ConorMacBride/install-package` step has no retry, so a hung package-manager mirror burns the whole job timeout

**Fork issue:** [wiki-mod/distcc-ng#493](https://github.com/wiki-mod/distcc-ng/issues/493)
**Fixed by:** [wiki-mod/distcc-ng#PLACEHOLDER](https://github.com/wiki-mod/distcc-ng/pull/PLACEHOLDER)
**Upstream location:** `.github/workflows/c-build.yml`, `make_check` job's `ConorMacBride/install-package@v1` step
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-08-19)
**Searched upstream issues/PRs for:** `apt mirror`, `ci hang`, `install-package`, `ci timeout` -- found upstream issue/PR [#565](https://github.com/distcc/distcc/issues/565) ("ci: Set shorter timeout on GitHub Actions", merged 2025-11-03), which documents the same underlying failure class (a `make_check` run "somehow hung though, running for 6hr before timing out", referencing [action run 18975209355](https://github.com/distcc/distcc/actions/runs/18975209355), whose `make_check (macOS-latest)` job shows `conclusion: cancelled` while `make_check (ubuntu-latest)` succeeded -- consistent with a single-leg hang, though the run's own step-level logs are no longer available to confirm which exact step hung). Upstream's merged fix only lowers `timeout-minutes` from the default 360 to 15, bounding the loss; it adds no retry.

## The problem

`ConorMacBride/install-package`'s own `apt` path (`.github/action.yml` at
the pinned tag) runs `sudo apt update && sudo apt install -y $apt` as a
single, unretried shell command inside its own composite-action step; the
`brew` path (macOS) similarly runs a single unretried `brew update`. On a
GitHub-hosted runner, a slow or unresponsive default package-manager mirror
(e.g. `azure.archive.ubuntu.com` on `ubuntu-latest`) has no bounded retry to
fall back on -- the surrounding job's `timeout-minutes` is the only thing
that eventually kills it, so one bad mirror response consumes the entire
job budget for zero actual progress. This fork independently reproduced
this twice against the identical `ConorMacBride/install-package` apt path
(`nightly-publish.yml`'s `build_check` job, job IDs 95959419297 and
96199186670, `timeout-minutes: 20`, repeated `Ign:` lines against
`noble`/`noble-updates`/`noble-backports`/`noble-security` until the job
was killed). Upstream's own `c-build.yml` uses the exact same unpinned
`ConorMacBride/install-package@v1` apt/brew invocation as this fork's
pre-fix `install-build-deps` composite action, so the same class of hang is
reachable there too -- consistent with upstream issue/PR #565's own
"somehow hung ... running for 6hr before timing out" report on this same
workflow's `make_check` job, though that specific incident's cancelled
macOS leg couldn't be confirmed here to be the same apt-vs-brew code path
since GitHub no longer retains that run's step logs.

## Upstream code (unchanged as of the commit above, upstream)

```yaml
  make_check:
    strategy:
      matrix:
        os:
        - macOS-latest
        - ubuntu-latest
      fail-fast: false
    runs-on: ${{ matrix.os }}
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v4
      - uses: ConorMacBride/install-package@v1
        with:
          brew: autoconf automake popt python@3.13 python-setuptools
          apt: clang libavahi-client-dev libpopt-dev gdb python3-dev python3-setuptools
      - run: which python3.13 || which python3
      - run: ./autogen.sh
      - run: ./configure PYTHON="$(which python3.13 || which python3)"
      - run: make
      - run: make check
```

## Fixed code (changed code as of the commit from distcc-ng fork)

`.github/actions/install-build-deps/action.yml` (this fork's own shared
composite action, consumed by `c-build.yml`'s `make_check`,
`nightly-publish.yml`'s `build_check`, and `package-release.yml`'s
`build_check`) replaces the apt path with a plain-shell equivalent wrapped
in a bounded retry loop, while leaving the brew path (macOS matrix legs)
unchanged:

```yaml
    - if: runner.os == 'Linux'
      shell: bash
      run: |
        packages="clang libavahi-client-dev libpopt-dev gdb python3-dev python3-setuptools ccache libzstd-dev libelf-dev"
        max_attempts=3
        attempt=1
        while true; do
          if timeout 2m sudo bash -c "apt-get update && apt-get install -y $packages"; then
            exit 0
          fi
          if [ "$attempt" -ge "$max_attempts" ]; then
            echo "apt update/install did not succeed after $max_attempts attempts" >&2
            exit 1
          fi
          echo "apt update/install attempt $attempt failed or timed out, retrying" >&2
          attempt=$((attempt + 1))
          sleep 10
        done
    - if: runner.os == 'macOS'
      uses: ConorMacBride/install-package@3e7ad059e07782ee54fa35f827df52aae0626f30 # v1.1.0
      with:
        brew: ${{ inputs.brew }}
```

Each attempt is capped well under every consumer workflow's own job
timeout, so a stuck mirror now fails fast with a clear diagnostic and gets
retried, instead of silently consuming the whole job budget once. This
fork's fix does not touch the brew/macOS path, which was not part of
either live reproduction.

## Empirical verification

This fix could not be verified against a live mirror hang on demand (that
failure mode isn't reproducible at will) -- see this fork's PR body for the
full reasoning on why the retry design is still correct despite that. What
was verified: a real triggered CI run on the fix branch completing the apt
step normally on a healthy mirror (the happy path is unchanged), and a
read-through confirming `ConorMacBride/install-package`'s own `action.yml`
(pinned SHA `3e7ad059e07782ee54fa35f827df52aae0626f30`) runs `sudo apt
update` unretried, gated only on `runner.os == 'Linux'`, and `brew update`
unretried, gated only on `runner.os == 'macOS'` -- confirming both this
fork's pre-fix exposure and upstream's identical exposure are the same
underlying mechanism.

## Upstream status

Still present in upstream's live source (`distcc/distcc`, `.github/
workflows/c-build.yml`, commit `8d569d19`, checked 2026-08-19): the apt and
brew paths both still run through `ConorMacBride/install-package@v1` with
no retry of any kind. Upstream's own merged #565 addressed the symptom (a
6-hour job burn against the 360-minute GitHub Actions default) by lowering
`timeout-minutes` to 15, not the root cause -- a hang still fails the whole
job on the first bad mirror response, with no retry. Not reported upstream
(per this fork's read-only upstream policy) -- filed here as passive
reference only.
