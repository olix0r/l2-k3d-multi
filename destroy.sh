#!/bin/sh

set -eu

for k in east west dev ; do
    k3d cluster delete "$k"
done
