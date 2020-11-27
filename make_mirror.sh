#!/bin/sh

set -eu

# This script fills either cache.A or cache.B with new content and then
# atomically switches the cache symlink from one to the other at the end.
# This way, at no point will the cache be in an non-working state, even
# when this script got canceled at any point.
# Working with two directories also automatically prunes old packages in
# the local repository.

deletecache() {
	dir="$1"
	echo "running deletecache $dir">&2
	if [ ! -e "$dir" ]; then
		return
	fi
	if [ ! -e "$dir/mmdebstrapcache" ]; then
		echo "$dir cannot be the mmdebstrap cache" >&2
		return 1
	fi
	# be very careful with removing the old directory
	for dist in stable testing unstable; do
		for variant in minbase buildd -; do
			if [ -e "$dir/debian-$dist-$variant.tar" ]; then
				rm "$dir/debian-$dist-$variant.tar"
			else
				echo "does not exist: $dir/debian-$dist-$variant.tar" >&2
			fi
		done
		if [ -e "$dir/debian/dists/$dist" ]; then
			rm --one-file-system --recursive "$dir/debian/dists/$dist"
		else
			echo "does not exist: $dir/debian/dists/$dist" >&2
		fi
		if [ "$dist" = "stable" ]; then
			if [ -e "$dir/debian/dists/stable-updates" ]; then
				rm --one-file-system --recursive "$dir/debian/dists/stable-updates"
			else
				echo "does not exist: $dir/debian/dists/stable-updates" >&2
			fi
			if [ -e "$dir/debian-security/dists/stable/updates" ]; then
				rm --one-file-system --recursive "$dir/debian-security/dists/stable/updates"
			else
				echo "does not exist: $dir/debian-security/dists/stable/updates" >&2
			fi
		fi
	done
	if [ -e $dir/debian-*.qcow ]; then
		rm --one-file-system "$dir"/debian-*.qcow
	else
		echo "does not exist: $dir/debian-*.qcow" >&2
	fi
	if [ -e "$dir/debian/pool/main" ]; then
		rm --one-file-system --recursive "$dir/debian/pool/main"
	else
		echo "does not exist: $dir/debian/pool/main" >&2
	fi
	if [ -e "$dir/debian-security/pool/updates/main" ]; then
		rm --one-file-system --recursive "$dir/debian-security/pool/updates/main"
	else
		echo "does not exist: $dir/debian-security/pool/updates/main" >&2
	fi
	for i in $(seq 1 6); do
		if [ ! -e "$dir/debian$i" ]; then
			continue
		fi
		rm "$dir/debian$i"
	done
	rm "$dir/mmdebstrapcache"
	# now the rest should only be empty directories
	if [ -e "$dir" ]; then
		find "$dir" -depth -print0 | xargs -0 --no-run-if-empty rmdir
	else
		echo "does not exist: $dir" >&2
	fi
}

cleanup_newcachedir() {
	echo "running cleanup_newcachedir"
	deletecache "$newcachedir"
}

get_oldaptnames() {
	if [ ! -e "$1/$2" ]; then
		return
	fi
	gzip -dc "$1/$2" \
		| grep-dctrl --no-field-names --show-field=Package,Version,Architecture,Filename '' \
		| paste -sd "    \n" \
		| while read name ver arch fname; do
			if [ ! -e "$1/$fname" ]; then
				continue
			fi
			# apt stores deb files with the colon encoded as %3a while
			# mirrors do not contain the epoch at all #645895
			case "$ver" in *:*) ver="${ver%%:*}%3a${ver#*:}";; esac
			aptname="$rootdir/var/cache/apt/archives/${name}_${ver}_${arch}.deb"
			# we have to cp and not mv because other
			# distributions might still need this file
			# we have to cp and not symlink because apt
			# doesn't recognize symlinks
			cp --link "$1/$fname" "$aptname"
			echo "$aptname"
		done
}

