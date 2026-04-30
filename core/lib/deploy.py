#!/usr/bin/env python3
import os
import sys
import yaml
import shutil
import subprocess
import jinja2
import base64
from pathlib import Path
from datetime import datetime

CORE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_DIR = os.path.dirname(CORE_DIR)
DEPLOY_BASE_DIR = os.environ.get("DEPLOY_BASE_DIR", "/opt")
TARGET_CORE = os.path.join(DEPLOY_BASE_DIR, "core")

def run_cmd(cmd, check=True):
    res = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and res.returncode != 0:
        print(f"Command failed: {cmd}\n{res.stderr}")
        sys.exit(1)
    return res

def load_yaml(path):
    if not os.path.exists(path):
        return {}
    with open(path, 'r') as f:
        return yaml.safe_load(f) or {}

def save_yaml(data, path):
    with open(path, 'w') as f:
        yaml.safe_dump(data, f, default_flow_style=False)

def generate_secret_b64(length=32):
    return run_cmd(f"openssl rand -base64 {length} | tr -d '\\n'").stdout.strip()

def unique_filter(x, attribute=None):
    if not x: return []
    seen = set()
    res = []
    for item in x:
        val = item.get(attribute, item) if isinstance(item, dict) and attribute else item
        if val not in seen:
            seen.add(val)
            res.append(item)
    return res

def regex_replace_filter(s, pattern, repl):
    import re
    return re.sub(pattern, repl, s)

def b64encode_filter(s):
    return base64.b64encode(s.encode()).decode()

def to_nice_yaml_filter(value, indent=4):
    return yaml.safe_dump(value, default_flow_style=False, indent=indent).strip()

def ensure_dir(path, mode=0o750, uid=0, gid=0):
    if not os.path.exists(path):
        os.makedirs(path, mode=mode)
    os.chmod(path, mode)
    os.chown(path, uid, gid)

def get_service_user(vars_dict, service_name):
    users = vars_dict.get('service_users', {})
    svc = users.get(service_name, {})
    return int(svc.get('uid', 0)), int(svc.get('gid', 0))

