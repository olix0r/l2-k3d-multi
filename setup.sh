#!/bin/bash

set -eu
set -x

# Requires:
#
# - k3d v3: https://github.com/rancher/k3d/releases/tag/v3.0.0-beta.1
# - smallstep/cli: https://github.com/smallstep/cli/releases
# - linkerd:edge-20.5.3: https://github.com/linkerd/linkerd2/releases/tag/edge-20.5.3

## Clusters

org_domain="${ORG_DOMAIN:-k3d.example.com}"

PORT=6440
for cluster in east west ; do
    if k3d get cluster "$cluster" >/dev/null 2>&1 ; then
        echo "Already exists: $cluster" >&2
        exit 1
    fi

    port="$((PORT++))"
    k3d create cluster $cluster \
        --network=multicluster-example \
        --k3s-server-arg="--cluster-domain=$cluster.${org_domain}" \
        --wait \
        --api-port="$port"
done

# Load k3d contexts into kubectl.
k3d get kubeconfig east west

cadir=$(mktemp --tmpdir="${TMPDIR:-/tmp}" -d k3d-ca.XXXXX)

# Generate the trust roots. These never touch the cluster. In the real world
# we'd squirrel these away in a vault.
step certificate create \
    "identity.linkerd.${org_domain}" \
    "$cadir/ca.crt" "$cadir/ca.key" \
    --profile root-ca \
    --no-password  --insecure --force

for cluster in east west ; do
    domain="${cluster}.${org_domain}"
    ctx="k3d-${cluster}"

    # Check that the cluster is up and running.
    while ! linkerd --context="$ctx" check --pre ; do sleep 2 ; done

    # Create issuing credentials. These end up on the cluster (and can be
    # rotated from the root).
    crt="${cadir}/${cluster}-issuer.crt"
    key="${cadir}/${cluster}-issuer.key"
    step certificate create "identity.linkerd.${domain}" \
        "$crt" "$key" \
        --ca="$cadir/ca.crt" --ca-key="$cadir/ca.key" \
        --profile=intermediate-ca \
        --not-after 8760h --no-password --insecure --force

    # Install Linkerd into the cluster.
    linkerd --context="$ctx" install \
        --cluster-domain="$domain" \
        --identity-trust-domain="$domain" \
        --identity-trust-anchors-file="$cadir/ca.crt" \
        --identity-issuer-certificate-file="${crt}" \
        --identity-issuer-key-file="${key}" \
        | kubectl --context="$ctx" apply -f -

    # Wait some time and check that the cluster has started properly.
    sleep 20
    while ! linkerd --context="$ctx" check ; do sleep 2 ; done
done

# Setup a gateway on the remote cluster.
#
# We need to use alternate ports to avoid conflicting with k3d's traefik
# instance.
for cluster in east west ; do
    kubectl --context="k3d-$cluster" create ns linkerd-multicluster
    linkerd --context="k3d-$cluster" cluster setup-remote \
        --incoming-port=4180 \
        --probe-port=4181 \
        | kubectl --context="k3d-$cluster" apply -f -
done

# Generate credentials so the service-mirror can access west's service api.
#
# Unfortunately, the credentials have the API server IP as addressed from
# localhost and not the docker network, so we have to patch that up.
east_secret=$(linkerd --context=k3d-east cluster get-credentials \
     --cluster-name=east \
     --remote-cluster-domain="east.${org_domain}")
# Grab the LB IP of west's API server & replace it in the secret blob:
east_lb_ip=$(kubectl --context=k3d-east \
    get svc -n kube-system traefik \
    -o 'go-template={{ (index .status.loadBalancer.ingress 0).ip }}')
east_config=$(echo "$east_secret" \
    | sed -ne 's/^  kubeconfig: //p'  | base64 -d \
    | sed -e "s|https://0.0.0.0:7443|https://${east_lb_ip}:6443|"  | base64 -w0)

west_secret=$(linkerd --context=k3d-west cluster get-credentials \
     --cluster-name=west \
     --remote-cluster-domain="west.${org_domain}")
# Grab the LB IP of west's API server & replace it in the secret blob:
west_lb_ip=$(kubectl --context=k3d-west \
    get svc -n kube-system traefik \
    -o 'go-template={{ (index .status.loadBalancer.ingress 0).ip }}')
west_config=$(echo "$west_secret" \
    | sed -ne 's/^  kubeconfig: //p'  | base64 -d \
    | sed -e "s|https://0.0.0.0:7443|https://${west_lb_ip}:6443|"  | base64 -w0)

echo "$east_secret" \
    | sed -e "s/^  kubeconfig: .*/  kubeconfig: $east_config/" \
    | kubectl --context=k3d-west apply -n linkerd-multicluster -f -
linkerd --context=k3d-west install-service-mirror \
    --namespace=linkerd-multicluster \
    --log-level=debug \
    | kubectl --context=k3d-west apply -f -

echo "$west_secret" \
    | sed -e "s/^  kubeconfig: .*/  kubeconfig: $west_config/" \
    | kubectl --context=k3d-east apply -n linkerd-multicluster -f -
linkerd --context=k3d-east install-service-mirror \
    --namespace=linkerd-multicluster \
    --log-level=debug \
    | kubectl --context=k3d-east apply -f -
