# `rpm.spec` commented-out directives are still expanded by rpmbuild

**Fork issue:** [wiki-mod/distcc-ng#479](https://github.com/wiki-mod/distcc-ng/issues/479)
**Fixed by:** [wiki-mod/distcc-ng#544](https://github.com/wiki-mod/distcc-ng/pull/544)
**Upstream location:** `packaging/RedHat/rpm.spec`, lines 6 and 109
**Checked against upstream commit:** [`8d569d19`](https://github.com/distcc/distcc/commit/8d569d192141615e26a3f0b65315822e7c814c3d) (`master`, checked 2026-10-01)
**Searched upstream issues/PRs for:** `Macro expanded in comment`, `rpm.spec comment`, `_docdir rpm` -- one match: distcc/distcc#418 ("make deb fails", closed 2021-05-11), whose log shows both warnings below; the maintainer's reply there says `make deb`/`make rpm` are not supported, and both lines are unchanged in the current source.

## The problem

rpmbuild expands macros inside comment lines. Two commented-out
directives in `rpm.spec` therefore still go through macro expansion on
every `make rpm`/`make deb` and print:

```
warning: Macro expanded in comment on line 6: %define _docdir %{_datadir}/doc/%{name}-%{version}
warning: Macro expanded in comment on line 109: %{_sysconfdir}/init.d
```

In this tree neither line changes the result: line 7 defines the
effective `_docdir` right after line 6, and line 109's directory is
deliberately left unowned. But the build is not clean, and the same
mechanism turns any `%`-carrying comment into live spec input; this
fork hit that case when a prose comment mentioning a setup macro ran a
second setup (fixed in wiki-mod/distcc-ng#544, commit `655908b`).

## Upstream code (unchanged as of the commit above, upstream)

```spec
#%define _docdir %{_datadir}/doc/%{name}-%{version}
%define _docdir %{_datadir}/doc/%{name}
```

```spec
# Don't list init.d dir because on Red Hat it's a symlink owned by
# chkconfig, so it causes a conflict on install.
#%dir %{_sysconfdir}/init.d
```

## Fixed code (changed code as of the commit from distcc-ng fork)

Commit `97710ef` writes every percent sign in both commented-out lines
as `%%`, so rpm reads them as plain text:

```spec
#%%define _docdir %%{_datadir}/doc/%%{name}-%%{version}
%define _docdir %{_datadir}/doc/%{name}
```

```spec
#%%dir %%{_sysconfdir}/init.d
```

## Empirical verification

This fork's CI package job runs `make deb` (rpmbuild, then alien) on
`ubuntu-latest`:

- Before (wiki-mod/distcc-ng Actions run 36925323463, job 110581191641,
  tree `184179d`): both `Macro expanded in comment` warnings above
  (fork lines 9 and 129), and both RPMs written.
- After (run 36930585481, job 110598666859, tree `97710ef`): zero
  `Macro expanded in comment` warnings, and both RPMs
  (`distcc-ng-3.6.6-1.NG.x86_64.rpm`, `distcc-ng-server-3.6.6-1.NG.x86_64.rpm`)
  written. The package contents were not compared file by file; the
  change only escapes text in comments, and line 7's (fork line 10's)
  live `_docdir` definition is untouched.
