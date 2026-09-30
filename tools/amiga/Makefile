M=../Musashi
CFLAGS=-O2 -g -I$(M) -Wno-unused-parameter -Wno-misleading-indentation
SRC=emu.c $(M)/m68kcpu.c $(M)/m68kops.c $(M)/m68kdasm.c $(M)/softfloat/softfloat.c

emu: $(SRC) $(M)/m68kops.h
	cc $(CFLAGS) -o emu $(SRC) -lz -lm

# Musashi's opcode tables are generated (not stored in the repository).
$(M)/m68kops.c $(M)/m68kops.h: $(M)/m68kmake.c $(M)/m68k_in.c
	cc -o $(M)/m68kmake $(M)/m68kmake.c
	cd $(M) && ./m68kmake

clean:
	rm -f emu $(M)/m68kmake $(M)/m68kops.c $(M)/m68kops.h
