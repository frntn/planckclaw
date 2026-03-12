ASM      = nasm
LDFLAGS  = -s -N
TARGET   = planckclaw

all: $(TARGET)

$(TARGET): planckclaw.o
	ld $(LDFLAGS) -o $@ $<

planckclaw.o: planckclaw.asm
	$(ASM) -f elf64 -o $@ $<

size: $(TARGET)
	@printf 'agent binary:  %s bytes\n' "$$(wc -c < $(TARGET))"
	@total=$$(wc -c < $(TARGET)); \
	for f in bridge_*.sh planckclaw.sh claws/*.sh config.env.example; do \
		[ -f "$$f" ] && total=$$((total + $$(wc -c < "$$f"))); \
	done; \
	printf 'total runtime: %s bytes (~%s KB)\n' "$$total" "$$((total / 1024))"

clean:
	rm -f planckclaw.o $(TARGET)

.PHONY: all size clean
