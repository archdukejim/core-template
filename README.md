# home-core

Ansible-driven infrastructure-as-code for a containerized home lab running DNS, certificate authority, reverse proxy, and directory services on Docker.

## Architecture

```
  LAN (192.168.0.0/16)
        |
        | :80 :443 :53 :853 :389 :636
        v
  +-----------+
  |   nginx   |  TLS termination + L4/L7 reverse proxy
  +-----------+
        |
   +----+----+-------+----------+----------+
   |         |       |          |          |
AdGuard   BIND9   Step-CA   Certbot   OpenLDAP
  DNS    auth DNS    CA      renewal     auth
```

All services run on a single Docker bridge network (`172.30.255.0/24`) and are orchestrated by a single Ansible playbook.

| Service | Container IP | Domain | UID:GID |
|---------|-------------|--------|---------|
| nginx | 172.30.255.10 | core-proxy.{{ domain }} | 443:443 |
| AdGuard Home | 172.30.255.20 | adguard.{{ domain }} | 153:153 |
| BIND9 | 172.30.255.30 | dns.{{ domain }} | 53:53 |
| Step-CA | 172.30.255.40 | ca.{{ domain }} | 135:135 |
| OpenLDAP | 172.30.255.50 | ldap.{{ domain }} | 389:389 |
| Certbot | (dynamic) | -- | 0:0 (root) |

## Repository Layout

```
home-core/
  setup.sh                    # Install, update, rollback, uninstall
  core/
    ansible.cfg               # Ansible settings (Python interpreter, facts behavior)
    core-config.yml           # 14-section Ansible playbook (shared by setup.sh and modify.sh)
    modify.sh                 # Live config changes: TSIG keys, certificates, DNS records
    vars.yaml                 # All infrastructure variables
    version.sh                # Shared version utilities (sourced by setup.sh)
    docker-compose.yml.j2     # Compose template rendered from vars
  nginx/
    nginx.conf.j2             # Reverse proxy config (stream + http)
    pki/index.html.j2         # PKI info page with cert downloads + install guides
  bind9/
    config/                   # BIND9 config templates (all .j2, rendered by Ansible)
      named.conf.j2           # Main config — includes all other named.conf.* files
      named.conf.acl.j2       # ACL definitions (from bind_acls in vars.yaml)
      named.conf.keys.j2      # TSIG key placeholder (overwritten at runtime by Section 9)
      named.conf.logs.j2      # Logging config (stderr for Docker)
      named.conf.options.j2   # Server options (listeners, DNSSEC, rate-limit)
      named.conf.tls.j2       # TLS profile for DoT; DoH http block in bind9-only mode
      named.conf.zones.j2     # Zone + update-policy (TSIG grants from certbot_domains)
    data/
      zone.j2                 # Zone data template (rendered per zone from dns in vars.yaml)
  openldap/
    base.ldif.j2              # LDAP base DN (rendered from ldap_* vars)
    ous.ldif.j2               # Organizational units
    groups.ldif.j2            # Group definitions
    acl.ldif.j2               # Access control rules
  adguardhome/
    config/AdGuardHome.yaml.j2  # AdGuard Home configuration (Jinja2 template)
  certbot/
    cert-relay.service        # Systemd unit for host-side ACL relay
    cert-relay-host.sh.j2     # ACL relay daemon (applies setfacl on cert renewal)
    hooks/cert-update.sh.j2   # Certbot deploy hook (signals relay, reloads services)
  stepca/
    templates/certs/leaf.tpl.j2  # X.509 leaf certificate template (rendered for Step-CA)
  easyrsa/
    sign-certs.sh.j2          # Root CA generation and CSR signing via EasyRSA in Docker
```

## Deployment Modes

### Full mode (default)

AdGuard Home acts as the network-facing DNS resolver. nginx proxies port 53 → AdGuard, DoT (853) → AdGuard, and serves the AdGuard UI over HTTPS. BIND9 runs internally on port 5353 and is only queried by AdGuard for the `{{ domain }}` zone.

