SHELL:=/bin/bash
REQUIRED_BINARIES := ytt jq yq hauler helm
WORKING_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
SCRIPT_DIR := ${WORKING_DIR}/scripts

# stack config and reference
CONFIG_FILE := ${WORKING_DIR}/config.yaml
RANCHER_VERSION := $(shell yq '.rancher_version' ${CONFIG_FILE})
CERT_MANAGER_VERSION := $(shell yq '.cert_manager_version' ${CONFIG_FILE})
HARBOR_CHART_VERSION := $(shell yq '.harbor.chart_version' ${CONFIG_FILE})
HARBOR_URL := $(shell yq '.harbor.core_url' ${CONFIG_FILE})
NOTARY_URL := $(shell yq '.harbor.notary_url' ${CONFIG_FILE})
HARBOR_ARCHIVE := $(shell yq e '.harbor.archive_path' ${CONFIG_FILE})
HAULER_ARCHIVE := $(shell yq e '.hauler.archive_path' ${CONFIG_FILE})
AFFINITY_NODE_NAME := $(shell yq e '.harbor.affinity_node' ${CONFIG_FILE})

check-tools: ## Check to make sure you have the right tools
	$(foreach exec,$(REQUIRED_BINARIES),\
		$(if $(shell which $(exec)),,$(error "'$(exec)' not found. It is a dependency for this Makefile")))

install:
	$(call colorecho, "===>Installing Hauler and Dependencies", 5)
	@sudo ${SCRIPT_DIR}/install.sh HAULER_VERSION=0.4.1
	@wget https://github.com/mikefarah/yq/releases/download/v4.30.1/yq_linux_amd64 \
		sudo install yq_linux_amd64 /usr/local/bin/yq; rm yq_linux_amd64
	@wget -O- https://carvel.dev/install.sh > install.sh \
		sudo bash install.sh; rm install.sh

package-rancher: check-tools
	$(call colorecho, "===>Pulling all Dependent Images via Hauler", 5)
	@curl -sL https://github.com/rancher/rancher/releases/download/$(RANCHER_VERSION)/rancher-images.txt > ${WORKING_DIR}/images.txt
	@for line in $$(cat ${WORKING_DIR}/filter.list); do \
		sed -ie "\|$$line|d" ${WORKING_DIR}/images.txt; \
	done
	@mv ${WORKING_DIR}/images.txt ${WORKING_DIR}/filtered_images.txt
	@rm ${WORKING_DIR}/images.txte || true

	@helm repo add jetstack https://charts.jetstack.io &> /dev/null && helm repo update &> /dev/null
	@helm template jetstack/cert-manager --version=$(CERT_MANAGER_VERSION) | grep 'image:' | sed 's/"//g'  | awk '{ print $$2 }' >> ${WORKING_DIR}/filtered_images.txt

	@echo -e "#@data/values\n---\n" > ${WORKING_DIR}/charts_values.yaml
	@yq '.phony.charts = .additional_charts | .phony' ${CONFIG_FILE} >> ${WORKING_DIR}/charts_values.yaml
	@ytt -f ${WORKING_DIR}/templates/chart_manifest_template.yaml -v cert_manager_version=$(CERT_MANAGER_VERSION) -v rancher_version=$(RANCHER_VERSION) -f ${WORKING_DIR}/charts_values.yaml > charts.yaml
	@echo -e "---" > ${WORKING_DIR}/manifest.yaml
	@cat images.yaml >> ${WORKING_DIR}/manifest.yaml
	@echo -e "---" >> ${WORKING_DIR}/manifest.yaml
	@cat charts.yaml >> ${WORKING_DIR}/manifest.yaml

	@hauler store sync -f ${WORKING_DIR}/manifest.yaml
	@rm ${WORKING_DIR}/images.yaml ${WORKING_DIR}/charts.yaml ${WORKING_DIR}/charts_values.yaml ${WORKING_DIR}/filtered_images.txt ${WORKING_DIR}/manifest.yaml || true

	@hauler store save -f $(shell yq e '.hauler.archive_path' ${CONFIG_FILE})

