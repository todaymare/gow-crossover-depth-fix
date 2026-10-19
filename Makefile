CC := x86_64-w64-mingw32-gcc
CFLAGS := -std=c11 -O2 -Wall -Wextra -Werror -Wno-cast-function-type
VERSION ?= 0.1.0

.PHONY: all release
all: d3d11.dll

d3d11.dll: proxy.c d3d11.def
	$(CC) $(CFLAGS) -shared -static-libgcc -Wl,--no-insert-timestamp proxy.c d3d11.def -o $@ -ldxguid -luuid

verify.exe: verify.c
	$(CC) $(CFLAGS) verify.c -o $@ -ldxguid -luuid

release: d3d11.dll
	/bin/bash scripts/package.sh "$(VERSION)"