### bind9-only mode (`--bind9-only`)

AdGuard Home is omitted entirely. nginx proxies port 53 directly to BIND9 (which listens internally on `bind_dns_port`, default 5353), and also handles DoT and DoH:

```
  LAN
   |
   +-- :53 UDP/TCP ----------> nginx (stream proxy) ──> BIND9:5353
   |
   +-- :853 (DoT) -----------> nginx (TLS termination) ──> BIND9:5353
   |
   +-- :443/dns-query (DoH) -> nginx (TLS termination) ──> BIND9:8053 (HTTP DoH)
   |
   +-- :443 ca.{{ domain }} -> nginx ──> Step-CA
   |
   +-- :389/:636 ------------> nginx ──> OpenLDAP
```

Certbot uses `dns.{{ domain }}` instead of `adguard.{{ domain }}` for its ACME certificate. DoH requires BIND9 9.18+ (`ubuntu/bind9:latest` shipped 9.20 as of March 2026).

**Enable at install time:**
```bash
sudo ./setup.sh --bind9-only
sudo ./setup.sh --bind9-only --target 192.168.1.5
```

`bind9_only: true` is written to `core/vars.yaml` and persists — subsequent `--update` or `--custom` runs pick it up automatically without re-passing the flag.

## Prerequisites

- Ubuntu 24.04 (other versions will warn but may work)
- Ansible 2.17 – 2.20.x (other versions will warn; tested with ansible-core 2.20.4)
- Root or sudo access
- Network connectivity for pulling Docker images and Ansible packages
- A bootstrap DNS server reachable at the IP set in `vars.yaml` (`dns_server`)

## Installation

**1. Clone and configure**

```bash
git clone <repo-url> ~/home-core
cd ~/home-core
```

Edit `core/vars.yaml` to match your environment. Key values to review:

| Variable | Default | Purpose |
|----------|---------|---------|
| `dns_server` | 192.168.4.1 | Bootstrap DNS before BIND9 is running |
| `ns_host_ip` | 192.168.7.53 | LAN IP of the BIND9 host (auto-injected as NS glue record) |
| `lan_cidr` | 192.168.4.0/22 | UFW firewall allow-source |
| `domain` | home | Top-level domain for all services (supports multi-part, e.g. `home.internal`) |
| `core_subnet` | 172.30.255.0/24 | Docker bridge network CIDR |
| `system_timezone` | America/New_York | Container timezone |
| `acme_email` | admin@email.{{ domain }} | Certbot notification address |
| `cert_country` | US | X.509 subject: Country (C) |
| `cert_province` | Florida | X.509 subject: State/Province (ST) |
| `cert_city` | Brandon | X.509 subject: Locality (L) |
| `cert_org` | Church Family Network | X.509 subject: Organization (O) |
| `cert_ou` | Infrastructure | X.509 subject: Organizational Unit (OU) |
| `cert_root_key_type` | rsa | Root CA key algorithm (`rsa` or `ec`) |
| `cert_root_key_param` | 4096 | RSA key size in bits, or EC curve name (e.g. `secp384r1`) |
| `cert_root_digest` | sha256 | Root CA signature digest |
| `cert_intermediate_key_type` | rsa | Intermediate CA key algorithm (`rsa` or `ec`) |
| `cert_intermediate_key_param` | 4096 | RSA key size in bits, or EC curve name (e.g. `secp256r1`) |
| `cert_intermediate_digest` | sha256 | Intermediate CA signature digest |
| `cert_root_ca_days` | 7300 | Root CA validity in days (~20 years) |
| `cert_intermediate_days` | 5475 | Intermediate CA validity in days (~15 years) |
| `cert_bind9_tls_days` | 5475 | BIND9 static TLS cert validity in days (~15 years) |
| `cert_acme_lifetime_hours` | 1080h | ACME certificate lifetime (45 days) |
| `cert_stepca_max_lifetime_hours` | 87600h | Max cert lifetime Step-CA will issue (10 years) |
| `cert_stepca_allow_subordinate_ca` | true | Allow issuing subordinate intermediate CA certs |
| `cert_acme_renew_before_days` | 15 | Renew ACME certs when this many days remain |
| `cert_renewal_check_hours` | 12 | Certbot renewal check interval in hours |

