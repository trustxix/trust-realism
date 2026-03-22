-- Trust Realism — Ballistics Framework for Teardown v2 Multiplayer
-- https://github.com/trustxix/trust-realism
-- Include in weapon mods: #include "lib/ballistics.lua"
--
-- Features:
--   - Configurable per-weapon damage profiles
--   - Exponential distance falloff with full-power close range zone
--   - Decoupled hole size vs penetration depth (Shoot + MakeHole)
--   - Material resistance (pellets less effective vs metal, more vs wood)
--   - Uniform disk spread (sqrt distribution — no center stacking)
--   - GetPlayerAimInfo-based aiming (shoots where crosshair points)
--   - 100% server-side, MP-safe (Shoot auto-syncs)
--
-- Usage:
--   local shotgun = CreateBallisticsProfile({
--       damage = 28, pellets = 24, spread = 0.07,
--       range = 50, toolId = "my-shotgun",
--       holeScale = 0.5, penScale = 1.0,
--       fullRange = 8, halfRange = 25, minFalloff = 0.15,
--   })
--
--   -- In server.tickPlayer, when player fires:
--   shotgun:Fire(muzzlePos, aimDir, p)
--
--   -- Or let it handle aiming from a muzzle offset:
--   shotgun:FireFromTool(toolBody, muzzleOffset, p)

-- ============================================================
-- Default material properties table
-- ============================================================
-- Each material has:
--   mult  = base damage multiplier (1.0 = normal, <1 = resistant, >1 = fragile)
--   range = effective range in meters (full damage within this distance,
--           rapid falloff beyond — must be this close to penetrate)
--
-- Example: metal has mult=0.3 and range=3 — even at point blank you only
-- do 30% damage, and beyond 3m you can barely scratch it.

DEFAULT_MATERIAL_PROPERTIES = {
	--               mult   range   notes
	glass        = { 1.5,   40 },  -- shatters from far away
	foliage      = { 1.8,   45 },  -- no resistance at any distance
	plaster      = { 1.3,   30 },  -- drywall, crumbles easily
	dirt         = { 1.2,   30 },  -- soft ground
	plastic      = { 1.1,   25 },  -- thin plastic
	wood         = { 1.0,   20 },  -- baseline: splinters but holds, effective at medium range
	ice          = { 0.9,   18 },  -- slightly harder than wood
	masonry      = { 0.6,   10 },  -- brick: need to be fairly close
	rock         = { 0.5,    8 },  -- stone: close range only
	hardmasonry  = { 0.35,   6 },  -- reinforced concrete: very close
	metal        = { 0.3,    3 },  -- steel plate: point blank only
	heavymetal   = { 0.15,   2 },  -- thick steel: literally touching it
	hardmetal    = { 0.1,    1 },  -- hardened steel: almost impervious
	unphysical   = { 1.0,   50 },  -- non-physical, no resistance
}

-- ============================================================
-- Caliber registry — define ammo types once, reuse everywhere
-- ============================================================
-- A caliber defines the ballistic properties of ammunition.
-- Weapons reference a caliber by name and inherit all its properties.
-- Per-weapon overrides still work — they take priority over the caliber.
--
-- Usage:
--   RegisterCaliber("12gauge", { damage = 28, pellets = 12, spread = 0.07, ... })
--   local gun = CreateBallisticsProfile({ caliber = "12gauge", toolId = "my-shotgun" })
--
-- The weapon inherits everything from 12gauge but can override:
--   local gun = CreateBallisticsProfile({ caliber = "12gauge", spread = 0.1, toolId = "sawed-off" })

CALIBER_REGISTRY = {}

function RegisterCaliber(name, props)
	CALIBER_REGISTRY[name] = props
end

function GetCaliber(name)
	return CALIBER_REGISTRY[name]
end

-- ============================================================
-- Built-in calibers
-- ============================================================

