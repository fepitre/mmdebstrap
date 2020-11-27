#!/bin/sh

set -eu

if [ -e ./mmdebstrap -a -e ./taridshift -a -e ./tarfilter ]; then
	TMPFILE=$(mktemp)
	perltidy < ./mmdebstrap > "$TMPFILE"
	ret=0
	diff -u ./mmdebstrap "$TMPFILE" || ret=$?
	if [ "$ret" -ne 0 ]; then
		echo "perltidy failed" >&2
		rm "$TMPFILE"
		exit 1
	fi
	rm "$TMPFILE"

	if [ $(sed -e '/^__END__$/,$d' ./mmdebstrap | wc --max-line-length) -gt 79 ]; then
		echo "exceeded maximum line length of 79 characters" >&2
		exit 1
	fi

	perlcritic --severity 4 --verbose 8 ./mmdebstrap

	black --check ./taridshift ./tarfilter
fi

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
: "${ONLINE:=no}"

HOSTARCH=$(dpkg --print-architecture)

if [ "$HAVE_QEMU" = "yes" ]; then
	# prepare image for cover_db
	guestfish -N shared/cover_db.img=disk:64M -- mkfs vfat /dev/sda

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
	if [ -e ./mmdebstrap ]; then
		cp -a mmdebstrap shared
	else
		cp -a /usr/bin/mmdebstrap shared
	fi
fi
if [ ! -e shared/taridshift ] || [ taridshift -nt shared/taridshift ]; then
	if [ -e ./taridshift ]; then
		cp -a ./taridshift shared
	else
		cp -a /usr/bin/mmtaridshift shared/taridshift
	fi
fi
if [ ! -e shared/tarfilter ] || [ tarfilter -nt shared/tarfilter ]; then
	if [ -e ./tarfilter ]; then
		cp -a tarfilter shared
	else
		cp -a /usr/bin/mmtarfilter shared/tarfilter
	fi
fi
mkdir -p shared/hooks
if [ ! -e shared/hooks/setup00-merged-usr.sh ] || [ hooks/setup00-merged-usr.sh -nt shared/hooks/setup00-merged-usr.sh ]; then
	if [ -e hooks/setup00-merged-usr.sh ]; then
		cp -a hooks/setup00-merged-usr.sh shared/hooks/
	else
		cp -a /usr/share/mmdebstrap/hooks/setup00-merged-usr.sh shared/hooks/
	fi
fi
mkdir -p shared/hooks/eatmydata
if [ ! -e shared/hooks/eatmydata/extract.sh ] || [ hooks/eatmydata/extract.sh -nt shared/hooks/eatmydata/extract.sh ]; then
	if [ -e hooks/eatmydata/extract.sh ]; then
		cp -a hooks/eatmydata/extract.sh shared/hooks/eatmydata/
	else
		cp -a /usr/share/mmdebstrap/hooks/eatmydata/extract.sh shared/hooks/eatmydata/
	fi
fi
if [ ! -e shared/hooks/eatmydata/customize.sh ] || [ hooks/eatmydata/customize.sh -nt shared/hooks/eatmydata/customize.sh ]; then
	if [ -e hooks/eatmydata/customize.sh ]; then
		cp -a hooks/eatmydata/customize.sh shared/hooks/eatmydata/
	else
		cp -a /usr/share/mmdebstrap/hooks/eatmydata/customize.sh shared/hooks/eatmydata/
	fi
fi

starttime=
total=164
skipped=0
runtests=0
i=1

print_header() {
	echo ------------------------------------------------------------------------------ >&2
	echo "($i/$total) $1" >&2
	if [ -z "$starttime" ]; then
		starttime=$(date +%s)
	else
		currenttime=$(date +%s)
		timeleft=$(((total-i+1)*(currenttime-starttime)/(i-1)))
		printf "time left: %02d:%02d:%02d\n" $((timeleft/3600)) $(((timeleft%3600)/60)) $((timeleft%60))
	fi
	echo ------------------------------------------------------------------------------ >&2
	i=$((i+1))
}

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
		if [ $dist != stable ] && [ $variant = - ]; then
			echo "skipping test because of #963788" >&2
			skipped=$((skipped+1))
			continue
		fi
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
		exit 1
	else
		echo "no diffoscope installed" >&2
	fi
	if type base64 >/dev/null; then
		base64 dev1.tar
		base64 dev2.tar
		exit 1
	else
		echo "no base64 installed" >&2
	fi
	if type xxd >/dev/null; then
		xxd dev1.tar
		xxd dev2.tar
		exit 1
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
if [ -e /tmp/debian-$dist-debootstrap/etc/apt/apt.conf.d/01autoremove-kernels ]; then
	rm /tmp/debian-$dist-debootstrap/etc/apt/apt.conf.d/01autoremove-kernels
fi
if [ -e /tmp/debian-$dist-mm/etc/apt/apt.conf.d/01autoremove-kernels ]; then
	rm /tmp/debian-$dist-mm/etc/apt/apt.conf.d/01autoremove-kernels
fi
# who creates /run/mount?
if [ -e "/tmp/debian-$dist-debootstrap/run/mount/utab" ]; then
	rm "/tmp/debian-$dist-debootstrap/run/mount/utab"
fi
if [ -e "/tmp/debian-$dist-debootstrap/run/mount" ]; then
	rmdir "/tmp/debian-$dist-debootstrap/run/mount"
fi
# debootstrap doesn't clean apt
rm /tmp/debian-$dist-debootstrap/var/lib/apt/lists/127.0.0.1_debian_dists_${dist}_main_binary-${HOSTARCH}_Packages \
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
		echo "but debootstrap produced: \$cap" >&2
		exit 1
	fi
	cap=\$(chroot /tmp/debian-$dist-mm /sbin/getcap /bin/ping)
	if [ "\$cap" != "/bin/ping = cap_net_raw+ep" ]; then
		echo "expected bin/ping to have capabilities cap_net_raw+ep" >&2
		echo "but mmdebstrap produced: \$cap" >&2
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
if ! cmp /tmp/debian-$dist-debootstrap/etc/shadow /tmp/debian-$dist-mm/etc/shadow; then
	echo patching /etc/shadow on $dist $variant >&2
	awk -v FS=: -v OFS=: -v SDE=\$SOURCE_DATE_EPOCH '{ print \$1,\$2,int(SDE/60/60/24),\$4,\$5,\$6,\$7,\$8,\$9 }' < /tmp/debian-$dist-mm/etc/shadow > /tmp/debian-$dist-mm/etc/shadow.bak
	cat /tmp/debian-$dist-mm/etc/shadow.bak > /tmp/debian-$dist-mm/etc/shadow
	rm /tmp/debian-$dist-mm/etc/shadow.bak
else
	echo no difference for /etc/shadow on $dist $variant >&2
fi
if ! cmp /tmp/debian-$dist-debootstrap/etc/shadow- /tmp/debian-$dist-mm/etc/shadow-; then
	echo patching /etc/shadow- on $dist $variant >&2
	awk -v FS=: -v OFS=: -v SDE=\$SOURCE_DATE_EPOCH '{ print \$1,\$2,int(SDE/60/60/24),\$4,\$5,\$6,\$7,\$8,\$9 }' < /tmp/debian-$dist-mm/etc/shadow- > /tmp/debian-$dist-mm/etc/shadow-.bak
	cat /tmp/debian-$dist-mm/etc/shadow-.bak > /tmp/debian-$dist-mm/etc/shadow-
	rm /tmp/debian-$dist-mm/etc/shadow-.bak
else
	echo no difference for /etc/shadow- on $dist $variant >&2
fi

# check if the file content differs
diff --unified --no-dereference --recursive /tmp/debian-$dist-debootstrap /tmp/debian-$dist-mm

# check permissions, ownership, symlink targets, modification times using tar
# directory mtimes will differ, thus we equalize them first
find /tmp/debian-$dist-debootstrap /tmp/debian-$dist-mm -type d -print0 | xargs -0 touch --date="@$SOURCE_DATE_EPOCH"
# debootstrap never ran apt -- fixing permissions
for d in ./var/lib/apt/lists/partial ./var/cache/apt/archives/partial; do
	chroot /tmp/debian-$dist-debootstrap chmod 0700 \$d
	chroot /tmp/debian-$dist-debootstrap chown _apt:root \$d
done
tar -C /tmp/debian-$dist-debootstrap --numeric-owner --sort=name --clamp-mtime --mtime=$(date --utc --date=@$SOURCE_DATE_EPOCH --iso-8601=seconds) -cf /tmp/root1.tar .
tar -C /tmp/debian-$dist-mm --numeric-owner --sort=name --clamp-mtime --mtime=$(date --utc --date=@$SOURCE_DATE_EPOCH --iso-8601=seconds) -cf /tmp/root2.tar .
tar --full-time --verbose -tf /tmp/root1.tar > /tmp/root1.tar.list
tar --full-time --verbose -tf /tmp/root2.tar > /tmp/root2.tar.list
diff -u /tmp/root1.tar.list /tmp/root2.tar.list
rm /tmp/root1.tar /tmp/root2.tar /tmp/root1.tar.list /tmp/root2.tar.list

# check if file properties (permissions, ownership, symlink names, modification time) differ
#
# we cannot use this (yet) because it cannot cope with paths that have [ or @ in them
#fmtree -c -p /tmp/debian-$dist-debootstrap -k flags,gid,link,mode,size,time,uid | sudo fmtree -p /tmp/debian-$dist-mm

