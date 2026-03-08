.PHONY: build release run clean fmt

build:
	zig build

release:
	zig build -Doptimize=ReleaseFast

run:
	zig build run -Doptimize=ReleaseFast

clean:
	rm -rf zig-out .zig-cache

fmt:
	zig fmt src/ build.zig
