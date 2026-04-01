# core-template

> Ansible-driven home lab infrastructure: authoritative DNS, internal PKI, LDAP, and TLS — deployable locally or remotely, with offline support.

---

## Table of Contents

- [Synopsis](#synopsis)
- [Architecture](#architecture)
- [Installation](#installation)
  - [Prerequisites](#prerequisites)
  - [Offline Deployments](#offline-deployments)
  - [Configure vars.yaml](#configure-varsyaml)
  - [Run the Installer](#run-the-installer)
- [Operations](#operations)
  - [Setup Modes](#setup-modes)
  - [Health Checks](#health-checks)
  - [Live Configuration Changes](#live-configuration-changes-modifysh)
    - [TSIG Key Management](#tsig-key-management)
    - [Certificate Minting](#certificate-minting)
    - [DNS Record Management](#dns-record-management)
  - [Ansible Tags Reference](#ansible-tags-reference)
  - [Service Ports](#service-ports)
- [Maintenance and Updates](#maintenance-and-updates)
  - [Updating Scripts](#updating-scripts)
  - [Rollback](#rollback)
  - [Uninstall](#uninstall)
  - [Version Tracking](#version-tracking)
- [Reference](#reference)
  - [PKI Chain](#pki-chain)
  - [DNS Architecture](#dns-architecture)
  - [Certificate Relay](#certificate-relay)
  - [Jinja2 Templates](#jinja2-templates)
  - [Customization Checklist](#customization-checklist)
- [Gaps and Next Tasks](#gaps-and-next-tasks)

---

## Synopsis

**core-template** is a template repository that provisions a self-contained home lab core stack via a single `setup.sh` invocation. It orchestrates an Ansible playbook across 14 sections, standing up:

| Service | Container | Purpose |
|---------|-----------|---------|
| **BIND9** | `bind9` | Authoritative DNS + DNS-over-HTTPS + DNS-over-TLS |
| **nginx** | `nginx` | Reverse proxy — DNS/DoT/DoH/LDAP/HTTPS |
| **Step-CA** | `step-ca` | Internal PKI — root CA → intermediate → ACME |
| **OpenLDAP** | `openldap` | Directory services |

Everything is rendered from Jinja2 templates using a single source of truth: `core/vars.yaml`.

---

## Architecture

```mermaid
graph TB
    subgraph LAN["LAN (10.0.0.0/22)"]
        CLIENT[Client devices]
        HOST[Pi / bare-metal host]
    end

    subgraph CORE["Docker bridge — core_net (10.255.0.0/24)"]
        NGINX["nginx :10.255.0.10\nports 53 · 80 · 389 · 443 · 636 · 853"]
        BIND9["bind9 :10.255.0.30\nhost port: bind_dns_port"]
        STEPCA["step-ca :10.255.0.40"]
        LDAP["openldap :10.255.0.50"]
    end

    CLIENT -->|"DNS · HTTPS · LDAPS"| HOST
    HOST --> NGINX
    NGINX -->|"DNS + DoT → bind_dns_port"| BIND9
    NGINX -->|"DoH /dns-query → :8053"| BIND9
    NGINX -->|"LDAP passthru"| LDAP
    NGINX -->|"HTTPS :443 → :9000"| STEPCA
    BIND9 -.->|"internal DNS"| STEPCA
```

### Request flow — DNS

```mermaid
sequenceDiagram
    participant C as Client
    participant N as nginx :53
    participant B as bind9 :bind_dns_port
    C->>N: DNS query (UDP/TCP)
    N->>B: proxy_pass bind9:bind_dns_port
    B-->>N: authoritative answer
    N-->>C: response
```

### Request flow — TLS certificate issuance

```mermaid
sequenceDiagram
    participant A as admin (install time)
    participant S as step-ca
    participant N as nginx/certs
    A->>S: step certificate create (offline)
    S-->>A: signed leaf cert (10 years)
    A->>N: deploy cert → nginx reload
```

---

## Installation

### Prerequisites

Prerequisites are split into two categories:

**Local** — needed on the machine running `setup.sh`:

| Tool | Notes |
|------|-------|
| Ubuntu 24.04 LTS | The controller machine |
| Ansible 2.17+ | Installed automatically by `setup.sh` if missing (via PPA or offline bundle) |
| Ansible collections | `community.docker`, `community.general`, `ansible.posix` — installed automatically |
| `rsync`, `ssh-client` | Required for remote targets and `--export` |

**Remote** — needed on the target machine (installed automatically by the Ansible playbook):

| Component | Notes |
|-----------|-------|
| Ubuntu 24.04 LTS | The deployment target |
| Docker Engine 26+ | Installed by the playbook |
| `docker compose` v2 | Installed by the playbook |
| `python3-docker` | Required for Ansible Docker modules |
| System packages | `acl`, `openssl`, `ca-certificates`, `ufw`, etc. |
| Docker images | `nginx`, `ubuntu/bind9`, `smallstep/step-ca`, `alpine` |

For remote targets, SSH access and `sudo` rights are required. `setup.sh` handles SSH key distribution automatically on the first run.

---

### Offline Deployments

**Step 1** — on an internet-connected Ubuntu 24.04 machine, stage the bundles:

```bash
sudo ./offline.sh --stage
# Downloads APT packages, Docker images, and Ansible collections.
# Scans with ClamAV if installed (skipped with a warning if not).
# Prompts for the output directory, then produces two bundles:
#   core-template-controller-<timestamp>.zip  — Ansible + collections (run on Ansible host)
#   core-template-target-<timestamp>.zip      — system/Docker packages + images (installed on target)
```

**Step 2** — transfer both zips to the air-gapped environment.

**Step 3** — on the Ansible host, run the installer pointing at both bundles:

```bash
# Local target (Ansible host = deployment target)
sudo ./setup.sh --prereqs ./core-template-controller-<timestamp>.zip \
                --prereqs-target ./core-template-target-<timestamp>.zip

# Remote target (Ansible host and target are separate machines)
sudo ./setup.sh --prereqs ./core-template-controller-<timestamp>.zip \
                --prereqs-target ./core-template-target-<timestamp>.zip \
                --target 192.168.1.5

# If Ansible is already installed on the host, skip the controller bundle
sudo ./setup.sh --offline --prereqs-target ./core-template-target-<timestamp>.zip
```

`--prereqs` installs Ansible and collections locally from the controller bundle. `--prereqs-target` passes the target bundle to Ansible so the playbook installs remote packages and loads Docker images without network access. `--offline` skips the external DNS check without installing local prerequisites.

> **ClamAV:** if `clamav` is installed on the staging machine, `offline.sh --stage` will run `freshclam` and scan all downloaded files before packaging. The scan result (`CLEAN`, `THREATS FOUND`, or `SKIPPED`) is embedded in `scan-results.txt` inside the zip. `setup.sh --prereqs` reads that result and warns (with a confirmation prompt) if the bundle was flagged.

---

### Configure vars.yaml

Before running the installer, edit `core/vars.yaml`. Minimum required changes:

```yaml
# ── GLOBAL ──────────────────────────────────────────────────────────────────
domain: home                    # your internal TLD  (e.g. "lab", "internal")
system_timezone: America/New_York

# ── NETWORK ─────────────────────────────────────────────────────────────────
lan_cidr: 10.0.0.0/22           # your LAN subnet
lan_gateway: 10.0.0.1
dns_server: 10.0.0.1            # used during bootstrap before BIND9 starts
pi_core_ip: 10.0.3.53           # host machine IP on the LAN

# ── PKI ─────────────────────────────────────────────────────────────────────
acme_email: admin@email.internal

# ── DNS RECORDS ─────────────────────────────────────────────────────────────
dns:
  home:
    A:
    - { name: pi-core, ip: 10.0.3.53 }
    - { name: nas,     ip: 10.0.3.10 }
    CNAME:
    - { name: dns,  canonical: pi-core }
    - { name: ldap, canonical: pi-core }
    - { name: ca,   canonical: pi-core }
```

Key tunables with their defaults:

| Variable | Default | Description |
|----------|---------|-------------|
| `bind_dns_port` | `5353` | Host-facing BIND9 port (host-side access, coexistence with other resolvers) |
| `bind9_doh_port` | `8053` | BIND9 plain-HTTP DoH port (nginx terminates TLS) |
| `stepca_port` | `9000` | Step-CA HTTPS port |

> **`bind_dns_port`** is intentionally configurable so you can run another DNS resolver on the host simultaneously (e.g. Pi-hole, Unbound). Set this to any unused port and BIND9 will bind there without conflicting. nginx always proxies public port 53 → `bind9:bind_dns_port`.

---

### Run the Installer

**Local install (most common):**

```bash
sudo ./setup.sh
```

**Local install + start services immediately:**

```bash
sudo ./setup.sh --start
```

**Remote install:**

```bash
sudo ./setup.sh --target 192.168.1.5
sudo ./setup.sh --target 192.168.1.5 --ssh-user myuser --start
```

On the first remote run, `setup.sh` will:
1. Generate `~/.ssh/id_ed25519` if no keypair exists
2. Trust the remote host key (`~/.ssh/known_hosts`)
3. Use `ssh-copy-id` to authorize the key (prompts for the remote password once)
4. Prompt for the remote sudo password before Ansible runs

After install, start services if you skipped `--start`:

```bash
docker compose -f /opt/core/docker-compose.yml up -d
```

---

## Operations

### Setup Modes

```bash
sudo ./setup.sh [mode] [flags]
```

| Mode | Description |
|------|-------------|
| *(default)* | Full install — bootstraps Ansible, runs the entire 14-section playbook |
| `--update` | Safe update — re-renders scripts and static files only; never overwrites live service configs unless `--force` is added |
| `--rollback` | Restore the most recent pre-update archive snapshot (interactive) |
| `--uninstall` | Stop containers, remove service accounts and project directories (interactive) |
| `--custom --tags <tag>` | Run specific playbook sections by tag |

**Flags:**

| Flag | Description |
|------|-------------|
| `--target <ip>` | Deploy to a remote host |
| `--ssh-user <user>` | SSH username (defaults to invoking user) |
| `--prereqs <path>` | Controller bundle zip or directory (from `offline.sh --stage`); installs Ansible + collections locally |
| `--prereqs-target <path>` | Target bundle zip or directory; passed to Ansible to install packages and load images on the target without internet |
| `--offline` | Skip external DNS resolution check (implied by `--prereqs` / `--prereqs-target`) |
| `--start` | Run `docker compose up -d` after install |
| `--export [path]` | Save built configs to `./builds/` (or specified path) |
| `--check` | Show what would change without applying |
| `--review` | Show full file diffs without applying (update mode) |
| `--apply` | Apply without interactive prompting |
| `--force` | Overwrite live configs in addition to scripts (update mode — use carefully) |
| `--version` / `-v` | Print version info |

**Common examples:**

```bash
sudo ./setup.sh --update                   # Preview script changes, prompt to apply
sudo ./setup.sh --update --review          # Show full diffs, don't apply
sudo ./setup.sh --update --apply           # Apply silently (CI-friendly)
sudo ./setup.sh --update --force --apply   # Overwrite everything, including configs
sudo ./setup.sh --export                   # Install + save build archive to ./builds/
sudo ./setup.sh --custom --tags pki        # Re-run PKI section only
sudo ./setup.sh --custom --tags service-certs  # Re-issue offline Step-CA certs for core services
```

---

### Health Checks

`check.sh` validates the running stack without modifying anything.

**Remote mode** — from any machine, no root required:

```bash
bash check.sh --target 192.168.1.5
bash check.sh --target 192.168.1.5 --domain mylab
```

Checks: DNS resolution (`:53` and `:<bind_dns_port>`), HTTP redirects, TLS certificates, external DNS reach.

**Local mode** — on the target host, requires root:

```bash
sudo bash check.sh
```

Checks everything above plus: Docker container health, CA file validity and expiry, Step-CA `/health`, service cert expiry, LDAP rootDSE, BIND9 `rndc status`.

Example output:

```
[PASS] A  pi-core → 10.0.3.53
[PASS] bind9: running, healthy
[WARN] cert expiry: 18 days remaining
[FAIL] openldap: not running
  3 passed   1 failed   1 warning
```

Exit code is non-zero if any check fails.

---

### Live Configuration Changes (`modify.sh`)

Use `core/modify.sh` for post-install changes to DNS records, TSIG keys, and certificates — no full redeploy needed.

```bash
sudo bash core/modify.sh [mode] [flags]
```

All modes support `--target <ip>` and `--ssh-user <user>` for remote operations.

#### TSIG Key Management

TSIG keys grant named DNS update rights to external services (NAS, reverse proxies, other hosts) for specific hostnames only.

```bash
# Interactive — prompts for key name, domain, and hostnames to allow
sudo bash core/modify.sh --tsig-keys

# Non-interactive — applies all non-primary entries in tsig_keys from vars.yaml
sudo bash core/modify.sh --tsig-keys --apply

# List all active keys and their per-record grants
sudo bash core/modify.sh --list-tsig

# Remove a key by name
sudo bash core/modify.sh --remove-tsig acme_nas-proxy
```

All TSIG keys — including the primary ACME key — are defined in a single `tsig_keys` list in `vars.yaml`. The entry with `primary: true` is the primary ACME key for Step-CA's DNS-01 provisioner, managed by the installer. All other entries are applied by `modify.sh --tsig-keys`.

```yaml
tsig_keys:
- name: acme_dns-01       # primary ACME key — managed by installer
  algorithm: hmac-sha256
  domain: '{{ domain }}'
  primary: true
- name: acme_nas-proxy    # extra key — applied by modify.sh
  algorithm: hmac-sha256
  domain: home
  records:
  - nas-apps
  - jellyfin
  - sonarr
```

Each non-primary key generates:
- An entry in `named.conf.keys` with a random 256-bit secret
- Per-record `update-policy` grants in `named.conf.zones`
- A `rfc2136.ini` credentials file for the consuming service

#### Certificate Minting

Mint TLS certificates for services outside this stack (NAS apps, VMs, etc.).

```bash
# Interactive
sudo bash core/modify.sh --mint-certs

# Non-interactive — mints all entries in extra_certs from vars.yaml
sudo bash core/modify.sh --mint-certs --apply

# Issue a subordinate CA certificate (pathLen=0 — can sign leaf certs only)
sudo bash core/modify.sh --mint-certs --intermediate-ca

# Subordinate CA that can sign one further CA level (pathLen=1)
sudo bash core/modify.sh --mint-certs --intermediate-ca 1
```

`vars.yaml` structure for extra certificates:

```yaml
extra_certs:
- cn: nas-apps.internal
  sans: [jellyfin.internal, sonarr.internal]
  mode: offline      # or: acme
  days: 365          # offline only
  output: /srv/certs # offline only
```

**Offline mode:** signed directly by Step-CA using the internal `leaf.tpl` x509 template — no ACME required.

**ACME mode:** issued via Step-CA's ACME provisioner with DNS-01 validation against BIND9 using the primary TSIG key. All core service certs (`dns.internal`, `ldap.internal`, `ca.internal`) are offline Step-CA certs issued at install time.

#### DNS Record Management

Add records to BIND9 zones without a full redeploy.

```bash
# Interactive — prompts for zone, type, and values
sudo bash core/modify.sh --dns-record

# Non-interactive — re-renders all zones from the dns: block in vars.yaml
sudo bash core/modify.sh --dns-record --apply
```

Supported record types: `A`, `AAAA`, `CNAME`, `MX`, `TXT`, `SRV`.

`vars.yaml` `dns:` block structure:

```yaml
dns:
  home:
    A:
    - { name: myserver, ip: 10.0.3.99 }
    CNAME:
    - { name: app, canonical: myserver }
    TXT:
    - { name: myserver, value: "v=spf1 -all" }
```

After changes, `modify.sh` re-renders zone files, updates `named.conf.zones`, and reloads BIND9 via `rndc reload`.

---

### Ansible Tags Reference

Run individual playbook sections with `--custom --tags`:

```bash
sudo ./setup.sh --custom --tags <tag>
```

| Tag | Section | What it does |
|-----|---------|-------------|
| `validation` | 1 | OS and Ansible version checks |
| `pkg_mgmt` | 2 | Install system packages (acl, openssl, curl, ufw…) |
| `docker_engine` | 3 | Install and verify Docker Engine |
| `cleanup` | 4 | Stop and remove existing containers |
| `network` | 5 | Harden systemd-resolved; free port 53 for Docker |
| `firewall` | 5.5 | Configure UFW (LAN allow-list) |
| `users` | 6 | Create service accounts (nginx, bind, step, ldap) |
| `files` | 7b | Sync all configs and service directories to `/opt` |
| `update` | 7a/7c | Sync scripts only + write `.version` file |
| `pki,stepca` | 8 | Bootstrap EasyRSA root CA + Step-CA intermediate |
| `bind9,tsig` | 9 | Generate primary TSIG key; mint BIND9 static TLS cert |
| `tsig-keys` | 10c | Apply non-primary entries from `tsig_keys` in vars.yaml |
| `mint-certs` | 10d | Mint `extra_certs` from vars.yaml |
| `dns-record` | 10e | Re-render and reload DNS zones |
| `service-certs` | 13 | Issue offline Step-CA certs for core services (dns, ldap, ca) |
| `verify` | 14 | Verify issued certificates |
| `compose-up` | 15 | `docker compose up -d` (opt-in via `start_services=true`) |

---

### Service Ports

| Port | Proto | Handler | Backend |
|------|-------|---------|---------|
| 53 | TCP + UDP | nginx | `bind9:bind_dns_port` |
| 80 | TCP | nginx | health check · ACME passthrough · HTTPS redirect |
| 389 | TCP | nginx | `openldap:389` (plain LDAP passthrough) |
| 443 | TCP | nginx | `step-ca:9000` · `bind9:8053` (`/dns-query`) |
| 636 | TCP | nginx | `openldap:389` (LDAPS — nginx terminates TLS) |
| 853 | TCP | nginx | `bind9:bind_dns_port` (DoT — nginx terminates TLS) |
| `bind_dns_port` | TCP + UDP | bind9 | host-facing; default `5353` |
| `bind9_doh_port` | TCP | bind9 | plain-HTTP DoH; default `8053` |
| `stepca_port` | TCP | step-ca | internal HTTPS; default `9000` |

> `bind_dns_port` (default `5353`) is the port BIND9 binds on the host for direct host access (e.g. `dig @localhost -p 5353`) and coexistence with other resolvers. Changing this in `vars.yaml` and re-running `--custom --tags bind9` lets you run another resolver on the host simultaneously without a port conflict.

---

## Maintenance and Updates

### Updating Scripts

`--update` mode re-renders scripts and static files from the current repo without touching live service configs:

```bash
sudo ./setup.sh --update              # Summary of what changed; prompt to apply
sudo ./setup.sh --update --review     # Full file diffs before applying
sudo ./setup.sh --update --apply      # Apply silently (CI-friendly)
```

Files updated: `setup.sh`, `check.sh`, `modify.sh`, `cert-relay-host.sh`, `cert-update.sh`, `sign-certs.sh`, PKI info page.

To also update service configs (nginx, BIND9, docker-compose, etc.), add `--force`:

```bash
sudo ./setup.sh --update --force --apply   # WARNING: overwrites live configs
```

A snapshot of `/opt/core/` is automatically archived before every update.

---

### Rollback

Restore from the most recent pre-update snapshot:

```bash
sudo ./setup.sh --rollback
```

Interactive — shows the available snapshot and asks for confirmation before restoring.

---

### Uninstall

```bash
sudo ./setup.sh --uninstall
```

Stops and removes all containers, removes service accounts, and deletes `/opt/{core,nginx,bind9,stepca,openldap,easyrsa}/`. Interactive — confirms before each destructive step.

---

### Version Tracking

Every install and update writes a `.version` file to `/opt/core/`:

```
HOMECORE_VERSION="0000005"
HOMECORE_COMMIT="4ceb2293..."
HOMECORE_COMMIT_SHORT="4ceb229"
HOMECORE_COMMIT_DATE="2026-03-27 19:47:52 +0000"
HOMECORE_COMMIT_MSG="feat: add TSIG extra key support"
HOMECORE_BRANCH="main"
HOMECORE_INSTALLED_AT="2026-03-29T11:00:00Z"
```

The serial increments monotonically with each install. Every rendered file includes a version stamp in its header so you can trace any deployed config back to its source commit.

**Export a build archive:**

```bash
sudo ./setup.sh --export ./builds/
```

Captures all rendered configs in a git-tracked directory. Each export is one commit — `git diff` between two exports shows exactly what changed in the deployed environment.

---

## Reference

### PKI Chain

```
EasyRSA Root CA  (RSA 4096, ~20 years)
    └── Step-CA Intermediate CA  (RSA 4096, ~15 years)
            ├── BIND9 static TLS cert  (offline, ~15 years)
            ├── Offline leaf certs  (10 years, issued at install time)
            │       ├── dns.<domain>   → nginx DoT / DoH
            │       ├── ldap.<domain>  → nginx LDAPS
            │       └── ca.<domain>    → nginx → Step-CA
            └── extra_certs  (offline or ACME, per-entry config)
```

The root CA lives offline in `/opt/easyrsa/`. Step-CA signs the intermediate and serves as the ACME endpoint. DNS-01 challenges for Step-CA's ACME provisioner can be fulfilled via the primary TSIG key (`acme_dns-01`).

Internal CA files are distributed to services as `root_ca.crt` volume mounts. The PKI info page is served at `https://ca.<domain>/pki/` with downloadable root and intermediate CA certificates.

---

### DNS Architecture

BIND9 runs as an **authoritative-only** server (recursion disabled). It serves:
- Internal zones defined in the `dns:` block of `vars.yaml`
- ACME challenge records updateable by the primary TSIG key (for Step-CA ACME provisioner)
- Any additional zones managed by `modify.sh --tsig-keys`

nginx fronts BIND9 on all public DNS ports:

```
:53  TCP/UDP  → bind9:bind_dns_port   plain DNS
:853 TCP      → bind9:bind_dns_port   DNS-over-TLS  (nginx terminates TLS)
:443 /dns-query → bind9:8053          DNS-over-HTTPS (nginx terminates TLS)
```

`bind_dns_port` (default `5353`) is the port BIND9 binds on the Docker host. This is separate from port 53 so you can run a forwarding resolver (Pi-hole, Unbound, etc.) on the host simultaneously — point it at `127.0.0.1:<bind_dns_port>` for local zone resolution.

---

### Certificate Relay

Core service certificates (`dns.<domain>`, `ldap.<domain>`, `ca.<domain>`) are offline Step-CA leaf certs with a 10-year lifetime, issued at install time via `step certificate create`. There is no certbot container or cert-relay service. nginx reads the issued certs directly from the volume paths set during install.

---

### Jinja2 Templates

All `.j2` files in this repo are rendered by the Ansible playbook into `/opt/<service>/`. The `.j2` source files are removed from `/opt` after rendering — only rendered outputs remain on the host.

| Template | Rendered to |
|----------|------------|
| `core/docker-compose.yml.j2` | `/opt/core/docker-compose.yml` |
| `nginx/nginx.conf.j2` | `/opt/nginx/nginx.conf` |
| `bind9/config/named.conf*.j2` | `/opt/bind9/config/named.conf*` |
| `bind9/data/zone.j2` | `/opt/bind9/data/<zone>.zone` |
| `openldap/*.ldif.j2` | `/opt/openldap/*.ldif` |
| `stepca/templates/certs/leaf.tpl.j2` | `/opt/stepca/data/templates/certs/leaf.tpl` |
| `nginx/pki/index.html.j2` | `/opt/nginx/pki/index.html` |

---

### Customization Checklist

Before your first install, review and set these in `core/vars.yaml`:

- [ ] `domain` — your internal TLD
- [ ] `system_timezone` — IANA timezone string
- [ ] `lan_cidr` / `lan_gateway` — your LAN network
- [ ] `pi_core_ip` — host machine's LAN IP
- [ ] `dns_server` — upstream DNS used during bootstrap
- [ ] `acme_email` — email for ACME registration
- [ ] `ca_name`, `cert_country`, `cert_org` — CA subject fields
- [ ] `dns:` block — A and CNAME records for your hosts
- [ ] `ldap_groups` / `ldap_organizational_units` — directory structure
- [ ] `tsig_keys` — add non-primary entries for external services that need DNS update rights (optional)
- [ ] `bind_dns_port` — change from `5353` if that port conflicts with an existing service

---

## Gaps and Next Tasks

The following gaps were identified while writing this document:

**Missing features:**
- `check.sh` does not validate DoH (`/dns-query`) or DoT (`:853`) endpoints — these are core delivery paths with no automated health check.
- `check.sh` remote mode contains hardcoded test hostnames and IPs that don't match the template `vars.yaml` records and will fail on a clean install.
- There is no `modify.sh --remove-dns-record` mode — only add is supported. Removing a record requires manually editing `vars.yaml` and re-running `--dns-record --apply`.
- No LDAP user/group provisioning tooling — `vars.yaml` defines the OU structure but adding actual users requires manual `ldapadd` after install.

**Hardening gaps:**
- `pull-prerequisites.sh` pins Docker images by `:latest` tag. In air-gapped deployments the bundled images may differ from what was tested. Pinning by digest in `vars.yaml` would improve reproducibility.

**Documentation gaps:**
- `modify.sh --mint-certs` ACME mode references a Portainer webhook URL but its expected format and behavior are not documented.
- IPv6 is not addressed in `vars.yaml` or `docker-compose.yml.j2`, despite BIND9 listening on `listen-on-v6 { any; }`.
- No monitoring or alerting integration — cert expiry warnings exist in `check.sh` but require manual invocation.

<!-- readme-version: 8beb636 -->
