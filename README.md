# Trust Realism

A realistic weapon and tool behavior framework for Teardown v2 multiplayer mods.

Trust Realism replaces the fragile, copy-pasted damage code found in most Teardown weapon mods with a single shared library. Define a weapon profile once, fire with one function call. The framework handles damage, penetration, spread, distance falloff, and multiplayer sync — all server-side, zero desync.

## Why

Every Teardown weapon mod reinvents the wheel. Some use `Shoot()`, some use `QueryShot` + `ApplyPlayerDamage` + `MakeHole`, some roll their own projectile physics. The results are inconsistent — weapons that feel different for no reason, desync bugs in multiplayer, and damage code scattered across hundreds of files with no way to tune globally.

Trust Realism fixes this by providing:

- **One library** that every weapon includes
- **Configurable profiles** that define how each weapon behaves
- **Realistic ballistics** — exponential distance falloff, decoupled hole size vs penetration, natural spread patterns
- **MP-safe by design** — server-side only, uses `Shoot()` for auto-sync, no RPC needed
- **One line to fire** — `weapon:FireFromTool(toolBody, muzzleOffset, player)`

## Quick Start

### 1. Copy into your mod

```
your_mod/
  lib/
    ballistics.lua    <-- copy src/ballistics.lua here
  main.lua
  info.txt
```

### 2. Include it

```lua
#version 2
#include "script/include/player.lua"
#include "lib/ballistics.lua"
```

### 3. Define your weapon

```lua
local myGun = CreateBallisticsProfile({
    damage     = 35,       -- base damage per projectile
    pellets    = 1,        -- 1 for rifles, 8+ for shotguns
    spread     = 0.02,     -- cone angle (0 = laser accurate)
    range      = 100,      -- max range in meters
    toolId     = "my-gun", -- kill feed attribution

    -- Falloff curve
    fullRange  = 15,       -- full damage within this distance (meters)
    halfRange  = 60,       -- damage drops to 50% at this distance
    minFalloff = 0.2,      -- damage never drops below 20%

    -- Hole size vs penetration (decoupled)
    holeScale  = 1.0,      -- visible crater multiplier
    penScale   = 0.5,      -- extra penetration depth (0 = Shoot only)
})
```

### 4. Fire it

```lua
function server.tickPlayer(p, dt)
    if InputPressed("usetool", p) then
        myGun:FireFromTool(GetToolBody(p), Vec(0, -0.5, -1.5), p)
        PlaySound(fireSound, GetPlayerTransform(p).pos, 0.75)
    end
end
```

That's it. The framework handles aiming (crosshair-accurate via `GetPlayerAimInfo`), spread (uniform disk distribution), falloff (exponential decay), terrain damage (`Shoot` + `MakeHole`), player damage (with kill attribution), and multiplayer sync (auto-synced to all clients).

## How It Works

### Firing Pipeline

```
FireFromTool(toolBody, muzzleOffset, player)
  |
  +-- GetPlayerAimInfo(muzzlePos, range, player)  --> crosshair-accurate aim direction
  |
  +-- Fire(muzzlePos, aimDir, player)
      |
      +-- for each pellet:
          |
          +-- ApplySpread(baseDir)                --> uniform disk distribution (sqrt random)
          |
          +-- FireProjectile(muzzlePos, dir, player)
              |
              +-- QueryRaycast(pos, dir, range)   --> get distance for falloff
              |
              +-- GetFalloff(distance)            --> exponential decay curve
              |
              +-- Shoot(pos, dir, type,           --> small craters + player damage
              |         damage * holeScale,        + bullet trace + MP sync
              |         range, player, toolId)
              |
              +-- MakeHole(hitPos, 0.01, 0.01,    --> extra penetration depth
                          damage * penScale)       (tiny surface, deep core)
```

### Distance Falloff

The falloff uses an exponential decay curve with a configurable full-power zone:

```
Damage %
100% |================
     |                ==
 75% |                  ====
     |                      ====
 50% |........................========  <-- halfRange
     |                              ========
 25% |                                      ====
min% |______________________________________________============
     0m    fullRange        halfRange        range
```

- **0 to fullRange:** 100% damage. No dropoff at all. Close range is devastating.
- **fullRange to halfRange:** Smooth exponential decay. Matches real-world ballistic curves.
- **Beyond halfRange:** Continues decaying but never drops below `minFalloff`.

### Spread Distribution

Pellet spread uses `sqrt(random)` to fill the cone uniformly:

- **Linear random** clusters pellets at the center (small radii have less area)
- **Squared random** makes it worse (nearly all pellets at center)
- **Sqrt random** corrects for area — every point in the cone is equally likely

This gives a natural, even shotgun pattern: no dead center stacking, consistent damage across the blast.

### Decoupled Holes vs Penetration

Most Teardown mods use `Shoot()` which ties hole size to penetration. Trust Realism decouples them:

| `holeScale` | `penScale` | Result |
|-------------|-----------|--------|
| 1.0 | 0 | Normal Shoot() behavior |
| 0.5 | 1.0 | Small craters but punches through walls |
| 2.0 | 0 | Large craters, no extra penetration |
| 0.3 | 2.0 | Tiny holes, massive penetration (armor piercing) |

