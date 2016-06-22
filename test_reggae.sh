#!/bin/sh
set -e
../dmd/src/dmd -defaultlib= -debuglib= hello.d generated/linux/release/64/libphobos2.a
./hello
