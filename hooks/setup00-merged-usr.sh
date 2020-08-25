#!/bin/sh

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
	setup_merged_usr
else
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
