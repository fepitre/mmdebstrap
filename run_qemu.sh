#!/bin/sh

set -eu

: "${cachedir:=./shared/cache}"
tmpdir="$(mktemp -d)"

cleanup() {
	rv=$?
	rm -f "$tmpdir/debian-unstable-overlay.qcow"
	[ -e "$tmpdir" ] && rmdir "$tmpdir"
	if [ -e shared/result.txt ]; then
		head --lines=-1 shared/result.txt
		res="$(tail --lines=1 shared/result.txt)"
		rm shared/result.txt
		if [ "$res" -ne 0 ]; then
			# this might possibly overwrite another non-zero rv
			rv=1
		fi
	fi
	exit $rv
}

trap cleanup INT TERM EXIT

# the path to debian-unstable.qcow must be absolute or otherwise qemu will
# look for the path relative to debian-unstable-overlay.qcow
qemu-img create -f qcow2 -b "$(realpath $cachedir)/debian-unstable.qcow" "$tmpdir/debian-unstable-overlay.qcow"
KVM=
if [ -e /dev/kvm ]; then
	KVM="-enable-kvm"
fi
qemu-system-x86_64 $KVM -m 512M -nographic \
	-monitor unix:/tmp/monitor,server,nowait \
	-serial unix:/tmp/ttyS0,server,nowait \
	-serial unix:/tmp/ttyS1,server,nowait \
	-virtfs local,id=mmdebstrap,path="$(pwd)/shared",security_model=none,mount_tag=mmdebstrap \
	-drive file="$tmpdir/debian-unstable-overlay.qcow",cache=unsafe,index=0
