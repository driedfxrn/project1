--!strict
-- WeatherStates.luau
-- Extensive catalog of weather states for the dust simulation.
--
-- Weather dramatically affects dust behavior - rain suppresses dust,
-- wind carries it, humidity makes it settle faster. Each weather state
-- defines environmental parameters that the simulation engine applies
-- globally to all grid cells.
--
-- Weather states can transition smoothly via the blend function.

local Types = require(script.Parent.Types)

local WeatherStates = {}

--===========================================================================
-- Weather ID Constants
--===========================================================================

WeatherStates.Ids = {
	Clear = 1,
	LightBreeze = 2,
	Windy = 3,
	StrongWind = 4,
	Gale = 5,
	Overcast = 6,
	LightRain = 7,
	HeavyRain = 8,
	Monsoon = 9,
	PostRain = 10,
	Foggy = 11,
	Misty = 12,
	Dusty = 13,
	Sandstorm = 14,
	Humid = 15,
	DryHeat = 16,
	Cold = 17,
	Freezing = 18,
	Thunderstorm = 19,
	Hazy = 20,
}

--===========================================================================
-- Weather Profiles
--===========================================================================

local STATES: { [number]: Types.WeatherState } = {}

local function register(state: Types.WeatherState): ()
	STATES[state.id] = state
end

-- Clear - calm, no weather effects
register({
	id = 1,
	name = "Clear",
	windBaseSpeed = 2.0,
	windDirection = Vector3.new(1, 0, 0),
	humidity = 0.30,
	precipitationRate = 0.0,
	dustSuppression = 0.0,
	visibilityReduction = 0.0,
	ambientColor = Color3.fromRGB(128, 128, 128),
	outdoorAmbient = Color3.fromRGB(128, 128, 128),
	fogEnd = 10000,
	fogStart = 8000,
})

-- Light Breeze - gentle wind, minimal dust impact
register({
	id = 2,
	name = "Light Breeze",
	windBaseSpeed = 8.0,
	windDirection = Vector3.new(1, 0, 0.3),
	humidity = 0.35,
	precipitationRate = 0.0,
	dustSuppression = 0.05,
	visibilityReduction = 0.02,
	ambientColor = Color3.fromRGB(135, 135, 140),
	outdoorAmbient = Color3.fromRGB(130, 130, 135),
	fogEnd = 9000,
	fogStart = 7000,
})

-- Windy - moderate wind, carries dust
register({
	id = 3,
	name = "Windy",
	windBaseSpeed = 18.0,
	windDirection = Vector3.new(1, 0, 0.5),
	humidity = 0.30,
	precipitationRate = 0.0,
	dustSuppression = 0.0,
	visibilityReduction = 0.08,
	ambientColor = Color3.fromRGB(140, 140, 145),
	outdoorAmbient = Color3.fromRGB(135, 135, 140),
	fogEnd = 8000,
	fogStart = 6000,
})

-- Strong Wind - high wind, significant dust transport
register({
	id = 4,
	name = "Strong Wind",
	windBaseSpeed = 35.0,
	windDirection = Vector3.new(1, 0.1, 0.7),
	humidity = 0.25,
	precipitationRate = 0.0,
	dustSuppression = 0.0,
	visibilityReduction = 0.15,
	ambientColor = Color3.fromRGB(145, 142, 138),
	outdoorAmbient = Color3.fromRGB(140, 137, 133),
	fogEnd = 7000,
	fogStart = 5000,
})

-- Gale - extreme wind, massive dust movement
register({
	id = 5,
	name = "Gale",
	windBaseSpeed = 55.0,
	windDirection = Vector3.new(1, 0.2, 0.8),
	humidity = 0.20,
	precipitationRate = 0.0,
	dustSuppression = 0.0,
	visibilityReduction = 0.30,
	ambientColor = Color3.fromRGB(150, 145, 135),
	outdoorAmbient = Color3.fromRGB(145, 140, 130),
	fogEnd = 5000,
	fogStart = 3000,
})

-- Overcast - cloudy, reduced light
register({
	id = 6,
	name = "Overcast",
	windBaseSpeed = 5.0,
	windDirection = Vector3.new(0.5, 0, 0.3),
	humidity = 0.55,
	precipitationRate = 0.0,
	dustSuppression = 0.10,
	visibilityReduction = 0.05,
	ambientColor = Color3.fromRGB(100, 100, 105),
	outdoorAmbient = Color3.fromRGB(95, 95, 100),
	fogEnd = 8000,
	fogStart = 6000,
})

