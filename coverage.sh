#!/bin/sh

set -eu

mkdir -p cover_db

if mountpoint -q -- cover_db; then
	sudo umount cover_db
fi

# here is something crazy:
# as we run mmdebstrap, the process ends up being run by different users with
# different privileges (real or fake). But for being able to collect
# Devel::Cover data, they must all share a single directory. The only way that
# I found to make this work is to mount the database directory with a
# filesystem that doesn't support ownership information at all and a umask that
# gives read/write access to everybody.
# https://github.com/pjcj/Devel--Cover/issues/223
fallocate -l 10M cover_db.img
sudo mkfs.vfat cover_db.img
sudo mount -o loop,umask=000 cover_db.img cover_db

nativearch=$(dpkg --print-architecture)

./make_mirror.sh

cd mirror
python3 -m http.server 8000 2>/dev/null & pid=$!
cd -

# wait for the server to start
sleep 1

if ! kill -0 $pid; then
	echo "failed to start http server"
	exit 1
fi

echo "running http server with pid $pid"

# choose the timestamp of the unstable Release file, so that we get
# reproducible results for the same mirror timestamp
export SOURCE_DATE_EPOCH=$(date --date="$(grep-dctrl -s Date -n '' mirror/dists/unstable/Release)" +%s)

CMD="perl -MDevel::Cover=-silent,-nogcov ./mmdebstrap"

total=37
i=1

echo ------------------------------------------------------------------------------
echo "($i/$total) mode=root,variant=apt: create directory"
echo ------------------------------------------------------------------------------
i=$((i+1))
sudo $CMD --mode=root --variant=apt unstable ./debian-unstable "http://localhost:8000"
sudo tar -C ./debian-unstable --one-file-system -c . | tar -t | sort > tar1.txt
sudo rm -r --one-file-system ./debian-unstable

echo ------------------------------------------------------------------------------
echo "($i/$total) mode=unshare,variant=apt: create tarball"
echo ------------------------------------------------------------------------------
i=$((i+1))
$CMD --mode=unshare --variant=apt unstable unstable-chroot.tar "http://localhost:8000"
tar -tf unstable-chroot.tar | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm unstable-chroot.tar

echo ------------------------------------------------------------------------------
echo "($i/$total) mode=auto,variant=apt: read from stdin, write to stdout"
echo ------------------------------------------------------------------------------
i=$((i+1))
echo "deb http://localhost:8000 unstable main" | $CMD --variant=apt > unstable-chroot.tar
tar -tf unstable-chroot.tar | sort > tar2.txt
diff -u tar1.txt tar2.txt
rm unstable-chroot.tar

echo ------------------------------------------------------------------------------
echo "($i/$total) mode=root,variant=apt: test --aptopt"
echo ------------------------------------------------------------------------------
i=$((i+1))
sudo $CMD --mode=root --variant=apt --aptopt="Acquire::Check-Valid-Until false" unstable ./debian-unstable "http://localhost:8000"
echo "Acquire::Check-Valid-Until false;" | cmp ./debian-unstable/etc/apt/apt.conf.d/99mmdebstrap -
sudo rm ./debian-unstable/etc/apt/apt.conf.d/99mmdebstrap
sudo tar -C ./debian-unstable --one-file-system -c . | tar -t | sort > tar2.txt
diff -u tar1.txt tar2.txt
sudo rm -r --one-file-system ./debian-unstable

echo ------------------------------------------------------------------------------
echo "($i/$total) mode=root,variant=apt: test --dpkgopt"
echo ------------------------------------------------------------------------------
i=$((i+1))
sudo $CMD --mode=root --variant=apt --dpkgopt="path-exclude=/usr/share/doc/*" unstable ./debian-unstable "http://localhost:8000"
echo "path-exclude=/usr/share/doc/*" | cmp ./debian-unstable/etc/dpkg/dpkg.cfg.d/99mmdebstrap -
sudo rm ./debian-unstable/etc/dpkg/dpkg.cfg.d/99mmdebstrap
sudo tar -C ./debian-unstable --one-file-system -c . | tar -t | sort > tar2.txt
grep -v '^./usr/share/doc/.' tar1.txt | diff -u - tar2.txt
sudo rm -r --one-file-system ./debian-unstable

