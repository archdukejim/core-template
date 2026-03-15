# home-core

## Service Accounts and Configurations

| container | host account name | host uid | host gid |
| - | - | - | - |
| nginx | nginx | 2000 | 2000 | 
| bind9 | bind9 | 2001 | 2001 |
| stepca | step | 2002 | 2002 |
| openldap | ldap | 2003 | 2003 |
| adguardhome | adguard | 2700 | 2700 |

## Update password in AdGuardHome.yaml
 mkpasswd -m bcrypt -R 10 "password"