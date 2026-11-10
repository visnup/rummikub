app := DerivedData/Build/Products

files := --device Yam --domain-type appDataContainer --domain-identifier com.visnup.Rummikub

.PHONY: all sim test captures watch timing upload labels train finder values looking check score

all:
	xcodebuild -scheme Rummikub -destination generic/platform=iOS -derivedDataPath DerivedData \
	  -allowProvisioningUpdates -quiet
	xcrun devicectl device install app --device Yam "$(app)/Debug-iphoneos/Rummikub.app"

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

# Boxes new captures, fills in what Values reads in each box, checks newly done ones against the models, and flags
# readable text in them every half minute, while capturing. The app pushes captures to the labeler (`make labels`),
# so run both.
watch:
	cd RummikubKit && swift build -c release --product words --product fill --product check
	while true; do uv run Labeler/prelabel.py --new 2>&1 | grep -v "Loading\|NOTE\|^\s*$$"; \
	  RummikubKit/.build/release/fill --new $(dir); \
	  RummikubKit/.build/release/check --new $(dir) > /dev/null; RummikubKit/.build/release/words $(dir); sleep 30; done

# Copies the app's per-frame timing logs, one a launch, every time, since they grow, then sums them up.
timing:
	mkdir -p Timing
	xcrun devicectl device info files $(files) --json-output Timing/.files.json > /dev/null
	jq -r '.result.files[].relativePath | select(startswith("Documents/timing/") and endswith(".csv"))' Timing/.files.json | \
	  while read f; do xcrun devicectl device copy from $(files) --source "$$f" --destination "Timing/$${f##*/}" > /dev/null; done
	tail -qn +2 Timing/*.csv | awk -F, '{ r += $$3; f += $$4; n++; if ($$3 > rm) rm = $$3; if ($$4 > fm) fm = $$4 } \
	  END { printf "%d frames: read %.0f ms (max %d), find %.0f ms (max %d)\n", n, r / n, rm, f / n, fm }'

# Boxes what the finder finds and fills in what Values reads, then serves the pages to check them at
# http://localhost:8765.
labels:
	uv run Labeler/prelabel.py
	cd RummikubKit && swift run -c release fill ../$(dir)
	uv run Labeler/server.py

# Trains the finder and Values side by side, then scores and checks them: a little over an hour, nearly all the
# finder's.
# After labeling values alone, `make values score` takes about 8 minutes.
train:
	$(MAKE) -j2 finder values
	$(MAKE) score check

# Trains the tile finder on captures whose boxes are done and the outside sets for MINUTES (60), and gives the app it.
finder:
	uv run Labeler/finder.py $(dir) $(wildcard Outside/*-train)
	rm -rf Rummikub/Tiles.mlpackage && cp -R $(dir)/Tiles.mlpackage Rummikub/

# Trains Values, which reads each tile and its orientation, on tile crops for MINUTES (5), and gives the app it.
values:
	uv run Labeler/crops.py $(dir) $(dir)/.crops $(wildcard Outside/*-train Outside/*-values)
	uv run Labeler/values.py $(dir)
	rm -rf Rummikub/Values.mlpackage && cp -R $(dir)/Values.mlpackage Rummikub/

# Trains Looking, which says whether a frame shows a rack or the table, on whole frames labeled in looking.txt, and
# gives the app it.
looking:
	uv run Labeler/looking.py $(dir) $(dir)/.looking
	cd RummikubKit && swift run -c release looking ../$(dir)/.looking ../$(dir)/Looking.mlmodel
	cp $(dir)/Looking.mlmodel Rummikub/

# Lists where the models disagree with the done captures' labels, for the labeler's Check section.
check:
	cd RummikubKit && swift run -c release check ../$(dir)

# Scores the finder and the reader on the held-out captures, a fifth of the done ones, which training never sees.
score:
	cd RummikubKit && swift run -c release score ../$(dir)

# Look through the captures in review.txt for personal text first, which `make watch` lists: the dataset is meant to
# go public.
upload:
	uvx --from huggingface_hub hf upload visnup/rummikub-captures $(dir) . --repo-type dataset --exclude .files.json \
	  --exclude .removed --exclude .DS_Store --exclude .words.txt --exclude review.txt \
	  --exclude ".crops/*" --exclude ".looking/*" --exclude ".finder/*" --exclude "*.mlmodel" \
	  --exclude "Tiles.mlpackage/*" --exclude "Values.mlpackage/*" --exclude ids.txt --exclude .check.json --exclude .check.done --exclude checked.txt
