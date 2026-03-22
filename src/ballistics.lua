-- Trust Realism -- Ballistics Framework for Teardown v2 Multiplayer
-- https://github.com/trustxix/trust-realism
-- Include in weapon mods: #include "lib/ballistics.lua"
-- @lint-ok-file HANDLE-GT-ZERO
-- @lint-ok-file MISSING-VERSION2
--
-- Features:
--   - Configurable per-weapon damage profiles
--   - Exponential distance falloff with full-power close range zone
--   - Decoupled hole size vs penetration depth (Shoot + MakeHole)
--   - Material resistance (pellets less effective vs metal, more vs wood)
--   - Uniform disk spread (sqrt distribution -- no center stacking)
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
--           rapid falloff beyond -- must be this close to penetrate)
--
-- Example: metal has mult=0.3 and range=3 -- even at point blank you only
-- do 30% damage, and beyond 3m you can barely scratch it.

DEFAULT_MATERIAL_PROPERTIES = {
	--               mult   range  ricochet?  notes
	glass        = { 1.5,   40 },  --         shatters, no ricochet
	foliage      = { 1.8,   45 },  --         absorbs, no ricochet
	plaster      = { 1.3,   30 },  --         crumbles, no ricochet
	dirt         = { 1.2,   30 },  --         absorbs, no ricochet
	plastic      = { 1.1,   25 },  --         absorbs, no ricochet
	wood         = { 1.0,   20 },  --         splinters, no ricochet
	ice          = { 0.9,   18 },  --         cracks, slight ricochet
	masonry      = { 0.6,   10 },  --         chips, can ricochet
	rock         = { 0.5,    8 },  --         deflects at angles
	hardmasonry  = { 0.35,   6 },  --         strong ricochet
	metal        = { 0.3,    3 },  --         classic ricochet surface
	heavymetal   = { 0.15,   2 },  --         strong ricochet
	hardmetal    = { 0.1,    1 },  --         strongest ricochet
	unphysical   = { 1.0,   50 },  --         no ricochet
}

-- Materials that can ricochet (hard surfaces only)
-- Value = ricochet efficiency (0-1): how well the material deflects
-- Higher = cleaner bounce with more retained energy
DEFAULT_RICOCHET_MATERIALS = {
	ice          = 0.3,   -- weak deflection, mostly shatters
	masonry      = 0.4,   -- brick chips but can deflect at shallow angles
	rock         = 0.6,   -- stone, good deflection
	hardmasonry  = 0.7,   -- reinforced concrete, strong
	metal        = 0.85,  -- steel, classic ricochet
	heavymetal   = 0.9,   -- thick steel, very clean bounce
	hardmetal    = 0.95,  -- hardened steel, nearly perfect reflection
}

-- ============================================================
-- Barrel presets (convenience -- use with barrelLength/choke)
-- ============================================================
BARREL_PRESETS = {
	sawed_off   = { length = 0.25, choke = 0 },    -- widest spread, shortest range
	tactical    = { length = 0.45, choke = 0.3 },   -- moderate spread, medium range
	standard    = { length = 0.5,  choke = 0.5 },   -- balanced
	hunting     = { length = 0.7,  choke = 0.8 },   -- tight pattern, long range
	competition = { length = 0.75, choke = 1.0 },   -- tightest pattern, longest range
	rifle       = { length = 0.6,  choke = 0.9 },   -- rifle barrel (nearly no spread)
	pistol      = { length = 0.12, choke = 0 },     -- short, no choke
	smg         = { length = 0.25, choke = 0.2 },   -- compact, slight choke
}

--- Helper: apply a barrel preset to a config table
function ApplyBarrelPreset(cfg, presetName)
	local preset = BARREL_PRESETS[presetName]
	if preset then
		cfg.barrelLength = preset.length
		cfg.choke = preset.choke
	end
	return cfg
end

-- ============================================================
-- Ammo subtype registry
-- ============================================================
-- Ammo subtypes are variants of a caliber with different properties.
-- The caliber is the base, the ammo type modifies specific fields.
--
-- Usage:
--   RegisterAmmoType("12gauge", "slug", { pellets = 1, damage = 80, spread = 0.01, penScale = 2.0 })
--   local gun = CreateBallisticsProfile({ caliber = "12gauge", ammoType = "slug", toolId = "my-gun" })
--
-- Runtime switching (for weapons that support multiple ammo types):
--   profile:SetAmmoType("slug")  -- re-applies caliber base + new ammo overrides

