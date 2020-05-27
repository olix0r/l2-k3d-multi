#!/bin/bash

# Creates three k3d clusters: dev, east, & west.
#

set -eu
set -x

export ORG_DOMAIN="${ORG_DOMAIN:-k3d.example.com}"

CA_DIR=$(mktemp --tmpdir="${TMPDIR:-/tmp}" -d k3d-ca.XXXXX)

# Generate the trust roots. These never touch the cluster. In the real world
# we'd squirrel these away in a vault.
step certificate create \
    "identity.linkerd.${ORG_DOMAIN}" \
    "$CA_DIR/ca.crt" "$CA_DIR/ca.key" \
    --profile root-ca \
    --no-password  --insecure --force

port=6440
for cluster in dev east west ; do
    if k3d get cluster "$cluster" >/dev/null 2>&1 ; then
        echo "Already exists: $cluster" >&2
        exit 1
    fi

    k3d create cluster "$cluster" \
        --network=multicluster-example \
        --k3s-server-arg="--cluster-domain=$cluster.${ORG_DOMAIN}" \
        --wait \
        --api-port="$((port++))"

    k3d get kubeconfig "$cluster"

    # Check that the cluster is up and running.
    while ! linkerd --context="k3d-$cluster" check --pre ; do :; done

    # Create issuing credentials. These end up on the cluster (and can be
    # rotated from the root).
    crt="${CA_DIR}/${cluster}-issuer.crt"
    key="${CA_DIR}/${cluster}-issuer.key"
    domain="${cluster}.${ORG_DOMAIN}"
    step certificate create "identity.linkerd.${domain}" \
        "$crt" "$key" \
        --ca="$CA_DIR/ca.crt" \
        --ca-key="$CA_DIR/ca.key" \
        --profile=intermediate-ca \
        --not-after 8760h --no-password --insecure

    # Install Linkerd into the cluster.
    linkerd --context="k3d-$cluster" install \
            --cluster-domain="$domain" \
            --identity-trust-domain="$domain" \
            --identity-trust-anchors-file="$CA_DIR/ca.crt" \
            --identity-issuer-certificate-file="${crt}" \
            --identity-issuer-key-file="${key}" |
        kubectl --context="k3d-$cluster" apply -f -

    # Wait some time and check that the cluster has started properly.
    sleep 30
    while ! linkerd --context="k3d-$cluster" check ; do :; done

    kubectl --context="k3d-$cluster" create ns linkerd-multicluster
    kubectl --context="k3d-$cluster" annotate ns/linkerd-multicluster \
        config.linkerd.io/proxy-version='ver-prevent-loop.0'

    # Setup the multicluster components on the server
    linkerd --context="k3d-$cluster" multicluster install --log-level=debug |
        kubectl --context="k3d-$cluster" apply -f -

done
