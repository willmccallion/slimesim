// src/main.zig — Physarum polycephalum slime mold simulation
//
// Controls:
//   1-6        cycle colour schemes
//   [ / ]      decay slower / faster
//   , / .      sensor distance shorter / longer
//   ; / '      turn speed down / up
//   - / =      agent speed down / up
//   D / F      diffuse weight down / up
//   R          reset params, trail, and agents
//   C          clear trail (agents keep going)
//   P          pause / resume
//   Escape     quit

const std = @import("std");
const math = std.math;

const c = @cImport({
    @cInclude("SDL2/SDL.h");
});

// ── Grid dimensions ───────────────────────────────────────────────────────────
const SIM_W: usize = 1280;
const SIM_H: usize = 720;
const WIN_W: c_int  = @intCast(SIM_W);
const WIN_H: c_int  = @intCast(SIM_H);
const NUM_AGENTS: usize = 200_000;

// ── Tunable parameters (live, mutated by key presses) ─────────────────────────
var p_speed:          f32 = 1.5;
var p_sensor_dist:    f32 = 9.0;
var p_sensor_angle:   f32 = 0.436; // ~25 deg, kept fixed for now
var p_turn_speed:     f32 = 0.3;
var p_deposit:        f32 = 5.0;
var p_decay:          f32 = 0.012;
var p_diffuse_weight: f32 = 0.2;

// Clamp helpers so params stay sane
inline fn clamp_f(v: f32, lo: f32, hi: f32) f32 {
    return @max(lo, @min(hi, v));
}

// ── Colour schemes ────────────────────────────────────────────────────────────
const Scheme = enum(u8) {
    amber   = 0,
    plasma  = 1,
    acid    = 2,
    ocean   = 3,
    lava    = 4,
    grey    = 5,
    pub const count = 6;
    pub fn name(s: Scheme) []const u8 {
        return switch (s) {
            .amber  => "Amber",
            .plasma => "Plasma",
            .acid   => "Acid Green",
            .ocean  => "Deep Ocean",
            .lava   => "Lava",
            .grey   => "Greyscale",
        };
    }
};

var current_scheme: Scheme = .amber;

// Pack ABGR (memory order R,G,B,A for SDL_PIXELFORMAT_ABGR8888)
inline fn rgb(r: f32, g: f32, b: f32) u32 {
    const ri: u32 = @intFromFloat(@min(255.0, r));
    const gi: u32 = @intFromFloat(@min(255.0, g));
    const bi: u32 = @intFromFloat(@min(255.0, b));
    return ri | (gi << 8) | (bi << 16) | (0xFF << 24);
}

// Interpolate between two rgb stops, local t in [0,1]
inline fn between(t: f32, r0: f32, g0: f32, b0: f32, r1: f32, g1: f32, b1: f32) u32 {
    return rgb(r0 + (r1 - r0) * t, g0 + (g1 - g0) * t, b0 + (b1 - b0) * t);
}

// Each palette is a hand-unrolled multi-stop gradient.
// Stops: (pos, r, g, b) — pos must be ascending, first=0.0, last=1.0.
fn pal_amber(t: f32) u32 {
    if (t < 0.3)  return between(t / 0.3,        0,  0,   8,  60,  15,   0);
    if (t < 0.65) return between((t-0.3)/0.35,   60, 15,  0, 220, 100,  10);
                  return between((t-0.65)/0.35, 220,100, 10, 255, 240, 200);
}
fn pal_plasma(t: f32) u32 {
    if (t < 0.25) return between(t / 0.25,          0,  0,  20, 100,  0, 160);
    if (t < 0.55) return between((t-0.25)/0.30,   100,  0,160, 220,  0, 200);
    if (t < 0.80) return between((t-0.55)/0.25,   220,  0,200,   0,200, 220);
                  return between((t-0.80)/0.20,     0,200,220, 230,255, 255);
}
fn pal_acid(t: f32) u32 {
    if (t < 0.35) return between(t / 0.35,         0,  0,  0,   0, 60,   0);
    if (t < 0.70) return between((t-0.35)/0.35,    0, 60,  0,  30,220,  10);
                  return between((t-0.70)/0.30,    30,220, 10, 180,255, 120);
}
fn pal_ocean(t: f32) u32 {
    if (t < 0.30) return between(t / 0.30,         0,  0, 20,   0, 30,  80);
    if (t < 0.65) return between((t-0.30)/0.35,    0, 30, 80,   0,140, 160);
                  return between((t-0.65)/0.35,    0,140,160, 180,240, 255);
}
fn pal_lava(t: f32) u32 {
    if (t < 0.30) return between(t / 0.30,         0,  0,  0, 120,  0,   0);
    if (t < 0.60) return between((t-0.30)/0.30,  120,  0,  0, 220, 60,   0);
    if (t < 0.85) return between((t-0.60)/0.25,  220, 60,  0, 255,200,  20);
                  return between((t-0.85)/0.15,  255,200, 20, 255,255, 200);
}

