# Core Template Configuration Variables

This document details all available configuration variables that can be defined in your `custom-vars.yaml` file. 

The `custom-vars.yaml` file acts as the single source of truth for rendering the infrastructure environment. While only a handful of variables are required (and included in the default `custom-vars-tpl.yml`), you may optionally define any of the variables below to override the backend system defaults.

---

## 1. Global / Core Options
These variables define top-level identity and basic settings.

### `domain`
**Description:** The base domain for the local network (e.g. `lan.example.com`). **Required.**

**Default Value:** *(Mandatory - Template: `example.com`)*

**Effected Jinja Templates:**
- `bind9/data/reverse-zone.j2`
- `bind9/data/zone.j2`
- `docs/testplan.md.j2`
- `nginx/www/certificates/index.html.j2`
- `nginx/www/certificates/install-certs.sh.j2`
- `openldap/docker-compose.yml.j2`
- `vars.yaml.j2`

### `domain_file`
**Description:** The domain name formatted for use as a filename (dots replaced with underscores).

**Default Value:** `domain` with `.` replaced by `_`

**Effected Jinja Templates:**
- `nginx/nginx.conf.j2`
- `nginx/www/certificates/index.html.j2`
- `nginx/www/certificates/install-all-ubuntu.sh.j2`
- `nginx/www/certificates/install-certs.sh.j2`
- `vars.yaml.j2`

### `hostname`
**Description:** The hostname of the Docker host server. **Required.**

**Default Value:** *(Mandatory - Template: `core-server`)*

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `friendly_name`
**Description:** A friendly display name for organizations or the CA.

**Default Value:** `"Example Org"`

**Effected Jinja Templates:**
- `nginx/www/certificates/index.html.j2`
- `nginx/www/certificates/install-certs.sh.j2`
- `nginx/www/certificates/install-chrome-ubuntu.sh.j2`
- `nginx/www/certificates/install-firefox-ubuntu.sh.j2`
- `nginx/www/certificates/install-python-ubuntu.sh.j2`
- `nginx/www/landing/index.html.j2`
- `nginx/www/manual/index.html.j2`
- `vars.yaml.j2`

### `service_mark`
**Description:** Text to display with the Service Mark (`℠`) symbol in the footer.

**Default Value:** `""`

### `trademark`
**Description:** Text to display with the Trademark (`™`) symbol in the footer.

**Default Value:** `""`

### `copyright`
**Description:** Copyright holder/year to display with the Copyright (`©`) symbol in the footer.

**Default Value:** `""`

### `contact_email`
**Description:** Contact email address displayed in the footer.

**Default Value:** `""`

### `contact_phone`
**Description:** Contact phone number displayed in the footer.

**Default Value:** `""`

### `address_line1`
**Description:** Primary address line displayed in the footer.

**Default Value:** `""`

### `address_line2`
**Description:** Secondary address line (e.g., Suite, City, State) displayed in the footer.

**Default Value:** `""`

### `care_of`
**Description:** Attribution text displayed with the Care Of (`℅`) symbol in the footer. Replaces the legacy `vendor` variable.

**Default Value:** `""`

### `system_timezone`
**Description:** The timezone for the server/containers.

**Default Value:** `"America/New_York"`

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `deploy_base_dir`
**Description:** The base directory on the host where project data and configs will be deployed.

**Default Value:** `"/opt"`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `bind9/docker-compose.yml.j2`
- `docs/testplan.md.j2`
- `keycloak/docker-compose.yml.j2`
- `nginx/docker-compose.yml.j2`
- `openldap/docker-compose.yml.j2`
- `postgres/docker-compose.yml.j2`
- `stepca/docker-compose.yml.j2`
- `systemd/wrapper.service.j2`
- `vars.yaml.j2`

### `repo_source`
**Description:** Absolute path to the template repository source directory.

**Default Value:** *(Ansible Playbook Parent Directory)*

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `vars.yaml.j2`


## 2. Networking & DNS
> [!WARNING]
> Editing core networking configurations post-deployment can impact routing and require widespread service restarts. Proceed with caution.

These settings dictate how containers route traffic and how the BIND9 DNS server handles resolution.

### `host_ip`
**Description:** The primary IP address of the Docker host. **Required.**

