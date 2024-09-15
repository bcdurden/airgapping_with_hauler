SHELL:=/bin/bash
REQUIRED_BINARIES := ytt jq yq hauler helm
WORKING_DIR := $(shell dirname $(realpath $(firstword $(MAKEFILE_LIST))))
SCRIPT_DIR := ${WORKING_DIR}/scripts

# stack config and reference
CONFIG_FILE := ${WORKING_DIR}/config.yaml
RANCHER_VERSION := $(shell yq '.rancher_version' ${CONFIG_FILE})
CARBIDE_VERSION := $(shell yq e '.carbide.version' ${CONFIG_FILE})
HARVESTER_VERSION := $(shell yq e '.harvester.version' ${CONFIG_FILE})
CERT_MANAGER_VERSION := $(shell yq '.cert_manager_version' ${CONFIG_FILE})
HARBOR_CHART_VERSION := $(shell yq '.bootstrap.harbor_chart_version' ${CONFIG_FILE})
HARBOR_URL := $(shell yq '.harbor.core_url' ${CONFIG_FILE})
NOTARY_URL := $(shell yq '.harbor.notary_url' ${CONFIG_FILE})
BOOTSTRAP_ARCHIVE := $(shell yq e '.bootstrap.archive_path' ${CONFIG_FILE})
HAULER_ARCHIVE := $(shell yq e '.hauler.archive_path' ${CONFIG_FILE})
AFFINITY_NODE_NAME := $(shell yq e '.harbor.affinity_node' ${CONFIG_FILE})

# Carbide variables
CARBIDE_CREDENTIALS = $$HOME/carbide_token.yaml
CARBIDE_USERNAME := $(shell yq .token_id ${CARBIDE_CREDENTIALS})
CARBIDE_PASSWORD := $(shell yq .token_password ${CARBIDE_CREDENTIALS})

check-tools: ## Check to make sure you have the right tools
	$(foreach exec,$(REQUIRED_BINARIES),\
		$(if $(shell which $(exec)),,$(error "'$(exec)' not found. It is a dependency for this Makefile")))

install:
	$(call colorecho, "===>Installing Hauler and Dependencies", 5)
	@curl -sfL https://get.hauler.dev | bash
# Need a Darwin check here
	@wget https://github.com/mikefarah/yq/releases/download/v4.30.1/yq_linux_amd64 \
		sudo install yq_linux_amd64 /usr/local/bin/yq; rm yq_linux_amd64
	@wget -O- https://carvel.dev/install.sh > install.sh \
		sudo bash install.sh; rm install.sh

all:
	$(MAKE) package-bootstrap
	$(MAKE) package-rancher

package-rancher: check-tools
	$(call colorecho, "===>Pulling all Dependent Images via Hauler", 5)
	@hauler login -u $(CARBIDE_USERNAME) -p $(CARBIDE_PASSWORD) rgcrprod.azurecr.us
	@hauler store add image rgcrprod.azurecr.us/hauler/rancher-manifest.yaml:$(RANCHER_VERSION)
	@hauler store extract hauler/rancher-manifest.yaml:$(RANCHER_VERSION)
	@rm -rf store/

	@for line in $$(cat ${WORKING_DIR}/filter.list); do \
		sed -ie "\|$$line|d" ${WORKING_DIR}/rancher-manifest.yaml; \
	done
	@rm rancher-manifest.yamle
	
	@hauler store sync --platform linux/amd64 -f ${WORKING_DIR}/rancher-manifest.yaml && rm ${WORKING_DIR}/rancher-manifest.yaml
	@hauler store save -f ${WORKING_DIR}/rancher.tar.zst

