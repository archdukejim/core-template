#!/bin/bash
# Output helpers — source this file, do not execute directly.

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
BLUE='\033[0;34m'

info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; }

usage() {
    sed -n '3,/^# ---/{ /^# ---/d; s/^# \?//p }' "$0"
    exit 0
}
