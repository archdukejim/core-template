# Operations

## Live Configuration Changes (`core-mgr`)

Use `core-mgr` (the global wrapper powered by the interactive Python engine) for post-install changes to DNS records, TSIG keys, certificates, and infrastructure variables — no full redeploy needed. Run it **on the target machine** (requires root / sudo).

### Table of Contents
- [Live Configuration Management (`core-mgr`)](#live-configuration-management-core-mgr)
  - [`--interactive`](#--interactive)
  - [`--print`](#--print)
  - [`--apply`](#--apply)
  - [`--update-containers`](#--update-containers)
- [Interactive Menu Categories](#interactive-menu-categories)
  - [DNS Configuration](#dns-configuration)
  - [Mint Certificates](#mint-certificates)
  - [TSIG Keys](#tsig-keys)
  - [Landing Page Links](#landing-page-links)
- [Ansible Tags Reference (Initial Install Only)](#ansible-tags-reference-initial-install-only)
- [Service Ports](#service-ports)

---

### Live Configuration Management (`core-mgr`)

The infrastructure variables defined in `vars.yaml` can be managed directly via `core-mgr` using the interactive menu system or by editing the YAML manually. 

#### `--interactive`
Launch the interactive configuration menu. This will display categories of variables in `vars.yaml`, allowing you to select and modify them one by one. Immutable variables are protected from modification to prevent breaking the deployment. Changes are audit-logged, and applying changes to network variables will prompt a warning before restarting services.

```bash
sudo core-mgr --interactive
```

#### `--print`
Print the current contents of `vars.yaml` in a colorized, human-readable format.

```bash
sudo core-mgr --print
```

#### `--apply`
Apply any manual changes made directly to `vars.yaml`. `core-mgr` leverages the native Python `deploy.py` engine to compare the file against the running configuration, directly render Jinja2 templates, and selectively reload or restart only the affected systemd-managed services. Ansible is bypassed entirely for these day-2 operations.

```bash
sudo core-mgr --apply
```

#### `--update-containers`
Pulls the latest images for all deployed containers and recreates them. This operation is protected by a 300-second timeout to prevent indefinite hangs if the upstream registries are slow or unreachable.

```bash
sudo core-mgr --update-containers
```

---

### Interactive Menu Categories

All granular modifications are now managed within the unified `--interactive` menu system rather than via individual command-line flags. 

#### DNS Configuration

Add or remove records in BIND9 zones without a full redeploy via the interactive menu. Supported record types include `A`, `AAAA`, `CNAME`, `MX`, `TXT`, and `SRV`.

Changes edit `vars.yaml` and re-render forward and reverse zone files natively using Jinja2. Rendered files are written to `/opt/bind9/data/` with bind ownership, and BIND9 is reloaded via `rndc reload`. **Reverse zones are auto-generated** based on `/24` subnets found in `A` records.

`dns:` zone key uses the actual domain string (the `dynamic_zone_var` placeholder is already resolved to `domain` at install time):

```yaml
dns:
  yourdomain.internal:
    zone_authority: true    # emit NS A record pointing to host_ip
    tsig: acme_dns-01
    A:
    - { name: myserver, ip: 10.0.3.99 }
    CNAME:
    - { name: app, canonical: myserver }
    TXT:
    - { name: myserver, text: "v=spf1 -all" }
```

#### Mint Certificates

Mint offline or ACME-based TLS certificates for services outside this stack (NAS apps, VMs, etc.) via the interactive menu. `vars.yaml` structure for extra certificates:

```yaml
extra_certs:
- cn: nas-apps.internal
  sans: [jellyfin.internal, sonarr.internal]
  days: 365
  kty: RSA           # RSA | EC | OKP  (default: RSA)
  size: 4096         # RSA: 2048/3072/4096  EC: 256/384  (default: 4096)
  out_dir: /srv/certs
```

**Offline mode:** signed directly by Step-CA using the internal `leaf.tpl` x509 template — no ACME required.

**ACME mode:** issued via Step-CA's ACME provisioner with DNS-01 validation against BIND9 using the primary TSIG key. All core service certs (`dns.internal`, `ldap.internal`, `ca.internal`) are offline Step-CA certs issued at install time.

#### TSIG Keys

TSIG keys grant named DNS update rights to external services (NAS, reverse proxies, other hosts) for specific hostnames only. Manage keys (Add, Modify, Delete) directly through the interactive menu.

All TSIG keys are managed in the `tsig_keys` list in `vars.yaml`. Each key carries a `record_types` list that drives its `update-policy` grant in BIND9:

- `primary: true` + `record_types` → `grant key subdomain _acme-challenge <types>` (ACME DNS-01 scope)
- no `primary` + `record_types` → `grant key zonesub <types>` (zone-wide update rights for those types)

```yaml
tsig_keys:
- name: acme_dns-01       # primary ACME key — managed by installer
  algorithm: hmac-sha256
  domain: '{{ domain }}'
  primary: true
  record_types: [TXT]     # may update _acme-challenge TXT records
- name: acme_nas-proxy    # extra key — applied by core-mgr
  algorithm: hmac-sha256
  domain: '{{ domain }}'
  record_types: [TXT, A]  # zone-wide TXT and A update rights
```

All TSIG key names are also collected into a `tsig-updaters` ACL in `named.conf.acl` so they can be referenced in other BIND9 directives. Each key generates:
- An entry in `named.conf.keys` with a random 256-bit secret
- `update-policy` grant(s) in `named.conf.zones` based on `record_types`
- A `rfc2136.ini` credentials file for the consuming service

#### Landing Page Links

The landing page provides a grid of quick links for the infrastructure. You can add, modify, or delete these links dynamically using the interactive menu. 

All custom links are saved in `link-vars.yaml` and are deployed alongside the normal variables. They natively evaluate Jinja variables such as `{{ domain }}` to ensure links stay accurate even if the base domain changes.

```yaml
links:
  - name: Adguard Home
    link: "adguard.{{ domain }}"
  - name: Keycloak (Admin)
    link: "sso.{{ domain }}/admin"
```

---

## Resource Utilization

The following chart outlines the memory footprint and CPU impact of the deployed applications. When `host_ram_capacity` is set to a value between 3 and 4, the infrastructure automatically enforces Docker Compose memory constraints to prevent these services from exceeding the host's physical memory boundaries.

| Service | Startup (Peak RAM) | Idle (RAM) | Typical Usage | CPU Impact |
|---------|--------------------|------------|---------------|------------|
| Keycloak | 800MB – 1.2GB | 500MB – 700MB | 800MB – 1.2GB | High (during auth) |
| Postgres | 150MB | 80MB | 100MB – 200MB | Low |
| OpenLDAP | 50MB | 10MB – 20MB | 30MB – 50MB | Very Low |
| AdGuardHome | 100MB | 30MB – 50MB | 60MB – 120MB | Low (sustained) |
| BIND9 | 60MB | 30MB – 40MB | 40MB – 80MB | Very Low |
| Nginx | 20MB | 5MB – 10MB | 15MB – 40MB | Very Low |
| Step-ca | 50MB | 15MB – 25MB | 30MB – 50MB | Minimal |

---

## Ansible Tags Reference (Initial Install Only)

> [!NOTE]
> Ansible is now strictly used for the **initial deployment and bootstrapping** of the infrastructure. For any day-2 operations (e.g. changing configurations, minting certificates, updating DNS), use the Python-based `core-mgr` interactive CLI instead.

The full playbook (`core/playbooks/core-config.yml`) is an `import_playbook` entry point composed of individual playbooks in `core/playbooks/`. During an initial install, each section can be run directly:

```bash
# Via setup.sh (recommended — handles SSH key setup and sudo)
sudo ./setup.sh --custom --tags <tag>

# Or directly with ansible-playbook
ansible-playbook core/playbooks/09-start-and-configure.yml -e target_host=core
```

| Tag | Section | Playbook | What it does |
|-----|---------|----------|-------------|
| `prereqs`,`validation` | 00 | `00-controller-check.yml` | Validate controller environment |
| *(always)* `handle-vars`, `render-jinja` | 01 | `01-gen-vars-and-render-jinja.yml` | Generate CA password + TSIG secrets into `core-secrets.yml` (idempotent); Merge all vars + secrets; render every template to `/tmp/core-template-render` |
| `users` | 03 | `03-target-service-accounts.yml` | Create service accounts (nginx, bind, step, ldap) |
| `file-structure`, `bind9`, `stepca`, `nginx`, `openldap` | 04 | `04-target-file-structure.yml` | Create directory tree; deploy configs, stepca dirs, bind9 runtime dirs; create `core-mgr` global wrapper |
| `network`, `firewall` | 05 | `05-target-network.yml` | Harden systemd-resolved; configure UFW (LAN allow-list) |
| `pki`, `stepca` | 06 | `06-configure-stepca.yml` | Sign intermediate CA CSR (if deployed); initialize and configure step-ca |
| `pki`, `bootstrap` | 07 | `07-bootstrap-containers.yml` | Bootstrap bind9+step-ca containers safely |
| `pki`, `mint-certs` | 08 | `08-mint-service-certs.yml` | Mint BIND9 TLS, service certs, and `extra_certs` |
| `verify`, `deploy-checks` | 09 | `09-start-and-configure.yml` | Start full stack and bring up services |
| `cleanup-temp`, `teardown`, `validation` | 10 | `10-deploy-checks-and-cleanup.yml` | dig DNS; check nginx/HTTPS; export 30s logs; drop stack if `no_start` |

---

## Service Ports

| Port | Proto | Handler | Backend |
|------|-------|---------|---------|
| 53 | TCP + UDP | nginx | `bind9:53` (container-to-container) |
| 80 | TCP | nginx | health check · ACME passthrough · HTTPS redirect |
| 389 | TCP | nginx | `openldap:389` (plain LDAP passthrough) |
| 443 | TCP | nginx | `step-ca:9000` · `bind9:8053` (`/dns-query`) |
| 636 | TCP | nginx | `openldap:389` (LDAPS — nginx terminates TLS) |
| 853 | TCP | nginx | `bind9:53` (DoT — nginx terminates TLS) |
| `bind_dns_port` | TCP + UDP | bind9 | host-facing (mapped `bind_dns_port:53`); default `5353` |
| `bind9_doh_port` | TCP | bind9 | plain-HTTP DoH; default `8053` |
| `stepca_port` | TCP | step-ca | internal HTTPS; default `9000` |

> `bind_dns_port` (default `5353`) is the Docker host port mapped to BIND9's internal port 53 (`bind_dns_port:53`). BIND9 only listens on port 53 inside the container; Docker forwards host traffic on `bind_dns_port` to it. nginx connects to `bind9:53` directly (container-to-container). Change `bind_dns_port` via `core-mgr --interactive` and apply if another service already uses `5353` on the host.