RegisterCaliber("12gauge", {
	damage      = 28,
	pellets     = 12,
	spread      = 0.07,
	range       = 50,
	bulletType  = "bullet",
	fullRange   = 8,
	halfRange   = 25,
	minFalloff  = 0.15,
	holeScale   = 0.5,
	penScale    = 1.0,
	pushScale   = 0.15,   -- shotgun pellets nudge objects, don't launch them
	materials   = {
		glass     = { 1.8,  40 },
		wood      = { 1.2,  18 },
		masonry   = { 0.5,   8 },
		metal     = { 0.2,   3 },
		heavymetal= { 0.1,   2 },
	},
})

RegisterCaliber("9mm", {
	damage      = 20,
	pellets     = 1,
	spread      = 0.025,
	range       = 50,
	bulletType  = "bullet",
	fullRange   = 10,
	halfRange   = 30,
	minFalloff  = 0.15,
	holeScale   = 0.8,
	penScale    = 0.3,
})

RegisterCaliber("5.56nato", {
	damage      = 35,
	pellets     = 1,
	spread      = 0.015,
	range       = 100,
	bulletType  = "bullet",
	fullRange   = 20,
	halfRange   = 60,
	minFalloff  = 0.25,
	holeScale   = 1.0,
	penScale    = 0.5,
	materials   = {
		wood      = { 1.2,  40 },
		masonry   = { 0.7,  20 },
		metal     = { 0.4,   8 },
		heavymetal= { 0.2,   4 },
	},
})

RegisterCaliber("7.62nato", {
	damage      = 50,
	pellets     = 1,
	spread      = 0.01,
	range       = 120,
	bulletType  = "bullet",
	fullRange   = 25,
	halfRange   = 80,
	minFalloff  = 0.3,
	holeScale   = 1.0,
	penScale    = 1.0,
	materials   = {
		wood      = { 1.3,  50 },
		masonry   = { 0.8,  30 },
		metal     = { 0.5,  12 },
		heavymetal= { 0.3,   6 },
	},
})

RegisterCaliber("50bmg", {
	damage      = 90,
	pellets     = 1,
	spread      = 0,
	range       = 200,
	bulletType  = "bullet",
	fullRange   = 50,
	halfRange   = 150,
	minFalloff  = 0.4,
	holeScale   = 1.2,
	penScale    = 2.5,
	materials   = {
		wood      = { 1.5,  80 },
		masonry   = { 1.0,  50 },
		metal     = { 0.7,  25 },
		heavymetal= { 0.5,  15 },
		hardmetal = { 0.3,   8 },
	},
})

RegisterCaliber("melee", {
	damage      = 60,
	pellets     = 3,
	spread      = 0.2,
	range       = 3,
	bulletType  = "bullet",
	fullRange   = 2,
	halfRange   = 3,
	minFalloff  = 0.5,
	holeScale   = 1.5,
	penScale    = 0.5,
	useMaterials = false,
})

-- ============================================================
-- Profile creation
-- ============================================================