**Default Value:** *(Mandatory - Template: `192.168.1.100`)*

**Effected Jinja Templates:**
- `bind9/data/zone.j2`
- `docs/testplan.md.j2`
- `nginx/docker-compose.yml.j2`
- `vars.yaml.j2`

### `lan_cidr`
**Description:** The subnet representing your local LAN clients.

**Default Value:** *(Mandatory - Template: `192.168.1.0/24`)*

**Effected Jinja Templates:**
- `docs/testplan.md.j2`
- `vars.yaml.j2`

### `lan_gateway`
**Description:** The default gateway router IP for your LAN.

**Default Value:** *(Mandatory - Template: `192.168.1.1`)*

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `core_subnet`
**Description:** The internal Docker bridge subnet for the core template.

**Default Value:** `10.255.0.0/24`

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `use_host_dns`
**Description:** If `true`, the host's existing `resolv.conf` is used during deployment. If `false`, systemd-resolved is reconfigured to use `dns_server`.

**Default Value:** `true`

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `dns_server`
**Description:** External upstream DNS server to forward queries to (e.g., `8.8.8.8`).

**Default Value:** `"8.8.8.8"`

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `bind_dns_port`
**Description:** The port BIND9 listens on for standard DNS (UDP/TCP).

**Default Value:** `5353`

**Effected Jinja Templates:**
- `bind9/config/named.conf.options.j2`
- `bind9/docker-compose.yml.j2`
- `docs/testplan.md.j2`
- `vars.yaml.j2`

### `bind9_doh_port`
**Description:** The port BIND9 listens on for DNS-over-HTTPS.

**Default Value:** `8053`

**Effected Jinja Templates:**
- `bind9/config/named.conf.options.j2`
- `bind9/config/named.conf.tls.j2`
- `nginx/nginx.conf.j2`
- `vars.yaml.j2`


### Advanced DNS Dictionary Variables

*   **`dns`**: A structured dictionary that defines your DNS records. Keys represent zone files (where `dynamic_zone_var` automatically correlates to your base `domain`).
*   **`bind_acls`**: Lists of IP ranges granted query/update permissions.
*   **`tsig_keys`**: List of dictionaries defining ACME update keys (used for DNS-01 challenges).

**Example DNS Configuration (`custom-vars.yaml`):**
```yaml
dns:
  dynamic_zone_var:
    zone_authority: true
    A:
    - { ip: "{{ host_ip }}", name: "{{ hostname }}" }
    - { ip: 192.168.1.10, name: server1 }
    AAAA:
    - { ip: "2001:db8::1", name: ipv6-host }
    CNAME:
    - { canonical: "{{ hostname }}", name: www }
    - { canonical: server1, name: ftp }
    MX:
    - { exchange: mail.example.com., priority: 10, name: "@" }
    TXT:
    - { text: "v=spf1 mx ~all", name: "@" }
    SRV:
    - { target: server1, port: 8080, priority: 10, weight: 5, name: _http._tcp }
```


## 3. PKI & Certificates (Step-CA)
These variables define how the internal Certificate Authority generates and signs certificates.

### `ca_name`
**Description:** The Common Name (CN) of the Root CA.

**Default Value:** `friendly_name` + `" CA"`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `cert_country`
**Description:** The country field (C) for the certificates.

**Default Value:** `"US"`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `nginx/www/certificates/index.html.j2`
- `stepca/leaf.tpl.j2`
- `stepca/subca.tpl.j2`
- `vars.yaml.j2`

### `cert_province`
**Description:** The state/province field (ST) for the certificates.

**Default Value:** `"State"`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `nginx/www/certificates/index.html.j2`
- `stepca/leaf.tpl.j2`
- `stepca/subca.tpl.j2`
- `vars.yaml.j2`

### `cert_city`
**Description:** The city/locality field (L) for the certificates.

**Default Value:** `"City"`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `nginx/www/certificates/index.html.j2`
- `stepca/leaf.tpl.j2`
- `stepca/subca.tpl.j2`
- `vars.yaml.j2`

### `cert_org`
**Description:** The organization field (O) for the certificates.

