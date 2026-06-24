#!/usr/bin/env bash
# render-config.sh - substitute runtime values into an OCUDU YAML template.
#
# Used as a Helm initContainer. Reads a *.tmpl from a mounted ConfigMap and
# writes the rendered YAML to a shared emptyDir, substituting:
#   - environment variables (envsubst), e.g. ${POD_IP}, ${AMF_ADDR}
#   - the SR-IOV fronthaul PCI address exported by the SR-IOV device plugin
#     into ${PCIDEVICE_*} env vars (first match wins -> ${FH_PCI}).
#
# Usage: render-config.sh /tmpl/du.yml.tmpl /etc/ocudu/du.yml
set -euo pipefail
src="${1:?template path required}"
dst="${2:?output path required}"

# Pick up the fronthaul VF PCI address assigned by the SR-IOV device plugin.
# The plugin exports PCIDEVICE_<RESOURCEPREFIX>_<RESOURCENAME>=0000:xx:yy.z
if [[ -z "${FH_PCI:-}" ]]; then
  for v in $(compgen -e | grep -E '^PCIDEVICE_' || true); do
    val="${!v}"
    if [[ "$val" =~ ^[0-9a-fA-F]{4}:[0-9a-fA-F]{2}: ]]; then
      export FH_PCI="${val%%,*}"   # first device if several were allocated
      break
    fi
  done
fi
export FH_PCI="${FH_PCI:-0000:00:00.0}"

mkdir -p "$(dirname "$dst")"
envsubst < "$src" > "$dst"
echo "Rendered $dst (FH_PCI=${FH_PCI})"
cat "$dst"
