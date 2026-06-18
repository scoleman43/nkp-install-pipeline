# 🚀 NKP Install Pipeline — Air-Gapped Infrastructure Engine

An end-to-end automation pipeline for deploying **Nutanix Kubernetes Platform (NKP)** in air-gapped (dark site) environments. Both installation modes are fundamentally air-gapped. The NKP cluster and all Kubernetes node images are always sourced from the local Harbor registry, never from the internet. The Internet-Based mode is a hybrid that uses an outbound connection only to download prerequisite packages and tooling onto the bastion itself; once Phase 1 completes, all cluster operations are fully isolated.

> **Deploying Nutanix Enterprise AI on top of NKP?** Once this pipeline completes, see the [NAI Installer](https://github.com/scoleman43/nai-install-pipeline) to deploy NAI onto the cluster provisioned here.

---

## Table of Contents

- [How It Works](#how-it-works)
- [Prerequisites](#prerequisites)
- [Bastion VM Setup](#bastion-vm-setup)
- [Quick Start](#quick-start)
  - [Phase 1 — Bastion & Harbor Registry](#phase-1--bastion--harbor-registry)
  - [Phase 2 — Node OS Image](#phase-2--node-os-image)
  - [Phase 3 — Cluster Deployment](#phase-3--cluster-deployment)
- [Day 2 — Upgrading NKP](#day-2--upgrading-nkp)
- [Architecture Notes](#architecture-notes)
- [Troubleshooting](#troubleshooting)

---

## How It Works

The pipeline breaks deployment into three sequential phases, each building on the last. A GitHub Actions workflow (Phase 0) compiles an offline prerequisites bundle on cloud runners so nothing needs to be compiled on the bastion itself.

| Phase | Script | What It Does |
|-------|--------|--------------|
| **0** | GitHub Actions | Builds and publishes `nkp-prereqs-bundle.tar.gz` to the Releases page — contains `kubectl`, `gum`, Docker packages, and a Harbor offline installer. Only needed for physical media transfers. |
| **1** | `phase1.sh` | Configures the bastion: installs Docker, `kubectl`, and `gum`; generates SSL certificates; and stands up a local Harbor registry. |
| **2** | `phase2.sh` | Stages the Kubernetes node OS image in Nutanix Prism Central — either using a pre-built image or building a custom one with Packer. |
| **3** | `phase3.sh` | Pushes ~12 GB of NKP container images into Harbor, bootstraps the air-gapped cluster via CAPI, and outputs Kommander dashboard credentials. |
| **Day 2** | `nkp-upgrade.sh` | Ingests a new NKP bundle into Harbor and orchestrates a rolling cluster upgrade. |

---

## Prerequisites

### Nutanix Infrastructure

- **Prism Central** deployed at **Small** size or larger

  > ⚠️ X-Small Prism Central is not supported — it causes API timeouts during the CAPI bootstrap sequence.

- Prism Central IP/FQDN and admin credentials
- Target Prism Element cluster name
- AHV subnet name or UUID for Kubernetes node VMs
- **1 unused VIP** for the Kubernetes control plane
- A dedicated block of unused IPs for MetalLB (application load balancing)
- A pre-uploaded QCOW2 node image in Prism Central *(or network access for a custom Packer build — see Phase 2)*

### Bundle Files

**For Dark Site / Air-Gapped installs**, transfer these files to the bastion before starting:

```
├── phase1.sh
├── phase2.sh
├── phase3.sh
├── nkp-upgrade.sh
├── nkp-air-gapped-bundle_v2.17.1_linux_amd64.tar.gz   ← From Nutanix Support Portal
└── nkp-prereqs-bundle.tar.gz                           ← From GitHub Releases
```

**For Internet-Assisted installs**, only the scripts are needed. Phase 1 will prompt for a presigned Nutanix download URL and pull everything automatically.

---

## Bastion VM Setup

The pipeline runs on a Linux VM inside your Nutanix environment. Provision it before running any scripts.

### Recommended Specifications

| Resource | Minimum | Notes |
|----------|---------|-------|
| vCPUs | 2 | |
| RAM | 12 GB | |
| Disk | 100 GB | Set to **200 GB** if you plan to deploy NAI afterward — the NAI bundles and images require the extra space |
| OS | Ubuntu 22.04 LTS | Ubuntu 26.04 LTS is also supported |

### Source Image

Use the official Ubuntu cloud image. Provide this URL in Prism Central's image upload or download it directly:

```
https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img
```

> When creating the VM from this image, explicitly expand the disk from the default 3.5 GB to at least 100 GB (200 GB recommended for NAI).

### Cloud-Init (Recommended)

Add this cloud-config during VM creation to set a password and enable SSH password authentication for first access:

```yaml
#cloud-config
password: password1
chpasswd: { expire: False }
ssh_pwauth: True
```

> Change the password immediately after first login, or replace this with your SSH public key for key-based auth.

### Prepare the Scripts

SSH into the bastion and make the scripts executable:

```bash
chmod +x phase1.sh phase2.sh phase3.sh nkp-upgrade.sh
```

---

## Quick Start

### Phase 1 — Bastion & Harbor Registry

```bash
./phase1.sh
```

Phase 1 is idempotent — if it detects that `gum` and `kubectl` are already installed, it skips straight to the UI. Safe to re-run if anything goes wrong.

**What you'll be prompted for:**

1. **Installation mode** — Dark Site (fully offline) or Internet-Based (hybrid)
   - **Dark Site:** all prerequisites come from the `nkp-prereqs-bundle.tar.gz`; no outbound access needed at any point
   - **Internet-Based:** the bastion uses its internet connection to install OS packages and tooling only; you will be asked whether you want to download the NKP air-gapped bundle via a presigned Nutanix URL, and optionally prompted for a corporate proxy URL and NO_PROXY list — the NKP cluster install itself always uses the local Harbor registry regardless

2. **NKP version** — e.g., `2.17.1`

3. **Harbor admin password** — Must contain uppercase, lowercase, and a number (e.g., `Harbor12345!`)

**What it does automatically:**

- Installs Docker, `kubectl`, and supporting OS packages
- Configures Docker proxy settings if applicable
- Generates an SSH keypair at `~/.ssh/id_rsa` if one does not exist
- Generates a self-signed SSL certificate for the Harbor registry and trusts it system-wide
- Deploys Harbor v2.10.3 and configures it with your password and certificate
- Extracts the NKP bundle and installs the `nkp` CLI to `/usr/local/bin/nkp`
- Writes `.nkp_version.env` and `.nkp_registry.env` for use by Phase 2 and Phase 3

**After Phase 1 completes:**

> ⚠️ **You must log out and log back in before running Phase 2.** Phase 1 adds your user to the `docker` group; the change does not take effect until you start a new session.

```bash
exit
# SSH back in, then:
./phase2.sh
```

---

### Phase 2 — Node OS Image

```bash
./phase2.sh
```

Phase 2 reads `.nkp_version.env` and `.nkp_registry.env` written by Phase 1. If those files are missing, it will exit with an error.

**You will be asked to choose between two paths:**

#### Option A — Use a Pre-Built Image *(Recommended for air-gapped environments)*

Select this if you have already uploaded an NKP-compatible QCOW2 image to Prism Central. You will be prompted for the exact image name as it appears in Prism Central's Image Configuration UI (case-sensitive).

The image name is saved to `.nkp_image.env` for Phase 3.

#### Option B — Build a Custom Image

Select this to build a node image from scratch using NKP's Packer-based image builder. You will be prompted for:

- Target OS (`ubuntu-22.04`, `rocky-9.6`, or `rhel-8.10`)
- Prism Central IP/FQDN and credentials
- Prism Element cluster name
- Subnet name or UUID
- Base image name in Prism Central (the source QCOW2 for Packer to boot)

> ⚠️ **Air-gap warning:** Custom image builds require the temporary Packer builder VM to download OS packages during the build. In a dark site, your base image must point to an internal APT/YUM mirror, or the build will time out. For most air-gapped deployments, Option A is the right choice.

The build streams Packer output live and takes 10–15 minutes. Once complete, you will be prompted to paste the name of the newly created image from the end of the build log.

---

### Phase 3 — Cluster Deployment

```bash
./phase3.sh
```

Phase 3 reads `.nkp_version.env`, `.nkp_image.env`, and `.nkp_registry.env`. It also requires `~/.ssh/id_rsa.pub` to exist — Phase 1 creates this automatically.

**What you'll be prompted for:**

| Prompt | Example |
|--------|---------|
| Cluster name | `nkp-prod-01` |
| Control plane VIP (must be an unused IP) | `10.0.0.50` |
| MetalLB IP range | `10.0.0.100-10.0.0.150` |
| Number of control plane nodes (must be odd) | `3` |
| Number of worker nodes | `3` |
| Prism Central IP/FQDN | `10.0.0.43` |
| Prism Central username | `admin` |
| Prism Central password | *(cached after first entry)* |
| Prism Element cluster name | `PE_Cluster_Name` |
| Subnet UUID | `VLAN_UUID_Goes_Here` |
| CSI storage container name | `Default_Container` |

All values are cached to `.nkp_phase3_cache.env` and pre-filled on subsequent runs. Press **Enter** to accept a cached value or type a new one to override.

**What it does automatically:**

1. Removes any stale bootstrap containers from a previous failed run
2. Logs the local Docker daemon into Harbor
3. Creates the `/nkp` project in Harbor via the API (prevents 401 errors on push)
4. Pushes the Konvoy core bundle (~12 GB) into Harbor
5. Pushes the Kommander application bundle into Harbor
6. Loads the bootstrap image into the local Docker daemon
7. Runs `nkp create cluster nutanix` in `--airgapped --self-managed` mode, streaming live CAPI logs
8. Validates the generated kubeconfig (`<cluster-name>.conf`)
9. Prints the Kommander dashboard URL and credentials

**After Phase 3 completes:**

Your cluster kubeconfig is at `./<cluster-name>.conf`. Set it as your active context:

```bash
export KUBECONFIG="$PWD/nkp-prod-01.conf"
kubectl get nodes
```

The Kommander dashboard URL and login credentials are printed at the end of the Phase 3 output. Save these.

---

## Day 2 — Upgrading NKP

When a new NKP version is released, use the upgrade script to update your air-gapped cluster without rebuilding from scratch.

### Step 1 — Stage the New Bundle

Transfer the new `nkp-air-gapped-bundle_v<NEW_VERSION>_linux_amd64.tar.gz` to the bastion, or have a presigned download URL ready.

### Step 2 — Run the Upgrade

```bash
./nkp-upgrade.sh
```

The script will:
1. Validate your existing kubeconfig and Harbor credentials
2. Prompt you to choose between a local tarball or a presigned download URL
3. Extract the new bundle and push updated container images into Harbor
4. Initiate the rolling CAPI upgrade sequence against your cluster

---

## Architecture Notes

### Air-Gapped by Design

Both installation modes produce a fully air-gapped cluster. The distinction between Dark Site and Internet-Based is limited to how the bastion acquires prerequisite tooling and the NKP bundle before the install begins. In Dark Site mode, everything arrives via physical media or a pre-staged bundle. In Internet-Based (hybrid) mode, the bastion uses a temporary internet connection to download OS packages and optionally the NKP bundle — but once Phase 1 completes and the bundle is staged in Harbor, all cluster operations source exclusively from the local registry. The Kubernetes control plane, worker nodes, and all container workloads never communicate with the internet.

### Harbor Registry Structure

Harbor runs on the bastion at `https://<bastion-ip>:5000`. All NKP images are pushed into a dedicated `/nkp` project (`https://<bastion-ip>:5000/nkp/...`). This project is created automatically by Phase 3 via the Harbor API before the first image push, which prevents 401 Unauthorized errors that occur when pushing to a non-existent project.

### Self-Signed SSL

Phase 1 generates a 4096-bit RSA certificate scoped to the bastion's IP address and trusts it system-wide. This certificate is passed to the `nkp create cluster` command via `--registry-mirror-cacert` so that cluster nodes can authenticate to Harbor without additional configuration.

### Smart Credential Caching

Phase 2 and Phase 3 each maintain their own cache files (`.nkp_phase2_cache.env` and `.nkp_phase3_cache.env`). Both are created with `chmod 600` and exist only on the local bastion. They contain plaintext credentials — delete them when no longer needed or when handing off the bastion to another operator.

### Idempotency

Phase 1 detects existing installations and skips straight to the UI rather than re-installing packages. Phase 3 cleans up stale Docker bootstrap containers before starting so a failed previous run does not block a retry.

---

## Troubleshooting

**Harbor returns 401 Unauthorized during image push**
The `/nkp` project must exist before images can be pushed. Phase 3 creates it automatically via `curl` against the Harbor API. If you are pushing manually, create the project first through the Harbor web UI at `https://<bastion-ip>:5000` or via:
```bash
curl -sk -u "admin:<password>" -X POST "https://<bastion-ip>:5000/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -d '{"project_name": "nkp", "metadata": {"public": "true"}}'
```

**Phase 2 or Phase 3 cannot find environment files**
Each phase depends on `.env` files written by the previous phase. If you see a missing file error, ensure the previous phase completed without errors. The files are: `.nkp_version.env` (Phase 1), `.nkp_registry.env` (Phase 1), `.nkp_image.env` (Phase 2).

**Docker permission denied after Phase 1**
You must log out and back in after Phase 1 for the `docker` group membership to take effect. Running `newgrp docker` in the current session also works as a temporary fix.

**Custom image build times out (Phase 2)**
The Packer builder VM needs to download OS packages during the build. In a dark site, your base image must be configured to use an internal package mirror. If no mirror is available, use a pre-built image (Option A in Phase 2) instead.

**Segmentation fault during certificate generation**
Occurs when upstream `.deb` packages overwrite system `glibc` libraries on newer Ubuntu versions (e.g., 26.04). The GitHub Actions prereqs bundle is specifically designed to exclude these packages — use the bundle from the Releases page rather than installing packages manually.

**Phase 3 cluster deployment fails mid-way**
The script removes stale bootstrap containers at the start of each run, so it is safe to re-run after fixing the underlying issue. Check the live CAPI log output above the error message for the specific failure reason (most commonly: incorrect PE cluster name, subnet UUID, or VIP already in use).

**`~/.ssh/id_rsa.pub` not found**
Phase 1 generates this keypair automatically. If you skipped Phase 1 or are on a different bastion, generate it manually:
```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
```
