# dkms-verifier — make targets.
#
# Usage:
#   make refresh-targets                       # fetch / refresh Ubuntu KMI baselines
#   make release-branch BRANCH=<branch> SRC=<path>  # branch → tag → report (CI)
#   make release TAG=<tag> SRC=<path>          # one-shot tag → report (manual)
#   make compare A=<tagA> B=<tagB>             # delta between two releases
#   make clean-targets                         # nuke cached Ubuntu kernels
#
# Variables:
#   BRANCH  branch ref (e.g. origin/6.18/linux); resolved to TAG/BASE/HEAD
#   TAG     release tag (e.g. lts-v6.18.27-linux-260507T092754Z)
#   SRC     path to the OOT kernel git tree
#   KMODS   /lib/modules/<ver>/kernel of the OOT kernel build (mutually
#           exclusive with ARTIFACT). Default: /lib/modules/$(uname -r)/kernel
#   ARTIFACT  Path to a deb / tarball / dir produced by the upstream build
#             job. Imported via scripts/import_modules.sh.
#   BASE    override BASE detection (skip parse_tag.sh)
#   HEAD    override HEAD rev (default: HEAD of $(SRC))

SHELL := /bin/bash
ROOT  := $(CURDIR)
SRC      ?=
KMODS    ?=
ARTIFACT ?=
BASE     ?=
HEAD     ?=

.PHONY: help release release-branch refresh-targets compare clean-targets

help:
	@grep -E '^# *(make |  )' Makefile | sed 's/^# *//'

refresh-targets:
	@$(ROOT)/scripts/refresh_targets.sh

release:
	@test -n "$(TAG)" || { echo "ERROR: TAG=... required"; exit 2; }
	@test -n "$(SRC)" || { echo "ERROR: SRC=... required"; exit 2; }
	@$(ROOT)/scripts/run_release.sh \
		--tag "$(TAG)" \
		--kernel-src "$(SRC)" \
		$(if $(KMODS),--kmods "$(KMODS)",) \
		$(if $(ARTIFACT),--module-artifact "$(ARTIFACT)",) \
		$(if $(BASE),--base "$(BASE)",) \
		$(if $(HEAD),--head "$(HEAD)",)

release-branch:
	@test -n "$(BRANCH)" || { echo "ERROR: BRANCH=... required"; exit 2; }
	@test -n "$(SRC)"    || { echo "ERROR: SRC=... required";    exit 2; }
	@set -e; \
	  eval "$$($(ROOT)/scripts/resolve_branch.sh $(SRC) $(BRANCH))"; \
	  echo "[release-branch] BRANCH=$(BRANCH) TAG=$$TAG BASE=$$BASE HEAD=$$HEAD"; \
	  $(ROOT)/scripts/run_release.sh \
	    --tag "$$TAG" --base "$$BASE" --head "$$HEAD" \
	    --kernel-src "$(SRC)" \
	    $(if $(KMODS),--kmods "$(KMODS)",) \
	    $(if $(ARTIFACT),--module-artifact "$(ARTIFACT)",)

compare:
	@test -n "$(A)" -a -n "$(B)" || { echo "ERROR: A=... B=... required"; exit 2; }
	@$(ROOT)/scripts/diff_releases.sh "$(A)" "$(B)"

clean-targets:
	@rm -rf $(ROOT)/targets/*/extracted $(ROOT)/targets/*/*.deb $(ROOT)/targets/*/*.ddeb
	@echo "kept: targets/*/staged"
