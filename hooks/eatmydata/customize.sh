#!/bin/sh

set -exu

rootdir="$1"

rm "$rootdir/usr/bin/eatmydata"
mv "$rootdir/usr/bin/dpkg.orig" "$rootdir/usr/bin/dpkg"

sync
