#!/bin/sh

export ORG_DOMAIN="${ORG_DOMAIN:-k3d.example.com}"

for cluster in dev east west ; do
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

# East & West get access to each other.
fetch_credentials east | kubectl --context=k3d-west apply -n linkerd-multicluster -f -
fetch_credentials west | kubectl --context=k3d-east apply -n linkerd-multicluster -f -

# Dev gets access to both clusters.
fetch_credentials east | kubectl --context=k3d-dev apply -n linkerd-multicluster -f -
fetch_credentials west | kubectl --context=k3d-dev apply -n linkerd-multicluster -f -