AMMO_TYPE_REGISTRY = {}

function RegisterAmmoType(caliber, name, overrides)
	if not AMMO_TYPE_REGISTRY[caliber] then
		AMMO_TYPE_REGISTRY[caliber] = {}
	end
	AMMO_TYPE_REGISTRY[caliber][name] = overrides
end

function GetAmmoType(caliber, name)
	return AMMO_TYPE_REGISTRY[caliber] and AMMO_TYPE_REGISTRY[caliber][name]
end

-- Built-in 12gauge ammo subtypes
RegisterAmmoType("12gauge", "buckshot", {})  -- default, no overrides needed

RegisterAmmoType("12gauge", "slug", {
	pellets = 1, damage = 80, spread = 0.01,
	penScale = 2.0, pushScale = 0.6,
	maxPenetrations = 3, penRetain = 0.55,
	damageVariance = 0.03,
	holeScale = 1.5,
	muzzleFlashSize = 0.7, muzzleSmokeSize = 3.0,
})

RegisterAmmoType("12gauge", "birdshot", {
	pellets = 40, damage = 5, spread = 0.12,
	range = 25, fullRange = 4, halfRange = 12, minFalloff = 0.05,
	penScale = 0, pushScale = 0.05,
	maxPenetrations = 1, maxRicochets = 0,
	damageVariance = 0.2,
	holeScale = 0.3,
})

RegisterAmmoType("12gauge", "ap", {
	pellets = 8, damage = 35, spread = 0.05,
	penScale = 2.5, pushScale = 0.1,
	maxPenetrations = 3, penRetain = 0.5,
	materials = { metal = { 0.7, 15 }, heavymetal = { 0.5, 8 }, hardmetal = { 0.3, 4 } },
})

-- ============================================================
-- Caliber registry -- define ammo types once, reuse everywhere
-- ============================================================
-- A caliber defines the ballistic properties of ammunition.
-- Weapons reference a caliber by name and inherit all its properties.
-- Per-weapon overrides still work -- they take priority over the caliber.
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
	pushScale   = 0.15,
	maxPenetrations = 2,
	penRetain   = 0.35,
	damageVariance = 0.15,
	maxRicochets = 1,
	ricochetRetain = 0.25,
	ricochetScatter = 0.08,
	soundVolume = 0.8,    -- loud boom
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
	maxPenetrations = 2,  -- can pass through drywall, thin wood
	penRetain   = 0.3,    -- 30% energy retained
	damageVariance = 0.08, -- +/-8% (factory ammo, fairly consistent)
	maxRicochets = 1,     -- one bounce
	ricochetRetain = 0.3,  -- 30% retained (jacketed round, cleaner bounce than buckshot)
	ricochetScatter = 0.04,
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
	maxPenetrations = 3,  -- high velocity, passes through multiple thin surfaces
	penRetain   = 0.45,   -- 45% retained -- tumbles but keeps going
	damageVariance = 0.05, -- +/-5% (military spec, tight tolerance)
	maxRicochets = 2,     -- two bounces (high velocity, maintains trajectory)
	ricochetRetain = 0.35,
	ricochetScatter = 0.03, -- tight scatter (pointed bullet, predictable deflection)
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
	maxPenetrations = 3,  -- heavy round, punches through walls
	penRetain   = 0.5,    -- 50% retained -- keeps most energy
	damageVariance = 0.05, -- +/-5% (military spec)
	maxRicochets = 2,
	ricochetRetain = 0.4,  -- heavy round keeps more energy on bounce
	ricochetScatter = 0.03,
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
	maxPenetrations = 4,  -- anti-material, goes through almost anything
	penRetain   = 0.6,    -- 60% retained -- massive energy reserve
	damageVariance = 0.03, -- +/-3% (match-grade precision)
	maxRicochets = 2,
	ricochetRetain = 0.45, -- massive round, lots of energy on bounce
	ricochetScatter = 0.02, -- very predictable deflection
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

BallisticsProfile = {}