echo ------------------------------------------------------------------------------
echo "($i/$total) mode=root,variant=apt: test --include"
echo ------------------------------------------------------------------------------
i=$((i+1))
sudo $CMD --mode=root --variant=apt --include=doc-debian unstable ./debian-unstable "http://localhost:8000"
sudo rm ./debian-unstable/usr/share/doc-base/debian-*
sudo rm -r ./debian-unstable/usr/share/doc/debian
sudo rm -r ./debian-unstable/usr/share/doc/doc-debian
sudo rm ./debian-unstable/var/log/apt/eipp.log.xz
sudo rm ./debian-unstable/var/lib/dpkg/info/doc-debian.list
sudo rm ./debian-unstable/var/lib/dpkg/info/doc-debian.md5sums
sudo tar -C ./debian-unstable --one-file-system -c . | tar -t | sort > tar2.txt
diff -u tar1.txt tar2.txt
sudo rm -r --one-file-system ./debian-unstable

# test all variants

for variant in essential apt required minbase buildd important debootstrap - standard; do
	echo ------------------------------------------------------------------------------
	echo "($i/$total) mode=root,variant=$variant: create directory"
	echo ------------------------------------------------------------------------------
	i=$((i+1))
	sudo $CMD --mode=root --variant=$variant unstable ./debian-unstable "http://localhost:8000"
	sudo tar -C ./debian-unstable --one-file-system -c . | tar -t | sort > "$variant.txt"
	sudo rm -r --one-file-system ./debian-unstable
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
		echo ------------------------------------------------------------------------------
		echo "($i/$total) mode=$mode,variant=$variant: create tarball"
		echo ------------------------------------------------------------------------------
		i=$((i+1))
		$CMD --mode=$mode --variant=$variant unstable unstable-chroot.tar "http://localhost:8000"
		# in fakechroot mode, we use a fake ldconfig, so we have to
		# artificially add some files
		{ tar -tf unstable-chroot.tar;
		  [ "$mode" = "fakechroot" ] && printf "./etc/ld.so.cache\n./var/cache/ldconfig/\n";
	 	} | sort | diff -u "./$variant.txt" -
		rm unstable-chroot.tar
		# Devel::Cover doesn't survive mmdebstrap re-exec-ing itself
		# with fakechroot, thus, we do an additional run where we
		# explicitly run mmdebstrap with fakechroot from the start
		if [ "$mode" = "fakechroot" ]; then
			echo ------------------------------------------------------------------------------
			echo "($i/$total) mode=$mode,variant=$variant: create tarball (ver 2)"
			echo ------------------------------------------------------------------------------
			i=$((i+1))
			fakechroot fakeroot $CMD --mode=$mode --variant=$variant unstable unstable-chroot.tar "http://localhost:8000"
			{ tar -tf unstable-chroot.tar;
			  printf "./etc/ld.so.cache\n./var/cache/ldconfig/\n";
			} | sort | diff -u "./$variant.txt" -
			rm unstable-chroot.tar
		fi
	done
	# some variants are equal and some are strict superset of the last
	# special case of the buildd variant: nothing is a superset of it
	case "$variant" in
		essential) ;; # nothing to compare it to
		apt)
			[ $(comm -23 essential.txt apt.txt | wc -l) -eq 0 ]
			[ $(comm -13 essential.txt apt.txt | wc -l) -gt 0 ]
			rm essential.txt
			;;
		required)
			[ $(comm -23 apt.txt required.txt | wc -l) -eq 0 ]
			[ $(comm -13 apt.txt required.txt | wc -l) -gt 0 ]
			rm apt.txt
			;;
		minbase) # equal to required
			cmp required.txt minbase.txt
			rm required.txt
			;;
		buildd)
			[ $(comm -23 minbase.txt buildd.txt | wc -l) -eq 0 ]
			[ $(comm -13 minbase.txt buildd.txt | wc -l) -gt 0 ]
			rm buildd.txt # we need minbase.txt but not buildd.txt
			;;
		important)
			[ $(comm -23 minbase.txt important.txt | wc -l) -eq 0 ]
			[ $(comm -13 minbase.txt important.txt | wc -l) -gt 0 ]
			rm minbase.txt
			;;
		debootstrap) # equal to important
			cmp important.txt debootstrap.txt
			rm important.txt
			;;
		-) # equal to debootstrap
			cmp debootstrap.txt ./-.txt
			rm debootstrap.txt
			;;
		standard)
			[ $(comm -23 ./-.txt standard.txt | wc -l) -eq 0 ]
			[ $(comm -13 ./-.txt standard.txt | wc -l) -gt 0 ]
			rm ./-.txt standard.txt
			;;
		*) exit 1;;
	esac