package-bootstrap: check-tools
	$(call colorecho, "===>Grabbing Harvester Images", 5)
	@hauler store add file -s $(shell yq '.bootstrap.store_path' $(CONFIG_FILE)) https://releases.rancher.com/harvester/$(HARVESTER_VERSION)/harvester-$(HARVESTER_VERSION)-vmlinuz-amd64
	@hauler store add file -s $(shell yq '.bootstrap.store_path' $(CONFIG_FILE)) https://releases.rancher.com/harvester/$(HARVESTER_VERSION)/harvester-$(HARVESTER_VERSION)-initrd-amd64
	@hauler store add file -s $(shell yq '.bootstrap.store_path' $(CONFIG_FILE)) https://releases.rancher.com/harvester/$(HARVESTER_VERSION)/harvester-$(HARVESTER_VERSION)-rootfs-amd64.squashfs
	@hauler store add file -s $(shell yq '.bootstrap.store_path' $(CONFIG_FILE)) https://releases.rancher.com/harvester/$(HARVESTER_VERSION)/harvester-$(HARVESTER_VERSION)-amd64.iso

	$(call colorecho, "===>Grabbing CertManager Images", 5)
	@hauler store add chart -s $(shell yq e '.bootstrap.store_path' $(CONFIG_FILE)) cert-manager --repo https://charts.jetstack.io --version=$(CERT_MANAGER_VERSION)
	@hauler store extract -s $(shell yq e '.bootstrap.store_path' $(CONFIG_FILE)) hauler/cert-manager:$(CERT_MANAGER_VERSION) -o /tmp
	@helm template /tmp/cert-manager-$(CERT_MANAGER_VERSION).tgz  | grep 'image:' | sed -e 's/^[ \t]*//' | sed 's/"//g' | sed "s/'//g" | sort --unique | awk '{ print $$2 }' > ${WORKING_DIR}/cert_images.txt;
	@ytt -f ${WORKING_DIR}/templates/image_manifest_template.yaml -v image_list="$$(cat ${WORKING_DIR}/cert_images.txt)" > ${WORKING_DIR}/cert_images.yaml
	@hauler store sync -s $(shell yq e '.bootstrap.store_path' $(CONFIG_FILE)) --platform linux/amd64 -f ${WORKING_DIR}/cert_images.yaml
	@rm ${WORKING_DIR}/cert_images.yaml ${WORKING_DIR}/cert_images.txt || true

	$(call colorecho, "===>Pulling RKE2 via Hauler", 5)
	@hauler store add file -s $(shell yq e '.bootstrap.store_path' $(CONFIG_FILE)) https://github.com/rancher/rke2/releases/download/v1.28.12-rc3-rke2r1/rke2.linux-amd64.tar.gz
	@hauler store add file -s $(shell yq e '.bootstrap.store_path' $(CONFIG_FILE)) https://get.rke2.io

	$(call colorecho, "===>Packaging Harbor", 5)
	@helm pull harbor --repo https://helm.goharbor.io
	@hauler store add chart -s $(shell yq e '.bootstrap.store_path' $(CONFIG_FILE)) ${WORKING_DIR}/harbor-$(HARBOR_CHART_VERSION).tgz
	@helm template ${WORKING_DIR}/harbor-$(HARBOR_CHART_VERSION).tgz | grep 'image:' | sed -e 's/^[ \t]*//' | sed 's/"//g' | sed "s/'//g" | sort --unique | awk '{ print $$2 }' > ${WORKING_DIR}/images.txt;
	@ytt -f ${WORKING_DIR}/templates/image_manifest_template.yaml -v image_list="$$(cat ${WORKING_DIR}/images.txt)" > ${WORKING_DIR}/images.yaml
	@hauler store sync -s $(shell yq e '.bootstrap.store_path' $(CONFIG_FILE)) --platform linux/amd64 -f ${WORKING_DIR}/images.yaml

	@hauler store save -s $(shell yq e '.bootstrap.store_path' $(CONFIG_FILE)) -f ${BOOTSTRAP_ARCHIVE}
	@rm ${WORKING_DIR}/harbor-$(HARBOR_CHART_VERSION).tgz
	@rm ${WORKING_DIR}/images.txt
	@rm ${WORKING_DIR}/images.yaml

install-harbor: check-tools
	$(call colorecho, "===>Installing Harbor into your Airgap", 5)
	$(call colorecho, "=>Creating Affinity Label on your node", 5)
	@kubectl label node $(AFFINITY_NODE_NAME) harbor-cache=true || true

	@hauler store load -s $(shell yq e '.bootstrap.store_path' ${CONFIG_FILE}) ${BOOTSTRAP_ARCHIVE}
	@hauler store serve -s $(shell yq e '.bootstrap.store_path' ${CONFIG_FILE}) &
	@sleep 10
	@sed 's/goharbor/$(shell yq e '.hauler.host' ${CONFIG_FILE}):5000\/goharbor/g' ${WORKING_DIR}/harbor/values.yaml | \
	yq '.externalURL = "https://$(HARBOR_URL)"' | yq '.expose.ingress.hosts.core = "$(HARBOR_URL)"' | yq '.expose.ingress.hosts.notary = "$(HARBOR_URL)"' | \
	helm upgrade --install harbor oci://localhost:5000/hauler/harbor --version $(HARBOR_CHART_VERSION) -n harbor --values - --create-namespace --wait
	@pkill hauler
	@rm -rf ${WORKING_DIR}/registry $(shell yq e '.bootstrap.store_path' ${CONFIG_FILE})

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
