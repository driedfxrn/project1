--!strict
-- VehicularDisturbance.luau
-- Extensive catalog of vehicle profiles for dust disturbance simulation.
--
-- Each vehicle type defines how it kicks up dust - from tire width and
-- weight to disturbance radius and particle emission rates. The simulation
-- engine uses these profiles when vehicles traverse the grid to calculate
-- disturbance events and particle emissions.
--
-- This catalog models real-world vehicle physics for accurate dust behavior.

local Types = require(script.Parent.Types)

local VehicularDisturbance = {}

--===========================================================================
-- Vehicle ID Constants
--===========================================================================

VehicularDisturbance.Ids = {
	Sedan = 1,
	SUV = 2,
	PickupTruck = 3,
	SemiTruck = 4,
	Motorcycle = 5,
	Bus = 6,
	Van = 7,
	SportsCar = 8,
	DumpTruck = 9,
	ConcreteMixer = 10,
	Bulldozer = 11,
	Excavator = 12,
	Forklift = 13,
	Bicycle = 14,
	Scooter = 15,
	ThreeWheeler = 16,
	TukTuk = 17,
	Cart = 18,
	Tank = 19,
	Tractor = 20,
}

--===========================================================================
-- Vehicle Profiles
--===========================================================================

local PROFILES: { [number]: Types.VehicleProfile } = {}

local function register(profile: Types.VehicleProfile): ()
	PROFILES[profile.id] = profile
end

-- Sedan - standard car, moderate disturbance
register({
	id = 1,
	name = "Sedan",
	weight = 1500,
	speed = 50,
	tireWidth = 0.2,
	disturbanceRadius = 3.0,
	disturbanceForce = 0.3,
	particleEmissionRate = 5,
	maxEmissionHeight = 2.0,
	dustKickMultiplier = 1.0,
})

-- SUV - heavier, wider tires
register({
	id = 2,
	name = "SUV",
	weight = 2200,
	speed = 45,
	tireWidth = 0.25,
	disturbanceRadius = 3.5,
	disturbanceForce = 0.4,
	particleEmissionRate = 7,
	maxEmissionHeight = 2.5,
	dustKickMultiplier = 1.3,
})

-- Pickup Truck - utility vehicle, high dust
register({
	id = 3,
	name = "Pickup Truck",
	weight = 2500,
	speed = 40,
	tireWidth = 0.28,
	disturbanceRadius = 4.0,
	disturbanceForce = 0.5,
	particleEmissionRate = 10,
	maxEmissionHeight = 3.0,
	dustKickMultiplier = 1.6,
})

-- Semi Truck - massive disturbance
register({
	id = 4,
	name = "Semi Truck",
	weight = 15000,
	speed = 35,
	tireWidth = 0.45,
	disturbanceRadius = 6.0,
	disturbanceForce = 0.8,
	particleEmissionRate = 20,
	maxEmissionHeight = 4.5,
	dustKickMultiplier = 2.5,
})

-- Motorcycle - narrow tires, high speed disturbance
register({
	id = 5,
	name = "Motorcycle",
	weight = 200,
	speed = 60,
	tireWidth = 0.1,
	disturbanceRadius = 2.0,
	disturbanceForce = 0.2,
	particleEmissionRate = 3,
	maxEmissionHeight = 1.5,
	dustKickMultiplier = 0.7,
})

-- Bus - large vehicle, significant disturbance
register({
	id = 6,
	name = "Bus",
	weight = 12000,
	speed = 30,
	tireWidth = 0.4,
	disturbanceRadius = 5.5,
	disturbanceForce = 0.7,
	particleEmissionRate = 15,
	maxEmissionHeight = 4.0,
	dustKickMultiplier = 2.2,
})

-- Van - delivery vehicle
register({
	id = 7,
	name = "Van",
	weight = 3500,
	speed = 40,
	tireWidth = 0.3,
	disturbanceRadius = 4.0,
	disturbanceForce = 0.45,
	particleEmissionRate = 8,
	maxEmissionHeight = 3.0,
	dustKickMultiplier = 1.4,
})

-- Sports Car - low clearance, high speed
register({
	id = 8,
	name = "Sports Car",
	weight = 1300,
	speed = 80,
	tireWidth = 0.22,
	disturbanceRadius = 3.0,
	disturbanceForce = 0.35,
	particleEmissionRate = 6,
	maxEmissionHeight = 1.5,
	dustKickMultiplier = 1.1,
})

