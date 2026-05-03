#!/usr/bin/env python3
import sys
import os
import yaml
import subprocess
import datetime

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
CORE_DIR = os.path.dirname(SCRIPT_DIR)
PLAYBOOKS_DIR = os.path.join(CORE_DIR, "playbooks")
CUSTOM_VARS_FILE = os.path.abspath(os.path.join(CORE_DIR, "config/vars.yaml"))
DEPLOYED_VARS_FILE = "/opt/core/config/vars.yaml"

# ANSI Colors
BLUE = "\033[94m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
RED = "\033[91m"
BOLD = "\033[1m"
NC = "\033[0m"

IMMUTABLE_KEYS = {
    "ca_name", "cert_country", "cert_province", "cert_city", "cert_org", "cert_ou",
    "cert_root_digest", "cert_root_key_type", "cert_root_key_param", "cert_root_ca_days",
    "cert_intermediate_days", "cert_intermediate_digest", "cert_intermediate_key_type",
    "cert_intermediate_key_param", "cert_service_days", "cert_acme_lifetime_hours",
    "stepca_port", "stepca_cert_allow_subordinate_ca", "stepca_cert_max_lifetime_hours",
    "byoc", "root_cert_name", "ca_crt_path", "ica_crt_path", "ica_key_path", "extra_certs",
    "deploy_base_dir", "repo_source", "domain"
}

WARNED_KEYS = {
    "hostname", "host_ip", "lan_cidr", "lan_gateway", "core_subnet"
}

CATEGORIES = [
    ("Docker & Services", ["host_ram_capacity", "compose_file", "project_containers", "nginx_backend_ldap", "nginx_backend_stepca", "keycloak_data_dir", "postgres_data_dir", "ip_nginx", "ip_bind9", "ip_stepca", "ip_ldap", "ip_keycloak", "ip_postgres", "image_nginx", "image_bind9", "image_stepca", "image_openldap", "image_keycloak", "image_postgres", "cname_ca", "landing_page_cname", "cname_dns", "cname_ldap", "cname_sso", "hostname_nginx", "hostname_bind9", "hostname_stepca", "hostname_landing", "hostname_ldap", "hostname_keycloak"])
]

IMPACT_MAP = {
    "domain": ["nginx", "bind9", "stepca", "ldap", "keycloak", "postgres"],
    "host_ip": ["nginx", "bind9"],
    "byoc": ["nginx", "stepca"],
    "ca_crt_path": ["nginx", "stepca"],
    "ica_crt_path": ["nginx", "stepca"],
    "cert_service_days": ["nginx", "bind9", "stepca"],
    "install_ldap": ["ldap", "nginx"],
    "install_keycloak": ["keycloak", "postgres", "nginx"],
    "dns_server": ["bind9"],
    "use_host_dns": ["nginx"],
    "bind_dns_port": ["bind9"],
    "stepca_port": ["stepca", "nginx"],
    "postgres_data_dir": ["postgres"],
    "keycloak_data_dir": ["keycloak"],
    "dns": ["bind9"],
    "tsig_keys": ["bind9"],
    "reverse_zone_names": ["bind9"],
    "extra_certs": ["nginx"],
    "ldap_groups": ["ldap"],
    "ldap_organizational_units": ["ldap"],
}

def map_service(key):
    if key in IMPACT_MAP:
        return IMPACT_MAP[key]
    if key.startswith("image_"):
        img = key.replace("image_", "")
        if img == "openldap": return ["ldap"]
        if img == "stepca": return ["stepca"]
        return [img]
    if key.startswith("cname_") or key.startswith("hostname_"):
        return ["nginx", "bind9", "stepca", "ldap", "keycloak", "postgres"]
    return ["nginx"]

def load_yaml(path):
    if not os.path.exists(path):
        return {}
    with open(path, "r") as f:
        return yaml.safe_load(f) or {}

def save_yaml(path, data):
    with open(path, "w") as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)

