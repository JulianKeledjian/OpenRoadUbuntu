#!/usr/bin/env bash
# Install/activate the gf180mcu PDK into $PDK_ROOT using ciel.
#
#   pdk-install              # install the version pinned at image build time
#   pdk-install <hash>       # install a specific open_pdks build
#   pdk-install --list       # show what is available upstream
set -euo pipefail

PDK_ROOT="${PDK_ROOT:-/opt/pdk}"
PDK_FAMILY="${PDK_FAMILY:-gf180mcu}"

if [[ "${1:-}" == "--list" || "${1:-}" == "-l" ]]; then
    exec ciel ls-remote --pdk-family "${PDK_FAMILY}"
fi

VERSION="${1:-${GF180MCU_VERSION:-}}"
if [[ -z "${VERSION}" ]]; then
    echo "error: no PDK version given and GF180MCU_VERSION is unset" >&2
    echo "       try: pdk-install --list" >&2
    exit 1
fi

if [[ ! -w "${PDK_ROOT}" ]]; then
    echo "error: ${PDK_ROOT} is not writable by $(id -un)." >&2
    echo "       Mount it as a volume owned by uid $(id -u), e.g. 'make pdk'." >&2
    exit 1
fi

echo ">>> installing ${PDK_FAMILY} @ ${VERSION} into ${PDK_ROOT}"
export PDK_ROOT
ciel enable --pdk-family "${PDK_FAMILY}" "${VERSION}"

echo
echo ">>> installed variants:"
find "${PDK_ROOT}" -maxdepth 1 -name "${PDK_FAMILY}*" -printf '    %f\n' | sort
echo
echo "Active PDK for this image is \$PDK = ${PDK:-gf180mcuD}"