-- Light Rain - suppresses dust significantly
register({
	id = 7,
	name = "Light Rain",
	windBaseSpeed = 10.0,
	windDirection = Vector3.new(0.8, 0, 0.4),
	humidity = 0.80,
	precipitationRate = 0.3,
	dustSuppression = 0.50,
	visibilityReduction = 0.12,
	ambientColor = Color3.fromRGB(85, 85, 95),
	outdoorAmbient = Color3.fromRGB(80, 80, 90),
	fogEnd = 6000,
	fogStart = 4000,
})

-- Heavy Rain - nearly eliminates airborne dust
register({
	id = 8,
	name = "Heavy Rain",
	windBaseSpeed = 20.0,
	windDirection = Vector3.new(1, 0, 0.5),
	humidity = 0.92,
	precipitationRate = 0.7,
	dustSuppression = 0.85,
	visibilityReduction = 0.25,
	ambientColor = Color3.fromRGB(70, 70, 80),
	outdoorAmbient = Color3.fromRGB(65, 65, 75),
	fogEnd = 4000,
	fogStart = 2500,
})

-- Monsoon - extreme rain, all dust suppressed
register({
	id = 9,
	name = "Monsoon",
	windBaseSpeed = 30.0,
	windDirection = Vector3.new(1, 0.1, 0.6),
	humidity = 0.98,
	precipitationRate = 1.0,
	dustSuppression = 0.98,
	visibilityReduction = 0.40,
	ambientColor = Color3.fromRGB(55, 55, 65),
	outdoorAmbient = Color3.fromRGB(50, 50, 60),
	fogEnd = 3000,
	fogStart = 1500,
})

-- Post Rain - wet ground, dust suppressed but recovering
register({
	id = 10,
	name = "Post Rain",
	windBaseSpeed = 6.0,
	windDirection = Vector3.new(0.6, 0, 0.3),
	humidity = 0.75,
	precipitationRate = 0.0,
	dustSuppression = 0.60,
	visibilityReduction = 0.08,
	ambientColor = Color3.fromRGB(110, 110, 120),
	outdoorAmbient = Color3.fromRGB(105, 105, 115),
	fogEnd = 7000,
	fogStart = 5000,
})

-- Foggy - high visibility reduction, low wind
register({
	id = 11,
	name = "Foggy",
	windBaseSpeed = 1.0,
	windDirection = Vector3.new(0.2, 0, 0.1),
	humidity = 0.90,
	precipitationRate = 0.0,
	dustSuppression = 0.30,
	visibilityReduction = 0.60,
	ambientColor = Color3.fromRGB(160, 160, 165),
	outdoorAmbient = Color3.fromRGB(155, 155, 160),
	fogEnd = 1500,
	fogStart = 500,
})

-- Misty - lighter fog
register({
	id = 12,
	name = "Misty",
	windBaseSpeed = 2.0,
	windDirection = Vector3.new(0.3, 0, 0.2),
	humidity = 0.85,
	precipitationRate = 0.0,
	dustSuppression = 0.20,
	visibilityReduction = 0.35,
	ambientColor = Color3.fromRGB(170, 170, 175),
	outdoorAmbient = Color3.fromRGB(165, 165, 170),
	fogEnd = 3000,
	fogStart = 1500,
})

-- Dusty - airborne dust increases, hazy conditions
register({
	id = 13,
	name = "Dusty",
	windBaseSpeed = 12.0,
	windDirection = Vector3.new(1, 0, 0.4),
	humidity = 0.20,
	precipitationRate = 0.0,
	dustSuppression = -0.20, -- negative = dust amplification
	visibilityReduction = 0.20,
	ambientColor = Color3.fromRGB(180, 165, 140),
	outdoorAmbient = Color3.fromRGB(175, 160, 135),
	fogEnd = 6000,
	fogStart = 4000,
})

-- Sandstorm - extreme dust conditions
register({
	id = 14,
	name = "Sandstorm",
	windBaseSpeed = 45.0,
	windDirection = Vector3.new(1, 0.15, 0.6),
	humidity = 0.10,
	precipitationRate = 0.0,
	dustSuppression = -0.50, -- massive dust amplification
	visibilityReduction = 0.70,
	ambientColor = Color3.fromRGB(190, 160, 110),
	outdoorAmbient = Color3.fromRGB(185, 155, 105),
	fogEnd = 2000,
	fogStart = 800,
})