This is done by firing `Shoot()` at reduced damage (small hole) and then `MakeHole()` at the same hit point with tiny surface radii but a large hard radius (deep penetration).

## Profile Reference

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `damage` | number | 10 | Base damage per projectile (divided by 100 internally) |
| `pellets` | number | 1 | Projectiles per shot |
| `bulletType` | string | "bullet" | Shoot() type |
| `range` | number | 50 | Max range in meters |
| `fullRange` | number | 5 | Full damage zone (meters) |
| `halfRange` | number | 20 | 50% damage distance (meters) |
| `minFalloff` | number | 0.1 | Minimum damage multiplier |
| `spread` | number | 0 | Cone spread angle (0 = laser) |
| `holeScale` | number | 1.0 | Shoot() damage multiplier (crater size) |
| `penScale` | number | 0 | Extra MakeHole penetration (0 = none) |
| `toolId` | string | "unknown" | Kill feed attribution |

## API

### `CreateBallisticsProfile(config)` -> profile

Create a weapon profile. All config fields are optional with sensible defaults.

### `profile:FireFromTool(toolBody, muzzleOffset, player)`

Fire all pellets from the tool's muzzle, aimed at the player's crosshair. This is the primary function — handles everything.

### `profile:Fire(position, direction, player)`

Fire all pellets from a position in a direction. Use for turrets, drones, or custom aim.

### `profile:FireProjectile(position, direction, player)`

Fire a single projectile. Use for beam weapons (call per-tick) or manual control.

### `profile:GetFalloff(distance)` -> number

Get the damage multiplier (0-1) for a distance. Use for HUD indicators or custom logic.

### `profile:ApplySpread(direction)` -> direction

Apply random spread to a direction. Returns a new direction vector.

## Example Profiles

```lua
-- Pump-action shotgun: devastating close, useless far
CreateBallisticsProfile({
    damage = 28, pellets = 24, spread = 0.07,
    range = 50, fullRange = 8, halfRange = 25, minFalloff = 0.15,
    holeScale = 0.5, penScale = 1.0, toolId = "shotgun",
})

-- Assault rifle: accurate, effective at medium range
CreateBallisticsProfile({
    damage = 35, pellets = 1, spread = 0.015,
    range = 100, fullRange = 20, halfRange = 60, minFalloff = 0.25,
    holeScale = 1.0, penScale = 0.3, toolId = "assault-rifle",
})

-- Sniper: long range, high penetration
CreateBallisticsProfile({
    damage = 80, pellets = 1, spread = 0,
    range = 200, fullRange = 50, halfRange = 150, minFalloff = 0.4,
    holeScale = 0.8, penScale = 2.0, toolId = "sniper",
})

-- SMG: low damage, high fire rate, spray pattern
CreateBallisticsProfile({
    damage = 8, pellets = 1, spread = 0.04,
    range = 40, fullRange = 5, halfRange = 20, minFalloff = 0.1,
    holeScale = 0.6, penScale = 0, toolId = "smg",
})

-- Melee slash: short range, wide arc
CreateBallisticsProfile({
    damage = 60, pellets = 3, spread = 0.2,
    range = 3, fullRange = 2, halfRange = 3, minFalloff = 0.5,
    holeScale = 1.5, penScale = 0.5, toolId = "sword",
})
```

## Multiplayer Safety

Trust Realism is designed for Teardown v2 multiplayer from the ground up:

- **Server-side only.** All firing happens in `server.tickPlayer`. No client-side damage code.
- **Shoot() for sync.** Terrain damage, bullet traces, and player damage auto-replicate to all clients.
- **No RPC.** Zero ServerCall/ClientCall for firing. No per-tick state sync.
- **No shared data conflicts.** The framework doesn't touch `players[p]` data — it's stateless per shot.
- **Kill attribution.** `toolId` in every `Shoot()` call feeds the kill feed correctly.

## Roadmap

Trust Realism currently covers ballistics (v1.0). Planned expansions:

| Version | Module | What It Covers |
|---------|--------|---------------|
| v1.0 | Ballistics | Damage, penetration, spread, falloff (current) |
| v2.0 | Effects | Muzzle flash, impact particles, tracer styles |
| v3.0 | Audio | Fire/reload/impact sounds with distance attenuation |
| v4.0 | Ammo | Magazine + reserve, reload timing, conservative reload |
| v5.0 | Physics | Recoil profiles, weapon weight, sway, ADS zoom |
| v6.0 | Tools | Non-weapon tool profiles (hooks, welders, cutters, scanners) |

The goal: every tool in Teardown feels finely tuned, realistic, and consistent — with one shared framework controlling it all.

## Part Of

Trust Realism is developed as part of the [Teardown MP Patches](https://github.com/trustxix/teardown-mp-patches) project, which patches 100+ workshop mods for multiplayer compatibility.

## License

[The Unlicense](UNLICENSE) — public domain. Use it however you want.
