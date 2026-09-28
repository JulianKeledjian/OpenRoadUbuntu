# syntax=docker/dockerfile:1.7
#
# Open-source analog + digital IC design environment.
#
#   digital : OpenROAD-flow-scripts (OpenROAD, Yosys, OpenSTA), iverilog,
#             verilator, gtkwave
#   analog  : xschem, ngspice, Xyce, magic, netgen, KLayout
#   PDK     : gf180mcu, managed by ciel into $PDK_ROOT (a mounted volume)
#
# Everything comes from apt unless the archive version is unusable; the three
# source builds left (magic, netgen, Xyce) each carry a note saying why.
#
# Build:  make build        (see Makefile / README.md)

ARG UBUNTU_VERSION=24.04

# ---------------------------------------------------------------- versions --
# ORFS and OpenROAD must be kept in step: ORFS master calls Tcl commands that
# only exist in an OpenROAD newer than the .deb below (final_outputs.tcl uses
# set_extraction_rules_file, which this build does not have). The 26Q3 tag still
# uses the extract_parasitics -ext_model_file form that it does.
ARG ORFS_REF=26Q3
# Prebuilt OpenROAD for ubuntu 24.04, published by Precision Innovations.
ARG OPENROAD_DEB_URL=https://vaultlink.precisioninno.com/api/releases/26Q2-1164-g08f67ee5ec/openroad_26Q2-1164-g08f67ee5ec_amd64-ubuntu-24.04.deb/download
ARG MAGIC_VERSION=8.3.683
ARG GAW_REF=main
ARG NETGEN_VERSION=1.5.323
ARG XYCE_VERSION=7.10.0
ARG TRILINOS_TAG=trilinos-release-16-1-0
# Build Xyce (1) or stub it out (0). Xyce pulls in a ~40 min Trilinos build.
ARG WITH_XYCE=1
# Parallelism for the source builds. Lower this if the build runs out of RAM.
ARG BUILD_THREADS=8