-- Humid - high moisture, dust settles faster
register({
	id = 15,
	name = "Humid",
	windBaseSpeed = 3.0,
	windDirection = Vector3.new(0.4, 0, 0.2),
	humidity = 0.88,
	precipitationRate = 0.0,
	dustSuppression = 0.25,
	visibilityReduction = 0.06,
	ambientColor = Color3.fromRGB(130, 130, 135),
	outdoorAmbient = Color3.fromRGB(125, 125, 130),
	fogEnd = 7500,
	fogStart = 5500,
})

-- Dry Heat - very low humidity, dust dries and lifts easily
register({
	id = 16,
	name = "Dry Heat",
	windBaseSpeed = 4.0,
	windDirection = Vector3.new(0.5, 0, 0.2),
	humidity = 0.12,
	precipitationRate = 0.0,
	dustSuppression = -0.10,
	visibilityReduction = 0.04,
	ambientColor = Color3.fromRGB(165, 155, 130),
	outdoorAmbient = Color3.fromRGB(160, 150, 125),
	fogEnd = 9000,
	fogStart = 7000,
})

-- Cold - low temperature, dust behavior slightly suppressed
register({
	id = 17,
	name = "Cold",
	windBaseSpeed = 7.0,
	windDirection = Vector3.new(0.7, 0, 0.3),
	humidity = 0.50,
	precipitationRate = 0.0,
	dustSuppression = 0.15,
	visibilityReduction = 0.07,
	ambientColor = Color3.fromRGB(120, 125, 140),
	outdoorAmbient = Color3.fromRGB(115, 120, 135),
	fogEnd = 8000,
	fogStart = 6000,
})

-- Freezing - very cold, dust largely settled
register({
	id = 18,
	name = "Freezing",
	windBaseSpeed = 5.0,
	windDirection = Vector3.new(0.5, 0, 0.2),
	humidity = 0.60,
	precipitationRate = 0.1,
	dustSuppression = 0.40,
	visibilityReduction = 0.10,
	ambientColor = Color3.fromRGB(110, 115, 135),
	outdoorAmbient = Color3.fromRGB(105, 110, 130),
	fogEnd = 7000,
	fogStart = 5000,
})

-- Thunderstorm - heavy rain with strong wind
register({
	id = 19,
	name = "Thunderstorm",
	windBaseSpeed = 40.0,
	windDirection = Vector3.new(1, 0.15, 0.7),
	humidity = 0.95,
	precipitationRate = 0.9,
	dustSuppression = 0.95,
	visibilityReduction = 0.35,
	ambientColor = Color3.fromRGB(60, 60, 75),
	outdoorAmbient = Color3.fromRGB(55, 55, 70),
	fogEnd = 3500,
	fogStart = 2000,
})

-- Hazy - pollution/dust haze, moderate visibility reduction
register({
	id = 20,
	name = "Hazy",
	windBaseSpeed = 3.0,
	windDirection = Vector3.new(0.3, 0, 0.15),
	humidity = 0.55,
	precipitationRate = 0.0,
	dustSuppression = -0.05,
	visibilityReduction = 0.25,
	ambientColor = Color3.fromRGB(175, 170, 155),
	outdoorAmbient = Color3.fromRGB(170, 165, 150),
	fogEnd = 5000,
	fogStart = 3000,
})

--===========================================================================
-- API
--===========================================================================

--[[
	Returns the weather state for the given ID, or Clear as default.
]]
function WeatherStates.getState(weatherId: number): Types.WeatherState
	local state = STATES[weatherId]
	if state then
		return state
	end
	return STATES[1] :: Types.WeatherState
end

--[[
	Returns all registered weather states as an array.
]]
function WeatherStates.getAllStates(): { Types.WeatherState }
	local states = {}
	for _, state in pairs(STATES) do
		table.insert(states, state)
	end
	return states
end

--[[
	Returns the effective wind vector for a weather state, normalized
	and scaled by the base speed.
]]
function WeatherStates.getWindVector(weatherId: number): Types.WindVector
	local state = WeatherStates.getState(weatherId)
	local dir = state.windDirection
	local magnitude = dir.Magnitude
	if magnitude < 0.001 then
		return {
			directionX = 0,
			directionY = 0,
			directionZ = 0,
			magnitude = 0,
		}
	end
	local normalized = dir / magnitude
	return {
		directionX = normalized.X,
		directionY = normalized.Y,
		directionZ = normalized.Z,
		magnitude = state.windBaseSpeed,
	}
