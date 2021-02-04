#!/bin/sh
#
# mmdebstrap does have a --merged-usr option but only as a no-op for
# debootstrap compatibility
#
# Using this hook script, you can emulate what debootstrap does to set up
# merged /usr via directory symlinks, even using the exact same shell function
# that debootstrap uses.
#
# mmdebstrap will not include this functionality via a --merged-usr option
# because there are many reasons against implementing merged-/usr that way:
#
# https://wiki.debian.org/Teams/Dpkg/MergedUsr
# https://wiki.debian.org/Teams/Dpkg/FAQ#Q:_Does_dpkg_support_merged-.2Fusr-via-aliased-dirs.3F
# https://lists.debian.org/20190219044924.GB21901@gaara.hadrons.org
# https://lists.debian.org/YAkLOMIocggdprSQ@thunder.hadrons.org
# https://lists.debian.org/20181223030614.GA8788@gaara.hadrons.org
#
# In addition, the merged-/usr-via-aliased-dirs approach violates an important
# principle of component based software engineering one of the core design
# ideas/goals of mmdebstrap: All the information to create a chroot of a Debian
# based distribution should be included in its packages and their metadata.
# Using directory symlinks as used by debootstrap contradicts this principle.
# The information whether a distribution uses this approach to merged-/usr or
# not is not anymore contained in its packages but in a tool from the outside.
#
# The problem is not the idea of merged-/usr but the problem is the way how it
# got implemented in debootstrap via directory symlinks. That way of rolling
# out merged-/usr is bad from the dpkg point-of-view and completely opposite of
# the vision with which in mind I wrote mmdebstrap.

set -exu

TARGET="$1"

if [ -e "$TARGET/var/lib/dpkg/arch" ]; then
	ARCH=$(head -1 "$TARGET/var/lib/dpkg/arch")
else
	ARCH=$(dpkg --print-architecture)
fi

if [ -e /usr/share/debootstrap/functions ]; then
	. /usr/share/debootstrap/functions
	doing_variant () { [ $1 != "buildd" ]; }
	MERGED_USR="yes"
	# until https://salsa.debian.org/installer-team/debootstrap/-/merge_requests/48 gets merged
	link_dir=""
	setup_merged_usr
else
	link_dir=""
	case $ARCH in
	    hurd-*) exit 0;;
	    amd64) link_dir="lib32 lib64 libx32" ;;
	    i386) link_dir="lib64 libx32" ;;
	    mips|mipsel) link_dir="lib32 lib64" ;;
	    mips64*|mipsn32*) link_dir="lib32 lib64 libo32" ;;
	    powerpc) link_dir="lib64" ;;
	    ppc64) link_dir="lib32 lib64" ;;
	    ppc64el) link_dir="lib64" ;;
	    s390x) link_dir="lib32" ;;
	    sparc) link_dir="lib64" ;;
	    sparc64) link_dir="lib32 lib64" ;;
	    x32) link_dir="lib32 lib64 libx32" ;;
	esac
	link_dir="bin sbin lib $link_dir"

	for dir in $link_dir; do
		ln -s usr/"$dir" "$TARGET/$dir"
		mkdir -p "$TARGET/usr/$dir"
	done
fi
