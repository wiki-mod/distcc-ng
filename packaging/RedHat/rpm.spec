# What: Prose comments here never contain a percent sign.
# Why: rpm expands comment macros; one ran a second setup.
# From: PR #544
%define	RELEASE	1
%define rel     %{?CUSTOM_RELEASE} %{!?CUSTOM_RELEASE:%RELEASE}
%define	_prefix	/usr
%define _bindir %{_prefix}/bin
%define _datadir %{_prefix}/share
#%%define _docdir %%{_datadir}/doc/%%{name}-%%{version}
%define _docdir %{_datadir}/doc/%{name}
%define _libdir %{_prefix}/lib
%define _mandir %{_datadir}/man
%define _sysconfdir /etc

Name: %NAME
Summary: Client side program for distributed C/C++ compilations.
# What: Version is RPM-safe; FULLVERSION keeps the -NG tag.
# Why: rpm-version(7) forbids '-'; rpm.sh splits the suffix.
# From: PR #46
Version: %VERSION
Release: %{rel}%{?VERSUFFIX:.%{VERSUFFIX}}
Group: Development/Languages
Url: https://github.com/wiki-mod/distcc-ng
License: GPL
Source: https://github.com/wiki-mod/distcc-ng/archive/refs/tags/v%{FULLVERSION}.tar.gz#/%{NAME}-%{FULLVERSION}.tar.gz
Distribution: Redhat 7 and above.
BuildRoot: %{_tmppath}/%{name}-buildroot
Prefix: %_prefix
Provides: distcc
# What: Conflict with and obsolete the real distcc package.
# Why: Same install paths at any version; no version boundary.
# From: Issue #412, PR #437
Conflicts: distcc
Obsoletes: distcc
Obsoletes: crosstool-distcc distcc-include-server

%description
distcc is a program to distribute compilation of C or C++ code across several
machines on a network. distcc should always generate the same results as a
local compile, is simple to install and use, and is often two or more times
faster than a local compile.

%prep
# What: Unpack into the tarball's real top-level directory.
# Why: The dist tarball dir uses FULLVERSION, not Version.
# From: PR #47, PR #544
%setup -n %{NAME}-%{FULLVERSION}

%build
# What: Configure without sendfile.
# Why: sendfile is broken for 32-bit apps on some x86_64.
ac_cv_func_sendfile=no ac_cv_header_sys_sendfile_h=no ./configure \
  --prefix=%{_prefix} \
  --bindir=%{_bindir} \
  --sysconfdir=%{_sysconfdir} \
  --datadir=%{_datadir} \
  --docdir=%{_docdir} \
  --mandir=%{_mandir} \
  --enable-rfc2553
# What: Have setup.py record its installed files in a list.
# Why: The files section is built from python_install_record.
make RPM_OPT_FLAGS="$RPM_OPT_FLAGS" \
     PYTHON_INSTALL_RECORD=python_install_record

%install
rm -rf $RPM_BUILD_ROOT
make DESTDIR=${RPM_BUILD_ROOT} PYTHON_INSTALL_RECORD=python_install_record install
# What: Install the remaining system-specific config files.
# Why: Their names and locations are too distro-specific.
mkdir -p $RPM_BUILD_ROOT%{_sysconfdir}/logrotate.d
install -m 644 packaging/RedHat/logrotate.d/distcc $RPM_BUILD_ROOT%{_sysconfdir}/logrotate.d/distcc
mkdir -p $RPM_BUILD_ROOT%{_sysconfdir}/xinetd.d
install -m 644 packaging/RedHat/xinetd.d/distcc $RPM_BUILD_ROOT%{_sysconfdir}/xinetd.d/distcc
mkdir -p $RPM_BUILD_ROOT%{_sysconfdir}/init.d
install -m 755 packaging/RedHat/init.d/distcc $RPM_BUILD_ROOT%{_sysconfdir}/init.d/distcc
# What: Relative masquerade symlinks cc, c++, gcc, g++.
# Why: make install skips them; rpm warns on absolute links.
mkdir -p $RPM_BUILD_ROOT/%{_libdir}/distcc
ln -sr $RPM_BUILD_ROOT%{_bindir}/distcc $RPM_BUILD_ROOT/%{_libdir}/distcc/cc
ln -sr $RPM_BUILD_ROOT%{_bindir}/distcc $RPM_BUILD_ROOT/%{_libdir}/distcc/c++
ln -sr $RPM_BUILD_ROOT%{_bindir}/distcc $RPM_BUILD_ROOT/%{_libdir}/distcc/gcc
ln -sr $RPM_BUILD_ROOT%{_bindir}/distcc $RPM_BUILD_ROOT/%{_libdir}/distcc/g++

