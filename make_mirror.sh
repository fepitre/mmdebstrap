#!/bin/sh

set -eu

# This script fills either cache.A or cache.B with new content and then
# atomically switches the cache symlink from one to the other at the end.
# This way, at no point will the cache be in an non-working state, even
# when this script got canceled at any point.
# Working with two directories also automatically prunes old packages in
# the local repository.

if [ -e "./shared/cache.A" ] && [ -e "./shared/cache.B" ]; then
	echo "both ./shared/cache.A and ./shared/cache.B exist" >&2
	echo "was a former run of the script aborted?" >&2
	echo "cache symlink points to $(readlink ./shared/cache)" >&2
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
arch1=$(dpkg --print-architecture)
arch2=armhf
if [ "$arch1" = "$arch2" ]; then
	arch2=amd64
fi
components=main

: "${HAVE_QEMU:=yes}"

if [ -e "$oldmirrordir/dists/unstable/Release" ]; then
	http_code=$(curl --output /dev/null --silent --location --head --time-cond "$oldmirrordir/dists/unstable/Release" --write-out '%{http_code}' "$mirror/dists/unstable/Release")
	case "$http_code" in
		200) ;; # need update
		304) echo up-to-date; exit 0;;
		*) echo "unexpected status: $http_code"; exit 1;;
	esac
fi

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
	gzip -dc "$1/$2" \
		| grep-dctrl --no-field-names --show-field=Package,Version,Architecture,Filename,MD5sum '' \
		| paste -sd "     \n" \
		| while read name ver arch fname md5; do
			dir="${fname%/*}"
			# apt stores deb files with the colon encoded as %3a while
			# mirrors do not contain the epoch at all #645895
			case "$ver" in *:*) ver="${ver%%:*}%3a${ver#*:}";; esac
			aptname="$rootdir/var/cache/apt/archives/${name}_${ver}_${arch}.deb"
			if [ -e "$aptname" ]; then
				# make sure that we found the right file by checking its hash
				echo "$md5  $aptname" | md5sum --check >&2
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

update_cache() {
	dist="$1"
	nativearch="$2"

	# use a subdirectory of $newcachedir so that we can use
	# hardlinks
	rootdir="$newcachedir/apt"
	mkdir -p "$rootdir"

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
			--or --field=Package build-essential \) )

	pkgs="$(echo $pkgs) build-essential"

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
		echo "/var/cache/apt/archives not empty"
		exit 1
	fi

	# cleanup
	APT_CONFIG="$rootdir/etc/apt/apt.conf" apt-get --option Dir::Etc::SourceList=/dev/null update
	APT_CONFIG="$rootdir/etc/apt/apt.conf" apt-get clean
	rm "$rootdir/var/cache/apt/archives/lock"
	rm "$rootdir/var/lib/apt/lists/lock"
	rm "$rootdir/var/lib/dpkg/status"
	rm "$rootdir/var/lib/dpkg/lock-frontend"
	rm "$rootdir/var/lib/dpkg/lock"
	rm "$rootdir/etc/apt/apt.conf"
	rm "$rootdir/etc/apt/sources.list"
	rm "$rootdir/oldaptnames"
	rm "$rootdir/newaptnames"
	find "$rootdir" -depth -print0 | xargs -0 rmdir
}

for nativearch in "$arch1" "$arch2"; do
	for dist in stable testing unstable; do
		cat << END | update_cache "$dist" "$nativearch"
deb [arch=$nativearch] $mirror $dist $components
END
		if [ "$dist" = "stable" ]; then
			cat << END | update_cache "$dist" "$nativearch"
deb [arch=$nativearch] $mirror $dist $components
deb [arch=$nativearch] $mirror stable-updates main
deb [arch=$nativearch] $security_mirror stable/updates main
END
		fi
	done
done

if [ "$HAVE_QEMU" = "yes" ]; then
	# We must not use any --dpkgopt here because any dpkg options still
	# leak into the chroot with chrootless mode.
	# We do not use our own package cache here because
	#   - it doesn't (and shouldn't) contain the extra packages
	#   - it doesn't matter if the base system is from a different mirror timestamp
	# procps is needed for /sbin/sysctl
	tmpdir="$(mktemp -d)"
	./mmdebstrap --variant=apt --architectures=amd64,armhf --mode=unshare \
		--include=perl-doc,linux-image-amd64,systemd-sysv,perl,arch-test,fakechroot,fakeroot,mount,uidmap,proot,qemu-user-static,binfmt-support,qemu-user,dpkg-dev,mini-httpd,libdevel-cover-perl,debootstrap,libfakechroot:armhf,libfakeroot:armhf,procps \
		unstable - "$mirror" > "$tmpdir/debian-unstable.tar"

	cat << END > "$tmpdir/extlinux.conf"
default linux
timeout 0

