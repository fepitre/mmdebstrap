0.6.0 (2020-01-16)
------------------

 - allow multiple --architecture options
 - allow multiple --include options
 - enable parallel compression with xz by default
 - add --man option
 - add --keyring option overwriting apt's default keyring
 - preserve extended attributes in tarball
 - allow running tests on non-amd64 systems
 - generate squashfs images if output file ends in .sqfs or .squashfs
 - add --dry-run/--simulate options
 - add taridshift tool

0.5.1 (2019-10-19)
------------------

 - minor bugfixes and documentation clarification
 - the --components option now takes component names as a comma or whitespace
   separated list or as multiple --components options
 - make_mirror.sh now has to be invoked manually before calling coverage.sh

0.5.0 (2019-10-05)
------------------

 - do not unconditionally read sources.list stdin anymore
     * if mmdebstrap is used via ssh without a pseudo-terminal, it will stall
       forever
     * as this is unexpected, one now has to explicitly request reading
       sources.list from stdin in situations where it's ambiguous whether
       that is requested
     * thus, the following modes of operation don't work anymore:
         $ mmdebstrap unstable /output/dir < sources.list
         $ mmdebstrap unstable /output/dir http://mirror < sources.list
     * instead, one now has to write:
         $ mmdebstrap unstable /output/dir - < sources.list
         $ mmdebstrap unstable /output/dir http://mirror - < sources.list
 - fix binfmt_misc support on docker
 - do not use qemu for architectures unequal the native architecture that can
   be used without it
 - do not copy /etc/resolv.conf or /etc/hostname if the host system doesn't
   have them
 - add --force-check-gpg dummy option
 - allow hooks to remove start-stop-daemon
 - add /var/lib/dpkg/arch in chrootless mode when chroot architecture differs
 - create /var/lib/dpkg/cmethopt for dselect
 - do not skip package installation in 'custom' variant
 - fix EDSP output for external solvers so that apt doesn't mark itself as
   Essential:yes
 - also re-exec under fakechroot if fakechroot is picked in 'auto' mode
 - chdir() before 'apt-get update' to accomodate for apt << 1.5
 - add Dir::State::Status to apt config for apt << 1.3
 - chmod 0755 on qemu-user-static binary
 - select the right mirror for ubuntu, kali and tanglu

0.4.1 (2019-03-01)
------------------

 - re-enable fakechroot mode testing
 - disable apt sandboxing if necessary
 - keep apt and dpkg lock files

0.4.0 (2019-02-23)
------------------

 - disable merged-usr
 - add --verbose option that prints apt and dpkg output instead of progress
   bars
 - add --quiet/--silent options which print nothing on stderr
 - add --debug option for even more output than with --verbose
 - add some no-op options to make mmdebstrap a drop-in replacement for certain
   debootstrap wrappers like sbuild-createchroot
 - add --logfile option which outputs to a file what would otherwise be written
   to stderr
 - add --version option

0.3.0 (2018-11-21)
------------------

 - add chrootless mode
 - add extract and custom variants
 - make testsuite unprivileged through qemu and guestfish
 - allow empty lost+found directory in target
 - add 54 testcases and fix lots of bugs as a result

0.2.0 (2018-10-03)
------------------

 - if no MIRROR was specified but there was data on standard input, then use
   that data as the sources.list instead of falling back to the default mirror
 - lots of bug fixes

0.1.0 (2018-09-24)
------------------

 - initial release
