#!/bin/bash
# ==============================================================================
# Script: 04_install_kommander.sh
# Purpose: Install Kommander platform services and the inbuilt Harbor registry
#          using a clean YAML override and the local air-gapped bundle.
# ==============================================================================

set -euo pipefail

# ==============================================================================
# STEP 1: PRE-FLIGHT CHECKS & HANDOFFS
# ==============================================================================
if [ -f ".nkp_version.env" ]; then
    source .nkp_version.env
else
    gum style --foreground 196 "❌ ERROR: .nkp_version.env not found. Please run Phase 1 first."
    exit 1
fi

export PATH="$PWD/nkp-${NKP_VERSION}/cli:$PATH"

gum style --border double --margin "1" --padding "1 2" --border-foreground 212 "NKP Phase 4: Management Plane & Harbor Installation (v${NKP_VERSION})"

gum style --foreground 99 -- "--- Cluster Handoff ---"
if [ -f ".nkp_cluster.env" ]; then
    source .nkp_cluster.env
    gum style --foreground 82 "✔ Found .nkp_cluster.env! Auto-populating Cluster Name: ${CLUSTER_NAME}"
else
    export CLUSTER_NAME=$(gum input --prompt "Enter your Cluster Name: " --value "nkp-prod-01")
fi

export KUBECONFIG="${CLUSTER_NAME}.conf"

if [ ! -f "${KUBECONFIG}" ]; then
    gum style --foreground 196 "❌ ERROR: Kubeconfig file (${KUBECONFIG}) not found."
    exit 1
fi

APP_BUNDLE="./nkp-${NKP_VERSION}/application-repositories/kommander-applications-${NKP_VERSION}.tar.gz"
if [ ! -f "${APP_BUNDLE}" ]; then
    gum style --foreground 196 "❌ ERROR: Application bundle not found at ${APP_BUNDLE}."
    exit 1
fi

# ==============================================================================
# STEP 2: GENERATE OVERRIDE YAML (Automated Certificate Trust)
# ==============================================================================
gum style --foreground 240 "Creating minimal Kommander override configuration for Harbor & Air-Gapped mode..."

export REGISTRY_CA="/opt/registry/certs/domain.crt"

if [ ! -f "${REGISTRY_CA}" ]; then
    gum style --foreground 196 "❌ ERROR: Local registry certificate authority not found at ${REGISTRY_CA}."
    exit 1
fi

# Format and indent the local registry CA file for direct YAML string injection
REGISTRY_CA_CONTENT=$(sed 's/^/    /' "${REGISTRY_CA}")

cat <<EOF > kommander.yaml
apiVersion: config.kommander.mesosphere.io/v1alpha1
kind: Installation
airgapped:
  enabled: true
# Dynamically register the local CA natively so Flux can execute direct secure handshakes
containerRegistry:
  caCert: |
${REGISTRY_CA_CONTENT}
apps:
  kube-prometheus-stack:
    enabled: true
  cloudnative-pg:
    enabled: true
  harbor:
    enabled: true
EOF

# ==============================================================================
# STEP 3: EXECUTE INSTALLATION
# ==============================================================================
gum style --foreground 212 -- "--- Deploying Platform Services ---"
gum style --foreground 240 "Installing Kommander with Harbor Registry enabled (Streaming logs below)..."
echo "------------------------------------------------------------------------------"

if ! nkp install kommander \
  --installer-config kommander.yaml \
  --kubeconfig="${KUBECONFIG}" \
  --kommander-applications-repository "${APP_BUNDLE}"; then
    echo "------------------------------------------------------------------------------"
    gum style --foreground 196 "❌ ERROR: Kommander installation failed! Check the logs above."
    exit 1
fi

echo "------------------------------------------------------------------------------"

# Wrap the final readiness wait in a clean UI spinner
gum spin --spinner dot --title "Waiting for Kommander helm releases to be ready (Timeout: 20m)..." -- kubectl -n kommander wait --for condition=Ready helmreleases --all --timeout 20m

# ==============================================================================
# STEP 4: RETRIEVE CREDENTIALS & URLS
# ==============================================================================
gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "🎉 SUCCESS: Kommander and Harbor installation complete!"

gum style --foreground 99 -- "--- NKP UI Details ---"
echo "URL: $(kubectl -n kommander get svc kommander-traefik -o go-template='https://{{with index .status.loadBalancer.ingress 0}}{{or .hostname .ip}}{{end}}/dkp/kommander/dashboard{{ "\n"}}')"
echo "Credentials:"
kubectl -n kommander get secret dkp-credentials -o go-template='Username: {{.data.username|base64decode}}{{ "\n"}}Password: {{.data.password|base64decode}}{{ "\n"}}'

echo ""
gum style --foreground 99 -- "--- Harbor Registry Details ---"
echo "Harbor URL: https://$(kubectl -n kommander get kommandercluster host-cluster -o jsonpath='{.status.ingress.address}'):5000"
echo "Harbor Admin Password: $(kubectl get secrets -n ncr-system harbor-admin-password -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d)"
echo ""