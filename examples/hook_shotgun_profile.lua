-- Example: Hook Shotgun weapon profile using Trust Realism
-- This is extracted from the Hook_Shotgun mod to show how the framework is used.

#include "lib/ballistics.lua"

local MUZZLE_OFFSET = Vec(0.35, -0.6, -2.1)

-- Define the shotgun profile
local shotgunProfile = CreateBallisticsProfile({
	damage      = 28,      -- base damage per pellet (divided by 100 internally)
	pellets     = 24,      -- pellets per shot
	spread      = 0.07,    -- cone spread (sqrt distribution for uniform fill)
	range       = 50,      -- max range in meters
	toolId      = "cresta-hookshotgun",

	-- Decoupled visuals vs penetration
	holeScale   = 0.5,     -- small visible craters (half Shoot damage)
	penScale    = 1.0,     -- full penetration punch-through (MakeHole hard)

	-- Custom falloff curve
	fullRange   = 8,       -- 0-8m: no falloff (devastating close range)
	halfRange   = 25,      -- 50% damage at 25m
	minFalloff  = 0.15,    -- 15% floor at max range
})

-- In server.tickPlayer, when the player fires:
function server.tickPlayer(p, dt)
	if InputPressed("usetool", p) then
		local b = GetToolBody(p)
		if b ~= 0 then
			-- One line fires 24 pellets, aimed at crosshair, with full ballistics
			shotgunProfile:FireFromTool(b, MUZZLE_OFFSET, p)
		end
	end
end