function CreateBallisticsProfile(cfg)
	-- If a caliber is specified, use it as the base and overlay cfg on top
	local caliberName = cfg.caliber
	if caliberName then
		local base = CALIBER_REGISTRY[caliberName]
		if base then
			local merged = {}
			for k, v in pairs(base) do merged[k] = v end
			-- Apply ammo subtype overrides (between caliber base and per-weapon overrides)
			if cfg.ammoType and cfg.ammoType ~= "" then
				local ammoOverrides = GetAmmoType(caliberName, cfg.ammoType)
				if ammoOverrides then
					for k, v in pairs(ammoOverrides) do merged[k] = v end
				end
			end
			-- Per-weapon overrides take final priority
			for k, v in pairs(cfg) do merged[k] = v end
			merged.caliber = nil
			merged.ammoType = cfg.ammoType  -- preserve for runtime switching
			merged._caliberName = caliberName -- preserve for runtime switching
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

	-- Merge ricochet materials
	local ricochetMats = {}
	for k, v in pairs(DEFAULT_RICOCHET_MATERIALS) do
		ricochetMats[k] = v
	end
	if cfg.ricochetMaterials then
		for k, v in pairs(cfg.ricochetMaterials) do
			ricochetMats[k] = v
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

		-- Barrel & choke (optional -- if set, overrides spread/range/fullRange)
		-- barrelLength in meters: 0.25 = sawed-off, 0.5 = tactical, 0.7 = hunting
		-- choke 0-1: 0 = cylinder (no choke, wide), 1 = full choke (tight pattern)
		barrelLength = cfg.barrelLength or nil,
		choke        = cfg.choke or nil,

		-- Hole size vs penetration (decoupled)
		holeScale    = cfg.holeScale or 1.0,     -- Shoot() damage multiplier (controls crater size)
		penScale     = cfg.penScale or 0,        -- extra MakeHole hard penetration (0 = no extra, >0 = punch deeper)

		-- Material resistance
		materials    = materials,                 -- material name -> damage multiplier
		useMaterials = cfg.useMaterials ~= false, -- enabled by default, set false to disable

		-- Physics push (0 = no push, 0.3 = gentle, 1.0 = full Shoot() default)
		pushScale    = cfg.pushScale or 1.0,     -- how much objects get pushed by impacts

		-- Overpenetration (pass-through)
		maxPenetrations = cfg.maxPenetrations or 1,  -- max surfaces to pass through (1 = stops at first hit)
		penRetain    = cfg.penRetain or 0.4,     -- energy retained after each pass-through (exponential)

		-- Per-pellet variance (0 = uniform, 0.15 = +/-15% randomized damage)
		damageVariance = cfg.damageVariance or 0,

		-- Ricochet
		ricochetAngle   = cfg.ricochetAngle or 45,    -- max incidence angle in degrees for ricochet (0=never, 90=always)
		ricochetRetain  = cfg.ricochetRetain or 0.3,   -- energy retained after bounce (exponential per bounce)
		ricochetScatter = cfg.ricochetScatter or 0.05, -- random scatter added to reflection (imperfect bounce)
		maxRicochets    = cfg.maxRicochets or 0,       -- max bounces (0 = no ricochet, backward compatible)
		ricochetMats    = ricochetMats,                -- material name -> ricochet efficiency (0-1)

		-- Sound
		sounds       = cfg.sounds or nil,        -- { fire = "path", reload = "path", empty = "path" }
		impactSounds = cfg.impactSounds or nil,   -- { metal = "path", wood = "path", ... }
		soundVolume  = cfg.soundVolume or 0.75,   -- base volume for fire sound
		_soundHandles = {},                       -- loaded handles (populated by InitSounds)
		_impactHandles = {},                      -- loaded impact handles
		_soundsReady = false,                     -- true after InitSounds() called

		-- Visual effects
		muzzleFlash  = cfg.muzzleFlash ~= false,  -- enable muzzle flash (default true)
		muzzleFlashSize = cfg.muzzleFlashSize or 0.5, -- fire particle size
		muzzleSmokeSize = cfg.muzzleSmokeSize or 2.5, -- smoke particle size
		muzzleLightIntensity = cfg.muzzleLightIntensity or 0.5, -- PointLight intensity at muzzle
		muzzleLightDuration = cfg.muzzleLightDuration or 0.05,  -- how long muzzle light lasts (seconds)
		impactParticles = cfg.impactParticles ~= false, -- enable impact particles (default true)
		impactParticleSize = cfg.impactParticleSize or 0.3, -- impact smoke size

		-- Per-material impact effects (what spawns when a pellet hits)
		materialEffects = cfg.materialEffects or nil, -- { metal = "spark", wood = "splinter", ... }

		-- Identity
		toolId       = cfg.toolId or "unknown",  -- kill feed attribution
	}
	-- Barrel & choke derivation: physical properties override manual spread/range
	if profile.barrelLength and profile.choke then
		local bl = profile.barrelLength
		local ch = profile.choke
		-- Longer barrel = tighter spread, more range, more full-power zone
		-- More choke = tighter spread, slightly more full-power zone
		-- Base spread of 0.12 is a cylinder-bore sawed-off (worst case)
		profile.spread = 0.12 * (1.0 - ch * 0.7) / (bl * 2.0)
		profile.range = profile.range * bl * 1.5
		profile.fullRange = profile.fullRange * (1.0 + ch * 0.5) * (bl / 0.5)
		profile.halfRange = profile.halfRange * (1.0 + ch * 0.3) * (bl / 0.5)
	end

	setmetatable(profile, { __index = BallisticsProfile })
	return profile
