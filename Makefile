# Analog + digital IC design container.
# Everything here is a thin wrapper around `docker build` / ./run.sh.

DOCKER      ?= docker
IMAGE       ?= ic-design:latest
PDK_VOLUME  ?= gf180mcu-pdk
THREADS     ?= $(shell nproc)
UID         ?= $(shell id -u)
GID         ?= $(shell id -g)

BUILD_ARGS = \
	--build-arg BUILD_THREADS=$(THREADS) \
	--build-arg USER_UID=$(UID) \
	--build-arg USER_GID=$(GID)

RUN = IMAGE=$(IMAGE) PDK_VOLUME=$(PDK_VOLUME) DOCKER="$(DOCKER)" ./run.sh

.PHONY: help
help:                       ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: build
build:                      ## Build the full image (OpenROAD + analog + Xyce)
	DOCKER_BUILDKIT=1 $(DOCKER) build $(BUILD_ARGS) -t $(IMAGE) .

.PHONY: build-no-xyce
build-no-xyce:              ## Build without Xyce (skips the long Trilinos build)
	DOCKER_BUILDKIT=1 $(DOCKER) build $(BUILD_ARGS) --build-arg WITH_XYCE=0 -t $(IMAGE) .

.PHONY: pdk
pdk:                        ## Install gf180mcu into the PDK volume (run once)
	$(RUN) pdk-install

.PHONY: pdk-list
pdk-list:                   ## List gf180mcu builds available from ciel
	$(RUN) pdk-install --list

.PHONY: shell
shell:                      ## Interactive shell in the container
	$(RUN) bash

.PHONY: xschem klayout magic gtkwave openroad-gui
xschem:                     ## Launch xschem
	$(RUN) xschem
klayout:                    ## Launch KLayout (PDK technology preloaded)
	$(RUN) klayout -e
magic:                      ## Launch magic with the PDK techfile
	$(RUN) magic
gtkwave:                    ## Launch GTKWave
	$(RUN) gtkwave
openroad-gui:               ## Launch the OpenROAD GUI
	$(RUN) openroad -gui

.PHONY: drc
drc:                        ## DRC a layout: make drc GDS=work/foo.gds [TOP=cellname]
	@test -n "$(GDS)" || { echo "usage: make drc GDS=work/<file>.gds [TOP=<cell>]"; exit 1; }
	$(RUN) bash -lc 'D=$$PDK_ROOT/$$PDK/libs.tech/klayout/tech/drc; \
	  klayout -b -r $$D/gf180mcu.drc \
	    -rd input=/work/$(patsubst work/%,%,$(GDS)) \
	    -rd report=/work/$(patsubst work/%,%,$(basename $(GDS))).lyrdb \
	    -rd variant=$${PDK#gf180mcu} -rd run_mode=deep \
	    -rd decks=all,-density,-antenna \
	    $(if $(TOP),-rd topcell=$(TOP),) -rd verbose=false'
	@echo "report: $(basename $(GDS)).lyrdb  (open in KLayout: Tools > Marker Browser)"

.PHONY: check
check:                      ## Report the version of every installed tool
	$(RUN) bash -lc '\
	  set +e; \
	  echo "openroad : $$(openroad -version 2>&1 | head -1)"; \
	  echo "yosys    : $$(yosys -V 2>&1 | head -1)"; \
	  echo "klayout  : $$(klayout -v 2>&1 | head -1)"; \
	  echo "magic    : $$(magic --version 2>&1 | head -1)"; \
	  echo "netgen   : $$(netgen -batch </dev/null 2>&1 | grep -i '^Netgen' | head -1)"; \
	  echo "xschem   : $$(xschem --version 2>&1 | head -2 | tail -1)"; \
	  echo "ngspice  : $$(ngspice --version 2>&1 | grep -i ngspice- | head -1)"; \
	  echo "Xyce     : $$(Xyce -v 2>&1 | head -1)"; \
	  echo "iverilog : $$(iverilog -V 2>&1 | head -1)"; \
	  echo "verilator: $$(verilator --version 2>&1 | head -1)"; \
	  echo "gtkwave  : $$(gtkwave --version 2>&1 | head -1)"; \
	  echo "ciel     : $$(ciel --version 2>&1 | head -1)"; \
	  echo "PDK      : $$PDK_ROOT/$$PDK $$([ -d $$PDK_ROOT/$$PDK ] && echo OK || echo MISSING)"'

.PHONY: smoke
smoke:                      ## Run a tiny ngspice + ORFS sanity check
	$(RUN) bash -lc '\
	  set -e; \
	  printf "v1 1 0 1\nr1 1 0 1k\n.op\n.end\n" > /tmp/t.sp; \
	  ngspice -b /tmp/t.sp | tail -20; \
	  cd $$ORFS_HOME/flow && make WORK_HOME=/work DESIGN_CONFIG=./designs/gf180/uart-blocks/config.mk synth'

.PHONY: orfs-demo
orfs-demo:                  ## Run the gf180 uart-blocks design end to end through ORFS
	$(RUN) bash -lc 'cd $$ORFS_HOME/flow && make WORK_HOME=/work DESIGN_CONFIG=./designs/gf180/uart-blocks/config.mk'

.PHONY: size
size:                       ## Show the image size
	$(DOCKER) image ls $(IMAGE)

.PHONY: clean-pdk
clean-pdk:                  ## Delete the PDK volume
	$(DOCKER) volume rm $(PDK_VOLUME)
