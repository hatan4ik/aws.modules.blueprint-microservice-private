SHELL := /bin/bash
.DEFAULT_GOAL := check

# The blueprint is one root module; examples and the integration roots are
# validated and linted like any module.
ROOT_DIRS     := .
EXAMPLE_DIRS  := $(sort $(patsubst %/,%,$(dir $(wildcard examples/*/*.tf))))
FIXTURE_DIRS  := tests/integration/setup tests/integration/e2e
ALL_DIRS      := $(ROOT_DIRS) $(EXAMPLE_DIRS) $(FIXTURE_DIRS)
TFLINT_CONFIG := $(CURDIR)/.tflint.hcl
TFDOCS_CONFIG := $(CURDIR)/.terraform-docs.yml
# Must match the terraform-docs bundled by the CI action (terraform-docs/gh-actions
# v1.4.1 ships 0.20.0); newer versions change table formatting and fail the
# docs drift check in CI.
TFDOCS_VERSION := v0.20.0
# The contract tests use override_module, which Terraform 1.7 does not honour
# (the overridden module is still planned). The module itself supports 1.7;
# only `terraform test` needs 1.8 or later. CI runs the tests with 1.8.5.
TEST_TERRAFORM ?= terraform

.PHONY: check fmt fmt-fix init validate lint test ordering docs-version docs docs-check security lock integration-e2e clean

check: fmt validate lint test ordering docs-check security

fmt:
	@echo "==> fmt ."
	@terraform fmt -check -recursive -diff

fmt-fix:
	@echo "==> fmt-fix ."
	@terraform fmt -recursive

init:
	@for dir in $(ALL_DIRS); do \
	  echo "==> init $$dir"; \
	  (cd "$$dir" && terraform init -backend=false -input=false >/dev/null) || exit 1; \
	done

validate: init
	@for dir in $(ALL_DIRS); do \
	  echo "==> validate $$dir"; \
	  (cd "$$dir" && terraform validate) || exit 1; \
	done

lint:
	@echo "==> lint (tflint --init)"
	@tflint --init --config="$(TFLINT_CONFIG)"
	@for dir in $(ALL_DIRS); do \
	  echo "==> lint $$dir"; \
	  (cd "$$dir" && tflint --config="$(TFLINT_CONFIG)" --format compact) || exit 1; \
	done

test:
	@$(TEST_TERRAFORM) version -json | python3 -c 'import json,sys; v=tuple(int(p) for p in json.load(sys.stdin)["terraform_version"].split(".")[:2]); sys.exit(0 if v >= (1, 8) else 1)' || { \
	  echo "error: terraform test needs Terraform >= 1.8 (override_module); run 'make test TEST_TERRAFORM=/path/to/terraform-1.8.x'" >&2; exit 1; }
	@echo "==> test ."
	@$(TEST_TERRAFORM) init -backend=false -input=false >/dev/null
	@$(TEST_TERRAFORM) test

ordering:
	@echo "==> ordering (the ECS service waits for the ALB listeners)"
	@scripts/check-listener-ordering.sh

docs-version:
	@terraform-docs --version | grep -q "$(TFDOCS_VERSION)" || { \
	  echo "error: terraform-docs $(TFDOCS_VERSION) is required (found: $$(terraform-docs --version)); CI generates docs with that version" >&2; exit 1; }

docs: docs-version
	@for dir in $(ALL_DIRS); do \
	  echo "==> docs $$dir"; \
	  terraform-docs -c "$(TFDOCS_CONFIG)" "$$dir" || exit 1; \
	done

docs-check: docs-version
	@for dir in $(ALL_DIRS); do \
	  echo "==> docs-check $$dir"; \
	  terraform-docs -c "$(TFDOCS_CONFIG)" --output-check "$$dir" || exit 1; \
	done

security:
	@echo "==> security checkov ."
	@checkov -d . --framework terraform --quiet --compact
	@if command -v trivy >/dev/null 2>&1; then \
	  echo "==> security trivy ."; \
	  trivy config --severity HIGH,CRITICAL --exit-code 1 .; \
	else \
	  echo "==> security trivy . (skipped: trivy not on PATH)"; \
	fi

# Creates real, billable resources in the caller's own account and destroys
# them afterwards. See tests/integration/README.md.
integration-e2e:
	@scripts/integration-e2e.sh

lock:
	@echo "==> lock ."
	@terraform providers lock -platform=linux_amd64 -platform=linux_arm64 -platform=darwin_amd64 -platform=darwin_arm64

clean:
	@echo "==> clean ."
	@find . -type d -name .terraform -prune -exec rm -rf {} +
	@find . -mindepth 2 -name .terraform.lock.hcl -not -path '*/.terraform/*' -delete
