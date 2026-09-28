#!/usr/bin/env bash
# Run a command inside the IC design image with X11 and the PDK volume attached.
#
#   ./run.sh                 # interactive bash
#   ./run.sh xschem          # launch a GUI tool
#   ./run.sh pdk-install     # one-off command
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOCKER="${DOCKER:-docker}"
IMAGE="${IMAGE:-ic-design:latest}"
PDK_VOLUME="${PDK_VOLUME:-gf180mcu-pdk}"
WORK_DIR="${WORK_DIR:-${HERE}/work}"
CONTAINER_NAME="${CONTAINER_NAME:-}"

mkdir -p "${WORK_DIR}"

args=(
    --rm
    --init
    -v "${PDK_VOLUME}:/opt/pdk"
    -v "${WORK_DIR}:/work"
    -w /work
)

# On an SELinux-enforcing host every bind mount is denied to the container
# unless it is relabelled: the X socket is user_tmp_t and ./work inherits your
# home's label, so GUIs fail with "unable to open display" and /work is
# unreadable. label=disable lifts SELinux confinement for this container only
# and, unlike a :z mount option, does not rewrite labels on the host.
if [[ "$(cat /sys/fs/selinux/enforce 2>/dev/null || echo 0)" == "1" ]]; then
    args+=(--security-opt label=disable)
fi
[[ -n "${CONTAINER_NAME}" ]] && args+=(--name "${CONTAINER_NAME}")
[[ -t 0 && -t 1 ]] && args+=(-it)

# ----------------------------------------------------------------- X11 ------
# Hand the container a cookie whose family is wildcarded, so it authenticates
# regardless of the hostname docker gives it. Falls back to xhost if the
# display has no cookie (a plain `xhost +local:` setup).
if [[ -n "${DISPLAY:-}" ]]; then
    args+=(-e "DISPLAY=${DISPLAY}" -e QT_X11_NO_MITSHM=1)
    [[ -d /tmp/.X11-unix ]] && args+=(-v /tmp/.X11-unix:/tmp/.X11-unix:rw)

    XAUTH="$(mktemp -t ic-design-xauth.XXXXXX)"
    trap 'rm -f "${XAUTH}"' EXIT
    if command -v xauth >/dev/null 2>&1 \
       && xauth nlist "${DISPLAY}" 2>/dev/null | sed -e 's/^..../ffff/' \
            | xauth -f "${XAUTH}" nmerge - 2>/dev/null \
       && [[ -s "${XAUTH}" ]]; then
        chmod 644 "${XAUTH}"
        args+=(-v "${XAUTH}:/tmp/.docker.xauth:ro" -e XAUTHORITY=/tmp/.docker.xauth)
    else
        echo "note: no X cookie for ${DISPLAY}; if GUIs fail run 'xhost +local:'" >&2
    fi
else
    echo "note: DISPLAY is unset - GUI tools will not open." >&2
fi

# Devices some tools poke at for rendering; harmless when absent.
[[ -d /dev/dri ]] && args+=(--device /dev/dri)

exec ${DOCKER} run "${args[@]}" "${IMAGE}" "$@"