def audit_log(key, old_val, new_val, action="MODIFIED"):
    audit_dir = "/opt/core/archive"
    if not os.path.exists(audit_dir):
        try:
            os.makedirs(audit_dir, mode=0o700)
        except Exception:
            pass
    
    audit_file = os.path.join(audit_dir, "audit.log")
    timestamp = datetime.datetime.now().isoformat()
    user = os.environ.get("SUDO_USER") or os.environ.get("USER") or "unknown"
    
    try:
        with open(audit_file, "a") as f:
            f.write(f"[{timestamp}] User: {user} | Action: {action} | Key: {key} | Old: {old_val} | New: {new_val}\n")
    except Exception:
        pass

def print_vars():
    data = load_yaml(CUSTOM_VARS_FILE)
    if not data:
        print(f"{YELLOW}No custom variables found in {CUSTOM_VARS_FILE}{NC}")
        return

    print(f"{BOLD}Custom Variables ({CUSTOM_VARS_FILE}):{NC}\n")
    for idx, (k, v) in enumerate(data.items(), 1):
        val_str = str(v)
        if isinstance(v, (dict, list)):
            val_str = "(complex structure)"
        print(f"  {idx}) {BLUE}{k}{NC}: {GREEN}{val_str}{NC}")
    print("")


def edit_dns_zone(full_data, dns_data, zone_key, domain_var):
    if zone_key not in dns_data:
        dns_data[zone_key] = {}
    zone_data = dns_data[zone_key]
    disp_zone = domain_var if zone_key == 'dynamic_zone_var' else zone_key
    
    while True:
        os.system('clear')
        print(f"{BOLD}--- DNS Zone: {disp_zone} ---{NC}\n")
        
        record_types = [k for k in zone_data.keys() if k != 'zone_authority' and isinstance(zone_data[k], list)]
        
        idx = 1
        record_map = {}
        for rtype in record_types:
            for ridx, record in enumerate(zone_data[rtype]):
                name = record.get('name', '')
                val = record.get('ip', record.get('value', record.get('target', '')))
                print(f"  {idx}) [{rtype}] {name} -> {val}")
                record_map[idx] = (rtype, ridx, record)
                idx += 1
                
        print(f"\n  a) Add new record")
        if record_map:
            print(f"  d) Delete record")
        print(f"  b) Back to zones")
        
        choice = input(f"Select an option: ").strip().lower()
        if choice == 'b':
            break
        elif choice == 'd' and record_map:
            del_idx = input(f"Enter record number to delete (1-{len(record_map)}): ").strip()
            if del_idx.isdigit() and int(del_idx) in record_map:
                rtype, ridx, _ = record_map[int(del_idx)]
                zone_data[rtype].pop(ridx)
                if not zone_data[rtype]:
                    del zone_data[rtype]
                save_yaml(CUSTOM_VARS_FILE, full_data)
                audit_log("dns", "record", "None", "DELETED")
        elif choice == 'a':
            rtype = input("Record type (A, CNAME, TXT, MX, etc): ").strip().upper()
            if rtype:
                name = input("Record name (e.g. '@', 'www'): ").strip()
                if rtype == 'A' or rtype == 'AAAA':
                    val = input("IP Address: ").strip()
                    new_rec = {'name': name, 'ip': val}
                elif rtype == 'CNAME':
                    val = input("Canonical Name/Target: ").strip()
                    new_rec = {'name': name, 'canonical': val}
                elif rtype == 'TXT':
                    val = input("Text Data: ").strip()
                    new_rec = {'name': name, 'text': val}
                elif rtype == 'MX':
                    priority = input("Priority (e.g. 10): ").strip()
                    exchange = input("Exchange (e.g. mail.domain.com.): ").strip()
                    new_rec = {'name': name, 'priority': int(priority) if priority.isdigit() else 10, 'exchange': exchange}
                elif rtype == 'SRV':
                    priority = input("Priority (e.g. 0): ").strip()
                    weight = input("Weight (e.g. 5): ").strip()
                    port = input("Port (e.g. 5060): ").strip()
                    target = input("Target: ").strip()
                    new_rec = {'name': name, 'priority': int(priority) if priority.isdigit() else 0, 'weight': int(weight) if weight.isdigit() else 0, 'port': int(port) if port.isdigit() else 0, 'target': target}
                else:
                    val = input("Value: ").strip()
                    new_rec = {'name': name, 'value': val}
                
                if rtype not in zone_data:
                    zone_data[rtype] = []
                zone_data[rtype].append(new_rec)
                save_yaml(CUSTOM_VARS_FILE, full_data)
                audit_log("dns", "None", f"Added {rtype} {name}", "MODIFIED")