get_newaptnames() {
	if [ ! -e "$1/$2" ]; then
		return
	fi
	# skip empty files by trying to uncompress the first byte of the payload
	if [ "$(gzip -dc "$1/$2" | head -c1 | wc -c)" -eq 0 ]; then
		return
	fi
	gzip -dc "$1/$2" \
		| grep-dctrl --no-field-names --show-field=Package,Version,Architecture,Filename,SHA256 '' \
		| paste -sd "     \n" \
		| while read name ver arch fname hash; do
			# sanity check for the hash because sometimes the
			# archive switches the hash algorithm
			if [ "${#hash}" -ne 64 ]; then
				echo "expected hash length of 64 but got ${#hash} for: $hash" >&2
				exit 1
			fi
			dir="${fname%/*}"
			# apt stores deb files with the colon encoded as %3a while
			# mirrors do not contain the epoch at all #645895
			case "$ver" in *:*) ver="${ver%%:*}%3a${ver#*:}";; esac
			aptname="$rootdir/var/cache/apt/archives/${name}_${ver}_${arch}.deb"
			if [ -e "$aptname" ]; then
				# make sure that we found the right file by checking its hash
				echo "$hash  $aptname" | sha256sum --check >&2
				mkdir -p "$1/$dir"
				# since we move hardlinks around, the same hardlink might've been
				# moved already into the same place by another distribution.
				# mv(1) refuses to copy A to B if both are hardlinks of each other.
				if [ "$aptname" -ef "$1/$fname" ]; then
					# both files are already the same so we just need to
					# delete the source
					rm "$aptname"
				else
					mv "$aptname" "$1/$fname"
				fi
				echo "$aptname"
			fi
		done
}

cleanupapt() {
	echo "running cleanupapt" >&2
	if [ ! -e "$rootdir" ]; then
		return
	fi
	for f in \
		"$rootdir/var/cache/apt/archives/"*.deb \
		"$rootdir/var/cache/apt/archives/partial/"*.deb \
		"$rootdir/var/cache/apt/"*.bin \
		"$rootdir/var/lib/apt/lists/"* \
		"$rootdir/var/lib/dpkg/status" \
		"$rootdir/var/lib/dpkg/lock-frontend" \
		"$rootdir/var/lib/dpkg/lock" \
		"$rootdir/etc/apt/apt.conf" \
		"$rootdir/etc/apt/sources.list" \
		"$rootdir/oldaptnames" \
		"$rootdir/newaptnames" \
		"$rootdir/var/cache/apt/archives/lock"; do
		if [ ! -e "$f" ]; then
			echo "does not exist: $f" >&2
			continue
		fi
		if [ -d "$f" ]; then
			rmdir "$f"
		else
			rm "$f"
		fi
	done
	find "$rootdir" -depth -print0 | xargs -0 --no-run-if-empty rmdir
}

