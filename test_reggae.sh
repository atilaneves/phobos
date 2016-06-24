#!/bin/sh
set -e
../dmd/src/dmd -defaultlib= -debuglib= hello.d -ofhello_static generated/linux/release/64/libphobos2.a
./hello_static
../dmd/src/dmd -defaultlib= -debuglib= hello.d -ofhello_dynamic generated/linux/release/64/libphobos2.so
./hello_dynamic