# ============================================================================
# base -- shared foundation for every stage
# ============================================================================
FROM ubuntu:${UBUNTU_VERSION} AS base

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Etc/UTC

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        git \
        sudo \
        xz-utils \
        bzip2 \
        unzip \
        tzdata \
    && rm -rf /var/lib/apt/lists/*


# ============================================================================
# xyce-build -- Trilinos + Xyce, isolated so a failure here cannot block the
#               rest of the image and so it can be skipped via WITH_XYCE=0
# ============================================================================
FROM base AS xyce-build
ARG XYCE_VERSION
ARG TRILINOS_TAG
ARG BUILD_THREADS

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        gfortran \
        bison \
        flex \
        libopenblas-dev \
        liblapack-dev \
        libsuitesparse-dev \
        libfftw3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Xyce sources first: Trilinos is configured from Xyce's own initial-cache file.
RUN curl -fsSL "https://github.com/Xyce/Xyce/archive/refs/tags/Release-${XYCE_VERSION}.tar.gz" \
      | tar xz && mv "Xyce-Release-${XYCE_VERSION}" xyce

# Trilinos: static libs, no tests/examples/Fortran -- everything Xyce links is
# folded into the Xyce binary, so only /opt/xyce needs to reach the final image.
RUN curl -fsSL "https://github.com/trilinos/Trilinos/archive/refs/tags/${TRILINOS_TAG}.tar.gz" \
      | tar xz && mv "Trilinos-${TRILINOS_TAG}" trilinos \
 && cmake -C /src/xyce/cmake/trilinos/trilinos-base.cmake \
        -S /src/trilinos -B /src/trilinos-build \
        -D CMAKE_INSTALL_PREFIX=/opt/trilinos \
        -D CMAKE_BUILD_TYPE=Release \
        -D CMAKE_CXX_STANDARD=17 \
        -D BUILD_SHARED_LIBS=OFF \
        -D Trilinos_ENABLE_Fortran=OFF \
        -D Trilinos_ENABLE_TESTS=OFF \
        -D Trilinos_ENABLE_EXAMPLES=OFF \
        -D TPL_ENABLE_AMD=ON \
        -D AMD_INCLUDE_DIRS=/usr/include/suitesparse \
 && cmake --build /src/trilinos-build -j "${BUILD_THREADS}" -t install \
 && rm -rf /src/trilinos /src/trilinos-build

# Xyce's parser needs FlexLexer.h, which Ubuntu ships in libfl-dev rather than
# in flex. Installed here rather than with the Trilinos deps above because
# Trilinos does not need it, and this keeps the 20-minute Trilinos layer cached
# when this list changes.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libfl-dev \
    && rm -rf /var/lib/apt/lists/*

RUN cmake -S /src/xyce -B /src/xyce-build \
        -D CMAKE_INSTALL_PREFIX=/opt/xyce \
        -D CMAKE_BUILD_TYPE=Release \
        -D Trilinos_ROOT=/opt/trilinos \
 && cmake --build /src/xyce-build -j "${BUILD_THREADS}" -t install \
 && rm -rf /src


# Stub stage used when WITH_XYCE=0 so the final COPY always has a source.
FROM base AS xyce-skip
RUN mkdir -p /opt/xyce/bin

# Alias stages: only the one selected by WITH_XYCE enters the build graph.
FROM xyce-skip  AS xyce-0
FROM xyce-build AS xyce-1
FROM xyce-${WITH_XYCE} AS xyce


# ============================================================================
# orfs -- OpenROAD-flow-scripts: prebuilt OpenROAD + Yosys + KLayout
# ============================================================================
FROM base AS orfs
ARG ORFS_REF
ARG OPENROAD_DEB_URL
ARG BUILD_THREADS

ENV ORFS_HOME=/opt/orfs

# --recursive: DependencyInstaller delegates to tools/OpenROAD/etc/, and the
# Yosys build below needs tools/yosys and its own submodules (abc).
RUN git clone --recursive --branch "${ORFS_REF}" \
        https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts.git "${ORFS_HOME}"

WORKDIR ${ORFS_HOME}

# -base is distro packages plus the official KLayout 0.30.12 .deb. The -common
# and -all phases exist to build OpenROAD's own dependencies from source
# (or-tools, a pinned CMake 3.31.9, boost, spdlog, lemon) and are dead weight
# now that OpenROAD arrives prebuilt -- skipping them saves ~20 minutes.
#
# Two adjustments to what -base does:
#   * a stub `docker` short-circuits its Docker CE install; the installer bails
#     out early on `command -v docker`, and a container that will never run
#     docker has no use for the daemon.
#   * cmake, build-essential and libgmock-dev are added explicitly. -base
#     leaves the first two to -common, and it installs libgtest-dev without
#     libgmock-dev -- the CMake-based Yosys (0.67+, pinned by newer ORFS refs)
#     builds tests/unit with no opt-out and fails to configure on a missing
#     GTest::gmock_main target.
#
# Retried: it pulls from apt and klayout.org over several minutes, and a single
# 504 from either would otherwise discard the whole layer.
RUN set -e; \
    printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/docker; \
    chmod +x /usr/local/bin/docker; \
    n=0; \
    until [ "$n" -ge 3 ]; do \
        ./etc/DependencyInstaller.sh -base && break; \
        n=$((n+1)); \
        echo ">>> DependencyInstaller failed, retry ${n}/3 in 60s"; \
        sleep 60; \
    done; \
    if [ "$n" -ge 3 ]; then echo ">>> giving up after 3 attempts" >&2; exit 1; fi; \
    rm -f /usr/local/bin/docker; \
    apt-get update; \
    apt-get install -y --no-install-recommends build-essential cmake libgmock-dev; \
    rm -rf /var/lib/apt/lists/*

# OpenROAD, prebuilt rather than compiled. apt resolves the Qt5/Tcl runtime
# from the package's own Depends field, so the GUI works. The package ships
# both `openroad` and `sta`; the flow is pointed at them further down.
RUN curl -fsSL -o /tmp/openroad.deb "${OPENROAD_DEB_URL}" \
 && apt-get update \
 && apt-get install -y --no-install-recommends /tmp/openroad.deb \
 && rm -f /tmp/openroad.deb \
 && rm -rf /var/lib/apt/lists/* \
 && openroad -version \
 && sta -version

# Yosys, built the way build_openroad.sh does -- but invoked directly, because
# that script also builds kepler-formal: unused by the flow, and compiled with
# -march=native, which would tie the image to the CPU that built it.
#
# Which build system applies depends on ORFS_REF: Yosys dropped its Makefile for
# CMake in 0.67, so 26Q3 (Yosys 0.64) needs make and a newer ref needs cmake.
# Both are handled so bumping ORFS_REF does not silently break this layer.
# yosys-slang is the SystemVerilog frontend; ORFS builds it alongside Yosys and
# designs written in SystemVerilog fail to elaborate without it.
RUN set -e; \
    YOSYS_PREFIX="${ORFS_HOME}/tools/install/yosys"; \
    if [ -f tools/yosys/CMakeLists.txt ]; then \
        cmake -B tools/yosys/build tools/yosys \
            -DCMAKE_BUILD_TYPE=Release \
            -DYOSYS_SKIP_ABC_SUBMODULE_CHECK=ON \
            -DCMAKE_INSTALL_PREFIX="${YOSYS_PREFIX}"; \
        cmake --build tools/yosys/build --target install -j "${BUILD_THREADS}"; \
    else \
        make install -C tools/yosys -j "${BUILD_THREADS}" PREFIX="${YOSYS_PREFIX}"; \
    fi; \
    if [ -d tools/yosys-slang ]; then \
        make install -C tools/yosys-slang -j "${BUILD_THREADS}" \
            YOSYS_PREFIX="${YOSYS_PREFIX}/bin/" \
            CMAKE_FLAGS="-DYOSYS_SLANG_REVISION=unknown -DSLANG_REVISION=unknown"; \
    fi; \
    rm -rf tools/yosys/build ~/.ccache

# flow/scripts/variables.mk only honours `command -v openroad` when IN_NIX_SHELL
# is set; otherwise OPENROAD_EXE and OPENSTA_EXE are hardcoded to
# tools/install/OpenROAD/bin. Link the packaged binaries into that layout so the
# flow finds them. Kept as its own step so it does not invalidate the Yosys
# build above.
RUN mkdir -p "${ORFS_HOME}/tools/install/OpenROAD/bin" \
 && ln -sf /usr/bin/openroad "${ORFS_HOME}/tools/install/OpenROAD/bin/openroad" \
 && ln -sf /usr/bin/sta "${ORFS_HOME}/tools/install/OpenROAD/bin/sta"


# ============================================================================
# analog -- magic + netgen from source
#
# These two are the only analog tools apt cannot supply usefully:
#   magic  : no magic-vlsi package exists in the Ubuntu archive at all
#   netgen : netgen-lvs is 1.5.133 (2020), far behind the 1.5.3xx that the
#            current open_pdks gf180mcu setup files are written against
#   gaw    : not in the archive under any name (gaw, gaw3, gwave, xschem-gaw).
#            xschem's Waves button runs `gaw "$n.raw"` by default, so without
#            it that button silently does nothing
# ngspice, xschem and KLayout all come from packages further down.
# ============================================================================
FROM orfs AS analog
ARG MAGIC_VERSION
ARG NETGEN_VERSION
ARG GAW_REF
ARG BUILD_THREADS

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        m4 csh \
        libx11-dev libcairo2-dev libglu1-mesa-dev \
        tcl-dev tk-dev \
        libgtk-3-dev pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN curl -fsSL "https://github.com/RTimothyEdwards/magic/archive/refs/tags/${MAGIC_VERSION}.tar.gz" \
      | tar xz \
 && cd "magic-${MAGIC_VERSION}" \
 && ./configure --prefix=/usr/local \
 && make -j"${BUILD_THREADS}" && make install \
 && cd /src && rm -rf "magic-${MAGIC_VERSION}"

RUN curl -fsSL "https://github.com/RTimothyEdwards/netgen/archive/refs/tags/${NETGEN_VERSION}.tar.gz" \
      | tar xz \
 && cd "netgen-${NETGEN_VERSION}" \
 && ./configure --prefix=/usr/local \
 && make -j"${BUILD_THREADS}" && make install \
 && cd /src && rm -rf "netgen-${NETGEN_VERSION}"

# gaw, from the xschem author's own fork (gaw3 patched for xschem's remote
# waveform commands). --enable-gawsound=no drops the ALSA dependency; an audio
# stack has no business in this image.
RUN git clone --depth 1 --branch "${GAW_REF}" \
        https://github.com/StefanSchippers/xschem-gaw.git gaw \
 && cd gaw \
 && ./configure --prefix=/usr/local --enable-gawsound=no --disable-nls \
 && make -j"${BUILD_THREADS}" && make install \
 && cd /src && rm -rf gaw


# ============================================================================
# final -- runtime extras, Python stack, ciel, user, entrypoint
# ============================================================================
FROM analog AS final
ARG GF180MCU_VERSION=f6eeac7dad085ffcc829ccfd721f7b4ce39edcf7
ARG USER_NAME=designer
ARG USER_UID=1000
ARG USER_GID=1000

COPY --from=xyce /opt/xyce /opt/xyce

# Analog simulation + schematic capture, RTL simulation + waveforms, Xyce
# runtime libs, X11/Qt runtime bits. xterm is not optional: xschem's simulate
# command is literally `$terminal -e 'ngspice -i "$N" -a || sh'` and $terminal
# defaults to xterm, so without it the Simulate button fails silently. The archive's ngspice 42 is built with
# KLU and the XSPICE code models, and libngspice0-dev supplies the
# libngspice.so that PySpice binds to -- no source build needed for either.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ngspice \
        libngspice0-dev \
        xschem \
        xterm \
        iverilog \
        verilator \
        gtkwave \
        python3-venv \
        libopenblas0 liblapack3 libamd3 libfftw3-double3 libgfortran5 \
        libgl1 libglu1-mesa libxkbcommon-x11-0 libxcursor1 libfontconfig1 \
        x11-utils xauth \
        less nano vim-tiny bc time rsync \
    && rm -rf /var/lib/apt/lists/*

# --system-site-packages so ORFS's own python tooling (installed system-wide by
# DependencyInstaller) stays importable even though the venv fronts PATH.
RUN python3 -m venv --system-site-packages /opt/venv \
 && /opt/venv/bin/pip install --no-cache-dir --upgrade pip wheel \
 && /opt/venv/bin/pip install --no-cache-dir \
        ciel \
        numpy scipy matplotlib \
        PySpice \
        cocotb cocotb-bus \
        pandas \
        gdsfactory

ENV PDK_ROOT=/opt/pdk \
    PDK=gf180mcuD \
    GF180MCU_VERSION=${GF180MCU_VERSION} \
    ORFS_HOME=/opt/orfs \
    OPENROAD=/opt/orfs/tools/OpenROAD \
    FLOW_HOME=/opt/orfs/flow \
    QT_X11_NO_MITSHM=1 \
    PATH=/opt/venv/bin:/opt/orfs/tools/install/yosys/bin:/opt/xyce/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

COPY docker/entrypoint.sh /usr/local/bin/entrypoint
COPY docker/pdk-install.sh /usr/local/bin/pdk-install
RUN chmod +x /usr/local/bin/entrypoint /usr/local/bin/pdk-install

# ubuntu:24.04 ships a stock `ubuntu` user already sitting on uid 1000; drop it
# so the host user's uid/gid can be reused and bind mounts stay writable.
RUN if getent passwd "${USER_UID}" >/dev/null; then \
        userdel -r "$(getent passwd "${USER_UID}" | cut -d: -f1)" 2>/dev/null || true; \
    fi \
 && if getent group "${USER_GID}" >/dev/null; then \
        groupmod -n "${USER_NAME}" "$(getent group "${USER_GID}" | cut -d: -f1)"; \
    else \
        groupadd -g "${USER_GID}" "${USER_NAME}"; \
    fi \
 && useradd -m -u "${USER_UID}" -g "${USER_GID}" -s /bin/bash "${USER_NAME}" \
 && echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/${USER_NAME}" \
 && chmod 0440 "/etc/sudoers.d/${USER_NAME}" \
 && mkdir -p /opt/pdk /work \
 && chown -R "${USER_UID}:${USER_GID}" /opt/pdk /work /opt/venv \
 && chmod -R a+rwX /opt/orfs

USER ${USER_NAME}
WORKDIR /work

ENTRYPOINT ["/usr/local/bin/entrypoint"]
CMD ["/bin/bash"]
