# Analog + Digital IC Design Container

A single Ubuntu 24.04 image carrying a complete open-source flow for both sides
of a mixed-signal chip, with the **gf180mcu** PDK managed by `ciel`.

| Domain | Tools |
|---|---|
| Digital | OpenROAD-flow-scripts 26Q3 (OpenROAD, Yosys, OpenSTA), Icarus Verilog, Verilator, GTKWave |
| Analog | xschem, ngspice, Xyce, magic, netgen, KLayout |
| PDK | `ciel` → gf180mcu (`gf180mcuA/B/C/D`) |
| Python | numpy, scipy, matplotlib, pandas, PySpice, cocotb |

## Quick start

If your user is not in the `docker` group, prefix every invocation:
`make build DOCKER="sudo docker"` (or `sudo usermod -aG docker $USER` once and
log back in — note that this grants root-equivalent access to the daemon).

```sh
make build      # ~1–2 h on 10 cores; grab a coffee, or several
make pdk        # one-off: download gf180mcu into a docker volume
make check      # print every tool's version
make shell      # drop into the environment
```

GUI tools open on your X display directly:

```sh
make xschem
make klayout
make openroad-gui
```

`make help` lists every target.

## How it is put together

The build is staged so the slow parts cache independently:

```
ubuntu:24.04 ──┬─ xyce   : Trilinos (static) + Xyce → /opt/xyce
               └─ orfs   : ORFS submodules, DependencyInstaller, build_openroad
                    └─ analog : ngspice ×2, xschem, magic, netgen → /usr/local
                          └─ final : + Xyce, RTL sim tools, venv, user, entrypoint
```

A few decisions worth knowing about:

- **ORFS and OpenROAD are pinned together.** `ORFS_REF` is `26Q3`, not master.
  ORFS master calls `set_extraction_rules_file`, a Tcl command that does not
  exist in the 26Q2 OpenROAD `.deb`; 26Q3 still uses the
  `extract_parasitics -ext_model_file` form that it does. Moving one without
  the other breaks the flow's final report stage. This also makes the build
  reproducible instead of tracking a moving branch.
- **`setup.sh` is bypassed.** It re-invokes itself via `sudo -u $SUDO_USER`,
  which is meaningless as root in a container, so the Dockerfile calls
  `etc/DependencyInstaller.sh` directly — with `-base`, since the `-common`
  and `-all` phases exist to build OpenROAD's own dependencies (or-tools, a
  pinned CMake, boost, spdlog, lemon) and are dead weight against a prebuilt
  OpenROAD. Two gaps have to be patched because `-base` was never meant to
  stand alone: it omits `cmake`/`build-essential`, and it installs
  `libgtest-dev` without `libgmock-dev`. It also installs Docker CE into the
  image unless `docker` is already on `PATH`, which a stub binary short-circuits.
- **Yosys is built directly, not via `build_openroad.sh`.** That script also
  builds kepler-formal, which the flow does not use and which compiles with
  `-march=native` — that would tie the image to the CPU that built it.
- **Packages first.** Everything that the Ubuntu archive can supply usefully
  comes from apt. Only three things are built from source, each for a specific
  reason — see the table below.
- **Xyce links Trilinos statically**, so only `/opt/xyce` has to cross into the
  final image. It is also the longest and most fragile build in here, so it
  lives in its own stage behind `WITH_XYCE`; `make build-no-xyce` skips it
  entirely and everything else is unaffected.
- **The Python venv uses `--system-site-packages`.** It fronts `PATH`, and ORFS
  installs its own Python tooling system-wide; without this, ORFS's scripts
  would run under the venv interpreter and lose their imports.

### What comes from where

