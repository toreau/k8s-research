#!/usr/bin/env bash
# app-onboard: scaffold a new app into the GitOps repo (apps/<name>/ + ArgoCD
# Application). Usage (see `make app-onboard`):
#   scripts/app-onboard.sh NAME IMAGE HOST PORT REPO [BUILD_TYPE] [ATTESTATION]
# NAME=app dir name, IMAGE=full pinned ref (…@sha256:<hex>), HOST=ingress host,
# PORT=container port, REPO=<owner>/<app-repo>, BUILD_TYPE=static|dotnet,
# ATTESTATION=true|false.
set -euo pipefail

NAME=$1
IMAGE=$2
HOST=$3
PORT=$4
REPO=$5
BUILD_TYPE=${6:-static}
ATTESTATION=${7:-false}

BASE="${IMAGE%%@*}"
DIR="apps/$NAME"

[ -e "$DIR" ] && { echo "error: $DIR already exists"; exit 1; }
[ -e "argocd/apps/$NAME.yaml" ] && { echo "error: argocd/apps/$NAME.yaml already exists"; exit 1; }

mkdir -p "$DIR/infra"

cat > "$DIR/meta.yaml" <<EOF
app:
  name: $NAME
  repo: $REPO
  image: $BASE
  digestFiles:
    - apps/$NAME/app.yaml
  hosts:
    - $HOST
  port: $PORT
  buildType: $BUILD_TYPE
  attestation: $ATTESTATION
EOF

cat > "$DIR/app.yaml" <<EOF
apiVersion: skiperator.kartverket.no/v1alpha1
kind: Application
metadata:
  name: $NAME
  namespace: $NAME
spec:
  image: $IMAGE
  port: $PORT
  ingresses:
    - $HOST
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
EOF

cat > "$DIR/infra/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NAME
EOF

if [ "$ATTESTATION" = "true" ]; then
  # Enforce SLSA attestations at admission for this app's namespace (the
  # trust-policies ClusterImagePolicy applies where this label is present).
  sed -i '' '/^metadata:/a\
  labels:\
    policy.sigstore.dev/include: "true"' "$DIR/infra/namespace.yaml"
fi

cat > "argocd/apps/$NAME.yaml" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $NAME
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/toreau/k8s-research.git
    targetRevision: HEAD
    path: apps/$NAME
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

echo "generated: $DIR/{meta.yaml,app.yaml,infra/namespace.yaml} argocd/apps/$NAME.yaml"
