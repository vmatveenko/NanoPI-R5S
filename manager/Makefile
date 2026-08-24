GO ?= go

.PHONY: test build build-linux clean

test:
	$(GO) test ./...

build:
	$(GO) build ./cmd/nanopi-manager-web ./cmd/nanopi-manager-agent

build-linux:
	mkdir -p dist/linux-arm64 dist/linux-amd64
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 $(GO) build -trimpath -ldflags='-s -w' -o dist/linux-arm64/nanopi-manager-web ./cmd/nanopi-manager-web
	CGO_ENABLED=0 GOOS=linux GOARCH=arm64 $(GO) build -trimpath -ldflags='-s -w' -o dist/linux-arm64/nanopi-manager-agent ./cmd/nanopi-manager-agent
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 $(GO) build -trimpath -ldflags='-s -w' -o dist/linux-amd64/nanopi-manager-web ./cmd/nanopi-manager-web
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 $(GO) build -trimpath -ldflags='-s -w' -o dist/linux-amd64/nanopi-manager-agent ./cmd/nanopi-manager-agent

clean:
	rm -rf dist

