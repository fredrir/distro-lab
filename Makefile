SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

ROOT := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
ENV_FILE ?= $(ROOT)/.env

STACKS := shared gentoo-dev nixos-dev
ACTIONS := init validate plan apply destroy refresh output show

DIR_shared := src/vm/shared
DIR_gentoo-dev := src/distros/gentoo-dev/tofu
DIR_nixos-dev := src/distros/nixos-dev/tofu

TOFU_ARGS ?=

LOAD_ENV = test -f "$(ENV_FILE)" || { echo "$(ENV_FILE) not found: cp .env.example .env" >&2; exit 1; }; set -a; source "$(ENV_FILE)"; set +a;

.DEFAULT_GOAL := help

.PHONY: help fmt env $(foreach s,$(STACKS),$(foreach a,$(ACTIONS),$(s)/$(a)))

help:
	@echo "usage: make <stack>/<action> [TOFU_ARGS=...] [ENV_FILE=...]"
	@echo
	@echo "stacks:  $(STACKS)"
	@echo "actions: $(ACTIONS)"
	@echo "extra:   fmt env"
	@echo
	@echo "example: make nixos-dev/plan"
	@echo "         make nixos-dev/apply TOFU_ARGS=-auto-approve"

fmt:
	@tofu fmt -recursive "$(ROOT)/src"

env:
	@$(LOAD_ENV) env | grep '^TF_VAR_' | sort

define STACK_RULE
$(1)/$(2):
	@$$(LOAD_ENV) tofu -chdir="$$(ROOT)/$$(DIR_$(1))" $(2) $$(TOFU_ARGS)
endef

$(foreach s,$(STACKS),$(foreach a,$(ACTIONS),$(eval $(call STACK_RULE,$(s),$(a)))))
