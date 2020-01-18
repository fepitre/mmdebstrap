#!/usr/bin/env python3
#
# This script is in the public domain
#
# This script accepts a tarball on standard input and prints a tarball on
# standard output with the same contents but all uid and gid ownership
# information shifted by the value given as first command line argument.
#
# A tool like this should be written in C but libarchive has issues:
# https://github.com/libarchive/libarchive/issues/587
# https://github.com/libarchive/libarchive/pull/1288/ (needs 3.4.1)
# Should these issues get fixed, then a good template is tarfilter.c in the
# examples directory of libarchive.
#
# We are not using Perl either, because Archive::Tar slurps the whole tarball
# into memory.
#
# We could also use Go but meh...
# https://stackoverflow.com/a/59542307/784669

import tarfile
import sys


def main():
    if len(sys.argv) < 2:
        print("usage: %s idshift" % sys.argv[0], file=sys.stderr)
        exit(1)

    idshift = int(sys.argv[1])

    # starting with Python 3.8, the default format became PAX_FORMAT, so this
    # is only for compatibility with older versions of Python 3
    with tarfile.open(fileobj=sys.stdin.buffer, mode="r|*") as in_tar, tarfile.open(
        fileobj=sys.stdout.buffer, mode="w|", format=tarfile.PAX_FORMAT
    ) as out_tar:
        for member in in_tar:
            if idshift < 0 and -idshift > member.uid:
                print("uid cannot be negative", file=sys.stderr)
                exit(1)
            if idshift < 0 and -idshift > member.gid:
                print("gid cannot be negative", file=sys.stderr)
                exit(1)

            member.uid += idshift
            member.gid += idshift
            if member.isfile():
                with in_tar.extractfile(member) as file:
                    out_tar.addfile(member, file)
            else:
                out_tar.addfile(member)


if __name__ == "__main__":
    main()
