#!/bin/sh

set -eu

mirrordir="./shared/cache/debian"

./make_mirror.sh

# we use -f because the file might not exist
rm -f shared/cover_db.img

: "${HAVE_QEMU:=yes}"

if [ "$HAVE_QEMU" = "yes" ]; then
	# prepare image for cover_db
	guestfish -N shared/cover_db.img=disk:100M -- mkfs vfat /dev/sda

	if [ ! -e "./shared/cache/debian-unstable.qcow" ]; then
		echo "./shared/cache/debian-unstable.qcow does not exist" >&2
		exit 1
	fi
fi

# check if all required debootstrap tarballs exist
notfound=0
for dist in stable testing unstable; do
	for variant in minbase buildd -; do
		# skip because of different userids for apt/systemd
		if [ "$dist" = 'stable' ] && [ "$variant" = '-' ]; then
			continue
		fi
		# skip because of #917386 and #917407
		if [ "$dist" = 'unstable' -o "$dist" = 'testing' ] && [ "$variant" = '-' ]; then
			continue
		fi

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
		# skip because of different userids for apt/systemd
		if [ "$dist" = 'stable' ] && [ "$variant" = '-' ]; then
			continue
		fi
		# skip because of #917386 and #917407
		if [ "$dist" = 'unstable' -o "$dist" = 'testing' ] && [ "$variant" = '-' ]; then
			continue
		fi
		print_header "mode=root,variant=$variant: check against debootstrap $dist"

		cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
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
		else
			./run_null.sh SUDO
		fi
	done
done

print_header "mode=root,variant=apt: create directory"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
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
export LC_ALL=C.UTF-8
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
export LC_ALL=C.UTF-8
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

print_header "mode=root,variant=apt: existing directory with lost+found"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
mkdir /tmp/debian-unstable
mkdir /tmp/debian-unstable/lost+found
$CMD --mode=root --variant=apt unstable /tmp/debian-unstable $mirror
rmdir /tmp/debian-unstable/lost+found
tar -C /tmp/debian-unstable --one-file-system -c . | tar -t | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm -r /tmp/debian-unstable
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
runuser -u user -- $CMD --mode=unshare --variant=apt unstable /tmp/unstable-chroot.tar.gz $mirror
tar -tf /tmp/unstable-chroot.tar.gz | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm /tmp/unstable-chroot.tar.gz
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	echo "HAVE_QEMU != yes -- Skipping test..."
fi

print_header "mode=root,variant=apt: create tarball with /tmp mounted nodev"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
mount -t tmpfs -o nodev,nosuid,size=300M tmpfs /tmp
# use --customize-hook to exercise the mounting/unmounting code of block devices in root mode
$CMD --mode=root --variant=apt --customize-hook='mount | grep /dev/full' --customize-hook='test "\$(echo foo | tee /dev/full 2>&1 1>/dev/null)" = "tee: /dev/full: No space left on device"' unstable /tmp/unstable-chroot.tar $mirror
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
export LC_ALL=C.UTF-8
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
$CMD --mode=root --variant=apt stable /tmp/debian-unstable
cat << SOURCES | cmp /tmp/debian-unstable/etc/apt/sources.list
deb http://deb.debian.org/debian stable main
deb http://deb.debian.org/debian stable-updates main
deb http://security.debian.org/debian-security stable/updates main
SOURCES
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=auto,variant=apt: pass distribution but implicitly write to stdout"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
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
export LC_ALL=C.UTF-8
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
export LC_ALL=C.UTF-8
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
export LC_ALL=C.UTF-8
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
export LC_ALL=C.UTF-8
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

print_header "mode=root,variant=apt: test --include=libc6:armhf"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt --architectures=amd64,armhf --include=gcc-8-base:armhf unstable /tmp/debian-unstable $mirror
{ echo "amd64"; echo "armhf"; } | cmp /tmp/debian-unstable/var/lib/dpkg/arch -
rm /tmp/debian-unstable/var/lib/dpkg/arch
rm /tmp/debian-unstable/var/log/apt/eipp.log.xz
rm /tmp/debian-unstable/var/lib/dpkg/info/gcc-8-base:armhf.list
rm /tmp/debian-unstable/var/lib/dpkg/info/gcc-8-base:armhf.md5sums
rm /tmp/debian-unstable/usr/share/doc/gcc-8-base/README.Debian.armhf.gz
rmdir /tmp/debian-unstable/usr/lib/gcc/arm-linux-gnueabihf/8/
rmdir /tmp/debian-unstable/usr/lib/gcc/arm-linux-gnueabihf/
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
export LC_ALL=C.UTF-8
echo 'Acquire::Languages "none";' > config
$CMD --mode=root --variant=apt --aptopt='Acquire::Check-Valid-Until "false"' --aptopt=config unstable /tmp/debian-unstable $mirror
printf 'Acquire::Check-Valid-Until "false";\nAcquire::Languages "none";\n' | cmp /tmp/debian-unstable/etc/apt/apt.conf.d/99mmdebstrap -
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
export LC_ALL=C.UTF-8
echo no-pager > config
$CMD --mode=root --variant=apt --dpkgopt="path-exclude=/usr/share/doc/*" --dpkgopt=config unstable /tmp/debian-unstable $mirror
printf 'path-exclude=/usr/share/doc/*\nno-pager\n' | cmp /tmp/debian-unstable/etc/dpkg/dpkg.cfg.d/99mmdebstrap -
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
export LC_ALL=C.UTF-8
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
$CMD --mode=root --variant=apt --setup-hook='ln -s usr/bin "\$1/bin"; mkdir -p "\$1/usr/bin"' --setup-hook=./customize.sh unstable /tmp/debian-unstable $mirror
tar -C /tmp/debian-unstable --one-file-system -c . | tar -t | sort > tar2.txt
{ sed -e 's/^\.\/bin\//.\/usr\/bin\//;s/^\.\/lib\//.\/usr\/lib\//;s/^\.\/sbin\//.\/usr\/sbin\//;' tar1.txt; echo ./bin; echo ./lib; echo ./sbin; } | sort -u | diff -u - tar2.txt
rm customize.sh
rm -r /tmp/debian-unstable
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
$CMD --mode=root --variant=apt --include=tzdata --essential-hook='echo tzdata tzdata/Areas select Europe | chroot "\$1" debconf-set-selections' --essential-hook=./customize.sh unstable /tmp/debian-unstable $mirror
echo Europe/Berlin | cmp /tmp/debian-unstable/etc/timezone
tar -C /tmp/debian-unstable --one-file-system -c . | tar -t | sort \
	| grep -v '^./etc/localtime' \
	| grep -v '^./etc/timezone' \
	| grep -v '^./usr/sbin/tzconfig' \
	| grep -v '^./usr/share/doc/tzdata' \
	| grep -v '^./usr/share/zoneinfo' \
	| grep -v '^./var/lib/dpkg/info/tzdata.' \
	| grep -v '^./var/log/apt/eipp.log.xz$' \
	> tar2.txt
