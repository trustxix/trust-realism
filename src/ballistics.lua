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
-- Default material resistance table
-- ============================================================
-- Multiplier on damage/penetration when hitting this material.
-- < 1.0 = less effective (pellets bounce off / barely scratch)
-- = 1.0 = normal effectiveness
-- > 1.0 = more effective (pellets tear through easily)

DEFAULT_MATERIAL_RESISTANCE = {
	glass        = 1.5,   -- shatters easily
	foliage      = 1.8,   -- leaves and branches, no resistance
	plaster      = 1.3,   -- drywall, crumbles
	dirt          = 1.2,   -- soft ground
	plastic      = 1.1,   -- thin plastic
	wood         = 1.0,   -- baseline material
	ice          = 0.9,   -- slightly harder than wood
	masonry      = 0.6,   -- brick, significant resistance
	rock         = 0.5,   -- stone, hard to penetrate
	hardmasonry  = 0.35,  -- reinforced concrete
	metal        = 0.25,  -- steel plate, very resistant
	heavymetal   = 0.15,  -- thick steel, barely scratched
	hardmetal    = 0.1,   -- hardened steel, almost impervious
	unphysical   = 1.0,   -- default for non-physical
}

-- ============================================================
-- Profile creation
-- ============================================================

function CreateBallisticsProfile(cfg)
	-- Merge custom material overrides with defaults
	local materials = {}
	for k, v in pairs(DEFAULT_MATERIAL_RESISTANCE) do
		materials[k] = v
	end
	if cfg.materials then
		for k, v in pairs(cfg.materials) do
			materials[k] = v
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

--- Get damage multiplier for hitting a specific material.
-- Returns a value from the materials table, or 1.0 if unknown.
function BallisticsProfile:GetMaterialMultiplier(shape, hitPos)
	if not self.useMaterials or shape == 0 then return 1.0 end
	local ok, mat = pcall(GetShapeMaterialAtPosition, shape, hitPos)
	if not ok or not mat or mat == "" then return 1.0 end
	return self.materials[mat] or 1.0
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

--- Fire a single projectile with falloff, material resistance, and decoupled penetration.
-- Call on SERVER only. Shoot() auto-syncs to all clients.
function BallisticsProfile:FireProjectile(muzzlePos, dir, p)
	local damage = self.damage / 100

	-- Pre-cast to find distance, shape, and material
	local hit, dist, normal, shape = QueryRaycast(muzzlePos, dir, self.range)
	local falloff = hit and self:GetFalloff(dist) or 1.0
	local finalDamage = damage * falloff

	-- Material resistance: reduce damage against hard materials
	if hit and shape and shape ~= 0 then
		local hitPos = VecAdd(muzzlePos, VecScale(dir, dist))
		local matMult = self:GetMaterialMultiplier(shape, hitPos)
		finalDamage = finalDamage * matMult
	end

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
