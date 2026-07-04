--!strict
-- MaterialsCatalog.luau
-- Extensive catalog of surface material profiles for the dust simulation.
--
-- Each material defines how dust behaves on that surface type - from
-- generation rates and retention to wind resistance and particle size.
-- This catalog is referenced by the simulation engine to determine
-- per-cell dust dynamics based on the underlying road/surface material.
--
-- Materials are indexed by ID for fast lookup during parallel processing.

local Types = require(script.Parent.Types)

local MaterialsCatalog = {}

--===========================================================================
-- Material ID Constants
--===========================================================================

MaterialsCatalog.Ids = {
	Asphalt = 1,
	Concrete = 2,
	DirtRoad = 3,
	Gravel = 4,
	Sand = 5,
	Cobblestone = 6,
	Brick = 7,
	WetAsphalt = 8,
	PackedDirt = 9,
	Clay = 10,
	Grass = 11,
	Sandstone = 12,
	Basalt = 13,
	Granite = 14,
	Limestone = 15,
	Mud = 16,
	DustyConcrete = 17,
	WornAsphalt = 18,
	ConstructionDirt = 19,
	RiverbedSilt = 20,
}

--===========================================================================
-- Material Profiles
--===========================================================================

local PROFILES: { [number]: Types.MaterialProfile } = {}

--[[
	Registers a material profile in the catalog.
]]
local function register(profile: Types.MaterialProfile): ()
	PROFILES[profile.id] = profile
end

-- Asphalt - standard road surface, moderate dust retention
register({
	id = 1,
	name = "Asphalt",
	surfaceRoughness = 0.35,
	dustRetention = 0.45,
	dustGenerationRate = 0.02,
	windResistance = 0.60,
	frictionCoefficient = 0.75,
	color = Color3.fromRGB(45, 45, 48),
	particleSizeMultiplier = 1.0,
})

-- Concrete - smoother, less dust generation
register({
	id = 2,
	name = "Concrete",
	surfaceRoughness = 0.25,
	dustRetention = 0.35,
	dustGenerationRate = 0.015,
	windResistance = 0.50,
	frictionCoefficient = 0.70,
	color = Color3.fromRGB(180, 180, 175),
	particleSizeMultiplier = 0.85,
})

-- Dirt Road - high dust generation, low retention
register({
	id = 3,
	name = "Dirt Road",
	surfaceRoughness = 0.80,
	dustRetention = 0.20,
	dustGenerationRate = 0.12,
	windResistance = 0.15,
	frictionCoefficient = 0.55,
	color = Color3.fromRGB(120, 90, 60),
	particleSizeMultiplier = 1.5,
})

-- Gravel - very high dust generation
register({
	id = 4,
	name = "Gravel",
	surfaceRoughness = 0.90,
	dustRetention = 0.15,
	dustGenerationRate = 0.18,
	windResistance = 0.10,
	frictionCoefficient = 0.65,
	color = Color3.fromRGB(130, 125, 120),
	particleSizeMultiplier = 1.8,
})

-- Sand - extreme dust, minimal retention
register({
	id = 5,
	name = "Sand",
	surfaceRoughness = 0.95,
	dustRetention = 0.05,
	dustGenerationRate = 0.25,
	windResistance = 0.05,
	frictionCoefficient = 0.40,
	color = Color3.fromRGB(210, 185, 140),
	particleSizeMultiplier = 2.0,
})

-- Cobblestone - moderate dust, high roughness
register({
	id = 6,
	name = "Cobblestone",
	surfaceRoughness = 0.70,
	dustRetention = 0.50,
	dustGenerationRate = 0.06,
	windResistance = 0.45,
	frictionCoefficient = 0.68,
	color = Color3.fromRGB(100, 95, 90),
	particleSizeMultiplier = 1.2,
})

-- Brick - moderate dust, textured surface
register({
	id = 7,
	name = "Brick",
	surfaceRoughness = 0.65,
	dustRetention = 0.40,
	dustGenerationRate = 0.05,
	windResistance = 0.40,
	frictionCoefficient = 0.62,
	color = Color3.fromRGB(150, 75, 55),
	particleSizeMultiplier = 1.1,
})