end

--[[
	Returns the dust suppression factor for a weather state.
	Negative values mean dust amplification (e.g., sandstorm).
]]
function WeatherStates.getDustSuppression(weatherId: number): number
	local state = WeatherStates.getState(weatherId)
	return state.dustSuppression
end

--[[
	Returns the effective dust generation multiplier for a weather state.
	1.0 = normal, <1.0 = suppressed, >1.0 = amplified.
]]
function WeatherStates.getGenerationMultiplier(weatherId: number): number
	local state = WeatherStates.getState(weatherId)
	-- Suppression reduces generation, negative suppression amplifies
	return math.max(0, 1.0 - state.dustSuppression)
end

--[[
	Returns the settling rate multiplier for a weather state.
	Higher humidity = faster settling.
]]
function WeatherStates.getSettlingMultiplier(weatherId: number): number
	local state = WeatherStates.getState(weatherId)
	-- Humidity increases settling rate
	return 1.0 + (state.humidity * 0.5)
end

--[[
	Returns the visibility (0-1) for a weather state, where 1 is fully clear.
]]
function WeatherStates.getVisibility(weatherId: number): number
	local state = WeatherStates.getState(weatherId)
	return math.max(0, 1.0 - state.visibilityReduction)
end

--[[
	Returns the precipitation rate (0-1) for a weather state.
]]
function WeatherStates.getPrecipitationRate(weatherId: number): number
	local state = WeatherStates.getState(weatherId)
	return state.precipitationRate
end

--[[
	Returns the humidity (0-1) for a weather state.
]]
function WeatherStates.getHumidity(weatherId: number): number
	local state = WeatherStates.getState(weatherId)
	return state.humidity
end

--[[
	Returns the ambient color for a weather state, for Lighting application.
]]
function WeatherStates.getAmbientColor(weatherId: number): Color3
	local state = WeatherStates.getState(weatherId)
	return state.ambientColor
end

--[[
	Returns the outdoor ambient color for a weather state.
]]
function WeatherStates.getOutdoorAmbient(weatherId: number): Color3
	local state = WeatherStates.getState(weatherId)
	return state.outdoorAmbient
end

--[[
	Returns the fog settings for a weather state.
]]
function WeatherStates.getFogSettings(weatherId: number): (number, number)
	local state = WeatherStates.getState(weatherId)
	return state.fogEnd, state.fogStart
end

--[[
	Blends two weather states by a factor (0 = fully state A, 1 = fully state B).
	Used for smooth weather transitions.
]]
function WeatherStates.blendStates(stateAId: number, stateBId: number, factor: number): Types.WeatherState
	local stateA = WeatherStates.getState(stateAId)
	local stateB = WeatherStates.getState(stateBId)
	local t = math.clamp(factor, 0, 1)
	local inv = 1 - t

	return {
		id = if t < 0.5 then stateA.id else stateB.id,
		name = if t < 0.5 then stateA.name else stateB.name,
		windBaseSpeed = (stateA.windBaseSpeed * inv) + (stateB.windBaseSpeed * t),
		windDirection = stateA.windDirection:Lerp(stateB.windDirection, t),
		humidity = (stateA.humidity * inv) + (stateB.humidity * t),
		precipitationRate = (stateA.precipitationRate * inv) + (stateB.precipitationRate * t),
		dustSuppression = (stateA.dustSuppression * inv) + (stateB.dustSuppression * t),
		visibilityReduction = (stateA.visibilityReduction * inv) + (stateB.visibilityReduction * t),
		ambientColor = stateA.ambientColor:Lerp(stateB.ambientColor, t),
		outdoorAmbient = stateA.outdoorAmbient:Lerp(stateB.outdoorAmbient, t),
		fogEnd = (stateA.fogEnd * inv) + (stateB.fogEnd * t),
		fogStart = (stateA.fogStart * inv) + (stateB.fogStart * t),
	}
end

--[[
	Returns the number of registered weather states.
]]
function WeatherStates.getCount(): number
	local count = 0
	for _ in pairs(STATES) do
		count += 1
	end
	return count
end

return WeatherStates