#!/bin/sh

set -eu

cachedir="./shared/cache"

# the path to debian-unstable.qcow must be absolute or otherwise qemu will
# look for the path relative to debian-unstable-overlay.qcow
qemu-img create -f qcow2 -b "$(realpath $cachedir)/debian-unstable.qcow" debian-unstable-overlay.qcow
qemu-system-x86_64 -enable-kvm -m 512M -nographic \
	-monitor unix:/tmp/monitor,server,nowait \
	-serial unix:/tmp/ttyS0,server,nowait \
	-serial unix:/tmp/ttyS1,server,nowait \
	-virtfs local,id=mmdebstrap,path="$(pwd)/shared",security_model=none,mount_tag=mmdebstrap \
	-drive file=debian-unstable-overlay.qcow,cache=unsafe,index=0
head --lines=-1 shared/result.txt
if [ "$(tail --lines=1 shared/result.txt)" -ne 0 ]; then
	echo "test.sh failed"
	exit 1
fi
rm debian-unstable-overlay.qcow shared/result.txt
