#!/bin/bash

# Creates three k3d clusters: dev, east, & west.
#

set -eu
set -x

export ORG_DOMAIN="${ORG_DOMAIN:-k3d.example.com}"

if ! command -v linkerd &>/dev/null
then
    echo "Install Linkerd with the command"
    echo "curl -sL https://run.linkerd.io/install | sh"
    exit 1
fi

case $(uname) in
	Darwin)
		# host_platform=darwin
        CA_DIR=$(mktemp -d k3d-ca.XXXXX)
		;;
	Linux)
		# host_platform=linux
        CA_DIR=$(mktemp --tmpdir="${TMPDIR:-/tmp}" -d k3d-ca.XXXXX)
		;;
	*)
		echo "Unknown operating system: $(uname)"
        exit 1
		;;
esac

# Generate the trust roots. These never touch the cluster. In the real world
# we'd squirrel these away in a vault.
step certificate create \
    "identity.linkerd.${ORG_DOMAIN}" \
    "$CA_DIR/ca.crt" "$CA_DIR/ca.key" \
    --profile root-ca \
    --no-password  --insecure --force

port=6440
for cluster in dev east west ; do
    if k3d cluster get "$cluster" >/dev/null 2>&1 ; then
        echo "Already exists: $cluster" >&2
        exit 1
    fi

    k3d cluster create "$cluster" \
        --api-port="$((port++))" \
        --network=multicluster-example \
        --k3s-server-arg="--cluster-domain=$cluster.${ORG_DOMAIN}" \
        --wait

    k3d kubeconfig get "$cluster"

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

    # kubectl --context="k3d-$cluster" create ns linkerd-multicluster
    # kubectl --context="k3d-$cluster" annotate ns/linkerd-multicluster \
    #     config.linkerd.io/proxy-image='olix0r/l2-proxy' \
    #     config.linkerd.io/proxy-log-level='linkerd=debug,warn' \
    #     config.linkerd.io/proxy-version='ver-gateway-no-cache.2'
    # k3d load image -c "$cluster" olix0r/l2-proxy:ver-gateway-no-cache.1
    # sleep 2

    # Setup the multicluster components on the server
    linkerd --context="k3d-$cluster" multicluster install |
        kubectl --context="k3d-$cluster" apply -f -

done
