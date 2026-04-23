# Setup and Installation

This guide covers the detailed setup and installation instructions for the `core-template` infrastructure, building upon the prerequisites described in the main README.

### Table of Contents
- [Offline Deployments](#offline-deployments)
- [Configure vars](#configure-vars)
  - [Customization Checklist](#customization-checklist)
- [Generate PKI (optional, before install)](#generate-pki-optional-before-install)
- [Run the Installer](#run-the-installer)
  - [Installation Modes](#installation-modes)
    - [`(default mode)`](#default-mode)
    - [`--custom --tags`](#--custom---tags)
  - [Installation Flags](#installation-flags)
    - [Remote Deployment](#remote-deployment) (`--target`, `--ssh-user`)
    - [Bring Your Own Certs (BYOC)](#bring-your-own-certs-byoc) (`--byoc`, `--ca-crt`, `--ica-crt`, `--ica-key`)
    - [Offline Packages](#offline-packages) (`--prereqs`, `--prereqs-target`, `--offline`)
    - [Execution Control](#execution-control) (`--no-start`, `--check`, `--export`)

---

## Offline Deployments

**Step 1** — on an internet-connected Ubuntu 24.04 machine, stage the bundles:

```bash
sudo ./offline.sh --stage [--output <dir>] [--compress | --package] [--no-images]
# Downloads APT packages, Docker images, and Ansible collections.
# Scans with ClamAV if installed (skipped with a warning if not).
# Produces two bundles in the output directory:
#   core-template-controller-<timestamp>/  — Ansible + collections (run on Ansible host)
#   core-template-target-<timestamp>/      — system/Docker packages + images (installed on target)
#
# --compress   produce .tar.gz archives instead of loose directories
# --package    produce .tar  archives instead of loose directories
# --no-images  skip pulling/saving Docker images (useful when images are already present)
```

**Step 2** — transfer both bundles to the air-gapped environment.

**Step 3** — install the controller bundle on the Ansible host (installs Ansible + collections):

```bash
sudo ./offline.sh --install ./core-template-controller-<timestamp>/
# Also accepts: .tar.gz, .tar, or legacy .zip archives
```

**Step 4** — run the installer, passing the target bundle for the remote host:

```bash
# Local target (Ansible host = deployment target)
sudo ./setup.sh --offline --prereqs-target ./core-template-target-<timestamp>/

# Remote target (Ansible host and target are separate machines)
sudo ./setup.sh --offline --prereqs-target ./core-template-target-<timestamp>/ \
                --target 192.168.1.5
```

`offline.sh --install` is the sole installer for controller-side prerequisites (Ansible, collections). `setup.sh` assumes they are already present and will error if `ansible-playbook` is not found. `--prereqs-target` passes the target bundle to Ansible so the playbook installs remote packages and loads Docker images without network access.

> **ClamAV:** if `clamav` is installed on the staging machine, `offline.sh --stage` will run `freshclam` and scan all downloaded files before packaging. The scan result (`CLEAN`, `THREATS FOUND`, or `SKIPPED`) is embedded in `scan-results.txt` inside each bundle. `setup.sh --prereqs` reads that result and warns (with a confirmation prompt) if the bundle was flagged.

---

## Configure vars

Variables are split across two files. Before installation, copy the provided templates to create your local config files:

```bash
cp custom-vars-tpl.yml custom-vars.yaml
```

- **`custom-vars.yaml`** (repo root) — deployment settings: domain, network, DNS records, PKI identity, infrastructure defaults, Docker container IPs, image refs, port numbers, TSIG key definitions, LDAP groups and OUs. Edit this file to customise your deployment.

`01-handle-vars.yml` generates secrets (CA password, one TSIG secret per key) and writes them to `core-secrets.yml` (git-ignored) on the first run; existing secrets are preserved on re-runs. `02-render-jinja.yml` then loads `custom-vars.yaml` and `core-secrets.yml`, renders `core/jinja/vars.yaml.j2`, and writes the fully-resolved result to `/tmp/core-template-render/vars.yaml`. All subsequent playbooks read from that rendered file.

Minimum required changes in `custom-vars.yaml`:

```yaml
# ── GLOBAL ──────────────────────────────────────────────────────────────────
domain: home                    # your internal TLD  (e.g. "lab", "internal")

# ── NETWORK ─────────────────────────────────────────────────────────────────
lan_cidr: 10.0.0.0/22           # your LAN subnet
lan_gateway: 10.0.0.1
host_ip: 10.0.3.53              # host machine IP on the LAN

# ── PKI ─────────────────────────────────────────────────────────────────────
acme_email: admin@email.internal

# ── DNS RECORDS ─────────────────────────────────────────────────────────────
# Zone key must be the static placeholder 'dynamic_zone_var'.
# Templates resolve it to the 'domain' value at render time.
dns:
  dynamic_zone_var:
    zone_authority: true        # emit NS A record pointing to host_ip
    tsig: acme_dns-01           # primary TSIG key for this zone
    A:
    - { name: core, ip: "{{ host_ip }}" }
    - { name: nas,  ip: 10.0.3.10 }
    CNAME:
    - { name: dns,  canonical: core }
    - { name: ldap, canonical: core }
    - { name: ca,   canonical: core }
```

Key tunables with their defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `bind_dns_port` | `5353` | Host port mapped to BIND9 container port 53 (`bind_dns_port:53`) — for direct host access and coexistence with other resolvers |
| `bind9_doh_port` | `8053` | BIND9 plain-HTTP DoH port (nginx terminates TLS) |
| `stepca_port` | `9000` | Step-CA HTTPS port |

> **`bind_dns_port`** is the host-side port Docker maps to BIND9's internal port 53 (e.g. `5353:53`). This keeps BIND9 off host port 53 so nginx can own it, while still letting host tools query directly: `dig @<host_ip> -p 5353`. nginx proxies public port 53 → `bind9:53` (container-to-container). nginx's port 53 (and all other LAN-facing ports) is bound to `host_ip` rather than `0.0.0.0` to avoid conflicts with `systemd-resolved`, which holds the loopback interface on Ubuntu.

### Customization Checklist

Before your first install, review and set these in `custom-vars.yaml`.

- [ ] `domain` — your internal TLD
- [ ] `system_timezone` — IANA timezone string
- [ ] `lan_cidr` / `lan_gateway` — your LAN network
- [ ] `host_ip` — host machine's LAN IP
- [ ] `dns_server` — upstream DNS used during bootstrap (only used when `use_host_dns: false`; defaults to using the host's existing resolver)
- [ ] `acme_email` — email for ACME registration
- [ ] `ca_name`, `cert_country`, `cert_org` — CA subject fields
- [ ] `byoc` / `ca_crt_path` / `ica_crt_path` — enable BYOC and point these to an offline PKI generation directory instead of utilizing the dynamic PKI.
- [ ] `dns:` block — A and CNAME records for your hosts
- [ ] `ldap_groups` / `ldap_organizational_units` — directory structure
- [ ] `tsig_keys` — add non-primary entries for external services that need DNS update rights (optional)
- [ ] `bind_dns_port` — change from `5353` if that port conflicts with an existing service
- [ ] `image_nginx` / `image_bind9` / `image_stepca` — override to pin images to specific digests or a local registry (optional; defaults to `:latest` tags)

---

## Generate PKI (optional, before install)

Certificates (such as the ones generated from our standalone [private-root-ca](https://github.com/private-root-ca) repository) are optional. 

If you choose to use an offline Root CA to sign your core TLS infrastructure, you should clone your CA repository (e.g., `private-root-ca`), generate the root and intermediate certificates offline on a secure machine, and never deploy the root key to the target.

Once your CA has generated the files, set them in `custom-vars.yaml`:

```yaml
byoc: true
ca_crt_path: /path/to/my/offline-pki/output/root_ca.crt
ica_crt_path: /path/to/my/offline-pki/output/intermediate_ca.crt
```

Or supply the paths directly to `setup.sh` to bypass `custom-vars.yaml`:

```bash
sudo ./setup.sh \
    --byoc \
    --ca-crt /path/to/my/offline-pki/output/root_ca.crt \
    --ica-crt /path/to/my/offline-pki/output/intermediate_ca.crt
```

> Playbook `01-handle-vars.yml` checks for these paths and will leverage them for Step-CA if provided.

---

## Run the Installer

The primary entry point is the `setup.sh` wrapper script. 

```bash
sudo ./setup.sh [mode] [flags]
```

> **Note**: For update (`--update`) and uninstall (`--uninstall`) modes, see the [Updates and Maintenance guide](updates.md).

### Installation Modes

#### `(default mode)`
Full install — bootstraps Ansible, runs the entire 11-section playbook (00–10).

```bash
# 1. Standard local installation
sudo ./setup.sh

# 2. Standard remote installation
sudo ./setup.sh --target 192.168.1.5
```

#### `--custom --tags`
Run specific playbook sections by tag.

```bash
# 1. Re-run only the PKI section locally
sudo ./setup.sh --custom --tags pki

# 2. Re-issue offline Step-CA certs for core services
sudo ./setup.sh --custom --tags service-certs
```

### Installation Flags

#### Remote Deployment
Deploy the infrastructure to a remote machine instead of `localhost`.

**`--target <ip>`**
```bash
# 1. Deploy to a remote IP address
sudo ./setup.sh --target 192.168.1.5

# 2. Deploy remotely without starting containers automatically
sudo ./setup.sh --target 192.168.1.5 --no-start
```

**`--ssh-user <user>`**
```bash
# 1. Deploy remotely using a specific SSH user
sudo ./setup.sh --target 192.168.1.5 --ssh-user admin_user

# 2. Deploy remotely with specific SSH user and custom tags
sudo ./setup.sh --target 192.168.1.5 --ssh-user admin_user --custom --tags pki
```

#### Bring Your Own Certs (BYOC)
Bypass Step-CA's internal offline root generation and supply your own trusted root and intermediate.

**`--byoc`**
```bash
# 1. Run in BYOC mode (assuming paths are defined in custom-vars.yaml)
sudo ./setup.sh --byoc

# 2. Run BYOC mode only applying PKI changes
sudo ./setup.sh --byoc --custom --tags pki
```

**`--ca-crt`, `--ica-crt`, `--ica-key`**
```bash
# 1. Supply full BYOC paths explicitly from command line
sudo ./setup.sh --byoc \
    --ca-crt /pki/root_ca.crt \
    --ica-crt /pki/intermediate_ca.crt \
    --ica-key /pki/intermediate_ca.key

# 2. Provide BYOC paths when deploying remotely
sudo ./setup.sh --target 192.168.1.5 --byoc \
    --ca-crt /pki/root_ca.crt \
    --ica-crt /pki/intermediate_ca.crt
```

#### Offline Packages
Manage installation without internet access.

**`--prereqs`, `--prereqs-target`, `--offline`**
```bash
# 1. Provide the target bundle and force offline mode locally
sudo ./setup.sh --offline --prereqs-target ./core-template-target-bundle/

# 2. Provide the target bundle and deploy to a remote target completely offline
sudo ./setup.sh --offline --prereqs-target ./core-template-target-bundle/ --target 192.168.1.5
```

#### Execution Control
Control the runtime behavior and outcomes of the script.

**`--no-start`**
```bash
# 1. Install locally but do not bring the Docker stack up
sudo ./setup.sh --no-start

# 2. Install remotely but leave the stack down for manual verification
sudo ./setup.sh --target 192.168.1.5 --no-start
```

**`--check`**
```bash
# 1. Dry run the installer locally
sudo ./setup.sh --check

# 2. Dry run specific playbook tags remotely
sudo ./setup.sh --target 192.168.1.5 --custom --tags bind9 --check
```

**`--export`**
```bash
# 1. Export rendered configurations to the default ./builds/ directory
sudo ./setup.sh --export

# 2. Export rendered configurations to a custom directory
sudo ./setup.sh --export /tmp/my-builds/
```