def edit_dns(data):
    if 'dns' not in data or not isinstance(data['dns'], dict):
        data['dns'] = {}
        
    dns_data = data['dns']
    
    while True:
        os.system('clear')
        print(f"{BOLD}--- DNS Records Editor ---{NC}\n")
        
        domain_var = data.get('domain', 'example.com')
        
        zones = list(dns_data.keys())
        if 'dynamic_zone_var' not in zones:
            zones.insert(0, 'dynamic_zone_var')
            
        print("Available Zones:")
        for i, z in enumerate(zones, 1):
            disp = domain_var if z == 'dynamic_zone_var' else z
            print(f"  {i}) {disp} ({z})")
            
        print(f"\n  a) Add a new zone")
        print(f"  b) Back to variables")
        
        choice = input(f"Select a zone (1-{len(zones)}), 'a', or 'b': ").strip().lower()
        if choice == 'b':
            break
        elif choice == 'a':
            new_zone = input("New zone name: ").strip()
            if new_zone and new_zone not in dns_data:
                dns_data[new_zone] = {}
                save_yaml(CUSTOM_VARS_FILE, data)
                audit_log("dns", "None", f"Added zone {new_zone}", "MODIFIED")
        elif choice.isdigit() and 1 <= int(choice) <= len(zones):
            zone_key = zones[int(choice)-1]
            edit_dns_zone(data, dns_data, zone_key, domain_var)

def edit_list_of_dicts(key, data, schema):
    if key not in data or not isinstance(data[key], list):
        data[key] = []
        
    lst = data[key]
    
    while True:
        os.system('clear')
        print(f"{BOLD}--- Editor: {key} ---{NC}\n")
        
        if not lst:
            print(f"{YELLOW}No custom entries defined. System defaults will be used.{NC}")
            
        for i, item in enumerate(lst, 1):
            name = item.get('name', f"Item {i}")
            print(f"  {i}) {name}")
            for k, v in item.items():
                if k != 'name':
                    print(f"      {k}: {v}")
                    
        print(f"\n  a) Add new entry")
        if lst:
            print(f"  m) Modify entry")
            print(f"  d) Delete entry")
        print(f"  b) Back to variables")
        
        choice = input(f"Select an option: ").strip().lower()
        if choice == 'b':
            break
        elif choice == 'a':
            new_item = {}
            print(f"\nAdding new entry to {key}:")
            for field in schema:
                val = input(f"  {field}: ").strip()
                if val:
                    if val.startswith('[') and val.endswith(']'):
                        val = [v.strip() for v in val[1:-1].split(',')]
                    elif val.isdigit():
                        val = int(val)
                    new_item[field] = val
            if new_item:
                lst.append(new_item)
                save_yaml(CUSTOM_VARS_FILE, data)
                audit_log(key, "None", str(new_item), "MODIFIED")
        elif choice == 'm' and lst:
            idx_str = input(f"Enter item number to modify (1-{len(lst)}): ").strip()
            if idx_str.isdigit() and 1 <= int(idx_str) <= len(lst):
                idx = int(idx_str) - 1
                item = lst[idx]
                print(f"\nModifying entry {idx+1}:")
                for field in schema:
                    current = item.get(field, '')
                    val = input(f"  {field} [{current}]: ").strip()
                    if val:
                        if val.startswith('[') and val.endswith(']'):
                            val = [v.strip() for v in val[1:-1].split(',')]
                        elif val.isdigit():
                            val = int(val)
                        item[field] = val
                save_yaml(CUSTOM_VARS_FILE, data)
                audit_log(key, "old", str(item), "MODIFIED")
        elif choice == 'd' and lst:
            idx_str = input(f"Enter item number to delete (1-{len(lst)}): ").strip()
            if idx_str.isdigit() and 1 <= int(idx_str) <= len(lst):
                del lst[int(idx_str)-1]
                save_yaml(CUSTOM_VARS_FILE, data)
                audit_log(key, "item", "None", "DELETED")

