#!/bin/bash
# ==============================================================================
# Script: build_prereqs.sh
# Purpose: Downloads all offline dependencies for a true Dark Site NKP Bastion.
#          Run this on an internet-connected machine matching your Bastion's OS.
# ==============================================================================
set -euo pipefail

BUNDLE_DIR="nkp-prereqs-bundle"
mkdir -p "${BUNDLE_DIR}/packages" "${BUNDLE_DIR}/binaries" "${BUNDLE_DIR}/harbor"

if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; else echo "Unsupported OS."; exit 1; fi

echo "=== 1. Downloading Binaries (kubectl, gum, & helm) ==="
# Download kubectl
curl -sSL -o "${BUNDLE_DIR}/binaries/kubectl" "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x "${BUNDLE_DIR}/binaries/kubectl"

# Download Gum UI standalone binary
GUM_VERSION="0.13.0"
curl -sSL "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_x86_64.tar.gz" | tar -xz -C "${BUNDLE_DIR}/binaries/" gum
chmod +x "${BUNDLE_DIR}/binaries/gum"

# Download Helm standalone binary
HELM_VERSION="v3.15.1"
echo "Downloading Helm ${HELM_VERSION}..."
curl -sSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C "${BUNDLE_DIR}/binaries/" --strip-components=1 linux-amd64/helm
chmod +x "${BUNDLE_DIR}/binaries/helm"

echo "=== 2. Downloading Enterprise Harbor (Offline Installer) ==="
HARBOR_VERSION="v2.10.3"
echo "Downloading Harbor ${HARBOR_VERSION} (This is ~700MB, please wait)..."
curl -sSL -o "${BUNDLE_DIR}/harbor/harbor-offline-installer-${HARBOR_VERSION}.tgz" "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-offline-installer-${HARBOR_VERSION}.tgz"

echo "=== 3. Downloading OS Packages (Offline Installers) ==="
if [[ "$OS" =~ ^(ubuntu|debian)$ ]]; then
    sudo apt-get update -y -qq
    sudo apt-get install -y -qq apt-transport-https ca-certificates curl software-properties-common
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg || true
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update -y -qq
    
    cd "${BUNDLE_DIR}/packages"
    sudo apt-get download docker-ce docker-ce-cli containerd.io docker-compose-plugin socat conntrack || true
    cd ../..

elif [[ "$OS" =~ ^(rhel|centos|rocky)$ ]]; then
    sudo yum install -y -q yum-utils
    sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo > /dev/null
    
    cd "${BUNDLE_DIR}/packages"
    sudo yumdownloader --resolve --quiet --destdir=. docker-ce docker-ce-cli containerd.io docker-compose-plugin socat conntrack
    cd ../..
fi

echo "=== 4. Packaging the Bundle ==="
tar -czvf "nkp-prereqs-bundle.tar.gz" "${BUNDLE_DIR}"
rm -rf "${BUNDLE_DIR}"

echo ""
echo "✅ SUCCESS! Your offline prerequisites bundle is ready: nkp-prereqs-bundle.tar.gz"
echo "Transfer this file, along with the main NKP bundle, to your Dark Site Bastion."