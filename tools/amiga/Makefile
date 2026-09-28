M=../Musashi
CFLAGS=-O2 -g -I$(M) -Wno-unused-parameter -Wno-misleading-indentation
emu: emu.c $(M)/m68kcpu.c $(M)/m68kops.c $(M)/m68kdasm.c $(M)/softfloat/softfloat.c
	cc $(CFLAGS) -o emu emu.c $(M)/m68kcpu.c $(M)/m68kops.c $(M)/m68kdasm.c $(M)/softfloat/softfloat.c -lz -lm