Edit the `dns` section in `core/vars.yaml` to define your DNS zones and records. Each top-level key is a zone name; zone files are rendered automatically by the playbook from `bind9/data/zone.j2`. The NS glue record (`ns.<domain>`) is auto-generated from `ns_host_ip` for the primary zone — no need to add it manually.

LDAP variables (`ldap_domain_components`, `ldap_base_dn`) are auto-derived from `domain` and support multi-part domains (e.g. `home.internal` → `dc=home,dc=internal`).

AdGuard Home configuration is rendered from `adguardhome/config/AdGuardHome.yaml.j2`. The template deploys with an empty `users` list — after first install, open the AdGuard Home UI and create your admin account. The password is managed entirely through the UI; the template intentionally does not set it because re-rendering would invalidate the stored hash.

DHCP can be enabled/disabled via `adguard_dhcp_enabled` in `vars.yaml`. When enabled, AdGuard serves DHCP on ports 67/68 and advertises `ns_host_ip` as the DNS server to clients.

**2. Run the setup**

```bash
# Local install
sudo ./setup.sh

# Local install — start services automatically when done
sudo ./setup.sh --start

# Remote install (prompts for SSH username and remote sudo password)
sudo ./setup.sh --target 192.168.1.5

# Remote install with explicit SSH user
sudo ./setup.sh --target 192.168.1.5 --ssh-user pi
```

This single command:
1. Configures DNS resolution for bootstrap
2. Installs Ansible and required collections (`community.docker`, `community.general`, `ansible.posix`)
3. Runs the full 14-section playbook which handles everything from Docker installation through certificate issuance

For remote targets, `setup.sh` handles SSH automatically:
- Generates `~/.ssh/id_ed25519` if no keypair exists
- Adds the remote host key to `~/.ssh/known_hosts`
- Copies the public key to the remote via `ssh-copy-id` (prompts once for the remote password)
- Prompts for the remote sudo password before Ansible runs (required because the playbook uses `become: true`)

**3. Start the stack**

After setup completes, start services manually:

```bash
cd /opt/core
sudo docker compose up -d
```

Or pass `--start` to have `setup.sh` start them automatically after the playbook finishes.

## Health Checks

`check.sh` validates the stack in two modes:

**Remote** — network-reachable checks from any machine (no SSH, no root required):
```bash
bash check.sh --target 192.168.7.53
```
Covers: DNS resolution (AdGuard :53, BIND9 :5353), HTTP endpoint reachability, and TLS certificate info. TLS trust is validated against the system store; internal CA certs will show as `[WARN]` with cert details rather than `[FAIL]` since the root CA is not in the system store.

**Local** — full check run on the target itself (requires root):
```bash
sudo bash check.sh
```
Covers everything in remote mode plus: Docker container status and health, CA file presence and expiry, step-ca internal health, certbot certificate expiry, LDAP base search, and BIND9 `rndc status`. TLS checks validate against the internal root CA.

## Version Tracking

Every install and update writes a `.version` file to `/opt/core/.version` recording the git commit hash, date, and branch. Each rendered file also embeds the version in a comment header, so you can identify the source commit of any file in `/opt`:

```bash
# Check installed version
head -5 /opt/core/.version

# Check version of a rendered file
head -5 /opt/core/docker-compose.yml
# => # Version: home-core 4ceb229 (2026-03-27 19:47:52 +0000)
```

## Updating

After making changes in the repo (editing `vars.yaml`, pulling new commits, etc.), use `setup.sh --update` to inspect and apply them to the live installation.