**Default Value:** `friendly_name`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `nginx/www/certificates/index.html.j2`
- `openldap/docker-compose.yml.j2`
- `stepca/leaf.tpl.j2`
- `stepca/subca.tpl.j2`
- `vars.yaml.j2`

### `cert_ou`
**Description:** The organizational unit field (OU) for the certificates.

**Default Value:** `"IT"`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `nginx/www/certificates/index.html.j2`
- `stepca/leaf.tpl.j2`
- `stepca/subca.tpl.j2`
- `vars.yaml.j2`

### `cert_root_ca_days`
**Description:** The validity lifetime (in days) of the Root CA.

**Default Value:** `1825` (5 years)

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `nginx/www/certificates/index.html.j2`
- `vars.yaml.j2`

### `cert_root_digest`
**Description:** The signature hash algorithm for the Root CA.

**Default Value:** `"sha512"`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `cert_root_key_type`
**Description:** The key type for the Root CA (e.g., rsa, ecdsa, ed25519).

**Default Value:** `"rsa"`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `nginx/www/certificates/index.html.j2`
- `vars.yaml.j2`

### `cert_root_key_param`
**Description:** The key parameter for the Root CA (e.g., 4096).

**Default Value:** `"4096"`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `nginx/www/certificates/index.html.j2`
- `vars.yaml.j2`

### `cert_intermediate_days`
**Description:** The validity lifetime (in days) of the Intermediate CA.

**Default Value:** `1095` (3 years)

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `nginx/www/certificates/index.html.j2`
- `vars.yaml.j2`

### `cert_intermediate_digest`
**Description:** The signature hash algorithm for the Intermediate CA.

**Default Value:** `"sha512"`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `cert_intermediate_key_type`
**Description:** The key type for the Intermediate CA.

**Default Value:** `"rsa"`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `nginx/www/certificates/index.html.j2`
- `vars.yaml.j2`

### `cert_intermediate_key_param`
**Description:** The key parameter for the Intermediate CA.

**Default Value:** `"4096"`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `nginx/www/certificates/index.html.j2`
- `vars.yaml.j2`

### `cert_service_days`
**Description:** The maximum validity lifetime (in days) of leaf certificates.

**Default Value:** `365` (1 year)

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `cert_acme_lifetime_hours`
**Description:** The default validity of certificates requested via ACME.

**Default Value:** `"720h"` (30 days)

**Effected Jinja Templates:**
- `nginx/www/certificates/index.html.j2`
- `vars.yaml.j2`

### `stepca_port`
**Description:** The port Step-CA listens on.

**Default Value:** `9000`

**Effected Jinja Templates:**
- `nginx/nginx.conf.j2`
- `stepca/docker-compose.yml.j2`
- `vars.yaml.j2`

### `stepca_cert_allow_subordinate_ca`
**Description:** Whether Step-CA allows signing subordinate CA certs.

**Default Value:** `true`

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `stepca_cert_max_lifetime_hours`
**Description:** The max lifetime Step-CA will issue a certificate for.

**Default Value:** `cert_service_days * 24h`

**Effected Jinja Templates:**
- `vars.yaml.j2`


### Bring Your Own Certificates (BYOC)
If you already possess a securely offline-generated Root and Intermediate CA, you can import them instead of letting Step-CA mint its own.

### `byoc`
**Description:** Set to `true` to enable importing your own CAs.

**Default Value:** `false`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `root_cert_name`
**Description:** Basename (without extension) for the imported root CA.

**Default Value:** `"root_ca"`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `nginx/nginx.conf.j2`
- `nginx/www/certificates/index.html.j2`
- `nginx/www/certificates/install-certs.sh.j2`
- `nginx/www/certificates/install-chrome-ubuntu.sh.j2`
- `nginx/www/certificates/install-firefox-ubuntu.sh.j2`
- `nginx/www/certificates/install-python-ubuntu.sh.j2`
- `vars.yaml.j2`

### `ca_crt_path`
**Description:** Absolute path to your existing Root CA certificate.

**Default Value:** `"/home/default_admin/output/root_ca.crt"`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `ica_crt_path`
**Description:** Absolute path to your existing Intermediate CA certificate.

**Default Value:** `"/home/default_admin/output/ica.crt"`

**Immutable:** Yes 🔒

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `ica_key_path`
**Description:** Absolute path to your existing Intermediate CA private key.