function CreateBallisticsProfile(cfg)
	-- If a caliber is specified, use it as the base and overlay cfg on top
	if cfg.caliber then
		local base = CALIBER_REGISTRY[cfg.caliber]
		if base then
			local merged = {}
			for k, v in pairs(base) do merged[k] = v end
			for k, v in pairs(cfg) do merged[k] = v end
			merged.caliber = nil  -- don't store the lookup key
			cfg = merged
		end
	end
	-- Merge custom material overrides with defaults
	-- Supports both formats:
	--   materials = { metal = { 0.5, 5 } }       -- new: {mult, range}
	--   materials = { metal = 0.5 }               -- legacy: just mult (uses default range)
	local materials = {}
	for k, v in pairs(DEFAULT_MATERIAL_PROPERTIES) do
		materials[k] = { v[1], v[2] }
	end
	if cfg.materials then
		for k, v in pairs(cfg.materials) do
			if type(v) == "table" then
				materials[k] = { v[1], v[2] }
			else
				-- Legacy: just a multiplier, keep default range for this material
				local defRange = (materials[k] and materials[k][2]) or 20
				materials[k] = { v, defRange }
			end
		end
	end

	local profile = {
		-- Damage
		damage       = cfg.damage or 10,        -- base damage per projectile
		pellets      = cfg.pellets or 1,         -- projectiles per shot (1 = rifle, 8+ = shotgun)
		bulletType   = cfg.bulletType or "bullet",-- Shoot() type: "bullet", "rocket", etc.

		-- Range & falloff
		range        = cfg.range or 50,          -- max range in meters
		fullRange    = cfg.fullRange or 5,       -- full damage zone (no falloff within this)
		halfRange    = cfg.halfRange or 20,      -- distance where damage drops to 50%
		minFalloff   = cfg.minFalloff or 0.1,    -- minimum damage multiplier (floor)

		-- Spread (0 = laser, 0.07 = shotgun, 0.15 = wide scatter)
		spread       = cfg.spread or 0,

		-- Hole size vs penetration (decoupled)
		holeScale    = cfg.holeScale or 1.0,     -- Shoot() damage multiplier (controls crater size)
		penScale     = cfg.penScale or 0,        -- extra MakeHole hard penetration (0 = no extra, >0 = punch deeper)

		-- Material resistance
		materials    = materials,                 -- material name -> damage multiplier
		useMaterials = cfg.useMaterials ~= false, -- enabled by default, set false to disable

		-- Physics push (0 = no push, 0.3 = gentle, 1.0 = full Shoot() default)
		pushScale    = cfg.pushScale or 1.0,     -- how much objects get pushed by impacts

		-- Identity
		toolId       = cfg.toolId or "unknown",  -- kill feed attribution
	}
	setmetatable(profile, { __index = BallisticsProfile })
	return profile
end

-- ============================================================
-- Ballistics math
-- ============================================================

BallisticsProfile = {}

--- Get damage multiplier for hitting a specific material at a given distance.
-- Each material has its own effective range — beyond that range, damage drops
-- rapidly even if the base multiplier would normally allow some damage.
-- This models real physics: shotgun pellets can dent metal at point blank
-- but bounce off at 10m.
function BallisticsProfile:GetMaterialMultiplier(shape, hitPos, dist)
	if not self.useMaterials or shape == 0 then return 1.0 end
	local ok, mat = pcall(GetShapeMaterialAtPosition, shape, hitPos)
	if not ok or not mat or mat == "" then return 1.0 end

	local props = self.materials[mat]
	if not props then return 1.0 end

	local mult = props[1]       -- base effectiveness
	local matRange = props[2]   -- effective range for this material

	-- Within material's effective range: full base multiplier
	if dist <= matRange then
		return mult
	end

	-- Beyond effective range: rapid exponential decay
	-- Drops to 10% of base mult at 2x the material's range
	local overDist = dist - matRange
	local matDecay = math.pow(0.1, overDist / matRange)
	return mult * matDecay
end

--- Calculate damage falloff multiplier for a given distance.
-- Returns 1.0 within fullRange, exponential decay after, floored at minFalloff.
function BallisticsProfile:GetFalloff(dist)
	if dist <= self.fullRange then
		return 1.0
	end
	local dropDist = dist - self.fullRange
	local halfDist = self.halfRange - self.fullRange
	if halfDist <= 0 then return self.minFalloff end
	local decay = math.pow(0.5, dropDist / halfDist)
	return math.max(self.minFalloff, decay)
end

--- Generate a random perpendicular vector to a direction.
local function randomPerpendicular(dir)
	local perp = VecNormalize(Vec(
		math.random() * 2 - 1,
		math.random() * 2 - 1,
		math.random() * 2 - 1
	))
	perp = VecNormalize(VecSub(perp, VecScale(dir, VecDot(dir, perp))))
	return perp
end

--- Apply spread to a direction vector using uniform disk distribution.
-- Returns a new direction with random angular offset.
function BallisticsProfile:ApplySpread(baseDir)
	if self.spread <= 0 then return baseDir end
	local perp = randomPerpendicular(baseDir)
	local offset = self.spread * math.sqrt(math.random())
	return VecNormalize(VecAdd(baseDir, VecScale(perp, offset)))
end

-- ============================================================
-- Firing
-- ============================================================

--- Fire a single projectile with falloff, material resistance, decoupled penetration,
--- and controlled physics push. Call on SERVER only. Shoot() auto-syncs to all clients.
function BallisticsProfile:FireProjectile(muzzlePos, dir, p)
	local damage = self.damage / 100

	-- Pre-cast to find distance, shape, and material
	local hit, dist, normal, shape = QueryRaycast(muzzlePos, dir, self.range)
	local falloff = hit and self:GetFalloff(dist) or 1.0
	local finalDamage = damage * falloff

	-- Material resistance: reduce damage based on what was hit AND how far away
	local hitBody = 0
	if hit and shape and shape ~= 0 then
		local hitPos = VecAdd(muzzlePos, VecScale(dir, dist))
		local matMult = self:GetMaterialMultiplier(shape, hitPos, dist)
		finalDamage = finalDamage * matMult
		hitBody = GetShapeBody(shape)
	end

	-- Capture velocity of hit body before Shoot() applies impulse
	local velBefore = nil
	if hit and hitBody ~= 0 and IsBodyDynamic(hitBody) then
		velBefore = GetBodyVelocity(hitBody)
	end

	-- Shoot() with holeScale controls visible crater size
	Shoot(muzzlePos, dir, self.bulletType, finalDamage * self.holeScale, self.range, p, self.toolId)

	-- Physics push correction
	-- Real physics: if a bullet punches THROUGH an object, most energy exits
	-- the other side — the object barely moves. If the bullet STOPS inside
	-- (low damage, hard material, long range), all energy transfers to the object.
	--
	-- penetrationRatio: how much of the pellet's energy went into destroying material
	-- vs passing through. High finalDamage = punches through = low push.
	-- Low finalDamage = stops inside = higher push (up to pushScale cap).
	if velBefore and hitBody ~= 0 and IsBodyDynamic(hitBody) then
		local velAfter = GetBodyVelocity(hitBody)
		local impulse = VecSub(velAfter, velBefore)

		-- How much damage vs the base? High ratio = overpowering the material = pass-through
		local baseDamage = self.damage / 100
		local penetrationRatio = math.min(finalDamage / baseDamage, 1.0)

		-- Invert: high penetration = low push, low penetration = more push
		-- At full power point blank: penetrationRatio ~1.0 → absorbed ~0.05 (5%)
		-- At far range weak hit: penetrationRatio ~0.15 → absorbed ~0.85 (85%)
		local absorbed = 1.0 - penetrationRatio * 0.95

		local effectivePush = self.pushScale * falloff * absorbed
		local reduction = VecScale(impulse, 1.0 - effectivePush)
		SetBodyVelocity(hitBody, VecSub(velAfter, reduction))
	end

	-- Extra penetration via MakeHole (tiny surface, deep core)
	if hit and self.penScale > 0 then
		local hitPos = VecAdd(muzzlePos, VecScale(dir, dist))
		MakeHole(hitPos, 0.01, 0.01, finalDamage * self.penScale)
	end
end

--- Fire all pellets in a spread pattern from a position + direction.
-- Call on SERVER only.
function BallisticsProfile:Fire(muzzlePos, baseDir, p)
	for i = 1, self.pellets do
		local dir = self:ApplySpread(baseDir)
		self:FireProjectile(muzzlePos, dir, p)
	end
end

--- Fire using GetPlayerAimInfo for crosshair-accurate aiming.
-- Provide the tool body handle and muzzle offset vector.
-- Call on SERVER only.
function BallisticsProfile:FireFromTool(toolBody, muzzleOffset, p)
	local toolTrans = GetBodyTransform(toolBody)
	local muzzlePos = TransformToParentPoint(toolTrans, muzzleOffset)
	local aimHit, aimStart, aimEnd, aimDir = GetPlayerAimInfo(muzzlePos, self.range, p)
	self:Fire(muzzlePos, aimDir, p)
end