-- Dump Truck - construction, extreme dust
register({
	id = 9,
	name = "Dump Truck",
	weight = 20000,
	speed = 25,
	tireWidth = 0.5,
	disturbanceRadius = 7.0,
	disturbanceForce = 0.9,
	particleEmissionRate = 25,
	maxEmissionHeight = 5.0,
	dustKickMultiplier = 3.0,
})

-- Concrete Mixer - heavy, slow, high disturbance
register({
	id = 10,
	name = "Concrete Mixer",
	weight = 18000,
	speed = 20,
	tireWidth = 0.48,
	disturbanceRadius = 6.5,
	disturbanceForce = 0.85,
	particleEmissionRate = 22,
	maxEmissionHeight = 4.5,
	dustKickMultiplier = 2.8,
})

-- Bulldozer - tracked vehicle, extreme ground disturbance
register({
	id = 11,
	name = "Bulldozer",
	weight = 25000,
	speed = 10,
	tireWidth = 0.6,
	disturbanceRadius = 8.0,
	disturbanceForce = 1.0,
	particleEmissionRate = 35,
	maxEmissionHeight = 6.0,
	dustKickMultiplier = 4.0,
})

-- Excavator - construction, very high disturbance
register({
	id = 12,
	name = "Excavator",
	weight = 22000,
	speed = 8,
	tireWidth = 0.55,
	disturbanceRadius = 7.5,
	disturbanceForce = 0.95,
	particleEmissionRate = 30,
	maxEmissionHeight = 5.5,
	dustKickMultiplier = 3.5,
})

-- Forklift - warehouse vehicle, moderate disturbance
register({
	id = 13,
	name = "Forklift",
	weight = 4000,
	speed = 15,
	tireWidth = 0.35,
	disturbanceRadius = 3.5,
	disturbanceForce = 0.4,
	particleEmissionRate = 6,
	maxEmissionHeight = 2.5,
	dustKickMultiplier = 1.2,
})

-- Bicycle - minimal disturbance
register({
	id = 14,
	name = "Bicycle",
	weight = 15,
	speed = 20,
	tireWidth = 0.04,
	disturbanceRadius = 1.0,
	disturbanceForce = 0.05,
	particleEmissionRate = 1,
	maxEmissionHeight = 0.8,
	dustKickMultiplier = 0.2,
})

-- Scooter - low disturbance
register({
	id = 15,
	name = "Scooter",
	weight = 120,
	speed = 40,
	tireWidth = 0.08,
	disturbanceRadius = 1.5,
	disturbanceForce = 0.1,
	particleEmissionRate = 2,
	maxEmissionHeight = 1.0,
	dustKickMultiplier = 0.4,
})

-- Three Wheeler - common in Indian cities
register({
	id = 16,
	name = "Three Wheeler",
	weight = 350,
	speed = 35,
	tireWidth = 0.12,
	disturbanceRadius = 2.5,
	disturbanceForce = 0.2,
	particleEmissionRate = 4,
	maxEmissionHeight = 1.8,
	dustKickMultiplier = 0.8,
})

-- Tuk Tuk - auto rickshaw, moderate disturbance
register({
	id = 17,
	name = "Tuk Tuk",
	weight = 400,
	speed = 35,
	tireWidth = 0.13,
	disturbanceRadius = 2.5,
	disturbanceForce = 0.22,
	particleEmissionRate = 4,
	maxEmissionHeight = 1.8,
	dustKickMultiplier = 0.85,
})

-- Cart - animal/human drawn, low disturbance
register({
	id = 18,
	name = "Cart",
	weight = 200,
	speed = 8,
	tireWidth = 0.1,
	disturbanceRadius = 2.0,
	disturbanceForce = 0.12,
	particleEmissionRate = 2,
	maxEmissionHeight = 1.2,
	dustKickMultiplier = 0.5,
})

-- Tank - military, extreme disturbance
register({
	id = 19,
	name = "Tank",
	weight = 60000,
	speed = 15,
	tireWidth = 0.8,
	disturbanceRadius = 10.0,
	disturbanceForce = 1.0,
	particleEmissionRate = 50,
	maxEmissionHeight = 7.0,
	dustKickMultiplier = 5.0,
})

-- Tractor - agricultural, high disturbance on dirt
register({
	id = 20,
	name = "Tractor",
	weight = 5000,
	speed = 12,
	tireWidth = 0.5,
	disturbanceRadius = 5.0,
	disturbanceForce = 0.6,
	particleEmissionRate = 15,
	maxEmissionHeight = 4.0,
	dustKickMultiplier = 2.0,
})

--===========================================================================
-- API
--===========================================================================