# note: this function uses brackets instead of curly braces, so that it's run
# in its own process and we can handle traps independent from the outside
update_cache() (
	dist="$1"
	nativearch="$2"

	# use a subdirectory of $newcachedir so that we can use
	# hardlinks
	rootdir="$newcachedir/apt"
	mkdir -p "$rootdir"

	# we only set this trap here and overwrite the previous trap, because
	# the update_cache function is run as part of a pipe and thus in its
	# own process which will EXIT after it finished
	trap "cleanupapt" EXIT INT TERM

	for p in /etc/apt/apt.conf.d /etc/apt/sources.list.d /etc/apt/preferences.d /var/cache/apt/archives /var/lib/apt/lists/partial /var/lib/dpkg; do
		mkdir -p "$rootdir/$p"
	done

	# read sources.list content from stdin
	cat > "$rootdir/etc/apt/sources.list"

	cat << END > "$rootdir/etc/apt/apt.conf"
Apt::Architecture "$nativearch";
Apt::Architectures "$nativearch";
Dir::Etc "$rootdir/etc/apt";
Dir::State "$rootdir/var/lib/apt";
Dir::Cache "$rootdir/var/cache/apt";
Apt::Install-Recommends false;
Apt::Get::Download-Only true;
Acquire::Languages "none";
Dir::Etc::Trusted "/etc/apt/trusted.gpg";
Dir::Etc::TrustedParts "/etc/apt/trusted.gpg.d";
END

	> "$rootdir/var/lib/dpkg/status"


	APT_CONFIG="$rootdir/etc/apt/apt.conf" apt-get update

	# before downloading packages and before replacing the old Packages
	# file, copy all old *.deb packages from the mirror to
	# /var/cache/apt/archives so that apt will not re-download *.deb
	# packages that we already have
	{
		get_oldaptnames "$oldmirrordir" "dists/$dist/main/binary-$nativearch/Packages.gz"
		if grep --quiet security.debian.org "$rootdir/etc/apt/sources.list"; then
			get_oldaptnames "$oldmirrordir" "dists/stable-updates/main/binary-$nativearch/Packages.gz"
			get_oldaptnames "$oldcachedir/debian-security" "dists/stable/updates/main/binary-$nativearch/Packages.gz"
		fi
	} | sort -u > "$rootdir/oldaptnames"

	pkgs=$(APT_CONFIG="$rootdir/etc/apt/apt.conf" apt-get indextargets \
		--format '$(FILENAME)' 'Created-By: Packages' "Architecture: $nativearch" \
		| xargs --delimiter='\n' /usr/lib/apt/apt-helper cat-file \
		| grep-dctrl --no-field-names --show-field=Package --exact-match \
			\( --field=Essential yes --or --field=Priority required \
			--or --field=Priority important --or --field=Priority standard \
			\) --and --not --field Package python )

	pkgs="$(echo $pkgs) build-essential busybox gpg eatmydata"

	APT_CONFIG="$rootdir/etc/apt/apt.conf" apt-get --yes install $pkgs

	# to be able to also test gpg verification, we need to create a mirror
	mkdir -p "$newmirrordir/dists/$dist/main/binary-$nativearch/"
	curl --location "$mirror/dists/$dist/Release" > "$newmirrordir/dists/$dist/Release"
	curl --location "$mirror/dists/$dist/Release.gpg" > "$newmirrordir/dists/$dist/Release.gpg"
	curl --location "$mirror/dists/$dist/main/binary-$nativearch/Packages.gz" > "$newmirrordir/dists/$dist/main/binary-$nativearch/Packages.gz"
	if grep --quiet security.debian.org "$rootdir/etc/apt/sources.list"; then
		mkdir -p "$newmirrordir/dists/stable-updates/main/binary-$nativearch/"
		curl --location "$mirror/dists/stable-updates/Release" > "$newmirrordir/dists/stable-updates/Release"
		curl --location "$mirror/dists/stable-updates/Release.gpg" > "$newmirrordir/dists/stable-updates/Release.gpg"
		curl --location "$mirror/dists/stable-updates/main/binary-$nativearch/Packages.gz" > "$newmirrordir/dists/stable-updates/main/binary-$nativearch/Packages.gz"
		mkdir -p "$newcachedir/debian-security/dists/stable/updates/main/binary-$nativearch/"
		curl --location "$security_mirror/dists/stable/updates/Release" > "$newcachedir/debian-security/dists/stable/updates/Release"
		curl --location "$security_mirror/dists/stable/updates/Release.gpg" > "$newcachedir/debian-security/dists/stable/updates/Release.gpg"
		curl --location "$security_mirror/dists/stable/updates/main/binary-$nativearch/Packages.gz" > "$newcachedir/debian-security/dists/stable/updates/main/binary-$nativearch/Packages.gz"
	fi

	# the deb files downloaded by apt must be moved to their right locations in the
	# pool directory
	#
	# Instead of parsing the Packages file, we could also attempt to move the deb
	# files ourselves to the appropriate pool directories. But that approach
	# requires re-creating the heuristic by which the directory is chosen, requires
	# stripping the epoch from the filename and will break once mirrors change.
	# This way, it doesn't matter where the mirror ends up storing the package.
	{
		get_newaptnames "$newmirrordir" "dists/$dist/main/binary-$nativearch/Packages.gz";
		if grep --quiet security.debian.org "$rootdir/etc/apt/sources.list"; then
			get_newaptnames "$newmirrordir" "dists/stable-updates/main/binary-$nativearch/Packages.gz"
			get_newaptnames "$newcachedir/debian-security" "dists/stable/updates/main/binary-$nativearch/Packages.gz"
		fi
	} | sort -u > "$rootdir/newaptnames"

	rm "$rootdir/var/cache/apt/archives/lock"
	rmdir "$rootdir/var/cache/apt/archives/partial"
	# remove all packages that were in the old Packages file but not in the
	# new one anymore
	comm -23 "$rootdir/oldaptnames" "$rootdir/newaptnames" | xargs --delimiter="\n" --no-run-if-empty rm
	# now the apt cache should be empty
	if [ ! -z "$(ls -1qA "$rootdir/var/cache/apt/archives/")" ]; then
		echo "$rootdir/var/cache/apt/archives not empty:"
		ls -la "$rootdir/var/cache/apt/archives/"
		exit 1
	fi

	APT_CONFIG="$rootdir/etc/apt/apt.conf" apt-get --option Dir::Etc::SourceList=/dev/null update
	APT_CONFIG="$rootdir/etc/apt/apt.conf" apt-get clean

	cleanupapt

	# this function is run in its own process, so we unset all traps before
	# returning
	trap "-" EXIT INT TERM
)

