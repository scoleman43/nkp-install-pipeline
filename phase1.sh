#!/bin/bash
# ==============================================================================
# Script: phase1.sh
# Purpose: Prepares Bastion Host, configures Proxy OR Offline Bundle, automates 
#          'gum' UI, generates SSH keys, and installs Enterprise Harbor Registry.
# Architecture: Smart & Idempotent. Instantly skips re-installation if run again.
# ==============================================================================

set -euo pipefail

export TERM="xterm-256color"
export REGISTRY_PORT="5000"
export REGISTRY_CERTS_DIR="/opt/registry/certs"
export HARBOR_VERSION="v2.10.3"

REGISTRY_IP=$(hostname -I | awk '{print $1}')
export REGISTRY_IP
export REGISTRY_URL="${REGISTRY_IP}:${REGISTRY_PORT}"

# shellcheck disable=SC1091
if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; else echo "Unsupported OS."; exit 1; fi

echo "Please authenticate sudo so we can configure the system uninterrupted:"
sudo -v

# ==============================================================================
# STEP 0: SMART RERUN / IDEMPOTENCY CHECK
# ==============================================================================
# If gum and kubectl are already installed, we completely skip the extraction 
# and package install loop, saving time on a rerun.
if command -v gum &> /dev/null && command -v kubectl &> /dev/null; then
    echo "✔ Prerequisites already installed on this Bastion. Booting UI mode instantly..."
    export INSTALL_MODE="dark"  # Default to dark for the UI reload path if offline
    if [ ! -f ".nkp_registry.env" ]; then
        # If cache doesn't exist yet, we still need to establish basic mode detection
        if [ ! -f "nkp-prereqs-bundle.tar.gz" ]; then export INSTALL_MODE="internet"; fi
    else
        exec bash "$0" --triggered-by-reload
        exit 0
    fi
fi

