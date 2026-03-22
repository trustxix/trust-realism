# Realistic Ballistics Framework

> **Source:** `lib/realistic_ballistics.lua`
> **Deploy:** Copy to each weapon mod as `lib/ballistics.lua`
> **Created:** 2026-03-22 — extracted from Hook_Shotgun refactor
> **Status:** v1.0 — covers firearms, expanding to all tools

---

## Purpose

A shared, MP-safe framework that replaces all inline weapon damage code across every mod. Instead of each mod copy-pasting its own MakeHole/QueryShot/ApplyPlayerDamage chains (which are error-prone, desync-prone, and inconsistent), every weapon uses this framework.

**One include. One profile. One function call.**

---

## Architecture

```
CreateBallisticsProfile(config)
    ├── :Fire(pos, dir, player)           -- fire all pellets with spread
    │   └── :FireProjectile(pos, dir, p)  -- single projectile
    │       ├── QueryRaycast → distance   -- pre-cast for custom falloff
    │       ├── :GetFalloff(dist)         -- exponential decay curve
    │       ├── Shoot() × holeScale       -- visual holes + player damage + MP sync
    │       └── MakeHole() × penScale     -- extra penetration depth
    └── :FireFromTool(body, offset, p)    -- auto-aims at crosshair via GetPlayerAimInfo
        └── :Fire(muzzlePos, aimDir, p)
```

### Why This Works in MP
- `Shoot()` auto-syncs terrain destruction, player damage, and bullet traces to all clients
- `MakeHole()` auto-syncs terrain modification to all clients
- `QueryRaycast()` is server-side only (pre-cast for falloff calculation)
- All firing happens in `server.tickPlayer` — server owns all damage
- No ClientCall, no RPC, no shared state needed for the firing itself

---

## API Reference

### CreateBallisticsProfile(config)

Creates a weapon profile. All fields have defaults.

```lua
local weapon = CreateBallisticsProfile({
    -- Damage
    damage     = 28,        -- base damage per projectile (divided by 100 internally)
    pellets    = 24,        -- projectiles per shot (1 = rifle, 8+ = shotgun)
    bulletType = "bullet",  -- Shoot() type

    -- Range & falloff
    range      = 50,        -- max range in meters
    fullRange  = 8,         -- full damage zone (no falloff within this distance)
    halfRange  = 25,        -- distance where damage drops to 50%
    minFalloff = 0.15,      -- minimum damage multiplier floor

    -- Spread
    spread     = 0.07,      -- cone angle (0 = laser, 0.07 = shotgun, 0.15 = scatter)

    -- Decoupled hole size vs penetration
    holeScale  = 0.5,       -- Shoot() damage multiplier (controls visible crater)
    penScale   = 1.0,       -- extra MakeHole hard penetration (0 = no extra)

    -- Identity
    toolId     = "my-gun",  -- kill feed attribution
})
```

### profile:FireFromTool(toolBody, muzzleOffset, player)

**The primary fire function.** Aims at the player's crosshair (via GetPlayerAimInfo), fires all pellets with spread from the muzzle position. Call on SERVER only.

```lua
-- In server.tickPlayer:
if InputPressed("usetool", p) then
    weapon:FireFromTool(GetToolBody(p), Vec(0, -0.5, -1.5), p)
end
```

### profile:Fire(position, direction, player)

Fire all pellets from a position in a direction. Use when you have custom aim logic (e.g., turrets, drones).

### profile:FireProjectile(position, direction, player)

Fire a single projectile. Use for beam weapons (call per-tick) or manual iteration.

### profile:GetFalloff(distance)

Returns the damage multiplier (0 to 1) for a given distance. Use for HUD damage indicators or custom logic.

### profile:ApplySpread(direction)

Returns a direction with random angular offset applied. Uses sqrt(random) uniform disk distribution.

---

## Falloff Curve

```
Damage %
100% |████████████████
     |                ██
 75% |                  ████
     |                      ████
 50% |........................████████  ← halfRange
     |                              ████████
 25% |                                      ████
min% |______________________________________________████████████
     0m    fullRange        halfRange        range
```