def handle_complex_variable(k, data):
    if k == 'dns':
        edit_dns(data)
    elif k in ['tsig_keys', 'ldap_groups', 'ldap_organizational_units']:
        schemas = {
            'tsig_keys': ['name', 'algorithm', 'domain', 'record_types'],
            'ldap_groups': ['gidNumber', 'name', 'permissions'],
            'ldap_organizational_units': ['name', 'description', 'parent', 'uid_range']
        }
        edit_list_of_dicts(k, data, schemas[k])
    else:
        print(f"\n{YELLOW}No interactive editor exists for {k}. Please edit manually in {CUSTOM_VARS_FILE}{NC}")
        input("Press Enter to continue...")


def mint_certificates_interactive(data):
    cert_data = {
        'cn': '',
        'sans': [],
        'days': 365,
        'kty': 'RSA',
        'size': 4096,
        'is_ca': False,
        'out_dir': ''
    }
    
    country = data.get('cert_country', 'US')
    org = data.get('cert_org', 'My Org')
    ou = data.get('cert_ou', 'My OU')
    city = data.get('cert_city', 'My City')
    province = data.get('cert_province', 'My Province')
    
    while True:
        os.system('clear')
        print(f"{BOLD}--- Mint Certificates ---{NC}\n")
        
        print(f"  1) Common Name:      {GREEN}{cert_data['cn']}{NC}")
        print(f"  2) SAN (URL):        {GREEN}{cert_data['sans']}{NC}")
        print(f"  3) Validity Days:    {GREEN}{cert_data['days']}{NC}")
        print(f"  4) Key Type:         {GREEN}{cert_data['kty']}{NC}")
        print(f"  5) Key Size:         {GREEN}{cert_data['size']}{NC}")
        print(f"  6) Is CA:            {GREEN}{cert_data['is_ca']}{NC}")
        print(f"  7) Output Directory: {GREEN}{cert_data['out_dir'] or '(Caller Home)'}{NC}")
        
        print(f"\n{BOLD}System PKI Defaults (will be applied to minted cert):{NC}")
        print(f"  Country: {country} | Province: {province} | City: {city}")
        print(f"  Org: {org} | OU: {ou}")
        
        print(f"\n  {BOLD}m{NC}) Mint Certificate")
        print(f"  {BOLD}b{NC}) Back to Main Menu")
        
        choice = input(f"\nSelect option to edit (1-7), 'm' to mint, or 'b' to go back: ").strip().lower()
        if choice == 'b':
            break
        elif choice == '1':
            cert_data['cn'] = input("Common Name: ").strip() or cert_data['cn']
        elif choice == '2':
            sans_str = input("SAN (URLs) separated by commas: ").strip()
            if sans_str:
                cert_data['sans'] = [s.strip() for s in sans_str.split(',') if s.strip()]
            else:
                cert_data['sans'] = []
        elif choice == '3':
            days = input(f"Validity Days [{cert_data['days']}]: ").strip()
            if days.isdigit():
                cert_data['days'] = int(days)
        elif choice == '4':
            cert_data['kty'] = input(f"Key Type [{cert_data['kty']}]: ").strip() or cert_data['kty']
        elif choice == '5':
            size = input(f"Key Size [{cert_data['size']}]: ").strip()
            if size.isdigit():
                cert_data['size'] = int(size)
        elif choice == '6':
            is_ca = input(f"Is CA? (true/false) [{str(cert_data['is_ca']).lower()}]: ").strip().lower()
            if is_ca in ('true', 'yes', 'y'):
                cert_data['is_ca'] = True
            elif is_ca in ('false', 'no', 'n'):
                cert_data['is_ca'] = False
        elif choice == '7':
            cert_data['out_dir'] = input(f"Output Directory [{cert_data['out_dir']}]: ").strip() or cert_data['out_dir']
        elif choice == 'm':
            if not cert_data['cn']:
                print(f"{RED}Common Name is required!{NC}")
                input("Press Enter to continue...")
                continue
                
            print(f"\n{BLUE}Preparing to mint certificate...{NC}")
            import json
            
            entry = {
                'cn': cert_data['cn'],
                'sans': cert_data['sans'],
                'days': cert_data['days'],
                'kty': cert_data['kty'],
                'size': cert_data['size']
            }
            if cert_data['is_ca']:
                entry['is_ca'] = True
                entry['path_len'] = 0
            if cert_data['out_dir']:
                entry['out_dir'] = cert_data['out_dir']
                
            if 'extra_certs' not in data:
                data['extra_certs'] = []
            data['extra_certs'].append(entry)
            save_yaml(CUSTOM_VARS_FILE, data)
            audit_log("extra_certs", "None", json.dumps(entry), "ADDED")
            
            print(f"{YELLOW}Saved configuration. Minting certificate...{NC}")
            
            try:
                env = os.environ.copy()
                # Use VARS_FILE to match certs.sh logic
                env['VARS_FILE'] = CUSTOM_VARS_FILE
                
                # Format exactly like do_extra_certs in certs.sh
                import shlex
                json_arg = shlex.quote(json.dumps(entry))
                cmd = f"source {CORE_DIR}/lib/certs.sh && _mint_extra_cert {json_arg}"
                res = subprocess.run(["bash", "-c", cmd], env=env)
                
                if res.returncode == 0:
                    print(f"{GREEN}Certificate successfully minted!{NC}")
                else:
                    print(f"{RED}Minting failed with exit code {res.returncode}.{NC}")
            except Exception as e:
                import traceback
                print(f"{RED}Error minting certificate: {e}{NC}")
                traceback.print_exc()
                
            input("Press Enter to continue...")