By default, `--update` re-renders **scripts** (`.sh` files, static pages) and **DNS zone data files** (so `vars.yaml` record changes take effect). Other config files (BIND9 named.conf, nginx.conf, docker-compose.yml, AdGuardHome.yaml) are never overwritten unless `--force` is used. This is safe for operational systems where configs may have local modifications.

After applying changes, `--update` automatically restarts all containers so services pick up the new files.

```bash
# Show installed vs repo version
sudo ./setup.sh --update --version

# Git-level change summary
sudo ./setup.sh --update --check

# Dry-run: show exact file diffs for everything (scripts + configs)
sudo ./setup.sh --update --review

# Interactive: review changes, prompt before updating scripts
sudo ./setup.sh --update

# Update scripts without prompting
sudo ./setup.sh --update --apply

# Full sync: overwrite everything including configs (DANGEROUS)
sudo ./setup.sh --update --force --apply

# Update and export build artifacts
sudo ./setup.sh --update --apply --export
sudo ./setup.sh --update --apply --export /srv/home-core/builds
```

Every update automatically archives the current installation to `/opt/core/archive/` before applying changes. This enables rollback if something goes wrong.

### vars.yaml live change history

When using `modify.sh` in interactive mode, it saves a timestamped backup of `vars.yaml` to `/opt/core/archive/vars/` **before** making any changes:

```
/opt/core/archive/vars/
  20260329-031500_tsig-keys_acme_npm.yaml
  20260329-032100_mint-certs_myservice.{{ domain }}.yaml
  20260329-034500_dns-record_internal_A.yaml
```

Each backup is named with the UTC timestamp and a label describing what was about to be added. This history is independent of git — it tracks live system changes even between commits.

To restore a previous state and re-apply:

```bash
# List available backups
ls /opt/core/archive/vars/

# Restore a previous vars.yaml
cp /opt/core/archive/vars/<timestamp>_<label>.yaml ~/home-core/core/vars.yaml

# Re-apply (non-interactive)
sudo bash core/modify.sh --tsig-keys --apply
# or
sudo bash core/modify.sh --mint-certs --apply
# or
sudo bash core/modify.sh --dns-record --apply
```

After applying, the `.version` file is updated to reflect the new commit and all containers are automatically restarted. Future runs of `--check` will diff from this new baseline.

### Build export

Pass `--export [path]` to save a snapshot of the deployed configuration to a local git-tracked directory after any install or update. If no path is given, artifacts are written to `./builds/`.

```bash
# Install and export
sudo ./setup.sh --export
sudo ./setup.sh --export /srv/home-core/builds

# Update and export
sudo ./setup.sh --update --apply --export
sudo ./setup.sh --update --apply --export /srv/home-core/builds

# Remote install with export
sudo ./setup.sh --target 192.168.1.5 --export /srv/home-core/builds
```

On first use the export directory is initialised as a git repository. Each subsequent export commits the current state with a message recording the source commit, target host, timestamp, and mode:

```
build(install): 4ceb229 → 192.168.1.5 [2026-03-29T11:00:00Z]
build(update):  7f3a100 → localhost   [2026-03-29T14:30:00Z]
```

The directory contains the full rendered contents of `/opt/core`, `/opt/nginx`, `/opt/bind9`, and all other service directories — exactly what was deployed. Because git tracks every change, you can diff any two builds:

```bash
cd /srv/home-core/builds

# What changed in the last deploy?
git show --stat

# Diff between two specific builds
git diff HEAD~2 HEAD -- bind9/config/named.conf.zones

# Full history
git log --oneline
```

No change since the previous export results in no commit (the export is a no-op if the target state is identical).

### Custom tag execution

Run specific playbook tags for advanced operations:

```bash
# Run specific tags
sudo ./setup.sh --custom --tags pki,bind9

# Dry-run specific tags
sudo ./setup.sh --custom --tags files --check --diff

# Target a remote host
sudo ./setup.sh --custom --tags update --target 192.168.1.5
```

## Rollback

If an update causes issues, restore a previous installation from the archive:

```bash
sudo ./setup.sh --rollback
```

