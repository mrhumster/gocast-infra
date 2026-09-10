IMAGE_NAME := xomrkob/db-migrate
VERSION ?= $(shell git describe --tags --always || echo "dev")
BUILD_DATE := $(shell date -u +"%Y-%m-%dT%H:%M:%SZ")

.PHONY: all build push test clean

all: build push

build:
	@echo "Building docker image $(IMAGE_NAME):$(VERSION)..."
	docker build \
		--build-arg VERSION=$(VERSION) \
		--build-arg BUILD_DATE=$(BUILD_DATE) \
		-t $(IMAGE_NAME):$(VERSION) \
		-t $(IMAGE_NAME):latest .

push:
	@echo "Pushing image $(IMAGE_NAME):$(VERSION)..."
	docker push $(IMAGE_NAME):$(VERSION)
	docker push $(IMAGE_NAME):latest

test:
	go test ./...

clean:
	rm -f db-migrate