if [ -z "${INSTALL_MODE:-}" ] && [ "${1:-}" != "--triggered-by-reload" ]; then
    echo "--- Select Bastion Installation Mode ---"
    echo "1) Internet-Based (Direct or via Corporate Proxy)"
    echo "2) Dark Site / Air-Gapped (Requires 'nkp-prereqs-bundle.tar.gz')"
    
    read -r -p "Select Mode (1 or 2): " MODE_SELECTION
    
    if [ "$MODE_SELECTION" == "2" ]; then
        export INSTALL_MODE="dark"
        export USE_PROXY="false"
        
        if [ ! -f "nkp-prereqs-bundle.tar.gz" ]; then
            echo "❌ ERROR: 'nkp-prereqs-bundle.tar.gz' not found in current directory."
            exit 1
        fi
        
        echo "Extracting offline prerequisites bundle..."
        tar -xzf nkp-prereqs-bundle.tar.gz
        
        echo "Installing offline binaries..."
        sudo cp nkp-prereqs-bundle/binaries/kubectl /usr/local/bin/kubectl
        sudo cp nkp-prereqs-bundle/binaries/gum /usr/local/bin/gum
        
        echo "Installing offline OS packages..."
        if [[ "$OS" =~ ^(ubuntu|debian)$ ]]; then
            sudo dpkg -i nkp-prereqs-bundle/packages/*.deb || true
            sudo apt-get install -f -y || true 
        elif [[ "$OS" =~ ^(rhel|centos|rocky)$ ]]; then
            sudo rpm -Uvh --force --nodeps nkp-prereqs-bundle/packages/*.rpm
        fi

    elif [ "$MODE_SELECTION" == "1" ]; then
        export INSTALL_MODE="internet"
        
        echo "--- Checking Network / Proxy Requirements ---"
        if [ -z "${http_proxy:-}" ]; then
            read -r -p "Do you need to configure a proxy for outbound internet access? (y/N): " needs_proxy
            if [[ "$needs_proxy" =~ ^[Yy] ]]; then
                export USE_PROXY="true"
                read -r -p "Proxy URL (e.g., http://proxy.corp.local:3128): " PROXY_URL
                read -r -p "NO_PROXY list (default: 127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/16): " NO_PROXY_INPUT
                export PROXY_URL="${PROXY_URL}"
                export NO_PROXY="${NO_PROXY_INPUT:-127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/16}"
            else
                export USE_PROXY="false"
            fi
        else
            export USE_PROXY="true"
            export PROXY_URL="${http_proxy}"
            read -r -p "NO_PROXY list (default: 127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/16): " NO_PROXY_INPUT
            export NO_PROXY="${NO_PROXY_INPUT:-127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/16}"
        fi

        if [ "${USE_PROXY}" == "true" ]; then
            export http_proxy="${PROXY_URL}"; export https_proxy="${PROXY_URL}"; export no_proxy="${NO_PROXY}"
            export HTTP_PROXY="${PROXY_URL}"; export HTTPS_PROXY="${PROXY_URL}"; export NO_PROXY="${NO_PROXY}"
            if [[ "$OS" =~ ^(ubuntu|debian)$ ]]; then
                echo "Acquire::http::Proxy \"${PROXY_URL}\";" | sudo tee /etc/apt/apt.conf.d/proxy.conf > /dev/null
                echo "Acquire::https::Proxy \"${PROXY_URL}\";" | sudo tee -a /etc/apt/apt.conf.d/proxy.conf > /dev/null
            elif [[ "$OS" =~ ^(rhel|centos|rocky)$ ]]; then
                grep -q "^proxy=" /etc/yum.conf || echo "proxy=${PROXY_URL}" | sudo tee -a /etc/yum.conf
            fi
        fi
        
        if ! command -v gum &> /dev/null; then
            echo "--- Preparing the Installer UI ---"
            if [[ "$OS" =~ ^(ubuntu|debian)$ ]]; then
                sudo apt-get update -y -qq && sudo apt-get install -y -qq curl gnupg
                sudo mkdir -p /etc/apt/keyrings
                curl -fsSL https://repo.charm.sh/apt/gpg.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/charm.gpg
                echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | sudo tee /etc/apt/sources.list.d/charm.list > /dev/null
                sudo apt-get update -y -qq && sudo apt-get install -y -qq gum
            elif [[ "$OS" =~ ^(rhel|centos|rocky)$ ]]; then
                sudo yum install -y -q curl
                echo '[charm]
name=Charm
baseurl=https://repo.charm.sh/yum/
enabled=1
gpgcheck=1
gpgkey=https://repo.charm.sh/yum/gpg.key' | sudo tee /etc/yum.repos.d/charm.repo > /dev/null
                sudo yum install -y -q gum
            fi
        fi
    else
        echo "Invalid selection."
        exit 1
    fi
    
    if command -v gum &> /dev/null; then
        echo "Dependencies installed successfully. Reloading script into UI mode..."
        sleep 1.5
        clear
        exec bash "$0" --triggered-by-reload
    else
        echo "ERROR: Failed to initialize 'gum' UI."
        exit 1
    fi
fi

# Determine install mode state if reloaded directly
if [ -f "nkp-prereqs-bundle.tar.gz" ]; then export INSTALL_MODE="dark"; else export INSTALL_MODE="internet"; fi

# ==============================================================================
# STEP 1: INTERACTIVE CONFIGURATION (Powered by Gum)
# ==============================================================================
gum style --border double --margin "1" --padding "1 2" --border-foreground 212 "NKP Phase 1: Bastion Host & Harbor Registry Setup"

if [ "${INSTALL_MODE}" == "dark" ]; then
    export DOWNLOAD_BUNDLE="false"
    gum style --foreground 240 "Dark Site Mode Active: Skipping Internet Downloads."
else
    gum style --foreground 99 -- "--- Air-Gapped Bundle Configuration ---"
    DOWNLOAD_BUNDLE=$(gum choose --header "Do you want to automatically download the NKP air-gapped bundle?" "Yes" "No (I already uploaded it)")
fi

if [ "$DOWNLOAD_BUNDLE" == "Yes" ]; then
    export DOWNLOAD_BUNDLE="true"
    gum style --foreground 212 "Presigned URL:"
    read -r BUNDLE_URL
    export BUNDLE_URL="${BUNDLE_URL}"
    
    NKP_VERSION=$(echo "${BUNDLE_URL}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?' | head -n 1 || true)
    export NKP_VERSION
    
    if [ -z "$NKP_VERSION" ]; then
        NKP_VERSION=$(gum input --prompt "Version not found in URL. Enter NKP Version: " --value "v2.17.1")
        export NKP_VERSION
    fi
    export BUNDLE_ARCHIVE="nkp-air-gapped-bundle_${NKP_VERSION}_linux_amd64.tar.gz"
    gum style --foreground 82 "✔ Auto-detected Version: ${NKP_VERSION}"
else
    export DOWNLOAD_BUNDLE="false"
    
    BUNDLE_ARCHIVE=$(ls nkp-air-gapped-bundle_v*_linux_amd64.tar.gz 2>/dev/null | head -n 1 || true)
    export BUNDLE_ARCHIVE
    
    if [ -z "${BUNDLE_ARCHIVE}" ] || [ ! -f "${BUNDLE_ARCHIVE}" ]; then
        gum style --foreground 196 "❌ ERROR: Missing Nutanix NKP Software Bundle!"
        gum style --foreground 226 "Please download the official 'nkp-air-gapped-bundle_vX.X.X_linux_amd64.tar.gz' from the Nutanix Portal and place it in this directory alongside your prereqs bundle."
        exit 1
    fi
    
    NKP_VERSION=$(echo "${BUNDLE_ARCHIVE}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?' | head -n 1 || true)
    export NKP_VERSION
    
    gum style --foreground 82 "✔ Detected local bundle: ${BUNDLE_ARCHIVE} (${NKP_VERSION})"
fi

# Harbor Password Prompt
export REGISTRY_USER="admin"
gum style --foreground 99 -- "--- Harbor Administrator Setup ---"
export REGISTRY_PASS=$(gum input --password --prompt "Create Harbor Admin Password (Must contain upper, lower, number): " --placeholder "Harbor12345!")

echo "export NKP_VERSION=\"${NKP_VERSION}\"" > .nkp_version.env
echo "export BUNDLE_ARCHIVE=\"${BUNDLE_ARCHIVE}\"" >> .nkp_version.env
{
    echo "export REGISTRY_URL=\"${REGISTRY_URL}\""
    echo "export REGISTRY_USER=\"${REGISTRY_USER}\""
    echo "export REGISTRY_PASS=\"${REGISTRY_PASS}\""
    echo "export REGISTRY_CA=\"${REGISTRY_CERTS_DIR}/domain.crt\""
} > .nkp_registry.env

# ==============================================================================
# STEP 2: SYSTEM INSTALLATION & PREPARATION
# ==============================================================================
gum style --foreground 212 -- "--- Beginning System Configuration ---"

# Install Docker and core dependencies if in internet mode
if [ "${INSTALL_MODE}" == "internet" ]; then
    gum style --foreground 240 "Installing OS Prerequisites (Kubectl, Docker, Docker-Compose, Tools)..."
    if [[ "$OS" =~ ^(rhel|centos|rocky)$ ]]; then
        sudo yum install -y -q yum-utils bzip2 wget curl openssl tar socat conntrack
        cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo > /dev/null
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-\$basearch
enabled=1
gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF
        sudo yum install -y -q kubectl
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo > /dev/null
        sudo yum install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin
    elif [[ "$OS" =~ ^(ubuntu|debian)$ ]]; then
        sudo apt-get update -y -qq && sudo apt-get install -y -qq apt-transport-https ca-certificates curl wget bzip2 software-properties-common openssl tar socat conntrack
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
        sudo apt-get update -y -qq && sudo apt-get install -y -qq kubectl
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update -y -qq && sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi
fi

# Start Docker and ensure permissions
if [ "${INSTALL_MODE}" == "internet" ] && [ "${USE_PROXY}" == "true" ]; then
    sudo mkdir -p /etc/systemd/system/docker.service.d
    cat <<EOF | sudo tee /etc/systemd/system/docker.service.d/http-proxy.conf > /dev/null
[Service]
Environment="HTTP_PROXY=${PROXY_URL}"
Environment="HTTPS_PROXY=${PROXY_URL}"
Environment="NO_PROXY=${NO_PROXY}"
EOF
else
    sudo rm -f /etc/systemd/system/docker.service.d/http-proxy.conf || true
fi

sudo systemctl daemon-reload
sudo systemctl start docker && sudo systemctl enable docker && sudo usermod -aG docker "$USER"
gum style --foreground 82 "✔ Docker runtime configured."

if [ ! -f "$HOME/.ssh/id_rsa" ]; then
    gum style --foreground 240 "Generating SSH keys..."
    mkdir -p "$HOME/.ssh"
    ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_rsa" -N "" > /dev/null 2>&1
fi

gum style --foreground 240 "Configuring Firewalls..."
if command -v ufw &> /dev/null; then
    sudo ufw allow ${REGISTRY_PORT}/tcp > /dev/null 2>&1 || true
elif command -v firewall-cmd &> /dev/null; then
    sudo firewall-cmd --permanent --add-port=${REGISTRY_PORT}/tcp > /dev/null 2>&1 || true
    sudo firewall-cmd --reload > /dev/null 2>&1 || true
fi

# ==============================================================================
# STEP 3: HARBOR SSL & INSTALLATION
# ==============================================================================
gum style --foreground 240 "Generating Self-Signed SSL Certificates for Harbor (${REGISTRY_IP})..."
sudo mkdir -p "${REGISTRY_CERTS_DIR}"
sudo openssl req -newkey rsa:4096 -nodes -sha256 -keyout "${REGISTRY_CERTS_DIR}/domain.key" \
  -addext "subjectAltName = DNS:localhost, IP:${REGISTRY_IP}, IP:127.0.0.1" \
  -x509 -days 365 -out "${REGISTRY_CERTS_DIR}/domain.crt" \
  -subj "/C=US/ST=State/L=City/O=Organization/CN=${REGISTRY_IP}" > /dev/null 2>&1

if [ -d "/etc/pki/ca-trust/source/anchors/" ]; then
    sudo cp "${REGISTRY_CERTS_DIR}/domain.crt" /etc/pki/ca-trust/source/anchors/registry.crt
    sudo update-ca-trust
elif [ -d "/usr/local/share/ca-certificates/" ]; then
    sudo cp "${REGISTRY_CERTS_DIR}/domain.crt" /usr/local/share/ca-certificates/registry.crt
    sudo update-ca-certificates > /dev/null 2>&1
fi
sudo systemctl restart docker

# Install Harbor using the Offline Installer
if [ ! -d "harbor" ]; then
    gum style --foreground 240 "Extracting Harbor Offline Installer ${HARBOR_VERSION}..."
    if [ "${INSTALL_MODE}" == "dark" ]; then
        if [ ! -f "nkp-prereqs-bundle/harbor/harbor-offline-installer-${HARBOR_VERSION}.tgz" ]; then
            gum style --foreground 196 "❌ ERROR: Dark Site mode detected, but offline Harbor installer is missing."
            exit 1
        fi
        cp "nkp-prereqs-bundle/harbor/harbor-offline-installer-${HARBOR_VERSION}.tgz" .
    elif [ "${INSTALL_MODE}" == "internet" ]; then
        if [ ! -f "harbor-offline-installer-${HARBOR_VERSION}.tgz" ]; then
            wget -q --show-progress "https://github.com/goharbor/harbor/releases/download/${HARBOR_VERSION}/harbor-offline-installer-${HARBOR_VERSION}.tgz"
        fi
    fi
    tar xzf harbor-offline-installer-${HARBOR_VERSION}.tgz
fi

gum style --foreground 240 "Configuring Harbor profile..."
cd harbor
cp harbor.yml.tmpl harbor.yml
sed -i "s/^hostname: .*/hostname: ${REGISTRY_IP}/" harbor.yml
sed -i "s/port: 80/port: 8080/" harbor.yml 
sed -i "s/port: 443/port: ${REGISTRY_PORT}/" harbor.yml 
sed -i "s|^  certificate: .*|  certificate: ${REGISTRY_CERTS_DIR}/domain.crt|" harbor.yml
sed -i "s|^  private_key: .*|  private_key: ${REGISTRY_CERTS_DIR}/domain.key|" harbor.yml
sed -i "s/^harbor_admin_password: .*/harbor_admin_password: ${REGISTRY_PASS}/" harbor.yml

