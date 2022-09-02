#!/usr/bin/env bash

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
            --k3s-arg="--cluster-domain=$cluster.${ORG_DOMAIN}@server:*" \
            --k3s-arg='--no-deploy=local-storage,metrics-server@server:*' \
            --kubeconfig-update-default \
            --kubeconfig-switch-context=false
    fi
    while [ $(kubectl --context="k3d-$cluster" get po -n kube-system -l k8s-app=kube-dns -o json |jq '.items | length') = "0" ]; do sleep 1 ; done
    kubectl --context="k3d-$cluster" wait pod --for=condition=ready \
        --namespace=kube-system --selector=k8s-app=kube-dns \
        --timeout=1m
done