--[[
	Returns the vehicle profile for the given ID, or Sedan as default.
]]
function VehicularDisturbance.getProfile(vehicleId: number): Types.VehicleProfile
	local profile = PROFILES[vehicleId]
	if profile then
		return profile
	end
	return PROFILES[1] :: Types.VehicleProfile
end

--[[
	Returns all registered vehicle profiles as an array.
]]
function VehicularDisturbance.getAllProfiles(): { Types.VehicleProfile }
	local profiles = {}
	for _, profile in pairs(PROFILES) do
		table.insert(profiles, profile)
	end
	return profiles
end

--[[
	Calculates the effective disturbance force for a vehicle at a given speed.
	Disturbance scales with speed - faster vehicles kick up more dust.
]]
function VehicularDisturbance.getEffectiveDisturbanceForce(vehicleId: number, currentSpeed: number): number
	local profile = VehicularDisturbance.getProfile(vehicleId)
	-- Normalize speed against the vehicle's rated speed
	local speedRatio = math.clamp(currentSpeed / profile.speed, 0, 2.0)
	-- Disturbance scales non-linearly with speed
	return profile.disturbanceForce * (0.3 + (speedRatio * 0.7)) * profile.dustKickMultiplier
end

--[[
	Calculates the effective disturbance radius for a vehicle, factoring
	in its weight (heavier vehicles disturb a wider area).
]]
function VehicularDisturbance.getEffectiveDisturbanceRadius(vehicleId: number): number
	local profile = VehicularDisturbance.getProfile(vehicleId)
	-- Weight contributes to radius (logarithmic scaling)
	local weightFactor = math.log(profile.weight / 1000 + 1) * 0.5
	return profile.disturbanceRadius * (1.0 + weightFactor * 0.1)
end

--[[
	Calculates the particle emission rate for a vehicle at a given speed
	on a given material type.
]]
function VehicularDisturbance.getEmissionRate(
	vehicleId: number,
	currentSpeed: number,
	materialDustGeneration: number
): number
	local profile = VehicularDisturbance.getProfile(vehicleId)
	local speedRatio = math.clamp(currentSpeed / profile.speed, 0, 2.0)
	-- Emission = base rate * speed factor * material factor
	return profile.particleEmissionRate * speedRatio * (1.0 + materialDustGeneration * 5.0)
end

--[[
	Returns the maximum emission height for a vehicle, determining how
	high dust particles can be kicked into the air.
]]
function VehicularDisturbance.getMaxEmissionHeight(vehicleId: number): number
	local profile = VehicularDisturbance.getProfile(vehicleId)
	return profile.maxEmissionHeight
end

--[[
	Returns the tire width for a vehicle, used for calculating the
	disturbance footprint width.
]]
function VehicularDisturbance.getTireWidth(vehicleId: number): number
	local profile = VehicularDisturbance.getProfile(vehicleId)
	return profile.tireWidth
end

--[[
	Returns the weight of a vehicle in kg.
]]
function VehicularDisturbance.getWeight(vehicleId: number): number
	local profile = VehicularDisturbance.getProfile(vehicleId)
	return profile.weight
end

--[[
	Returns the rated speed of a vehicle.
]]
function VehicularDisturbance.getRatedSpeed(vehicleId: number): number
	local profile = VehicularDisturbance.getProfile(vehicleId)
	return profile.speed
end

--[[
	Returns the dust kick multiplier for a vehicle.
]]
function VehicularDisturbance.getDustKickMultiplier(vehicleId: number): number
	local profile = VehicularDisturbance.getProfile(vehicleId)
	return profile.dustKickMultiplier
end

--[[
	Creates a disturbance event for a vehicle at a given position.
	Returns a DisturbanceEvent ready to be injected into the simulation.
]]
function VehicularDisturbance.createDisturbanceEvent(
	vehicleId: number,
	cellId: number,
	currentSpeed: number
): Types.DisturbanceEvent
	local force = VehicularDisturbance.getEffectiveDisturbanceForce(vehicleId, currentSpeed)
	local radius = VehicularDisturbance.getEffectiveDisturbanceRadius(vehicleId)

	return {
		cellId = cellId,
		source = "Vehicle",
		intensity = force,
		radius = radius,
		timestamp = os.clock(),
		duration = 0.5, -- 500ms disturbance duration
	}
end

--[[
	Returns the number of registered vehicle profiles.
]]
function VehicularDisturbance.getCount(): number
	local count = 0
	for _ in pairs(PROFILES) do
		count += 1
	end
	return count
end

--[[
	Returns true if a vehicle with the given ID exists.
]]
function VehicularDisturbance.exists(vehicleId: number): boolean
	return PROFILES[vehicleId] ~= nil
end

return VehicularDisturbance