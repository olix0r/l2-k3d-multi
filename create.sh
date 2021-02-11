#!/bin/bash

# Creates three k3d clusters: dev, east, & west.
#

set -eu
set -x

export ORG_DOMAIN="${ORG_DOMAIN:-k3d.example.com}"

port=6440
for cluster in dev east west ; do
    if k3d cluster get "$cluster" >/dev/null 2>&1 ; then
        echo "Already exists: $cluster" >&2
    else
        k3d cluster create "$cluster" \
            --api-port="$((port++))" \
            --network=multicluster-example \
            --k3s-server-arg="--cluster-domain=$cluster.${ORG_DOMAIN}" \
            --wait
    fi
done