fn palette(t: f32) u32 {
    return switch (current_scheme) {
        .amber  => pal_amber(t),
        .plasma => pal_plasma(t),
        .acid   => pal_acid(t),
        .ocean  => pal_ocean(t),
        .lava   => pal_lava(t),
        .grey   => blk: { const v = t * 255.0; break :blk rgb(v, v, v); },
    };
}

// ── Agent ─────────────────────────────────────────────────────────────────────
const Agent = struct { x: f32, y: f32, angle: f32 };

// ── Global state ──────────────────────────────────────────────────────────────
var agents:      [NUM_AGENTS]Agent       = undefined;
var trail:       [SIM_H][SIM_W]f32      = undefined;
var diffuse_buf: [SIM_H][SIM_W]f32      = undefined;
var pixels:      [SIM_H * SIM_W]u32     = undefined;

var rng = std.Random.DefaultPrng.init(0);
inline fn frand() f32 { return rng.random().float(f32); }

// ── Init / reset ──────────────────────────────────────────────────────────────
fn init_agents() void {
    const cx: f32 = @as(f32, @floatFromInt(SIM_W)) * 0.5;
    const cy: f32 = @as(f32, @floatFromInt(SIM_H)) * 0.5;
    const spawn_r: f32 = @min(cx, cy) * 0.25;
    for (&agents) |*a| {
        const angle = frand() * math.tau;
        const r     = frand() * spawn_r;
        a.x     = cx + @cos(angle) * r;
        a.y     = cy + @sin(angle) * r;
        a.angle = angle;
    }
}

fn clear_trail() void {
    for (&trail) |*row| @memset(row, 0.0);
}

// ── Simulation ────────────────────────────────────────────────────────────────
inline fn sample(x: f32, y: f32) f32 {
    const ix: i32 = @intFromFloat(x);
    const iy: i32 = @intFromFloat(y);
    if (ix < 0 or iy < 0 or ix >= SIM_W or iy >= SIM_H) return 0.0;
    return trail[@intCast(iy)][@intCast(ix)];
}

fn step_agents() void {
    const fw: f32 = @floatFromInt(SIM_W);
    const fh: f32 = @floatFromInt(SIM_H);

    for (&agents) |*a| {
        const sl = a.angle - p_sensor_angle;
        const sr = a.angle + p_sensor_angle;
        const sc = sample(a.x + @cos(a.angle) * p_sensor_dist,
                          a.y + @sin(a.angle) * p_sensor_dist);
        const sl_ = sample(a.x + @cos(sl) * p_sensor_dist,
                           a.y + @sin(sl) * p_sensor_dist);
        const sr_ = sample(a.x + @cos(sr) * p_sensor_dist,
                           a.y + @sin(sr) * p_sensor_dist);

        if (sc >= sl_ and sc >= sr_) {
            a.angle += (frand() - 0.5) * p_turn_speed * 0.2;
        } else if (sl_ > sr_) {
            a.angle -= frand() * p_turn_speed;
        } else if (sr_ > sl_) {
            a.angle += frand() * p_turn_speed;
        } else {
            a.angle += (frand() - 0.5) * p_turn_speed;
        }

        a.x = @mod(a.x + @cos(a.angle) * p_speed + fw, fw);
        a.y = @mod(a.y + @sin(a.angle) * p_speed + fh, fh);

        const px: usize = @intFromFloat(a.x);
        const py: usize = @intFromFloat(a.y);
        trail[py][px] = @min(1.0, trail[py][px] + p_deposit * (1.0 / 255.0));
    }
}

fn diffuse_and_decay() void {
    const W = SIM_W;
    const H = SIM_H;
    for (0..H) |y| {
        const ym = if (y == 0) H - 1 else y - 1;
        const yp = if (y == H - 1) 0 else y + 1;
        for (0..W) |x| {
            const xm = if (x == 0) W - 1 else x - 1;
            const xp = if (x == W - 1) 0 else x + 1;
            const blurred = (trail[ym][xm] + trail[ym][x] + trail[ym][xp] +
                             trail[y ][xm] + trail[y ][x]  + trail[y ][xp] +
                             trail[yp][xm] + trail[yp][x] + trail[yp][xp]) * (1.0 / 9.0);
            diffuse_buf[y][x] = math.lerp(trail[y][x], blurred, p_diffuse_weight) * (1.0 - p_decay);
        }
    }
    for (0..H) |y| @memcpy(&trail[y], &diffuse_buf[y]);
}

fn render_pixels() void {
    for (0..SIM_H) |y| {
        for (0..SIM_W) |x| {
            pixels[y * SIM_W + x] = palette(trail[y][x]);
        }
    }
}

// ── SDL helpers ───────────────────────────────────────────────────────────────
fn sdl_die(msg: []const u8) noreturn {
    std.debug.print("SDL Error: {s}: {s}\n", .{ msg, c.SDL_GetError() });
    std.process.exit(1);
}

