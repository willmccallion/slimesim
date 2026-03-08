# slimemold

Physarum polycephalum slime mold simulation — 200k agents, real-time, interactive.

![slime mold simulation](assets/slime.png)

Built with Zig + SDL2.

## Build

**Dependencies:** Zig 0.15, SDL2

```sh
make run       # build ReleaseFast and launch
make build     # debug build
make release   # ReleaseFast without running
```

Or with `pbuild` / `zig build run -Doptimize=ReleaseFast` directly.

## Controls

| Key | Action |
|-----|--------|
| `1`–`6` | Colour scheme (Amber, Plasma, Acid Green, Deep Ocean, Lava, Greyscale) |
| `[` / `]` | Decay slower / faster |
| `,` / `.` | Sensor distance shorter / longer |
| `;` / `'` | Turn speed down / up |
| `-` / `=` | Agent speed down / up |
| `D` / `F` | Diffuse weight down / up |
| `R` | Full reset (params + trail + agents) |
| `C` | Clear trail (agents keep going) |
| `P` | Pause / resume |
| `Escape` | Quit |

## How it works

Each agent moves forward, depositing a trail. Before each step it samples the trail at three forward-facing sensor positions and steers toward the strongest signal. The trail diffuses (3×3 box blur) and decays each frame, producing the characteristic network patterns.
