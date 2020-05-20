#!/bin/sh

set -eu
set -x

kubectl --context=k3d-east kustomize ./east |
    linkerd --context=k3d-east inject - |
    linkerd --context=k3d-east cluster export-service - --gateway-namespace=linkerd-multicluster |
    kubectl --context=k3d-east apply -f -

kubectl --context=k3d-west kustomize ./west |
    linkerd --context=k3d-west inject - |
    linkerd --context=k3d-west cluster export-service - --gateway-namespace=linkerd-multicluster |
    kubectl --context=k3d-west apply -f -