%clean
rm -rf $RPM_BUILD_ROOT

%files -f python_install_record
%defattr(-, root, root, 0755)
%{_bindir}/distcc
%{_bindir}/distccmon-text
%{_bindir}/lsdistcc
%{_libdir}/distcc
%{_bindir}/pump
%{_sbindir}/update-distcc-symlinks
%dir %{_sysconfdir}/distcc
%config %{_sysconfdir}/distcc/hosts
%doc %{_mandir}/man1/distcc.1.gz
%doc %{_mandir}/man1/distccmon-text.1.gz
%doc %{_mandir}/man1/pump.1.gz
%doc %{_mandir}/man1/include_server.1.gz
%doc %{_mandir}/man1/lsdistcc.1.gz
%doc %{_docdir}


%package server
Summary: Server side program for distributed C/C++ compilations.
Group: Development/Languages
Provides: distccd
# What: Conflict with and obsolete real distcc-server.
# Why: It installs the same distccd paths at any version.
# From: Issue #412, PR #437
Conflicts: distcc-server
Obsoletes: distcc-server
Obsoletes: crosstool-distcc-server

%description server
distcc is a program to distribute compilation of C or C++ code across several
machines on a network. distcc should always generate the same results as a
local compile, is simple to install and use, and is often two or more times
faster than a local compile.

%files server
%defattr(-, root, root, 0755)
%{_bindir}/distccd
%dir %{_sysconfdir}/logrotate.d
%config %{_sysconfdir}/logrotate.d/distcc
# What: The init.d directory itself is not owned here.
# Why: On Red Hat it is a chkconfig-owned symlink.
#%%dir %%{_sysconfdir}/init.d
%config %{_sysconfdir}/init.d/distcc
%dir %{_sysconfdir}/xinetd.d/
%config %{_sysconfdir}/xinetd.d/distcc
%dir %{_sysconfdir}/distcc
%config %{_sysconfdir}/distcc/clients.allow
%config %{_sysconfdir}/distcc/commands.allow.sh
%dir %{_sysconfdir}/default
%config %{_sysconfdir}/default/distcc
%doc %{_mandir}/man1/distccd.1.gz

%pre server

%post server
DISTCC_USER=distcc
if [ -s /etc/redhat-release ]; then
  # What: Pick the user shell by how init functions run su.
  # Why: su - ignores nologin; see Red Hat bug 26894.
  /sbin/service distcc stop &>/dev/null || :
  if fgrep 'nice initlog $INITLOG_ARGS -c "su - $user' /etc/init.d/functions | fgrep -v '.-s ' > /dev/null 2>&1 ; then
    # What: Old su: no nologin shell; home is /nonexistent.
    # Why: A service user needs no home, like Debian's distcc.
    # From: PR #284
    /usr/sbin/useradd -d /nonexistent -r $DISTCC_USER &>/dev/null || :
  else
    # What: Everyone else also gets the nologin shell.
    # Why: A service account must never be a login account.
    /usr/sbin/useradd -d /nonexistent -r -s /sbin/nologin $DISTCC_USER &>/dev/null || :
  fi
else
  echo Creating $DISTCC_USER user...
  if ! id $DISTCC_USER > /dev/null 2>&1 ; then
    if ! id -g $DISTCC_USER > /dev/null 2>&1 ; then
      addgroup --system --gid 11 $DISTCC_USER
    fi
    # What: Debian path: system user with home /nonexistent.
    # Why: Matches Debian's own distcc package, not upstream /.
    # From: PR #284
    adduser --quiet --system --gid 11 \
      --home /nonexistent --no-create-home --uid 15 $DISTCC_USER
  fi
fi

DISTCC_LOGFILE=/var/log/distccd.log
if [ ! -s $DISTCC_LOGFILE ]; then
  touch $DISTCC_LOGFILE
  chown ${DISTCC_USER}:adm $DISTCC_LOGFILE
  chmod 640 $DISTCC_LOGFILE
fi

if ! grep -q "3632/tcp" /etc/services; then
  echo -e "distcc\t\t3632/tcp\t\t\t# Distcc Distributed Compiler" >> /etc/services
fi

if ! grep -q "^distcc:" /etc/hosts.allow; then
  echo -e "distcc:\t127.0.0.1" >> /etc/hosts.allow
fi

if [ -s /etc/redhat-release ]; then
  /sbin/chkconfig --add distcc
  /etc/init.d/distcc start || exit 0