if [ -e "./shared/cache.A" ] && [ -e "./shared/cache.B" ]; then
	echo "both ./shared/cache.A and ./shared/cache.B exist" >&2
	echo "was a former run of the script aborted?" >&2
	if [ -e ./shared/cache ]; then
		echo "cache symlink points to $(readlink ./shared/cache)" >&2
		case "$(readlink ./shared/cache)" in
			cache.A)
				echo "maybe rm -r ./shared/cache.B" >&2
				;;
			cache.B)
				echo "maybe rm -r ./shared/cache.A" >&2
				;;
			*)
				echo "unexpected" >&2
		esac
	fi
	exit 1
fi

if [ -e "./shared/cache.A" ]; then
	oldcache=cache.A
	newcache=cache.B
else
	oldcache=cache.B
	newcache=cache.A
fi

oldcachedir="./shared/$oldcache"
newcachedir="./shared/$newcache"

oldmirrordir="$oldcachedir/debian"
newmirrordir="$newcachedir/debian"

mirror="http://deb.debian.org/debian"
security_mirror="http://security.debian.org/debian-security"
components=main

: "${DEFAULT_DIST:=unstable}"
: "${HAVE_QEMU:=yes}"
: "${RUN_MA_SAME_TESTS:=yes}"
: "${HAVE_PROOT:=yes}"
# by default, use the mmdebstrap executable in the current directory
: "${CMD:=./mmdebstrap}"

if [ -e "$oldmirrordir/dists/$DEFAULT_DIST/Release" ]; then
	http_code=$(curl --output /dev/null --silent --location --head --time-cond "$oldmirrordir/dists/$DEFAULT_DIST/Release" --write-out '%{http_code}' "$mirror/dists/$DEFAULT_DIST/Release")
	case "$http_code" in
		200) ;; # need update
		304) echo up-to-date; exit 0;;
		*) echo "unexpected status: $http_code"; exit 1;;
	esac
fi

trap "cleanup_newcachedir" EXIT INT TERM

mkdir -p "$newcachedir"
touch "$newcachedir/mmdebstrapcache"

HOSTARCH=$(dpkg --print-architecture)
if [ "$HOSTARCH" = amd64 ]; then
	arches="amd64 arm64 i386"
else
	arches="$HOSTARCH"
fi

for nativearch in $arches; do
	for dist in stable testing unstable; do
		# non-host architectures are only downloaded for $DEFAULT_DIST
		if [ $nativearch != $HOSTARCH ] && [ $DEFAULT_DIST != $dist ]; then
			continue
		fi
		cat << END | update_cache "$dist" "$nativearch"
deb [arch=$nativearch] $mirror $dist $components
END
		if [ "$dist" = "stable" ]; then
			# starting wit bullseye, stable/updates becomes stable-security
			cat << END | update_cache "$dist" "$nativearch"
deb [arch=$nativearch] $mirror $dist $components
deb [arch=$nativearch] $mirror stable-updates main
deb [arch=$nativearch] $security_mirror stable/updates main
END
		fi
	done
done

# Create some symlinks so that we can trick apt into accepting multiple apt
# lines that point to the same repository but look different. This is to
# avoid the warning:
# W: Target Packages (main/binary-all/Packages) is configured multiple times...
for i in $(seq 1 6); do
	ln -s debian "$newcachedir/debian$i"
done

tmpdir=""

cleanuptmpdir() {
	if [ -z "$tmpdir" ]; then
		return
	fi
	if [ ! -e "$tmpdir" ]; then
		return
	fi
	for f in "$tmpdir/extlinux.conf" \
		"$tmpdir/worker.sh" \
		"$tmpdir/mini-httpd" "$tmpdir/hosts" \
		"$tmpdir/debian-chroot.tar" \
		"$tmpdir/mmdebstrap.service" \
		"$tmpdir/debian-$DEFAULT_DIST.img"; do
		if [ ! -e "$f" ]; then
			echo "does not exist: $f" >&2
			continue
		fi
		rm "$f"
	done
	rmdir "$tmpdir"
}