end

-- ============================================================
-- Sound system
-- ============================================================

-- Default impact sound paths per material (mods override with their own paths)
-- Set to empty table by default -- mods provide their own sound files via impactSounds config.
-- The framework only loads sounds that the mod explicitly provides.
DEFAULT_IMPACT_SOUNDS = {}

--- Initialize sound handles. Call in BOTH server.init() and client.init().
-- Server needs fire sound for PlaySound() auto-sync.
-- Client needs impact sounds for ClientCall handling.
function BallisticsProfile:InitSounds()
	if self._soundsReady then return end

	-- Load fire/reload/empty sounds
	if self.sounds then
		for key, path in pairs(self.sounds) do
			if path and path ~= "" then
				self._soundHandles[key] = LoadSound(path)
			end
		end
	end

	-- Load impact sounds (merge defaults with overrides)
	local impactPaths = {}
	for k, v in pairs(DEFAULT_IMPACT_SOUNDS) do impactPaths[k] = v end
	if self.impactSounds then
		for k, v in pairs(self.impactSounds) do impactPaths[k] = v end
	end
	for mat, path in pairs(impactPaths) do
		if path and path ~= "" then
			local ok, handle = pcall(LoadSound, path)
			if ok and handle then
				self._impactHandles[mat] = handle
			end
		end
	end

	self._soundsReady = true
	_BALLISTICS_ACTIVE_PROFILE = self
end

--- Play the fire sound at a position. Called automatically by Fire/FireFromTool.
-- Uses PlaySound() on server = auto-syncs to all clients.
function BallisticsProfile:PlayFireSound(pos)
	if self._soundHandles.fire then
		PlaySound(self._soundHandles.fire, pos, self.soundVolume)
	end
end

--- Play impact sound for a material at a position via ClientCall.
-- Called automatically by FireProjectile on hit.
function BallisticsProfile:PlayImpactSound(matName, hitPos)
	local handle = self._impactHandles[matName]
	if handle then
		-- PlaySound on server auto-syncs positional audio to all clients
		PlaySound(handle, hitPos, self.soundVolume * 0.5)
	end
end

-- ============================================================
-- Visual effects system
-- ============================================================
-- Effects are client-only (SpawnParticle, PointLight). The server triggers them
-- via ClientCall(0, ...) so all clients see the same effects at the same positions.
-- This follows base game MP pattern: ClientCall(0) for world-visible events.

-- Default material -> particle type mapping
DEFAULT_MATERIAL_EFFECTS = {
	metal       = { particle = "smoke",     size = 0.15, color = {1, 0.8, 0.3} },  -- sparky
	heavymetal  = { particle = "smoke",     size = 0.15, color = {1, 0.8, 0.3} },
	hardmetal   = { particle = "smoke",     size = 0.1,  color = {1, 0.7, 0.2} },
	wood        = { particle = "smoke",     size = 0.2,  color = {0.8, 0.7, 0.5} }, -- dusty
	glass       = { particle = "smoke",     size = 0.25, color = {1, 1, 1} },        -- white dust
	masonry     = { particle = "smoke",     size = 0.3,  color = {0.7, 0.65, 0.6} }, -- brick dust
	rock        = { particle = "smoke",     size = 0.25, color = {0.6, 0.6, 0.6} },  -- grey dust
	hardmasonry = { particle = "smoke",     size = 0.25, color = {0.65, 0.6, 0.55} },
	plaster     = { particle = "smoke",     size = 0.35, color = {0.9, 0.9, 0.85} }, -- white cloud
	dirt        = { particle = "smoke",     size = 0.3,  color = {0.5, 0.4, 0.3} },  -- brown dust
	foliage     = { particle = "smoke",     size = 0.15, color = {0.4, 0.6, 0.3} },  -- green bits
	plastic     = { particle = "smoke",     size = 0.15, color = {0.8, 0.8, 0.8} },
}

