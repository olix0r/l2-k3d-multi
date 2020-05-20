#!/bin/bash

set -eu
set -x

# Requires:
#
# - k3d v3: https://github.com/rancher/k3d/releases/tag/v3.0.0-beta.1
# - smallstep/cli: https://github.com/smallstep/cli/releases
# - linkerd:edge-20.5.3: https://github.com/linkerd/linkerd2/releases/tag/edge-20.5.3

## Clusters

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
for cluster in east west ; do
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

    # Setup a gateway on the remote cluster.
    kubectl --context="k3d-$cluster" create ns linkerd-multicluster
    linkerd --context="k3d-$cluster" cluster setup-remote \
            --gateway-namespace=linkerd-multicluster \
            --service-account-namespace=linkerd-multicluster \
            --incoming-port=4180 \
            --probe-port=4181 |
        kubectl --context="k3d-$cluster" apply -f -

    linkerd --context="k3d-$cluster" install-service-mirror \
            --namespace=linkerd-multicluster \
            --log-level=debug |
        kubectl --context="k3d-$cluster" apply -f -
done

# Generate credentials so the service-mirror
#
# Unfortunately, the credentials have the API server IP as addressed from
# localhost and not the docker network, so we have to patch that up.
fetch_credentials() {
    cluster="$1"
    # Grab the LB IP of cluster's API server & replace it in the secret blob:
    lb_ip=$(kubectl --context="k3d-$cluster" get svc -n kube-system traefik \
        -o 'go-template={{ (index .status.loadBalancer.ingress 0).ip }}')
    secret=$(linkerd --context="k3d-$cluster" cluster get-credentials \
            --cluster-name="$cluster" \
            --remote-cluster-domain="${cluster}.${ORG_DOMAIN}" \
            --service-account-namespace=linkerd-multicluster)
    config=$(echo "$secret" |
        sed -ne 's/^  kubeconfig: //p' | base64 -d |
        sed -Ee "s|server: https://.*|server: https://${lb_ip}:6443|" | base64 -w0)
    # shellcheck disable=SC2001
    echo "$secret" | sed -e "s/  kubeconfig: .*/  kubeconfig: $config/"
}

fetch_credentials east | kubectl --context=k3d-west apply -n linkerd-multicluster -f -
fetch_credentials west | kubectl --context=k3d-east apply -n linkerd-multicluster -f -
