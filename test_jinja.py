import jinja2
import yaml

template = """
{% set cname_ca = 'ca' %}
{% set cname_certificates = 'certificates' %}
{% set cname_dns = 'dns' %}
{% set cname_ldap = 'ldap' %}
{% set cname_sso = 'sso' %}
{% set hostname = 'core-server' %}
{% set host_ip = '192.168.1.100' %}

{% set default_cnames = [
  { 'canonical': hostname, 'name': cname_ca },
  { 'canonical': hostname, 'name': cname_certificates },
  { 'canonical': hostname, 'name': cname_dns },
  { 'canonical': hostname, 'name': cname_ldap },
  { 'canonical': hostname, 'name': cname_sso }
] %}
{% set default_a = [
  { 'ip': host_ip, 'name': hostname }
] %}
{% set _user_dns = dns | default({'dynamic_zone_var': {'zone_authority': true}}) %}
{% set _dynamic_zone = _user_dns.get('dynamic_zone_var', {}) %}
{% set _merged_a = (_dynamic_zone.get('A', []) + default_a) | unique | list %}
{% set _merged_cname = (_dynamic_zone.get('CNAME', []) + default_cnames) | unique | list %}
{% set _ = _dynamic_zone.update({'A': _merged_a, 'CNAME': _merged_cname}) %}
{% set _ = _user_dns.update({'dynamic_zone_var': _dynamic_zone}) %}

dns:
{% for zone_key, zone_records in _user_dns.items() %}
{% set zone_name = 'example.com' if zone_key == 'dynamic_zone_var' else zone_key %}
  {{ zone_name }}:
{{ zone_records | to_nice_yaml(indent=4) | indent(4, first=True) }}
{% endfor %}

reverse_zone_names:
{{ _user_dns.values() |
   selectattr('A', 'defined') |
   map(attribute='A') |
   flatten |
   map(attribute='ip') |
   select('match', '^\d+\.\d+\.\d+\.\d+$') |
   map('regex_replace', '^(\d+)\.(\d+)\.(\d+)\.\d+$', '\\3.\\2.\\1.in-addr.arpa') |
   unique |
   list |
   to_nice_yaml(indent=2) |
   indent(2, first=True) }}
"""

def to_nice_yaml(a, indent=4):
    return yaml.dump(a, default_flow_style=False, indent=indent).strip()

env = jinja2.Environment()
env.filters['to_nice_yaml'] = to_nice_yaml
# dummy flatten for test since we don't have ansible filters
def flatten(lst):
    return [item for sublist in lst for item in sublist]
env.filters['flatten'] = flatten
def regex_replace(s, p, r):
    import re
    return re.sub(p, r, s)
env.filters['regex_replace'] = regex_replace
def unique(lst):
    # poor man's unique for dicts
    seen = []
    for d in lst:
        if d not in seen:
            seen.append(d)
    return seen
env.filters['unique'] = unique
env.tests['match'] = lambda val, p: __import__('re').match(p, val) is not None

print(env.from_string(template).render(dns={'dynamic_zone_var': {'zone_authority': True}}))
