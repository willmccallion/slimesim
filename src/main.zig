// src/main.zig — Physarum polycephalum slime mold simulation
//
// Algorithm per frame:
//   1. Sense: each agent samples trail at left/center/right offsets, steers toward max
//   2. Rotate & move: update agent angle and position
//   3. Deposit: write trail value at agent position
//   4. Diffuse: 3x3 box blur on trail grid
//   5. Decay: multiply trail by (1 - DECAY)
//   6. Render: map trail [0,1] through a palette into the SDL texture

const std = @import("std");
const math = std.math;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

// ── Simulation constants ──────────────────────────────────────────────────────
const SIM_W: usize = 1280;
const SIM_H: usize = 720;
const WIN_W: c_int = @intCast(SIM_W);
const WIN_H: c_int = @intCast(SIM_H);

const NUM_AGENTS: usize = 200_000;

// Agent parameters
const AGENT_SPEED: f32     = 1.5;   // pixels per step
const SENSOR_DIST: f32     = 9.0;   // how far ahead to sample
const SENSOR_ANGLE: f32    = 0.436; // ~25 deg in radians
const TURN_SPEED: f32      = 0.3;   // radians per step (max random turn)
const DEPOSIT: f32         = 5.0;   // trail deposited per step
const DECAY: f32           = 0.012; // fraction removed per step
const DIFFUSE_WEIGHT: f32  = 0.2;   // blend factor toward blurred value

// ── Types ─────────────────────────────────────────────────────────────────────
const Agent = struct {
    x: f32,
    y: f32,
    angle: f32, // radians
};

// ── Global state (static to avoid large stack frames) ─────────────────────────
var agents: [NUM_AGENTS]Agent = undefined;
var trail:  [SIM_H][SIM_W]f32 = undefined;
var diffuse_buf: [SIM_H][SIM_W]f32 = undefined;

// ── PRNG ─────────────────────────────────────────────────────────────────────
var rng = std.Random.DefaultPrng.init(0xdeadbeef_cafebabe);

inline fn frand() f32 {
    return rng.random().float(f32);
}

// ── Palette ───────────────────────────────────────────────────────────────────
// Maps t in [0,1] to a warm-amber/white bioluminescent look (RGBA bytes).
fn palette(t: f32) u32 {
    // Low: deep blue-black → mid: orange-amber → high: white
    const r: u8 = @intFromFloat(@min(255.0, t * t * 800.0));
    const g: u8 = @intFromFloat(@min(255.0, t * t * 340.0));
    const b: u8 = @intFromFloat(@min(255.0, t * 180.0 + t * t * 60.0));
    const a: u8 = 255;
    // Pack as ABGR8888 (what SDL_PIXELFORMAT_ABGR8888 expects in memory: R,G,B,A bytes)
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16) | (@as(u32, a) << 24);
}

// ── Helpers ───────────────────────────────────────────────────────────────────
inline fn sample_trail(x: f32, y: f32) f32 {
    const ix = @as(i32, @intFromFloat(x));
    const iy = @as(i32, @intFromFloat(y));
    if (ix < 0 or iy < 0 or ix >= SIM_W or iy >= SIM_H) return 0.0;
    return trail[@intCast(iy)][@intCast(ix)];
}

// ── Init ──────────────────────────────────────────────────────────────────────
fn init_agents() void {
    const cx: f32 = @as(f32, @floatFromInt(SIM_W)) * 0.5;
    const cy: f32 = @as(f32, @floatFromInt(SIM_H)) * 0.5;
    const spawn_r: f32 = @min(cx, cy) * 0.25;

    for (&agents) |*a| {
        // Spawn in a circle, facing outward
        const angle = frand() * math.tau;
        const r = frand() * spawn_r;
        a.x     = cx + @cos(angle) * r;
        a.y     = cy + @sin(angle) * r;
        a.angle = angle; // face outward
    }
}

fn init_trail() void {
    for (&trail) |*row| @memset(row, 0.0);
}

