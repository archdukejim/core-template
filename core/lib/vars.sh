#!/bin/bash
# YAML mutation helpers — source this file, do not execute directly.

# -----------------------------------------------------------------------
# _vars_list_append <key> <json_entry>
# Append an entry to a top-level YAML list in custom-vars.yaml.
# Tries ruamel.yaml first (preserves comments), falls back to PyYAML.
# -----------------------------------------------------------------------
_vars_list_append() {
    local key="$1" json_entry="$2"
    VARS_KEY="$key" VARS_ENTRY="$json_entry" VARS_FILE="$CUSTOM_VARS_FILE" \
    python3 - <<'PYEOF'
import json, os
key = os.environ['VARS_KEY']
entry = json.loads(os.environ['VARS_ENTRY'])
vars_file = os.environ['VARS_FILE']
try:
    from ruamel.yaml import YAML
    from ruamel.yaml.comments import CommentedSeq
    ry = YAML(); ry.preserve_quotes = True; ry.width = 4096
    with open(vars_file) as f: data = ry.load(f)
    lst = data.get(key)
    if not lst:
        data[key] = CommentedSeq([entry])
    else:
        lst.append(entry)
    with open(vars_file, 'w') as f: ry.dump(data, f)
    print("[+] custom-vars.yaml updated (comments preserved)")
except ImportError:
    import yaml
    with open(vars_file) as f: data = yaml.safe_load(f)
    if not data.get(key): data[key] = []
    data[key].append(entry)
    with open(vars_file, 'w') as f:
        yaml.dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
    print("[!] custom-vars.yaml updated (ruamel.yaml unavailable — comments may be reformatted)")
PYEOF
}

# -----------------------------------------------------------------------
# _vars_dns_record_append <zone> <record_type> <json_record>
# Append a DNS record to the nested dns dict in custom-vars.yaml.
# Navigates: dns[zone][record_type] → list of records.
# -----------------------------------------------------------------------
_vars_dns_record_append() {
    local zone="$1" rtype="$2" json_record="$3"
    VARS_ZONE="$zone" VARS_RTYPE="$rtype" VARS_RECORD="$json_record" VARS_FILE="$CUSTOM_VARS_FILE" \
    python3 - <<'PYEOF'
import json, os
zone      = os.environ['VARS_ZONE']
rtype     = os.environ['VARS_RTYPE']
record    = json.loads(os.environ['VARS_RECORD'])
vars_file = os.environ['VARS_FILE']
try:
    from ruamel.yaml import YAML
    from ruamel.yaml.comments import CommentedMap, CommentedSeq
    ry = YAML(); ry.preserve_quotes = True; ry.width = 4096
    with open(vars_file) as f: data = ry.load(f)
    dns = data.get('dns')
    if dns is None:
        data['dns'] = CommentedMap({zone: CommentedMap({rtype: CommentedSeq([record])})})
    else:
        if zone not in dns:
            dns[zone] = CommentedMap({rtype: CommentedSeq([record])})
        elif rtype not in dns[zone]:
            dns[zone][rtype] = CommentedSeq([record])
        else:
            dns[zone][rtype].append(record)
    with open(vars_file, 'w') as f: ry.dump(data, f)
    print("[+] custom-vars.yaml updated (comments preserved)")
except ImportError:
    import yaml
    with open(vars_file) as f: data = yaml.safe_load(f)
    if 'dns' not in data or data['dns'] is None: data['dns'] = {}
    if zone not in data['dns']: data['dns'][zone] = {}
    if rtype not in data['dns'][zone]: data['dns'][zone][rtype] = []
    data['dns'][zone][rtype].append(record)
    with open(vars_file, 'w') as f:
        yaml.dump(data, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
    print("[!] custom-vars.yaml updated (ruamel.yaml unavailable — comments may be reformatted)")
PYEOF
}

# -----------------------------------------------------------------------
# _vars_archive <label>
# Save a timestamped backup of custom-vars.yaml before modifying it.
# Backups stored in $ARCHIVE_DIR/vars/<timestamp>_<label>.yaml
# -----------------------------------------------------------------------
_vars_archive() {
    local label="$1"
    local timestamp; timestamp="$(date -u '+%Y%m%d-%H%M%S')"
    local vars_archive_dir="$ARCHIVE_DIR/vars"
    mkdir -p "$vars_archive_dir"
    local backup="${vars_archive_dir}/${timestamp}_${label}.yaml"
    cp "$CUSTOM_VARS_FILE" "$backup"
    ok "custom-vars.yaml backed up to ${backup}"
}
