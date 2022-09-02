# Linkerd2 Multi-Cluster Demo

This demo uses Linkerd's new multicluster functionality to demonstrate
failover & traffic-splitting in a multi-cluster mesh of Kubernetes clusters.

- [`k3d:v5`](https://github.com/rancher/k3d/releases/tag/v5.4.4)
- [`smallstep/cli`](https://github.com/smallstep/cli/releases)
- [`linkerd:stable-2.12.0`+](https://github.com/linkerd/linkerd2/releases)
- A [devcontainer](https://code.visualstudio.com/docs/remote/containers) is
  included with the needed tools.

[`./create.sh`](./create.sh) initializes a set of clusters in `k3d`: _dev_,
_east_, and _west_.

[`./install.sh`](./install.sh) creates a temporary CA and installs Linkerd
into these clusters.

We can then deploy the [app](https://github.com/BuoyantIO/emojivoto/) into
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
