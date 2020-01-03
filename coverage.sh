#!/bin/sh

set -eu

mirrordir="./shared/cache/debian"

if [ ! -e "$mirrordir" ]; then
	echo "run ./make_mirror.sh before running $0" >&2
	exit 1
fi

# we use -f because the file might not exist
rm -f shared/cover_db.img

: "${DEFAULT_DIST:=unstable}"
: "${HAVE_QEMU:=yes}"
: "${RUN_MA_SAME_TESTS:=yes}"

if [ "$HAVE_QEMU" = "yes" ]; then
	# prepare image for cover_db
	guestfish -N shared/cover_db.img=disk:256M -- mkfs vfat /dev/sda

	if [ ! -e "./shared/cache/debian-$DEFAULT_DIST.qcow" ]; then
		echo "./shared/cache/debian-$DEFAULT_DIST.qcow does not exist" >&2
		exit 1
	fi
fi

# check if all required debootstrap tarballs exist
notfound=0
for dist in stable testing unstable; do
	for variant in minbase buildd -; do
		if [ ! -e "shared/cache/debian-$dist-$variant.tar" ]; then
			echo "shared/cache/debian-$dist-$variant.tar does not exist" >&2
			notfound=1
		fi
	done
done
if [ "$notfound" -ne 0 ]; then
	echo "not all required debootstrap tarballs are present" >&2
	exit 1
fi

# only copy if necessary
if [ ! -e shared/mmdebstrap ] || [ mmdebstrap -nt shared/mmdebstrap ]; then
	cp -a mmdebstrap shared
fi

starttime=
total=122
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
SOURCE_DATE_EPOCH=$(date --date="$(grep-dctrl -s Date -n '' "$mirrordir/dists/$DEFAULT_DIST/Release")" +%s)

# for traditional sort order that uses native byte values
export LC_ALL=C.UTF-8

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
		print_header "mode=$defaultmode,variant=$variant: check against debootstrap $dist"

		cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
export SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
$CMD --variant=$variant --mode=$defaultmode $dist /tmp/debian-$dist-mm.tar $mirror

mkdir /tmp/debian-$dist-mm
tar --xattrs --xattrs-include='*' -C /tmp/debian-$dist-mm -xf /tmp/debian-$dist-mm.tar

mkdir /tmp/debian-$dist-debootstrap
tar --xattrs --xattrs-include='*' -C /tmp/debian-$dist-debootstrap -xf "cache/debian-$dist-$variant.tar"

# diff cannot compare device nodes, so we use tar to do that for us and then
# delete the directory
tar -C /tmp/debian-$dist-debootstrap -cf dev1.tar ./dev
tar -C /tmp/debian-$dist-mm -cf dev2.tar ./dev
ret=0
cmp dev1.tar dev2.tar || ret=\$?
if [ "\$ret" -ne 0 ]; then
	if type diffoscope >/dev/null; then
		diffoscope dev1.tar dev2.tar
		continue
	else
		echo "no diffoscope installed" >&2
	fi
	if type base64 >/dev/null; then
		base64 dev1.tar
		base64 dev2.tar
		continue
	else
		echo "no base64 installed" >&2
	fi
	if type xxd >/dev/null; then
		xxd dev1.tar
		xxd dev2.tar
		continue
	else
		echo "no xxd installed" >&2
	fi
	exit 1
fi
rm dev1.tar dev2.tar
rm -r /tmp/debian-$dist-debootstrap/dev /tmp/debian-$dist-mm/dev