-- Wet Asphalt - suppressed dust due to moisture
register({
	id = 8,
	name = "Wet Asphalt",
	surfaceRoughness = 0.30,
	dustRetention = 0.80,
	dustGenerationRate = 0.005,
	windResistance = 0.70,
	frictionCoefficient = 0.45,
	color = Color3.fromRGB(30, 30, 33),
	particleSizeMultiplier = 0.6,
})

-- Packed Dirt - moderate dust, higher retention than loose dirt
register({
	id = 9,
	name = "Packed Dirt",
	surfaceRoughness = 0.60,
	dustRetention = 0.35,
	dustGenerationRate = 0.08,
	windResistance = 0.25,
	frictionCoefficient = 0.60,
	color = Color3.fromRGB(110, 80, 55),
	particleSizeMultiplier = 1.3,
})

-- Clay - high retention, low generation when dry
register({
	id = 10,
	name = "Clay",
	surfaceRoughness = 0.45,
	dustRetention = 0.65,
	dustGenerationRate = 0.04,
	windResistance = 0.55,
	frictionCoefficient = 0.50,
	color = Color3.fromRGB(170, 120, 90),
	particleSizeMultiplier = 0.9,
})

-- Grass - very low dust, high wind resistance from vegetation
register({
	id = 11,
	name = "Grass",
	surfaceRoughness = 0.50,
	dustRetention = 0.70,
	dustGenerationRate = 0.008,
	windResistance = 0.85,
	frictionCoefficient = 0.48,
	color = Color3.fromRGB(60, 120, 50),
	particleSizeMultiplier = 0.7,
})

-- Sandstone - high dust, moderate retention
register({
	id = 12,
	name = "Sandstone",
	surfaceRoughness = 0.75,
	dustRetention = 0.30,
	dustGenerationRate = 0.14,
	windResistance = 0.20,
	frictionCoefficient = 0.58,
	color = Color3.fromRGB(200, 165, 120),
	particleSizeMultiplier = 1.6,
})

-- Basalt - low dust, very hard surface
register({
	id = 13,
	name = "Basalt",
	surfaceRoughness = 0.40,
	dustRetention = 0.50,
	dustGenerationRate = 0.01,
	windResistance = 0.65,
	frictionCoefficient = 0.78,
	color = Color3.fromRGB(50, 50, 55),
	particleSizeMultiplier = 0.8,
})

-- Granite - very low dust, extremely hard
register({
	id = 14,
	name = "Granite",
	surfaceRoughness = 0.35,
	dustRetention = 0.45,
	dustGenerationRate = 0.008,
	windResistance = 0.60,
	frictionCoefficient = 0.80,
	color = Color3.fromRGB(140, 135, 130),
	particleSizeMultiplier = 0.75,
})

-- Limestone - moderate dust, soft rock
register({
	id = 15,
	name = "Limestone",
	surfaceRoughness = 0.55,
	dustRetention = 0.40,
	dustGenerationRate = 0.07,
	windResistance = 0.35,
	frictionCoefficient = 0.65,
	color = Color3.fromRGB(220, 215, 200),
	particleSizeMultiplier = 1.0,
})

-- Mud - very high retention, zero generation when wet
register({
	id = 16,
	name = "Mud",
	surfaceRoughness = 0.85,
	dustRetention = 0.90,
	dustGenerationRate = 0.002,
	windResistance = 0.75,
	frictionCoefficient = 0.35,
	color = Color3.fromRGB(80, 55, 35),
	particleSizeMultiplier = 1.4,
})

-- Dusty Concrete - concrete with accumulated dust layer
register({
	id = 17,
	name = "Dusty Concrete",
	surfaceRoughness = 0.30,
	dustRetention = 0.25,
	dustGenerationRate = 0.09,
	windResistance = 0.30,
	frictionCoefficient = 0.68,
	color = Color3.fromRGB(160, 155, 145),
	particleSizeMultiplier = 1.1,
})