- **0 to fullRange:** 100% damage, no dropoff. Devastating close range.
- **fullRange to halfRange:** Exponential decay. Smooth, realistic ballistic curve.
- **Beyond halfRange:** Continues decaying toward minFalloff floor.
- **minFalloff:** Pellets never go below this multiplier, even at max range.

---

## Weapon Profile Examples

### Shotgun (Hook_Shotgun)
```lua
CreateBallisticsProfile({
    damage = 28, pellets = 24, spread = 0.07,
    range = 50, fullRange = 8, halfRange = 25, minFalloff = 0.15,
    holeScale = 0.5, penScale = 1.0, toolId = "cresta-hookshotgun",
})
```

### Assault Rifle
```lua
CreateBallisticsProfile({
    damage = 35, pellets = 1, spread = 0.015,
    range = 100, fullRange = 20, halfRange = 60, minFalloff = 0.25,
    holeScale = 1.0, penScale = 0.3, toolId = "assault-rifle",
})
```

### Sniper Rifle
```lua
CreateBallisticsProfile({
    damage = 80, pellets = 1, spread = 0,
    range = 200, fullRange = 50, halfRange = 150, minFalloff = 0.4,
    holeScale = 0.8, penScale = 2.0, toolId = "sniper",
})
```

### SMG / Minigun
```lua
CreateBallisticsProfile({
    damage = 8, pellets = 1, spread = 0.04,
    range = 40, fullRange = 5, halfRange = 20, minFalloff = 0.1,
    holeScale = 0.6, penScale = 0, toolId = "smg",
})
```

### Melee Weapon (short range slash)
```lua
CreateBallisticsProfile({
    damage = 60, pellets = 3, spread = 0.2,
    range = 3, fullRange = 2, halfRange = 3, minFalloff = 0.5,
    holeScale = 1.5, penScale = 0.5, toolId = "sword",
})
```

---

## Roadmap — Future Expansion

### v2.0: Visual Effects Profiles
```lua
effects = {
    muzzleFlash = { particle = "fire", size = 0.5, duration = 0.15 },
    impactSmoke = { particle = "darksmoke", size = 0.3 },
    tracerStyle = "bullet",  -- or "laser", "none"
}
```

### v3.0: Audio Profiles
```lua
audio = {
    fireSound = "MOD/snd/fire.ogg",
    reloadSound = "MOD/snd/reload.ogg",
    impactSound = "MOD/snd/impact.ogg",
    volume = 0.75,
}
```

### v4.0: Ammo & Magazine System
```lua
ammo = {
    magazineSize = 8,
    reserveDefault = 32,
    reloadTime = 1.5,
    conservativeReload = true,  -- only use shells needed
}
```

### v5.0: Tool Physics
```lua
physics = {
    recoilKick = 2.4,
    recoilRotation = 24,
    weight = 1.0,          -- affects sway
    adsZoom = 1.5,          -- aim-down-sights magnification
}
```

### v6.0: Non-Weapon Tools
```lua
-- Grappling hook profile
hook = CreateToolProfile({
    type = "hook",
    range = 50,
    cooldown = 2.0,
    pullForce = 120,
    attachTo = "static",  -- or "dynamic", "both"
})

-- Welding tool profile
welder = CreateToolProfile({
    type = "beam",
    range = 5,
    damagePerSecond = 0,
    repairRate = 10,
    effectColor = {0.2, 0.6, 1.0},
})
```

---

## Deployment

To add the framework to a mod:

1. Create `lib/` directory in the mod folder
2. Copy `lib/realistic_ballistics.lua` → mod's `lib/ballistics.lua`
3. Add `#include "lib/ballistics.lua"` to main.lua (after player.lua)
4. Define a profile with `CreateBallisticsProfile({...})`
5. Replace all inline Shoot/MakeHole/QueryShot/ApplyPlayerDamage with `profile:FireFromTool()`
6. Run `python -m tools.lint --mod "ModName"` to verify
