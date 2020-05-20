# Linkerd2 Multi-Cluster Demo

This demo uses Linkerd's new multicluster functionality to demonstrate
failover & traffic-splitting in a multi-cluster mesh of Kubernetes clusters.

- [`k3d:v3`](https://github.com/rancher/k3d/releases/tag/v3.0.0-beta.1)
- [`smallstep/cli`](https://github.com/smallstep/cli/releases)
- [`linkerd:edge-20.5.3`+](https://github.com/linkerd/linkerd2/releases)

[`./setup.sh`](./setup.sh) initializes a temporary CA and a pair of clusters
in `k3d`: _east_ and _west_.

Then, deploy the [emojivoto](https://github.com/BuoyantIO/emojivoto/) app to each cluster:

```sh
:; kubectl --context=k3d-east apply -k east
:; kubectl --context=k3d-west apply -k west
```

Then, note that [`./east/kustomization.yml`](./east/kustomization.yml) and
[`./west/kustomization.yml`](./west/kustomization.yml) have commented
sections disabling traffic shifts between clusters. Uncomment these to move
traffic between clusters!
