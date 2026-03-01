SHELL := /bin/bash

-include device-config.mk

CONFIGURATION ?= Debug
DERIVED_DATA ?= .build/DerivedData
LOG_ROOT ?= logs
WORKSPACE_PATH ?= keyd.xcworkspace
SCRIPT := ./scripts/deploy-and-run.sh
IOS_LABELS ?=

DEVICE_SELECTORS := $(filter ipad iphone ios mac,$(wordlist 2,$(words $(MAKECMDGOALS)),$(MAKECMDGOALS)))

.PHONY: deploy run attach stop index test-integration ipad iphone ios mac

deploy: test-integration
	@WORKSPACE_PATH="$(WORKSPACE_PATH)" \
	DERIVED_DATA="$(DERIVED_DATA)" \
	LOG_ROOT="$(LOG_ROOT)" \
	CONFIGURATION="$(CONFIGURATION)" \
	IOS_DEVICES="$(IOS_DEVICES)" \
	IOS_LABELS="$(IOS_LABELS)" \
	IPAD_DEVICE="$(IPAD_DEVICE)" \
	IPHONE_DEVICE="$(IPHONE_DEVICE)" \
	IOS_BUNDLE_ID="$(IOS_BUNDLE_ID)" \
	$(SCRIPT) deploy

run:
	@selectors="$(DEVICE_SELECTORS)"; \
	mode="run"; \
	include_mac=false; \
	include_ios=false; \
	ios_devices=""; \
	ios_labels=""; \
	append_ios() { \
		device="$$1"; \
		label="$$2"; \
		if [[ -z "$$device" ]]; then \
			return; \
		fi; \
		if [[ -z "$$ios_devices" ]]; then \
			ios_devices="$$device"; \
			ios_labels="$$label"; \
		else \
			case ",$$ios_labels," in \
				*,"$$label",*) ;; \
				*) ios_devices="$$ios_devices,$$device"; ios_labels="$$ios_labels,$$label" ;; \
			esac; \
		fi; \
	}; \
	if [[ -z "$$selectors" ]]; then \
		include_mac=true; \
		include_ios=true; \
	else \
		for selector in $$selectors; do \
			case "$$selector" in \
				mac) include_mac=true ;; \
				ios) include_ios=true ;; \
				ipad) append_ios "$(IPAD_DEVICE)" "iPad" ;; \
				iphone) append_ios "$(IPHONE_DEVICE)" "iPhone" ;; \
			esac; \
		done; \
	fi; \
	if [[ "$$include_ios" == true ]]; then \
		append_ios "$(IPAD_DEVICE)" "iPad"; \
		append_ios "$(IPHONE_DEVICE)" "iPhone"; \
	fi; \
	if [[ "$$include_mac" == true && -n "$$ios_devices" ]]; then \
		mode="run"; \
	elif [[ "$$include_mac" == true ]]; then \
		mode="run-mac"; \
	else \
		mode="run-ios"; \
	fi; \
	WORKSPACE_PATH="$(WORKSPACE_PATH)" \
	DERIVED_DATA="$(DERIVED_DATA)" \
	LOG_ROOT="$(LOG_ROOT)" \
	CONFIGURATION="$(CONFIGURATION)" \
	IOS_DEVICES="$$ios_devices" \
	IOS_LABELS="$$ios_labels" \
	IPAD_DEVICE="$(IPAD_DEVICE)" \
	IPHONE_DEVICE="$(IPHONE_DEVICE)" \
	IOS_BUNDLE_ID="$(IOS_BUNDLE_ID)" \
	$(SCRIPT) "$$mode"