rm /tmp/debian-$dist-mm.tar
rm -r /tmp/debian-$dist-debootstrap /tmp/debian-$dist-mm
END
		if [ "$HAVE_QEMU" = "yes" ]; then
			./run_qemu.sh
			runtests=$((runtests+1))
		elif [ "$defaultmode" = "root" ]; then
			./run_null.sh SUDO
			runtests=$((runtests+1))
		else
			./run_null.sh
			runtests=$((runtests+1))
		fi
	done
done

# this is a solution for https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=829134
print_header "mode=unshare,variant=custom: as debootstrap unshare wrapper"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
export SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test modifies the system and should only be run inside a container" >&2
	exit 1
fi
sysctl -w kernel.unprivileged_userns_clone=1
adduser --gecos user --disabled-password user
runuser -u user -- $CMD --variant=custom --mode=unshare --setup-hook='env container=lxc debootstrap --no-merged-usr unstable "\$1" $mirror' - /tmp/debian-mm.tar $mirror

mkdir /tmp/debian-mm
tar --xattrs --xattrs-include='*' -C /tmp/debian-mm -xf /tmp/debian-mm.tar

mkdir /tmp/debian-debootstrap
tar --xattrs --xattrs-include='*' -C /tmp/debian-debootstrap -xf "cache/debian-unstable--.tar"

# diff cannot compare device nodes, so we use tar to do that for us and then
# delete the directory
tar -C /tmp/debian-debootstrap -cf dev1.tar ./dev
tar -C /tmp/debian-mm -cf dev2.tar ./dev
cmp dev1.tar dev2.tar
rm dev1.tar dev2.tar
rm -r /tmp/debian-debootstrap/dev /tmp/debian-mm/dev