This presents a list of archived snapshots (created automatically before each update) and prompts you to select one. The current state is archived first, so you can always roll back a rollback.

After restoring, services may need a restart:

```bash
cd /opt/core && sudo docker compose restart
```

## Uninstall

```bash
sudo ./setup.sh --uninstall
```

This interactively tears down the entire home-core installation:

1. Offers to save archived snapshots to another location
2. Offers to create a final backup of the current installation
3. Requires typing `UNINSTALL` to confirm
4. Stops and removes all containers and Docker networks
5. Removes service accounts (nginx, bind, step, ldap, certbot, adguard)
6. Deletes all project directories under `/opt` — including TSIG credential directories (e.g. `/opt/acme_*`)

## What the Playbook Does

The playbook (`core/core-config.yml`) runs 14 sections in order:

| Section | Tag(s) | What it does |
|---------|--------|--------------|
| 1 | `validation` | Asserts Ubuntu OS, warns if Ansible version is outside tested range (2.17 – 2.20.x) |
| 2 | `pkg_mgmt` | Installs system packages (acl, openssl, curl, ufw, etc.) |
| 3 | `docker_engine` | Installs Docker CE from official repo if missing |
| 4 | `cleanup` | Removes any existing project containers |
| 5 | `network` | Disables systemd-resolved stub, frees port 53 |
| 5.5 | `firewall` | Configures UFW (deny incoming, allow LAN for service ports) |
| 6 | `users` | Creates service accounts with designated UID:GID |
| 7a | `files, update` | Renders scripts (.sh) and static pages from templates |
| 7b | `files` | Syncs service dirs, renders configs (BIND9, nginx, compose, LDAP, AdGuard†) |
| 7b+ | `files, update` | Renders DNS zone data files (safe to re-render on update) |
| 7c | `files, update` | Removes .j2 sources, writes .version file |
| 8 | `stepca` | Bootstraps PKI: Root CA, Step-CA init, intermediate cert |
| 9 | `bind9, tsig` | Generates TSIG keys, certbot credentials, BIND9 TLS cert |
| 10 | `certbot, hooks` | Sets up FIFO relay pipe and cert-relay systemd service |
| 11 | `files` | Creates runtime directories (BIND9 var/, AdGuard work/) |
| 13 | `certbot, bootstrap` | Issues initial certs, sets ACLs, starts renewal loop |
| 14 | `verify` | Validates certificates and shuts down bootstrap stack |

† AdGuard config rendering and its work directory are skipped in `--bind9-only` mode.

Run specific sections with tags:

```bash
sudo ./setup.sh --custom --tags files
```

## PKI Chain

```
Root CA (EasyRSA, cert_root_key_type/cert_root_key_param, cert_root_ca_days)
  |
  +-- Intermediate CA (Step-CA, cert_intermediate_key_type/cert_intermediate_key_param, cert_intermediate_days)
       |
       +-- BIND9 DoT cert (static, cert_bind9_tls_days)
       +-- adguard.{{ domain }} (ACME, cert_acme_lifetime_hours, auto-renewed)
       +-- ldap.{{ domain }}    (ACME, cert_acme_lifetime_hours, auto-renewed)
       +-- ca.{{ domain }}      (ACME, cert_acme_lifetime_hours, auto-renewed)
```

- Root CA generated via `easyrsa/sign-certs.sh.j2` running EasyRSA in Docker
- All leaf certificates (ACME and offline) use an X.509 template (`stepca/templates/certs/leaf.tpl.j2`) that injects the organization subject fields (C, ST, L, O, OU) from `vars.yaml` into every issued certificate
- The ACME provisioner in Step-CA's `ca.json` is configured with `options.x509.templateFile` pointing to the rendered template, so certbot-issued certs automatically receive the full distinguished name
- ACME certificates issued by Step-CA, validated via DNS-01 (RFC2136 against BIND9)
- Certbot renewal loop runs every `cert_renewal_check_hours` hours inside its container
- On renewal, the deploy hook signals a host-side relay (via FIFO) to apply filesystem ACLs, then reloads affected services

