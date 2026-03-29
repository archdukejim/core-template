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
| nginx | 172.30.255.10 | core-proxy.internal | 443:443 |
| AdGuard Home | 172.30.255.20 | adguard.internal | 153:153 |
| BIND9 | 172.30.255.30 | dns.internal | 53:53 |
| Step-CA | 172.30.255.40 | ca.internal | 135:135 |
| OpenLDAP | 172.30.255.50 | ldap.internal | 389:389 |
| Certbot | (dynamic) | -- | 0:0 (root) |

## Repository Layout

```
home-core/
  setup.sh                    # Unified entry point: install, update, rollback, uninstall
  core/
    ansible.cfg               # Ansible settings (Python interpreter, facts behavior)
    core-setup.yml            # 14-section Ansible playbook (the entire setup)
    vars.yaml                 # All infrastructure variables
    version.sh                # Shared version utilities (sourced by setup.sh)
    docker-compose.yml.j2     # Compose template rendered from vars
    mint-cert.sh.j2           # Certificate minting template (offline + ACME modes)
    add-tsig-key.sh.j2        # TSIG key management template
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
      named.conf.tls.j2       # TLS profile for DoT
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
| `domain` | internal | Top-level domain for all services (supports multi-part, e.g. `home.internal`) |
| `core_subnet` | 172.30.255.0/24 | Docker bridge network CIDR |
| `system_timezone` | America/New_York | Container timezone |
| `acme_email` | admin@email.internal | Certbot notification address |
| `cert_country` | US | X.509 subject: Country (C) |
| `cert_province` | Florida | X.509 subject: State/Province (ST) |
| `cert_city` | Brandon | X.509 subject: Locality (L) |
| `cert_org` | Church Family Network | X.509 subject: Organization (O) |
| `cert_ou` | Infrastructure | X.509 subject: Organizational Unit (OU) |
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
# Local install (default)
sudo ./setup.sh

# Remote install
sudo ./setup.sh --target 192.168.1.5
```

This single command:
1. Configures DNS resolution for bootstrap
2. Installs Ansible and required collections (`community.docker`, `community.general`, `ansible.posix`)
3. Runs the full 14-section playbook which handles everything from Docker installation through certificate issuance

**3. Start the stack**

After setup completes, start services:

```bash
cd /opt/core
sudo docker compose up -d
```

## Version Tracking

Every install and update writes a `.version` file to `/opt/core/.version` recording the git commit hash, date, and branch. Each rendered file also embeds the version in a comment header, so you can identify the source commit of any file in `/opt`:

```bash
# Check installed version
head -5 /opt/core/.version

# Check version of a rendered file
head -5 /opt/core/mint-cert.sh
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
```

Every update automatically archives the current installation to `/opt/core/archive/` before applying changes. This enables rollback if something goes wrong.

After applying, the `.version` file is updated to reflect the new commit and all containers are automatically restarted. Future runs of `--check` will diff from this new baseline.

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
6. Deletes all project directories under `/opt`

## What the Playbook Does

The playbook (`core/core-setup.yml`) runs 14 sections in order:

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
| 7b | `files` | Syncs service dirs, renders configs (BIND9, nginx, compose, LDAP, AdGuard) |
| 7b+ | `files, update` | Renders DNS zone data files (safe to re-render on update) |
| 7c | `files, update` | Removes .j2 sources, writes .version file |
| 8 | `stepca` | Bootstraps PKI: Root CA, Step-CA init, intermediate cert |
| 9 | `bind9, tsig` | Generates TSIG keys, certbot credentials, BIND9 TLS cert |
| 10 | `certbot, hooks` | Sets up FIFO relay pipe and cert-relay systemd service |
| 11 | `files` | Creates runtime directories (BIND9 var/, AdGuard work/) |
| 13 | `certbot, bootstrap` | Issues initial certs, sets ACLs, starts renewal loop |
| 14 | `verify` | Validates certificates and shuts down bootstrap stack |

Run specific sections with tags:

```bash
sudo ./setup.sh --custom --tags files
```

