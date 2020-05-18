#!/bin/sh

set -eux

# Requires:
#
# - k3d v3: https://github.com/rancher/k3d/releases/tag/v3.0.0-beta.1
# - smallstep/cli: https://github.com/smallstep/cli/releases
# - linkerd:edge-20.5.3: https://github.com/linkerd/linkerd2/releases/tag/edge-20.5.3

## Clusters

for cluster in multi0 multi1 ; do
    if k3d get cluster "$cluster" >/dev/null 2>&1 ; then
        k3d delete cluster "$cluster"
    fi
done

org_domain="${ORG_DOMAIN:-k3d.olix0r.net}"

# Start two clusters in k3d, each serving on a different localhost port.
k3d create cluster multi0 --wait \
    --network k3d-multi \
    --k3s-server-arg="--cluster-domain=multi0.${org_domain}" \
    -a 6443
k3d create cluster multi1 --wait \
    --network k3d-multi \
    --k3s-server-arg="--cluster-domain=multi1.${org_domain}" \
    -a 7443
   
# if CLEANUP is set, delete everything when the script completes.
if [ -n "${CLEANUP:-}" ]; then
    trap '{ k3d delete cluster multi0 multi1 ; }' EXIT
fi

# Load k3d contexts into kubectl.
k3d get kubeconfig multi0 multi1

cadir=$(mktemp -d multicluster.XXXXX)

# Generate the trust roots. These never touch the cluster. In the real world
# we'd squirrel these away in a vault.
step certificate create \
    "identity.linkerd.${org_domain}" \
    "$cadir/ca.crt" "$cadir/ca.key" \
    --profile root-ca \
    --no-password  --insecure --force

for cluster in multi0 multi1 ; do
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
        --ca=ca.crt --ca-key=ca.key \
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
kubectl --context=k3d-multi1 create ns linkerd-multicluster
kubectl --context=k3d-multi1 annotate ns linkerd-multicluster \
    'config.linkerd.io/proxy-log-level=linkerd=debug,warn'
linkerd --context=k3d-multi1 cluster setup-remote \
    --incoming-port=4180 \
    --probe-port=4181 \
    | kubectl --context=k3d-multi1 apply -f -

# Create a local service-mirror namespace.
kubectl --context=k3d-multi0 create ns linkerd-multicluster
kubectl --context=k3d-multi0 annotate ns linkerd-multicluster
    'linkerd.io/inject=enabled' \
    'config.linkerd.io/proxy-log-level=linkerd=trace,warn'

# Generate credentials so the service-mirror can access multi1's service api.
#
# Unfortunately, the credentials have the API server IP as addressed from
# localhost and not the docker network, so we have to patch that up.
secret1=$(linkerd --context=k3d-multi1 cluster get-credentials \
     --cluster-name=multi1 \
     --remote-cluster-domain="multi1.${org_domain}")
# Grab the LB IP of multi1's API server & replace it in the secret blob:
lbip1=$(kubectl --context=k3d-multi1 \
    get svc -n kube-system traefik \
    -o 'go-template={{ (index .status.loadBalancer.ingress 0).ip }}')
kubeconfig1=$(echo "$secret1" \
    | sed -ne 's/^  kubeconfig: //p'  | base64 -d \
    | sed -e "s|https://0.0.0.0:7443|https://${lbip1}:6443|"  | base64 -w0)
echo "$secret1" \
    | sed -e "s/^  kubeconfig: .*/  kubeconfig: $kubeconfig1/" \
    | kubectl --context=k3d-multi0 apply -n linkerd-multicluster -f -
linkerd --context=k3d-multi0 install-service-mirror \
    --namespace=linkerd-multicluster \
    --log-level=debug \
    | kubectl --context=k3d-multi0 apply -f -

# Create the services in both clusters.
for ctx in k3d-multi0 k3d-multi1 ; do
    linkerd --context="$ctx" inject example-servers.yml \
        | kubectl --context="$ctx" apply -f -
    #kubectl --context=k3d-multi0 annotate ns example \
    #    'config.linkerd.io/proxy-log-level=linkerd=debug,warn'
done

# Export the services from multi1 to multi0
kubectl --context=k3d-multi1 get -n multicluster-test svc -o yaml \
    | linkerd cluster export-service - \
    | kubectl --context=k3d-multi1 apply -f -

# Check that the services are mirrored into multi0
sleep 1
kubectl --context=k3d-multi0 get -n example svc -o wide
kubectl --context=k3d-multi0 get -n example ep -o wide \
    http-multi1  grpc-multi1

kubectl --context=k3d-multi0 apply -f - <<EOF
--
apiVersion: split.smi-spec.io/v1alpha1
kind: TrafficSplit
metadata:
    name: http
spec:
    service: http
    backends:
        - service: http
          weight: 500m
        - service: http-multi1
          weight: 500m
--
apiVersion: split.smi-spec.io/v1alpha1
kind: TrafficSplit
metadata:
    name: grpc
spec:
    service: grpc
    backends:
        - service: grpc
          weight: 500m
        - service: gprc-multi1
          weight: 500m
EOF

kubectl --context=k3d-multi0 run \
    --image=buoyantio/bb:v0.0.5 \
    