def apply_deployment():
    print("Starting native Python deployment...")
    
    custom_vars_path = os.environ.get("CUSTOM_VARS_PATH", os.path.join(TARGET_CORE, "config/custom-vars.yaml"))
    secrets_path = os.environ.get("SECRETS_FILE_OVERRIDE", os.path.join(TARGET_CORE, "config/core-secrets.yml"))
    
    if not os.path.exists(custom_vars_path):
        custom_vars_path = os.path.join(REPO_DIR, "custom-vars.yaml")
    if not os.path.exists(secrets_path):
        secrets_path = os.path.join(REPO_DIR, "core-secrets.yml")

    # 1. Load Custom Vars
    custom_vars = load_yaml(custom_vars_path)
    
    # 2. Handle Secrets
    secrets = load_yaml(secrets_path)
    changed_secrets = False
    
    if 'ca_password' not in secrets:
        secrets['ca_password'] = generate_secret_b64(32)
        changed_secrets = True
    if 'rndc_secret' not in secrets:
        secrets['rndc_secret'] = generate_secret_b64(32)
        changed_secrets = True
    if 'ldap_admin_password' not in secrets:
        secrets['ldap_admin_password'] = generate_secret_b64(24)
        changed_secrets = True
    if 'ldap_keycloak_password' not in secrets:
        secrets['ldap_keycloak_password'] = generate_secret_b64(24)
        changed_secrets = True
    if 'keycloak_admin_user' not in secrets:
        secrets['keycloak_admin_user'] = 'admin'
        changed_secrets = True
    if 'keycloak_admin_password' not in secrets:
        secrets['keycloak_admin_password'] = generate_secret_b64(24)
        changed_secrets = True
    if 'keycloak_db_password' not in secrets:
        secrets['keycloak_db_password'] = generate_secret_b64(32)
        changed_secrets = True
        
    if 'tsig_secrets' not in secrets:
        secrets['tsig_secrets'] = {}
        changed_secrets = True
        
    tsig_keys = custom_vars.get('tsig_keys', [])
    for key in tsig_keys:
        kname = key.get('name')
        if kname and kname not in secrets['tsig_secrets']:
            secrets['tsig_secrets'][kname] = generate_secret_b64(32)
            changed_secrets = True
            
    if changed_secrets:
        save_yaml(secrets, secrets_path)
        os.chmod(secrets_path, 0o600)
        
    # 3. Render vars.yaml.j2
    jinja_dir = os.path.join(CORE_DIR, 'jinja')
    jinja_env = jinja2.Environment(loader=jinja2.FileSystemLoader(jinja_dir), keep_trailing_newline=True)
    jinja_env.filters['to_nice_yaml'] = to_nice_yaml_filter
    jinja_env.filters['unique'] = unique_filter
    jinja_env.filters['regex_replace'] = regex_replace_filter
    jinja_env.filters['b64encode'] = b64encode_filter
    
    merged_context = {**secrets, **custom_vars}
    
    try:
        vars_template = jinja_env.get_template('vars.yaml.j2')
        rendered_vars_str = vars_template.render(**merged_context)
    except Exception as e:
        print(f"Failed to render vars.yaml.j2: {e}")
        sys.exit(1)
        
    fresh_vars = yaml.safe_load(rendered_vars_str) or {}
    
    deployed_vars_path = os.path.join(TARGET_CORE, "config/vars.yaml")
    if os.path.exists(deployed_vars_path):
        old_vars = load_yaml(deployed_vars_path)
        final_vars = {}
        for k, v in fresh_vars.items():
            if k.startswith('image_'):
                final_vars[k] = v
            elif k in old_vars:
                final_vars[k] = old_vars[k]
            else:
                final_vars[k] = v
        for k, v in old_vars.items():
            if k not in final_vars:
                final_vars[k] = v
                
        # Archive old vars
        archive_dir = os.path.join(TARGET_CORE, "archive")
        ensure_dir(archive_dir)
        stamp = datetime.now().strftime("%Y%m%dT%H%M%S")
        shutil.copy(deployed_vars_path, os.path.join(archive_dir, f"{stamp}-vars.yaml"))
    else:
        final_vars = fresh_vars
        
    render_tmp = "/tmp/core-template-render"
    if os.path.exists(render_tmp):
        shutil.rmtree(render_tmp)
    os.makedirs(render_tmp, exist_ok=True)
    
    save_yaml(final_vars, os.path.join(render_tmp, "vars.yaml"))
    merged_context.update(final_vars)
    
    # 4. Render all other templates
    print("Rendering Jinja2 templates...")
    def render_file(src_rel, dest_rel):
        dest_path = os.path.join(render_tmp, dest_rel)
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        try:
            tpl = jinja_env.get_template(src_rel)
            with open(dest_path, 'w') as f:
                f.write(tpl.render(**merged_context))
        except Exception as e:
            print(f"Error rendering {src_rel}: {e}")
            sys.exit(1)

    # Nginx
    render_file('nginx/nginx.conf.j2', 'nginx/nginx.conf')
    render_file('nginx/bind9.conf.j2', 'nginx/bind9.conf')
    render_file('nginx/www/certificates/index.html.j2', 'nginx/www/certificates/index.html')
    render_file('nginx/www/landing/index.html.j2', 'nginx/www/landing/index.html')
    render_file('nginx/www/manual/index.html.j2', 'nginx/www/manual/index.html')
    shutil.copy(os.path.join(jinja_dir, 'nginx/www/shared/style.css'), os.path.join(render_tmp, 'nginx/www/shared/style.css'))
    shutil.copy(os.path.join(jinja_dir, 'nginx/www/manual/marked.min.js'), os.path.join(render_tmp, 'nginx/www/manual/marked.min.js'))
    
    domain_file = merged_context.get('domain_file', 'example_com')
    for script in ['certs', 'firefox-ubuntu', 'chrome-ubuntu', 'all-ubuntu', 'python-ubuntu']:
        src = f'nginx/www/certificates/install-{script}.sh.j2'
        dest = f'nginx/www/certificates/install-{script.replace("-ubuntu", "")}-{domain_file}.sh'
        render_file(src, dest)
        
    # Docker Compose
    for svc in ['nginx', 'bind9', 'stepca', 'openldap', 'keycloak', 'postgres']:
        if svc in ['keycloak', 'postgres'] and not final_vars.get('install_keycloak'):
            continue
        if svc == 'openldap' and not final_vars.get('install_ldap'):
            continue
        render_file(f'{svc}/docker-compose.yml.j2', f'{svc}/docker-compose.yml')
        
    # Docs
    render_file('docs/testplan.md.j2', 'docs/testplan.md')
    
    # Bind9 Config
    for f in ['named.conf', 'named.conf.acl', 'named.conf.logs', 'named.conf.options', 'named.conf.tls', 'named.conf.zones', 'named.conf.keys', 'rndc.key']:
        render_file(f'bind9/config/{f}.j2', f'bind9/config/{f}')
        
    # Bind9 Zones
    dns = final_vars.get('dns', {})
    for k, v in dns.items():
        zone_name = final_vars.get('domain') if k == 'dynamic_zone_var' else k
        dest_path = os.path.join(render_tmp, f"bind9/data/db.{zone_name}")
        os.makedirs(os.path.dirname(dest_path), exist_ok=True)
        tpl = jinja_env.get_template('bind9/data/zone.j2')
        with open(dest_path, 'w') as f:
            f.write(tpl.render(**merged_context, zone_name=zone_name, zone_records=v))
            
    for rz in final_vars.get('reverse_zone_names', []):
        dest_path = os.path.join(render_tmp, f"bind9/data/db.{rz}")
        tpl = jinja_env.get_template('bind9/data/reverse-zone.j2')
        with open(dest_path, 'w') as f:
            f.write(tpl.render(**merged_context, reverse_zone_name=rz))

    # OpenLDAP
    if final_vars.get('install_ldap'):
        for ldif in ['02-ous.ldif.j2', '03-groups.ldif.j2', '05-admins.ldif.j2', '06-acl.ldif.j2']:
            render_file(f'openldap/{ldif}', f"openldap/{ldif.replace('.j2', '')}")

    # Step-CA
    render_file('stepca/leaf.tpl.j2', 'stepca/templates/certs/leaf.tpl')
    render_file('stepca/subca.tpl.j2', 'stepca/templates/certs/subca.tpl')
    
    # RFC2136
    for key in tsig_keys:
        if 'primary' not in key:
            kname = key['name']
            kdir = os.path.join(render_tmp, f"rfc2136/{kname}")
            os.makedirs(kdir, exist_ok=True)
            with open(os.path.join(kdir, "rfc2136.ini"), 'w') as f:
                f.write(f"""# RFC2136 credentials for TSIG key: {kname}
dns_rfc2136_server = {final_vars.get('ip_bind9')}
dns_rfc2136_port = {final_vars.get('bind_dns_port')}
dns_rfc2136_name = {kname}
dns_rfc2136_secret = {secrets['tsig_secrets'].get(kname)}
dns_rfc2136_algorithm = HMAC-SHA256
dns_rfc2136_base_domain = {key.get('domain', final_vars.get('domain'))}
""")

    print("Deploying configurations...")
    
    # Ensure Base Directories
    for d in ['core/config/certs', 'nginx/www/certificates', 'nginx/www/shared', 'nginx/www/landing', 'nginx/www/manual/docs', 'docs']:
        ensure_dir(os.path.join(DEPLOY_BASE_DIR, d), 0o755)

    nginx_uid, nginx_gid = get_service_user(final_vars, 'nginx')
    os.chown(os.path.join(DEPLOY_BASE_DIR, 'nginx/www'), nginx_uid, nginx_gid)
    
    def copy_tree_with_perms(src, dst, uid=0, gid=0, fmode=0o640, dmode=0o750):
        if not os.path.exists(dst):
            os.makedirs(dst)
        os.chown(dst, uid, gid)
        os.chmod(dst, dmode)
        for item in os.listdir(src):
            s = os.path.join(src, item)
            d = os.path.join(dst, item)
            if os.path.isdir(s):
                copy_tree_with_perms(s, d, uid, gid, fmode, dmode)
            else:
                shutil.copy2(s, d)
                os.chown(d, uid, gid)
                os.chmod(d, fmode)

    # Sync repo core directory (safely)
    # Exclude jinja, playbooks if we want, but copying full is fine.
    copy_tree_with_perms(CORE_DIR, TARGET_CORE, 0, 0, 0o640, 0o750)
    
    shutil.copy2(os.path.join(REPO_DIR, "setup.sh"), os.path.join(TARGET_CORE, "setup.sh"))
    os.chmod(os.path.join(TARGET_CORE, "setup.sh"), 0o755)
    
    shutil.copy2(secrets_path, os.path.join(TARGET_CORE, "config/core-secrets.yml"))
    os.chmod(os.path.join(TARGET_CORE, "config/core-secrets.yml"), 0o600)
    
    shutil.copy2(os.path.join(render_tmp, "vars.yaml"), os.path.join(TARGET_CORE, "config/vars.yaml"))
    
    # Nginx Web Assets
    for folder in ['certificates', 'shared', 'landing', 'manual']:
        src_dir = os.path.join(render_tmp, f"nginx/www/{folder}")
        dest_dir = os.path.join(DEPLOY_BASE_DIR, f"nginx/www/{folder}")
        if os.path.exists(src_dir):
            copy_tree_with_perms(src_dir, dest_dir, nginx_uid, nginx_gid, 0o644, 0o755)
            
    if os.path.exists(os.path.join(REPO_DIR, "docs")):
        copy_tree_with_perms(os.path.join(REPO_DIR, "docs"), os.path.join(DEPLOY_BASE_DIR, "nginx/www/manual/docs"), nginx_uid, nginx_gid, 0o644, 0o755)
        
    # Service Directories & Config Files
    for svc in ['nginx', 'bind9', 'stepca', 'openldap', 'keycloak', 'postgres']:
        if svc in ['keycloak', 'postgres'] and not final_vars.get('install_keycloak'): continue
        if svc == 'openldap' and not final_vars.get('install_ldap'): continue
        
        uid, gid = get_service_user(final_vars, 'bind' if svc == 'bind9' else ('step' if svc == 'stepca' else ('ldap' if svc == 'openldap' else svc)))
        
        # Deploy docker-compose
        svc_dir = os.path.join(DEPLOY_BASE_DIR, svc)
        ensure_dir(svc_dir, 0o750, uid, gid)
        src_dc = os.path.join(render_tmp, f"{svc}/docker-compose.yml")
        if os.path.exists(src_dc):
            shutil.copy2(src_dc, os.path.join(svc_dir, "docker-compose.yml"))
            os.chmod(os.path.join(svc_dir, "docker-compose.yml"), 0o640)
            os.chown(os.path.join(svc_dir, "docker-compose.yml"), uid, gid)

    # Nginx Conf
    shutil.copy2(os.path.join(render_tmp, "nginx/nginx.conf"), os.path.join(DEPLOY_BASE_DIR, "nginx/nginx.conf"))
    shutil.copy2(os.path.join(render_tmp, "nginx/bind9.conf"), os.path.join(DEPLOY_BASE_DIR, "nginx/bind9.conf"))
    os.chown(os.path.join(DEPLOY_BASE_DIR, "nginx/nginx.conf"), nginx_uid, nginx_gid)
    os.chown(os.path.join(DEPLOY_BASE_DIR, "nginx/bind9.conf"), nginx_uid, nginx_gid)
    
    # Bind9 Files
    bind_uid, bind_gid = get_service_user(final_vars, 'bind')
    for d in ['config', 'data', 'log', 'cache']:
        ensure_dir(os.path.join(DEPLOY_BASE_DIR, f"bind9/{d}"), 0o750, bind_uid, bind_gid)
    
    copy_tree_with_perms(os.path.join(render_tmp, "bind9/config"), os.path.join(DEPLOY_BASE_DIR, "bind9/config"), bind_uid, bind_gid, 0o640, 0o750)
    copy_tree_with_perms(os.path.join(render_tmp, "bind9/data"), os.path.join(DEPLOY_BASE_DIR, "bind9/data"), bind_uid, bind_gid, 0o640, 0o750)
    
    os.chmod(os.path.join(DEPLOY_BASE_DIR, "bind9/config/named.conf.keys"), 0o600)
    os.chmod(os.path.join(DEPLOY_BASE_DIR, "bind9/config/rndc.key"), 0o600)

    # OpenLDAP Files
    if final_vars.get('install_ldap'):
        ldap_uid, ldap_gid = get_service_user(final_vars, 'ldap')
        ensure_dir(os.path.join(DEPLOY_BASE_DIR, "openldap/data"), 0o750, ldap_uid, ldap_gid)
        if os.path.exists(os.path.join(render_tmp, "openldap")):
            copy_tree_with_perms(os.path.join(render_tmp, "openldap"), os.path.join(DEPLOY_BASE_DIR, "openldap"), ldap_uid, ldap_gid, 0o640, 0o750)

    # Step-CA Files
    step_uid, step_gid = get_service_user(final_vars, 'step')
    ensure_dir(os.path.join(DEPLOY_BASE_DIR, "stepca/data"), 0o750, step_uid, step_gid)
    if os.path.exists(os.path.join(render_tmp, "stepca/templates/certs")):
        copy_tree_with_perms(os.path.join(render_tmp, "stepca/templates"), os.path.join(DEPLOY_BASE_DIR, "stepca/templates"), step_uid, step_gid, 0o640, 0o750)

    # Reloading services
    print("Reloading active services...")
    res = subprocess.run("docker ps --format '{{.Names}}'", shell=True, capture_output=True, text=True)
    running = res.stdout.split('\n')
    
    if "bind9" in running:
        print("Reloading BIND9...")
        subprocess.run("docker exec -u bind bind9 rndc reload", shell=True)
        
    if "nginx" in running:
        print("Reloading NGINX...")
        subprocess.run("docker exec nginx nginx -s reload", shell=True)

    print("Deployment complete.")

if __name__ == "__main__":
    apply_deployment()
