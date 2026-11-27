# Game Boy test ROMs

Our own test ROMs for the Game Boy, for behaviour that no public test suite covers, each written after a game showed it. Each is a 32 KB ROM-only cartridge written for rgbds 1.0.4; `make` builds them, and `testroms/fetch.py` does it into its folder and checks each against `testroms/manifest-gb.toml`. They run on the Game Boy and the Color as the manifest's entries say, each checked by its frame (`harness/golden/gb_frames_crc32.txt`, from MesenCE, as with the other ROMs; where it's known, the line also says what SameBoy gives).

| ROM | Tests |
| --- | --- |
| `win_off_pixel` | The Game Boy's blank pixel with the window off: once WY has matched in a frame the window stays triggered, and with LCDC bit 5 then cleared, WX matching the line's position + 7 while the fetcher waits to push with the background FIFO empty puts one colour-0 pixel in the FIFO, moving the rest of the line right by one (SameBoy issue 278). WY 0 and WX 7, the window off for lines 32-111 and WX 87 for lines 64-95, each change made in the HBlank before (so none lands in mode 3, where MesenCE takes a write at another dot); BGP `$1B` makes the extra pixel black. The Color has no such pixel. From Star Trek: 25th Anniversary's credits, which turn the window off for a band |
