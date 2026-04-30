#!/usr/bin/env python3
import sys
import os
import yaml
import subprocess

SCRIPT_DIR = os.path.dirname(os.path.realpath(__file__))
CORE_DIR = os.path.dirname(SCRIPT_DIR)
PLAYBOOKS_DIR = os.path.join(CORE_DIR, "playbooks")
CUSTOM_VARS_FILE = os.path.abspath(os.path.join(CORE_DIR, "../custom-vars.yaml"))
DEPLOYED_VARS_FILE = "/opt/core/config/vars.yaml"

# ANSI Colors
BLUE = "\033[94m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
RED = "\033[91m"
BOLD = "\033[1m"
NC = "\033[0m"

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
    # Default impact if unknown (safe fallback)
    return ["nginx"]

def load_yaml(path):
    if not os.path.exists(path):
        return {}
    with open(path, "r") as f:
        return yaml.safe_load(f) or {}

def save_yaml(path, data):
    with open(path, "w") as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False)

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

def interactive_mode():
    while True:
        os.system('clear')
        print(f"{BOLD}--- Interactive Variables Editor ---{NC}\n")
        data = load_yaml(CUSTOM_VARS_FILE)
        keys = list(data.keys())
        
        for idx, k in enumerate(keys, 1):
            v = data[k]
            val_str = str(v)
            if isinstance(v, (dict, list)):
                val_str = "(complex structure)"
            print(f"  {idx}) {BLUE}{k}{NC}: {GREEN}{val_str}{NC}")
            
        print(f"\nOptions:")
        print(f"  {BOLD}a{NC}    Add new variable")
        print(f"  {BOLD}d#{NC}   Delete variable (e.g., d3)")
        print(f"  {BOLD}apply{NC} Save and Apply changes")
        print(f"  {BOLD}q{NC}    Quit without applying\n")
        
        choice = input(f"Select a variable to edit (1-{len(keys)}) or option: ").strip().lower()
        
        if choice in ['q', 'quit', 'exit']:
            print("Exiting.")
            sys.exit(0)
            
        if choice == 'apply':
            print("Applying changes...")
            apply_mode()
            sys.exit(0)
            
        if choice == 'a':
            k = input("New variable key: ").strip()
            if k:
                v = input(f"Value for {k}: ").strip()
                # Try to cast boolean or int
                if v.lower() == 'true': v = True
                elif v.lower() == 'false': v = False
                elif v.isdigit(): v = int(v)
                data[k] = v
                save_yaml(CUSTOM_VARS_FILE, data)
            continue
            
        if choice.startswith('d') and choice[1:].isdigit():
            idx = int(choice[1:]) - 1
            if 0 <= idx < len(keys):
                k = keys[idx]
                del data[k]
                save_yaml(CUSTOM_VARS_FILE, data)
            continue
            
        if choice.isdigit():
            idx = int(choice) - 1
            if 0 <= idx < len(keys):
                k = keys[idx]
                current = data[k]
                if isinstance(current, (dict, list)):
                    print(f"{YELLOW}Complex structures must be edited manually in {CUSTOM_VARS_FILE}{NC}")
                    input("Press Enter to continue...")
                    continue
                
                print(f"\nEditing: {BLUE}{k}{NC}")
                print(f"Current value: {GREEN}{current}{NC}")
                new_v = input(f"New value (press Enter to keep current): ").strip()
                if new_v:
                    if new_v.lower() == 'true': new_v = True
                    elif new_v.lower() == 'false': new_v = False
                    elif new_v.isdigit(): new_v = int(new_v)
                    data[k] = new_v
                    save_yaml(CUSTOM_VARS_FILE, data)
            continue

def apply_mode():
    print(f"{BOLD}Applying changes...{NC}")
    old_vars = load_yaml(DEPLOYED_VARS_FILE)
    
    # 1. Render Jinja templates and merge vars to /tmp/core-template-render/vars.yaml
    print(f"  {BLUE}[1/3]{NC} Rendering configurations...")
    ansible_cmd1 = [
        "ansible-playbook", 
        os.path.join(PLAYBOOKS_DIR, "01-gen-vars-and-render-jinja.yml"),
        "-i", "localhost,", "-c", "local", "-e", "target_host=localhost"
    ]
    res1 = subprocess.run(ansible_cmd1, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if res1.returncode != 0:
        print(f"{RED}Error rendering jinja templates!{NC}")
        print(res1.stderr.decode())
        sys.exit(1)
        
    new_vars = load_yaml("/tmp/core-template-render/vars.yaml")
    
    # Identify changed keys
    changed_keys = []
    for k, v in new_vars.items():
        if k not in old_vars or old_vars[k] != v:
            changed_keys.append(k)
            
    # Check for removed keys
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
            
    # Ensure dependencies: if postgres restarts, keycloak should restart.
    if "postgres" in impacted_services and new_vars.get("install_keycloak"):
        impacted_services.add("keycloak")
            
    print(f"Impacted services to restart: {YELLOW}{', '.join(impacted_services)}{NC}")
    
    # 2. Deploy file structure
    print(f"  {BLUE}[2/3]{NC} Deploying configuration files...")
    ansible_cmd2 = [
        "ansible-playbook", 
        os.path.join(PLAYBOOKS_DIR, "04-target-file-structure.yml"),
        "-i", "localhost,", "-c", "local", "-e", "target_host=localhost"
    ]
    res2 = subprocess.run(ansible_cmd2, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if res2.returncode != 0:
        print(f"{RED}Error deploying file structure!{NC}")
        print(res2.stderr.decode())
        sys.exit(1)
        
    # 3. Restart impacted services
    print(f"  {BLUE}[3/3]{NC} Restarting services...")
    for svc in impacted_services:
        # Check if service is actually active/installed before restarting
        res_check = subprocess.run(["systemctl", "is-active", svc], capture_output=True)
        if res_check.returncode == 0:
            print(f"    Restarting {svc}...")
            subprocess.run(["systemctl", "restart", svc], check=True)
        else:
            print(f"    Skipping {svc} (not currently active)")
            
    print(f"\n{BOLD}{GREEN}Apply complete!{NC}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: interactive.py [--print | --interactive | --apply]")
        sys.exit(1)
        
    mode = sys.argv[1]
    if mode == "--print":
        print_vars()
    elif mode == "--interactive":
        interactive_mode()
    elif mode == "--apply":
        apply_mode()
    else:
        print(f"Unknown mode: {mode}")
        sys.exit(1)