## PKI Chain

```
Root CA (EasyRSA, ECC P-384, cert_root_ca_days)
  |
  +-- Intermediate CA (Step-CA, signed by Root, cert_intermediate_days)
       |
       +-- BIND9 DoT cert (static, cert_bind9_tls_days)
       +-- adguard.internal (ACME, cert_acme_lifetime_hours, auto-renewed)
       +-- ldap.internal    (ACME, cert_acme_lifetime_hours, auto-renewed)
       +-- ca.internal      (ACME, cert_acme_lifetime_hours, auto-renewed)
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

### Certificate minting with `mint-cert.sh`

`mint-cert.sh` is a single script for issuing leaf certificates in two modes:

**Offline mode (default)** — signs directly with the intermediate CA key. Useful for services that don't support ACME or need long-lived certs:

```bash
# Generate a new key + cert (exported to calling user's home directory)
sudo ./core/mint-cert.sh --cn myservice.internal

# With additional SANs and custom validity
sudo ./core/mint-cert.sh --cn myservice.internal --san api.internal --days 730

# Use an existing private key
sudo ./core/mint-cert.sh --cn myservice.internal --key /path/to/existing.key

# Override output directory
sudo ./core/mint-cert.sh --cn myservice.internal --out-dir /opt/myservice/ssl
```

**ACME mode (`--renew`)** — uses Certbot + DNS-01 for auto-renewed 45-day certificates:

```bash
sudo ./core/mint-cert.sh --cn myservice.internal --renew
sudo ./core/mint-cert.sh --cn app.internal --san api.internal --renew
sudo ./core/mint-cert.sh --cn app.internal --renew --portainer-webhook https://portainer.example/api/stacks/webhooks/abc
```

ACME mode temporarily stops the certbot renewal loop, runs a one-off certbot container, then restarts the loop. The new certificate is automatically managed by future renewals.

The script detects `$SUDO_USER` and exports the key/cert to the real user's home directory with correct ownership. Both modes produce certificates with full X.509 subject fields from the shared leaf template.

## TSIG Key Management

The core certbot service uses a single TSIG key (`acme_dns-01`) scoped to only the `_acme-challenge` TXT records for its managed domains (`certbot_domains` in `vars.yaml`). External ACME clients (Nginx Proxy Manager, other hosts) should use their own keys with their own scoped grants.

### How update-policy grants work

Each TSIG key gets per-domain `name` grants in BIND9's `update-policy` that restrict it to the **exact** `_acme-challenge.<domain>` TXT records it needs — nothing else:

```
update-policy {
    // core-certbot (managed by Ansible from certbot_domains)
    grant "acme_dns-01" name _acme-challenge.adguard.internal. TXT;
    grant "acme_dns-01" name _acme-challenge.ldap.internal. TXT;
    grant "acme_dns-01" name _acme-challenge.ca.internal. TXT;

    // additional keys (managed by add-tsig-key.sh)
    grant "acme_npm" name _acme-challenge.jellyfin.internal. TXT;
    grant "acme_npm" name _acme-challenge.sonarr.internal. TXT;
};
```

### Adding a TSIG key

Use `add-tsig-key.sh` to create a new key scoped to specific domains. Each `--scope` creates an exact-match grant for that domain's ACME challenge record:

```bash
# Key for Nginx Proxy Manager managing several app proxies
sudo ./core/add-tsig-key.sh --name acme_npm \
    --scope jellyfin.internal \
    --scope sonarr.internal \
    --scope radarr.internal

# Key for a VPN server (single domain)
sudo ./core/add-tsig-key.sh --name acme_vpn --scope vpn.internal

# Custom output path for the credentials file
sudo ./core/add-tsig-key.sh --name acme_apps \
    --scope calibre.internal --scope binge.internal \
    --out /home/user/rfc2136.ini