--- Spawn muzzle flash effect. Called by Fire() via ClientCall(0).
-- CLIENT-SIDE ONLY -- this function is called by the client handler.
function BallisticsProfile:SpawnMuzzleFlash(pos)
	if not self.muzzleFlash then return end
	SpawnParticle("fire", pos, Vec(0, 1.0 + math.random() * 0.5, 0), self.muzzleFlashSize, 0.15)
	SpawnParticle("darksmoke", pos, Vec(0, 0.8 + math.random() * 0.3, 0), self.muzzleSmokeSize * 0.3, 2.0)
end

--- Spawn impact effect for a material at a position.
-- CLIENT-SIDE ONLY -- called by the client handler.
function BallisticsProfile:SpawnImpactEffect(matName, hitPos)
	if not self.impactParticles then return end

	-- Check for custom material effects first, then defaults
	local fx = (self.materialEffects and self.materialEffects[matName])
		or DEFAULT_MATERIAL_EFFECTS[matName]

	if fx then
		local vel = Vec(0, 0.5 + math.random() * 0.5, 0)
		SpawnParticle(fx.particle, hitPos, vel, fx.size * self.impactParticleSize / 0.3, 1.0)
	else
		-- Fallback: generic smoke puff
		SpawnParticle("smoke", hitPos, Vec(0, 0.5, 0), self.impactParticleSize, 1.0)
	end
end

--- Client-side handler for ballistics effects. Mod must register this:
--   function client.ballisticsEffect(effectType, x, y, z, matName)
--       _ballisticsEffectHandler(effectType, x, y, z, matName)
--   end
-- Or use RegisterBallisticsEffectHandler() for automatic setup.
function _ballisticsEffectHandler(effectType, x, y, z, matName)
	local pos = Vec(x, y, z)
	-- Find the active profile (stored globally by InitSounds)
	local profile = _BALLISTICS_ACTIVE_PROFILE
	if not profile then return end

	if effectType == "muzzle" then
		profile:SpawnMuzzleFlash(pos)
		if profile.muzzleLightIntensity > 0 then
			PointLight(pos, 1, 0.8, 0.5, profile.muzzleLightIntensity)
		end
	elseif effectType == "impact" then
		profile:SpawnImpactEffect(matName or "", pos)
	end
end

--- Register the active profile for client-side effect handling.
-- Call in InitSounds() automatically.
_BALLISTICS_ACTIVE_PROFILE = nil

-- ============================================================
-- Server context guard
-- ============================================================
-- All firing functions MUST run on the server. If called from client context,
-- the damage won't sync and you get desync. This guard catches the mistake
-- at runtime with a clear error instead of silent breakage.
--
-- Detection: try calling a server-only function (SetToolAmmo with dummy args).
-- On client, it silently fails or errors. We use a simpler approach: track
-- which context we're in via a flag set by the mod's server/client callbacks.

_BALLISTICS_SERVER_CONTEXT = false

--- Call at the start of server.tick to enable firing functions.
function BallisticsServerTick()
	_BALLISTICS_SERVER_CONTEXT = true
end

--- Call at the start of client.tick to disable firing functions.
function BallisticsClientTick()
	_BALLISTICS_SERVER_CONTEXT = false
end

local function assertServer(funcName)
	if not _BALLISTICS_SERVER_CONTEXT then
		DebugPrint("[Trust Realism] ERROR: " .. funcName .. "() called outside server context! "
			.. "All firing must happen in server.tickPlayer. This WILL cause desync. "
			.. "Add BallisticsServerTick() to server.tick and BallisticsClientTick() to client.tick.")
		return true
	end
	return false
end

-- ============================================================
-- Ballistics math
-- ============================================================