**Default Value:** *(None)*

**Immutable:** Yes 🔒


## 4. Docker Infrastructure
Allows deep customization of the container orchestration, including overriding images and statically assigning internal IPs on the Docker bridge.

### General Orchestration
### `compose_file`
**Description:** Path to the generated `docker-compose.yml` file.

**Default Value:** `deploy_base_dir` + `"/core/docker-compose.yml"`

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `project_containers`
**Description:** List of containers to include in deployment.

**Default Value:** `['nginx', 'step-ca', 'bind9']` (plus conditionally enabled services)

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `nginx_backend_ldap`
**Description:** Upstream target for Nginx LDAP proxy.

**Default Value:** `"openldap:389"`

**Effected Jinja Templates:**
- `nginx/nginx.conf.j2`
- `vars.yaml.j2`

### `nginx_backend_stepca`
**Description:** Upstream target for Nginx Step-CA proxy.

**Default Value:** `"https://step-ca:9000"`

**Effected Jinja Templates:**
- `nginx/nginx.conf.j2`
- `vars.yaml.j2`

### `keycloak_data_dir`
**Description:** Directory where Keycloak persists its data.

**Default Value:** `deploy_base_dir` + `"/keycloak/data"`

**Effected Jinja Templates:**
- `keycloak/docker-compose.yml.j2`
- `vars.yaml.j2`

### `postgres_data_dir`
**Description:** Directory where the Postgres database persists its data.

**Default Value:** `deploy_base_dir` + `"/postgres/data"`

**Effected Jinja Templates:**
- `postgres/docker-compose.yml.j2`
- `vars.yaml.j2`

### `host_ram_capacity`
**Description:** Host RAM limit in GB (min 3) to enforce memory ceilings and staggered boots. `0` disables limits.

**Default Value:** `0`


### Internal IP Assignments
| Variable | Default Value |
|----------|---------------|
| `ip_nginx` | `"10.255.0.10"` |
| `ip_bind9` | `"10.255.0.30"` |
| `ip_stepca` | `"10.255.0.40"` |
| `ip_ldap` | `"10.255.0.50"` |
| `ip_keycloak` | `"10.255.0.60"` |
| `ip_postgres` | `"10.255.0.70"` |

### Container Images
| Variable | Default Value |
|----------|---------------|
| `image_nginx` | `"nginx:latest"` |
| `image_bind9` | `"ubuntu/bind9:latest"` |
| `image_stepca` | `"smallstep/step-ca:latest"` |
| `image_openldap`| `"osixia/openldap:latest"` |
| `image_keycloak`| `"keycloak/keycloak:latest"` |
| `image_postgres`| `"postgres:latest"` |

### Service CNAMEs
Allows overriding the default short hostnames (CNAMEs) automatically assigned to the services.
| Variable | Default Value |
|----------|---------------|
| `cname_ca` | `"ca"` |
| `landing_page_cname` | `""` (Empty string, defaults to root domain) |
| `cname_dns` | `"dns"` |
| `cname_ldap` | `"ldap"` |
| `cname_sso` | `"sso"` |

### Internal Subdomain Routing (Nginx)
By default, the fully qualified hostnames are constructed using the CNAMEs above appended with the base `domain`.
| Variable | Default Value |
|----------|---------------|
| `hostname_nginx` | `"nginx." + domain` |
| `hostname_bind9` | `cname_dns + "." + domain` |
| `hostname_stepca` | `cname_ca + "." + domain` |
| `hostname_landing` | `landing_page_cname + "." + domain` (or `domain` if empty) |
| `hostname_ldap` | `cname_ldap + "." + domain` |
| `hostname_keycloak`| `cname_sso + "." + domain` |

## 5. Security Contexts & Features
Toggle features and control system-level UNIX isolation mapping.

### `install_ldap`
**Description:** Toggles whether the OpenLDAP container is deployed.

**Default Value:** `false`

**Effected Jinja Templates:**
- `vars.yaml.j2`

### `install_keycloak`
**Description:** Toggles whether Keycloak (and PostgreSQL) are deployed.

**Default Value:** `false`