## Certificate Relay

Certbot runs as a container and cannot call `setfacl` on the host filesystem. The relay solves this:

```
[certbot container]               [host]
cert-update.sh                    cert-relay-host.sh (systemd)
  |                                 |
  +-- writes domain to FIFO -----> reads FIFO
                                    |
                                    +-- setfacl for nginx UID
                                    +-- setfacl for service UID
```

## Issuing Additional Certificates

### Certificate minting with `modify.sh --mint-certs`

The recommended way to mint certificates is through `modify.sh`, which prompts for all required values, saves the entry to `vars.yaml`, archives the previous state, and runs the playbook:

```bash
sudo bash core/modify.sh --mint-certs
```

This will prompt for: Common Name, optional SANs, offline vs ACME mode, and mode-specific options (validity days / output directory for offline; Portainer webhook for ACME). The new entry is appended to `mint_certs` in `vars.yaml` and applied immediately.

To re-apply all entries in `vars.yaml` without prompting:

```bash
sudo bash core/modify.sh --mint-certs --apply
```

## TSIG Key Management

The core certbot service uses a single TSIG key (`acme_dns-01`) scoped to only the `_acme-challenge` TXT records for its managed domains (`certbot_domains` in `vars.yaml`). External ACME clients (Nginx Proxy Manager, other hosts) should use their own keys with their own scoped grants.

### How update-policy grants work

Each TSIG key gets per-record `name` grants in BIND9's `update-policy` that restrict it to the **exact** `_acme-challenge.<record>.<domain>` TXT records it needs — nothing else:

```
update-policy {
    // core-certbot (managed by Ansible from certbot_domains)
    grant "acme_dns-01" name _acme-challenge.adguard.home. TXT;
    grant "acme_dns-01" name _acme-challenge.ldap.home. TXT;
    grant "acme_dns-01" name _acme-challenge.ca.home. TXT;

    // additional keys (managed by modify.sh --tsig-keys)
    grant "acme_npm" name _acme-challenge.jellyfin.home. TXT;
    grant "acme_npm" name _acme-challenge.sonarr.home. TXT;
};
```

Keys in `vars.yaml` use a `domain` + `records` structure to keep hostnames and domain separate:

```yaml
tsig_extra_keys:
  - name: acme_npm
    domain: home
    records:
      - jellyfin
      - sonarr
    out: /opt/npm/rfc2136.ini    # optional
```

The `domain` field defaults to the top-level `domain` var if omitted.

### Adding a TSIG key via `modify.sh`

The recommended way to add a TSIG key is through `modify.sh`, which prompts for all required values, saves the entry to `vars.yaml`, archives the previous state, and applies it to BIND9:

```bash
sudo bash core/modify.sh --tsig-keys
```

This will prompt for: key name, domain, hostnames (one per line), and an optional credentials output path. The new entry is appended to `tsig_extra_keys` in `vars.yaml` and applied immediately.

To re-apply all entries in `vars.yaml` without prompting:

```bash
sudo bash core/modify.sh --tsig-keys --apply
```

When applied, `modify.sh` will:
1. Generate a 256-bit random TSIG secret
2. Append the key block to `/opt/bind9/config/named.conf.keys`
3. Add per-domain `name` grants to the `update-policy` block in `named.conf.zones`
4. Write an `rfc2136.ini` credentials file (default: `/opt/<key-name>/rfc2136.ini`)
5. Reload BIND9 via `rndc reload`

### Listing and removing keys

```bash
# Show all active TSIG keys and their grants from the live BIND9 config
sudo bash core/modify.sh --list-tsig

# Remove a key and all its grants (prompts for key name if omitted)
sudo bash core/modify.sh --remove-tsig acme_npm
```

### Using a key with an external ACME client

The generated `rfc2136.ini` contains everything the client needs:

