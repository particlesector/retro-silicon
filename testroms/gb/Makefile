# SPDX-License-Identifier: Apache-2.0
# retro-silicon's own Game Boy test ROMs: one 32 KB .gb from each .asm, with rgbds 1.0.4 (rgbasm,
# rgblink, rgbfix; tools/fetch.sh in the rig installs it, as SameBoy's boot ROMs need it too).
ROMS := $(patsubst %.asm,%.gb,$(wildcard *.asm))

all: $(ROMS)

%.gb: %.asm
	rgbasm -o $*.o $<
	rgblink -o $@ $*.o
	rgbfix -v -p 0xFF -t $(shell echo $* | tr a-z A-Z | cut -c1-11) $@
	rm -f $*.o

clean:
	rm -f $(ROMS) *.o

.PHONY: all clean
