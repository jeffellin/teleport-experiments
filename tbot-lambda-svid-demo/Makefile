# Builds two zips consumed by Terraform:
#   build/tbot-layer.zip  -> Lambda layer (extensions/tbot-extension + bin/tbot)
#   build/function.zip    -> Lambda function (bootstrap)
#
#   make                      # arm64, TELEPORT_VERSION below
#   make ARCH=amd64           # x86_64 Lambda (also set lambda_architecture in tfvars)
#   make TELEPORT_VERSION=18.11.2

TELEPORT_VERSION ?= 18.11.2
ARCH             ?= arm64
BUILD            := build
GOFLAGS          := CGO_ENABLED=0 GOOS=linux GOARCH=$(ARCH)
LDFLAGS          := -s -w

.PHONY: all layer function tbot clean tidy

all: layer function

tidy:
	go mod tidy

$(BUILD)/tbot-$(TELEPORT_VERSION)-$(ARCH):
	@mkdir -p $(BUILD)/dl
	curl -fsSL -o $(BUILD)/dl/teleport.tgz \
	  https://cdn.teleport.dev/teleport-v$(TELEPORT_VERSION)-linux-$(ARCH)-bin.tar.gz
	tar -xzf $(BUILD)/dl/teleport.tgz -C $(BUILD)/dl teleport/tbot
	mv $(BUILD)/dl/teleport/tbot $@
	rm -rf $(BUILD)/dl

tbot: $(BUILD)/tbot-$(TELEPORT_VERSION)-$(ARCH)

layer: tbot
	rm -rf $(BUILD)/layer && mkdir -p $(BUILD)/layer/extensions $(BUILD)/layer/bin
	$(GOFLAGS) go build -trimpath -ldflags '$(LDFLAGS)' -o $(BUILD)/layer/extensions/tbot-extension ./cmd/tbot-extension
	cp $(BUILD)/tbot-$(TELEPORT_VERSION)-$(ARCH) $(BUILD)/layer/bin/tbot
	chmod 0755 $(BUILD)/layer/extensions/tbot-extension $(BUILD)/layer/bin/tbot
	cd $(BUILD)/layer && rm -f ../tbot-layer.zip && zip -qr9 ../tbot-layer.zip .
	@ls -lh $(BUILD)/tbot-layer.zip

function:
	rm -rf $(BUILD)/function && mkdir -p $(BUILD)/function
	$(GOFLAGS) go build -tags lambda.norpc -trimpath -ldflags '$(LDFLAGS)' -o $(BUILD)/function/bootstrap ./cmd/handler
	cd $(BUILD)/function && rm -f ../function.zip && zip -qr9 ../function.zip bootstrap
	@ls -lh $(BUILD)/function.zip

clean:
	rm -rf $(BUILD)
