app := DerivedData/Build/Products

files := --device Yam --domain-type appDataContainer --domain-identifier com.visnup.Rummikub

.PHONY: all sim test captures watch timing upload labels train score

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
	jq -r '.result.files[].relativePath | select(startswith("Documents/") and (startswith("Documents/timing") | not))' \
	  $(dir)/.files.json | while read f; do \
	  [ -e "$(dir)/$${f#Documents/}" ] || [ -e "$(dir)/unlabeled/$${f#Documents/}" ] || \
	    grep -qxF "$${f#Documents/}" $(dir)/.removed 2>/dev/null || \
	    xcrun devicectl device copy from $(files) --source "$$f" --destination "$(dir)/$${f#Documents/}" > /dev/null; \
	done
	# New captures whose truth is what was read go to unlabeled/ until it's written.
	for j in $(dir)/*.json; do b=$${j%.json}; [ -e "$$b.tiles.json" ] || [ "$$(jq -r .layout "$$j" 2>/dev/null)" != "As read" ] || \
	  grep -qxF "$${b#$(dir)/}" $(dir)/boxed.txt || mv "$$b".* $(dir)/unlabeled/; done

# Pre-labels new captures and flags readable text in them every half minute, while capturing. The app pushes
# captures to the labeler (`make labels`), so run both.
watch:
	cd RummikubKit && swift build -c release --product words
	while true; do uv run Labeler/prelabel.py --new 2>&1 | grep -v "Loading\|NOTE\|^\s*$$"; \
	  RummikubKit/.build/release/words $(dir); sleep 30; done

# Copies the app's per-frame timing logs, one a launch, every time, since they grow, then sums them up.
timing:
	mkdir -p Timing
	xcrun devicectl device info files $(files) --json-output Timing/.files.json > /dev/null
	jq -r '.result.files[].relativePath | select(startswith("Documents/timing/") and endswith(".csv"))' Timing/.files.json | \
	  while read f; do xcrun devicectl device copy from $(files) --source "$$f" --destination "Timing/$${f##*/}" > /dev/null; done
	tail -qn +2 Timing/*.csv | awk -F, '{ r += $$3; f += $$4; n++; if ($$3 > rm) rm = $$3; if ($$4 > fm) fm = $$4 } \
	  END { printf "%d frames: read %.0f ms (max %d), find %.0f ms (max %d)\n", n, r / n, rm, f / n, fm }'

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

# Look through the captures in review.txt for personal text first, which `make watch` lists: the dataset is meant to
# go public.
upload:
	uvx --from huggingface_hub hf upload visnup/rummikub-captures $(dir) . --repo-type dataset --exclude .files.json \
	  --exclude .removed --exclude .DS_Store --exclude .probe.pt --exclude .words.txt --exclude review.txt
