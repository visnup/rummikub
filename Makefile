app := DerivedData/Build/Products

files := --device Yam --domain-type appDataContainer --domain-identifier com.visnup.Rummikub

.PHONY: all sim test captures upload labels train score bootstrap

all:
	xcodebuild -scheme Rummikub -destination generic/platform=iOS -derivedDataPath DerivedData \
	  -allowProvisioningUpdates -quiet
	xcrun devicectl device install app --device Yam "$(app)/Debug-iphoneos/Rummikub.app"
	xcrun devicectl device process launch --device Yam com.visnup.Rummikub

sim:
	xcodebuild -scheme Rummikub -destination 'name=iPhone 18 Pro' -derivedDataPath DerivedData -quiet

test:
	cd RummikubKit && swift test

dir := Captures

# Copies the phone's captures not yet in $(dir). Copying Documents whole copies nothing.
captures:
	mkdir -p $(dir)
	xcrun devicectl device info files $(files) --json-output $(dir)/.files.json > /dev/null
	jq -r '.result.files[].relativePath | select(startswith("Documents/"))' $(dir)/.files.json | while read f; do \
	  [ -e "$(dir)/$${f#Documents/}" ] || [ -e "$(dir)/unlabeled/$${f#Documents/}" ] || \
	    grep -qxF "$${f#Documents/}" $(dir)/.removed 2>/dev/null || \
	    xcrun devicectl device copy from $(files) --source "$$f" --destination "$(dir)/$${f#Documents/}" > /dev/null; \
	done

# Labels what the reader agrees with and boxes what OWLv2 finds, then serves the page for the rest at
# http://localhost:8765.
labels:
	cd RummikubKit && swift run -c release label ../$(dir)
	uv run Labeler/prelabel.py
	uv run Labeler/server.py

# Trains the tile finder on captures whose boxes are done, gives the app the model, and scores it.
train:
	cd RummikubKit && swift run -c release train ../$(dir)
	cp $(dir)/Tiles.mlmodel Rummikub/
	$(MAKE) score

# Scores the finder and the reader on the held-out captures, a fifth of the done ones, which training never sees.
score:
	cd RummikubKit && swift run -c release score ../$(dir)

# The same, with christophrus/rummikub's 828 boxed photos too, for while ours are few. GPL-3.0, so its model stays
# in Bootstrap/ and only pre-labels.
bootstrap:
	[ -e Bootstrap/annotations.json ] || uv run Labeler/bootstrap.py
	cd RummikubKit && swift run -c release train ../$(dir) ../Bootstrap

# Look through new captures for personal text on screens first: the dataset is meant to go public.
upload:
	uvx --from huggingface_hub hf upload visnup/rummikub-captures $(dir) . --repo-type dataset --exclude .files.json \
	  --exclude .removed --exclude .DS_Store
