SHELL:=/bin/bash
REQUIRED_BINARIES := ytt yq hauler helm
WORKING_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
SCRIPT_DIR := ${WORKING_DIR}/scripts

# stack config and reference
CONFIG_FILE := ${WORKING_DIR}/config.yaml
RANCHER_VERSION := $(shell yq '.rancher_version' ${CONFIG_FILE})
CERT_MANAGER_VERSION := $(shell yq '.cert_manager_version' ${CONFIG_FILE})

check-tools: ## Check to make sure you have the right tools
	$(foreach exec,$(REQUIRED_BINARIES),\
		$(if $(shell which $(exec)),,$(error "'$(exec)' not found. It is a dependency for this Makefile")))

install:
	$(call colorecho, "===>Installing Hauler and Dependencies", 5)
	@sudo ${SCRIPT_DIR}/install.sh HAULER_VERSION=0.4.1-rc.2
	@wget https://github.com/mikefarah/yq/releases/download/v4.30.1/yq_linux_amd64 \
		sudo install yq_linux_amd64 /usr/local/bin/yq; rm yq_linux_amd64
	@wget -O- https://carvel.dev/install.sh > install.sh \
		sudo bash install.sh; rm install.sh

pull: check-tools
	$(call colorecho, "===>Pulling all Dependent Images via Hauler", 5)
	@curl -sL https://github.com/rancher/rancher/releases/download/$(RANCHER_VERSION)/rancher-images.txt > ${WORKING_DIR}/images.txt
	@for line in $$(cat ${WORKING_DIR}/filter.list); do \
		sed -ie "\|$$line|d" ${WORKING_DIR}/images.txt; \
	done
	@mv ${WORKING_DIR}/images.txt ${WORKING_DIR}/filtered_images.txt
	@rm ${WORKING_DIR}/images.txte || true

	@helm repo add jetstack https://charts.jetstack.io &> /dev/null && helm repo update &> /dev/null
	@helm template jetstack/cert-manager --version=$(CERT_MANAGER_VERSION) | grep 'image:' | sed 's/"//g' | awk '{ print $$2 }' >> ${WORKING_DIR}/filtered_images.txt

	@ytt -f ${WORKING_DIR}/templates/image_manifest_template.yaml -v image_list="$$(cat ${WORKING_DIR}/filtered_images.txt)" > ${WORKING_DIR}/images.yaml

	@echo -e "#@data/values\n---\n" > ${WORKING_DIR}/charts_values.yaml
	@yq '.phony.charts = .additional_charts | .phony' ${CONFIG_FILE} >> ${WORKING_DIR}/charts_values.yaml
	@ytt -f ${WORKING_DIR}/templates/chart_manifest_template.yaml -v cert_manager_version=$(CERT_MANAGER_VERSION) -v rancher_version=$(RANCHER_VERSION) -f ${WORKING_DIR}/charts_values.yaml > charts.yaml
	@echo -e "---" > ${WORKING_DIR}/manifest.yaml
	@cat images.yaml >> ${WORKING_DIR}/manifest.yaml
	@echo -e "---" >> ${WORKING_DIR}/manifest.yaml
	@cat charts.yaml >> ${WORKING_DIR}/manifest.yaml

	@hauler store sync -f ${WORKING_DIR}/manifest.yaml
	@rm ${WORKING_DIR}/images.yaml ${WORKING_DIR}/charts.yaml ${WORKING_DIR}/charts_values.yaml ${WORKING_DIR}/filtered_images.txt ${WORKING_DIR}/manifest.yaml || true

	@hauler store save -f $(shell yq e '.hauler_store_path' ${CONFIG_FILE})/hauler-images-$(RANCHER_VERSION).tar.zst

define colorecho
@tput setaf $2
@echo $1
@tput sgr0
endef
define randompassword
${shell head /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 13}
endef