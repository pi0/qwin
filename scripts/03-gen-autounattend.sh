#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_env.sh"

TEMPLATE="config/Autounattend.xml.tpl"
OUTPUT="images/Autounattend.xml"

if [[ ! -f "$TEMPLATE" ]]; then
  log_error "Template not found: $TEMPLATE"
  exit 1
fi

log_info "Generating Autounattend.xml..."

# Build product key XML block (omit if no key provided)
if [[ -n "$WIN_PRODUCT_KEY" ]]; then
  PRODUCT_KEY_BLOCK="<ProductKey><Key>${WIN_PRODUCT_KEY}</Key></ProductKey>"
else
  PRODUCT_KEY_BLOCK=""
fi

export PRODUCT_KEY_BLOCK

# Substitute variables
sed \
  -e "s|{{WIN_ADMIN_PASSWORD}}|${WIN_ADMIN_PASSWORD}|g" \
  -e "s|{{WIN_PRODUCT_KEY_BLOCK}}|${PRODUCT_KEY_BLOCK}|g" \
  -e "s|{{WIN_TIMEZONE}}|${WIN_TIMEZONE}|g" \
  -e "s|{{WIN_HOSTNAME}}|${WIN_HOSTNAME}|g" \
  "$TEMPLATE" > "$OUTPUT"

log_ok "Answer file ready: $OUTPUT"
