ASM      = nasm
LDFLAGS  = -s -N
TARGET   = planckclaw

all: $(TARGET)

$(TARGET): planckclaw.o
	ld $(LDFLAGS) -o $@ $<

planckclaw.o: planckclaw.asm
	$(ASM) -f elf64 -o $@ $<

size: $(TARGET)
	wc -c $(TARGET)
	size $(TARGET)

clean:
	rm -f planckclaw.o $(TARGET)

.PHONY: all size clean