diff -u tar1.txt tar2.txt
rm customize.sh
rm -r /tmp/debian-unstable
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
$CMD --mode=root --variant=apt --customize-hook='chroot "\$1" sh -c "whoami; pwd" > "\$1/output1"' --customize-hook=./customize.sh unstable /tmp/debian-unstable $mirror
printf "root\n/\n" | cmp /tmp/debian-unstable/output1
printf "root\n/\n" | cmp /tmp/debian-unstable/output2
rm /tmp/debian-unstable/output1
rm /tmp/debian-unstable/output2
tar -C /tmp/debian-unstable --one-file-system -c . | tar -t | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm customize.sh
rm -r /tmp/debian-unstable
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
else
	./run_null.sh SUDO
fi

print_header "mode=root,variant=apt: debootstrap no-op options"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt --resolve-deps --merged-usr --no-merged-usr unstable /tmp/debian-unstable $mirror
tar -C /tmp/debian-unstable --one-file-system -c . | tar -t | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm -r /tmp/debian-unstable
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
$CMD --mode=root --variant=apt --verbose unstable /tmp/debian-unstable $mirror
tar -C /tmp/debian-unstable --one-file-system -c . | tar -t | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm -r /tmp/debian-unstable
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
$CMD --mode=root --variant=apt --debug unstable /tmp/debian-unstable $mirror
tar -C /tmp/debian-unstable --one-file-system -c . | tar -t | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm -r /tmp/debian-unstable
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
$CMD --mode=root --variant=apt --quiet unstable /tmp/debian-unstable $mirror
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
export LC_ALL=C.UTF-8
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
export LC_ALL=C.UTF-8
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
export LC_ALL=C.UTF-8
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
rm /tmp/debian-unstable/var/lib/dpkg/available
## delete merged usr symlinks
#rm /tmp/debian-unstable/libx32
#rm /tmp/debian-unstable/lib64
#rm /tmp/debian-unstable/lib32
#rm /tmp/debian-unstable/sbin
#rm /tmp/debian-unstable/bin
#rm /tmp/debian-unstable/lib
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
export LC_ALL=C.UTF-8
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
rm /tmp/debian-unstable/var/lib/dpkg/available
## delete merged usr symlinks
#rm /tmp/debian-unstable/libx32
#rm /tmp/debian-unstable/lib64
#rm /tmp/debian-unstable/lib32
#rm /tmp/debian-unstable/sbin
#rm /tmp/debian-unstable/bin
#rm /tmp/debian-unstable/lib
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
\$prefix $CMD --mode=$mode --variant=apt --architectures=armhf unstable /tmp/unstable-chroot.tar $mirror
# we ignore differences between architectures by ignoring some files
# and renaming others
# in fakechroot mode, we use a fake ldconfig, so we have to
# artificially add some files
# in proot mode, some extra files are put there by proot
{ tar -tf /tmp/unstable-chroot.tar \
	| grep -v '^\./lib/ld-linux-armhf\.so\.3$' \
	| grep -v '^\./lib/arm-linux-gnueabihf/ld-linux\.so\.3$' \
	| grep -v '^\./lib/arm-linux-gnueabihf/ld-linux-armhf\.so\.3$' \
	| sed 's/arm-linux-gnueabihf/x86_64-linux-gnu/' \
	| sed 's/armhf/amd64/';
	[ "$mode" = "fakechroot" ] && printf "./etc/ld.so.cache\n./var/cache/ldconfig/\n";
} | sort > tar2.txt
{ cat tar1.txt \
	| grep -v '^\./usr/bin/i386$' \
	| grep -v '^\./usr/bin/x86_64$' \
	| grep -v '^\./lib64/$' \
	| grep -v '^\./lib64/ld-linux-x86-64\.so\.2$' \
	| grep -v '^\./lib/x86_64-linux-gnu/ld-linux-x86-64\.so\.2$' \
	| grep -v '^\./lib/x86_64-linux-gnu/libmvec-2\.[0-9]\+\.so$' \
	| grep -v '^\./lib/x86_64-linux-gnu/libmvec\.so\.1$' \
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
