#!/bin/bash
# ==============================================================================
# Script: 01_setup_bastion_registry.sh
# Purpose: Prepares Bastion Host, configures Proxy OR Offline Bundle, automates 
#          'gum' UI, generates SSH keys, and runs local registry.
# ==============================================================================

set -euo pipefail

export REGISTRY_PORT="5000"
export REGISTRY_DIR="/opt/registry/data"
export REGISTRY_CERTS_DIR="/opt/registry/certs"
export REGISTRY_IP=$(hostname -I | awk '{print $1}')
export REGISTRY_URL="${REGISTRY_IP}:${REGISTRY_PORT}"

if [ -f /etc/os-release ]; then . /etc/os-release; OS=$ID; else echo "Unsupported OS."; exit 1; fi

echo "Please authenticate sudo so we can configure the system uninterrupted:"
sudo -v

# ==============================================================================
# STEP 0: INSTALLATION MODE (Standard Bash)
# ==============================================================================
if [ -z "${INSTALL_MODE:-}" ]; then
    echo "--- Select Bastion Installation Mode ---"
    echo "1) Internet-Based (Direct or via Corporate Proxy)"
    echo "2) Dark Site / Air-Gapped (Requires 'nkp-prereqs-bundle.tar.gz')"
    read -p "Select Mode (1 or 2): " MODE_SELECTION
    
    if [ "$MODE_SELECTION" == "2" ]; then
        export INSTALL_MODE="dark"
        export USE_PROXY="false"
        
        # Verify bundle exists
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
            sudo apt-get install -f -y || true # Fix any local dependency cross-links
        elif [[ "$OS" =~ ^(rhel|centos|rocky)$ ]]; then
            sudo rpm -Uvh --force --nodeps nkp-prereqs-bundle/packages/*.rpm
        fi

    elif [ "$MODE_SELECTION" == "1" ]; then
        export INSTALL_MODE="internet"
        
        echo "--- Checking Network / Proxy Requirements ---"
        if [ -z "${http_proxy:-}" ]; then
            read -p "Do you need to configure a proxy for outbound internet access? (y/N): " needs_proxy
            if [[ "$needs_proxy" =~ ^[Yy] ]]; then
                export USE_PROXY="true"
                read -p "Proxy URL (e.g., http://proxy.corp.local:3128): " PROXY_URL
                read -p "NO_PROXY list (default: 127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/16): " NO_PROXY_INPUT
                export PROXY_URL="${PROXY_URL}"
                export NO_PROXY="${NO_PROXY_INPUT:-127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/16}"
            else
                export USE_PROXY="false"
            fi
        else
            export USE_PROXY="true"
            export PROXY_URL="${http_proxy}"
            read -p "NO_PROXY list (default: 127.0.0.1,localhost,192.168.0.0/16,10.0.0.0/16): " NO_PROXY_INPUT
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
        
        # Install Gum UI via Internet
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
    
    # Reload script into UI mode with the chosen environment variables applied
    if command -v gum &> /dev/null; then
        exec bash "$0" "$@"
    else
        echo "ERROR: Failed to initialize 'gum' UI."
        exit 1
    fi
fi

# ==============================================================================
# STEP 1: INTERACTIVE CONFIGURATION (Powered by Gum)
# ==============================================================================
gum style --border double --margin "1" --padding "1 2" --border-foreground 212 "NKP Phase 1: Bastion Host & Registry Setup"

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
    export NKP_VERSION=$(echo "${BUNDLE_URL}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?' | head -n 1 || true)
    if [ -z "$NKP_VERSION" ]; then
        export NKP_VERSION=$(gum input --prompt "Version not found in URL. Enter NKP Version: " --value "v2.17.1")
    fi
    export BUNDLE_ARCHIVE="nkp-air-gapped-bundle_${NKP_VERSION}_linux_amd64.tar.gz"
    gum style --foreground 82 "✔ Auto-detected Version: ${NKP_VERSION}"
else
    export DOWNLOAD_BUNDLE="false"
    export BUNDLE_ARCHIVE=$(ls nkp-air-gapped-bundle_v*_linux_amd64.tar.gz 2>/dev/null | head -n 1 || true)
    
    if [ -z "${BUNDLE_ARCHIVE}" ] || [ ! -f "${BUNDLE_ARCHIVE}" ]; then
        gum style --foreground 196 "❌ ERROR: No bundle found. Please place the .tar.gz file here and retry."
        exit 1
    fi
    export NKP_VERSION=$(echo "${BUNDLE_ARCHIVE}" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+)?' | head -n 1 || true)
    gum style --foreground 82 "✔ Detected local bundle: ${BUNDLE_ARCHIVE} (${NKP_VERSION})"
fi

echo "export NKP_VERSION=\"${NKP_VERSION}\"" > .nkp_version.env
echo "export BUNDLE_ARCHIVE=\"${BUNDLE_ARCHIVE}\"" >> .nkp_version.env

# ==============================================================================
# STEP 2: SYSTEM INSTALLATION & PREPARATION
# ==============================================================================
gum style --foreground 212 -- "--- Beginning System Configuration ---"

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

gum style --foreground 240 "Configuring Local Registry and Firewalls..."
if command -v ufw &> /dev/null; then
    sudo ufw allow ${REGISTRY_PORT}/tcp > /dev/null 2>&1 || true
elif command -v firewall-cmd &> /dev/null; then
    sudo firewall-cmd --permanent --add-port=${REGISTRY_PORT}/tcp > /dev/null 2>&1 || true
    sudo firewall-cmd --reload > /dev/null 2>&1 || true
fi

# Generate certificates
sudo mkdir -p "${REGISTRY_DIR}" "${REGISTRY_CERTS_DIR}"
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

# Load registry image if Dark Site, then run container
if [ "${INSTALL_MODE}" == "dark" ]; then
    gum style --foreground 240 "Loading offline Docker Registry image..."
    sudo docker load -i nkp-prereqs-bundle/images/registry-2.tar > /dev/null 2>&1
fi

if [ ! "$(sudo docker ps -q -f name=registry)" ]; then
    if [ "$(sudo docker ps -aq -f status=exited -f name=registry)" ]; then sudo docker rm registry > /dev/null 2>&1; fi
    if ! gum spin --spinner line --title "Starting Docker Registry..." -- bash -c "sudo docker run -d --restart=always --name registry -v \"${REGISTRY_CERTS_DIR}:/certs\" -e REGISTRY_HTTP_ADDR=0.0.0.0:${REGISTRY_PORT} -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/domain.crt -e REGISTRY_HTTP_TLS_KEY=/certs/domain.key -v \"${REGISTRY_DIR}:/var/lib/registry\" -p ${REGISTRY_PORT}:${REGISTRY_PORT} registry:2 > /dev/null 2>&1"; then
        gum style --foreground 196 "❌ ERROR: Failed to start local Docker registry."
        exit 1
    fi
fi
gum style --foreground 82 "✔ Registry running at: ${REGISTRY_URL}"

# ==============================================================================
# STEP 3: BUNDLE DOWNLOAD & EXTRACTION 
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

# Cleanup
if [ "${INSTALL_MODE}" == "dark" ]; then
    sudo rm -rf nkp-prereqs-bundle
fi

gum style --border normal --margin "1" --padding "1 2" --border-foreground 82 "Phase 1 Complete! IMPORTANT: Please log out and log back in for Docker group changes to apply."