// ── Simulation step ───────────────────────────────────────────────────────────
fn step_agents() void {
    const fw: f32 = @floatFromInt(SIM_W);
    const fh: f32 = @floatFromInt(SIM_H);

    for (&agents) |*a| {
        // Sensor positions
        const sl = a.angle - SENSOR_ANGLE;
        const sr = a.angle + SENSOR_ANGLE;

        const sense_c = sample_trail(
            a.x + @cos(a.angle) * SENSOR_DIST,
            a.y + @sin(a.angle) * SENSOR_DIST,
        );
        const sense_l = sample_trail(
            a.x + @cos(sl) * SENSOR_DIST,
            a.y + @sin(sl) * SENSOR_DIST,
        );
        const sense_r = sample_trail(
            a.x + @cos(sr) * SENSOR_DIST,
            a.y + @sin(sr) * SENSOR_DIST,
        );

        // Steer
        if (sense_c >= sense_l and sense_c >= sense_r) {
            // Continue straight — tiny random wobble
            a.angle += (frand() - 0.5) * TURN_SPEED * 0.2;
        } else if (sense_l > sense_r) {
            a.angle -= frand() * TURN_SPEED;
        } else if (sense_r > sense_l) {
            a.angle += frand() * TURN_SPEED;
        } else {
            // Equal: random turn
            a.angle += (frand() - 0.5) * TURN_SPEED;
        }

        // Move
        const nx = a.x + @cos(a.angle) * AGENT_SPEED;
        const ny = a.y + @sin(a.angle) * AGENT_SPEED;

        // Wrap at boundaries
        a.x = @mod(nx + fw, fw);
        a.y = @mod(ny + fh, fh);

        // Deposit
        const px: usize = @intFromFloat(a.x);
        const py: usize = @intFromFloat(a.y);
        const cur = trail[py][px];
        trail[py][px] = @min(1.0, cur + DEPOSIT * (1.0 / 255.0));
    }
}

fn diffuse_and_decay() void {
    // 3x3 box blur blended with original, then decay
    const W: usize = SIM_W;
    const H: usize = SIM_H;

    for (0..H) |y| {
        const ym = if (y == 0) H - 1 else y - 1;
        const yp = if (y == H - 1) 0 else y + 1;
        for (0..W) |x| {
            const xm = if (x == 0) W - 1 else x - 1;
            const xp = if (x == W - 1) 0 else x + 1;

            const sum =
                trail[ym][xm] + trail[ym][x] + trail[ym][xp] +
                trail[y ][xm] + trail[y ][x]  + trail[y ][xp] +
                trail[yp][xm] + trail[yp][x] + trail[yp][xp];

            const blurred = sum * (1.0 / 9.0);
            diffuse_buf[y][x] = std.math.lerp(trail[y][x], blurred, DIFFUSE_WEIGHT) * (1.0 - DECAY);
        }
    }

    // Swap buffers
    for (0..H) |y| {
        @memcpy(&trail[y], &diffuse_buf[y]);
    }
}

// ── Pixel buffer ─────────────────────────────────────────────────────────────
var pixels: [SIM_H * SIM_W]u32 = undefined;

fn render_pixels() void {
    for (0..SIM_H) |y| {
        for (0..SIM_W) |x| {
            pixels[y * SIM_W + x] = palette(trail[y][x]);
        }
    }
}

// ── SDL helpers ───────────────────────────────────────────────────────────────
fn sdl_die(msg: []const u8) noreturn {
    const err = c.SDL_GetError();
    std.debug.print("SDL Error: {s}: {s}\n", .{ msg, err });
    std.process.exit(1);
}

// ── Entry point ───────────────────────────────────────────────────────────────
pub fn main() !void {
    // Seed RNG with time
    rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));

    init_trail();
    init_agents();

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) sdl_die("SDL_Init");
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "Slime Mold — Physarum polycephalum",
        c.SDL_WINDOWPOS_CENTERED,
        c.SDL_WINDOWPOS_CENTERED,
        WIN_W,
        WIN_H,
        c.SDL_WINDOW_SHOWN,
    ) orelse sdl_die("SDL_CreateWindow");
    defer c.SDL_DestroyWindow(window);

    const renderer = c.SDL_CreateRenderer(
        window, -1,
        c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC,
    ) orelse sdl_die("SDL_CreateRenderer");
    defer c.SDL_DestroyRenderer(renderer);

    const texture = c.SDL_CreateTexture(
        renderer,
        c.SDL_PIXELFORMAT_ABGR8888,
        c.SDL_TEXTUREACCESS_STREAMING,
        WIN_W,
        WIN_H,
    ) orelse sdl_die("SDL_CreateTexture");
    defer c.SDL_DestroyTexture(texture);

    var running = true;
    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    if (event.key.keysym.sym == c.SDLK_ESCAPE) running = false;
                },
                else => {},
            }
        }

        // Simulate
        step_agents();
        diffuse_and_decay();
        render_pixels();

        // Upload & present
        _ = c.SDL_UpdateTexture(texture, null, &pixels, WIN_W * 4);
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderCopy(renderer, texture, null, null);
        c.SDL_RenderPresent(renderer);
    }
}