def interactive_mode():
    data = load_yaml(CUSTOM_VARS_FILE)
    
    while True:
        os.system('clear')
        print(f"{BOLD}--- Interactive Variables Editor ---{NC}\n")
        
        print(f"  {BOLD}1{NC}) DNS Configuration")
        print(f"  {BOLD}2{NC}) Mint Certificates")
        print(f"  {BOLD}3{NC}) Docker & Services")
        print(f"  {BOLD}4{NC}) TSIG Keys")
        print(f"  {BOLD}5{NC}) Advanced Configuration")
        
        print(f"\nOptions:")
        print(f"  {BOLD}a{NC}    Add new variable")
        print(f"  {BOLD}d{NC}    Delete variable")
        print(f"  {BOLD}apply{NC} Save and Apply changes")
        print(f"  {BOLD}q{NC}    Quit without applying\n")
        
        choice = input(f"Select a category (1-5), or option: ").strip().lower()
        
        if choice in ['q', 'quit', 'exit']:
            print("Exiting.")
            sys.exit(0)
            
        if choice == 'apply':
            old_vars = load_yaml(DEPLOYED_VARS_FILE)
            warned_mods = [k for k in WARNED_KEYS if k in data and k in old_vars and data[k] != old_vars[k]]
            if warned_mods:
                print(f"\n{RED}{BOLD}[WARNING]{NC} You are about to apply changes to highly sensitive network configurations: {', '.join(warned_mods)}")
                print(f"This may break routing and require widespread restarts.")
                confirm = input("Are you absolutely sure you want to apply? (type 'yes'): ").strip().lower()
                if confirm != 'yes':
                    continue
                    
            print("Applying changes...")
            apply_mode()
            sys.exit(0)
            
        if choice == 'a':
            k = input("New variable key: ").strip()
            if k:
                v = input(f"Value for {k}: ").strip()
                if v.lower() == 'true': v = True
                elif v.lower() == 'false': v = False
                elif v.isdigit(): v = int(v)
                data[k] = v
                save_yaml(CUSTOM_VARS_FILE, data)
                audit_log(k, "None", v, "ADDED")
            continue
            
        if choice == 'd':
            k = input("Variable key to delete: ").strip()
            if k in IMMUTABLE_KEYS:
                print(f"{RED}Cannot delete immutable key: {k}{NC}")
                input("Press Enter to continue...")
                continue
            if k in data:
                old = data[k]
                del data[k]
                save_yaml(CUSTOM_VARS_FILE, data)
                audit_log(k, old, "None", "DELETED")
            continue
            
        if choice == '1':
            edit_dns(data)
            continue
        elif choice == '2':
            mint_certificates_interactive(data)
            continue
        elif choice == '4':
            schemas = {
                'tsig_keys': ['name', 'algorithm', 'domain', 'record_types']
            }
            edit_list_of_dicts('tsig_keys', data, schemas['tsig_keys'])
            continue
            
        selected_cat_keys = None
        cat_title = ""
        if choice == '3':
            cat_title = "Docker & Services"
            selected_cat_keys = CATEGORIES[0][1]
        elif choice == '5':
            cat_title = "Advanced Configuration"
            known_keys = set(CATEGORIES[0][1]) | {'dns', 'tsig_keys', 'domain'}
            selected_cat_keys = [k for k in data.keys() if k not in known_keys]
            
        if selected_cat_keys is not None:
            while True:
                os.system('clear')
                print(f"{BOLD}--- {cat_title} ---{NC}\n")
                
                display_keys = [k for k in selected_cat_keys if k in data]
                
                if cat_title == "Advanced Configuration":
                    # Add remaining unknown keys to display_keys
                    for k in data.keys():
                        if k not in known_keys and k not in display_keys:
                            display_keys.append(k)
                            
                if not display_keys:
                    print(f"{YELLOW}No active variables in this category.{NC}")
                
                for i, k in enumerate(display_keys, 1):
                    v = data[k]
                    val_str = str(v)
                    if isinstance(v, (dict, list)):
                        val_str = "(complex structure)"
                        
                    status = ""
                    if k in IMMUTABLE_KEYS:
                        status = f" {BOLD}🔒 [IMMUTABLE]{NC}"
                    elif k in WARNED_KEYS:
                        status = f" {YELLOW}⚠️ [CAUTION]{NC}"
                        
                    print(f"  {i}) {BLUE}{k}{NC}: {GREEN}{val_str}{NC}{status}")
                
                print(f"\n  {BOLD}b{NC} Back to categories")
                subchoice = input(f"Select a variable to edit (1-{len(display_keys)}) or 'b': ").strip().lower()
                
                if subchoice == 'b':
                    break
                    
                if subchoice.isdigit():
                    idx = int(subchoice) - 1
                    if 0 <= idx < len(display_keys):
                        k = display_keys[idx]
                        if k in IMMUTABLE_KEYS:
                            print(f"\n{RED}Error: '{k}' is an immutable variable and cannot be changed post-deployment.{NC}")
                            input("Press Enter to continue...")
                            continue
                            
                        current = data[k]
                        if isinstance(current, (dict, list)):
                            handle_complex_variable(k, data)
                            continue
                        
                        print(f"\nEditing: {BLUE}{k}{NC}")
                        if k in WARNED_KEYS:
                            print(f"{YELLOW}⚠️ WARNING: Editing this variable could impact network routing!{NC}")
                            
                        print(f"Current value: {GREEN}{current}{NC}")
                        new_v = input(f"New value (press Enter to keep current): ").strip()
                        if new_v:
                            if new_v.lower() == 'true': new_v = True
                            elif new_v.lower() == 'false': new_v = False
                            elif new_v.isdigit(): new_v = int(new_v)
                            data[k] = new_v
                            save_yaml(CUSTOM_VARS_FILE, data)
                            audit_log(k, current, new_v, "MODIFIED")
                            print(f"{GREEN}Saved.{NC}")
                            input("Press Enter to continue...")
            continue

