# `rpm.spec` makes rpmbuild warn: comment macros, an unknown configure option, absolute symlinks

**Fork issue:** [wiki-mod/distcc-ng#479](https://github.com/wiki-mod/distcc-ng/issues/479)
**Fixed by:** [wiki-mod/distcc-ng#544](https://github.com/wiki-mod/distcc-ng/pull/544)
**Upstream location:** `packaging/RedHat/rpm.spec`, lines 6 and 109 (comment macros), line 43 (`--with-docdir`), lines 65-68 (masquerade symlinks)
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-10-01)
**Searched upstream issues/PRs for:** `Macro expanded in comment`, `rpm.spec comment`, `_docdir rpm` -- one match: distcc/distcc#418 ("make deb fails", closed 2021-05-11), whose log shows both comment-macro warnings below; the maintainer's reply there says `make deb`/`make rpm` are not supported, and all lines below are unchanged in the current source.

## The problem

Every `make rpm`/`make deb` of upstream's spec makes rpmbuild or the
configure step it runs warn about three separate defects:

1. **Comment macros.** rpmbuild expands macros inside comment lines, so
   two commented-out directives still go through macro expansion:

   ```
   warning: Macro expanded in comment on line 6: %define _docdir %{_datadir}/doc/%{name}-%{version}
   warning: Macro expanded in comment on line 109: %{_sysconfdir}/init.d
   ```

   In this tree neither changes the result (line 7 defines the effective
   `_docdir`; line 109's directory is deliberately unowned), but the same
   mechanism turns any `%`-carrying comment into live spec input. This
   fork hit that case when a prose comment naming a setup macro ran a
   second setup (fixed in wiki-mod/distcc-ng#544, commit `655908b`).
2. **Unknown configure option.** `%build` passes `--with-docdir=%{_docdir}`,
   which `configure` does not define:

   ```
   configure: WARNING: unrecognized options: --with-docdir
   ```

   The documentation directory therefore comes from configure's default,
   not from the spec. autoconf's own option is `--docdir`.
3. **Absolute symlinks.** The `cc`/`c++`/`gcc`/`g++` masquerade links point
   at an absolute path, which rpmbuild reports four times:

   ```
   warning: absolute symlink: /usr/lib/distcc/cc -> /usr/bin/distcc
   ```

## Upstream code (unchanged as of the commit above, upstream)

```spec
#%define _docdir %{_datadir}/doc/%{name}-%{version}
%define _docdir %{_datadir}/doc/%{name}
```

```spec
  --with-docdir=%{_docdir} \
```

```spec
ln -s %{_bindir}/distcc $RPM_BUILD_ROOT/%{_libdir}/distcc/cc
ln -s %{_bindir}/distcc $RPM_BUILD_ROOT/%{_libdir}/distcc/c++
ln -s %{_bindir}/distcc $RPM_BUILD_ROOT/%{_libdir}/distcc/gcc
ln -s %{_bindir}/distcc $RPM_BUILD_ROOT/%{_libdir}/distcc/g++
```

```spec
#%dir %{_sysconfdir}/init.d
```

## Fixed code (changed code as of the commit from distcc-ng fork)

Commit `97710ef` writes every percent sign in both commented-out lines as
`%%`; commit `00335ea` passes `--docdir` and makes the links relative with
`ln -sr`, which writes `../../bin/distcc`:

```spec
#%%define _docdir %%{_datadir}/doc/%%{name}-%%{version}
%define _docdir %{_datadir}/doc/%{name}
```

```spec
  --docdir=%{_docdir} \
```

```spec
ln -sr $RPM_BUILD_ROOT%{_bindir}/distcc $RPM_BUILD_ROOT/%{_libdir}/distcc/cc
ln -sr $RPM_BUILD_ROOT%{_bindir}/distcc $RPM_BUILD_ROOT/%{_libdir}/distcc/c++
ln -sr $RPM_BUILD_ROOT%{_bindir}/distcc $RPM_BUILD_ROOT/%{_libdir}/distcc/gcc
ln -sr $RPM_BUILD_ROOT%{_bindir}/distcc $RPM_BUILD_ROOT/%{_libdir}/distcc/g++
```

```spec
#%%dir %%{_sysconfdir}/init.d
```

## Empirical verification

This fork's CI package job runs `make deb` (rpmbuild, then alien) on
`ubuntu-latest`:

- Before (wiki-mod/distcc-ng Actions run 36925323463, tree `184179d`):
  both `Macro expanded in comment` warnings (fork lines 9 and 129), the
  `--with-docdir` configure warning and the four `absolute symlink`
  warnings; both RPMs written.
- After the comment fix (run 36930585481, tree `97710ef`): zero
  `Macro expanded in comment` warnings.
- After the option and symlink fix (run 36934874992, tree `00335ea`): no
  `unrecognized options` and no `absolute symlink` warning; configure
  still reports `documents /usr/share/doc/distcc-ng` inside the build
  root, the same path as before; both RPMs and both DEBs written.
  `ln -sr` writing `../../bin/distcc` for this layout was checked
  separately in a container.

The package contents were not compared file by file.