**Effected Jinja Templates:**
- `nginx/nginx.conf.j2`
- `nginx/www/landing/index.html.j2`
- `vars.yaml.j2`

### `service_users`
**Description:** Dictionary mapping container names to UID/GID objects for setting permissions.

**Default Value:** *(See default configuration below)*

**Effected Jinja Templates:**
- `bind9/docker-compose.yml.j2`
- `keycloak/docker-compose.yml.j2`
- `nginx/docker-compose.yml.j2`
- `nginx/nginx.conf.j2`
- `postgres/docker-compose.yml.j2`
- `stepca/docker-compose.yml.j2`
- `vars.yaml.j2`

### `service_dirs`
**Description:** List defining data directories and their owning users to create.

**Default Value:** *(See default configuration below)*

**Effected Jinja Templates:**
- `vars.yaml.j2`


### Default Security Contexts

**`service_users` Default:**
```yaml
service_users:
  bind:     { uid: 53,  gid: 53 }
  ldap:     { uid: 389, gid: 389 }
  nginx:    { uid: 443, gid: 443 }
  step:     { uid: 135, gid: 135 }
  keycloak: { uid: 900, gid: 0 }
  postgres: { uid: 901, gid: 901 }
```

**`service_dirs` Default:**
```yaml
service_dirs:
  - { folder: nginx,    owner: nginx }
  - { folder: bind9,    owner: bind }
  - { folder: stepca,   owner: step }
  - { folder: openldap, owner: ldap }
  - { folder: keycloak, owner: keycloak }
  - { folder: postgres, owner: postgres }
```

## 6. OpenLDAP Specifics
If `install_ldap` is enabled, these settings govern the directory structure.

### `ldap_base_dn`
**Description:** Base distinguished name, automatically computed from `domain`.

**Default Value:** `dc=lan,dc=example,dc=com`

**Effected Jinja Templates:**
- `openldap/02-ous.ldif.j2`
- `openldap/03-groups.ldif.j2`
- `openldap/05-admins.ldif.j2`
- `openldap/06-acl.ldif.j2`
- `openldap/base.ldif.j2`
- `openldap/docker-compose.yml.j2`

### `ldap_groups`
**Description:** Defines the security groups to pre-provision in LDAP.

**Default Value:** `[{name: admins, gidNumber: 1100, permissions: [read, write, modify]}, ...]`

**Effected Jinja Templates:**
- `openldap/03-groups.ldif.j2`
- `vars.yaml.j2`

### `ldap_organizational_units`
**Description:** Defines the tree structure/OUs to pre-provision.

**Default Value:** `[{name: accounts, description: User Accounts}, ...]`

**Effected Jinja Templates:**
- `openldap/02-ous.ldif.j2`
- `vars.yaml.j2`


**Example LDAP Configuration (`custom-vars.yaml`):**
```yaml
ldap_groups:
- { gidNumber: 1100, name: admins, permissions: [read, write, modify] }
- { gidNumber: 1200, name: developers, permissions: [read, write] }
- { gidNumber: 1300, name: operations, permissions: [read, write] }
- { gidNumber: 5000, name: users, permissions: [read] }

ldap_organizational_units:
- { name: accounts, description: User Accounts }
- { name: groups, description: Security Groups }
- { name: admins, description: Privileged accounts, parent: accounts, uid_range: 1101-1999 }
- { name: users, description: Regular User accounts, parent: accounts, uid_range: 5001-50000 }
- { name: hosts, description: Computer objects, uid_range: 2000-4900 }
- { name: services, description: Service Accounts }
```

## 7. Landing Page Links (`link-vars.yaml`)
The `link-vars.yaml` file (or `link-vars-template.yaml`) defines the dynamic list of quick links shown on the Core Infrastructure Landing Portal. It is managed interactively via `core-mgr` under the **Landing Page Links** menu.

### `links`
**Description:** A list of dictionaries containing `name` and `link` keys for each quick link to display on the landing page. The `link` values can use Jinja variables like `{{ domain }}` or `{{ hostname_keycloak }}` which will be evaluated natively during deployment.

**Default Value:**
```yaml
links:
  - name: Keycloak (Admin)
    link: "sso.{{ domain }}/admin"
```

**Effected Jinja Templates:**
- `nginx/www/landing/index.html.j2`
