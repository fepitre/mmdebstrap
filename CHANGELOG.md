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
