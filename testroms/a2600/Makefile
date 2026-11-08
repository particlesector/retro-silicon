# SPDX-License-Identifier: Apache-2.0
# The Atari 2600 test cartridges: one 4 KB .bin from each .s, with ca65 and ld65 from cc65.
CARTS := $(patsubst %.s,%.bin,$(wildcard *.s))

all: $(CARTS)

%.bin: %.s vcs.inc show.inc cart4k.cfg
	ca65 -o $*.o $<
	ld65 -C cart4k.cfg -o $@ $*.o
	rm -f $*.o

clean:
	rm -f *.bin *.o

.PHONY: all clean