attach:
	@selectors="$(DEVICE_SELECTORS)"; \
	mode="attach"; \
	include_mac=false; \
	include_ios=false; \
	ios_devices=""; \
	ios_labels=""; \
	append_ios() { \
		device="$$1"; \
		label="$$2"; \
		if [[ -z "$$device" ]]; then \
			return; \
		fi; \
		if [[ -z "$$ios_devices" ]]; then \
			ios_devices="$$device"; \
			ios_labels="$$label"; \
		else \
			case ",$$ios_labels," in \
				*,"$$label",*) ;; \
				*) ios_devices="$$ios_devices,$$device"; ios_labels="$$ios_labels,$$label" ;; \
			esac; \
		fi; \
	}; \
	if [[ -z "$$selectors" ]]; then \
		include_mac=true; \
		include_ios=true; \
	else \
		for selector in $$selectors; do \
			case "$$selector" in \
				mac) include_mac=true ;; \
				ios) include_ios=true ;; \
				ipad) append_ios "$(IPAD_DEVICE)" "iPad" ;; \
				iphone) append_ios "$(IPHONE_DEVICE)" "iPhone" ;; \
			esac; \
		done; \
	fi; \
	if [[ "$$include_ios" == true ]]; then \
		append_ios "$(IPAD_DEVICE)" "iPad"; \
		append_ios "$(IPHONE_DEVICE)" "iPhone"; \
	fi; \
	if [[ "$$include_mac" == true && -n "$$ios_devices" ]]; then \
		mode="attach"; \
	elif [[ "$$include_mac" == true ]]; then \
		mode="attach-mac"; \
	else \
		mode="attach-ios"; \
	fi; \
	WORKSPACE_PATH="$(WORKSPACE_PATH)" \
	DERIVED_DATA="$(DERIVED_DATA)" \
	LOG_ROOT="$(LOG_ROOT)" \
	CONFIGURATION="$(CONFIGURATION)" \
	IOS_DEVICES="$$ios_devices" \
	IOS_LABELS="$$ios_labels" \
	IPAD_DEVICE="$(IPAD_DEVICE)" \
	IPHONE_DEVICE="$(IPHONE_DEVICE)" \
	IOS_BUNDLE_ID="$(IOS_BUNDLE_ID)" \
	$(SCRIPT) "$$mode"

stop:
	@WORKSPACE_PATH="$(WORKSPACE_PATH)" \
	DERIVED_DATA="$(DERIVED_DATA)" \
	LOG_ROOT="$(LOG_ROOT)" \
	CONFIGURATION="$(CONFIGURATION)" \
	IOS_DEVICES="$(IOS_DEVICES)" \
	IOS_LABELS="$(IOS_LABELS)" \
	IPAD_DEVICE="$(IPAD_DEVICE)" \
	IPHONE_DEVICE="$(IPHONE_DEVICE)" \
	IOS_BUNDLE_ID="$(IOS_BUNDLE_ID)" \
	$(SCRIPT) stop

test-integration:
	@WORKSPACE_PATH="$(WORKSPACE_PATH)" \
	DERIVED_DATA="$(DERIVED_DATA)" \
	LOG_ROOT="$(LOG_ROOT)" \
	CONFIGURATION="$(CONFIGURATION)" \
	IOS_DEVICES="$(IOS_DEVICES)" \
	IOS_LABELS="$(IOS_LABELS)" \
	IPAD_DEVICE="$(IPAD_DEVICE)" \
	IPHONE_DEVICE="$(IPHONE_DEVICE)" \
	IOS_BUNDLE_ID="$(IOS_BUNDLE_ID)" \
	$(SCRIPT) test-integration

index:
	@echo "==> Indexing SharedProtocol (SPM)..."
	cd SharedProtocol && swift build \
		-Xswiftc -index-store-path \
		-Xswiftc "$(CURDIR)/SharedProtocol/.build/index/store"
	@echo "==> Indexing KeydAgent (macOS)..."
	xcodebuild -project macOS/KeydAgent.xcodeproj \
		-scheme KeydAgent \
		-destination "platform=macOS,arch=arm64" \
		-derivedDataPath "$(DERIVED_DATA)" \
		COMPILER_INDEX_STORE_ENABLE=YES \
		INDEX_ENABLE_DATA_STORE=YES \
		build 2>&1 | grep -E "^(error:|warning: |Build (succeeded|FAILED))" || true
	@echo "==> Indexing KeydApp (iOS)..."
	xcodebuild -workspace "$(WORKSPACE_PATH)" \
		-scheme KeydApp \
		-destination "generic/platform=iOS" \
		-derivedDataPath "$(DERIVED_DATA)" \
		COMPILER_INDEX_STORE_ENABLE=YES \
		INDEX_ENABLE_DATA_STORE=YES \
		build 2>&1 | grep -E "^(error:|warning: |Build (succeeded|FAILED))" || true
	@echo "==> Index complete. Store: $(DERIVED_DATA)/Index.noindex/DataStore"

ipad iphone ios mac:
	@:
