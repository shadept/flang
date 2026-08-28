# Cold-start the FLang compiler from the committed seed C. See ../README.md.
# No -Werror: the seed must stay buildable by future compilers whose warning
# sets this file cannot predict.
CC ?= cc

flang-seed: $(wildcard *.c)
	$(CC) -O2 -Wno-pointer-sign -o $@ $(wildcard *.c) -lm

clean:
	rm -f flang-seed

.PHONY: clean