label linux
kernel /vmlinuz
append initrd=/initrd.img root=/dev/sda1 rw console=ttyS0,115200
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
(
	cd /mnt;
	if [ -e cover_db.img ]; then
		mkdir -p cover_db
		mount -o loop,umask=000 cover_db.img cover_db
	fi
	sh -x ./test.sh
	ret=$?
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
	guestfish -N "$tmpdir/debian-unstable.img"=disk:3G -- \
		part-disk /dev/sda mbr : \
		part-set-bootable /dev/sda 1 true : \
		mkfs ext2 /dev/sda1 : \
		mount /dev/sda1 / : \
		tar-in "$tmpdir/debian-unstable.tar" / : \
		extlinux / : \
		copy-in "$tmpdir/extlinux.conf" / : \
		mkdir-p /etc/systemd/system/multi-user.target.wants : \
		ln-s ../mmdebstrap.service /etc/systemd/system/multi-user.target.wants/mmdebstrap.service : \
		copy-in "$tmpdir/mmdebstrap.service" /etc/systemd/system/ : \
		copy-in "$tmpdir/worker.sh" / : \
		copy-in "$tmpdir/mini-httpd" /etc/default : \
		copy-in "$tmpdir/hosts" /etc/ :
	rm "$tmpdir/extlinux.conf" "$tmpdir/worker.sh" "$tmpdir/mini-httpd" "$tmpdir/hosts" "$tmpdir/debian-unstable.tar" "$tmpdir/mmdebstrap.service"
	qemu-img convert -O qcow2 "$tmpdir/debian-unstable.img" "$newcachedir/debian-unstable.qcow"
	rm "$tmpdir/debian-unstable.img"
	rmdir "$tmpdir"
fi

mirror="http://127.0.0.1/debian"
SOURCE_DATE_EPOCH=$(date --date="$(grep-dctrl -s Date -n '' "$newmirrordir/dists/unstable/Release")" +%s)
for dist in stable testing unstable; do
	for variant in minbase buildd -; do
		# skip because of different userids for apt/systemd
		if [ "$dist" = 'stable' ] && [ "$variant" = '-' ]; then
			continue
		fi
		# skip because of #917386 and #917407
		if [ "$dist" = 'unstable' ] && [ "$variant" = '-' ]; then
			continue
		fi
		echo running debootstrap --no-merged-usr --variant=$variant $dist /tmp/debian-$dist-debootstrap $mirror
		cat << END > shared/test.sh
#!/bin/sh
set -eu
export LC_ALL=C.UTF-8
export SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
debootstrap --no-merged-usr --variant=$variant $dist /tmp/debian-$dist-debootstrap $mirror
tar --sort=name --mtime=@$SOURCE_DATE_EPOCH --clamp-mtime --numeric-owner --one-file-system -C /tmp/debian-$dist-debootstrap -c . > "$newcache/debian-$dist-$variant.tar"
rm -r /tmp/debian-$dist-debootstrap
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
	# create a temporary directory because "copy-in" cannot rename the file
	tmpdir="$(mktemp -d)"
	cat << END > "$tmpdir/mini-httpd"
START=1
DAEMON_OPTS="-h 127.0.0.1 -p 80 -u nobody -dd /mnt/cache -i /var/run/mini-httpd.pid -T UTF-8"
END
	guestfish -a "$newcachedir/debian-unstable.qcow" -i copy-in "$tmpdir/mini-httpd" /etc/default
	rm "$tmpdir/mini-httpd"
	rmdir "$tmpdir"
fi

# delete possibly leftover symlink
if [ -e ./shared/cache.tmp ]; then
	rm ./shared/cache.tmp
fi
# now atomically switch the symlink to point to the other directory
ln -s $newcache ./shared/cache.tmp
mv --no-target-directory ./shared/cache.tmp ./shared/cache
# be very careful with removing the old directory
for dist in stable testing unstable; do
	for variant in minbase buildd -; do
		if [ -e "$oldcachedir/debian-$dist-$variant.tar" ]; then
			rm "$oldcachedir/debian-$dist-$variant.tar"
		fi
	done
	if [ -e "$oldcachedir/debian/dists/$dist" ]; then
		rm --one-file-system --recursive "$oldcachedir/debian/dists/$dist"
	fi
	if [ "$dist" = "stable" ]; then
		if [ -e "$oldcachedir/debian/dists/stable-updates" ]; then
			rm --one-file-system --recursive "$oldcachedir/debian/dists/stable-updates"
		fi
		if [ -e "$oldcachedir/debian-security/dists/stable/updates" ]; then
			rm --one-file-system --recursive "$oldcachedir/debian-security/dists/stable/updates"
		fi
	fi
done
if [ -e $oldcachedir/debian-unstable.qcow ]; then
	rm --one-file-system "$oldcachedir/debian-unstable.qcow"
fi
if [ -e "$oldcachedir/debian/pool/main" ]; then
	rm --one-file-system --recursive "$oldcachedir/debian/pool/main"
fi
if [ -e "$oldcachedir/debian-security/pool/updates/main" ]; then
	rm --one-file-system --recursive "$oldcachedir/debian-security/pool/updates/main"
fi
# now the rest should only be empty directories
if [ -e "$oldcachedir" ]; then
	find "$oldcachedir" -depth -print0 | xargs -0 --no-run-if-empty rmdir
fi
