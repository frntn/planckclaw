ASM      = nasm
LDFLAGS  = -s -n
TARGET   = plankclaw

all: $(TARGET)

$(TARGET): plankclaw.o
	ld $(LDFLAGS) -o $@ $<

plankclaw.o: plankclaw.asm
	$(ASM) -f elf64 -o $@ $<

size: $(TARGET)
	wc -c $(TARGET)
	size $(TARGET)

clean:
	rm -f plankclaw.o $(TARGET)

.PHONY: all size clean
