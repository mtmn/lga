VIDEO  := lga-2000.mp4
FRAMES ?= 600
# make LGA_FLAGS="--seed 42 --gas 0.2"
LGA_FLAGS ?=

WEB := lga.wasm

.PHONY: all video web serve help check clean

all: video

video: $(VIDEO)

$(VIDEO): lga.janet
	janet lga.janet --frames $(FRAMES) $(LGA_FLAGS) $@

help:
	@janet lga.janet --help

check:
	@command -v janet  >/dev/null || { echo "missing: janet";  exit 1; }
	@command -v ffmpeg >/dev/null || { echo "missing: ffmpeg"; exit 1; }
	@echo "janet $$(janet -v), ffmpeg ok"

web: $(WEB)

$(WEB): lga.c
	clang --target=wasm32-unknown-unknown -O3 -ffreestanding -nostdlib \
		-Wl,--no-entry -Wl,--export-all -o $@ lga.c

serve: web
	python3 -m http.server 8000

clean:
	rm -f $(VIDEO) $(WEB)
