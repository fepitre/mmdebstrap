#!/bin/sh

set -eu

mirrordir="./mirror"

mirror="http://deb.debian.org/debian"
nativearch=$(dpkg --print-architecture)
components=main

if [ -e "$mirrordir/dists/unstable/Release" ]; then
	http_code=$(curl --output /dev/null --silent --location --head --time-cond "$mirrordir/dists/unstable/Release" --write-out '%{http_code}' "$mirror/dists/unstable/Release")
	case "$http_code" in
		200) ;; # need update
		304) echo up-to-date; exit 0;;
		*) echo unexpected status: $http_code; exit 1;;
	esac
fi

for dist in stable testing unstable; do
	rootdir=$(mktemp --directory)

	for p in /etc/apt/apt.conf.d /etc/apt/sources.list.d /etc/apt/preferences.d /var/cache/apt /var/lib/apt/lists/partial /var/lib/dpkg; do
		mkdir -p "$rootdir/$p"
	done

	cat << END > "$rootdir/etc/apt/apt.conf"
Apt::Architecture "$nativearch";
Dir::Etc "$rootdir/etc/apt";
Dir::State "$rootdir/var/lib/apt";
Dir::Cache "$rootdir/var/cache/apt";
Apt::Install-Recommends false;
Apt::Get::Download-Only true;
Dir::Etc::Trusted "/etc/apt/trusted.gpg";
Dir::Etc::TrustedParts "/etc/apt/trusted.gpg.d";
END

	> "$rootdir/var/lib/dpkg/status"

	cat << END > "$rootdir/etc/apt/sources.list"
deb [arch=$nativearch] $mirror $dist $components
END


	APT_CONFIG="$rootdir/etc/apt/apt.conf" apt-get update

	pkgs=$(APT_CONFIG="$rootdir/etc/apt/apt.conf" apt-get indextargets \
		--format '$(FILENAME)' 'Created-By: Packages' "Architecture: $nativearch" \
		| xargs --delimiter='\n' /usr/lib/apt/apt-helper cat-file \
		| grep-dctrl --no-field-names --show-field=Package --exact-match \
			\( --field=Essential yes --or --field=Priority required \
			--or --field=Priority important --or --field=Priority standard \))

	pkgs="$(echo $pkgs) build-essential"

	APT_CONFIG="$rootdir/etc/apt/apt.conf" apt-get --yes install $pkgs

	# to be able to also test gpg verification, we need to create a mirror
	mkdir -p "$mirrordir/dists/$dist/" "$mirrordir/dists/$dist/main/binary-amd64/"
	curl --location "$mirror/dists/$dist/Release" > "$mirrordir/dists/$dist/Release"
	curl --location "$mirror/dists/$dist/Release.gpg" > "$mirrordir/dists/$dist/Release.gpg"
	curl --location "$mirror/dists/$dist/main/binary-amd64/Packages.gz" > "$mirrordir/dists/$dist/main/binary-amd64/Packages.gz"

	# the deb files downloaded by apt must be moved to their right locations in the
	# pool directory
	#
	# Instead of parsing the Packages file, we could also attempt to move the deb
	# files ourselves to the appropriate pool directories. But that approach
	# requires re-creating the heuristic by which the directory is chosen, requires
	# stripping the epoch from the filename and will break once mirrors change.
	# This way, it doesn't matter where the mirror ends up storing the package.
	gzip -dc "$mirrordir/dists/$dist/main/binary-amd64/Packages.gz" \
		| grep-dctrl --no-field-names --show-field=Package,Version,Architecture,Filename,MD5sum '' \
		| paste -sd "     \n" \
		| while read name ver arch fname md5; do
			dir="${fname%/*}"
			basename="${fname##*/}"
			# apt stores deb files with the colon encoded as %3a while
			# mirrors do not contain the epoch at all #645895
			case "$ver" in *:*) ver="${ver%%:*}%3a${ver#*:}";; esac
			aptname="$rootdir/var/cache/apt/archives/${name}_${ver}_${arch}.deb"
			if [ -e "$aptname" ]; then
				# make sure that we found the right file by checking its hash
				echo "$md5  $aptname" | md5sum --check
				mkdir -p "$mirrordir/$dir"
				mv "$aptname" "$mirrordir/$fname"
			fi
		done

	rm "$rootdir/var/cache/apt/archives/lock"
	rmdir "$rootdir/var/cache/apt/archives/partial"
	# now the apt cache should be empty
	if [ ! -z "$(ls -1qA "$rootdir/var/cache/apt/archives/")" ]; then
		echo "/var/cache/apt/archives not empty"
		exit 1
	fi

	rm -r "$rootdir"
done