```ini
dns_rfc2136_server = 172.30.255.30
dns_rfc2136_port = 5353
dns_rfc2136_name = acme_npm
dns_rfc2136_secret = <base64-secret>
dns_rfc2136_algorithm = HMAC-SHA256
dns_rfc2136_base_domain = {{ domain }}
```

**Certbot (on another host):**
```bash
certbot certonly --authenticator dns-rfc2136 \
    --dns-rfc2136-credentials /path/to/rfc2136.ini \
    --server https://ca.{{ domain }}/acme/acme/directory \
    -d jellyfin.{{ domain }} -d sonarr.{{ domain }}
```

**Nginx Proxy Manager:**
```yaml
environment:
  - NODE_EXTRA_CA_CERTS=/etc/ssl/certs/internal-root.crt
  - ACME_SERVER=https://ca.{{ domain }}/acme/acme/directory
dns:
  - 192.168.4.53  # pi-core running BIND9
```
Then in NPM's UI: SSL Certificates → DNS Challenge → RFC2136, using the values from the generated `rfc2136.ini`.

## DNS Record Management

DNS records are defined in the `dns` section of `vars.yaml` and rendered into BIND9 zone files by Ansible. Supported record types: **A**, **AAAA**, **CNAME**, **MX**, **TXT**, **SRV**.

### Structure in vars.yaml

```yaml
dns:
  "{{ domain }}":
    A:
      - name: myhost
        ip: 192.168.7.50
    CNAME:
      - name: myalias
        canonical: myhost
    TXT:
      - name: "@"
        text: "v=spf1 -all"
```

New zones are added as top-level keys under `dns`. The BIND9 `named.conf.zones` file is automatically regenerated to include any new zones.

### Adding a record via `modify.sh`

The recommended approach prompts for all values, archives `vars.yaml`, updates it, re-renders zone files, and reloads BIND9:

```bash
sudo bash core/modify.sh --dns-record
```

You will be prompted for: zone name, record type (A/AAAA/CNAME/MX/TXT/SRV), and the type-specific fields. The record is appended to the correct zone in `vars.yaml` and BIND9 is reloaded via `rndc reload`.

To re-render all zones and reload BIND9 without adding a new record (e.g. after manually editing `vars.yaml`):

```bash
sudo bash core/modify.sh --dns-record --apply
```

### Record type field reference

| Type  | Required fields                                    |
|-------|----------------------------------------------------|
| A     | `name`, `ip`                                       |
| AAAA  | `name`, `ip`                                       |
| CNAME | `name`, `canonical`                                |
| MX    | `name` (usually `@`), `priority`, `exchange`       |
| TXT   | `name`, `text`                                     |
| SRV   | `name`, `priority`, `weight`, `port`, `target`     |

### New zones

Adding a record to a zone that doesn't exist yet will create the zone in `vars.yaml` and generate both the zone data file (`db.<zone>`) and a new entry in `named.conf.zones`. The zone is automatically configured with the standard BIND9 settings (allow-query ACLs, update-policy for ACME keys).

## PKI Info Page

Browse to `https://ca.{{ domain }}/pki` to view:
- Trust chain diagram (Root CA → Intermediate CA → Leaf certificates)
- Download links for root and intermediate CA certificates
- Certificate subject details (C, ST, L, O, OU)
- Platform-specific install instructions (Linux, macOS, Windows, iOS, Android)

The page is rendered from `nginx/pki/index.html.j2` and served as static content by nginx alongside the Step-CA API.

## Nginx Proxy

Nginx handles both Layer 4 (stream) and Layer 7 (http) proxying:

**Stream (L4):**
- DNS UDP/TCP (:53) → AdGuard Home (full mode) or BIND9:5353 (bind9-only)
- DNS-over-TLS (:853) → TLS termination → AdGuard Home (full) or BIND9:5353 (bind9-only)
- LDAP (:389) → OpenLDAP
- LDAPS (:636) → TLS termination → OpenLDAP

