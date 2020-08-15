#!/bin/sh

set -exu

rootdir="$1"

for d in bin sbin lib; do
	ln -s usr/$d "$rootdir/$d"
	mkdir -p "$rootdir/usr/$d"
done
