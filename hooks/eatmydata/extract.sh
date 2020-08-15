#!/bin/sh

set -exu

rootdir="$1"

libdir="/usr/lib/$(dpkg-architecture -q DEB_HOST_MULTIARCH)"
mkdir -p "$rootdir$libdir"
cp -a $libdir/libeatmydata* "$rootdir$libdir"
cp -a /usr/bin/eatmydata "$rootdir/usr/bin"
mv "$rootdir/usr/bin/dpkg" "$rootdir/usr/bin/dpkg.orig"
cat << END > "$rootdir/usr/bin/dpkg"
#!/bin/sh
exec /usr/bin/eatmydata /usr/bin/dpkg.orig "\$@"
END
chmod +x "$rootdir/usr/bin/dpkg"
