#!/bin/sh

set -eu

: "${DEFAULT_DIST:=unstable}"
: "${cachedir:=./shared/cache}"
tmpdir="$(mktemp -d)"

cleanup() {
	rv=$?
	rm -f "$tmpdir/debian-$DEFAULT_DIST-overlay.qcow"
	[ -e "$tmpdir" ] && rmdir "$tmpdir"
	if [ -e shared/result.txt ]; then
		head --lines=-1 shared/result.txt
		res="$(tail --lines=1 shared/result.txt)"
		rm shared/result.txt
		if [ "$res" != "0" ]; then
			# this might possibly overwrite another non-zero rv
			rv=1
		fi
	fi
	exit $rv
}

trap cleanup INT TERM EXIT

# the path to debian-$DEFAULT_DIST.qcow must be absolute or otherwise qemu will
# look for the path relative to debian-$DEFAULT_DIST-overlay.qcow
qemu-img create -f qcow2 -b "$(realpath $cachedir)/debian-$DEFAULT_DIST.qcow" "$tmpdir/debian-$DEFAULT_DIST-overlay.qcow"
KVM=
if [ -e /dev/kvm ]; then
	KVM="-enable-kvm"
fi
# to connect to serial use:
#   minicom -D 'unix#/tmp/ttyS0'
qemu-system-x86_64 $KVM -m 1G -nographic \
	-monitor unix:/tmp/monitor,server,nowait \
	-serial unix:/tmp/ttyS0,server,nowait \
	-serial unix:/tmp/ttyS1,server,nowait \
	-virtfs local,id=mmdebstrap,path="$(pwd)/shared",security_model=none,mount_tag=mmdebstrap \
	-drive file="$tmpdir/debian-$DEFAULT_DIST-overlay.qcow",cache=unsafe,index=0
