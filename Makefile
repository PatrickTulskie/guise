# make            build bin/guise for this machine
# make install    build and copy it to ~/.local/bin (BINDIR to put it elsewhere)
# make test       the suite, against a fresh build
# make dist       one archive per platform, what a release ships

BINDIR  ?= $(HOME)/.local/bin
VERSION := $(shell sed -n 's/^const version = "\(.*\)"$$/\1/p' cmd/guise/main.go)
GOFLAGS := -trimpath
LDFLAGS := -s -w

PLATFORMS := darwin/amd64 darwin/arm64 linux/amd64 linux/arm64 windows/amd64 windows/arm64

.PHONY: build install test vet dist clean

build:
	go build $(GOFLAGS) -ldflags '$(LDFLAGS)' -o bin/guise ./cmd/guise

install: build
	install -d "$(BINDIR)"
	install -m 755 bin/guise "$(BINDIR)/guise"
	@echo "installed $(BINDIR)/guise"
	@if [ -f "$(HOME)/.config/guise/config" ]; then \
	  echo "run 'guise update' so the installed helpers and hooks come from this copy"; \
	fi

test:
	bash tests/run.sh

vet:
	test -z "$$(gofmt -l cmd/)"
	go vet ./...

# One archive per platform holding the binary alone, plus a checksum file.
dist: clean
	@for p in $(PLATFORMS); do \
	  os=$${p%/*}; arch=$${p#*/}; stage=dist/$$os-$$arch; \
	  mkdir -p $$stage; \
	  echo "building guise for $$os/$$arch"; \
	  if [ "$$os" = windows ]; then \
	    CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch go build $(GOFLAGS) -ldflags '$(LDFLAGS)' -o $$stage/guise.exe ./cmd/guise || exit 1; \
	    (cd $$stage && zip -q ../guise-$(VERSION)-$$os-$$arch.zip guise.exe); \
	  else \
	    CGO_ENABLED=0 GOOS=$$os GOARCH=$$arch go build $(GOFLAGS) -ldflags '$(LDFLAGS)' -o $$stage/guise ./cmd/guise || exit 1; \
	    tar -czf dist/guise-$(VERSION)-$$os-$$arch.tar.gz -C $$stage guise; \
	  fi; \
	  rm -rf $$stage; \
	done
	@cd dist && (sha256sum * 2>/dev/null || shasum -a 256 *) > checksums.txt
	@ls dist

clean:
	rm -rf bin dist
