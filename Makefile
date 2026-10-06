VERSION ?= 0.1.0
APP     := build/Sonora.app
export MACOSX_DEPLOYMENT_TARGET := 14.2
export CGO_CFLAGS  := -O2 -mmacosx-version-min=14.2
export CGO_LDFLAGS := -mmacosx-version-min=14.2
LDFLAGS := -s -w -X main.version=$(VERSION)

.PHONY: app run install test universal zip clean

# Builds build/Sonora.app for this Mac's architecture.
app:
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	go build -ldflags "$(LDFLAGS)" -o $(APP)/Contents/MacOS/Sonora .
	sed 's/VERSION/$(VERSION)/g' Info.plist > $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

test:
	go vet ./...
	go test ./...

run: app
	open $(APP)

install: app
	-pkill -x Sonora
	rm -rf /Applications/Sonora.app
	cp -R $(APP) /Applications/
	open /Applications/Sonora.app

# Builds a single app that runs on both Apple Silicon and Intel Macs.
universal:
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	GOARCH=arm64 CGO_ENABLED=1 go build -ldflags "$(LDFLAGS)" -o build/Sonora-arm64 .
	GOARCH=amd64 CGO_ENABLED=1 CGO_CFLAGS="$(CGO_CFLAGS) -arch x86_64" CGO_LDFLAGS="$(CGO_LDFLAGS) -arch x86_64" \
		go build -ldflags "$(LDFLAGS)" -o build/Sonora-amd64 .
	lipo -create -output $(APP)/Contents/MacOS/Sonora build/Sonora-arm64 build/Sonora-amd64
	sed 's/VERSION/$(VERSION)/g' Info.plist > $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

zip: universal
	cd build && ditto -c -k --keepParent Sonora.app Sonora-$(VERSION).zip

clean:
	rm -rf build
