# Operations

## Live Configuration Changes (`core-mgr`)

Use `core-mgr` (the global wrapper for `core/lib/manage.sh`) for post-install changes to DNS records, TSIG keys, certificates, and infrastructure variables — no full redeploy needed. Run it **on the target machine** (requires root / sudo).

### Table of Contents: `core-mgr` Options
- [Variable Management](#variable-management)
  - [`--interactive`](#--interactive)
  - [`--print`](#--print)
  - [`--apply`](#--apply)
- [TSIG Key Management](#tsig-key-management)
  - [`--tsig-keys`](#--tsig-keys)
  - [`--list-tsig`](#--list-tsig)
  - [`--remove-tsig`](#--remove-tsig)
- [Certificate Minting](#certificate-minting)
  - [`--mint-certs`](#--mint-certs)
  - [`--service-cert`](#--service-cert)
- [DNS Record Management](#dns-record-management)
  - [`--dns-record`](#--dns-record)
  - [`--remove-dns-record`](#--remove-dns-record)
- [Ansible Tags Reference](#ansible-tags-reference)
- [Service Ports](#service-ports)

---

### Variable Management

The infrastructure variables defined in `vars.yaml` can be managed directly via `core-mgr` using the interactive menu system.

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
Apply any manual changes made directly to `vars.yaml`. `core-mgr` will compare the file against the running configuration and selectively reload or restart only the affected services (e.g., reloading BIND9 if DNS records changed, or Nginx if routing configurations changed).

```bash
sudo core-mgr --apply
```

---

### TSIG Key Management

TSIG keys grant named DNS update rights to external services (NAS, reverse proxies, other hosts) for specific hostnames only.

#### `--tsig-keys`
Add a TSIG key to `vars.yaml` and reload BIND9.

```bash
# 1. Interactive mode: prompts for key name, domain, and hostnames to allow
sudo core-mgr --tsig-keys

# 2. Non-interactive mode: apply new keys added manually to vars.yaml
sudo core-mgr --tsig-keys --apply
```

#### `--list-tsig`
List all active TSIG keys and grants from the live BIND9 config.

```bash
# 1. Standard listing of all active keys
sudo core-mgr --list-tsig

# 2. List keys and pipe to grep to search for a specific domain
sudo core-mgr --list-tsig | grep "acme"
```

#### `--remove-tsig`
Remove a TSIG key and its grants from the live BIND9 config.

```bash
# 1. Remove a specific key by providing the name
sudo core-mgr --remove-tsig acme_nas-proxy

# 2. Remove another key by name
sudo core-mgr --remove-tsig acme_npm
```

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

---

### Certificate Minting

Mint TLS certificates for services outside this stack (NAS apps, VMs, etc.).

#### `--mint-certs`
Mint an offline certificate or subordinate CA and save it to `vars.yaml`.

```bash
# 1. Interactive mode: prompts for CN, SANs, days, output dir, key type/size
sudo core-mgr --mint-certs

# 2. Non-interactive mode: mints all entries in extra_certs from vars.yaml
sudo core-mgr --mint-certs --apply
```

#### `--service-cert`
Re-issue core service TLS certs (`dns`, `ldap`, `ca`, `certificates`) via Step-CA.

```bash
# 1. Interactive mode: shows current cert expiry and prompts to re-issue
sudo core-mgr --service-cert

# 2. Non-interactive mode: re-issues all core service certs immediately
sudo core-mgr --service-cert --apply
```

`vars.yaml` structure for extra certificates:

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

---

### DNS Record Management

Add or remove records in BIND9 zones without a full redeploy.

#### `--dns-record`
Add a DNS record to `vars.yaml` and reload BIND9.

```bash
# 1. Interactive mode: prompts for zone, type, and values
sudo core-mgr --dns-record

# 2. Non-interactive mode: re-renders all zones from the dns: block in vars.yaml
sudo core-mgr --dns-record --apply
```

#### `--remove-dns-record`
Remove a DNS record from `vars.yaml` and reload BIND9.

```bash
# 1. Interactive mode: lists live records and pick by number to remove
sudo core-mgr --remove-dns-record

# 2. Execute interactively using the absolute path to the script
sudo core-mgr --remove-dns-record
```

Supported record types: `A`, `AAAA`, `CNAME`, `MX`, `TXT`, `SRV`.

Both operations edit `vars.yaml`, then re-render forward and reverse zone files directly from `vars.yaml` using an inline Python renderer (PyYAML only — no Jinja2 engine or Ansible required). Rendered files are written to `/opt/bind9/data/` with bind ownership (uid/gid 53, mode 0640) and BIND9 is reloaded via `rndc reload`. Zone serials are incremented automatically (YYYYMMDDNN). When adding an `A` record the interactive prompt shows the PTR entry that will be auto-generated in the corresponding reverse zone.

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

**Reverse zones are auto-generated.** Every unique /24 subnet found in `A` records gets a `<octet3>.<octet2>.<octet1>.in-addr.arpa` zone file rendered from `reverse-zone.j2` and a corresponding zone entry in `named.conf.zones`. PTR records are derived from the forward A records — no separate configuration needed.

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

## Ansible Tags Reference

The full playbook (`core/playbooks/core-config.yml`) is an `import_playbook` entry point composed of individual playbooks in `core/playbooks/`. Each section can be run directly for targeted operations:

```bash
# Via setup.sh (recommended — handles SSH key setup and sudo)
sudo ./setup.sh --custom --tags <tag>

# Or directly with ansible-playbook
ansible-playbook core/playbooks/04-target-file-structure.yml -e target_host=core --tags dns-record
ansible-playbook core/playbooks/08-mint-service-certs.yml    -e target_host=core
ansible-playbook core/playbooks/09-start-and-configure.yml   -e target_host=core
```

| Tag | Section | Playbook | What it does |
|-----|---------|----------|-------------|
| `prereqs`,`validation` | 00 | `00-controller-check.yml` | Validate controller environment |
| *(always)* `handle-vars`, `render-jinja` | 01 | `01-gen-vars-and-render-jinja.yml` | Generate CA password + TSIG secrets into `core-secrets.yml` (idempotent); Merge all vars + secrets; render every template to `/tmp/core-template-render` |
| `users` | 03 | `03-target-service-accounts.yml` | Create service accounts (nginx, bind, step, ldap) |
| `file-structure`, `update`, `dns-record`, `bind9`, `stepca`, `nginx`, `openldap` | 04 | `04-target-file-structure.yml` | Create directory tree; deploy configs, stepca dirs, bind9 runtime dirs; `rndc reload` on `dns-record`; create `core-mgr` global wrapper |
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

> `bind_dns_port` (default `5353`) is the Docker host port mapped to BIND9's internal port 53 (`bind_dns_port:53`). BIND9 only listens on port 53 inside the container; Docker forwards host traffic on `bind_dns_port` to it. nginx connects to `bind9:53` directly (container-to-container). Change `bind_dns_port` in `vars.yaml` and re-run `--custom --tags bind9` if another service already uses `5353` on the host.