-- Worn Asphalt - degraded road, higher dust than fresh asphalt
register({
	id = 18,
	name = "Worn Asphalt",
	surfaceRoughness = 0.55,
	dustRetention = 0.30,
	dustGenerationRate = 0.06,
	windResistance = 0.40,
	frictionCoefficient = 0.65,
	color = Color3.fromRGB(70, 68, 70),
	particleSizeMultiplier = 1.15,
})

-- Construction Dirt - loose soil from construction sites
register({
	id = 19,
	name = "Construction Dirt",
	surfaceRoughness = 0.88,
	dustRetention = 0.10,
	dustGenerationRate = 0.22,
	windResistance = 0.08,
	frictionCoefficient = 0.50,
	color = Color3.fromRGB(140, 105, 70),
	particleSizeMultiplier = 1.9,
})

-- Riverbed Silt - fine particles, very high dust potential
register({
	id = 20,
	name = "Riverbed Silt",
	surfaceRoughness = 0.92,
	dustRetention = 0.08,
	dustGenerationRate = 0.20,
	windResistance = 0.06,
	frictionCoefficient = 0.42,
	color = Color3.fromRGB(155, 140, 110),
	particleSizeMultiplier = 2.1,
})

--===========================================================================
-- API
--===========================================================================

--[[
	Returns the material profile for the given ID, or a default if not found.
]]
function MaterialsCatalog.getProfile(materialId: number): Types.MaterialProfile
	local profile = PROFILES[materialId]
	if profile then
		return profile
	end
	-- Return asphalt as default fallback
	return PROFILES[1] :: Types.MaterialProfile
end

--[[
	Returns all registered material profiles as an array.
]]
function MaterialsCatalog.getAllProfiles(): { Types.MaterialProfile }
	local profiles = {}
	for _, profile in pairs(PROFILES) do
		table.insert(profiles, profile)
	end
	return profiles
end

--[[
	Returns the dust generation rate for a material at a given disturbance level.
	Disturbance amplifies generation rate non-linearly.
]]
function MaterialsCatalog.getEffectiveGenerationRate(materialId: number, disturbance: number): number
	local profile = MaterialsCatalog.getProfile(materialId)
	-- Non-linear: more disturbance = disproportionately more dust
	return profile.dustGenerationRate * (1.0 + (disturbance * disturbance * 3.0))
end

--[[
	Returns the effective wind resistance for a material, factoring in
	its surface roughness as a turbulence modifier.
]]
function MaterialsCatalog.getEffectiveWindResistance(materialId: number): number
	local profile = MaterialsCatalog.getProfile(materialId)
	-- Rougher surfaces create more turbulence, slightly reducing effective resistance
	return profile.windResistance * (1.0 - (profile.surfaceRoughness * 0.15))
end

--[[
	Returns the settling rate for dust on a given material.
	Higher retention = faster settling. Lower retention = dust stays airborne.
]]
function MaterialsCatalog.getSettlingRate(materialId: number): number
	local profile = MaterialsCatalog.getProfile(materialId)
	return profile.dustRetention * 0.05 -- 5% of retention per tick
end

--[[
	Returns the particle size for a given material, optionally modified
	by a global scale factor.
]]
function MaterialsCatalog.getParticleSize(materialId: number, scale: number?): number
	local profile = MaterialsCatalog.getProfile(materialId)
	return profile.particleSizeMultiplier * (scale or 1.0)
end

--[[
	Returns the color associated with a material for visualization.
]]
function MaterialsCatalog.getColor(materialId: number): Color3
	local profile = MaterialsCatalog.getProfile(materialId)
	return profile.color
end

--[[
	Returns the number of registered materials.
]]
function MaterialsCatalog.getCount(): number
	local count = 0
	for _ in pairs(PROFILES) do
		count += 1
	end
	return count
end

--[[
	Returns true if a material with the given ID exists.
]]
function MaterialsCatalog.exists(materialId: number): boolean
	return PROFILES[materialId] ~= nil
end

return MaterialsCatalog