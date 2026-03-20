# home-core

## Service Accounts and Configurations

| container | host account name | host uid | host gid |
| - | - | - | - |
| nginx | nginx | 2000 | 2000 | 
| bind9 | bind9 | 2001 | 2001 |
| stepca | step | 2002 | 2002 |
| openldap | ldap | 2003 | 2003 |
| adguardhome | adguard | 2700 | 2700 |

## Installation

*ALl Commands are assumed to be ran from the cloned git directory*
nominally: `/home/admin/home-core`

### Step 0: Condition the system for execution
```bash
sudo bash ./system-conditioning.sh
```

### Step 1: build the Root CA

```bash
sudo bash SCRIPT_DIR/easyrsa/sign-certs.sh --generate-rootca
```

### Step 2: Generate a CSR for Step-CA

```bash
sudo docker run -it --rm \
  --name step-ca-bootstrap \
  --user "2002:2002" \
  --network core_net \
  --ip 172.31.255.40 \
  -v "/opt/step-ca/data:/home/step" \
  -v "/opt/step-ca/entrypoint.sh:/usr/local/bin/entrypoint.sh:ro" \
  --entrypoint "/bin/bash" \
  smallstep/step-ca:latest \
  "/usr/local/bin/entrypoint.sh"
```

### Step 3: Sign Certificate
```bash
sudo bash /opt/easyrsa/sign-certs.sh --sign-cert --path "/opt/step-ca/data/artifacts/intermediate.csr"
```

### Step 4: boot the stack
*example: Production should use portainer to boot the stack*
```bash
cd /opt/
sudo docker compose up -d
```

### Step 5: Cerbot 
requests certs for rest of the stack (adguardhome, bind9, nginx) and auto restarts them when they have their certificates

## Update password in AdGuardHome.yaml
`mkpasswd -m bcrypt -R 10 "password"`