package-harbor: check-tools
	$(call colorecho, "===>Packaging Harbor", 5)
	@helm template ${WORKING_DIR}/harbor/harbor-$(HARBOR_CHART_VERSION).tgz | grep 'image:' | sed 's/"//g' | tr -d ' ' | sed 's/image://g' | awk '{ print $2 }' > ${WORKING_DIR}/images.txt
	@ytt -f ${WORKING_DIR}/templates/image_manifest_template.yaml -v image_list="$$(cat ${WORKING_DIR}/images.txt)" > ${WORKING_DIR}/images.yaml
	@rm ${WORKING_DIR}/images.txt

	@hauler store sync -s $(shell yq e '.harbor.store_path' $(CONFIG_FILE)) -f ${WORKING_DIR}/images.yaml
	@hauler store add chart -s $(shell yq e '.harbor.store_path' $(CONFIG_FILE)) ${WORKING_DIR}/harbor/harbor-${HARBOR_CHART_VERSION}.tgz
	@hauler store save -s $(shell yq e '.harbor.store_path' $(CONFIG_FILE)) -f ${HARBOR_ARCHIVE}
	@rm ${WORKING_DIR}/images.yaml

install-harbor: check-tools
	$(call colorecho, "===>Installing Harbor into your Airgap", 5)
	$(call colorecho, "=>Creating Affinity Label on your node", 5)
	@kubectl label node $(AFFINITY_NODE_NAME) harbor-cache=true || true

	@hauler store load -s $(shell yq e '.harbor.store_path' ${CONFIG_FILE}) ${HARBOR_ARCHIVE}
	@hauler store serve -s $(shell yq e '.harbor.store_path' ${CONFIG_FILE}) &
	@sleep 10
	@sed 's/goharbor/$(shell yq e '.hauler.host' ${CONFIG_FILE}):5000\/goharbor/g' ${WORKING_DIR}/harbor/values.yaml | \
	yq '.externalURL = "https://$(HARBOR_URL)"' | yq '.expose.ingress.hosts.core = "$(HARBOR_URL)"' | yq '.expose.ingress.hosts.notary = "$(HARBOR_URL)"' | \
	helm upgrade --install harbor oci://localhost:5000/hauler/harbor --version $(HARBOR_CHART_VERSION) -n harbor --values - --create-namespace --wait
	@pkill hauler
	@rm -rf ${WORKING_DIR}/registry $(shell yq e '.harbor.store_path' ${CONFIG_FILE})

push-rancher: check-tools
	$(call colorecho, "===>Installing Rancher Images into your Airgap", 5)
	$(call colorecho, "=>Creating Harbor Projects", 3)
	@jq '.project_name = "rancher"' ${WORKING_DIR}/harbor/project_template.json | curl -sk -o /tmp/result -u "admin:Harbor12345" -H 'accept: application/json' -H 'Content-Type: application/json' --data-binary @- -X POST https://$(HARBOR_URL)/api/v2.0/projects
	@jq '.project_name = "jetstack"' ${WORKING_DIR}/harbor/project_template.json | curl -sk -o /tmp/result -u "admin:Harbor12345" -H 'accept: application/json' -H 'Content-Type: application/json' --data-binary @- -X POST https://$(HARBOR_URL)/api/v2.0/projects
	@jq '.project_name = "hauler"' ${WORKING_DIR}/harbor/project_template.json | curl -sk -o /tmp/result -u "admin:Harbor12345" -H 'accept: application/json' -H 'Content-Type: application/json' --data-binary @- -X POST https://$(HARBOR_URL)/api/v2.0/projects

	$(call colorecho, "=>Pushing Images to Harbor", 3)
	@hauler store load -s $(shell yq e '.hauler.store_path' ${CONFIG_FILE}) ${HAULER_ARCHIVE}
	@hauler store copy -u admin -p Harbor12345 --insecure -s $(shell yq e '.hauler.store_path' ${CONFIG_FILE}) registry://${HARBOR_URL}

define colorecho
@tput setaf $2
@echo $1
@tput sgr0
endef
define randompassword
${shell head /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 13}
endef