0.7.5 (2021-02-06)
------------------

 - skip emulation check for extract variant
 - add new suite name trixie
 - unset TMPDIR in hooks because there is no value that works inside as well as
   outside the chroot
 - expose hook name to hooks via MMDEBSTRAP_HOOK environment variable

0.7.4 (2021-01-16)
------------------

 - Optimize mmtarfilter to handle many path exclusions
 - Set MMDEBSTRAP_APT_CONFIG, MMDEBSTRAP_MODE and MMDEBSTRAP_HOOKSOCK for hook
   scripts
 - Do not run an additional env command inside the chroot
 - Allow unshare mode as root user
 - Additional checks whether root has the necessary privileges to mount
 - Make most features work on Debian 10 Buster

0.7.3 (2020-12-02)
------------------

 - bugfix release

0.7.2 (2020-11-28)
------------------

 - check whether tools like dpkg and apt are installed at startup
 - make it possible to seed /var/cache/apt/archives with deb packages
 - if a suite name was specified, use the matching apt index to figure out the
   package set to install
 - use Debian::DistroInfo or /usr/share/distro-info/debian.csv (if available)
   to figure out the security mirror for bullseye and beyond
 - use argparse in tarfilter and taridshift for proper --help output

0.7.1 (2020-09-18)
------------------

 - bugfix release

0.7.0 (2020-08-27)
-----------------

 - the hook system (setup, extract, essential, customize and hook-dir) is made
   public and is now a documented interface
 - tarball is also created if the output is a named pipe or character special
 - add --format option to control the output format independent of the output
   filename or in cases where output is directed to stdout
 - generate ext2 filesystems if output file ends with .ext2 or --format=ext2
 - add --skip option to prevent some automatic actions from being carried out
 - implement dpkg-realpath in perl so that we don't need to run tar inside the
   chroot anymore for modes other than fakechroot and proot
 - add ready-to-use hook scripts for eatmydata, merged-usr and busybox
 - add tarfilter tool
 - use distro-info-data and debootstrap to help with suite name and keyring
   discovery
 - no longer needs to install twice when --depkgopt=path-exclude is given
 - variant=custom and hooks can be used as a debootstrap wrapper
 - use File::Find instead of "du" to avoid different results on different
   filesystems
 - many, many bugfixes and documentation enhancements

0.6.1 (2020-03-08)
------------------

 - replace /etc/machine-id with an empty file
 - fix deterministic tar with pax and xattr support
 - support deb822-style format apt sources
 - mount /sys and /proc as read-only in root mode
 - unset TMPDIR environment variable for everything running inside the chroot

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