done

# test extract variant also with chrootless mode
for mode in root unshare fakechroot proot chrootless; do
	prefix=
	if [ "$mode" = "root" ]; then
		prefix=sudo
	fi
	echo ------------------------------------------------------------------------------
	echo "($i/$total) mode=$mode,variant=extract: unpack doc-debian"
	echo ------------------------------------------------------------------------------
	i=$((i+1))
	$prefix $CMD --mode=$mode --variant=extract --include=doc-debian unstable ./debian-unstable "http://localhost:8000"
	# delete contents of doc-debian
	sudo rm ./debian-unstable/usr/share/doc-base/debian-*
	sudo rm -r ./debian-unstable/usr/share/doc/debian
	sudo rm -r ./debian-unstable/usr/share/doc/doc-debian
	# delete real files
	sudo rm ./debian-unstable/etc/apt/sources.list
	sudo rm ./debian-unstable/etc/fstab
	sudo rm ./debian-unstable/etc/hostname
	sudo rm ./debian-unstable/etc/resolv.conf
	sudo rm ./debian-unstable/var/lib/dpkg/status
	# delete symlinks
	sudo rm ./debian-unstable/libx32
	sudo rm ./debian-unstable/lib64
	sudo rm ./debian-unstable/lib32
	sudo rm ./debian-unstable/sbin
	sudo rm ./debian-unstable/bin
	sudo rm ./debian-unstable/lib
	# delete ./dev (files might exist or not depending on the mode)
	sudo rm -f ./debian-unstable/dev/console
	sudo rm -f ./debian-unstable/dev/fd
	sudo rm -f ./debian-unstable/dev/full
	sudo rm -f ./debian-unstable/dev/null
	sudo rm -f ./debian-unstable/dev/ptmx
	sudo rm -f ./debian-unstable/dev/random
	sudo rm -f ./debian-unstable/dev/stderr
	sudo rm -f ./debian-unstable/dev/stdin
	sudo rm -f ./debian-unstable/dev/stdout
	sudo rm -f ./debian-unstable/dev/tty
	sudo rm -f ./debian-unstable/dev/urandom
	sudo rm -f ./debian-unstable/dev/zero
	# in chrootless mode, there is more to remove
	if [ "$mode" = "chrootless" ]; then
		sudo rm ./debian-unstable/var/log/apt/eipp.log.xz
		sudo rm ./debian-unstable/var/lib/dpkg/triggers/Lock
		sudo rm ./debian-unstable/var/lib/dpkg/triggers/Unincorp
		sudo rm ./debian-unstable/var/lib/dpkg/status-old
		sudo rm ./debian-unstable/var/lib/dpkg/info/format
		sudo rm ./debian-unstable/var/lib/dpkg/info/doc-debian.md5sums
		sudo rm ./debian-unstable/var/lib/dpkg/info/doc-debian.list
	fi
	# the rest should be empty directories that we can rmdir recursively
	sudo find ./debian-unstable -depth -print0 | xargs -0 sudo rmdir
done

echo ------------------------------------------------------------------------------
echo "($i/$total) mode=chrootless,variant=custom: install doc-debian"
echo ------------------------------------------------------------------------------
i=$((i+1))
$CMD --mode=chrootless --variant=custom --include=doc-debian unstable ./debian-unstable "http://localhost:8000"
# delete contents of doc-debian
sudo rm ./debian-unstable/usr/share/doc-base/debian-*
sudo rm -r ./debian-unstable/usr/share/doc/debian
sudo rm -r ./debian-unstable/usr/share/doc/doc-debian
# delete real files
sudo rm ./debian-unstable/etc/apt/sources.list
sudo rm ./debian-unstable/etc/fstab
sudo rm ./debian-unstable/etc/hostname
sudo rm ./debian-unstable/etc/resolv.conf
sudo rm ./debian-unstable/var/lib/dpkg/status
# delete symlinks
sudo rm ./debian-unstable/libx32
sudo rm ./debian-unstable/lib64
sudo rm ./debian-unstable/lib32
sudo rm ./debian-unstable/sbin
sudo rm ./debian-unstable/bin
sudo rm ./debian-unstable/lib
# in chrootless mode, there is more to remove
sudo rm ./debian-unstable/var/log/apt/eipp.log.xz
sudo rm ./debian-unstable/var/lib/dpkg/triggers/Lock
sudo rm ./debian-unstable/var/lib/dpkg/triggers/Unincorp
sudo rm ./debian-unstable/var/lib/dpkg/status-old
sudo rm ./debian-unstable/var/lib/dpkg/info/format
sudo rm ./debian-unstable/var/lib/dpkg/info/doc-debian.md5sums
sudo rm ./debian-unstable/var/lib/dpkg/info/doc-debian.list
# the rest should be empty directories that we can rmdir recursively
sudo find ./debian-unstable -depth -print0 | xargs -0 sudo rmdir