--- Switch ammo type at runtime. Rebuilds the profile from caliber base + new ammo overrides.
-- Call on SERVER only. Preserves per-weapon overrides and sound handles.
function BallisticsProfile:SetAmmoType(ammoName)
	local caliberName = self._caliberName
	if not caliberName then return end

	local base = CALIBER_REGISTRY[caliberName]
	if not base then return end

	-- Rebuild: caliber base -> ammo overrides -> keep identity/sounds
	local ammoOverrides = GetAmmoType(caliberName, ammoName) or {}
	local keepFields = { toolId = self.toolId, sounds = self.sounds, impactSounds = self.impactSounds,
		_soundHandles = self._soundHandles, _impactHandles = self._impactHandles,
		_soundsReady = self._soundsReady, _caliberName = caliberName,
		barrelLength = self.barrelLength, choke = self.choke }

	for k, v in pairs(base) do self[k] = v end
	for k, v in pairs(ammoOverrides) do self[k] = v end
	for k, v in pairs(keepFields) do self[k] = v end
	self.ammoType = ammoName
end

--- Get damage multiplier for hitting a specific material at a given distance.
-- Each material has its own effective range -- beyond that range, damage drops
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
--- controlled physics push, and overpenetration (pass-through).
--- Call on SERVER only. Shoot() auto-syncs to all clients.
--- @param muzzlePos vec Origin point
--- @param dir vec Direction (normalized)
--- @param p number Player ID
--- @param _energy number|nil Internal: remaining energy (nil = full power, used for recursive pass-through)
--- @param _depth number|nil Internal: current penetration depth (nil = 0, used to cap recursion)
--- @param _totalDist number|nil Internal: total distance traveled from original muzzle (for falloff)
--- @param _ricochetCount number|nil Internal: number of ricochets so far
function BallisticsProfile:FireProjectile(muzzlePos, dir, p, _energy, _depth, _totalDist, _ricochetCount)
	if assertServer("FireProjectile") then return end
	local depth = _depth or 0
	local totalDist = _totalDist or 0
	local baseDamage = self.damage / 100
	local damage = _energy or baseDamage

	-- Per-pellet variance: randomize on initial shot only (not pass-throughs)
	if depth == 0 and self.damageVariance > 0 then
		local v = self.damageVariance
		damage = damage * (1.0 + (math.random() * 2 - 1) * v)
	end

	-- Pre-cast to find distance, shape, and material
	local hit, dist, normal, shape = QueryRaycast(muzzlePos, dir, self.range)
	local falloff = hit and self:GetFalloff(totalDist + (dist or 0)) or 1.0
	local finalDamage = damage * falloff

	-- Material resistance: reduce damage based on what was hit AND how far away
	local hitBody = 0
	local matMult = 1.0
	local hitMatName = ""
	if hit and shape and shape ~= 0 then
		local hitPos = VecAdd(muzzlePos, VecScale(dir, dist))
		matMult = self:GetMaterialMultiplier(shape, hitPos, totalDist + dist)
		finalDamage = finalDamage * matMult
		hitBody = GetShapeBody(shape)
		-- Capture material name for impact sounds and ricochet
		local ok, m = pcall(GetShapeMaterialAtPosition, shape, hitPos)
		if ok and m then hitMatName = m end
	end

	-- Capture velocity of hit body before Shoot() applies impulse
	local velBefore = nil
	if hit and hitBody ~= 0 and IsBodyDynamic(hitBody) then
		velBefore = GetBodyVelocity(hitBody)
	end

	-- Shoot() with holeScale controls visible crater size
	Shoot(muzzlePos, dir, self.bulletType, finalDamage * self.holeScale, self.range, p, self.toolId)

	-- Impact sound + particles (only on initial hits and first pass-through, not every recursion)
	if hit and depth <= 1 and hitMatName ~= "" then
		local hitPos = VecAdd(muzzlePos, VecScale(dir, dist))
		if self._soundsReady then
			self:PlayImpactSound(hitMatName, hitPos)
		end
		if self.impactParticles then
			ClientCall(0, "client.ballisticsEffect", "impact", hitPos[1], hitPos[2], hitPos[3], hitMatName)
		end
	end

	-- Physics push correction
	if velBefore and hitBody ~= 0 and IsBodyDynamic(hitBody) then
		local velAfter = GetBodyVelocity(hitBody)
		local impulse = VecSub(velAfter, velBefore)

		local penetrationRatio = math.min(finalDamage / baseDamage, 1.0)
		local absorbed = math.pow(0.05, penetrationRatio)

		local effectivePush = self.pushScale * falloff * absorbed
		local reduction = VecScale(impulse, 1.0 - effectivePush)
		SetBodyVelocity(hitBody, VecSub(velAfter, reduction))
	end

	-- Extra penetration via MakeHole (tiny surface, deep core)
	if hit and self.penScale > 0 then
		local hitPos = VecAdd(muzzlePos, VecScale(dir, dist))
		MakeHole(hitPos, 0.01, 0.01, finalDamage * self.penScale)
	end

	-- Continuation: ricochet OR overpenetration (mutually exclusive per hit)
	-- Decision: shallow angle + hard material = ricochet, steep angle = overpenetrate
	if hit then
		local hitPos = VecAdd(muzzlePos, VecScale(dir, dist))
		local minUsefulDamage = baseDamage * 0.05

		-- Check ricochet conditions
		local didRicochet = false
		if self.maxRicochets > 0 and (_ricochetCount or 0) < self.maxRicochets and normal then
			-- Incidence angle: 0 deg = head-on (no ricochet), 90 deg = parallel (perfect ricochet)
			local cosAngle = math.abs(VecDot(dir, normal))
			local incidenceAngle = 90 - math.deg(math.acos(math.min(cosAngle, 1.0)))

			-- Check if material can ricochet (reuse hitMatName from earlier)
			local ricochetEff = self.ricochetMats[hitMatName] or 0

			-- Ricochet triggers at shallow angles on hard surfaces
			if incidenceAngle <= self.ricochetAngle and ricochetEff > 0 then
				-- Reflect direction: dir - 2 * dot(dir, normal) * normal
				local dotDN = VecDot(dir, normal)
				local reflectDir = VecSub(dir, VecScale(normal, 2 * dotDN))

				-- Add scatter (imperfect reflection)
				if self.ricochetScatter > 0 then
					local perp = randomPerpendicular(reflectDir)
					local scatter = self.ricochetScatter * math.random()
					reflectDir = VecNormalize(VecAdd(reflectDir, VecScale(perp, scatter)))
				end

				-- Energy after bounce: base retain * material efficiency * angle factor
				-- Shallower angles retain more energy (grazing = clean deflection)
				local angleFactor = 1.0 - (incidenceAngle / self.ricochetAngle) * 0.5
				local bounceEnergy = finalDamage * self.ricochetRetain * ricochetEff * angleFactor

				if bounceEnergy > minUsefulDamage then
					local bouncePos = VecAdd(hitPos, VecScale(reflectDir, 0.05))
					self:FireProjectile(bouncePos, reflectDir, p, bounceEnergy,
						depth, totalDist + dist, (_ricochetCount or 0) + 1)
					didRicochet = true
				end
			end
		end

		-- Overpenetration: only if we didn't ricochet
		if not didRicochet and depth < self.maxPenetrations - 1 then
			local remainingEnergy = finalDamage * self.penRetain

			if remainingEnergy > minUsefulDamage then
				local exitPos = VecAdd(hitPos, VecScale(dir, 0.15))
				self:FireProjectile(exitPos, dir, p, remainingEnergy,
					depth + 1, totalDist + dist, _ricochetCount)
			end
		end
	end