export SOURCE_DATE_EPOCH=$(date --date="$(grep-dctrl -s Date -n '' "$newmirrordir/dists/unstable/Release")" +%s)

if [ "$HAVE_QEMU" = "yes" ]; then
	# We must not use any --dpkgopt here because any dpkg options still
	# leak into the chroot with chrootless mode.
	# We do not use our own package cache here because
	#   - it doesn't (and shouldn't) contain the extra packages
	#   - it doesn't matter if the base system is from a different mirror timestamp
	# procps is needed for /sbin/sysctl
	tmpdir="$(mktemp -d)"
	trap "cleanuptmpdir; cleanup_newcachedir" EXIT INT TERM

	pkgs=perl-doc,systemd-sysv,perl,arch-test,fakechroot,fakeroot,mount,uidmap,qemu-user-static,binfmt-support,qemu-user,dpkg-dev,mini-httpd,libdevel-cover-perl,libtemplate-perl,debootstrap,procps,apt-cudf,aspcud,squashfs-tools-ng,genext2fs,python3,libcap2-bin,gpg,debootstrap,distro-info-data,iproute2,ubuntu-keyring,apt-utils
	if [ "$HAVE_PROOT" = "yes" ]; then
		pkgs="$pkgs,proot"
	fi
	if [ ! -e ./mmdebstrap ]; then
		pkgs="$pkgs,mmdebstrap"
	fi
	case "$HOSTARCH" in
		amd64|arm64|i386)
			pkgs="$pkgs,linux-image-$HOSTARCH"
			;;
		ppc64el)
			pkgs="$pkgs,linux-image-powerpc64le"
			;;
		*)
			echo "no kernel image for $HOSTARCH" >&2
			exit 1
			;;
	esac
	if [ "$HOSTARCH" = amd64 ] && [ "$RUN_MA_SAME_TESTS" = "yes" ]; then
		arches=amd64,arm64
		pkgs="$pkgs,libfakechroot:arm64,libfakeroot:arm64"
	else
		arches=$HOSTARCH
	fi
	$CMD --variant=apt --architectures=$arches --include="$pkgs" \
		$DEFAULT_DIST - "$mirror" > "$tmpdir/debian-chroot.tar"

	cat << END > "$tmpdir/extlinux.conf"
default linux
timeout 0

label linux
kernel /vmlinuz
append initrd=/initrd.img root=/dev/vda1 rw console=ttyS0,115200
serial 0 115200
END
	cat << END > "$tmpdir/mmdebstrap.service"
[Unit]
Description=mmdebstrap worker script

[Service]
Type=oneshot
ExecStart=/worker.sh

[Install]
WantedBy=multi-user.target
END
	# here is something crazy:
	# as we run mmdebstrap, the process ends up being run by different users with
	# different privileges (real or fake). But for being able to collect
	# Devel::Cover data, they must all share a single directory. The only way that
	# I found to make this work is to mount the database directory with a
	# filesystem that doesn't support ownership information at all and a umask that
	# gives read/write access to everybody.
	# https://github.com/pjcj/Devel--Cover/issues/223
	cat << 'END' > "$tmpdir/worker.sh"
#!/bin/sh
echo 'root:root' | chpasswd
mount -t 9p -o trans=virtio,access=any mmdebstrap /mnt
# need to restart mini-httpd because we mounted different content into www-root
systemctl restart mini-httpd

handler () {
	while IFS= read -r line || [ -n "$line" ]; do
		printf "%s %s: %s\n" "$(date -u -d "0 $(date +%s.%3N) seconds - $2 seconds" +"%T.%3N")" "$1" "$line"
	done
}

(
	cd /mnt;
	if [ -e cover_db.img ]; then
		mkdir -p cover_db
		mount -o loop,umask=000 cover_db.img cover_db
	fi

	now=$(date +%s.%3N)
	ret=0
	{ { { { {
	          sh -x ./test.sh 2>&1 1>&4 3>&- 4>&-; echo $? >&2;
	        } | handler E "$now" >&3;
	      } 4>&1 | handler O "$now" >&3;
	    } 2>&1;
	  } | { read xs; exit $xs; };
	} 3>&1 || ret=$?
	if [ -e cover_db.img ]; then
		df -h cover_db
		umount cover_db
	fi
	echo $ret
) > /mnt/result.txt 2>&1
umount /mnt
systemctl poweroff
END
	chmod +x "$tmpdir/worker.sh"
	# initially we serve from the new cache so that debootstrap can grab
	# the new package repository and not the old
	cat << END > "$tmpdir/mini-httpd"
