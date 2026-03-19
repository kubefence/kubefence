BINARY := 10-nono-nri
CMD := ./cmd/nono-nri

.PHONY: build test test-all clean lint \
        docker-build docker-load-kind \
        kind-up kind-test kind-down kind-e2e

build:
	go build -o $(BINARY) $(CMD)

test:
	go test ./internal/... -v -count=1

test-all:
	go test ./... -v -count=1

clean:
	rm -f $(BINARY)

lint:
	go vet ./...

# ── Docker ────────────────────────────────────────────────────────────────────
IMAGE        ?= nono-nri:latest
KIND_CLUSTER ?= nono-test

docker-build:
	@test -f nono || (echo "ERROR: ./nono binary not found in build context. Download from nono releases and place at repo root." && exit 1)
	docker build -t $(IMAGE) .

docker-load-kind: docker-build
	kind load docker-image $(IMAGE) --name $(KIND_CLUSTER)

# ── Kind e2e ──────────────────────────────────────────────────────────────────
# deploy.sh builds the image internally (via make docker-build), so kind-up
# does not depend on docker-build to avoid a double build.
RUNTIME       ?= containerd
CLUSTER_NAME  ?= nono-$(RUNTIME)
KATA          ?= false
REGISTRY_NAME ?= nono-nri-registry
REGISTRY_PORT ?= 5100

# Create a Kind cluster and deploy the nono-nri plugin.
kind-up:
	RUNTIME=$(RUNTIME) CLUSTER_NAME=$(CLUSTER_NAME) IMAGE=$(IMAGE) KATA=$(KATA) \
		bash deploy/kind/deploy.sh

# Run the e2e test suite against an existing Kind cluster.
kind-test:
	RUNTIME=$(RUNTIME) CLUSTER_NAME=$(CLUSTER_NAME) \
		REGISTRY_NAME=$(REGISTRY_NAME) REGISTRY_PORT=$(REGISTRY_PORT) \
		bash deploy/kind/e2e.sh

# Tear down the Kind cluster. Also removes the local registry for crio clusters.
kind-down:
	kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true
	@[ "$(RUNTIME)" != "crio" ] || docker rm -f $(REGISTRY_NAME) 2>/dev/null || true

# Full CI cycle: deploy → test (capture exit code) → always teardown.
# The cluster is deleted even when tests fail; exits with the test exit code.
kind-e2e: kind-up
	EXIT=0; \
	RUNTIME=$(RUNTIME) CLUSTER_NAME=$(CLUSTER_NAME) \
		REGISTRY_NAME=$(REGISTRY_NAME) REGISTRY_PORT=$(REGISTRY_PORT) \
		bash deploy/kind/e2e.sh || EXIT=$$?; \
	kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true; \
	[ "$(RUNTIME)" != "crio" ] || docker rm -f $(REGISTRY_NAME) 2>/dev/null || true; \
	exit $$EXIT
