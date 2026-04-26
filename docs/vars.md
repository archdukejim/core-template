# Core Template Configuration Variables

This document details all available configuration variables that can be defined in your `custom-vars.yaml` file. 

The `custom-vars.yaml` file acts as the single source of truth for rendering the infrastructure environment. While only a handful of variables are required (and included in the default `custom-vars-tpl.yml`), you may optionally define any of the variables below to override the backend system defaults.

---

## 1. Global / Core Options
These variables define top-level identity and basic settings.

| Variable | Description | Default Value (if omitted) |
|----------|-------------|----------------------------|
| `domain` | The base domain for the local network (e.g. `lan.example.com`). **Required.** | *(Mandatory - Template: `example.com`)* |
| `domain_file` | The domain name formatted for use as a filename (dots replaced with underscores). | `domain` with `.` replaced by `_` |
| `hostname` | The hostname of the Docker host server. **Required.** | *(Mandatory - Template: `core-server`)* |
| `friendly_name` | A friendly display name for organizations or the CA. | `"Example Org"` |
| `system_timezone` | The timezone for the server/containers. | `"America/New_York"` |
| `deploy_base_dir` | The base directory on the host where project data and configs will be deployed. | `"/opt"` |
| `repo_source` | Absolute path to the template repository source directory. | *(Ansible Playbook Parent Directory)* |

## 2. Networking & DNS
These settings dictate how containers route traffic and how the BIND9 DNS server handles resolution.

| Variable | Description | Default Value |
|----------|-------------|---------------|
| `host_ip` | The primary IP address of the Docker host. **Required.** | *(Mandatory - Template: `192.168.1.100`)* |
| `lan_cidr` | The subnet representing your local LAN clients. | *(Mandatory - Template: `192.168.1.0/24`)* |
| `lan_gateway` | The default gateway router IP for your LAN. | *(Mandatory - Template: `192.168.1.1`)* |
| `core_subnet` | The internal Docker bridge subnet for the core template. | *(Mandatory - Template: `10.255.0.0/24`)* |
| `use_host_dns` | If `true`, the host's existing `resolv.conf` is used during deployment. If `false`, systemd-resolved is reconfigured to use `dns_server`. | `true` |
| `dns_server` | External upstream DNS server to forward queries to (e.g., `8.8.8.8`). | `"8.8.8.8"` |
| `bind_dns_port` | The port BIND9 listens on for standard DNS (UDP/TCP). | `5353` |
| `bind9_doh_port` | The port BIND9 listens on for DNS-over-HTTPS. | `8053` |

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

| Variable | Description | Default Value |
|----------|-------------|---------------|
| `ca_name` | The Common Name (CN) of the Root CA. | `friendly_name` + `" CA"` |
| `cert_country` | The country field (C) for the certificates. | `"US"` |
| `cert_province` | The state/province field (ST) for the certificates. | `"State"` |
| `cert_city` | The city/locality field (L) for the certificates. | `"City"` |
| `cert_org` | The organization field (O) for the certificates. | `friendly_name` |
| `cert_ou` | The organizational unit field (OU) for the certificates. | `"IT"` |
| `cert_root_ca_days` | The validity lifetime (in days) of the Root CA. | `1825` (5 years) |
| `cert_root_digest` | The signature hash algorithm for the Root CA. | `"sha512"` |
| `cert_root_key_type` | The key type for the Root CA (e.g., rsa, ecdsa, ed25519). | `"rsa"` |
| `cert_root_key_param` | The key parameter for the Root CA (e.g., 4096). | `"4096"` |
| `cert_intermediate_days`| The validity lifetime (in days) of the Intermediate CA. | `1095` (3 years) |
| `cert_intermediate_digest` | The signature hash algorithm for the Intermediate CA. | `"sha512"` |
| `cert_intermediate_key_type` | The key type for the Intermediate CA. | `"rsa"` |
| `cert_intermediate_key_param`| The key parameter for the Intermediate CA. | `"4096"` |
| `cert_service_days` | The maximum validity lifetime (in days) of leaf certificates. | `365` (1 year) |
| `cert_acme_lifetime_hours`| The default validity of certificates requested via ACME. | `"720h"` (30 days) |
| `stepca_port` | The port Step-CA listens on. | `9000` |
| `stepca_cert_allow_subordinate_ca`| Whether Step-CA allows signing subordinate CA certs. | `true` |
| `stepca_cert_max_lifetime_hours`| The max lifetime Step-CA will issue a certificate for. | `cert_service_days * 24h` |

### Bring Your Own Certificates (BYOC)
If you already possess a securely offline-generated Root and Intermediate CA, you can import them instead of letting Step-CA mint its own.

| Variable | Description | Default Value |
|----------|-------------|---------------|
| `byoc` | Set to `true` to enable importing your own CAs. | `false` |
| `root_cert_name` | Basename (without extension) for the imported root CA. | `"root_ca"` |
| `ca_crt_path` | Absolute path to your existing Root CA certificate. | `"/home/default_admin/output/root_ca.crt"` |
| `ica_crt_path` | Absolute path to your existing Intermediate CA certificate. | `"/home/default_admin/output/ica.crt"` |
| `ica_key_path` | Absolute path to your existing Intermediate CA private key. | *(None)* |

## 4. Docker Infrastructure
Allows deep customization of the container orchestration, including overriding images and statically assigning internal IPs on the Docker bridge.

### General Orchestration
| Variable | Description | Default Value |
|----------|-------------|---------------|
| `compose_file` | Path to the generated `docker-compose.yml` file. | `deploy_base_dir` + `"/core/docker-compose.yml"` |
| `project_containers` | List of containers to include in deployment. | `['nginx', 'step-ca', 'bind9']` (plus conditionally enabled services) |
| `nginx_backend_ldap` | Upstream target for Nginx LDAP proxy. | `"openldap:389"` |
| `nginx_backend_stepca` | Upstream target for Nginx Step-CA proxy. | `"https://step-ca:9000"` |

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

### Internal Subdomain Routing (Nginx)
| Variable | Default Value |
|----------|---------------|
| `hostname_nginx` | `"nginx." + domain` |
| `hostname_bind9` | `"dns." + domain` |
| `hostname_stepca` | `"ca." + domain` |
| `hostname_certs` | `"certificates." + domain` |
| `hostname_ldap` | `"ldap." + domain` |
| `hostname_keycloak`| `"sso." + domain` |

## 5. Security Contexts & Features
Toggle features and control system-level UNIX isolation mapping.

| Variable | Description | Default Value |
|----------|-------------|---------------|
| `install_ldap` | Toggles whether the OpenLDAP container is deployed. | `false` |
| `install_keycloak` | Toggles whether Keycloak (and PostgreSQL) are deployed. | `false` |
| `service_users` | Dictionary mapping container names to UID/GID objects for setting permissions. | *(See default configuration below)* |
| `service_dirs` | List defining data directories and their owning users to create. | *(See default configuration below)* |

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

| Variable | Description | Default Value |
|----------|-------------|---------------|
| `ldap_base_dn` | Base distinguished name, automatically computed from `domain`. | `dc=lan,dc=example,dc=com` |
| `ldap_groups` | Defines the security groups to pre-provision in LDAP. | `[{name: admins, gidNumber: 1100, permissions: [read, write, modify]}, ...]` |
| `ldap_organizational_units` | Defines the tree structure/OUs to pre-provision. | `[{name: accounts, description: User Accounts}, ...]` |

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
