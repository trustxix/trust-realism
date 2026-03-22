-- Realistic Ballistics Framework for Teardown v2 Multiplayer
-- Include this in weapon mods: #include "lib/ballistics.lua"
--
-- Features:
--   - Configurable per-weapon damage profiles
--   - Exponential distance falloff with full-power close range zone
--   - Decoupled hole size vs penetration depth (Shoot + MakeHole)
--   - Uniform disk spread (sqrt distribution — no center stacking)
--   - GetPlayerAimInfo-based aiming (shoots where crosshair points)
--   - 100% server-side, MP-safe (Shoot auto-syncs)
--
-- Usage:
--   local shotgun = CreateBallisticsProfile({
--       damage = 28, pellets = 24, spread = 0.07,
--       range = 50, toolId = "my-shotgun",
--       holeScale = 0.5, penetrationScale = 1.0,
--       fullRange = 8, halfRange = 25, minFalloff = 0.15,
--   })
--
--   -- In server.tickPlayer, when player fires:
--   shotgun:Fire(muzzlePos, aimDir, p)
--
--   -- Or let it handle aiming from a muzzle offset:
--   shotgun:FireFromTool(toolBody, muzzleOffset, p)

-- ============================================================
-- Profile creation
-- ============================================================

function CreateBallisticsProfile(cfg)
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

--- Fire a single projectile with falloff and decoupled penetration.
-- Call on SERVER only. Shoot() auto-syncs to all clients.
function BallisticsProfile:FireProjectile(muzzlePos, dir, p)
	local damage = self.damage / 100

	-- Pre-cast to find distance for custom falloff
	local hit, dist = QueryRaycast(muzzlePos, dir, self.range)
	local falloff = hit and self:GetFalloff(dist) or 1.0
	local finalDamage = damage * falloff

	-- Shoot() with holeScale controls visible crater size
	Shoot(muzzlePos, dir, self.bulletType, finalDamage * self.holeScale, self.range, p, self.toolId)

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