# test foreign architecture with all modes
# create directory in sudo mode
# FIXME: once fakechroot and proot are fixed, we have to test more variants
#        than just essential
echo ------------------------------------------------------------------------------
echo "($i/$total) mode=root,variant=essential: create directory"
echo ------------------------------------------------------------------------------
i=$((i+1))
sudo $CMD --mode=root --variant=essential unstable ./debian-unstable "http://localhost:8000"
sudo tar -C ./debian-unstable --one-file-system -c . | tar -t | sort > tar1.txt
sudo rm -r --one-file-system ./debian-unstable

# FIXME: once fakechroot and proot are fixed, we can switch to variant=apt
# FIXME: cannot test fakechroot or proot because of
#        https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=909637
for mode in root unshare fakechroot proot; do
	prefix=
	if [ "$mode" = "root" ]; then
		prefix=sudo
	elif [ "$mode" = "fakechroot" ]; then
		# Devel::Cover doesn't survive mmdebstrap re-exec-ing itself
		# with fakechroot, thus, we explicitly run mmdebstrap with
		# fakechroot from the start
		prefix="fakechroot fakeroot"
	fi
	echo ------------------------------------------------------------------------------
	echo "($i/$total) mode=$mode,variant=essential: create armhf tarball"
	echo ------------------------------------------------------------------------------
	i=$((i+1))
	$prefix $CMD --mode=$mode --variant=essential --architectures=armhf unstable ./debian-unstable.tar "http://localhost:8000"
	# we ignore differences between architectures by ignoring some files
	# and renaming others
	# in fakechroot mode, we use a fake ldconfig, so we have to
	# artificially add some files
	# in proot mode, some extra files are put there by proot
	{ tar -tf ./debian-unstable.tar \
		| grep -v '^./usr/lib/ld-linux-armhf.so.3$' \
		| grep -v '^./usr/lib/arm-linux-gnueabihf/ld-linux.so.3$' \
		| grep -v '^./usr/lib/arm-linux-gnueabihf/ld-linux-armhf.so.3$' \
		| sed 's/arm-linux-gnueabihf/x86_64-linux-gnu/' \
		| sed 's/armhf/amd64/';
		[ "$mode" = "fakechroot" ] && printf "./etc/ld.so.cache\n./var/cache/ldconfig/\n";
	} | sort > tar2.txt
	{ cat tar1.txt \
		| grep -v '^./usr/bin/i386$' \
		| grep -v '^./usr/bin/x86_64$' \
		| grep -v '^./usr/lib64/ld-linux-x86-64.so.2$' \
		| grep -v '^./usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2$' \
		| grep -v '^./usr/lib/x86_64-linux-gnu/libmvec-2.27.so$' \
		| grep -v '^./usr/lib/x86_64-linux-gnu/libmvec.so.1$' \
		| grep -v '^./usr/share/man/man8/i386.8.gz$' \
		| grep -v '^./usr/share/man/man8/x86_64.8.gz$';
		[ "$mode" = "proot" ] && printf "./etc/ld.so.preload\n./host-rootfs/\n";
	} | sort | diff -u - tar2.txt
	sudo rm ./debian-unstable.tar
done

# test if auto mode picks the right mode

kill $pid

wait $pid || true

cover -nogcov -report html_basic
mkdir -p report
for f in common.js coverage.html cover.css css.js mmdebstrap--branch.html mmdebstrap--condition.html mmdebstrap.html mmdebstrap--subroutine.html standardista-table-sorting.js; do
	cp -a cover_db/$f report
done

echo
echo open file://$(pwd)/report/coverage.html in a browser
echo

sudo umount cover_db
sudo rmdir cover_db
#rm tar1.txt tar2.txt
