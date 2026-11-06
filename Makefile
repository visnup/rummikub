app := DerivedData/Build/Products

files := --device Yam --domain-type appDataContainer --domain-identifier com.visnup.Rummikub

.PHONY: all sim test captures

all:
	xcodebuild -scheme Rummikub -destination generic/platform=iOS -derivedDataPath DerivedData \
	  -allowProvisioningUpdates -quiet
	xcrun devicectl device install app --device Yam "$(app)/Debug-iphoneos/Rummikub.app"
	xcrun devicectl device process launch --device Yam com.visnup.Rummikub

sim:
	xcodebuild -scheme Rummikub -destination 'name=iPhone 18 Pro' -derivedDataPath DerivedData -quiet

test:
	cd RummikubKit && swift test

# Copies the phone's captures not yet in Captures/. Copying Documents whole copies nothing.
captures:
	mkdir -p Captures
	xcrun devicectl device info files $(files) --json-output Captures/.files.json > /dev/null
	jq -r '.result.files[].relativePath | select(startswith("Documents/"))' Captures/.files.json | while read f; do \
	  [ -e "Captures/$${f#Documents/}" ] || \
	    xcrun devicectl device copy from $(files) --source "$$f" --destination "Captures/$${f#Documents/}" > /dev/null; \
	done