gum spin --spinner line --title "Installing Harbor Registry..." -- sudo ./install.sh > /dev/null
cd ..

gum style --foreground 82 "✔ Harbor is Live! UI Available at: https://${REGISTRY_URL}"

# ==============================================================================
# STEP 4: BUNDLE DOWNLOAD & EXTRACTION 
# ==============================================================================
if [ "${DOWNLOAD_BUNDLE}" == "true" ]; then
    gum style --foreground 212 "Downloading NKP Air-Gapped Bundle (~12GB). This may take a while..."
    if ! wget --show-progress -O "${BUNDLE_ARCHIVE}" "${BUNDLE_URL}"; then
        echo ""
        gum style --foreground 196 "❌ ERROR: Download failed! Look at the wget error above to see why."
        exit 1
    fi
    gum style --foreground 82 "✔ Successfully downloaded ${BUNDLE_ARCHIVE}."
fi

if [ ! -d "nkp-${NKP_VERSION}" ]; then
    if ! gum spin --spinner minidot --title "Extracting NKP Bundle (This will take a few minutes)..." -- tar -xzf "${BUNDLE_ARCHIVE}"; then
        gum style --foreground 196 "❌ ERROR: Failed to extract the bundle. The file may be corrupted or incomplete."
        exit 1
    fi
    sudo cp "nkp-${NKP_VERSION}/cli/nkp" /usr/local/bin/nkp
    sudo chmod +x /usr/local/bin/nkp
    gum style --foreground 82 "✔ Bundle extracted and CLI installed."
else
    gum style --foreground 82 "✔ Bundle already extracted."
fi

# FIX: Persist 256-color terminal setting for Phase 2 & Phase 3
if ! grep -q "export TERM=xterm-256color" "$HOME/.bashrc"; then
    echo "export TERM=xterm-256color" >> "$HOME/.bashrc"
fi

gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "Phase 1 Complete! IMPORTANT: Please log out and log back in for Docker group changes to apply."