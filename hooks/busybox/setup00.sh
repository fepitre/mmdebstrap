#!/bin/sh

set -exu

rootdir="$1"

mkdir -p "$rootdir/bin"
echo root:x:0:0:root:/root:/bin/sh > "$rootdir/etc/passwd"
cat << END > "$rootdir/etc/group"
root:x:0:
mail:x:8:
utmp:x:43:
END
