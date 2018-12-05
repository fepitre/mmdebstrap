#!/bin/sh

set -eu

mirrordir="./shared/debian"

./make_mirror.sh

# we use -f because the file might not exist
rm -f shared/cover_db.img

: "${HAVE_QEMU:=yes}"

if [ "$HAVE_QEMU" = "yes" ]; then
	# prepare image for cover_db
	guestfish -N shared/cover_db.img=disk:100M -- mkfs vfat /dev/sda
fi

# only copy if necessary
if [ ! -e shared/mmdebstrap ] || [ mmdebstrap -nt shared/mmdebstrap ]; then
	cp -a mmdebstrap shared
fi

starttime=
total=54
i=1

print_header() {
	echo ------------------------------------------------------------------------------
	echo "($i/$total) $1"
	if [ -z "$starttime" ]; then
		starttime=$(date +%s)
	else
		currenttime=$(date +%s)
		timeleft=$(((total-i+1)*(currenttime-starttime)/(i-1)))
		printf "time left: %02d:%02d:%02d\n" $((timeleft/3600)) $(((timeleft%3600)/60)) $((timeleft%60))
	fi
	echo ------------------------------------------------------------------------------
	i=$((i+1))
}

nativearch=$(dpkg --print-architecture)

# choose the timestamp of the unstable Release file, so that we get
# reproducible results for the same mirror timestamp
SOURCE_DATE_EPOCH=$(date --date="$(grep-dctrl -s Date -n '' "$mirrordir/dists/unstable/Release")" +%s)

# for traditional sort order that uses native byte values
export LC_ALL=C

: "${HAVE_UNSHARE:=yes}"
: "${HAVE_PROOT:=yes}"
: "${HAVE_BINFMT:=yes}"

defaultmode="auto"
if [ "$HAVE_UNSHARE" != "yes" ]; then
	defaultmode="root"
fi

# by default, use the mmdebstrap executable in the current directory together
# with perl Devel::Cover but allow to overwrite this
: "${CMD:=perl -MDevel::Cover=-silent,-nogcov ./mmdebstrap}"
mirror="http://127.0.0.1/debian"

for dist in stable testing unstable; do
	for variant in minbase buildd -; do
		# skip because of different userids for apt/systemd
		if [ "$dist" = 'stable' ] && [ "$variant" = '-' ]; then
			continue
		fi
		print_header "mode=root,variant=$variant: check against debootstrap $dist"

		if [ ! -e "shared/cache/debian-$dist-$variant.tar" ]; then
			echo "shared/cache/debian-$dist-$variant.tar does not exist. Skipping..."
			continue
		fi

		cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
export SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
$CMD --variant=$variant --mode=root $dist /tmp/debian-$dist-mm.tar $mirror

mkdir /tmp/debian-$dist-mm
tar -C /tmp/debian-$dist-mm -xf /tmp/debian-$dist-mm.tar

mkdir /tmp/debian-$dist-debootstrap
tar -C /tmp/debian-$dist-debootstrap -xf "cache/debian-$dist-$variant.tar"

# diff cannot compare device nodes, so we use tar to do that for us and then
# delete the directory
tar -C /tmp/debian-$dist-debootstrap -cf dev1.tar ./dev
tar -C /tmp/debian-$dist-mm -cf dev2.tar ./dev
cmp dev1.tar dev2.tar
rm dev1.tar dev2.tar
rm -r /tmp/debian-$dist-debootstrap/dev /tmp/debian-$dist-mm/dev

