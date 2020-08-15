#!/bin/sh

set -exu

rootdir="$1"

chroot "$rootdir" busybox --install -s