end

--- Fire all pellets in a spread pattern from a position + direction.
-- Plays fire sound once (not per pellet). Call on SERVER only.
function BallisticsProfile:Fire(muzzlePos, baseDir, p)
	if assertServer("Fire") then return end
	-- Fire sound: once per shot, PlaySound on server auto-syncs to all clients
	if self._soundsReady then
		self:PlayFireSound(muzzlePos)
	end

	-- Muzzle flash: ClientCall(0) tells all clients to spawn particles at muzzle
	if self.muzzleFlash then
		ClientCall(0, "client.ballisticsEffect", "muzzle", muzzlePos[1], muzzlePos[2], muzzlePos[3], "")
	end

	for i = 1, self.pellets do
		local dir = self:ApplySpread(baseDir)
		self:FireProjectile(muzzlePos, dir, p)
	end
end

--- Fire using GetPlayerAimInfo for crosshair-accurate aiming.
-- Provide the tool body handle and muzzle offset vector.
-- Call on SERVER only.
function BallisticsProfile:FireFromTool(toolBody, muzzleOffset, p)
	if assertServer("FireFromTool") then return end
	local toolTrans = GetBodyTransform(toolBody)
	local muzzlePos = TransformToParentPoint(toolTrans, muzzleOffset)
	local aimHit, aimStart, aimEnd, aimDir = GetPlayerAimInfo(muzzlePos, self.range, p)
	self:Fire(muzzlePos, aimDir, p)
end
