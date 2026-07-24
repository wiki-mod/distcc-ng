# distcc -- a free distributed C/C++ compiler system

[![OpenSSF Baseline](https://www.bestpractices.dev/projects/13760/baseline)](https://www.bestpractices.dev/projects/13760)

by Martin Pool

Current Documents: <https://distcc.github.io/>

Formerly <http://distcc.org/>

"pump" functionality added by
Fergus Henderson, Nils Klarlund, Manos Renieris, and Craig Silverstein (Google Inc.)

distcc is a program to distribute compilation of C or C++ code across
several machines on a network. distcc should always generate the same
results as a local compile, is simple to install and use, and is often
two or more times faster than a local compile.

Unlike other distributed build systems, distcc does not require all
machines to share a filesystem, have synchronized clocks, or to have
the same libraries or header files installed. Machines can be running
different operating systems, as long as they have compatible binary
formats or cross-compilers.

By default, distcc sends the complete preprocessed source code across
the network for each job, so all it requires of the volunteer machines
is that they be running the distccd daemon, and that they have an
appropriate compiler installed.

The distcc "pump" functionality, added in distcc 3.0, improves on
distcc by distributing not only compilation but also preprocessing to
distcc servers. This requires that the server and client have the same
system headers (the client takes responsibility for transmitting
application-specific headers).  Given that, distcc in pump mode yields
the same results that distcc would in non-pump mode, but faster, since
the preprocessor no longer runs locally. For more details on the pump
functionality, see [Pump mode](#pump-mode) below.

distcc is not itself a compiler, but rather a front-end to the GNU
C/C++ compiler (gcc), or another compiler of your choice. All the
regular gcc options and features work as normal.

distcc is designed to be used with GNU make's parallel-build feature
(-j). Shipping files across the network takes time, but few cycles on
the client machine. Any files that can be built remotely are
essentially "for free" in terms of client CPU.  This is even more true
in "pump" mode, where the client does not even have to take time to
preprocess the source files.  distcc has been successfully used in
environments with hundreds of distcc servers, supporting dozens of
simultaneous compiles.

distcc is now reasonably stable and can successfully compile the Linux
kernel, rsync, KDE, GNOME (via GARNOME), Samba and Ethereal.  distcc
is nearly linearly scalable for small numbers of machines: for a
typical case, three machines are 2.6 times faster than one.

## Pump mode

distcc's "pump" mode improves on plain distcc by distributing not only
compilation but also preprocessing to distcc servers.

Pump mode uses an "include server" process that runs during the build.
The include server parses and analyzes source (including header) files.
It runs on the workstation that initiates the build. The include server
analyzes each header file only a few times during a build, sometimes
just once. In contrast, during ordinary distcc operation, the
preprocessor examines each header file multiple times, even hundreds of
times for a large build.

### Header analysis

In pump mode, a static analysis algorithm inspects each `#include`
directive and computes a superset of the possible values of its
argument. The resulting dependency graph among header files persists
during the lifetime of the include server, which then acts as a cache
for include analysis.

The include server compresses source files into a temporary directory
as they are encountered. In this way, a given source file is compressed
only once during the build.

### Absolute include paths

It may happen that a header file is included via an absolutely
specified include directory such as `-I/absolute/path`. But on the
compilation server the path `-I/absolute/path` does not exist; instead
the server places `foo.h` under `/server_temporary_path/absolute/path`
for some `/server_temporary_path` root directory. This directory has no
meaning on the workstation. Before compressing `foo.h`, the include
server therefore inserts a `#line` directive in `foo.h`, to inform the
preprocessor that the real location is `/absolute/path`.

### Build flow

The distcc client asks the include server for the list of compressed
files that constitute the transitive closure of the source file to be
compiled. It then spools these files to a distcc server. The distcc
server unpacks these files in the `/server_temporary_path` directory
before preprocessing and compiling. The server also rewrites include
options, such as `-I`'s, to reflect the new locations of the files on
the server. The `.d` and the `.o` files are both rewritten as necessary
to refer to client-side filenames and returned to the pump-mode client.

### Performance characteristics

Pump mode is able to distribute compilations up to 10X faster than
plain distcc. But because building also involves linking and perhaps
generation of source files, the overall speed-up of the build time is
variable.

Pump mode was developed to be used with large clusters of distcc
servers, providing hundreds of CPUs. With versions of gcc >= 4.1.1,
pump mode will probably not show major performance gains using clusters
of less than ten CPUs. The preprocessor running on the workstation is
fast enough to keep that many machines busy.

## Security

`distccd` doesn't authenticate *who* connects, only *from where*: without
an explicit `--allow`, it automatically restricts itself to private,
non-Internet-routable address ranges (`src/dopt.c`'s `--allow-private`
fallback) — it isn't wide open by default. That's still IP-range
filtering, not real identity verification (an optional GSSAPI `--auth`
mode exists, but is off unless explicitly enabled and requires a build
with GSSAPI support). The real risk is an administrator who widens
`--allow` to a public range, or passes `--enable-tcp-insecure`, without
understanding that anyone reachable at that point can ask the daemon to
run a compiler. Don't have a package or install script make either of
those choices automatically — leave it to the administrator.

## Licence

distcc is distributed under the GNU General Public Licence v2.

## Resources

* Repo, questions, and bugs: https://github.com/wiki-mod/distcc-ng

* [Stack Overflow questions](http://stackoverflow.com/questions/tagged/distcc)