# remove downloaded deb packages
rm /tmp/debian-$dist-debootstrap/var/cache/apt/archives/*.deb
# remove aux-cache
rm /tmp/debian-$dist-debootstrap/var/cache/ldconfig/aux-cache
# remove logs
rm /tmp/debian-$dist-debootstrap/var/log/dpkg.log \
	/tmp/debian-$dist-debootstrap/var/log/bootstrap.log \
	/tmp/debian-$dist-debootstrap/var/log/alternatives.log
# remove *-old files
rm /tmp/debian-$dist-debootstrap/var/cache/debconf/config.dat-old \
	/tmp/debian-$dist-mm/var/cache/debconf/config.dat-old
rm /tmp/debian-$dist-debootstrap/var/cache/debconf/templates.dat-old \
	/tmp/debian-$dist-mm/var/cache/debconf/templates.dat-old
rm /tmp/debian-$dist-debootstrap/var/lib/dpkg/status-old \
	/tmp/debian-$dist-mm/var/lib/dpkg/status-old
# remove dpkg files
rm /tmp/debian-$dist-debootstrap/var/lib/dpkg/available
touch /tmp/debian-$dist-debootstrap/var/lib/dpkg/available
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
# debootstrap exposes the hosts's kernel version
rm /tmp/debian-$dist-debootstrap/etc/apt/apt.conf.d/01autoremove-kernels \
	/tmp/debian-$dist-mm/etc/apt/apt.conf.d/01autoremove-kernels
# who creates /run/mount?
if [ -e "/tmp/debian-$dist-debootstrap/run/mount/utab" ]; then
	rm "/tmp/debian-$dist-debootstrap/run/mount/utab"
fi
if [ -e "/tmp/debian-$dist-debootstrap/run/mount" ]; then
	rmdir "/tmp/debian-$dist-debootstrap/run/mount"
fi
# debootstrap doesn't clean apt
rm /tmp/debian-$dist-debootstrap/var/lib/apt/lists/127.0.0.1_debian_dists_${dist}_main_binary-amd64_Packages \
	/tmp/debian-$dist-debootstrap/var/lib/apt/lists/127.0.0.1_debian_dists_${dist}_Release \
	/tmp/debian-$dist-debootstrap/var/lib/apt/lists/127.0.0.1_debian_dists_${dist}_Release.gpg

if [ "$variant" = "-" ]; then
	rm /tmp/debian-$dist-debootstrap/etc/machine-id
	rm /tmp/debian-$dist-mm/etc/machine-id
	rm /tmp/debian-$dist-debootstrap/var/lib/systemd/catalog/database
	rm /tmp/debian-$dist-mm/var/lib/systemd/catalog/database

	cap=\$(chroot /tmp/debian-$dist-debootstrap /sbin/getcap /bin/ping)
	if [ "\$cap" != "/bin/ping = cap_net_raw+ep" ]; then
		echo "expected bin/ping to have capabilities cap_net_raw+ep" >&2
		echo "but debootstrap produced: \$cap"
		exit 1
	fi
	cap=\$(chroot /tmp/debian-$dist-mm /sbin/getcap /bin/ping)
	if [ "\$cap" != "/bin/ping = cap_net_raw+ep" ]; then
		echo "expected bin/ping to have capabilities cap_net_raw+ep" >&2
		echo "but mmdebstrap produced: \$cap"
		exit 1
	fi
fi
rm /tmp/debian-$dist-mm/var/cache/apt/archives/lock
rm /tmp/debian-$dist-mm/var/lib/apt/extended_states
rm /tmp/debian-$dist-mm/var/lib/apt/lists/lock

# the list of shells might be sorted wrongly
for f in "/tmp/debian-$dist-debootstrap/etc/shells" "/tmp/debian-$dist-mm/etc/shells"; do
	sort -o "\$f" "\$f"
done

# workaround for https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=917773
awk -v FS=: -v OFS=: -v SDE=\$SOURCE_DATE_EPOCH '{ print \$1,\$2,int(SDE/60/60/24),\$4,\$5,\$6,\$7,\$8,\$9 }' < /tmp/debian-$dist-mm/etc/shadow > /tmp/debian-$dist-mm/etc/shadow.bak
mv /tmp/debian-$dist-mm/etc/shadow.bak /tmp/debian-$dist-mm/etc/shadow
awk -v FS=: -v OFS=: -v SDE=\$SOURCE_DATE_EPOCH '{ print \$1,\$2,int(SDE/60/60/24),\$4,\$5,\$6,\$7,\$8,\$9 }' < /tmp/debian-$dist-mm/etc/shadow- > /tmp/debian-$dist-mm/etc/shadow-.bak
mv /tmp/debian-$dist-mm/etc/shadow-.bak /tmp/debian-$dist-mm/etc/shadow-

# check if the file content differs
diff --no-dereference --recursive /tmp/debian-$dist-debootstrap /tmp/debian-$dist-mm

# check if file properties (permissions, ownership, symlink names, modification time) differ
#
# we cannot use this (yet) because it cannot copy with paths that have [ or @ in them
#fmtree -c -p /tmp/debian-$dist-debootstrap -k flags,gid,link,mode,size,time,uid | sudo fmtree -p /tmp/debian-$dist-mm

rm /tmp/debian-$dist-mm.tar
rm -r /tmp/debian-$dist-debootstrap /tmp/debian-$dist-mm
END
		if [ "$HAVE_QEMU" = "yes" ]; then
			./run_qemu.sh
		elif [ "$defaultmode" = "root" ]; then
			./run_null.sh SUDO
		else
			./run_null.sh
		fi
	done
done

print_header "test --help"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --help | grep --quiet --fixed-strings 'mmdebstrap [OPTION...] [SUITE [TARGET [MIRROR...]]]'
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "test --man"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --man | grep --quiet --fixed-strings 'mmdebstrap [OPTION...] [*SUITE* [*TARGET* [*MIRROR*...]]]'
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "test --version"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --version | egrep --quiet '^mmdebstrap [0-9](\.[0-9])+$'
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: create directory"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt $DEFAULT_DIST /tmp/debian-chroot $mirror
chroot /tmp/debian-chroot dpkg-query --showformat '\${binary:Package}\n' --show > pkglist.txt
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort > tar1.txt
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=unshare,variant=apt: fail with unshare as root user"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
ret=0
$CMD --mode=unshare --variant=apt $DEFAULT_DIST /tmp/debian-chroot $mirror || ret=\$?
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

print_header "mode=$defaultmode,variant=apt: test progress bars on fake tty"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
script -qfc "$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar $mirror" /dev/null
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=$defaultmode,variant=apt: test --debug output on fake tty"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
script -qfc "$CMD --mode=$defaultmode --debug --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar $mirror" /dev/null
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=root,variant=apt: existing empty directory"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
mkdir /tmp/debian-chroot
$CMD --mode=root --variant=apt $DEFAULT_DIST /tmp/debian-chroot $mirror
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: existing directory with lost+found"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
mkdir /tmp/debian-chroot
mkdir /tmp/debian-chroot/lost+found
$CMD --mode=root --variant=apt $DEFAULT_DIST /tmp/debian-chroot $mirror
rmdir /tmp/debian-chroot/lost+found
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=$defaultmode,variant=apt: fail installing to non-empty lost+found"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
mkdir /tmp/debian-chroot
mkdir /tmp/debian-chroot/lost+found
touch /tmp/debian-chroot/lost+found/exists
ret=0
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot $mirror || ret=\$?
rm /tmp/debian-chroot/lost+found/exists
rmdir /tmp/debian-chroot/lost+found
rmdir /tmp/debian-chroot
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=$defaultmode,variant=apt: fail installing to non-empty target directory"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
mkdir /tmp/debian-chroot
mkdir /tmp/debian-chroot/lost+found
touch /tmp/debian-chroot/exists
ret=0
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot $mirror || ret=\$?
rmdir /tmp/debian-chroot/lost+found
rm /tmp/debian-chroot/exists
rmdir /tmp/debian-chroot
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=root,variant=apt: chroot directory not accessible by _apt user"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
mkdir /tmp/debian-chroot
chmod 700 /tmp/debian-chroot
$CMD --mode=root --variant=apt $DEFAULT_DIST /tmp/debian-chroot $mirror
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=unshare,variant=apt: create gzip compressed tarball"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
adduser --gecos user --disabled-password user
sysctl -w kernel.unprivileged_userns_clone=1
runuser -u user -- $CMD --mode=unshare --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar.gz $mirror
printf '\037\213\010' | cmp --bytes=3 /tmp/debian-chroot.tar.gz -
tar -tf /tmp/debian-chroot.tar.gz | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar.gz
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

print_header "mode=$defaultmode,variant=apt: test xz compressed tarball"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar.xz $mirror
printf '\3757zXZ\0' | cmp --bytes=6 /tmp/debian-chroot.tar.xz -
tar -tf /tmp/debian-chroot.tar.xz | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar.xz
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=auto,variant=apt: test auto-mode without unshare capabilities"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
adduser --gecos user --disabled-password user
sysctl -w kernel.unprivileged_userns_clone=0
runuser -u user -- $CMD --mode=auto --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar.gz $mirror
{ tar -tf /tmp/debian-chroot.tar.gz;
  printf "./etc/ld.so.cache\n./var/cache/ldconfig/\n./etc/.pwd.lock\n";
} | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar.gz
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

print_header "mode=$defaultmode,variant=apt: fail with missing lz4"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
ret=0
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar.lz4 $mirror || ret=\$?
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=$defaultmode,variant=apt: fail with path with quotes"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
ret=0
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/quoted\"path $mirror || ret=\$?
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=root,variant=apt: create tarball with /tmp mounted nodev"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
mount -t tmpfs -o nodev,nosuid,size=300M tmpfs /tmp
# use --customize-hook to exercise the mounting/unmounting code of block devices in root mode
$CMD --mode=root --variant=apt --customize-hook='mount | grep /dev/full' --customize-hook='test "\$(echo foo | tee /dev/full 2>&1 1>/dev/null)" = "tee: /dev/full: No space left on device"' $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
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
export LC_ALL=C.UTF-8
echo "deb $mirror $DEFAULT_DIST main" | $CMD --mode=$defaultmode --variant=apt > /tmp/debian-chroot.tar
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=$defaultmode,variant=apt: supply components manually"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=$defaultmode --variant=apt --components="main main" --comp="main,main" $DEFAULT_DIST /tmp/debian-chroot $mirror
echo "deb $mirror $DEFAULT_DIST main" | cmp /tmp/debian-chroot/etc/apt/sources.list
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=root,variant=apt: stable default mirror"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
cat << HOSTS >> /etc/hosts
127.0.0.1 deb.debian.org
127.0.0.1 security.debian.org
HOSTS
apt-cache policy
cat /etc/apt/sources.list
$CMD --mode=root --variant=apt stable /tmp/debian-chroot
cat << SOURCES | cmp /tmp/debian-chroot/etc/apt/sources.list
deb http://deb.debian.org/debian stable main
deb http://deb.debian.org/debian stable-updates main
deb http://security.debian.org/debian-security stable/updates main
SOURCES
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

print_header "mode=$defaultmode,variant=apt: pass distribution but implicitly write to stdout"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
echo "127.0.0.1 deb.debian.org" >> /etc/hosts
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST > /tmp/debian-chroot.tar
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

print_header "mode=$defaultmode,variant=apt: test aspcud apt solver"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=$defaultmode --variant=custom \
    --include \$(cat pkglist.txt | tr '\n' ',') \
    --aptopt='APT::Solver "aspcud"' \
    $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
tar -tf /tmp/debian-chroot.tar | sort \
    | grep -v '^./etc/apt/apt.conf.d/99mmdebstrap$' \
    | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=$defaultmode,variant=apt: mirror is -"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
echo "deb $mirror $DEFAULT_DIST main" | $CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar -
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=$defaultmode,variant=apt: copy:// mirror"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar "deb copy:///mnt/cache/debian unstable main"
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

print_header "mode=$defaultmode,variant=apt: fail with file:// mirror"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
ret=0
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar "deb file:///mnt/cache/debian unstable main" || ret=\$?
rm /tmp/debian-chroot.tar
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

print_header "mode=$defaultmode,variant=apt: mirror is deb..."
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar "deb $mirror $DEFAULT_DIST main"
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=$defaultmode,variant=apt: mirror is real file"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
echo "deb $mirror $DEFAULT_DIST main" > /tmp/sources.list
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar /tmp/sources.list
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar /tmp/sources.list
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=$defaultmode,variant=apt: automatic mirror from suite"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
echo "127.0.0.1 deb.debian.org" >> /etc/hosts
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=$defaultmode,variant=apt: invalid mirror"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
ret=0
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar $mirror/invalid || ret=\$?
rm /tmp/debian-chroot.tar
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=root,variant=apt: fail installing to /"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
ret=0
$CMD --mode=root --variant=apt $DEFAULT_DIST / $mirror || ret=\$?
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: fail installing to existing file"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
touch /tmp/exists
ret=0
$CMD --mode=root --variant=apt $DEFAULT_DIST /tmp/exists $mirror || ret=\$?
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=$defaultmode,variant=apt: test armhf without qemu support"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
apt-get remove --yes qemu-user-static binfmt-support qemu-user
ret=0
$CMD --mode=$defaultmode --variant=apt --architectures=armhf $DEFAULT_DIST /tmp/debian-chroot.tar $mirror || ret=\$?
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

print_header "mode=$defaultmode,variant=apt: test i386 (which can be executed without qemu)"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
# remove qemu just to be sure
apt-get remove --yes qemu-user-static binfmt-support qemu-user
$CMD --mode=$defaultmode --variant=apt --architectures=i386 $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
# we ignore differences between architectures by ignoring some files
# and renaming others
{ tar -tf /tmp/debian-chroot.tar \
	| grep -v '^\./usr/bin/i386$' \
	| grep -v '^\./lib/ld-linux\.so\.2$' \
	| grep -v '^\./lib/i386-linux-gnu/ld-linux\.so\.2$' \
	| grep -v '^\./usr/lib/gcc/i686-linux-gnu/$' \
	| grep -v '^\./usr/lib/gcc/i686-linux-gnu/9/$' \
	| grep -v '^\./usr/share/man/man8/i386\.8\.gz$' \
	| grep -v '^\./usr/share/doc/[^/]\+/changelog\(\.Debian\)\?\.i386\.gz$' \
	| sed 's/i386-linux-gnu/x86_64-linux-gnu/' \
	| sed 's/i386/amd64/';
} | sort > tar2.txt
{ cat tar1.txt \
	| grep -v '^\./usr/bin/i386$' \
	| grep -v '^\./usr/bin/x86_64$' \
	| grep -v '^\./lib64/$' \
	| grep -v '^\./lib64/ld-linux-x86-64\.so\.2$' \
	| grep -v '^\./usr/lib/gcc/x86_64-linux-gnu/$' \
	| grep -v '^\./usr/lib/gcc/x86_64-linux-gnu/9/$' \
	| grep -v '^\./lib/x86_64-linux-gnu/ld-linux-x86-64\.so\.2$' \
	| grep -v '^\./lib/x86_64-linux-gnu/libmvec-2\.[0-9]\+\.so$' \
	| grep -v '^\./lib/x86_64-linux-gnu/libmvec\.so\.1$' \
	| grep -v '^\./usr/share/doc/[^/]\+/changelog\(\.Debian\)\?\.amd64\.gz$' \
	| grep -v '^\./usr/share/man/man8/i386\.8\.gz$' \
	| grep -v '^\./usr/share/man/man8/x86_64\.8\.gz$';
} | sort | diff -u - tar2.txt
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

# to test foreign architecture package installation we choose a package which
#   - is not part of the native installation set
#   - does not have any dependencies
#   - installs only few files
#   - doesn't change its name regularly (like gcc-*-base)
print_header "mode=root,variant=apt: test --include=libmagic-mgc:armhf"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt --architectures=amd64,armhf --include=libmagic-mgc:armhf $DEFAULT_DIST /tmp/debian-chroot $mirror
{ echo "amd64"; echo "armhf"; } | cmp /tmp/debian-chroot/var/lib/dpkg/arch -
rm /tmp/debian-chroot/var/lib/dpkg/arch
rm /tmp/debian-chroot/var/lib/apt/extended_states
rm /tmp/debian-chroot/var/lib/dpkg/info/libmagic-mgc.list
rm /tmp/debian-chroot/var/lib/dpkg/info/libmagic-mgc.md5sums
rm /tmp/debian-chroot/usr/lib/file/magic.mgc
rm /tmp/debian-chroot/usr/share/doc/libmagic-mgc/README.Debian
rm /tmp/debian-chroot/usr/share/doc/libmagic-mgc/changelog.Debian.gz
rm /tmp/debian-chroot/usr/share/doc/libmagic-mgc/changelog.gz
rm /tmp/debian-chroot/usr/share/doc/libmagic-mgc/copyright
rm /tmp/debian-chroot/usr/share/file/magic.mgc
rm /tmp/debian-chroot/usr/share/misc/magic.mgc
rmdir /tmp/debian-chroot/usr/share/doc/libmagic-mgc/
rmdir /tmp/debian-chroot/usr/share/file/magic/
rmdir /tmp/debian-chroot/usr/share/file/
rmdir /tmp/debian-chroot/usr/lib/file/
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$RUN_MA_SAME_TESTS" = "yes" ]; then
	if [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
	else
		./run_null.sh SUDO
	fi
else
	echo "RUN_MA_SAME_TESTS != yes -- Skipping test..."
fi

print_header "mode=root,variant=apt: test --include=libmagic-mgc:armhf with multiple --arch options"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt --architectures=amd64 --architectures=armhf --include=libmagic-mgc:armhf $DEFAULT_DIST /tmp/debian-chroot $mirror
{ echo "amd64"; echo "armhf"; } | cmp /tmp/debian-chroot/var/lib/dpkg/arch -
rm /tmp/debian-chroot/var/lib/dpkg/arch
rm /tmp/debian-chroot/var/lib/apt/extended_states
rm /tmp/debian-chroot/var/lib/dpkg/info/libmagic-mgc.list
rm /tmp/debian-chroot/var/lib/dpkg/info/libmagic-mgc.md5sums
rm /tmp/debian-chroot/usr/lib/file/magic.mgc
rm /tmp/debian-chroot/usr/share/doc/libmagic-mgc/README.Debian
rm /tmp/debian-chroot/usr/share/doc/libmagic-mgc/changelog.Debian.gz
rm /tmp/debian-chroot/usr/share/doc/libmagic-mgc/changelog.gz
rm /tmp/debian-chroot/usr/share/doc/libmagic-mgc/copyright
rm /tmp/debian-chroot/usr/share/file/magic.mgc
rm /tmp/debian-chroot/usr/share/misc/magic.mgc
rmdir /tmp/debian-chroot/usr/share/doc/libmagic-mgc/
rmdir /tmp/debian-chroot/usr/share/file/magic/
rmdir /tmp/debian-chroot/usr/share/file/
rmdir /tmp/debian-chroot/usr/lib/file/
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$RUN_MA_SAME_TESTS" = "yes" ]; then
	if [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
	else
		./run_null.sh SUDO
	fi
else
	echo "RUN_MA_SAME_TESTS != yes -- Skipping test..."
fi

print_header "mode=root,variant=apt: test --aptopt"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
echo 'Acquire::Languages "none";' > config
$CMD --mode=root --variant=apt --aptopt='Acquire::Check-Valid-Until "false"' --aptopt=config $DEFAULT_DIST /tmp/debian-chroot $mirror
printf 'Acquire::Check-Valid-Until "false";\nAcquire::Languages "none";\n' | cmp /tmp/debian-chroot/etc/apt/apt.conf.d/99mmdebstrap -
rm /tmp/debian-chroot/etc/apt/apt.conf.d/99mmdebstrap
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: test --keyring"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
rm /etc/apt/trusted.gpg.d/*.gpg
$CMD --mode=root --variant=apt --keyring=/usr/share/keyrings/debian-archive-keyring.gpg --keyring=/usr/share/keyrings/ $DEFAULT_DIST /tmp/debian-chroot $mirror
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

print_header "mode=root,variant=apt: test --keyring overwrites"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
mkdir -p emptydir
touch emptyfile
# this overwrites the apt keyring options and should fail
ret=0
$CMD --mode=root --variant=apt --keyring=./emptydir --keyring=./emptyfile $DEFAULT_DIST /tmp/debian-chroot $mirror || ret=\$?
rm -r /tmp/debian-chroot
rmdir emptydir
rm emptyfile
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: test signed-by without host keys"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
echo "deb $mirror $DEFAULT_DIST main" > /etc/apt/sources.list
apt-get -o Acquire::Languages=none update
apt-get install --yes --no-install-recommends gpg
rm /etc/apt/trusted.gpg.d/*.gpg
$CMD --mode=root --variant=apt $DEFAULT_DIST /tmp/debian-chroot $mirror
printf 'deb [signed-by="/usr/share/keyrings/debian-archive-keyring.gpg"] $mirror $DEFAULT_DIST main\n' | cmp /tmp/debian-chroot/etc/apt/sources.list -
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

print_header "mode=root,variant=apt: test signed-by with host keys"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
echo "deb $mirror $DEFAULT_DIST main" > /etc/apt/sources.list
apt-get -o Acquire::Languages=none update
apt-get install --yes --no-install-recommends gpg
$CMD --mode=root --variant=apt $DEFAULT_DIST /tmp/debian-chroot $mirror
printf 'deb $mirror $DEFAULT_DIST main\n' | cmp /tmp/debian-chroot/etc/apt/sources.list -
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

print_header "mode=root,variant=apt: test --dpkgopt"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
echo no-pager > config
$CMD --mode=root --variant=apt --dpkgopt="path-exclude=/usr/share/doc/*" --dpkgopt=config $DEFAULT_DIST /tmp/debian-chroot $mirror
printf 'path-exclude=/usr/share/doc/*\nno-pager\n' | cmp /tmp/debian-chroot/etc/dpkg/dpkg.cfg.d/99mmdebstrap -
rm /tmp/debian-chroot/etc/dpkg/dpkg.cfg.d/99mmdebstrap
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort > tar2.txt
grep -v '^./usr/share/doc/.' tar1.txt | diff -u - tar2.txt
rm -r /tmp/debian-chroot
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
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt --include=doc-debian $DEFAULT_DIST /tmp/debian-chroot $mirror
rm /tmp/debian-chroot/usr/share/doc-base/debian-*
rm -r /tmp/debian-chroot/usr/share/doc/debian
rm -r /tmp/debian-chroot/usr/share/doc/doc-debian
rm /tmp/debian-chroot/var/lib/apt/extended_states
rm /tmp/debian-chroot/var/lib/dpkg/info/doc-debian.list
rm /tmp/debian-chroot/var/lib/dpkg/info/doc-debian.md5sums
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: test multiple --include"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt --include=doc-debian --include=tzdata $DEFAULT_DIST /tmp/debian-chroot $mirror
rm /tmp/debian-chroot/usr/share/doc-base/debian-*
rm -r /tmp/debian-chroot/usr/share/doc/debian
rm -r /tmp/debian-chroot/usr/share/doc/doc-debian
rm /tmp/debian-chroot/etc/localtime
rm /tmp/debian-chroot/etc/timezone
rm /tmp/debian-chroot/usr/sbin/tzconfig
rm -r /tmp/debian-chroot/usr/share/doc/tzdata
rm -r /tmp/debian-chroot/usr/share/zoneinfo
rm /tmp/debian-chroot/var/lib/apt/extended_states
rm /tmp/debian-chroot/var/lib/dpkg/info/doc-debian.list
rm /tmp/debian-chroot/var/lib/dpkg/info/doc-debian.md5sums
rm /tmp/debian-chroot/var/lib/dpkg/info/tzdata.list
rm /tmp/debian-chroot/var/lib/dpkg/info/tzdata.md5sums
rm /tmp/debian-chroot/var/lib/dpkg/info/tzdata.config
rm /tmp/debian-chroot/var/lib/dpkg/info/tzdata.postinst
rm /tmp/debian-chroot/var/lib/dpkg/info/tzdata.postrm
rm /tmp/debian-chroot/var/lib/dpkg/info/tzdata.templates
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: test --setup-hook"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
cat << 'SCRIPT' > customize.sh
#!/bin/sh
for d in sbin lib; do ln -s usr/\$d "\$1/\$d"; mkdir -p "\$1/usr/\$d"; done
SCRIPT
chmod +x customize.sh
$CMD --mode=root --variant=apt --setup-hook='ln -s usr/bin "\$1/bin"; mkdir -p "\$1/usr/bin"' --setup-hook=./customize.sh $DEFAULT_DIST /tmp/debian-chroot $mirror
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort > tar2.txt
{ sed -e 's/^\.\/bin\//.\/usr\/bin\//;s/^\.\/lib\//.\/usr\/lib\//;s/^\.\/sbin\//.\/usr\/sbin\//;' tar1.txt; echo ./bin; echo ./lib; echo ./sbin; } | sort -u | diff -u - tar2.txt
rm customize.sh
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: test --essential-hook"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
cat << 'SCRIPT' > customize.sh
#!/bin/sh
echo tzdata tzdata/Zones/Europe select Berlin | chroot "\$1" debconf-set-selections
SCRIPT
chmod +x customize.sh
$CMD --mode=root --variant=apt --include=tzdata --essential-hook='echo tzdata tzdata/Areas select Europe | chroot "\$1" debconf-set-selections' --essential-hook=./customize.sh $DEFAULT_DIST /tmp/debian-chroot $mirror
echo Europe/Berlin | cmp /tmp/debian-chroot/etc/timezone
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort \
	| grep -v '^./etc/localtime' \
	| grep -v '^./etc/timezone' \
	| grep -v '^./usr/sbin/tzconfig' \
	| grep -v '^./usr/share/doc/tzdata' \
	| grep -v '^./usr/share/zoneinfo' \
	| grep -v '^./var/lib/dpkg/info/tzdata.' \
	| grep -v '^./var/lib/apt/extended_states$' \
	| diff -u tar1.txt -
rm customize.sh
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: test --customize-hook"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
cat << 'SCRIPT' > customize.sh
#!/bin/sh
chroot "\$1" whoami > "\$1/output2"
chroot "\$1" pwd >> "\$1/output2"
SCRIPT
chmod +x customize.sh
$CMD --mode=root --variant=apt --customize-hook='chroot "\$1" sh -c "whoami; pwd" > "\$1/output1"' --customize-hook=./customize.sh $DEFAULT_DIST /tmp/debian-chroot $mirror
printf "root\n/\n" | cmp /tmp/debian-chroot/output1
printf "root\n/\n" | cmp /tmp/debian-chroot/output2
rm /tmp/debian-chroot/output1
rm /tmp/debian-chroot/output2
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm customize.sh
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: test failing --customize-hook"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
ret=0
$CMD --mode=root --variant=apt --customize-hook='chroot "\$1" sh -c "exit 1"' $DEFAULT_DIST /tmp/debian-chroot $mirror || ret=\$?
rm -r /tmp/debian-chroot
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: test sigint during --customize-hook"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
setsid --wait $CMD --mode=root --variant=apt --customize-hook='touch done && sleep 10 && touch fail' $DEFAULT_DIST /tmp/debian-chroot $mirror &
pid=\$!
while sleep 1; do [ -e done ] && break; done
rm done
pgid=\$(echo \$(ps -p \$pid -o pgid=))
/bin/kill --signal INT -- -\$pgid
ret=0
wait \$pid || ret=\$?
rm -r /tmp/debian-chroot
if [ -e fail ]; then
	echo customize hook was not interrupted
	rm fail
	exit 1
fi
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

# test special hooks
for mode in root unshare fakechroot proot; do
	print_header "mode=$mode,variant=apt: test special hooks with $mode mode"
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
export LC_ALL=C.UTF-8
[ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1 && adduser --gecos user --disabled-password user
[ "$mode" = unshare ] && sysctl -w kernel.unprivileged_userns_clone=1
prefix=
[ "\$(id -u)" -eq 0 ] && [ "$mode" != "root" ] && prefix="runuser -u user --"
[ "$mode" = "fakechroot" ] && prefix="\$prefix fakechroot fakeroot"
symlinktarget=/real
case $mode in fakechroot|proot) symlinktarget='\$1/real';; esac
echo copy-in-setup > /tmp/copy-in-setup
echo copy-in-essential > /tmp/copy-in-essential
echo copy-in-customize > /tmp/copy-in-customize
echo tar-in-setup > /tmp/tar-in-setup
echo tar-in-essential > /tmp/tar-in-essential
echo tar-in-customize > /tmp/tar-in-customize
tar -C /tmp -cf /tmp/tar-in-setup.tar tar-in-setup
tar -C /tmp -cf /tmp/tar-in-essential.tar tar-in-essential
tar -C /tmp -cf /tmp/tar-in-customize.tar tar-in-customize
rm /tmp/tar-in-setup
rm /tmp/tar-in-essential
rm /tmp/tar-in-customize
echo upload-in-setup > /tmp/upload-in-setup
echo upload-in-essential > /tmp/upload-in-essential
echo upload-in-customize > /tmp/upload-in-customize
\$prefix $CMD --mode=$mode --variant=apt \
	--setup-hook='mkdir "\$1/real"' \
	--setup-hook='copy-in /tmp/copy-in-setup /real' \
	--setup-hook='echo copy-in-setup | cmp "\$1/real/copy-in-setup" -' \
	--setup-hook='rm "\$1/real/copy-in-setup"' \
	--setup-hook='echo copy-out-setup > "\$1/real/copy-out-setup"' \
	--setup-hook='copy-out /real/copy-out-setup /tmp' \
	--setup-hook='rm "\$1/real/copy-out-setup"' \
	--setup-hook='tar-in /tmp/tar-in-setup.tar /real' \
	--setup-hook='echo tar-in-setup | cmp "\$1/real/tar-in-setup" -' \
	--setup-hook='tar-out /real/tar-in-setup /tmp/tar-out-setup.tar' \
	--setup-hook='rm "\$1"/real/tar-in-setup' \
	--setup-hook='upload /tmp/upload-in-setup /real/upload' \
	--setup-hook='echo upload-in-setup | cmp "\$1/real/upload" -' \
	--setup-hook='download /real/upload /tmp/download-in-setup' \
	--setup-hook='rm "\$1/real/upload"' \
	--essential-hook='ln -s "'"\$symlinktarget"'" "\$1/symlink"' \
	--essential-hook='copy-in /tmp/copy-in-essential /symlink' \
	--essential-hook='echo copy-in-essential | cmp "\$1/real/copy-in-essential" -' \
	--essential-hook='rm "\$1/real/copy-in-essential"' \
	--essential-hook='echo copy-out-essential > "\$1/real/copy-out-essential"' \
	--essential-hook='copy-out /symlink/copy-out-essential /tmp' \
	--essential-hook='rm "\$1/real/copy-out-essential"' \
	--essential-hook='tar-in /tmp/tar-in-essential.tar /symlink' \
	--essential-hook='echo tar-in-essential | cmp "\$1/real/tar-in-essential" -' \
	--essential-hook='tar-out /symlink/tar-in-essential /tmp/tar-out-essential.tar' \
	--essential-hook='rm "\$1"/real/tar-in-essential' \
	--essential-hook='upload /tmp/upload-in-essential /symlink/upload' \
	--essential-hook='echo upload-in-essential | cmp "\$1/real/upload" -' \
	--essential-hook='download /symlink/upload /tmp/download-in-essential' \
	--essential-hook='rm "\$1/real/upload"' \
	--customize-hook='copy-in /tmp/copy-in-customize /symlink' \
	--customize-hook='echo copy-in-customize | cmp "\$1/real/copy-in-customize" -' \
	--customize-hook='rm "\$1/real/copy-in-customize"' \
	--customize-hook='echo copy-out-customize > "\$1/real/copy-out-customize"' \
	--customize-hook='copy-out /symlink/copy-out-customize /tmp' \
	--customize-hook='rm "\$1/real/copy-out-customize"' \
	--customize-hook='tar-in /tmp/tar-in-customize.tar /symlink' \
	--customize-hook='echo tar-in-customize | cmp "\$1/real/tar-in-customize" -' \
	--customize-hook='tar-out /symlink/tar-in-customize /tmp/tar-out-customize.tar' \
	--customize-hook='rm "\$1"/real/tar-in-customize' \
	--customize-hook='upload /tmp/upload-in-customize /symlink/upload' \
	--customize-hook='echo upload-in-customize | cmp "\$1/real/upload" -' \
	--customize-hook='download /symlink/upload /tmp/download-in-customize' \
	--customize-hook='rm "\$1/real/upload"' \
	--customize-hook='rmdir "\$1/real"' \
	--customize-hook='rm "\$1/symlink"' \
	$DEFAULT_DIST /tmp/debian-chroot.tar $mirror
for n in setup essential customize; do
	ret=0
	cmp /tmp/tar-in-\$n.tar /tmp/tar-out-\$n.tar || ret=\$?
	if [ "\$ret" -ne 0 ]; then
		if type diffoscope >/dev/null; then
			diffoscope /tmp/tar-in-\$n.tar /tmp/tar-out-\$n.tar
			continue
		else
			echo "no diffoscope installed" >&2
		fi
		if type base64 >/dev/null; then
			base64 /tmp/tar-in-\$n.tar
			base64 /tmp/tar-out-\$n.tar
			continue
		else
			echo "no base64 installed" >&2
		fi
		if type xxd >/dev/null; then
			xxd /tmp/tar-in-\$n.tar
			xxd /tmp/tar-out-\$n.tar
			continue
		else
			echo "no xxd installed" >&2
		fi
		exit 1
	fi
done
echo copy-out-setup | cmp /tmp/copy-out-setup -
echo copy-out-essential | cmp /tmp/copy-out-essential -
echo copy-out-customize | cmp /tmp/copy-out-customize -
echo upload-in-setup | cmp /tmp/download-in-setup -
echo upload-in-essential | cmp /tmp/download-in-essential -
echo upload-in-customize | cmp /tmp/download-in-customize -
# in fakechroot mode, we use a fake ldconfig, so we have to
# artificially add some files
{ tar -tf /tmp/debian-chroot.tar;
  [ "$mode" = "fakechroot" ] && printf "./etc/ld.so.cache\n./var/cache/ldconfig/\n";
  [ "$mode" = "fakechroot" ] && [ "$variant" != "essential" ] && printf "./etc/.pwd.lock\n";
} | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar \
	/tmp/copy-in-setup /tmp/copy-in-essential /tmp/copy-in-customize \
	/tmp/copy-out-setup /tmp/copy-out-essential /tmp/copy-out-customize \
	/tmp/tar-in-setup.tar /tmp/tar-in-essential.tar /tmp/tar-in-customize.tar \
	/tmp/tar-out-setup.tar /tmp/tar-out-essential.tar /tmp/tar-out-customize.tar \
	/tmp/upload-in-setup /tmp/upload-in-essential /tmp/upload-in-customize \
	/tmp/download-in-setup /tmp/download-in-essential /tmp/download-in-customize
END
	if [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
	elif [ "$mode" = "root" ]; then
		./run_null.sh SUDO
	else
		./run_null.sh
	fi
done

print_header "mode=root,variant=apt: debootstrap no-op options"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt --resolve-deps --merged-usr --no-merged-usr --force-check-gpg $DEFAULT_DIST /tmp/debian-chroot $mirror
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: --verbose"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt --verbose $DEFAULT_DIST /tmp/debian-chroot $mirror
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: --debug"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt --debug $DEFAULT_DIST /tmp/debian-chroot $mirror
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: --quiet"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt --quiet $DEFAULT_DIST /tmp/debian-chroot $mirror
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: --logfile"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt --logfile=log $DEFAULT_DIST /tmp/debian-chroot $mirror
grep --quiet "I: running apt-get update..." log
grep --quiet "I: downloading packages with apt..." log
grep --quiet "I: extracting archives..." log
grep --quiet "I: installing packages..." log
grep --quiet "I: cleaning package lists and apt cache..." log
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
rm log
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=$defaultmode,variant=apt: without /etc/resolv.conf and /etc/hostname"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
rm /etc/resolv.conf /etc/hostname
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
{ tar -tf /tmp/debian-chroot.tar;
  printf "./etc/hostname\n";
  printf "./etc/resolv.conf\n";
} | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

print_header "mode=$defaultmode,variant=essential: test not having to installing apt with --include"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=$defaultmode --variant=essential --include=apt --setup-hook="apt-get update" --setup-hook="apt-get --yes -oApt::Get::Download-Only=true install apt" $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

print_header "mode=$defaultmode,variant=apt: remove start-stop-daemon and policy-rc.d in hook"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=$defaultmode --variant=apt --customize-hook='rm "\$1/usr/sbin/policy-rc.d"; rm "\$1/sbin/start-stop-daemon"' $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
else
	./run_null.sh
fi

# test all variants

for variant in essential apt required minbase buildd important debootstrap - standard; do
	print_header "mode=root,variant=$variant: create directory"
	cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=$variant $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
tar -tf /tmp/debian-chroot.tar | sort > "$variant.txt"
rm /tmp/debian-chroot.tar
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
		case "$mode" in
			proot)
				case "$variant" in
					important|debootstrap|-|standard)
						# the systemd postint yields:
						# chfn: PAM: System error
						# adduser: `/usr/bin/chfn -f systemd Time Synchronization systemd-timesync' returned error code 1. Exiting.
						# similar error with fakechroot https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=745082#75
						# https://github.com/proot-me/PRoot/issues/156
						continue
						;;
				esac
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
export LC_ALL=C.UTF-8
[ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1 && adduser --gecos user --disabled-password user
[ "$mode" = unshare ] && sysctl -w kernel.unprivileged_userns_clone=1
prefix=
[ "\$(id -u)" -eq 0 ] && prefix="runuser -u user --"
\$prefix $CMD --mode=$mode --variant=$variant $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
# in fakechroot mode, we use a fake ldconfig, so we have to
# artificially add some files
{ tar -tf /tmp/debian-chroot.tar;
  [ "$mode" = "fakechroot" ] && printf "./etc/ld.so.cache\n./var/cache/ldconfig/\n";
  [ "$mode" = "fakechroot" ] && [ "$variant" != "essential" ] && printf "./etc/.pwd.lock\n";
} | sort | diff -u "./$variant.txt" -
rm /tmp/debian-chroot.tar
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
export LC_ALL=C.UTF-8
[ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1 && adduser --gecos user --disabled-password user
prefix=
[ "\$(id -u)" -eq 0 ] && prefix="runuser -u user --"
\$prefix fakechroot fakeroot $CMD --mode=$mode --variant=$variant $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
{ tar -tf /tmp/debian-chroot.tar;
  printf "./etc/ld.so.cache\n./var/cache/ldconfig/\n";
  [ "$variant" != "essential" ] && printf "./etc/.pwd.lock\n";
} | sort | diff -u "./$variant.txt" -
rm /tmp/debian-chroot.tar
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
export LC_ALL=C.UTF-8
[ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1 && adduser --gecos user --disabled-password user
[ "$mode" = unshare ] && sysctl -w kernel.unprivileged_userns_clone=1
prefix=
[ "\$(id -u)" -eq 0 ] && [ "$mode" != "root" ] && prefix="runuser -u user --"
[ "$mode" = "fakechroot" ] && prefix="\$prefix fakechroot fakeroot"
\$prefix $CMD --mode=$mode --variant=extract --include=doc-debian $DEFAULT_DIST /tmp/debian-chroot $mirror
# delete contents of doc-debian
rm /tmp/debian-chroot/usr/share/doc-base/debian-*
rm -r /tmp/debian-chroot/usr/share/doc/debian
rm -r /tmp/debian-chroot/usr/share/doc/doc-debian
# delete real files
rm /tmp/debian-chroot/etc/apt/sources.list
rm /tmp/debian-chroot/etc/fstab
rm /tmp/debian-chroot/etc/hostname
rm /tmp/debian-chroot/etc/resolv.conf
rm /tmp/debian-chroot/var/lib/dpkg/status
rm /tmp/debian-chroot/var/lib/dpkg/available
rm /tmp/debian-chroot/var/cache/apt/archives/lock
rm /tmp/debian-chroot/var/lib/dpkg/lock
rm /tmp/debian-chroot/var/lib/dpkg/lock-frontend
rm /tmp/debian-chroot/var/lib/dpkg/cmethopt
rm /tmp/debian-chroot/var/lib/apt/lists/lock
## delete merged usr symlinks
#rm /tmp/debian-chroot/libx32
#rm /tmp/debian-chroot/lib64
#rm /tmp/debian-chroot/lib32
#rm /tmp/debian-chroot/sbin
#rm /tmp/debian-chroot/bin
#rm /tmp/debian-chroot/lib
# delete ./dev (files might exist or not depending on the mode)
rm -f /tmp/debian-chroot/dev/console
rm -f /tmp/debian-chroot/dev/fd
rm -f /tmp/debian-chroot/dev/full
rm -f /tmp/debian-chroot/dev/null
rm -f /tmp/debian-chroot/dev/ptmx
rm -f /tmp/debian-chroot/dev/random
rm -f /tmp/debian-chroot/dev/stderr
rm -f /tmp/debian-chroot/dev/stdin
rm -f /tmp/debian-chroot/dev/stdout
rm -f /tmp/debian-chroot/dev/tty
rm -f /tmp/debian-chroot/dev/urandom
rm -f /tmp/debian-chroot/dev/zero
# the rest should be empty directories that we can rmdir recursively
find /tmp/debian-chroot -depth -print0 | xargs -0 rmdir
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
export LC_ALL=C.UTF-8
[ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1 && adduser --gecos user --disabled-password user
prefix=
[ "\$(id -u)" -eq 0 ] && prefix="runuser -u user --"
\$prefix $CMD --mode=chrootless --variant=custom --include=doc-debian $DEFAULT_DIST /tmp/debian-chroot $mirror
# preserve output with permissions and timestamps for later test
chmod 700 /tmp/debian-chroot
tar -C /tmp/debian-chroot --owner=0 --group=0 --numeric-owner --sort=name --clamp-mtime --mtime=$(date --utc --date=@$SOURCE_DATE_EPOCH --iso-8601=seconds) -cf /tmp/debian-chroot.tar .
tar tvf /tmp/debian-chroot.tar > doc-debian.tar.list
rm /tmp/debian-chroot.tar
# delete contents of doc-debian
rm /tmp/debian-chroot/usr/share/doc-base/debian-*
rm -r /tmp/debian-chroot/usr/share/doc/debian
rm -r /tmp/debian-chroot/usr/share/doc/doc-debian
# delete real files
rm /tmp/debian-chroot/etc/apt/sources.list
rm /tmp/debian-chroot/etc/fstab
rm /tmp/debian-chroot/etc/hostname
rm /tmp/debian-chroot/etc/resolv.conf
rm /tmp/debian-chroot/var/lib/dpkg/status
rm /tmp/debian-chroot/var/lib/dpkg/available
rm /tmp/debian-chroot/var/cache/apt/archives/lock
rm /tmp/debian-chroot/var/lib/dpkg/lock
rm /tmp/debian-chroot/var/lib/dpkg/lock-frontend
rm /tmp/debian-chroot/var/lib/dpkg/cmethopt
rm /tmp/debian-chroot/var/lib/apt/lists/lock
rm /tmp/debian-chroot/var/lib/apt/extended_states
## delete merged usr symlinks
#rm /tmp/debian-chroot/libx32
#rm /tmp/debian-chroot/lib64
#rm /tmp/debian-chroot/lib32
#rm /tmp/debian-chroot/sbin
#rm /tmp/debian-chroot/bin
#rm /tmp/debian-chroot/lib
# in chrootless mode, there is more to remove
rm /tmp/debian-chroot/var/lib/dpkg/triggers/Lock
rm /tmp/debian-chroot/var/lib/dpkg/triggers/Unincorp
rm /tmp/debian-chroot/var/lib/dpkg/status-old
rm /tmp/debian-chroot/var/lib/dpkg/info/format
rm /tmp/debian-chroot/var/lib/dpkg/info/doc-debian.md5sums
rm /tmp/debian-chroot/var/lib/dpkg/info/doc-debian.list
# the rest should be empty directories that we can rmdir recursively
find /tmp/debian-chroot -depth -print0 | xargs -0 rmdir
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh
fi

print_header "mode=chrootless,variant=custom: install doc-debian and output tarball"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
export SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
[ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1 && adduser --gecos user --disabled-password user
prefix=
[ "\$(id -u)" -eq 0 ] && prefix="runuser -u user --"
\$prefix $CMD --mode=chrootless --variant=custom --include=doc-debian $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
tar tvf /tmp/debian-chroot.tar | grep -v ' ./dev' | diff -u doc-debian.tar.list -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh
fi

print_header "mode=chrootless,variant=custom: install doc-debian and test hooks"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
export SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
[ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1 && adduser --gecos user --disabled-password user
prefix=
[ "\$(id -u)" -eq 0 ] && prefix="runuser -u user --"
\$prefix $CMD --mode=chrootless --variant=custom --include=doc-debian --setup-hook='touch "\$1/setup"' --customize-hook='touch "\$1/customize"' $DEFAULT_DIST /tmp/debian-chroot $mirror
rm /tmp/debian-chroot/setup
rm /tmp/debian-chroot/customize
chmod 700 /tmp/debian-chroot
tar -C /tmp/debian-chroot --owner=0 --group=0 --numeric-owner --sort=name --clamp-mtime --mtime=$(date --utc --date=@$SOURCE_DATE_EPOCH --iso-8601=seconds) -cf /tmp/debian-chroot.tar .
tar tvf /tmp/debian-chroot.tar | grep -v ' ./dev' | diff -u doc-debian.tar.list -
rm /tmp/debian-chroot.tar
# delete contents of doc-debian
rm /tmp/debian-chroot/usr/share/doc-base/debian-*
rm -r /tmp/debian-chroot/usr/share/doc/debian
rm -r /tmp/debian-chroot/usr/share/doc/doc-debian
# delete real files
rm /tmp/debian-chroot/etc/apt/sources.list
rm /tmp/debian-chroot/etc/fstab
rm /tmp/debian-chroot/etc/hostname
rm /tmp/debian-chroot/etc/resolv.conf
rm /tmp/debian-chroot/var/lib/dpkg/status
rm /tmp/debian-chroot/var/lib/dpkg/available
rm /tmp/debian-chroot/var/cache/apt/archives/lock
rm /tmp/debian-chroot/var/lib/dpkg/lock
rm /tmp/debian-chroot/var/lib/dpkg/lock-frontend
rm /tmp/debian-chroot/var/lib/dpkg/cmethopt
rm /tmp/debian-chroot/var/lib/apt/lists/lock
rm /tmp/debian-chroot/var/lib/apt/extended_states
## delete merged usr symlinks
#rm /tmp/debian-chroot/libx32
#rm /tmp/debian-chroot/lib64
#rm /tmp/debian-chroot/lib32
#rm /tmp/debian-chroot/sbin
#rm /tmp/debian-chroot/bin
#rm /tmp/debian-chroot/lib
# in chrootless mode, there is more to remove
rm /tmp/debian-chroot/var/lib/dpkg/triggers/Lock
rm /tmp/debian-chroot/var/lib/dpkg/triggers/Unincorp
rm /tmp/debian-chroot/var/lib/dpkg/status-old
rm /tmp/debian-chroot/var/lib/dpkg/info/format
rm /tmp/debian-chroot/var/lib/dpkg/info/doc-debian.md5sums
rm /tmp/debian-chroot/var/lib/dpkg/info/doc-debian.list
# the rest should be empty directories that we can rmdir recursively
find /tmp/debian-chroot -depth -print0 | xargs -0 rmdir
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh
fi

print_header "mode=chrootless,variant=custom: install libmagic-mgc on armhf"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
[ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1 && adduser --gecos user --disabled-password user
prefix=
[ "\$(id -u)" -eq 0 ] && prefix="runuser -u user --"
\$prefix $CMD --mode=chrootless --variant=custom --architectures=armhf --include=libmagic-mgc $DEFAULT_DIST /tmp/debian-chroot $mirror
# delete contents of libmagic-mgc
rm /tmp/debian-chroot/usr/lib/file/magic.mgc
rm /tmp/debian-chroot/usr/share/doc/libmagic-mgc/README.Debian
rm /tmp/debian-chroot/usr/share/doc/libmagic-mgc/changelog.Debian.gz
rm /tmp/debian-chroot/usr/share/doc/libmagic-mgc/changelog.gz
rm /tmp/debian-chroot/usr/share/doc/libmagic-mgc/copyright
rm /tmp/debian-chroot/usr/share/file/magic.mgc
rm /tmp/debian-chroot/usr/share/misc/magic.mgc
# delete real files
rm /tmp/debian-chroot/etc/apt/sources.list
rm /tmp/debian-chroot/etc/fstab
rm /tmp/debian-chroot/etc/hostname
rm /tmp/debian-chroot/etc/resolv.conf
rm /tmp/debian-chroot/var/lib/dpkg/status
rm /tmp/debian-chroot/var/lib/dpkg/available
rm /tmp/debian-chroot/var/cache/apt/archives/lock
rm /tmp/debian-chroot/var/lib/dpkg/lock
rm /tmp/debian-chroot/var/lib/dpkg/lock-frontend
rm /tmp/debian-chroot/var/lib/dpkg/cmethopt
rm /tmp/debian-chroot/var/lib/apt/lists/lock
rm /tmp/debian-chroot/var/lib/apt/extended_states
## delete merged usr symlinks
#rm /tmp/debian-chroot/libx32
#rm /tmp/debian-chroot/lib64
#rm /tmp/debian-chroot/lib32
#rm /tmp/debian-chroot/sbin
#rm /tmp/debian-chroot/bin
#rm /tmp/debian-chroot/lib
# in chrootless mode, there is more to remove
rm /tmp/debian-chroot/var/lib/dpkg/arch
rm /tmp/debian-chroot/var/lib/dpkg/triggers/Lock
rm /tmp/debian-chroot/var/lib/dpkg/triggers/Unincorp
rm /tmp/debian-chroot/var/lib/dpkg/status-old
rm /tmp/debian-chroot/var/lib/dpkg/info/format
rm /tmp/debian-chroot/var/lib/dpkg/info/libmagic-mgc.md5sums
rm /tmp/debian-chroot/var/lib/dpkg/info/libmagic-mgc.list
# the rest should be empty directories that we can rmdir recursively
find /tmp/debian-chroot -depth -print0 | xargs -0 rmdir
END
if [ "$HAVE_BINFMT" = "yes" ]; then
	if [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
	else
		./run_null.sh
	fi
else
	echo "HAVE_BINFMT != yes -- Skipping test..."
fi

print_header "mode=root,variant=custom: install busybox-based sub-essential system"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=custom \
    --include=dpkg,busybox,libc-bin,base-files,base-passwd,debianutils \
    --setup-hook='mkdir -p "\$1/bin"' \
    --setup-hook='for p in awk cat chmod chown cp diff echo env grep less ln mkdir mount rm rmdir sed sh sleep sort touch uname; do ln -s busybox "\$1/bin/\$p"; done' \
    --setup-hook='echo root:x:0:0:root:/root:/bin/sh > "\$1/etc/passwd"' \
    --setup-hook='printf "root:x:0:\nmail:x:8:\nutmp:x:43:\n" > "\$1/etc/group"' \
    $DEFAULT_DIST /tmp/debian-chroot $mirror
cat << FILE > expected
base-files
base-passwd
busybox
debianutils
dpkg
gcc-9-base:amd64
libacl1:amd64
libbz2-1.0:amd64
libc-bin
libc6:amd64
libdebconfclient0:amd64
libgcc1:amd64
liblzma5:amd64
libpcre2-8-0:amd64
libselinux1:amd64
mawk
tar
zlib1g:amd64
FILE
chroot /tmp/debian-chroot dpkg-query -f '\${binary:Package}\n' -W | diff -u - expected
rm expected
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

# test foreign architecture with all modes
# create directory in sudo mode

for mode in root unshare fakechroot proot; do
	print_header "mode=$mode,variant=apt: create armhf tarball"
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
export LC_ALL=C.UTF-8
[ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1 && adduser --gecos user --disabled-password user
[ "$mode" = unshare ] && sysctl -w kernel.unprivileged_userns_clone=1
prefix=
[ "\$(id -u)" -eq 0 ] && [ "$mode" != "root" ] && prefix="runuser -u user --"
[ "$mode" = "fakechroot" ] && prefix="\$prefix fakechroot fakeroot"
\$prefix $CMD --mode=$mode --variant=apt --architectures=armhf $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
# we ignore differences between architectures by ignoring some files
# and renaming others
# in fakechroot mode, we use a fake ldconfig, so we have to
# artificially add some files
# in proot mode, some extra files are put there by proot
{ tar -tf /tmp/debian-chroot.tar \
	| grep -v '^\./lib/ld-linux-armhf\.so\.3$' \
	| grep -v '^\./lib/arm-linux-gnueabihf/ld-linux\.so\.3$' \
	| grep -v '^\./lib/arm-linux-gnueabihf/ld-linux-armhf\.so\.3$' \
	| grep -v '^\./usr/share/doc/[^/]\+/changelog\(\.Debian\)\?\.armhf\.gz$' \
	| sed 's/arm-linux-gnueabihf/x86_64-linux-gnu/' \
	| sed 's/armhf/amd64/';
	[ "$mode" = "fakechroot" ] && printf "./etc/ld.so.cache\n./var/cache/ldconfig/\n./etc/.pwd.lock\n";
} | sort > tar2.txt
{ cat tar1.txt \
	| grep -v '^\./usr/bin/i386$' \
	| grep -v '^\./usr/bin/x86_64$' \
	| grep -v '^\./lib64/$' \
	| grep -v '^\./lib64/ld-linux-x86-64\.so\.2$' \
	| grep -v '^\./lib/x86_64-linux-gnu/ld-linux-x86-64\.so\.2$' \
	| grep -v '^\./lib/x86_64-linux-gnu/libmvec-2\.[0-9]\+\.so$' \
	| grep -v '^\./lib/x86_64-linux-gnu/libmvec\.so\.1$' \
	| grep -v '^\./usr/share/doc/[^/]\+/changelog\(\.Debian\)\?\.amd64\.gz$' \
	| grep -v '^\./usr/share/man/man8/i386\.8\.gz$' \
	| grep -v '^\./usr/share/man/man8/x86_64\.8\.gz$';
	[ "$mode" = "proot" ] && printf "./etc/ld.so.preload\n";
} | sort | diff -u - tar2.txt
rm /tmp/debian-chroot.tar
END
	if [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
	elif [ "$mode" = "root" ]; then
		./run_null.sh SUDO
	else
		./run_null.sh
	fi
done

if [ "$((i-1))" -ne "$total" ]; then
	echo unexpected number of tests: got $((i-1)) but expected $total
	exit 1
fi

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

rm shared/tar1.txt shared/tar2.txt shared/pkglist.txt shared/doc-debian.tar.list