START=1
DAEMON_OPTS="-h 127.0.0.1 -p 80 -u nobody -dd /mnt/$newcache -i /var/run/mini-httpd.pid -T UTF-8"
END
	cat << 'END' > "$tmpdir/hosts"
127.0.0.1 localhost
END
	#libguestfs-test-tool
	#export LIBGUESTFS_DEBUG=1 LIBGUESTFS_TRACE=1
	#
	# In case the rootfs was prepared in fakechroot mode, ldconfig has to
	# run to populate /etc/ld.so.cache or otherwise fakechroot tests will
	# fail to run.
	#
	# The disk size is sufficient in most cases. Sometimes, gcc will do
	# an upload with unstripped executables to make tracking down ICEs much
	# easier (see #872672, #894014). During times with unstripped gcc, the
	# buildd variant will not be 400MB but 1.3GB large and needs a 10G
	# disk.
	if [ -z ${DISK_SIZE+x} ]; then
		DISK_SIZE=3G
	fi
	guestfish -N "$tmpdir/debian-$DEFAULT_DIST.img"=disk:$DISK_SIZE -- \
		part-disk /dev/sda mbr : \
		mkfs ext2 /dev/sda1 : \
		mount /dev/sda1 / : \
		tar-in "$tmpdir/debian-chroot.tar" / : \
		command /sbin/ldconfig : \
		copy-in "$tmpdir/extlinux.conf" / : \
		mkdir-p /etc/systemd/system/multi-user.target.wants : \
		ln-s ../mmdebstrap.service /etc/systemd/system/multi-user.target.wants/mmdebstrap.service : \
		copy-in "$tmpdir/mmdebstrap.service" /etc/systemd/system/ : \
		copy-in "$tmpdir/worker.sh" / : \
		copy-in "$tmpdir/mini-httpd" /etc/default : \
		copy-in "$tmpdir/hosts" /etc/ : \
		touch /mmdebstrap-testenv : \
		upload /usr/lib/SYSLINUX/mbr.bin /mbr.bin : \
		copy-file-to-device /mbr.bin /dev/sda size:440 : \
		rm /mbr.bin : \
		extlinux / : \
		sync : \
		umount / : \
		part-set-bootable /dev/sda 1 true : \
		shutdown
	qemu-img convert -O qcow2 "$tmpdir/debian-$DEFAULT_DIST.img" "$newcachedir/debian-$DEFAULT_DIST.qcow"
	cleanuptmpdir
	trap "cleanup_newcachedir" EXIT INT TERM
fi

mirror="http://127.0.0.1/debian"
for dist in stable testing unstable; do
	for variant in minbase buildd -; do
		echo "running debootstrap --no-merged-usr --variant=$variant $dist \${TEMPDIR} $mirror"
		cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
export SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
tmpdir="\$(mktemp -d)"
chmod 755 "\$tmpdir"
debootstrap --no-merged-usr --variant=$variant $dist "\$tmpdir" $mirror
tar --sort=name --mtime=@$SOURCE_DATE_EPOCH --clamp-mtime --numeric-owner --one-file-system --xattrs -C "\$tmpdir" -c . > "$newcache/debian-$dist-$variant.tar"
rm -r "\$tmpdir"
END
		if [ "$HAVE_QEMU" = "yes" ]; then
			cachedir=$newcachedir ./run_qemu.sh
		else
			./run_null.sh SUDO
		fi
	done
done

if [ "$HAVE_QEMU" = "yes" ]; then
	# now replace the minihttpd config with one that serves the new repository
	guestfish -a "$newcachedir/debian-$DEFAULT_DIST.qcow" -i <<EOF
upload -<<END /etc/default/mini-httpd
START=1
DAEMON_OPTS="-h 127.0.0.1 -p 80 -u nobody -dd /mnt/cache -i /var/run/mini-httpd.pid -T UTF-8"
END
EOF
fi

# delete possibly leftover symlink
if [ -e ./shared/cache.tmp ]; then
	rm ./shared/cache.tmp
fi
# now atomically switch the symlink to point to the other directory
ln -s $newcache ./shared/cache.tmp
mv --no-target-directory ./shared/cache.tmp ./shared/cache

deletecache "$oldcachedir"

trap - EXIT INT TERM
