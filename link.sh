#!/bin/sh

export ORG_DOMAIN="${ORG_DOMAIN:-k3d.example.com}"

# Generate credentials so the service-mirror
#
# Unfortunately, the credentials have the API server IP as addressed from
# localhost and not the docker network, so we have to patch that up.
fetch_credentials() {
    cluster="$1"
    # Grab the LB IP of cluster's API server & replace it in the secret blob:
    lb_ip=$(kubectl --context="k3d-$cluster" get svc -n kube-system traefik \
        -o 'go-template={{ (index .status.loadBalancer.ingress 0).ip }}')
    
    # shellcheck disable=SC2001  
    echo "$(linkerd --context="k3d-$cluster" multicluster link \
            --cluster-name="$cluster" \
            --api-server-address="https://${lb_ip}:6443")"
}

# East & West get access to each other.
fetch_credentials east | kubectl --context=k3d-west apply -n linkerd-multicluster -f -
fetch_credentials west | kubectl --context=k3d-east apply -n linkerd-multicluster -f -

# Dev gets access to both clusters.
fetch_credentials east | kubectl --context=k3d-dev apply -n linkerd-multicluster -f -
fetch_credentials west | kubectl --context=k3d-dev apply -n linkerd-multicluster -f -