**HTTP (L7):**
- Port 80: health check (`/health`), ACME challenges, HTTPS redirect
- Port 443 `adguard.{{ domain }}`: AdGuard Home UI + DNS-over-HTTPS (`/dns-query`) — full mode only
- Port 443 `dns.{{ domain }}` `/dns-query`: DNS-over-HTTPS → BIND9:8053 — bind9-only mode only
- Port 443 `ca.{{ domain }}`: Step-CA API + PKI info page (`/pki`)
- Port 443 `ca.{{ domain }}/pki`: Download root and intermediate CA certificates, view trust chain, platform-specific install and download instructions (wget/curl/Invoke-WebRequest/Safari/Chrome)

## Firewall

UFW is configured to deny all incoming traffic except from `lan_cidr` (default `192.168.0.0/16`):

| Port | Protocol | Service |
|------|----------|---------|
| 22 | TCP | SSH |
| 53 | TCP/UDP | DNS |
| 80 | TCP | HTTP |
| 443 | TCP | HTTPS |
| 853 | TCP | DNS-over-TLS |
| 389 | TCP | LDAP |
| 636 | TCP | LDAPS |

## Jinja2 Templates

All `.j2` files are rendered from variables during playbook execution. After rendering, `.j2` source files are removed from `/opt` to keep install directories clean.

| Template | Rendered to | Key variables used |
|----------|-------------|-------------------|
| `core/docker-compose.yml.j2` | `/opt/core/docker-compose.yml` | service_users, IPs, URLs, ports |
| `nginx/nginx.conf.j2` | `/opt/nginx/nginx.conf` | url_*, nginx_backend_*, stepca_port |
| `nginx/pki/index.html.j2` | `/opt/nginx/pki/index.html` | ca_name, cert_org, cert_*_key_type, cert_*_key_param, domain, url_stepca |
| `certbot/cert-relay-host.sh.j2` | `/opt/certbot/cert-relay-host.sh` | target_base, service_users, url_* |
| `certbot/hooks/cert-update.sh.j2` | `/opt/certbot/hooks/cert-update.sh` | url_adguard, url_ldap |
| `adguardhome/config/AdGuardHome.yaml.j2` | `/opt/adguardhome/config/AdGuardHome.yaml` | adguard_*, url_adguard, domain, lan_gateway, ns_host_ip |
| `easyrsa/sign-certs.sh.j2` | `/opt/easyrsa/sign-certs.sh` | cert_root_key_type, cert_root_key_param, cert_root_digest, cert_country, cert_province, cert_city, cert_org, cert_ou |
| `stepca/templates/certs/leaf.tpl.j2` | `/opt/stepca/data/templates/certs/leaf.tpl` | cert_country, cert_province, cert_city, cert_org, cert_ou |
| `bind9/config/named.conf*.j2` | `/opt/bind9/config/named.conf*` | bind_acls, tsig_key_name, bind_dns_port, certbot_domains, domain |
| `bind9/data/zone.j2` | `/opt/bind9/data/db.<zone>` (per zone) | domain, dns |
| `openldap/*.ldif.j2` | `/opt/openldap/*.ldif` | ldap_base_dn, ldap_domain_components, ldap_organizational_units, ldap_groups |

All variables are defined in `core/vars.yaml`. Change values there; never edit rendered files on the target directly.

`vars.yaml` supports Jinja2 expressions in dictionary keys (e.g. `"{{ domain }}"` as a DNS zone name). The playbook pre-renders `vars.yaml` through Jinja2 before loading it, so all expressions — including dict keys — are resolved. A rendered copy is saved to `/opt/core/vars.yaml`.

## Customization Checklist

Before first run, review and edit:

- [ ] `core/vars.yaml` -- IPs, domain, timezone, email, certificate subject fields (org, country, etc.)
- [ ] `dns` in `core/vars.yaml` -- DNS zones and A/CNAME records for your hosts
- [ ] `adguard_*` in `core/vars.yaml` -- upstream DNS, DHCP settings, DNS rewrites
- [ ] After first deploy, create admin account via AdGuard Home UI (password not managed by template)
