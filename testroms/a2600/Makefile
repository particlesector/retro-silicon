# SPDX-License-Identifier: Apache-2.0
# The Atari 2600 test cartridges: one 4 KB .bin from each .s, with ca65 and ld65 from cc65.
CARTS := $(patsubst %.s,%.bin,$(filter-out bank_%.s,$(wildcard *.s)))

# The bank-switching cartridges, each named for its scheme (Stella takes the scheme from the
# extension): bank_f.s once per 4 KB bank (-D BANK=k), the banks joined in order.
BANKED := bank_f8.F8 bank_f6.F6 bank_f4.F4 bank_f8sc.F8SC bank_f6sc.F6SC bank_f4sc.F4SC \
          bank_fa.FA bank_f0.F0 bank_fe.FE bank_e0.E0 bank_3f.3F bank_e7.E7

DEFS_bank_f8.F8     := -D NB=2 -D HOT=65528
DEFS_bank_f6.F6     := -D NB=4 -D HOT=65526
DEFS_bank_f4.F4     := -D NB=8 -D HOT=65524
DEFS_bank_f8sc.F8SC := -D NB=2 -D HOT=65528 -D RAM=128
DEFS_bank_f6sc.F6SC := -D NB=4 -D HOT=65526 -D RAM=128
DEFS_bank_f4sc.F4SC := -D NB=8 -D HOT=65524 -D RAM=128
DEFS_bank_fa.FA     := -D NB=3 -D HOT=65528 -D RAM=256
DEFS_bank_f0.F0     := -D NB=16 -D F0=1

all: $(CARTS) $(BANKED)

%.bin: %.s vcs.inc show.inc cart4k.cfg
	ca65 -o $*.o $<
	ld65 -C cart4k.cfg -o $@ $*.o
	rm -f $*.o

bank_f8.F8 bank_f6.F6 bank_f4.F4 bank_f8sc.F8SC bank_f6sc.F6SC bank_f4sc.F4SC bank_fa.FA bank_f0.F0: \
		bank_f.s vcs.inc show.inc bank4k.cfg
	rm -f $@.part*
	n=$$(echo '$(DEFS_$@)' | sed 's/.*NB=\([0-9]*\).*/\1/'); \
	for k in $$(seq 0 $$((n - 1))); do \
		ca65 $(DEFS_$@) -D BANK=$$k -o $@.o bank_f.s && \
		ld65 -C bank4k.cfg -o $@.part$$(printf %02d $$k) $@.o || exit 1; \
	done
	cat $@.part* > $@
	rm -f $@.part* $@.o

# FE: two 4 KB banks, bank 0 at $F000 and bank 1 at $D000.
bank_fe.FE: bank_fe.s vcs.inc show.inc fe.cfg
	ca65 -D BANK=0 -o $@.o bank_fe.s && ld65 -C fe.cfg -D ORG=0xF000 -o $@.part0 $@.o
	ca65 -D BANK=1 -o $@.o bank_fe.s && ld65 -C fe.cfg -D ORG=0xD000 -o $@.part1 $@.o
	cat $@.part0 $@.part1 > $@
	rm -f $@.part* $@.o

# The sliced ones: data slices from bank_id.s (SLICE=k), then the program in the fixed top slice.
# $(call sliced,program,slices,slice size,top start)
define sliced
	for k in $$(seq 0 $$(($(2) - 1))); do \
		ca65 -D SLICE=$$k -o $@.o bank_id.s && \
		ld65 -C slice.cfg -D SIZE=$(3) -o $@.part$$k $@.o || exit 1; \
	done
	ca65 -o $@.o $(1) && ld65 -C slice_top.cfg -D SIZE=$(3) -D TOP=$(4) -o $@.part$(2) $@.o
	cat $$(for k in $$(seq 0 $(2)); do echo $@.part$$k; done) > $@
	rm -f $@.part* $@.o
endef

bank_e0.E0: bank_e0.s bank_id.s vcs.inc show.inc slice.cfg slice_top.cfg
	$(call sliced,bank_e0.s,7,1024,0xFC00)
bank_3f.3F: bank_3f.s bank_id.s vcs.inc show.inc slice.cfg slice_top.cfg
	$(call sliced,bank_3f.s,7,2048,0xF800)
bank_e7.E7: bank_e7.s bank_id.s vcs.inc show.inc slice.cfg slice_top.cfg
	$(call sliced,bank_e7.s,7,2048,0xF800)

clean:
	rm -f *.bin *.o $(BANKED)

.PHONY: all clean
