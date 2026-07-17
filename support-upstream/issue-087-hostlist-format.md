# pump mode's manual `DISTCC_HOSTS` path requires a different host-list format than plain distcc

**Fork issue:** [wiki-mod/distcc-ng#87](https://github.com/wiki-mod/distcc-ng/issues/87)
**Fixed by:** [wiki-mod/distcc-ng#99](https://github.com/wiki-mod/distcc-ng/pull/99)
**Upstream location:** `pump.in`, function `StartIncludeServerAndDetermineHosts()`
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-07-17)
**Searched upstream issues/PRs for:** `DISTCC_HOSTS cpp`, `pump host list`, `hosts list does not contain any hosts with cpp` — no matching report or fix attempt found, open or closed.

## The problem

Plain `distcc` accepts a bare host-list entry (e.g. `distccd-server:3632`,
with no options) and gracefully falls back to client-side preprocessing if
no include server is running for that host. Pump mode, however, requires
server-side preprocessing, so it needs the `,cpp` option present on host
entries. When a user runs `pump.in`'s manual-`DISTCC_HOSTS` code path (as
opposed to its own separate auto-discovery path, which already
auto-appends `,cpp,lzo`), a host-list entry lacking `,cpp` on *any* host
hard-fails the whole build with an error, rather than falling back or
auto-appending the option the way the auto-discovery path already does.
This forces users maintaining a single shared host-list configuration to
keep two different, incompatible formats — one for plain `distcc`, one for
`pump` — for the exact same set of hosts.

## Upstream code (unchanged as of the commit above, upstream)

`pump.in`, `StartIncludeServerAndDetermineHosts()`:

```sh
hosts=`$distcc_location/distcc --show-hosts`
num_hosts=`echo "$hosts" | wc -l`
num_pump_hosts=`echo "$hosts" | grep ',cpp' | wc -l`
if [ $num_hosts -eq 0 ]; then
  echo "$program_name: error: distcc hosts list is empty!" 1>&2
  exit 1
elif [ $num_pump_hosts -eq 0 ]; then
  echo "$program_name: error: pump mode requested, but distcc" \
    "hosts list does not contain any hosts with ',cpp' option" 1>&2
  exit 1
else
  ...
```

Any manual `DISTCC_HOSTS` entry without `,cpp` still triggers the hard
`exit 1` above — no auto-append, no fallback.

## Fixed code (this fork, PR #99)

```sh
hosts=`$distcc_location/distcc --show-hosts`
num_hosts=`echo "$hosts" | wc -l`
if [ $num_hosts -eq 0 ]; then
  echo "$program_name: error: distcc hosts list is empty!" 1>&2
  exit 1
else
  # Auto-append ,cpp,lzo to hosts that don't already specify ,cpp.
  # This mirrors the behavior of ExportDISTCC_HOSTS() for the auto-discovery
  # path. Hosts that already have ,cpp are left unchanged (may have their own
  # compression option). This ensures a single host-list format works for both
  # pump and plain distcc (which gracefully falls back to client-side cpp if
  # the include-server isn't running).
  hosts_with_cpp=`echo "$hosts" | sed '/,cpp/! s/$/,cpp,lzo/'`

  export DISTCC_HOSTS="--randomize `echo "$hosts_with_cpp" | tr '\n' ' ' | sed 's/ $//'`"

  num_pump_hosts=`echo "$hosts_with_cpp" | grep ',cpp' | wc -l`
  if [ "$verbose" = 1 ]; then
    ...
```

The manual `DISTCC_HOSTS` path now auto-appends `,cpp,lzo` to any host entry
lacking `,cpp`, exactly like the auto-discovery path already did, so a
single host-list format (e.g. `distccd-server:3632`) now works correctly
under both plain `distcc` and `pump` without a hard failure.

Landed via [wiki-mod/distcc-ng#99](https://github.com/wiki-mod/distcc-ng/pull/99).