def apply_mode():
    import glob
    from deploy import apply_deployment
    print(f"{BOLD}Applying changes natively...{NC}")
    
    archives = glob.glob(os.path.join(CORE_DIR, "archive/*-vars.yaml"))
    if archives:
        latest_archive = max(archives)
        old_vars = load_yaml(latest_archive)
    else:
        old_vars = load_yaml(DEPLOYED_VARS_FILE)
        
    print(f"  {BLUE}[1/3]{NC} Rendering and deploying configurations...")
    
    os.environ["CUSTOM_VARS_PATH"] = CUSTOM_VARS_FILE
    os.environ["SECRETS_FILE_OVERRIDE"] = os.path.join(CORE_DIR, 'config', 'core-secrets.yml')
    os.environ["DEPLOY_BASE_DIR"] = os.path.dirname(CORE_DIR)
    
    try:
        restarted_services = apply_deployment()
        if restarted_services is None:
            restarted_services = set()
    except SystemExit as e:
        print(f"{RED}Error deploying configurations! Exit code {e.code}{NC}")
        sys.exit(e.code)
    except Exception as e:
        import traceback
        print(f"{RED}Exception during deployment!{NC}")
        traceback.print_exc()
        sys.exit(1)
        
    new_vars = load_yaml("/tmp/core-template-render/vars.yaml")
    
    changed_keys = []
    for k, v in new_vars.items():
        if k not in old_vars or old_vars[k] != v:
            changed_keys.append(k)
            
    for k in old_vars:
        if k not in new_vars:
            changed_keys.append(k)
            
    if not changed_keys:
        print(f"{GREEN}No variables have changed. System is up to date.{NC}")
        return
        
    print(f"Changed variables: {YELLOW}{', '.join(changed_keys)}{NC}")
    
    impacted_services = set()
    for k in changed_keys:
        for s in map_service(k):
            impacted_services.add(s)
            
    if "postgres" in impacted_services and new_vars.get("install_keycloak"):
        impacted_services.add("keycloak")
            
    print(f"Impacted services to restart: {YELLOW}{', '.join(impacted_services)}{NC}")
    print(f"  {BLUE}[2/3]{NC} Done deploying configuration files.")
    def get_svc_timeout(s):
        if s == "keycloak": return 90
        if s == "postgres": return 60
        return 30

    print(f"  {BLUE}[3/3]{NC} Restarting services...")
    for svc in impacted_services:
        if svc in ["bind9", "nginx"] or svc in restarted_services:
            continue
        try:
            res_check = subprocess.run(["systemctl", "is-active", svc], capture_output=True, timeout=10)
            if res_check.returncode == 0:
                print(f"    Restarting {svc}...")
                subprocess.run(["systemctl", "restart", svc], check=True, timeout=get_svc_timeout(svc))
            else:
                print(f"    Skipping {svc} (not currently active)")
        except subprocess.TimeoutExpired:
            print(f"{RED}    Timeout while checking/restarting {svc}. Please check systemctl status manually.{NC}")
            
    print(f"\n{BOLD}{GREEN}Apply complete!{NC}")