else
  if [ -x "/etc/init.d/distcc" ]; then
    update-rc.d -f distcc remove >/dev/null
    update-rc.d distcc defaults 95 05 >/dev/null
    if [ -x /usr/sbin/invoke-rc.d ]; then
      start_command="invoke-rc.d distcc start"
    else
      start_command="/etc/init.d/distcc start"
    fi
    $start_command || {
        echo "To enable distcc's TCP mode, you should edit these files"
        echo "        %{_sysconfdir}/distcc/clients.allow"
        echo "        %{_sysconfdir}/distcc/commands.allow.sh"
        echo "and then run (as root)"
        echo "        $start_command"
        echo "For more info, including alternatives to TCP mode, see"
        echo "%{_docdir}/INSTALL and %{_docdir}/examples/README."
    }
  fi
fi

%preun server
if grep -q "^distcc:" /etc/hosts.allow; then
  sed -e "/^distcc/d" /etc/hosts.allow > /etc/hosts.allow.new
  mv /etc/hosts.allow.new /etc/hosts.allow
fi

if [ -s /etc/redhat-release ]; then
  if [ $1 -eq 0 ]; then
    /sbin/service distcc stop &>/dev/null || :
  fi
  # What: Unregister from chkconfig before the script goes.
  # Why: chkconfig --del needs the init script to exist.
  /sbin/chkconfig --del distcc
else
  if [ -x "/etc/init.d/distcc" ]; then
    if [ -x /usr/sbin/invoke-rc.d ] ; then
      invoke-rc.d distcc stop || exit 0
    else
      /etc/init.d/distcc stop || exit 0
    fi
  fi
fi

%postun server
# What: Never remove the distcc user or group on purge.
# Why: Debian's own distcc keeps them; be no stricter.
# From: PR #284
if [ -s /etc/debian_version ]; then
  case "$1" in
    purge)
      ;;
    remove)
      ;;
    upgrade|failed-upgrade|abort-install|abort-upgrade|disappear)
      ;;
    *)
      echo "postrm called with unknown argument \`$1'" >&2
      exit 1
    ;;
  esac

  if [ "$1" = "purge" ] ; then
    # What: Drop the runlevel links once the script is gone.
    # Why: update-rc.d remove refuses while the script exists.
    update-rc.d distcc remove >/dev/null || exit 0
  fi
fi


%changelog
* Sat Mar 12 2008 Craig Silverstein <opensource@google.com> 3.0-1
- Updated to 3.0
- Added include-server files
- useradd is run in post- rather than pre-install
- distcc server is automatically started
- Remove source package generation
- Man pages are now unzipped
- Deb packages now also built, using alien

* Sat May 31 2003 Terry Griffin <terryg@axian.com> 2.5-2
- Updated to 2.5

* Sat May 24 2003 Terry Griffin <terryg@axian.com> 2.4.2-2
- Updated to 2.4.2

* Sat May 17 2003 Terry Griffin <terryg@axian.com> 2.3-2
- Updated to 2.3

* Sun May 04 2003 Terry Griffin <terryg@axian.com> 2.1-2
- Updated to 2.1
- Added symbolic links for masquerade mode

* Fri Mar 28 2003 Terry Griffin <terryg@axian.com> 2.0.1-2
- Updated to 2.0.1
- Removed info file from document list.

* Tue Feb 25 2003 Terry Griffin <terryg@axian.com> 1.2.1-2
- Updated to 1.2.1

* Mon Jan 27 2003 Terry Griffin <terryg@axian.com> 1.1-2
- Updated to 1.1
- Minor improvements to the RPM spec file

* Mon Dec 16 2002 Terry Griffin <terryg@axian.com> 0.15-2
- Changed server user back to 'nobody'

* Fri Dec 13 2002 Terry Griffin <terryg@axian.com> 0.15-2
- Updated to 0.15
- Changed port number in server configs to 3632

* Sat Nov 23 2002 Terry Griffin <terryg@axian.com> 0.14-2
- Updated to 0.14
- Major rework of the RPM spec file
- Added Red Hat server config files for both xinetd and SysV init.
- Change server user to daemon.

* Sat Nov 09 2002 Terry Griffin <terryg@axian.com> 0.12-1
- Updated to 0.12

* Thu Oct 10 2002 Terry Griffin <terryg@axian.com> 0.11-3
- First binary packages for Red Hat 8.x
- Fixed xinetd config file for location of distccd.

* Mon Sep 30 2002 Terry Griffin <terryg@axian.com> 0.11-2
- Moved distccd back to /usr/bin from /usr/sbin.

* Sat Sep 28 2002 Terry Griffin <terryg@axian.com> 0.11-1
- Initial build (Red Hat 7.x)
- Client and server in separate binary packages
- Added xinetd config file
- Moved distccd to /usr/sbin
- Added version number suffix to the documentation directory
