CC ?= cc
CFLAGS ?= -std=c99 -Wall -Wextra -I../..
LIB = ../../zig-out/lib/liberevo.a
UNAME := $(shell uname -s)

# for my specific configuration, this is the only way to make it work on osx15.5
ifeq ($(UNAME), Darwin)
CFLAGS += -mmacosx-version-min=15.5
endif

all: basic

$(LIB):
	cd ../.. && zig build

basic: basic.c $(LIB)
	$(CC) $(CFLAGS) $< $(LIB) -o $@

run: basic
	./basic

clean:
	rm -f basic