```

The script:
1. Generates a 256-bit random TSIG secret
2. Appends the key to `named.conf.keys`
3. Adds per-domain `name` grants to the `update-policy` block in `named.conf.zones`
4. Writes an `rfc2136.ini` credentials file (default: `/opt/<key-name>/rfc2136.ini`)
5. Reloads BIND9 via `rndc reload`

### Listing and removing keys

```bash
# List all TSIG keys and their grants
sudo ./core/add-tsig-key.sh --list

# Remove a key and all its grants
sudo ./core/add-tsig-key.sh --remove acme_npm
```

### Using a key with an external ACME client

The generated `rfc2136.ini` contains everything the client needs:

```ini
dns_rfc2136_server = 172.30.255.30
dns_rfc2136_port = 5353
dns_rfc2136_name = acme_npm
dns_rfc2136_secret = <base64-secret>
dns_rfc2136_algorithm = HMAC-SHA256
dns_rfc2136_base_domain = internal
```

**Certbot (on another host):**
```bash
certbot certonly --authenticator dns-rfc2136 \
    --dns-rfc2136-credentials /path/to/rfc2136.ini \
    --server https://ca.internal/acme/acme/directory \
    -d jellyfin.internal -d sonarr.internal
```

**Nginx Proxy Manager:**
```yaml
environment:
  - NODE_EXTRA_CA_CERTS=/etc/ssl/certs/internal-root.crt
  - ACME_SERVER=https://ca.internal/acme/acme/directory
dns:
  - 192.168.4.53  # pi-core running BIND9
```
Then in NPM's UI: SSL Certificates → DNS Challenge → RFC2136, using the values from the generated `rfc2136.ini`.

## PKI Info Page

Browse to `https://ca.internal/pki` to view:
- Trust chain diagram (Root CA → Intermediate CA → Leaf certificates)
- Download links for root and intermediate CA certificates
- Certificate subject details (C, ST, L, O, OU)
- Platform-specific install instructions (Linux, macOS, Windows, iOS, Android)

The page is rendered from `nginx/pki/index.html.j2` and served as static content by nginx alongside the Step-CA API.

## Nginx Proxy

Nginx handles both Layer 4 (stream) and Layer 7 (http) proxying:

**Stream (L4):**
- DNS UDP/TCP (:53) -> AdGuard Home
- DNS-over-TLS (:853) -> TLS termination -> AdGuard Home
- LDAP (:389) -> OpenLDAP
- LDAPS (:636) -> TLS termination -> OpenLDAP

**HTTP (L7):**
- Port 80: health check (`/health`), ACME challenges, HTTPS redirect
- Port 443 `adguard.internal`: AdGuard Home UI + DNS-over-HTTPS (`/dns-query`)
- Port 443 `ca.internal`: Step-CA API + PKI info page (`/pki`)
- Port 443 `ca.internal/pki`: Download root and intermediate CA certificates, view trust chain, platform-specific install instructions

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
| `core/add-tsig-key.sh.j2` | `/opt/core/add-tsig-key.sh` | target_base, service_users.bind, ip_bind9, bind_dns_port, domain, tsig_algorithm |
| `core/mint-cert.sh.j2` | `/opt/core/mint-cert.sh` | target_base, service_users.step, domain |
| `nginx/nginx.conf.j2` | `/opt/nginx/nginx.conf` | url_*, nginx_backend_*, stepca_port |
| `nginx/pki/index.html.j2` | `/opt/nginx/pki/index.html` | ca_name, cert_org, cert_*, domain, url_stepca |
| `certbot/cert-relay-host.sh.j2` | `/opt/certbot/cert-relay-host.sh` | target_base, service_users, url_* |
| `certbot/hooks/cert-update.sh.j2` | `/opt/certbot/hooks/cert-update.sh` | url_adguard, url_ldap |
| `adguardhome/config/AdGuardHome.yaml.j2` | `/opt/adguardhome/config/AdGuardHome.yaml` | adguard_*, url_adguard, domain, lan_gateway, ns_host_ip |
| `easyrsa/sign-certs.sh.j2` | `/opt/easyrsa/sign-certs.sh` | cert_country, cert_province, cert_city, cert_org, cert_ou |
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