# remove downloaded deb packages
rm /tmp/debian-debootstrap/var/cache/apt/archives/*.deb
# remove aux-cache
rm /tmp/debian-debootstrap/var/cache/ldconfig/aux-cache
# remove logs
rm /tmp/debian-debootstrap/var/log/dpkg.log \
	/tmp/debian-debootstrap/var/log/bootstrap.log \
	/tmp/debian-debootstrap/var/log/alternatives.log \
	/tmp/debian-mm/var/log/bootstrap.log

# debootstrap doesn't clean apt
rm /tmp/debian-debootstrap/var/lib/apt/lists/127.0.0.1_debian_dists_unstable_main_binary-${HOSTARCH}_Packages \
	/tmp/debian-debootstrap/var/lib/apt/lists/127.0.0.1_debian_dists_unstable_Release \
	/tmp/debian-debootstrap/var/lib/apt/lists/127.0.0.1_debian_dists_unstable_Release.gpg

rm /tmp/debian-debootstrap/etc/machine-id /tmp/debian-mm/etc/machine-id
rm /tmp/debian-mm/var/cache/apt/archives/lock
rm /tmp/debian-mm/var/lib/apt/lists/lock

# check if the file content differs
diff --no-dereference --recursive /tmp/debian-debootstrap /tmp/debian-mm

# check permissions, ownership, symlink targets, modification times using tar
# mtimes of directories created by mmdebstrap will differ, thus we equalize them first
for d in etc/apt/preferences.d/ etc/apt/sources.list.d/ etc/dpkg/dpkg.cfg.d/; do
	touch --date="@$SOURCE_DATE_EPOCH" /tmp/debian-debootstrap/\$d /tmp/debian-mm/\$d
done
# debootstrap never ran apt -- fixing permissions
for d in ./var/lib/apt/lists/partial ./var/cache/apt/archives/partial; do
	chroot /tmp/debian-debootstrap chmod 0700 \$d
	chroot /tmp/debian-debootstrap chown _apt:root \$d
done
tar -C /tmp/debian-debootstrap --numeric-owner --xattrs --xattrs-include='*' --sort=name --clamp-mtime --mtime=$(date --utc --date=@$SOURCE_DATE_EPOCH --iso-8601=seconds) -cf /tmp/root1.tar .
tar -C /tmp/debian-mm --numeric-owner --xattrs --xattrs-include='*' --sort=name --clamp-mtime --mtime=$(date --utc --date=@$SOURCE_DATE_EPOCH --iso-8601=seconds) -cf /tmp/root2.tar .
tar --full-time --verbose -tf /tmp/root1.tar > /tmp/root1.tar.list
tar --full-time --verbose -tf /tmp/root2.tar > /tmp/root2.tar.list
# despite SOURCE_DATE_EPOCH and --clamp-mtime, the timestamps in the tarball
# will slightly differ from each other in the sub-second precision (last
# decimals) so the tarballs will not be identical, so we use diff to compare
# content and tar to compare attributes
diff -u /tmp/root1.tar.list /tmp/root2.tar.list
rm /tmp/root1.tar /tmp/root2.tar /tmp/root1.tar.list /tmp/root2.tar.list

rm /tmp/debian-mm.tar
rm -r /tmp/debian-debootstrap /tmp/debian-mm
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	echo "HAVE_QEMU != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
fi


print_header "test --help"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
# we redirect to /dev/null instead of using --quiet to not cause a broken pipe
# when grep exits before mmdebstrap was able to write all its output
$CMD --help | grep --fixed-strings 'mmdebstrap [OPTION...] [SUITE [TARGET [MIRROR...]]]' >/dev/null
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "test --man"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8

# we redirect to /dev/null instead of using --quiet to not cause a broken pipe
# when grep exits before mmdebstrap was able to write all its output
$CMD --man | grep --fixed-strings 'mmdebstrap [OPTION...] [*SUITE* [*TARGET* [*MIRROR*...]]]' >/dev/null
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "test --version"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
# we redirect to /dev/null instead of using --quiet to not cause a broken pipe
# when grep exits before mmdebstrap was able to write all its output
$CMD --version | egrep '^mmdebstrap [0-9](\.[0-9])+$' >/dev/null
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
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
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "mode=unshare,variant=apt: fail with unshare as root user"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test modifies the system and should only be run inside a container" >&2
	exit 1
fi
sysctl -w kernel.unprivileged_userns_clone=1
ret=0
$CMD --mode=unshare --variant=apt $DEFAULT_DIST /tmp/debian-chroot $mirror || ret=\$?
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret >&2
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	echo "HAVE_QEMU != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
fi

for format in tar squashfs ext2; do
	print_header "mode=unshare/root,variant=debootstrap: check for bit-by-bit identical $format output"
	cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test modifies the system and should only be run inside a container" >&2
	exit 1
fi
adduser --gecos user --disabled-password user
sysctl -w kernel.unprivileged_userns_clone=1
export SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
$CMD --mode=root --variant=debootstrap $DEFAULT_DIST /tmp/debian-chroot-root.$format $mirror
if [ "$format" = tar ]; then
	printf 'ustar ' | cmp --bytes=6 --ignore-initial=257:0 /tmp/debian-chroot-root.tar -
elif [ "$format" = squashfs ]; then
	printf 'hsqs' | cmp --bytes=4 /tmp/debian-chroot-root.squashfs -
elif [ "$format" = ext2 ]; then
	printf '\123\357' | cmp --bytes=2 --ignore-initial=1080:0 /tmp/debian-chroot-root.ext2 -
else
	echo "unknown format: $format" >&2
fi
runuser -u user -- $CMD --mode=unshare --variant=debootstrap $DEFAULT_DIST /tmp/debian-chroot-unshare.$format $mirror
cmp /tmp/debian-chroot-root.$format /tmp/debian-chroot-unshare.$format
rm /tmp/debian-chroot-root.$format /tmp/debian-chroot-unshare.$format
END
	if [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
		runtests=$((runtests+1))
	else
		echo "HAVE_QEMU != yes -- Skipping test..." >&2
		skipped=$((skipped+1))
	fi
done

print_header "mode=unshare,variant=apt: test taridshift utility"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test modifies the system and should only be run inside a container" >&2
	exit 1
fi
adduser --gecos user --disabled-password user
echo user:100000:65536 | cmp /etc/subuid -
echo user:100000:65536 | cmp /etc/subgid -
sysctl -w kernel.unprivileged_userns_clone=1
# include iputils-ping so that we can verify that taridshift does not remove
# extended attributes
# run through tarshift no-op to create a tarball that should be bit-by-bit
# identical to a round trip through "taridshift X" and "taridshift -X"
runuser -u user -- $CMD --mode=unshare --variant=apt --include=iputils-ping $DEFAULT_DIST - $mirror \
	| ./taridshift 0 > /tmp/debian-chroot.tar
# make sure that xattrs are set in the original tarball
mkdir /tmp/debian-chroot
tar --xattrs --xattrs-include='*' --directory /tmp/debian-chroot -xf /tmp/debian-chroot.tar ./bin/ping
echo "/tmp/debian-chroot/bin/ping cap_net_raw=ep" > /tmp/expected
getcap /tmp/debian-chroot/bin/ping | diff -u /tmp/expected -
rm /tmp/debian-chroot/bin/ping
rmdir /tmp/debian-chroot/bin
rmdir /tmp/debian-chroot
# shift the uid/gid forward by 100000 and backward by 100000
./taridshift 100000 < /tmp/debian-chroot.tar > /tmp/debian-chroot-shifted.tar
./taridshift -100000 < /tmp/debian-chroot-shifted.tar > /tmp/debian-chroot-shiftedback.tar
# the tarball before and after the roundtrip through taridshift should be bit
# by bit identical
cmp /tmp/debian-chroot.tar /tmp/debian-chroot-shiftedback.tar
# manually adjust uid/gid and compare "tar -t" output
tar --numeric-owner -tvf /tmp/debian-chroot.tar \
	| sed 's# 100/0 # 100100/100000 #' \
	| sed 's# 0/0 # 100000/100000 #' \
	| sed 's# 0/5 # 100000/100005 #' \
	| sed 's# 0/8 # 100000/100008 #' \
	| sed 's# 0/42 # 100000/100042 #' \
	| sed 's# 0/43 # 100000/100043 #' \
	| sed 's# 0/50 # 100000/100050 #' \
	| sed 's/ \\+/ /g' \
	> /tmp/debian-chroot.txt
tar --numeric-owner -tvf /tmp/debian-chroot-shifted.tar \
	| sed 's/ \\+/ /g' \
	| diff -u /tmp/debian-chroot.txt -
mkdir /tmp/debian-chroot
tar --xattrs --xattrs-include='*' --directory /tmp/debian-chroot -xf /tmp/debian-chroot-shifted.tar
echo "100000 100000" > /tmp/expected
stat --format="%u %g" /tmp/debian-chroot/bin/ping | diff -u /tmp/expected -
echo "/tmp/debian-chroot/bin/ping cap_net_raw=ep" > /tmp/expected
getcap /tmp/debian-chroot/bin/ping | diff -u /tmp/expected -
echo "0 0" > /tmp/expected
runuser -u user -- $CMD --unshare-helper /usr/sbin/chroot /tmp/debian-chroot stat --format="%u %g" /bin/ping \
	| diff -u /tmp/expected -
echo "/bin/ping cap_net_raw=ep" > /tmp/expected
runuser -u user -- $CMD --unshare-helper /usr/sbin/chroot /tmp/debian-chroot getcap /bin/ping \
	| diff -u /tmp/expected -
rm /tmp/debian-chroot.tar /tmp/debian-chroot-shifted.tar /tmp/debian-chroot.txt /tmp/debian-chroot-shiftedback.tar /tmp/expected
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	echo "HAVE_QEMU != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
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
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
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
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
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
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
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
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
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
	echo expected failure but got exit \$ret >&2
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
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
	echo expected failure but got exit \$ret >&2
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
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
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "mode=unshare,variant=apt: create gzip compressed tarball"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test modifies the system and should only be run inside a container" >&2
	exit 1
fi
adduser --gecos user --disabled-password user
sysctl -w kernel.unprivileged_userns_clone=1
runuser -u user -- $CMD --mode=unshare --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar.gz $mirror
printf '\037\213\010' | cmp --bytes=3 /tmp/debian-chroot.tar.gz -
tar -tf /tmp/debian-chroot.tar.gz | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar.gz
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	echo "HAVE_QEMU != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
fi

print_header "mode=unshare,variant=apt: custom TMPDIR"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test modifies the system and should only be run inside a container" >&2
	exit 1
fi
adduser --gecos user --disabled-password user
sysctl -w kernel.unprivileged_userns_clone=1
homedir=\$(runuser -u user -- sh -c 'cd && pwd')
runuser -u user -- mkdir "\$homedir/tmp"
runuser -u user -- env TMPDIR="\$homedir/tmp" $CMD --mode=unshare --variant=apt \
	--setup-hook='case "\$1" in "'"\$homedir/tmp/mmdebstrap."'"??????????) exit 0;; *) exit 1;; esac' \
	 $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
# use rmdir as a quick check that nothing is remaining in TMPDIR
runuser -u user -- rmdir "\$homedir/tmp"
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	echo "HAVE_QEMU != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
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
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

print_header "mode=$defaultmode,variant=apt: directory ending in .tar"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=$defaultmode --variant=apt --format=directory $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
ftype=\$(stat -c %F /tmp/debian-chroot.tar)
if [ "\$ftype" != directory ]; then
	echo "expected directory but got: \$ftype" >&2
	exit 1
fi
tar -C /tmp/debian-chroot.tar --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

print_header "mode=$defaultmode,variant=apt: test squashfs image"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.squashfs $mirror
printf 'hsqs' | cmp --bytes=4 /tmp/debian-chroot.squashfs -
# workaround for https://github.com/AgentD/squashfs-tools-ng/issues/37
sed 's#\\([^.]\\)/\$#\\1#' tar1.txt | sort > /tmp/tar1noslash.txt
# workaround for https://github.com/AgentD/squashfs-tools-ng/issues/42
sqfs2tar --no-skip --root-becomes . /tmp/debian-chroot.squashfs | tar -t \
	| sed 's#\\([^.]\\)/\$#\\1#' \
	| sort | diff -u /tmp/tar1noslash.txt -
rm /tmp/debian-chroot.squashfs /tmp/tar1noslash.txt
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

for mode in root unshare fakechroot proot; do
	print_header "mode=$mode,variant=apt: test ext2 image"
	cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	adduser --gecos user --disabled-password user
fi
if [ "$mode" = unshare ]; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	sysctl -w kernel.unprivileged_userns_clone=1
fi
prefix=
[ "\$(id -u)" -eq 0 ] && [ "$mode" != "root" ] && prefix="runuser -u user --"
[ "$mode" = "fakechroot" ] && prefix="\$prefix fakechroot fakeroot"
\$prefix $CMD --mode=$mode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.ext2 $mirror
mkdir /tmp/mnt
mount /tmp/debian-chroot.ext2 /tmp/mnt
rmdir /tmp/mnt/lost+found
# in fakechroot mode, we use a fake ldconfig, so we have to
# artificially add some files
{ tar -C /tmp/mnt -c . | tar -t;
  [ "$mode" = "fakechroot" ] && printf "./etc/ld.so.cache\n./var/cache/ldconfig/\n";
  [ "$mode" = "fakechroot" ] && printf "./etc/.pwd.lock\n";
} | sort | diff -u tar1.txt -
umount /tmp/mnt
rmdir /tmp/mnt
rm /tmp/debian-chroot.ext2
END
	if [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
		runtests=$((runtests+1))
	else
		echo "HAVE_QEMU != yes -- Skipping test..." >&2
		skipped=$((skipped+1))
	fi
done

print_header "mode=auto,variant=apt: test auto-mode without unshare capabilities"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test modifies the system and should only be run inside a container" >&2
	exit 1
fi
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
	runtests=$((runtests+1))
else
	echo "HAVE_QEMU != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
fi

print_header "mode=$defaultmode,variant=apt: fail with missing lz4"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
ret=0
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar.lz4 $mirror || ret=\$?
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret >&2
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

print_header "mode=$defaultmode,variant=apt: fail with path with quotes"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
ret=0
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/quoted\"path $mirror || ret=\$?
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret >&2
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

print_header "mode=root,variant=apt: create tarball with /tmp mounted nodev"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test modifies the system and should only be run inside a container" >&2
	exit 1
fi
mount -t tmpfs -o nodev,nosuid,size=300M tmpfs /tmp
# use --customize-hook to exercise the mounting/unmounting code of block devices in root mode
$CMD --mode=root --variant=apt --customize-hook='mount | grep /dev/full' --customize-hook='test "\$(echo foo | tee /dev/full 2>&1 1>/dev/null)" = "tee: /dev/full: No space left on device"' $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	echo "HAVE_QEMU != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
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
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
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
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

print_header "mode=root,variant=apt: stable default mirror"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test modifies the system and should only be run inside a container" >&2
	exit 1
fi
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
	runtests=$((runtests+1))
else
	echo "HAVE_QEMU != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
fi

print_header "mode=$defaultmode,variant=apt: pass distribution but implicitly write to stdout"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test modifies the system and should only be run inside a container" >&2
	exit 1
fi
echo "127.0.0.1 deb.debian.org" >> /etc/hosts
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST > /tmp/debian-chroot.tar
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	echo "HAVE_QEMU != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
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
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
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
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

print_header "mode=$defaultmode,variant=apt: copy:// mirror"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test requires the cache directory to be mounted on /mnt and should only be run inside a container" >&2
	exit 1
fi
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar "deb copy:///mnt/cache/debian unstable main"
tar -tf /tmp/debian-chroot.tar | sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	echo "HAVE_QEMU != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
fi

print_header "mode=$defaultmode,variant=apt: fail with file:// mirror"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test requires the cache directory to be mounted on /mnt and should only be run inside a container" >&2
	exit 1
fi
ret=0
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar "deb file:///mnt/cache/debian unstable main" || ret=\$?
rm /tmp/debian-chroot.tar
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret >&2
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	echo "HAVE_QEMU != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
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
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

print_header "mode=$defaultmode,variant=apt: mirror is real file"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
echo "deb $mirror $DEFAULT_DIST main" > /tmp/sources.list
$CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST /tmp/debian-chroot.tar /tmp/sources.list
tar -tf /tmp/debian-chroot.tar \
	| sed 's#^./etc/apt/sources.list.d/0000sources.list\$#./etc/apt/sources.list#' \
	| sort | diff -u tar1.txt -
rm /tmp/debian-chroot.tar /tmp/sources.list
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

print_header "mode=$defaultmode,variant=apt: test deb822 (1/2)"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
cat << SOURCES > /tmp/deb822.sources
Types: deb
URIs: ${mirror}1
Suites: $DEFAULT_DIST
Components: main
SOURCES
echo "deb ${mirror}2 $DEFAULT_DIST main" > /tmp/sources.list
echo "deb ${mirror}3 $DEFAULT_DIST main" \
	| $CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST \
		/tmp/debian-chroot \
		/tmp/deb822.sources \
		${mirror}4 \
		- \
		"deb ${mirror}5 $DEFAULT_DIST main" \
		${mirror}6 \
		/tmp/sources.list
test ! -e /tmp/debian-chroot/etc/apt/sources.list
cat << SOURCES | cmp /tmp/debian-chroot/etc/apt/sources.list.d/0000deb822.sources -
Types: deb
URIs: ${mirror}1
Suites: $DEFAULT_DIST
Components: main
SOURCES
cat << SOURCES | cmp /tmp/debian-chroot/etc/apt/sources.list.d/0001main.list -
deb ${mirror}4 $DEFAULT_DIST main

deb ${mirror}3 $DEFAULT_DIST main

deb ${mirror}5 $DEFAULT_DIST main

deb ${mirror}6 $DEFAULT_DIST main
SOURCES
echo "deb ${mirror}2 $DEFAULT_DIST main" | cmp /tmp/debian-chroot/etc/apt/sources.list.d/0002sources.list -
tar -C /tmp/debian-chroot --one-file-system -c . \
	| {
		tar -t \
			| grep -v "^./etc/apt/sources.list.d/0000deb822.sources$" \
			| grep -v "^./etc/apt/sources.list.d/0001main.list$" \
			| grep -v "^./etc/apt/sources.list.d/0002sources.list";
		printf "./etc/apt/sources.list\n";
	} | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
rm /tmp/sources.list /tmp/deb822.sources
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

print_header "mode=$defaultmode,variant=apt: test deb822 (2/2)"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
cat << SOURCES > /tmp/deb822
Types: deb
URIs: ${mirror}1
Suites: $DEFAULT_DIST
Components: main
SOURCES
echo "deb ${mirror}2 $DEFAULT_DIST main" > /tmp/sources
cat << SOURCES | $CMD --mode=$defaultmode --variant=apt $DEFAULT_DIST \
		/tmp/debian-chroot \
		/tmp/deb822 \
		- \
		/tmp/sources
Types: deb
URIs: ${mirror}3
Suites: $DEFAULT_DIST
Components: main
SOURCES
test ! -e /tmp/debian-chroot/etc/apt/sources.list
ls -lha /tmp/debian-chroot/etc/apt/sources.list.d/
cat << SOURCES | cmp /tmp/debian-chroot/etc/apt/sources.list.d/0000deb822.sources -
Types: deb
URIs: ${mirror}1
Suites: $DEFAULT_DIST
Components: main
SOURCES
cat << SOURCES | cmp /tmp/debian-chroot/etc/apt/sources.list.d/0001main.sources -
Types: deb
URIs: ${mirror}3
Suites: $DEFAULT_DIST
Components: main
SOURCES
echo "deb ${mirror}2 $DEFAULT_DIST main" | cmp /tmp/debian-chroot/etc/apt/sources.list.d/0002sources.list -
tar -C /tmp/debian-chroot --one-file-system -c . \
	| {
		tar -t \
			| grep -v "^./etc/apt/sources.list.d/0000deb822.sources$" \
			| grep -v "^./etc/apt/sources.list.d/0001main.sources$" \
			| grep -v "^./etc/apt/sources.list.d/0002sources.list$";
		printf "./etc/apt/sources.list\n";
	} | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
rm /tmp/sources /tmp/deb822
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
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
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
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
	echo expected failure but got exit \$ret >&2
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

print_header "mode=root,variant=apt: fail installing to /"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
ret=0
$CMD --mode=root --variant=apt $DEFAULT_DIST / $mirror || ret=\$?
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret >&2
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
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
	echo expected failure but got exit \$ret >&2
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "mode=$defaultmode,variant=apt: test arm64 without qemu support"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test modifies the system and should only be run inside a container" >&2
	exit 1
fi
apt-get remove --yes qemu-user-static binfmt-support qemu-user
ret=0
$CMD --mode=$defaultmode --variant=apt --architectures=arm64 $DEFAULT_DIST /tmp/debian-chroot.tar $mirror || ret=\$?
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret >&2
	exit 1
fi
END
if [ "$HOSTARCH" != amd64 ]; then
	echo "HOSTARCH != amd64 -- Skipping test..." >&2
	skipped=$((skipped+1))
elif [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	echo "HAVE_QEMU != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
fi

print_header "mode=$defaultmode,variant=apt: test i386 (which can be executed without qemu)"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test modifies the system and should only be run inside a container" >&2
	exit 1
fi
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
	| grep -v '^\./usr/lib/gcc/i686-linux-gnu/[0-9]\+/$' \
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
	| grep -v '^\./usr/lib/gcc/x86_64-linux-gnu/[0-9]\+/$' \
	| grep -v '^\./lib/x86_64-linux-gnu/ld-linux-x86-64\.so\.2$' \
	| grep -v '^\./lib/x86_64-linux-gnu/libmvec-2\.[0-9]\+\.so$' \
	| grep -v '^\./lib/x86_64-linux-gnu/libmvec\.so\.1$' \
	| grep -v '^\./usr/share/doc/[^/]\+/changelog\(\.Debian\)\?\.amd64\.gz$' \
	| grep -v '^\./usr/share/man/man8/i386\.8\.gz$' \
	| grep -v '^\./usr/share/man/man8/x86_64\.8\.gz$';
} | sort | diff -u - tar2.txt
rm /tmp/debian-chroot.tar
END
# this test compares the contents of different architectures, so this might
# fail if the versions do not match
if [ "$RUN_MA_SAME_TESTS" = "yes" ]; then
	if [ "$HOSTARCH" != amd64 ]; then
		echo "HOSTARCH != amd64 -- Skipping test..." >&2
		skipped=$((skipped+1))
	elif [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
		runtests=$((runtests+1))
	else
		echo "HAVE_QEMU != yes -- Skipping test..." >&2
		skipped=$((skipped+1))
	fi
else
	echo "RUN_MA_SAME_TESTS != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
fi

# to test foreign architecture package installation we choose a package which
#   - is not part of the native installation set
#   - does not have any dependencies
#   - installs only few files
#   - doesn't change its name regularly (like gcc-*-base)
print_header "mode=root,variant=apt: test --include=libmagic-mgc:arm64"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt --architectures=amd64,arm64 --include=libmagic-mgc:arm64 $DEFAULT_DIST /tmp/debian-chroot $mirror
{ echo "amd64"; echo "arm64"; } | cmp /tmp/debian-chroot/var/lib/dpkg/arch -
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
	if [ "$HOSTARCH" != amd64 ]; then
		echo "HOSTARCH != amd64 -- Skipping test..." >&2
		skipped=$((skipped+1))
	elif [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
		runtests=$((runtests+1))
	else
		./run_null.sh SUDO
		runtests=$((runtests+1))
	fi
else
	echo "RUN_MA_SAME_TESTS != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
fi

print_header "mode=root,variant=apt: test --include=libmagic-mgc:arm64 with multiple --arch options"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt --architectures=amd64 --architectures=arm64 --include=libmagic-mgc:arm64 $DEFAULT_DIST /tmp/debian-chroot $mirror
{ echo "amd64"; echo "arm64"; } | cmp /tmp/debian-chroot/var/lib/dpkg/arch -
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
	if [ "$HOSTARCH" != amd64 ]; then
		echo "HOSTARCH != amd64 -- Skipping test..." >&2
		skipped=$((skipped+1))
	elif [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
		runtests=$((runtests+1))
	else
		./run_null.sh SUDO
		runtests=$((runtests+1))
	fi
else
	echo "RUN_MA_SAME_TESTS != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
fi

print_header "mode=root,variant=apt: test --aptopt"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
echo 'Acquire::Languages "none";' > /tmp/config
$CMD --mode=root --variant=apt --aptopt='Acquire::Check-Valid-Until "false"' --aptopt=/tmp/config $DEFAULT_DIST /tmp/debian-chroot $mirror
printf 'Acquire::Check-Valid-Until "false";\nAcquire::Languages "none";\n' | cmp /tmp/debian-chroot/etc/apt/apt.conf.d/99mmdebstrap -
rm /tmp/debian-chroot/etc/apt/apt.conf.d/99mmdebstrap
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot /tmp/config
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "mode=root,variant=apt: test --keyring"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test modifies the system and should only be run inside a container" >&2
	exit 1
fi
rm /etc/apt/trusted.gpg.d/*.gpg
$CMD --mode=root --variant=apt --keyring=/usr/share/keyrings/debian-archive-keyring.gpg --keyring=/usr/share/keyrings/ $DEFAULT_DIST /tmp/debian-chroot "deb $mirror $DEFAULT_DIST main"
# make sure that no [signedby=...] managed to make it into the sources.list
echo "deb $mirror $DEFAULT_DIST main" | cmp /tmp/debian-chroot/etc/apt/sources.list -
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	echo "HAVE_QEMU != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
fi

print_header "mode=root,variant=apt: test --keyring overwrites"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
mkdir -p /tmp/emptydir
touch /tmp/emptyfile
# this overwrites the apt keyring options and should fail
ret=0
$CMD --mode=root --variant=apt --keyring=/tmp/emptydir --keyring=/tmp/emptyfile $DEFAULT_DIST /tmp/debian-chroot "deb $mirror $DEFAULT_DIST main" || ret=\$?
# make sure that no [signedby=...] managed to make it into the sources.list
echo "deb $mirror $DEFAULT_DIST main" | cmp /tmp/debian-chroot/etc/apt/sources.list -
rm -r /tmp/debian-chroot
rmdir /tmp/emptydir
rm /tmp/emptyfile
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret >&2
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "mode=root,variant=apt: test signed-by without host keys"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test modifies the system and should only be run inside a container" >&2
	exit 1
fi
rm /etc/apt/trusted.gpg.d/*.gpg
$CMD --mode=root --variant=apt $DEFAULT_DIST /tmp/debian-chroot $mirror
printf 'deb [signed-by="/usr/share/keyrings/debian-archive-keyring.gpg"] $mirror $DEFAULT_DIST main\n' | cmp /tmp/debian-chroot/etc/apt/sources.list -
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	echo "HAVE_QEMU != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
fi

print_header "mode=root,variant=apt: test signed-by with host keys"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt $DEFAULT_DIST /tmp/debian-chroot $mirror
printf 'deb $mirror $DEFAULT_DIST main\n' | cmp /tmp/debian-chroot/etc/apt/sources.list -
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "mode=root,variant=apt: test --dpkgopt"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
echo no-pager > /tmp/config
$CMD --mode=root --variant=apt --dpkgopt="path-exclude=/usr/share/doc/*" --dpkgopt=/tmp/config --dpkgopt="path-include=/usr/share/doc/dpkg/copyright" $DEFAULT_DIST /tmp/debian-chroot $mirror
printf 'path-exclude=/usr/share/doc/*\nno-pager\npath-include=/usr/share/doc/dpkg/copyright\n' | cmp /tmp/debian-chroot/etc/dpkg/dpkg.cfg.d/99mmdebstrap -
rm /tmp/debian-chroot/etc/dpkg/dpkg.cfg.d/99mmdebstrap
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort > tar2.txt
{ grep -v '^./usr/share/doc/.' tar1.txt; echo ./usr/share/doc/dpkg/; echo ./usr/share/doc/dpkg/copyright; } | sort | diff -u - tar2.txt
rm -r /tmp/debian-chroot /tmp/config
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
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
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
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
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "mode=root,variant=apt: test merged-usr via --setup-hook"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=root --variant=apt \
	--setup-hook=./hooks/setup00-merged-usr.sh \
	--customize-hook='[ -L "\$1"/bin -a -L "\$1"/sbin -a -L "\$1"/lib ]' \
	$DEFAULT_DIST /tmp/debian-chroot $mirror
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort > tar2.txt
{
	sed -e 's/^\.\/bin\//.\/usr\/bin\//;s/^\.\/lib\//.\/usr\/lib\//;s/^\.\/sbin\//.\/usr\/sbin\//;' tar1.txt | {
		case $HOSTARCH in
		amd64) sed -e 's/^\.\/lib32\//.\/usr\/lib32\//;s/^\.\/lib64\//.\/usr\/lib64\//;s/^\.\/libx32\//.\/usr\/libx32\//;';;
		ppc64el) sed -e 's/^\.\/lib64\//.\/usr\/lib64\//;';;
		*) cat;;
		esac
	};
	echo ./bin;
	echo ./lib;
	echo ./sbin;
	case $HOSTARCH in
	amd64)
		echo ./lib32;
		echo ./lib64;
		echo ./libx32;
		echo ./usr/lib32/;
		echo ./usr/libx32/;
		;;
	ppc64el)
		echo ./lib64;
		;;
	esac
} | sort -u | diff -u - tar2.txt
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "mode=root,variant=apt: test --essential-hook"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
cat << 'SCRIPT' > /tmp/essential.sh
#!/bin/sh
echo tzdata tzdata/Zones/Europe select Berlin | chroot "\$1" debconf-set-selections
SCRIPT
chmod +x /tmp/essential.sh
$CMD --mode=root --variant=apt --include=tzdata --essential-hook='echo tzdata tzdata/Areas select Europe | chroot "\$1" debconf-set-selections' --essential-hook=/tmp/essential.sh $DEFAULT_DIST /tmp/debian-chroot $mirror
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
rm /tmp/essential.sh
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "mode=root,variant=apt: test --customize-hook"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
cat << 'SCRIPT' > /tmp/customize.sh
#!/bin/sh
chroot "\$1" whoami > "\$1/output2"
chroot "\$1" pwd >> "\$1/output2"
SCRIPT
chmod +x /tmp/customize.sh
$CMD --mode=root --variant=apt --customize-hook='chroot "\$1" sh -c "whoami; pwd" > "\$1/output1"' --customize-hook=/tmp/customize.sh $DEFAULT_DIST /tmp/debian-chroot $mirror
printf "root\n/\n" | cmp /tmp/debian-chroot/output1
printf "root\n/\n" | cmp /tmp/debian-chroot/output2
rm /tmp/debian-chroot/output1
rm /tmp/debian-chroot/output2
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm /tmp/customize.sh
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
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
	echo expected failure but got exit \$ret >&2
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
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
	echo customize hook was not interrupted >&2
	rm fail
	exit 1
fi
if [ "\$ret" = 0 ]; then
	echo expected failure but got exit \$ret >&2
	exit 1
fi
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "mode=root,variant=apt: test --hook-directory"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
for h in hookA hookB; do
	mkdir /tmp/\$h
	for s in setup extract essential customize; do
		cat << SCRIPT > /tmp/\$h/\${s}00.sh
#!/bin/sh
echo \$h/\${s}00 >> "\\\$1/\$s"
SCRIPT
		chmod +x /tmp/\$h/\${s}00.sh
		cat << SCRIPT > /tmp/\$h/\${s}01.sh
echo \$h/\${s}01 >> "\\\$1/\$s"
SCRIPT
		chmod +x /tmp/\$h/\${s}01.sh
	done
done
$CMD --mode=root --variant=apt \
	--setup-hook='echo cliA/setup >> "\$1"/setup' \
	--extract-hook='echo cliA/extract >> "\$1"/extract' \
	--essential-hook='echo cliA/essential >> "\$1"/essential' \
	--customize-hook='echo cliA/customize >> "\$1"/customize' \
	--hook-dir=/tmp/hookA \
	--setup-hook='echo cliB/setup >> "\$1"/setup' \
	--extract-hook='echo cliB/extract >> "\$1"/extract' \
	--essential-hook='echo cliB/essential >> "\$1"/essential' \
	--customize-hook='echo cliB/customize >> "\$1"/customize' \
	--hook-dir=/tmp/hookB \
	--setup-hook='echo cliC/setup >> "\$1"/setup' \
	--extract-hook='echo cliC/extract >> "\$1"/extract' \
	--essential-hook='echo cliC/essential >> "\$1"/essential' \
	--customize-hook='echo cliC/customize >> "\$1"/customize' \
	 $DEFAULT_DIST /tmp/debian-chroot $mirror
printf "cliA/setup\nhookA/setup00\nhookA/setup01\ncliB/setup\nhookB/setup00\nhookB/setup01\ncliC/setup\n" | diff -u - /tmp/debian-chroot/setup
printf "cliA/extract\nhookA/extract00\nhookA/extract01\ncliB/extract\nhookB/extract00\nhookB/extract01\ncliC/extract\n" | diff -u - /tmp/debian-chroot/extract
printf "cliA/essential\nhookA/essential00\nhookA/essential01\ncliB/essential\nhookB/essential00\nhookB/essential01\ncliC/essential\n" | diff -u - /tmp/debian-chroot/essential
printf "cliA/customize\nhookA/customize00\nhookA/customize01\ncliB/customize\nhookB/customize00\nhookB/customize01\ncliC/customize\n" | diff -u - /tmp/debian-chroot/customize
for s in setup extract essential customize; do
	rm /tmp/debian-chroot/\$s
done
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
for h in hookA hookB; do
	for s in setup extract essential customize; do
		rm /tmp/\$h/\${s}00.sh
		rm /tmp/\$h/\${s}01.sh
	done
	rmdir /tmp/\$h
done
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "mode=root,variant=apt: test eatmydata via --hook-dir"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
cat << SCRIPT > /tmp/checkeatmydata.sh
#!/bin/sh
set -exu
cat << EOF | diff - "\\\$1"/usr/bin/dpkg
#!/bin/sh
exec /usr/bin/eatmydata /usr/bin/dpkg.distrib "\\\\\\\$@"
EOF
[ -e "\\\$1"/usr/bin/eatmydata ]
SCRIPT
chmod +x /tmp/checkeatmydata.sh
$CMD --mode=root --variant=apt \
	--customize-hook=/tmp/checkeatmydata.sh \
	--essential-hook=/tmp/checkeatmydata.sh \
	--extract-hook='printf "\\177ELF\\002\\001\\001\\000" | cmp --bytes=8 - "\$1"/usr/bin/dpkg' \
	--hook-dir=./hooks/eatmydata \
	--customize-hook='printf "\\177ELF\\002\\001\\001\\000" | cmp --bytes=8 - "\$1"/usr/bin/dpkg' \
	 $DEFAULT_DIST /tmp/debian-chroot $mirror
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm /tmp/checkeatmydata.sh
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "mode=root,variant=apt: test special hooks using helpers"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
mkfifo /tmp/myfifo
mkdir /tmp/root
ln -s /real /tmp/root/link
mkdir /tmp/root/real
run_testA() {
  echo content > /tmp/foo
  { { { $CMD --hook-helper /tmp/root root setup env 1 upload /tmp/foo \$1 < /tmp/myfifo 3>&-; echo \$? >&3; printf "\\000\\000adios";
      } | $CMD --hook-listener 1 3>&- >/tmp/myfifo; echo \$?; } 3>&1;
  } | { read xs1; [ "\$xs1" -eq 0 ]; read xs2; [ "\$xs2" -eq 0 ]; }
  echo content | diff -u - /tmp/root/real/foo
  rm /tmp/foo
  rm /tmp/root/real/foo
}
run_testA link/foo
run_testA /link/foo
run_testA ///link///foo///
run_testA /././link/././foo/././
run_testA /link/../link/foo
run_testA /link/../../link/foo
run_testA /../../link/foo
rmdir /tmp/root/real
rm /tmp/root/link
rmdir /tmp/root
rm /tmp/myfifo
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

# test special hooks
for mode in root unshare fakechroot proot; do
	print_header "mode=$mode,variant=apt: test special hooks with $mode mode"
	if [ "$mode" = "unshare" ] && [ "$HAVE_UNSHARE" != "yes" ]; then
		echo "HAVE_UNSHARE != yes -- Skipping test..." >&2
		skipped=$((skipped+1))
		continue
	fi
	if [ "$mode" = "proot" ] && [ "$HAVE_PROOT" != "yes" ]; then
		echo "HAVE_PROOT != yes -- Skipping test..." >&2
		skipped=$((skipped+1))
		continue
	fi
	cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	adduser --gecos user --disabled-password user
fi
if [ "$mode" = unshare ]; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	sysctl -w kernel.unprivileged_userns_clone=1
fi
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
tar --numeric-owner --format=pax --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime -C /tmp -cf /tmp/tar-in-setup.tar tar-in-setup
tar --numeric-owner --format=pax --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime -C /tmp -cf /tmp/tar-in-essential.tar tar-in-essential
tar --numeric-owner --format=pax --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime -C /tmp -cf /tmp/tar-in-customize.tar tar-in-customize
rm /tmp/tar-in-setup
rm /tmp/tar-in-essential
rm /tmp/tar-in-customize
echo upload-setup > /tmp/upload-setup
echo upload-essential > /tmp/upload-essential
echo upload-customize > /tmp/upload-customize
mkdir /tmp/sync-in-setup
mkdir /tmp/sync-in-essential
mkdir /tmp/sync-in-customize
echo sync-in-setup > /tmp/sync-in-setup/file
echo sync-in-essential > /tmp/sync-in-essential/file
echo sync-in-customize > /tmp/sync-in-customize/file
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
	--setup-hook='upload /tmp/upload-setup /real/upload' \
	--setup-hook='echo upload-setup | cmp "\$1/real/upload" -' \
	--setup-hook='download /real/upload /tmp/download-setup' \
	--setup-hook='rm "\$1/real/upload"' \
	--setup-hook='sync-in /tmp/sync-in-setup /real' \
	--setup-hook='echo sync-in-setup | cmp "\$1/real/file" -' \
	--setup-hook='sync-out /real /tmp/sync-out-setup' \
	--setup-hook='rm "\$1/real/file"' \
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
	--essential-hook='upload /tmp/upload-essential /symlink/upload' \
	--essential-hook='echo upload-essential | cmp "\$1/real/upload" -' \
	--essential-hook='download /symlink/upload /tmp/download-essential' \
	--essential-hook='rm "\$1/real/upload"' \
	--essential-hook='sync-in /tmp/sync-in-essential /symlink' \
	--essential-hook='echo sync-in-essential | cmp "\$1/real/file" -' \
	--essential-hook='sync-out /real /tmp/sync-out-essential' \
	--essential-hook='rm "\$1/real/file"' \
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
	--customize-hook='upload /tmp/upload-customize /symlink/upload' \
	--customize-hook='echo upload-customize | cmp "\$1/real/upload" -' \
	--customize-hook='download /symlink/upload /tmp/download-customize' \
	--customize-hook='rm "\$1/real/upload"' \
	--customize-hook='sync-in /tmp/sync-in-customize /symlink' \
	--customize-hook='echo sync-in-customize | cmp "\$1/real/file" -' \
	--customize-hook='sync-out /real /tmp/sync-out-customize' \
	--customize-hook='rm "\$1/real/file"' \
	--customize-hook='rmdir "\$1/real"' \
	--customize-hook='rm "\$1/symlink"' \
	$DEFAULT_DIST /tmp/debian-chroot.tar $mirror
for n in setup essential customize; do
	ret=0
	cmp /tmp/tar-in-\$n.tar /tmp/tar-out-\$n.tar || ret=\$?
	if [ "\$ret" -ne 0 ]; then
		if type diffoscope >/dev/null; then
			diffoscope /tmp/tar-in-\$n.tar /tmp/tar-out-\$n.tar
			exit 1
		else
			echo "no diffoscope installed" >&2
		fi
		if type base64 >/dev/null; then
			base64 /tmp/tar-in-\$n.tar
			base64 /tmp/tar-out-\$n.tar
			exit 1
		else
			echo "no base64 installed" >&2
		fi
		if type xxd >/dev/null; then
			xxd /tmp/tar-in-\$n.tar
			xxd /tmp/tar-out-\$n.tar
			exit 1
		else
			echo "no xxd installed" >&2
		fi
		exit 1
	fi
done
echo copy-out-setup | cmp /tmp/copy-out-setup -
echo copy-out-essential | cmp /tmp/copy-out-essential -
echo copy-out-customize | cmp /tmp/copy-out-customize -
echo upload-setup | cmp /tmp/download-setup -
echo upload-essential | cmp /tmp/download-essential -
echo upload-customize | cmp /tmp/download-customize -
echo sync-in-setup | cmp /tmp/sync-out-setup/file -
echo sync-in-essential | cmp /tmp/sync-out-essential/file -
echo sync-in-customize | cmp /tmp/sync-out-customize/file -
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
	/tmp/upload-setup /tmp/upload-essential /tmp/upload-customize \
	/tmp/download-setup /tmp/download-essential /tmp/download-customize \
	/tmp/sync-in-setup/file /tmp/sync-in-essential/file /tmp/sync-in-customize/file \
	/tmp/sync-out-setup/file /tmp/sync-out-essential/file /tmp/sync-out-customize/file
rmdir /tmp/sync-in-setup /tmp/sync-in-essential /tmp/sync-in-customize \
	/tmp/sync-out-setup /tmp/sync-out-essential /tmp/sync-out-customize
END
	if [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
		runtests=$((runtests+1))
	else
		echo "HAVE_QEMU != yes -- Skipping test..." >&2
		skipped=$((skipped+1))
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
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
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
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
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
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
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
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "mode=root,variant=apt: --logfile"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
# we check the full log to also prevent debug printfs to accidentally make it into a commit
$CMD --mode=root --variant=apt --logfile=/tmp/log $DEFAULT_DIST /tmp/debian-chroot $mirror
# omit the last line which should contain the runtime
head --lines=-1 /tmp/log > /tmp/trimmed
cat << LOG | diff -u - /tmp/trimmed
I: chroot architecture $HOSTARCH is equal to the host's architecture
I: automatically chosen format: directory
I: running apt-get update...
I: downloading packages with apt...
I: extracting archives...
I: installing packages...
I: cleaning package lists and apt cache...
LOG
tail --lines=1 /tmp/log | grep '^I: success in .* seconds$'
tar -C /tmp/debian-chroot --one-file-system -c . | tar -t | sort | diff -u tar1.txt -
rm -r /tmp/debian-chroot
rm /tmp/log /tmp/trimmed
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

print_header "mode=$defaultmode,variant=apt: without /etc/resolv.conf and /etc/hostname"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ ! -e /mmdebstrap-testenv ]; then
	echo "this test modifies the system and should only be run inside a container" >&2
	exit 1
fi
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
	runtests=$((runtests+1))
else
	echo "HAVE_QEMU != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
fi

print_header "mode=$defaultmode,variant=essential: test not having to install apt in --include because a hook did it before"
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
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
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
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

# test that the user can drop archives into /var/cache/apt/archives as well as
# into /var/cache/apt/archives/partial
for variant in extract custom essential apt minbase buildd important standard; do
	case "$variant" in
		custom)
			# we cannot try try it in other variants than
			# chrootless unless we pass a package list including
			# dpkg and friends
			continue
			;;
		standard)
			# python is priority:standard but uninstallable since
			# August 03 2020, see Debian bug #968217
			echo "skipping test because of #968217" >&2
			skipped=$((skipped+1))
			continue
			;;
	esac
	print_header "mode=$defaultmode,variant=$variant: compare output with pre-seeded /var/cache/apt/archives"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
export SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
$CMD --include=doc-debian --mode=$defaultmode --variant=$variant \
	--setup-hook='mkdir -p "\$1"/var/cache/apt/archives/partial' \
	--setup-hook='touch "\$1"/var/cache/apt/archives/lock' \
	--setup-hook='chmod 0640 "\$1"/var/cache/apt/archives/lock' \
	$DEFAULT_DIST - $mirror > orig.tar
# somehow, when trying to create a tarball from the 9p mount, tar throws the
# following error: tar: ./doc-debian_6.4_all.deb: File shrank by 132942 bytes; padding with zeros
# to reproduce, try: tar --directory /mnt/cache/debian/pool/main/d/doc-debian/ --create --file - . | tar --directory /tmp/ --extract --file -
# this will be different:
# md5sum /mnt/cache/debian/pool/main/d/doc-debian/*.deb /tmp/*.deb
# another reason to copy the files into a new directory is, that we can use shell globs
tmpdir=\$(mktemp -d)
cp /mnt/cache/debian/pool/main/b/busybox/busybox_*"_$HOSTARCH.deb" /mnt/cache/debian/pool/main/a/apt/apt_*"_$HOSTARCH.deb" "\$tmpdir"
$CMD --include=doc-debian --mode=$defaultmode --variant=$variant \
	--setup-hook='mkdir -p "\$1"/var/cache/apt/archives/partial' \
	--setup-hook='sync-in "'"\$tmpdir"'" /var/cache/apt/archives/partial' \
	$DEFAULT_DIST - $mirror > test1.tar
cmp orig.tar test1.tar
$CMD --include=doc-debian --mode=$defaultmode --variant=$variant --skip=download/empty \
	--customize-hook='touch "\$1"/var/cache/apt/archives/partial' \
	--setup-hook='mkdir -p "\$1"/var/cache/apt/archives/' \
	--setup-hook='sync-in "'"\$tmpdir"'" /var/cache/apt/archives/' \
	--setup-hook='chmod 0755 "\$1"/var/cache/apt/archives/' \
	$DEFAULT_DIST - $mirror > test2.tar
cmp orig.tar test2.tar
rm "\$tmpdir"/*.deb
rmdir "\$tmpdir"
END
	if [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
		runtests=$((runtests+1))
	elif [ "$defaultmode" = "root" ]; then
		./run_null.sh SUDO
		runtests=$((runtests+1))
	else
		./run_null.sh
		runtests=$((runtests+1))
	fi
done

print_header "mode=$defaultmode,variant=apt: create directory --dry-run"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
$CMD --mode=$defaultmode --dry-run --variant=apt --setup-hook="exit 1" --essential-hook="exit 1" --customize-hook="exit 1" $DEFAULT_DIST /tmp/debian-chroot $mirror
rm /tmp/debian-chroot/dev/console
rm /tmp/debian-chroot/dev/fd
rm /tmp/debian-chroot/dev/full
rm /tmp/debian-chroot/dev/null
rm /tmp/debian-chroot/dev/ptmx
rm /tmp/debian-chroot/dev/random
rm /tmp/debian-chroot/dev/stderr
rm /tmp/debian-chroot/dev/stdin
rm /tmp/debian-chroot/dev/stdout
rm /tmp/debian-chroot/dev/tty
rm /tmp/debian-chroot/dev/urandom
rm /tmp/debian-chroot/dev/zero
rm /tmp/debian-chroot/etc/apt/sources.list
rm /tmp/debian-chroot/etc/fstab
rm /tmp/debian-chroot/etc/hostname
rm /tmp/debian-chroot/etc/resolv.conf
rm /tmp/debian-chroot/var/lib/apt/lists/lock
rm /tmp/debian-chroot/var/lib/dpkg/available
rm /tmp/debian-chroot/var/lib/dpkg/cmethopt
rm /tmp/debian-chroot/var/lib/dpkg/status
# the rest should be empty directories that we can rmdir recursively
find /tmp/debian-chroot -depth -print0 | xargs -0 rmdir
END
if true; then
	echo "skipping test because of #973305" >&2
	skipped=$((skipped+1))
elif [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
elif [ "$defaultmode" = "root" ]; then
	./run_null.sh SUDO
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

# test all --dry-run variants

for variant in extract custom essential apt; do
	for mode in root unshare fakechroot proot chrootless; do
		print_header "mode=$mode,variant=$variant: create tarball --dry-run"
		if true; then
			echo "skipping test because of #973305" >&2
			skipped=$((skipped+1))
			continue
		fi
		if [ "$mode" = "unshare" ] && [ "$HAVE_UNSHARE" != "yes" ]; then
			echo "HAVE_UNSHARE != yes -- Skipping test..." >&2
			skipped=$((skipped+1))
			continue
		fi
		if [ "$mode" = "proot" ] && [ "$HAVE_PROOT" != "yes" ]; then
			echo "HAVE_PROOT != yes -- Skipping test..." >&2
			skipped=$((skipped+1))
			continue
		fi
		cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
prefix=
include=
if [ "\$(id -u)" -eq 0 ] && [ "$mode" != root ]; then
	# this must be qemu
	if ! id -u user >/dev/null 2>&1; then
		if [ ! -e /mmdebstrap-testenv ]; then
			echo "this test modifies the system and should only be run inside a container" >&2
			exit 1
		fi
		adduser --gecos user --disabled-password user
	fi
	if [ "$mode" = unshare ]; then
		if [ ! -e /mmdebstrap-testenv ]; then
			echo "this test modifies the system and should only be run inside a container" >&2
			exit 1
		fi
		sysctl -w kernel.unprivileged_userns_clone=1
	fi
	prefix="runuser -u user --"
	if [ "$mode" = extract ] || [ "$mode" = custom ]; then
		include="--include=\$(cat pkglist.txt | tr '\n' ',')"
	fi
fi
\$prefix $CMD --mode=$mode \$include --dry-run --variant=$variant $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
if [ -e /tmp/debian-chroot.tar ]; then
	echo "/tmp/debian-chroot.tar must not be created with --dry-run" >&2
	exit 1
fi
END
		if [ "$HAVE_QEMU" = "yes" ]; then
			./run_qemu.sh
			runtests=$((runtests+1))
		elif [ "$mode" = "root" ]; then
			./run_null.sh SUDO
			runtests=$((runtests+1))
		else
			./run_null.sh
			runtests=$((runtests+1))
		fi
	done
done

# test all variants

for variant in essential apt required minbase buildd important debootstrap - standard; do
	print_header "mode=root,variant=$variant: create tarball"
	if [ "$variant" = standard ]; then
		# python is priority:standard but uninstallable since August 03
		# 2020, see Debian bug #968217
		echo "skipping test because of #968217" >&2
		skipped=$((skipped+1))
		continue
	fi
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
		runtests=$((runtests+1))
	else
		./run_null.sh SUDO
		runtests=$((runtests+1))
	fi
	# check if the other modes produce the same result in each variant
	for mode in unshare fakechroot proot; do
		print_header "mode=$mode,variant=$variant: create tarball"
		# fontconfig doesn't install reproducibly because differences
		# in /var/cache/fontconfig/. See
		# https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=864082
		if [ "$variant" = standard ]; then
			echo "skipping test because of #864082" >&2
			skipped=$((skipped+1))
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
		if [ "$mode" = "unshare" ] && [ "$HAVE_UNSHARE" != "yes" ]; then
			echo "HAVE_UNSHARE != yes -- Skipping test..." >&2
			skipped=$((skipped+1))
			continue
		fi
		if [ "$mode" = "proot" ] && [ "$HAVE_PROOT" != "yes" ]; then
			echo "HAVE_PROOT != yes -- Skipping test..." >&2
			skipped=$((skipped+1))
			continue
		fi
		cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	adduser --gecos user --disabled-password user
fi
if [ "$mode" = unshare ]; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	sysctl -w kernel.unprivileged_userns_clone=1
fi
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
			runtests=$((runtests+1))
		else
			./run_null.sh
			runtests=$((runtests+1))
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
		echo "HAVE_UNSHARE != yes -- Skipping test..." >&2
		skipped=$((skipped+1))
		continue
	fi
	if [ "$mode" = "proot" ] && [ "$HAVE_PROOT" != "yes" ]; then
		echo "HAVE_PROOT != yes -- Skipping test..." >&2
		skipped=$((skipped+1))
		continue
	fi
	cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	adduser --gecos user --disabled-password user
fi
if [ "$mode" = unshare ]; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	sysctl -w kernel.unprivileged_userns_clone=1
fi
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
		runtests=$((runtests+1))
	else
		echo "HAVE_QEMU != yes -- Skipping test..." >&2
		skipped=$((skipped+1))
	fi
done

print_header "mode=chrootless,variant=custom: install doc-debian"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	adduser --gecos user --disabled-password user
fi
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
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

# regularly check whether more packages work with chrootless:
# for p in $(grep-aptavail -F Essential yes -s Package -n | sort -u); do ./mmdebstrap --mode=chrootless --variant=custom --include=bsdutils,coreutils,debianutils,diffutils,dpkg,findutils,grep,gzip,hostname,init-system-helpers,ncurses-base,ncurses-bin,perl-base,sed,tar,$p unstable /dev/null; done
print_header "mode=chrootless,variant=custom: install known-good from essential:yes"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	adduser --gecos user --disabled-password user
fi
prefix=
[ "\$(id -u)" -eq 0 ] && prefix="runuser -u user --"
\$prefix $CMD --mode=chrootless --variant=custom --include=bsdutils,coreutils,debianutils,diffutils,dpkg,findutils,grep,gzip,hostname,init-system-helpers,ncurses-base,ncurses-bin,perl-base,sed,tar $DEFAULT_DIST /dev/null $mirror
END
if true; then
	echo "skipping test because of #973325" >&2
	skipped=$((skipped+1))
elif [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

print_header "mode=chrootless,variant=custom: install doc-debian and output tarball"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
export SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
if [ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	adduser --gecos user --disabled-password user
fi
prefix=
[ "\$(id -u)" -eq 0 ] && prefix="runuser -u user --"
\$prefix $CMD --mode=chrootless --variant=custom --include=doc-debian $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
tar tvf /tmp/debian-chroot.tar | grep -v ' ./dev' | diff -u doc-debian.tar.list -
rm /tmp/debian-chroot.tar
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

print_header "mode=chrootless,variant=custom: install doc-debian and test hooks"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
export SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
if [ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	adduser --gecos user --disabled-password user
fi
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
	runtests=$((runtests+1))
else
	./run_null.sh
	runtests=$((runtests+1))
fi

print_header "mode=chrootless,variant=custom: install libmagic-mgc on arm64"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	adduser --gecos user --disabled-password user
fi
prefix=
[ "\$(id -u)" -eq 0 ] && prefix="runuser -u user --"
\$prefix $CMD --mode=chrootless --variant=custom --architectures=arm64 --include=libmagic-mgc $DEFAULT_DIST /tmp/debian-chroot $mirror
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
if [ "$HOSTARCH" != amd64 ]; then
	echo "HOSTARCH != amd64 -- Skipping test..." >&2
	skipped=$((skipped+1))
elif [ "$HAVE_BINFMT" = "yes" ]; then
	if [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
		runtests=$((runtests+1))
	else
		./run_null.sh
		runtests=$((runtests+1))
	fi
else
	echo "HAVE_BINFMT != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
fi

print_header "mode=root,variant=custom: install busybox-based sub-essential system"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
pkgs=base-files,base-passwd,busybox,debianutils,dpkg,libc-bin,mawk,tar
# busybox --install -s will install symbolic links into the rootfs, leaving
# existing files untouched. It has to run after extraction (otherwise there is
# no busybox binary) and before first configuration
$CMD --mode=root --variant=custom \
    --include=\$pkgs \
    --setup-hook='mkdir -p "\$1/bin"' \
    --setup-hook='echo root:x:0:0:root:/root:/bin/sh > "\$1/etc/passwd"' \
    --setup-hook='printf "root:x:0:\nmail:x:8:\nutmp:x:43:\n" > "\$1/etc/group"' \
    --extract-hook='chroot "\$1" busybox --install -s' \
    $DEFAULT_DIST /tmp/debian-chroot $mirror
echo "\$pkgs" | tr ',' '\n' > /tmp/expected
chroot /tmp/debian-chroot dpkg-query -f '\${binary:Package}\n' -W \
	| comm -12 - /tmp/expected \
	| diff -u - /tmp/expected
rm /tmp/expected
for cmd in echo cat sed grep; do
	test -L /tmp/debian-chroot/bin/\$cmd
	test "\$(readlink /tmp/debian-chroot/bin/\$cmd)" = "/bin/busybox"
done
for cmd in sort; do
	test -L /tmp/debian-chroot/usr/bin/\$cmd
	test "\$(readlink /tmp/debian-chroot/usr/bin/\$cmd)" = "/bin/busybox"
done
chroot /tmp/debian-chroot echo foobar \
	| chroot /tmp/debian-chroot cat \
	| chroot /tmp/debian-chroot sort \
	| chroot /tmp/debian-chroot sed 's/foobar/blubber/' \
	| chroot /tmp/debian-chroot grep blubber >/dev/null
rm -r /tmp/debian-chroot
END
if [ "$HAVE_QEMU" = "yes" ]; then
	./run_qemu.sh
	runtests=$((runtests+1))
else
	./run_null.sh SUDO
	runtests=$((runtests+1))
fi

# test foreign architecture with all modes
# create directory in sudo mode

for mode in root unshare fakechroot proot; do
	print_header "mode=$mode,variant=apt: create arm64 tarball"
	if [ "$HOSTARCH" != amd64 ]; then
		echo "HOSTARCH != amd64 -- Skipping test..." >&2
		skipped=$((skipped+1))
		continue
	fi
	if [ "$RUN_MA_SAME_TESTS" != yes ]; then
		echo "RUN_MA_SAME_TESTS != yes -- Skipping test..." >&2
		skipped=$((skipped+1))
		continue
	fi
	if [ "$HAVE_BINFMT" != "yes" ]; then
		echo "HAVE_BINFMT != yes -- Skipping test..." >&2
		skipped=$((skipped+1))
		continue
	fi
	if [ "$mode" = "unshare" ] && [ "$HAVE_UNSHARE" != "yes" ]; then
		echo "HAVE_UNSHARE != yes -- Skipping test..." >&2
		skipped=$((skipped+1))
		continue
	fi
	if [ "$mode" = "proot" ] && [ "$HAVE_PROOT" != "yes" ]; then
		echo "HAVE_PROOT != yes -- Skipping test..." >&2
		skipped=$((skipped+1))
		continue
	fi
	cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if [ "\$(id -u)" -eq 0 ] && ! id -u user > /dev/null 2>&1; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	adduser --gecos user --disabled-password user
fi
if [ "$mode" = unshare ]; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	sysctl -w kernel.unprivileged_userns_clone=1
fi
prefix=
[ "\$(id -u)" -eq 0 ] && [ "$mode" != "root" ] && prefix="runuser -u user --"
[ "$mode" = "fakechroot" ] && prefix="\$prefix fakechroot fakeroot"
\$prefix $CMD --mode=$mode --variant=apt --architectures=arm64 $DEFAULT_DIST /tmp/debian-chroot.tar $mirror
# we ignore differences between architectures by ignoring some files
# and renaming others
# in fakechroot mode, we use a fake ldconfig, so we have to
# artificially add some files
# in proot mode, some extra files are put there by proot
{ tar -tf /tmp/debian-chroot.tar \
	| grep -v '^\./lib/ld-linux-aarch64\.so\.1$' \
	| grep -v '^\./lib/aarch64-linux-gnu/ld-linux-aarch64\.so\.1$' \
	| grep -v '^\./usr/share/doc/[^/]\+/changelog\(\.Debian\)\?\.arm64\.gz$' \
	| sed 's/aarch64-linux-gnu/x86_64-linux-gnu/' \
	| sed 's/arm64/amd64/';
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
		runtests=$((runtests+1))
	elif [ "$mode" = "root" ]; then
		./run_null.sh SUDO
		runtests=$((runtests+1))
	else
		./run_null.sh
		runtests=$((runtests+1))
	fi
done

print_header "mode=$defaultmode,variant=apt: test ubuntu focal"
cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
if ! /usr/lib/apt/apt-helper download-file http://archive.ubuntu.com/ubuntu/dists/focal/Release /dev/null && grep "QEMU Virtual CPU" /proc/cpuinfo; then
	if [ ! -e /mmdebstrap-testenv ]; then
		echo "this test modifies the system and should only be run inside a container" >&2
		exit 1
	fi
	ip link set dev ens3 up
	ip addr add 10.0.2.15/24 dev ens3
	ip route add default via 10.0.2.2 dev ens3
	echo "nameserver 10.0.2.3" > /etc/resolv.conf
fi
$CMD --mode=$defaultmode --variant=apt --customize-hook='grep UBUNTU_CODENAME=focal "\$1/etc/os-release"' focal /dev/null
END
if [ "$ONLINE" = "yes" ]; then
	if [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
		runtests=$((runtests+1))
	elif [ "$defaultmode" = "root" ]; then
		./run_null.sh SUDO
		runtests=$((runtests+1))
	else
		./run_null.sh
		runtests=$((runtests+1))
	fi
else
	echo "ONLINE != yes -- Skipping test..." >&2
	skipped=$((skipped+1))
fi


if [ -e shared/cover_db.img ]; then
	# produce report inside the VM to make sure that the versions match or
	# otherwise we might get:
	# Can't read shared/cover_db/runs/1598213854.252.64287/cover.14 with Sereal: Sereal: Error: Bad Sereal header: Not a valid Sereal document. at offset 1 of input at srl_decoder.c line 600 at /usr/lib/x86_64-linux-gnu/perl5/5.30/Devel/Cover/DB/IO/Sereal.pm line 34, <$fh> chunk 1.
	cat << END > shared/test.sh
cover -nogcov -report html_basic cover_db
mkdir -p report
for f in common.js coverage.html cover.css css.js mmdebstrap--branch.html mmdebstrap--condition.html mmdebstrap.html mmdebstrap--subroutine.html standardista-table-sorting.js; do
	cp -a cover_db/\$f report
done
cover -delete cover_db
END
	if [ "$HAVE_QEMU" = "yes" ]; then
		./run_qemu.sh
	elif [ "$mode" = "root" ]; then
		./run_null.sh SUDO
	else
		./run_null.sh
	fi

	echo
	echo open file://$(pwd)/shared/report/coverage.html in a browser
	echo
fi

if [ "$((i-1))" -ne "$total" ]; then
	echo "unexpected number of tests: got $((i-1)) but expected $total" >&2
	exit 1
fi

if [ "$skipped" -gt 0 ]; then
	echo "number of skipped tests: $skipped" >&2
fi

if [ "$runtests" -gt 0 ]; then
	echo "number of executed tests: $runtests" >&2
fi

if [ "$((skipped+runtests))" -ne "$total" ]; then
	echo "sum of skipped and executed tests is not equal to $total" >&2
	exit 1
fi

rm shared/test.sh shared/tar1.txt shared/tar2.txt shared/pkglist.txt shared/doc-debian.tar.list shared/mmdebstrap shared/taridshift
