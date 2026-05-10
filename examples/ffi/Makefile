LDFLAGS := -std=c99 -shared -Wall -Wextra
UNAME := $(shell uname -s)
ifeq ($(UNAME), Darwin)
	LDFLAGS += -undefined dynamic_lookup -target arm64-apple-macos11 -fPIC
endif

all:
	clang $(LDFLAGS) all.c -o all.so

clean:
	rm -f *.so *.dylib
