#!/usr/bin/env bash
# Wires the per-tool config files to whichever PDK is present in $PDK_ROOT,
# then hands off to the requested command.
set -euo pipefail

PDK_ROOT="${PDK_ROOT:-/opt/pdk}"
PDK="${PDK:-gf180mcuD}"
PDK_PATH="${PDK_ROOT}/${PDK}"

# Docker sets neither USER nor LOGNAME. The gf180mcu KLayout PCell library reads
# os.environ["USER"] unguarded (draw_efuse.py), so its whole pymacro tree fails
# to load with a KeyError without this. Derived from the uid actually in use so
# it stays correct under `docker run --user`.
: "${USER:=$(id -un 2>/dev/null || echo designer)}"
: "${LOGNAME:=${USER}}"
export USER LOGNAME

if [[ -d "${PDK_PATH}" ]]; then
    # xschem: PDK ships a complete xschemrc; chain to it so PDK updates land
    # automatically and anything the user adds below survives.
    if [[ ! -e "${HOME}/.xschem/xschemrc" && -f "${PDK_PATH}/libs.tech/xschem/xschemrc" ]]; then
        mkdir -p "${HOME}/.xschem"
        cat > "${HOME}/.xschem/xschemrc" <<EOF
# Generated on first container start. Edit freely - it is not regenerated.
source ${PDK_PATH}/libs.tech/xschem/xschemrc
EOF
    fi

    # magic: read by magic when started outside a directory with its own .magicrc
    if [[ ! -e "${HOME}/.magicrc" && -f "${PDK_PATH}/libs.tech/magic/${PDK}.magicrc" ]]; then
        cat > "${HOME}/.magicrc" <<EOF
# Generated on first container start. Edit freely - it is not regenerated.
source ${PDK_PATH}/libs.tech/magic/${PDK}.magicrc
EOF
    fi

    # klayout: puts the PDK technology (layer properties, DRC) on the search path
    if [[ -d "${PDK_PATH}/libs.tech/klayout" ]]; then
        export KLAYOUT_PATH="${PDK_PATH}/libs.tech/klayout:${HOME}/.klayout"
    fi

    # The PCell library reads GF_PDK_OPTION to pick the metal stack variant and
    # warns that it is "assuming option D" when unset. Derive it from $PDK so
    # the choice is explicit and follows a change of variant.
    export GF_PDK_OPTION="${PDK#gf180mcu}"

    # KLayout embeds its own Python (3.12 on noble, the same version the venv
    # uses) but does not see the venv. Expose it so the PDK's gdsfactory-based
    # PCells import; without it they are skipped with a warning at startup.
    if [[ -z "${KLAYOUT_PYTHONPATH:-}" ]]; then
        for _sp in /opt/venv/lib/python3.*/site-packages; do
            [[ -d "${_sp}" ]] && export KLAYOUT_PYTHONPATH="${_sp}" && break
        done
    fi

    # The PDK ships lvs_defaults.yml but NOT drc_defaults.yml, so option_drc()
    # in macros/options_helper.rb reads a file that does not exist and the GUI
    # "Run Klayout DRC" macro dies before it launches anything -- it looks like
    # the menu item simply does nothing. Seed the user-level options file it
    # prefers so DRC is runnable out of the box; the PDK's options dialog
    # overwrites this once you use it.
    _drc_opts="${XDG_CONFIG_HOME:-${HOME}/.config}/klayout_gf180mcu/drc_options.yml"
    if [[ ! -e "${_drc_opts}" ]]; then
        mkdir -p "$(dirname "${_drc_opts}")"
        cat > "${_drc_opts}" <<EOF
---
# Seeded by the container because the PDK omits drc_defaults.yml.
run_mode: deep
variant: ${PDK#gf180mcu}
top_cell_name: ''
verbose: true
threads: max
# KLayout before 0.30.9 (this image ships 0.30.7) cannot run parallel DRC
# workers; raise this only if you upgrade KLayout.
workers: '1'
feol: true
beol: true
offgrid: true
# Off by default: both are slow and density needs a full-chip context.
density: false
antenna: false
EOF
    fi

    # The PCell code loads fixed layout (efuse et al) from a hardcoded
    # ~/.klayout/pymacros/cells path rather than from the PDK it ships in.
    # Link it so those cells resolve.
    if [[ -d "${PDK_PATH}/libs.tech/klayout/tech/pymacros/cells" \
          && ! -e "${HOME}/.klayout/pymacros/cells" ]]; then
        mkdir -p "${HOME}/.klayout/pymacros"
        ln -sfn "${PDK_PATH}/libs.tech/klayout/tech/pymacros/cells" \
                "${HOME}/.klayout/pymacros/cells"
    fi

    # netgen: LVS setup file, referenced as `netgen -batch lvs "... $NETGEN_SETUP"`
    if [[ -f "${PDK_PATH}/libs.tech/netgen/${PDK}_setup.tcl" ]]; then
        export NETGEN_SETUP="${PDK_PATH}/libs.tech/netgen/${PDK}_setup.tcl"
    fi

    # ngspice: deliberately NOT setting SPICE_LIB_DIR. That variable points at
    # ngspice's OWN library (spinit and the XSPICE .cm code models); aiming it
    # at the PDK breaks both. Reference the models from the netlist instead:
    #   .include $PDK_ROOT/$PDK/libs.tech/ngspice/design.ngspice
    #   .lib     $PDK_ROOT/$PDK/libs.tech/ngspice/sm141064.ngspice typical
else
    cat >&2 <<EOF
------------------------------------------------------------------
No PDK found at ${PDK_PATH}.

The analog tools will start, but without gf180mcu models, layers
or symbols. Install the PDK once into the mounted volume with:

    pdk-install

(from the host: 'make pdk')
------------------------------------------------------------------
EOF
fi

exec "$@"