fn update_title(window: *c.SDL_Window) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrintZ(&buf,
        "Slime Mold [{s}]  spd={d:.2} sens={d:.1} turn={d:.2} decay={d:.3} diff={d:.2}  " ++
        "1-6:scheme  [/]:decay  ,/.:sensor  ;/':turn  -/=:speed  d/f:diffuse  r:full reset  c:clear trail  p:pause",
        .{
            current_scheme.name(),
            p_speed, p_sensor_dist, p_turn_speed, p_decay, p_diffuse_weight,
        },
    ) catch return;
    c.SDL_SetWindowTitle(window, s.ptr);
}

// ── Main ──────────────────────────────────────────────────────────────────────
pub fn main() !void {
    rng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));
    clear_trail();
    init_agents();

    if (c.SDL_Init(c.SDL_INIT_VIDEO) != 0) sdl_die("SDL_Init");
    defer c.SDL_Quit();

    const window = c.SDL_CreateWindow(
        "Slime Mold",
        c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED,
        WIN_W, WIN_H,
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
        WIN_W, WIN_H,
    ) orelse sdl_die("SDL_CreateTexture");
    defer c.SDL_DestroyTexture(texture);

    update_title(window);

    var running = true;
    var paused  = false;
    var dirty_title = false; // set when params change, title updated next frame

    while (running) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event) != 0) {
            switch (event.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    const sym = event.key.keysym.sym;
                    switch (sym) {
                        c.SDLK_ESCAPE => running = false,
                        c.SDLK_p => paused = !paused,

                        // ── Colour schemes ─────────────────────────────────
                        c.SDLK_1 => { current_scheme = .amber;  dirty_title = true; },
                        c.SDLK_2 => { current_scheme = .plasma; dirty_title = true; },
                        c.SDLK_3 => { current_scheme = .acid;   dirty_title = true; },
                        c.SDLK_4 => { current_scheme = .ocean;  dirty_title = true; },
                        c.SDLK_5 => { current_scheme = .lava;   dirty_title = true; },
                        c.SDLK_6 => { current_scheme = .grey;   dirty_title = true; },

                        // ── Decay  [ / ] ───────────────────────────────────
                        c.SDLK_LEFTBRACKET  => { p_decay = clamp_f(p_decay - 0.002, 0.001, 0.15); dirty_title = true; },
                        c.SDLK_RIGHTBRACKET => { p_decay = clamp_f(p_decay + 0.002, 0.001, 0.15); dirty_title = true; },

                        // ── Sensor distance  , / . ─────────────────────────
                        c.SDLK_COMMA  => { p_sensor_dist = clamp_f(p_sensor_dist - 1.0, 1.0, 40.0); dirty_title = true; },
                        c.SDLK_PERIOD => { p_sensor_dist = clamp_f(p_sensor_dist + 1.0, 1.0, 40.0); dirty_title = true; },

                        // ── Turn speed  ; / ' ──────────────────────────────
                        c.SDLK_SEMICOLON    => { p_turn_speed = clamp_f(p_turn_speed - 0.05, 0.01, 2.0); dirty_title = true; },
                        c.SDLK_QUOTE        => { p_turn_speed = clamp_f(p_turn_speed + 0.05, 0.01, 2.0); dirty_title = true; },

                        // ── Agent speed  - / = ─────────────────────────────
                        c.SDLK_MINUS => { p_speed = clamp_f(p_speed - 0.25, 0.25, 8.0); dirty_title = true; },
                        c.SDLK_EQUALS => { p_speed = clamp_f(p_speed + 0.25, 0.25, 8.0); dirty_title = true; },

                        // ── Diffuse weight  d / f ──────────────────────────
                        c.SDLK_d => { p_diffuse_weight = clamp_f(p_diffuse_weight - 0.05, 0.0, 1.0); dirty_title = true; },
                        c.SDLK_f => { p_diffuse_weight = clamp_f(p_diffuse_weight + 0.05, 0.0, 1.0); dirty_title = true; },

                        // ── Reset / clear ──────────────────────────────────
                        c.SDLK_r => {
                            p_speed          = 1.5;
                            p_sensor_dist    = 9.0;
                            p_sensor_angle   = 0.436;
                            p_turn_speed     = 0.3;
                            p_deposit        = 5.0;
                            p_decay          = 0.012;
                            p_diffuse_weight = 0.2;
                            current_scheme   = .amber;
                            clear_trail();
                            init_agents();
                            dirty_title = true;
                        },
                        c.SDLK_c => { clear_trail(); },

                        else => {},
                    }
                },
                else => {},
            }
        }

        if (!paused) {
            step_agents();
            diffuse_and_decay();
        }

        render_pixels();

        _ = c.SDL_UpdateTexture(texture, null, &pixels, WIN_W * 4);
        _ = c.SDL_RenderClear(renderer);
        _ = c.SDL_RenderCopy(renderer, texture, null, null);
        c.SDL_RenderPresent(renderer);

        if (dirty_title) {
            update_title(window);
            dirty_title = false;
        }
    }
}
