# Source-only release. All arcade-derived data is generated in ignored build/.
CA65 ?= ca65
LD65 ?= ld65
PY ?= python3
override NBANKS = 256
CFG = build/snes$(NBANKS).cfg
.DEFAULT_GOAL := all

SRCS = $(wildcard src/*.s)
GENS = roaddata scenery2 sndgen road2 roadkeys rom0 gametab sprdat3 sprgeom textdat pages2 ohbdat
CAFLAGS += -D NEWGAME
ifdef LOCKSTEP
CAFLAGS += -D LOCKSTEP -D LSINPUT
OBJDIR = build/lobj
ROM = build/outrun_ls.sfc
else ifdef LSINPUT
CAFLAGS += -D LSINPUT
OBJDIR = build/iobj
ROM = build/outrun_li.sfc
else
OBJDIR = build/nobj
ROM = build/outrun_ng.sfc
endif
OBJS = $(patsubst src/%.s,$(OBJDIR)/%.o,$(SRCS)) $(patsubst %,$(OBJDIR)/%.o,$(GENS))

all:
	$(PY) tools/build.py $(if $(MAME_ROMS),--mame-roms "$(MAME_ROMS)")

# For engine development after a successful asset build; no asset importing.
assemble: $(ROM)

$(OBJS): build/assets.json

build/assets.json:
	@echo 'Generate local assets first: python3 tools/build.py --mame-roms /path/to/outrun.zip'
	@exit 1

$(CFG): tools/mkcfg.py
	@mkdir -p build
	$(PY) tools/mkcfg.py $(NBANKS) $(CFG)

$(OBJDIR)/%.o: src/%.s $(wildcard src/*.inc) $(wildcard build/gen/*.inc)
	@mkdir -p $(OBJDIR)
	$(CA65) --cpu 65816 $(CAFLAGS) -I src -I build/gen -I build --bin-include-dir build/gen -g -o $@ $<

$(OBJDIR)/%.o: build/gen/%.s $(wildcard build/gen/*.inc) $(wildcard build/gen/*.bin)
	@mkdir -p $(OBJDIR)
	$(CA65) --cpu 65816 $(CAFLAGS) -I src -I build/gen --bin-include-dir build/gen -g -o $@ $<

$(ROM): $(OBJS) $(CFG)
	$(LD65) -C $(CFG) -m $(ROM:.sfc=.map) -Ln $(ROM:.sfc=.sym) --dbgfile $(ROM:.sfc=.dbg) -o $@ $(OBJS)
	$(PY) tools/fixsum.py $@

clean:
	rm -rf $(OBJDIR) $(ROM)

.PHONY: all assemble clean release

release:
	$(PY) tools/release.py

# generated sound module includes the upload streams
$(OBJDIR)/sndgen.o: $(wildcard build/gen/snd_*.bin)

build/gen/sprgeom.s: tools/mksprgeom.py build/gen/sprmeta.bin build/gen/sprzt.bin build/gen/sprdat3.inc
	$(PY) tools/mksprgeom.py

build/gen/roadkeys.s: tools/mkroadkeys.py build/gen/road2.s $(wildcard build/gen/road2_path_*.bin)
	$(PY) tools/mkroadkeys.py