# remove downloaded deb packages
rm /tmp/debian-$dist-debootstrap/var/cache/apt/archives/*.deb
# remove aux-cache
rm /tmp/debian-$dist-debootstrap/var/cache/ldconfig/aux-cache
# remove logs
rm /tmp/debian-$dist-debootstrap/var/log/dpkg.log \
	/tmp/debian-$dist-debootstrap/var/log/bootstrap.log \
	/tmp/debian-$dist-mm/var/log/apt/eipp.log.xz \
	/tmp/debian-$dist-debootstrap/var/log/alternatives.log
# remove *-old files
rm /tmp/debian-$dist-debootstrap/var/cache/debconf/config.dat-old \
	/tmp/debian-$dist-mm/var/cache/debconf/config.dat-old
rm /tmp/debian-$dist-debootstrap/var/cache/debconf/templates.dat-old \
	/tmp/debian-$dist-mm/var/cache/debconf/templates.dat-old
rm /tmp/debian-$dist-debootstrap/var/lib/dpkg/status-old \
	/tmp/debian-$dist-mm/var/lib/dpkg/status-old
# remove dpkg files
rm /tmp/debian-$dist-debootstrap/var/lib/dpkg/available \
	/tmp/debian-$dist-debootstrap/var/lib/dpkg/cmethopt
# since we installed packages directly from the .deb files, Priorities differ
# thus we first check for equality and then remove the files
chroot /tmp/debian-$dist-debootstrap dpkg --list > dpkg1
chroot /tmp/debian-$dist-mm dpkg --list > dpkg2
diff -u dpkg1 dpkg2
rm dpkg1 dpkg2
grep -v '^Priority: ' /tmp/debian-$dist-debootstrap/var/lib/dpkg/status > status1
grep -v '^Priority: ' /tmp/debian-$dist-mm/var/lib/dpkg/status > status2
diff -u status1 status2
rm status1 status2
rm /tmp/debian-$dist-debootstrap/var/lib/dpkg/status /tmp/debian-$dist-mm/var/lib/dpkg/status
rmdir /tmp/debian-$dist-mm/var/lib/apt/lists/auxfiles
# debootstrap exposes the hosts's kernel version
rm /tmp/debian-$dist-debootstrap/etc/apt/apt.conf.d/01autoremove-kernels \
	/tmp/debian-$dist-mm/etc/apt/apt.conf.d/01autoremove-kernels
# who creates /run/mount?
rm -f /tmp/debian-$dist-debootstrap/run/mount/utab
rmdir /tmp/debian-$dist-debootstrap/run/mount
# debootstrap doesn't clean apt
rm /tmp/debian-$dist-debootstrap/var/lib/apt/lists/127.0.0.1_debian_dists_${dist}_main_binary-amd64_Packages \
	/tmp/debian-$dist-debootstrap/var/lib/apt/lists/127.0.0.1_debian_dists_${dist}_Release \
	/tmp/debian-$dist-debootstrap/var/lib/apt/lists/127.0.0.1_debian_dists_${dist}_Release.gpg

if [ "$variant" = "-" ]; then
	rm /tmp/debian-$dist-debootstrap/etc/machine-id
	rm /tmp/debian-$dist-mm/etc/machine-id
	rm /tmp/debian-$dist-debootstrap/var/lib/systemd/catalog/database
	rm /tmp/debian-$dist-mm/var/lib/systemd/catalog/database
fi
rm /tmp/debian-$dist-debootstrap/var/lib/dpkg/lock
# introduced in dpkg 1.19.1
if [ "$dist" != "stable" ]; then
	rm /tmp/debian-$dist-debootstrap/var/lib/dpkg/lock-frontend
fi

# check if the file content differs
diff --no-dereference --brief --recursive /tmp/debian-$dist-debootstrap /tmp/debian-$dist-mm

# check if file properties (permissions, ownership, symlink names, modification time) differ
#
# we cannot use this (yet) because it cannot copy with paths that have [ or @ in them
#fmtree -c -p /tmp/debian-$dist-debootstrap -k flags,gid,link,mode,size,time,uid | sudo fmtree -p /tmp/debian-$dist-mm

rm /tmp/debian-$dist-mm.tar
rm -r /tmp/debian-$dist-debootstrap /tmp/debian-$dist-mm
END
		if [ "$HAVE_QEMU" = "yes" ]; then
			./run_qemu.sh
		else
			./run_null.sh SUDO
		fi
	done
done

print_header "mode=root,variant=apt: create directory"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
$CMD --mode=root --variant=apt unstable /tmp/debian-unstable $mirror
tar -C /tmp/debian-unstable --one-file-system -c . | tar -t | sort > tar1.txt
rm -r /tmp/debian-unstable
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: test progress bars on fake tty"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
script -qfc "$CMD --mode=root --variant=apt unstable /tmp/unstable-chroot.tar $mirror" /dev/null
tar -tf /tmp/unstable-chroot.tar | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm /tmp/unstable-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: existing empty directory"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
mkdir /tmp/debian-unstable
$CMD --mode=root --variant=apt unstable /tmp/debian-unstable $mirror
tar -C /tmp/debian-unstable --one-file-system -c . | tar -t | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm -r /tmp/debian-unstable
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=unshare,variant=apt: create tarball"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
adduser --gecos user --disabled-password user
sysctl -w kernel.unprivileged_userns_clone=1
runuser -u user -- $CMD --mode=unshare --variant=apt unstable /tmp/unstable-chroot.tar $mirror
tar -tf /tmp/unstable-chroot.tar | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm /tmp/unstable-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

print_header "mode=$defaultmode,variant=apt: read from stdin, write to stdout"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
echo "deb $mirror unstable main" | $CMD --mode=$defaultmode --variant=apt > /tmp/unstable-chroot.tar
tar -tf /tmp/unstable-chroot.tar | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm /tmp/unstable-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=auto,variant=apt: default mirror"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
echo "127.0.0.1 deb.debian.org" >> /etc/hosts
$CMD --mode=$defaultmode --variant=apt unstable /tmp/unstable-chroot.tar
tar -tf /tmp/unstable-chroot.tar | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm /tmp/unstable-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=auto,variant=apt: pass distribution but implicitly write to stdout"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
echo "127.0.0.1 deb.debian.org" >> /etc/hosts
$CMD --mode=$defaultmode --variant=apt unstable > /tmp/unstable-chroot.tar
tar -tf /tmp/unstable-chroot.tar | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm /tmp/unstable-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

print_header "mode=auto,variant=apt: mirror is -"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
echo "deb $mirror unstable main" | $CMD --mode=$defaultmode --variant=apt unstable /tmp/unstable-chroot.tar -
tar -tf /tmp/unstable-chroot.tar | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm /tmp/unstable-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=auto,variant=apt: mirror is deb..."
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
$CMD --mode=$defaultmode --variant=apt unstable /tmp/unstable-chroot.tar "deb $mirror unstable main"
tar -tf /tmp/unstable-chroot.tar | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm /tmp/unstable-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=auto,variant=apt: mirror is real file"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
echo "deb $mirror unstable main" > /tmp/sources.list
$CMD --mode=$defaultmode --variant=apt unstable /tmp/unstable-chroot.tar /tmp/sources.list
tar -tf /tmp/unstable-chroot.tar | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm /tmp/unstable-chroot.tar /tmp/sources.list
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=auto,variant=apt: no mirror but data on stdin"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
echo "deb $mirror unstable main" | $CMD --mode=$defaultmode --variant=apt unstable /tmp/unstable-chroot.tar
tar -tf /tmp/unstable-chroot.tar | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm /tmp/unstable-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=root,variant=apt: add foreign architecture"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
$CMD --mode=root --variant=apt --architectures=amd64,armhf unstable /tmp/debian-unstable $mirror
{ echo "amd64"; echo "armhf"; } | cmp /tmp/debian-unstable/var/lib/dpkg/arch -
rm /tmp/debian-unstable/var/lib/dpkg/arch
tar -C /tmp/debian-unstable --one-file-system -c . | tar -t | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm -r /tmp/debian-unstable
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: test --aptopt"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
$CMD --mode=root --variant=apt --aptopt="Acquire::Check-Valid-Until false" unstable /tmp/debian-unstable $mirror
echo "Acquire::Check-Valid-Until false;" | cmp /tmp/debian-unstable/etc/apt/apt.conf.d/99mmdebstrap -
rm /tmp/debian-unstable/etc/apt/apt.conf.d/99mmdebstrap
tar -C /tmp/debian-unstable --one-file-system -c . | tar -t | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm -r /tmp/debian-unstable
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: test --dpkgopt"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
$CMD --mode=root --variant=apt --dpkgopt="path-exclude=/usr/share/doc/*" unstable /tmp/debian-unstable $mirror
echo "path-exclude=/usr/share/doc/*" | cmp /tmp/debian-unstable/etc/dpkg/dpkg.cfg.d/99mmdebstrap -
rm /tmp/debian-unstable/etc/dpkg/dpkg.cfg.d/99mmdebstrap
tar -C /tmp/debian-unstable --one-file-system -c . | tar -t | sort > tar2.txt
grep -v '^./usr/share/doc/.' tar1.txt | diff -u - tar2.txt
rm -r /tmp/debian-unstable
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: test --include"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
$CMD --mode=root --variant=apt --include=doc-debian unstable /tmp/debian-unstable $mirror
rm /tmp/debian-unstable/usr/share/doc-base/debian-*
rm -r /tmp/debian-unstable/usr/share/doc/debian
rm -r /tmp/debian-unstable/usr/share/doc/doc-debian
rm /tmp/debian-unstable/var/log/apt/eipp.log.xz
rm /tmp/debian-unstable/var/lib/dpkg/info/doc-debian.list
rm /tmp/debian-unstable/var/lib/dpkg/info/doc-debian.md5sums
tar -C /tmp/debian-unstable --one-file-system -c . | tar -t | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm -r /tmp/debian-unstable
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

# test all variants

for variant in essential apt required minbase buildd important debootstrap - standard; do
	print_header "mode=root,variant=$variant: create directory"
	cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
$CMD --mode=root --variant=$variant unstable /tmp/unstable-chroot.tar $mirror
tar -tf /tmp/unstable-chroot.tar | sort > "$variant.txt"
rm /tmp/unstable-chroot.tar
END
	if [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
	else
		./run_null.sh SUDO
	fi
	# check if the other modes produce the same result in each variant
	for mode in unshare fakechroot proot; do
		# fontconfig doesn't install reproducibly because differences
		# in /var/cache/fontconfig/. See
		# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=864082
		if [ "$variant" = standard ]; then
			continue
		fi
		# FIXME: cannot test fakechroot or proot in any other variant
		#        than essential because of
		#        https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=909637
		case "$mode" in
			fakechroot|proot)
				if [ "$variant" != "essential" ]; then
					continue
				fi
				;;
		esac
		print_header "mode=$mode,variant=$variant: create tarball"
		if [ "$mode" = "unshare" ] && [ "$HAVE_UNSHARE" != "yes" ]; then
			echo "HAVE_UNSHARE != yes -- Skipping test..."
			continue
		fi
		if [ "$mode" = "proot" ] && [ "$HAVE_PROOT" != "yes" ]; then
			echo "HAVE_PROOT != yes -- Skipping test..."
			continue
		fi
		cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
[ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1 && adduser --gecos user --disabled-password user
[ "$mode" = unshare ] && sysctl -w kernel.unprivileged_userns_clone=1
prefix=
[ "\$(id -u)" -eq 0 ] && prefix="runuser -u user --"
\$prefix $CMD --mode=$mode --variant=$variant unstable /tmp/unstable-chroot.tar $mirror
# in fakechroot mode, we use a fake ldconfig, so we have to
# artificially add some files
{ tar -tf /tmp/unstable-chroot.tar;
  [ "$mode" = "fakechroot" ] && printf "./etc/ld.so.cache\n./var/cache/ldconfig/\n";
} | sort | diff -u "./$variant.txt" -
rm /tmp/unstable-chroot.tar
END
		if [ "$HAVE_QEMU" = "yes" ]; then
			./run_qemu.sh
		else
			./run_null.sh
		fi
		# Devel::Cover doesn't survive mmdebstrap re-exec-ing itself
		# with fakechroot, thus, we do an additional run where we
		# explicitly run mmdebstrap with fakechroot from the start
		if [ "$mode" = "fakechroot" ]; then
			print_header "mode=$mode,variant=$variant: create tarball (ver 2)"
			cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
[ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1 && adduser --gecos user --disabled-password user
prefix=
[ "\$(id -u)" -eq 0 ] && prefix="runuser -u user --"
\$prefix fakechroot fakeroot $CMD --mode=$mode --variant=$variant unstable /tmp/unstable-chroot.tar $mirror
{ tar -tf /tmp/unstable-chroot.tar;
  printf "./etc/ld.so.cache\n./var/cache/ldconfig/\n";
} | sort | diff -u "./$variant.txt" -
rm /tmp/unstable-chroot.tar
END
			if [ "$HAVE_QEMU" = "yes" ]; then
				./run_qemu.sh
			else
				./run_null.sh
			fi
		fi
	done
	# some variants are equal and some are strict superset of the last
	# special case of the buildd variant: nothing is a superset of it
	case "$variant" in
		essential) ;; # nothing to compare it to
		apt)
			[ $(comm -23 shared/essential.txt shared/apt.txt | wc -l) -eq 0 ]
			[ $(comm -13 shared/essential.txt shared/apt.txt | wc -l) -gt 0 ]
			rm shared/essential.txt
			;;
		required)
			[ $(comm -23 shared/apt.txt shared/required.txt | wc -l) -eq 0 ]
			[ $(comm -13 shared/apt.txt shared/required.txt | wc -l) -gt 0 ]
			rm shared/apt.txt
			;;
		minbase) # equal to required
			cmp shared/required.txt shared/minbase.txt
			rm shared/required.txt
			;;
		buildd)
			[ $(comm -23 shared/minbase.txt shared/buildd.txt | wc -l) -eq 0 ]
			[ $(comm -13 shared/minbase.txt shared/buildd.txt | wc -l) -gt 0 ]
			rm shared/buildd.txt # we need minbase.txt but not buildd.txt
			;;
		important)
			[ $(comm -23 shared/minbase.txt shared/important.txt | wc -l) -eq 0 ]
			[ $(comm -13 shared/minbase.txt shared/important.txt | wc -l) -gt 0 ]
			rm shared/minbase.txt
			;;
		debootstrap) # equal to important
			cmp shared/important.txt shared/debootstrap.txt
			rm shared/important.txt
			;;
		-) # equal to debootstrap
			cmp shared/debootstrap.txt shared/-.txt
			rm shared/debootstrap.txt
			;;
		standard)
			[ $(comm -23 shared/-.txt shared/standard.txt | wc -l) -eq 0 ]
			[ $(comm -13 shared/-.txt shared/standard.txt | wc -l) -gt 0 ]
			rm shared/-.txt shared/standard.txt
			;;
		*) exit 1;;
	esac
done

# test extract variant also with chrootless mode
for mode in root unshare fakechroot proot chrootless; do
	print_header "mode=$mode,variant=extract: unpack doc-debian"
	if [ "$mode" = "unshare" ] && [ "$HAVE_UNSHARE" != "yes" ]; then
		echo "HAVE_UNSHARE != yes -- Skipping test..."
		continue
	fi
	if [ "$mode" = "proot" ] && [ "$HAVE_PROOT" != "yes" ]; then
		echo "HAVE_PROOT != yes -- Skipping test..."
		continue
	fi
	cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
[ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1 && adduser --gecos user --disabled-password user
[ "$mode" = unshare ] && sysctl -w kernel.unprivileged_userns_clone=1
prefix=
[ "\$(id -u)" -eq 0 ] && [ "$mode" != "root" ] && prefix="runuser -u user --"
[ "$mode" = "fakechroot" ] && prefix="\$prefix fakechroot fakeroot"
\$prefix $CMD --mode=$mode --variant=extract --include=doc-debian unstable /tmp/debian-unstable $mirror
# delete contents of doc-debian
rm /tmp/debian-unstable/usr/share/doc-base/debian-*
rm -r /tmp/debian-unstable/usr/share/doc/debian
rm -r /tmp/debian-unstable/usr/share/doc/doc-debian
# delete real files
rm /tmp/debian-unstable/etc/apt/sources.list
rm /tmp/debian-unstable/etc/fstab
rm /tmp/debian-unstable/etc/hostname
rm /tmp/debian-unstable/etc/resolv.conf
rm /tmp/debian-unstable/var/lib/dpkg/status
# delete symlinks
rm /tmp/debian-unstable/libx32
rm /tmp/debian-unstable/lib64
rm /tmp/debian-unstable/lib32
rm /tmp/debian-unstable/sbin
rm /tmp/debian-unstable/bin
rm /tmp/debian-unstable/lib
# delete ./dev (files might exist or not depending on the mode)
rm -f /tmp/debian-unstable/dev/console
rm -f /tmp/debian-unstable/dev/fd
rm -f /tmp/debian-unstable/dev/full
rm -f /tmp/debian-unstable/dev/null
rm -f /tmp/debian-unstable/dev/ptmx
rm -f /tmp/debian-unstable/dev/random
rm -f /tmp/debian-unstable/dev/stderr
rm -f /tmp/debian-unstable/dev/stdin
rm -f /tmp/debian-unstable/dev/stdout
rm -f /tmp/debian-unstable/dev/tty
rm -f /tmp/debian-unstable/dev/urandom
rm -f /tmp/debian-unstable/dev/zero
# the rest should be empty directories that we can rmdir recursively
find /tmp/debian-unstable -depth -print0 | xargs -0 rmdir
END
	if [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
	elif [ "$mode" = "root" ]; then
		./run_null.sh SUDO
	else
		./run_null.sh
	fi
done

print_header "mode=chrootless,variant=custom: install doc-debian"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
[ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1 && adduser --gecos user --disabled-password user
prefix=
[ "\$(id -u)" -eq 0 ] && prefix="runuser -u user --"
\$prefix $CMD --mode=chrootless --variant=custom --include=doc-debian unstable /tmp/debian-unstable $mirror
# delete contents of doc-debian
rm /tmp/debian-unstable/usr/share/doc-base/debian-*
rm -r /tmp/debian-unstable/usr/share/doc/debian
rm -r /tmp/debian-unstable/usr/share/doc/doc-debian
# delete real files
rm /tmp/debian-unstable/etc/apt/sources.list
rm /tmp/debian-unstable/etc/fstab
rm /tmp/debian-unstable/etc/hostname
rm /tmp/debian-unstable/etc/resolv.conf
rm /tmp/debian-unstable/var/lib/dpkg/status
# delete symlinks
rm /tmp/debian-unstable/libx32
rm /tmp/debian-unstable/lib64
rm /tmp/debian-unstable/lib32
rm /tmp/debian-unstable/sbin
rm /tmp/debian-unstable/bin
rm /tmp/debian-unstable/lib
# in chrootless mode, there is more to remove
rm /tmp/debian-unstable/var/log/apt/eipp.log.xz
rm /tmp/debian-unstable/var/lib/dpkg/triggers/Lock
rm /tmp/debian-unstable/var/lib/dpkg/triggers/Unincorp
rm /tmp/debian-unstable/var/lib/dpkg/status-old
rm /tmp/debian-unstable/var/lib/dpkg/info/format
rm /tmp/debian-unstable/var/lib/dpkg/info/doc-debian.md5sums
rm /tmp/debian-unstable/var/lib/dpkg/info/doc-debian.list
# the rest should be empty directories that we can rmdir recursively
find /tmp/debian-unstable -depth -print0 | xargs -0 rmdir
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh
fi

# test foreign architecture with all modes
# create directory in sudo mode
# FIXME: once fakechroot and proot are fixed, we have to test more variants
#        than just essential
print_header "mode=root,variant=essential: create directory"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
$CMD --mode=root --variant=essential unstable /tmp/unstable-chroot.tar $mirror
tar -tf /tmp/unstable-chroot.tar | sort > tar1.txt
rm /tmp/unstable-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

# FIXME: once fakechroot and proot are fixed, we can switch to variant=apt
# FIXME: cannot test fakechroot or proot because of
#        https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=909637
for mode in root unshare fakechroot proot; do
	print_header "mode=$mode,variant=essential: create armhf tarball"
	if [ "$HAVE_BINFMT" != "yes" ]; then
		echo "HAVE_BINFMT != yes -- Skipping test..."
		continue
	fi
	if [ "$mode" = "unshare" ] && [ "$HAVE_UNSHARE" != "yes" ]; then
		echo "HAVE_UNSHARE != yes -- Skipping test..."
		continue
	fi
	if [ "$mode" = "proot" ] && [ "$HAVE_PROOT" != "yes" ]; then
		echo "HAVE_PROOT != yes -- Skipping test..."
		continue
	fi
	cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C
[ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1 && adduser --gecos user --disabled-password user
[ "$mode" = unshare ] && sysctl -w kernel.unprivileged_userns_clone=1
prefix=
[ "\$(id -u)" -eq 0 ] && [ "$mode" != "root" ] && prefix="runuser -u user --"
[ "$mode" = "fakechroot" ] && prefix="\$prefix fakechroot fakeroot"
\$prefix $CMD --mode=$mode --variant=essential --architectures=armhf unstable /tmp/unstable-chroot.tar $mirror
# we ignore differences between architectures by ignoring some files
# and renaming others
# in fakechroot mode, we use a fake ldconfig, so we have to
# artificially add some files
# in proot mode, some extra files are put there by proot
{ tar -tf /tmp/unstable-chroot.tar \
	| grep -v '^\./usr/lib/ld-linux-armhf\.so\.3$' \
	| grep -v '^\./usr/lib/arm-linux-gnueabihf/ld-linux\.so\.3$' \
	| grep -v '^\./usr/lib/arm-linux-gnueabihf/ld-linux-armhf\.so\.3$' \
	| sed 's/arm-linux-gnueabihf/x86_64-linux-gnu/' \
	| sed 's/armhf/amd64/';
	[ "$mode" = "fakechroot" ] && printf "./etc/ld.so.cache\n./var/cache/ldconfig/\n";
} | sort > tar2.txt
{ cat tar1.txt \
	| grep -v '^\./usr/bin/i386$' \
	| grep -v '^\./usr/bin/x86_64$' \
	| grep -v '^\./usr/lib64/ld-linux-x86-64\.so\.2$' \
	| grep -v '^\./usr/lib/x86_64-linux-gnu/ld-linux-x86-64\.so\.2$' \
	| grep -v '^\./usr/lib/x86_64-linux-gnu/libmvec-2\.[0-9]\+\.so$' \
	| grep -v '^\./usr/lib/x86_64-linux-gnu/libmvec\.so\.1$' \
	| grep -v '^\./usr/share/man/man8/i386\.8\.gz$' \
	| grep -v '^\./usr/share/man/man8/x86_64\.8\.gz$';
	[ "$mode" = "proot" ] && printf "./etc/ld.so.preload\n";
} | sort | diff -u - tar2.txt
rm /tmp/unstable-chroot.tar
END
	if [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
	elif [ "$mode" = "root" ]; then
		./run_null.sh SUDO
	else
		./run_null.sh
	fi
done

# test if auto mode picks the right mode

# test installation of foreign architecture packages

# test tty output

if [ "$HAVE_QEMU" = "yes" ]; then
	guestfish add-ro shared/cover_db.img : run : mount /dev/sda / : tar-out / - \
		| tar -C shared/cover_db --extract
fi

if [ -e shared/cover_db/runs ]; then
	cover -nogcov -report html_basic shared/cover_db
	mkdir -p report
	for f in common.js coverage.html cover.css css.js mmdebstrap--branch.html mmdebstrap--condition.html mmdebstrap.html mmdebstrap--subroutine.html standardista-table-sorting.js; do
		cp -a shared/cover_db/$f report
	done
	cover -delete shared/cover_db

	echo
	echo open file://$(pwd)/report/coverage.html in a browser
	echo
fi

rm shared/tar1.txt shared/tar2.txt
