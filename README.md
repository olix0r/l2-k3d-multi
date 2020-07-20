# Linkerd2 Multi-Cluster Demo

This demo uses Linkerd's new multicluster functionality to demonstrate
failover & traffic-splitting in a multi-cluster mesh of Kubernetes clusters.

- [`k3d:v3`](https://github.com/rancher/k3d/releases/tag/v3.0.0-beta.1)
- [`smallstep/cli`](https://github.com/smallstep/cli/releases)
- [`linkerd:edge-20.5.3`+](https://github.com/linkerd/linkerd2/releases)
- [`kubectl 1.16`+](https://github.com/kubernetes/kubectl/releases)

[`./create.sh`](./create.sh) initializes a temporary CA and a set of clusters
in `k3d`: _dev_, _east_, and _west_.

We can then install the [app](https://github.com/BuoyantIO/emojivoto/) into
the _east_ and _west_ clusters:

```sh
:; kubectl --context=k3d-east apply -k east
:; kubectl --context=k3d-west apply -k west
```

These clusters operate independently by default.

[`./link.sh`](./link.sh) configures linkerd-multicluster gateways & service
mirrors on each cluster. _east_ and _west_ are configured to discover
services from each other. _dev_ is only configured run the _web_ and
_vote-bot_ components, and it discovers other services from both _east_ and
_west_.

At this point, we can start our _dev_ setup which uses the voting and emoji
services in the _east_ and _west_ clusters:

```sh
:; kubectl --context=k3d-dev apply -k dev
```

We can also route traffic between the _east_ and _west_ clusters.
See the commented sections in
[`./east/kustomization.yml`](./east/kustomization.yml) and
[`./west/kustomization.yml`](./west/kustomization.yml). These configurations
can be modified to reroute traffic between clusters!