| Tool | Source | Why |
|---|---|---|
| ngspice 42 + `libngspice.so` | apt | Archive build already has KLU and the XSPICE code models; `libngspice0-dev` is exactly what PySpice binds to |
| xschem 3.4.4 | apt | Current enough for gf180mcu |
| iverilog, verilator, gtkwave | apt | — |
| KLayout 0.30.7 | official `.deb` | Installed by ORFS's DependencyInstaller; apt only has 0.28.16 |
| OpenROAD 26Q2 + OpenSTA | prebuilt `.deb` | Precision Innovations build for ubuntu 24.04; also removes the need for OpenROAD's source-built dependencies |
| Yosys 0.64 + yosys-slang | source (ORFS) | apt has 0.33; ORFS pins its own much newer fork |
| magic 8.3.683 | source | No `magic-vlsi` package exists in the Ubuntu archive |
| netgen 1.5.323 | source | `netgen-lvs` is 1.5.133 (2020), well behind what current open_pdks gf180mcu setup files expect |
| Xyce 7.10 + Trilinos 16.1 | source | Xyce is not packaged; apt's Trilinos is 13.2.0 and Xyce needs ≥ 14.4 |

## The PDK

PDKs live in a docker volume (`gf180mcu-pdk`) mounted at `/opt/pdk`, not baked
into the image. That keeps the image smaller and lets you move between PDK
builds without a rebuild.

```sh
make pdk-list                       # what ciel has upstream
make pdk                            # install the pinned version
./run.sh pdk-install <commit-hash>  # install some other build
```

The pinned version is the `GF180MCU_VERSION` build arg in the Dockerfile
(currently `f6eeac7…`, the 2026-07-14 open_pdks build). `$PDK` selects the
variant and defaults to `gf180mcuD`.

On container start the entrypoint points each tool at whatever is in
`$PDK_ROOT/$PDK`:

| Tool | Wiring |
|---|---|
| xschem | `~/.xschem/xschemrc` sources the PDK's xschemrc |
| magic | `~/.magicrc` sources `gf180mcuD.magicrc` |
| KLayout | `KLAYOUT_PATH` includes the PDK technology |
| netgen | `NETGEN_SETUP` points at the LVS setup file |
| ngspice | `SPICE_LIB_DIR` points at the model libraries |

The two generated rc files are written only if absent, so your edits survive.

Note that **ORFS does not use this PDK**. Its gf180 platform files (LEF, LIB,
tech) are checked into the ORFS repo under `flow/platforms/gf180`, and the
digital flow reads those. The ciel-managed PDK serves the analog tools.

## Working in it

Your host `./work` directory is bind-mounted at `/work` and the container user
is built with your uid/gid, so files come out owned by you. Everything else in
the container is disposable — `run.sh` passes `--rm`.

```sh
./run.sh                       # interactive shell
./run.sh ngspice -b sim.sp     # one-off command
./run.sh xschem tb.sch         # GUI on a file in ./work
```

Digital flow:

```sh
./run.sh bash -lc 'cd $ORFS_HOME/flow && make WORK_HOME=/work DESIGN_CONFIG=./designs/gf180/uart-blocks/config.mk'
make orfs-demo                 # the same thing
```

`WORK_HOME=/work` matters: ORFS defaults its `results/`, `logs/` and `reports/`
to the current directory, which is inside the container and vanishes with
`--rm`. Pointing it at `/work` puts the GDS on your host, owned by you.

## X11

`run.sh` builds a wildcarded X cookie with `xauth` and mounts it, which works
regardless of the container's hostname. If your display has no cookie at all,
it says so and `xhost +local:` is the fallback. On Wayland this needs Xwayland
(usually already running).

**On an SELinux-enforcing host** (this one included) every bind mount is denied
to the container unless relabelled — the X socket is `user_tmp_t` and `./work`
carries your home's label, so GUIs fail with *unable to open display* and
`/work` is unreadable. `run.sh` detects enforcing mode and adds
`--security-opt label=disable`, which lifts confinement for that container only;
unlike a `:z` mount option it does not rewrite labels on your host.

## KLayout, PCells and DRC

The gf180mcu KLayout integration needs three things the PDK does not provide
itself. The entrypoint handles all of them:

- **`USER` must be set.** `draw_efuse.py` reads `os.environ["USER"]` unguarded,
  and Docker sets neither `USER` nor `LOGNAME`, so the whole PCell tree failed
  to load with a `KeyError`. It is now derived from the running uid.