def update_containers_mode():
    import glob
    print(f"{BOLD}Updating container images...{NC}")
    sys_svcs = [
        {'service': 'nginx', 'folder': 'nginx'},
        {'service': 'bind9', 'folder': 'bind9'},
        {'service': 'stepca', 'folder': 'stepca'},
        {'service': 'ldap', 'folder': 'openldap'},
        {'service': 'postgres', 'folder': 'postgres'},
        {'service': 'keycloak', 'folder': 'keycloak'}
    ]
    
    def get_svc_timeout(s):
        if s == "keycloak": return 90
        if s == "postgres": return 60
        return 30

    for svc in sys_svcs:
        dc_path = f"/opt/core/{svc['folder']}/docker-compose.yml"
        if os.path.exists(dc_path):
            print(f"\n{BLUE}Pulling latest images for {svc['service']}...{NC}")
            try:
                res = subprocess.run(["docker", "compose", "-f", dc_path, "pull"], timeout=300)
                if res.returncode == 0:
                    print(f"{GREEN}Restarting {svc['service']} to apply updates...{NC}")
                    subprocess.run(["systemctl", "restart", svc['service']], timeout=get_svc_timeout(svc['service']))
            except subprocess.TimeoutExpired:
                print(f"{RED}Timeout during update for {svc['service']}.{NC}")
    print(f"\n{BOLD}{GREEN}Container updates complete!{NC}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: interactive.py [--print | --interactive | --apply | --update-containers]")
        sys.exit(1)
        
    mode = sys.argv[1]
    if mode == "--print":
        print_vars()
    elif mode == "--interactive":
        interactive_mode()
    elif mode == "--apply":
        apply_mode()
    elif mode == "--update-containers":
        update_containers_mode()
    else:
        print(f"Unknown mode: {mode}")
        sys.exit(1)
