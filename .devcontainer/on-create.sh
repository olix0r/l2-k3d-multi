#!/usr/bin/env bash

set -euo pipefail

mkdir -p ~/bin

scurl https://run.linkerd.io/install-edge | sh
scurl https://linkerd.github.io/linkerd-smi/install | sh
ln -s ~/.linkerd2/bin/linkerd* ~/bin