- **gdsfactory.** The PDK's newer PCells `import gdsfactory`; without it they
  are skipped with a warning (the older KLayout-API PCells still work). It is
  installed in the venv, and `KLAYOUT_PYTHONPATH` points KLayout's embedded
  interpreter — Python 3.12, same as the venv — at it.
- **`drc_defaults.yml` is missing from the PDK.** Only `lvs_defaults.yml` ships,
  so `option_drc()` in `macros/options_helper.rb` reads a nonexistent file and
  the GUI's *Run Klayout DRC* dies before launching anything — the menu item
  appears to do nothing at all. A `drc_options.yml` is seeded into
  `~/.config/klayout_gf180mcu/`; the PDK's own options dialog overwrites it.

Two things worth knowing about the GUI DRC macro:

- It does not run DRC in-process. It reads the **filename of the loaded
  layout**, shells out to `klayout -b -r .../gf180mcu.drc`, streams progress to
  the *macro log window*, and writes `<layout>.lyrdb` beside the GDS before
  loading it into the marker browser. A layout that has never been saved to
  disk has no filename, and the run is skipped silently.
- `workers` must be `1` on KLayout before 0.30.9, and ORFS 26Q3 installs 0.30.7.
- Upstream bug worth knowing: in `gf180mcu_options.lym` the "Antenna rules"
  checkbox writes to the `offgrid` key, so those two cannot be set independently
  from the dialog.

From the command line, skipping the GUI entirely:

```sh
make drc GDS=work/results/gf180/uart-blocks/base/6_final.gds
```

That writes a `.lyrdb` next to the GDS; open it in KLayout via
*Tools > Marker Browser*. Density and antenna decks are off by default — both
are slow and density needs full-chip context.

## Simulating with the PDK

ngspice does not expand environment variables inside `.include` / `.lib`, and
the corner sections live in `sm141064.ngspice` — `design.ngspice` only carries
global settings. Write both paths out in full:

```spice
.include /opt/pdk/gf180mcuD/libs.tech/ngspice/design.ngspice
.lib     /opt/pdk/gf180mcuD/libs.tech/ngspice/sm141064.ngspice typical
```

Corners available in that file: `typical`, `ff`, `ss`, `fs`, `sf`, plus
`bjt_*`, `diode_*` and `res_*` variants.

`SPICE_LIB_DIR` is deliberately left unset. It points at ngspice's *own*
library — `spinit` and the XSPICE `.cm` code models — so aiming it at the PDK
silently disables XSPICE.

PySpice prints `Unsupported Ngspice version 42` on startup. It is a version
check, not a failure; the binding works.

### xschem's Simulate button needs a terminal emulator

xschem does not run the simulator in-process. Its default command is literally

```tcl
set_ne sim(spice,0,cmd) {$terminal -e 'ngspice -i "$N" -a || sh'}
```

with `$terminal` defaulting to `xterm`. A container without a terminal emulator
makes Simulate fail silently — no error, nothing happens. `xterm` is therefore
installed deliberately; do not prune it as desktop cruft.

## Tuning the build

| Build arg | Default | Purpose |
|---|---|---|
| `BUILD_THREADS` | 8 | Parallelism. Lower it if the build gets OOM-killed |
| `WITH_XYCE` | 1 | `0` skips Trilinos + Xyce |
| `ORFS_REF` | `26Q3` | ORFS tag; must stay in step with `OPENROAD_DEB_URL` |
| `OPENROAD_DEB_URL` | 26Q2 build | Prebuilt OpenROAD package |
| `USER_UID` / `USER_GID` | 1000 | Matched to your host user by the Makefile |
| `GF180MCU_VERSION` | `f6eeac7…` | Default PDK build for `pdk-install` |

The `DOCKER` make variable (and the `DOCKER` env var read by `run.sh`) selects
the docker binary, for `sudo docker` or a podman shim.

The remaining source-built tools are pinned by build args at the top of the
Dockerfile (`MAGIC_VERSION`, `NETGEN_VERSION`, `XYCE_VERSION`, `TRILINOS_TAG`). Xyce only supports Trilinos 14.4–16.1, so do not move
`TRILINOS_TAG` past `trilinos-release-16-1-0` without checking upstream first.
