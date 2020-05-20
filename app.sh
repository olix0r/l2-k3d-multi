#!/bin/sh

set -eu
set -x

for c in east west ; do
    kubectl --context="k3d-$c" apply -k "$c"
done
