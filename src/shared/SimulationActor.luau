--!strict
-- SimulationActor.luau
-- Parallel Luau worker for the Dynamic Road Dust & Particulate Simulation.
--
-- This is the core "Invention" layer math engine. Each actor:
--   - Owns a contiguous sector of grid cells
--   - Runs fluid dynamics calculations in parallel via task.desynchronize()
--   - Writes results into a binary buffer (via BufferSerializer)
--   - Shares state with other actors through SharedTable
--
-- The simulation step performs:
--   1. Wind field update (global + turbulence)
--   2. Diffusion (dust spreads to neighbors)
--   3. Advection (wind carries dust)
--   4. Gravity settling (dust falls)
--   5. Disturbance application (vehicle kicks)
--   6. Decay (dust dissipates over time)
--   7. Precipitation (rain suppresses dust)
--   8. Material-based generation (surfaces generate dust)
--
-- All heavy math runs inside task.desynchronize() blocks for true
-- multi-threaded execution. Results are synchronized back before
-- buffer serialization.

local Types = require(script.Parent.Types)
local BufferSerializer = require(script.Parent.BufferSerializer)
local MaterialsCatalog = require(script.Parent.MaterialsCatalog)
local WeatherStates = require(script.Parent.WeatherStates)

local SimulationActor = {}
SimulationActor.__index = SimulationActor

--===========================================================================
-- Internal Types
--===========================================================================

type ActorT = {
	sectorId: number,
	startCell: number,
	endCell: number,
	cellCount: number,
	cells: { Types.GridCell },
	config: Types.SimulationConfig,
	neighborCache: { [number]: { Types.GridCell } },
	outputBuffer: buffer,
	outputCellCount: number,
	frameId: number,
	weatherId: number,
	weatherState: Types.WeatherState,
	windField: { number }, -- flattened 3D wind field
	windFieldDims: Types.Vector3Int,
	turbulenceSeed: number,
	statistics: Types.GridStatistics,
	sharedTable: any,
	-- Methods
	step: (self: ActorT, deltaTime: number) -> (),
	getOutput: (self: ActorT) -> (buffer, number),
	applyDisturbance: (self: ActorT, cellId: number, intensity: number, radius: number) -> (),
	buildNeighborCache: (self: ActorT, allCellsMap: { [number]: Types.GridCell }) -> (),
	setWeather: (self: ActorT, weatherId: number) -> (),
	setFrameId: (self: ActorT, frameId: number) -> (),
	getStatistics: (self: ActorT) -> Types.GridStatistics,
	destroy: (self: ActorT) -> (),
}

--===========================================================================
-- Constants
--===========================================================================

local MAX_DENSITY = 1.0
local MIN_DENSITY = 0.0
local WIND_TURBULENCE_FREQUENCY = 0.3
local WIND_TURBULENCE_AMPLITUDE = 0.4
local DIFFUSION_NEIGHBOR_WEIGHT = 0.125
local ADVECTION_COURANT_LIMIT = 0.5
local SETTLING_RATE_BASE = 0.05
local PRECIPITATION_SUPPRESSION = 0.8
local DISTURBANCE_DECAY_RATE = 0.92
local MAX_NEIGHBORS = 6

--===========================================================================
-- Constructor
--===========================================================================

function SimulationActor.new(
	sectorId: number,
	startCell: number,
	endCell: number,
	cells: { Types.GridCell },
	config: Types.SimulationConfig
): SimulationActor.SimulationActor
	local cellCount = #cells

	local self = setmetatable({
		sectorId = sectorId,
		startCell = startCell,
		endCell = endCell,
		cellCount = cellCount,
		cells = cells,
		config = config,
		neighborCache = {},
		outputBuffer = BufferSerializer.createBuffer(cellCount),
		outputCellCount = cellCount,
		frameId = 0,
		weatherId = 1,
		weatherState = WeatherStates.getState(1),
		windField = {},
		windFieldDims = config.gridDimensions,
		turbulenceSeed = math.random() * 1000,
		statistics = {
			totalCells = cellCount,
			activeCells = 0,
			averageDensity = 0,
			maxDensity = 0,
			totalDustMass = 0,
			sectorsProcessed = 0,
			processingTimeMs = 0,
		},
		sharedTable = nil,
	}, SimulationActor) :: any

	return self
end

--===========================================================================
-- Neighbor Cache Construction
--===========================================================================

function SimulationActor:buildNeighborCache(allCellsMap: { [number]: Types.GridCell }): ()
	self.neighborCache = {}

	for _, cell in ipairs(self.cells) do
		local neighbors: { Types.GridCell } = {}
		for _, neighborId in ipairs(cell.neighborIds) do
			local neighborCell = allCellsMap[neighborId]
			if neighborCell then
				table.insert(neighbors, neighborCell)
			end
		end
		self.neighborCache[cell.id] = neighbors
	end
end

--===========================================================================
-- Weather Management
--===========================================================================

function SimulationActor:setWeather(weatherId: number): ()
	local state = WeatherStates.getState(weatherId)
	if state then
		self.weatherId = weatherId
		self.weatherState = state
	end
end

function SimulationActor:setFrameId(frameId: number): ()
	self.frameId = frameId
end

--===========================================================================
-- Wind Field Update
--===========================================================================

--[[
	Updates the wind vector for each cell based on the current weather state
	and a turbulence model. This runs in the parallel context.
]]
local function updateWindField(cells: { Types.GridCell }, weather: Types.WeatherState, deltaTime: number, seed: number): ()
	local baseSpeed = weather.windBaseSpeed
	local baseDir = weather.windDirection
	local turbulence = weather.humidity * 0.1 -- more humidity = slightly more turbulent

	for _, cell in ipairs(cells) do
		-- Turbulence based on cell position and time
		local phaseX = math.sin((cell.coords.x * WIND_TURBULENCE_FREQUENCY) + seed + os.clock())
		local phaseZ = math.cos((cell.coords.z * WIND_TURBULENCE_FREQUENCY) + seed + os.clock())
		local turbX = phaseX * WIND_TURBULENCE_AMPLITUDE * turbulence
		local turbZ = phaseZ * WIND_TURBULENCE_AMPLITUDE * turbulence

		-- Combine base wind direction with turbulence
		cell.wind.directionX = baseDir.X + turbX
		cell.wind.directionZ = baseDir.Z + turbZ

		-- Normalize direction
		local dirMag = math.sqrt(cell.wind.directionX ^ 2 + cell.wind.directionZ ^ 2)
		if dirMag > 0.001 then
			cell.wind.directionX /= dirMag
			cell.wind.directionZ /= dirMag
		end

		-- Magnitude with slight per-cell variation
		cell.wind.magnitude = baseSpeed * (0.8 + (math.random() * 0.4))
	end
end

--===========================================================================
-- Diffusion (Dust Spreading)
--===========================================================================

--[[
	Diffusion step: dust spreads from high-density cells to low-density neighbors.
	Uses a weighted average approach with the diffusion rate from config.
	Runs in parallel context.
]]
local function diffuseDust(
	cells: { Types.GridCell },
	neighborCache: { [number]: { Types.GridCell } },
	diffusionRate: number,
	deltaTime: number
): ()
	-- We need to read all current densities first, then write, to avoid
	-- order-dependent results (Jacobi-style update)
	local newDensities: { [number]: number } = {}

	for _, cell in ipairs(cells) do
		local neighbors = neighborCache[cell.id]
		local neighborCount = #neighbors

		if neighborCount == 0 then
			newDensities[cell.id] = cell.density
		else
			local neighborSum = 0.0
			for _, neighbor in ipairs(neighbors) do
				neighborSum += neighbor.density
			end
			local neighborAvg = neighborSum / neighborCount
			local diff = (neighborAvg - cell.density) * diffusionRate * deltaTime
			newDensities[cell.id] = cell.density + diff
		end
	end

	-- Apply the computed densities
	for _, cell in ipairs(cells) do
		cell.density = math.clamp(newDensities[cell.id] or cell.density, MIN_DENSITY, MAX_DENSITY)
	end
end

--===========================================================================
-- Advection (Wind Transport)
--===========================================================================

--[[
	Advection step: wind carries dust in its direction.
	Uses a semi-Lagrangian approach: trace back along the wind vector
	to find the source cell, then sample its density.
	Runs in parallel context.
]]
local function advectDust(
	cells: { Types.GridCell },
	neighborCache: { [number]: { Types.GridCell } },
	windInfluence: number,
	deltaTime: number
): ()
	local newDensities: { [number]: number } = {}

	for _, cell in ipairs(cells) do
		local windX = cell.wind.directionX * cell.wind.magnitude * windInfluence * deltaTime
		local windZ = cell.wind.directionZ * cell.wind.magnitude * windInfluence * deltaTime

		-- Clamp advection distance (Courant-Friedrichs-Lewy condition)
		local advectionMag = math.sqrt(windX ^ 2 + windZ ^ 2)
		if advectionMag > ADVECTION_COURANT_LIMIT then
			windX = (windX / advectionMag) * ADVECTION_COURANT_LIMIT
			windZ = (windZ / advectionMag) * ADVECTION_COURANT_LIMIT
		end

		-- Find the "upwind" neighbor - the cell the wind is coming FROM
		local neighbors = neighborCache[cell.id]
		local bestNeighbor: Types.GridCell? = nil
		local bestDot = -2.0

		for _, neighbor in ipairs(neighbors) do
			-- Direction from neighbor to current cell
			local dirX = cell.worldPosition.X - neighbor.worldPosition.X
			local dirZ = cell.worldPosition.Z - neighbor.worldPosition.Z
			local dirMag = math.sqrt(dirX ^ 2 + dirZ ^ 2)

			if dirMag > 0.001 then
				dirX /= dirMag
				dirZ /= dirMag

				-- Dot product: how aligned is wind with this direction?
				local dot = cell.wind.directionX * dirX + cell.wind.directionZ * dirZ
				if dot > bestDot then
					bestDot = dot
					bestNeighbor = neighbor
				end
			end
		end

		-- Blend current density with upwind source
		if bestNeighbor and bestDot > 0 then
			local blendFactor = bestDot * advectionMag
			newDensities[cell.id] = cell.density * (1 - blendFactor) + bestNeighbor.density * blendFactor
		else
			newDensities[cell.id] = cell.density
		end
	end

	for _, cell in ipairs(cells) do
		cell.density = math.clamp(newDensities[cell.id] or cell.density, MIN_DENSITY, MAX_DENSITY)
	end
end

--===========================================================================
-- Gravity Settling
--===========================================================================

--[[
	Gravity settling: dust in higher vertical layers settles down to lower layers.
	This creates the effect of dust falling after being kicked up.
]]
local function settleDust(
	cells: { Types.GridCell },
	neighborCache: { [number]: { Types.GridCell } },
	settlingRate: number,
	deltaTime: number
): ()
	local newDensities: { [number]: number } = {}

	for _, cell in ipairs(cells) do
		local belowNeighbor: Types.GridCell? = nil
		local neighbors = neighborCache[cell.id]

		-- Find the neighbor directly below (lower Y)
		for _, neighbor in ipairs(neighbors) do
			if neighbor.coords.y < cell.coords.y then
				belowNeighbor = neighbor
				break
			end
		end

		if belowNeighbor then
			-- Dust flows downward
			local transferAmount = cell.density * settlingRate * deltaTime
			newDensities[cell.id] = cell.density - transferAmount
			-- Note: we can't add to the neighbor here because it might be
			-- processed in a different order. The neighbor's gain is handled
			-- by its own settling calculation looking at what's above it.
			-- For simplicity, we use a one-sided model where dust settles
			-- and is removed from the upper cell, with the lower cell
			-- gaining it through diffusion in the next step.
		else
			-- Ground level - dust accumulates
			newDensities[cell.id] = cell.density
		end
	end

	for _, cell in ipairs(cells) do
		cell.density = math.clamp(newDensities[cell.id] or cell.density, MIN_DENSITY, MAX_DENSITY)
	end
end

--===========================================================================
-- Disturbance Application
--===========================================================================

--[[
	Applies a disturbance event to a cell and its neighbors.
	This is called from the main thread (not parallel) when processing
	the disturbance queue.
]]
function SimulationActor:applyDisturbance(cellId: number, intensity: number, radius: number): ()
	-- Find the target cell
	local targetCell: Types.GridCell? = nil
	for _, cell in ipairs(self.cells) do
		if cell.id == cellId then
			targetCell = cell
			break
		end
	end

	if targetCell == nil then
		return
	end

	local center = targetCell :: Types.GridCell

	-- Apply to center cell
	center.disturbance = math.min(1.0, center.disturbance + intensity)
	center.density = math.min(MAX_DENSITY, center.density + intensity * 0.3)

	-- Apply to neighbors within radius
	local neighbors = self.neighborCache[cellId]
	if neighbors then
		for _, neighbor in ipairs(neighbors) do
			local dist = (neighbor.worldPosition - center.worldPosition).Magnitude
			if dist <= radius then
				local falloff = 1.0 - (dist / radius)
				local effect = intensity * falloff * 0.5
				neighbor.disturbance = math.min(1.0, neighbor.disturbance + effect)
				neighbor.density = math.min(MAX_DENSITY, neighbor.density + effect * 0.2)
			end
		end
	end
end

--===========================================================================
-- Disturbance Decay
--===========================================================================

--[[
	Decays the disturbance level of each cell over time.
	Disturbance naturally fades after the source (vehicle) passes.
]]
local function decayDisturbance(cells: { Types.GridCell }, deltaTime: number): ()
	for _, cell in ipairs(cells) do
		cell.disturbance = cell.disturbance * math.pow(DISTURBANCE_DECAY_RATE, deltaTime * 60)
		if cell.disturbance < 0.001 then
			cell.disturbance = 0
		end
	end
end

--===========================================================================
-- Dust Decay (Natural Dissipation)
--===========================================================================

--[[
	Natural dust decay: dust slowly dissipates even without disturbance.
	Rate is influenced by the material's dust retention property.
]]
local function decayDust(cells: { Types.GridCell }, decayRate: number, deltaTime: number): ()
	for _, cell in ipairs(cells) do
		local materialProfile = MaterialsCatalog.getProfile(cell.materialId)
		-- Materials with higher retention decay slower
		local materialDecayRate = decayRate * (1.0 - materialProfile.dustRetention * 0.5)
		cell.density = cell.density * math.pow(1.0 - materialDecayRate, deltaTime * 60)
		if cell.density < 0.0001 then
			cell.density = 0
		end
	end
end

--===========================================================================
-- Precipitation Effects
--===========================================================================

--[[
	Applies precipitation effects: rain suppresses dust density.
	The weather state's precipitationRate and dustSuppression control this.
]]
local function applyPrecipitation(cells: { Types.GridCell }, weather: Types.WeatherState, deltaTime: number): ()
	if weather.precipitationRate <= 0 then
		return
	end

	local suppressionFactor = weather.dustSuppression * weather.precipitationRate * PRECIPITATION_SUPPRESSION
	local decayAmount = suppressionFactor * deltaTime

	for _, cell in ipairs(cells) do
		cell.density = math.max(MIN_DENSITY, cell.density - decayAmount)
		-- Rain also reduces disturbance
		cell.disturbance = math.max(0, cell.disturbance - decayAmount * 0.5)
	end
end

--===========================================================================
-- Material-Based Dust Generation
--===========================================================================

--[[
	Generates dust based on material properties.
	Some surfaces (dirt, gravel) naturally generate more dust than others (asphalt).
	Disturbance amplifies generation.
]]
local function generateDust(cells: { Types.GridCell }, deltaTime: number): ()
	for _, cell in ipairs(cells) do
		local materialProfile = MaterialsCatalog.getProfile(cell.materialId)
		local baseGeneration = materialProfile.dustGenerationRate * deltaTime

		-- Disturbance amplifies generation
		local disturbanceBoost = 1.0 + (cell.disturbance * 3.0)
		local totalGeneration = baseGeneration * disturbanceBoost

		-- Wind resistance reduces generation (sheltered areas generate more)
		local windFactor = 1.0 - (cell.wind.magnitude * 0.01 * materialProfile.windResistance)
		totalGeneration *= math.max(0.1, windFactor)

		cell.density = math.min(MAX_DENSITY, cell.density + totalGeneration)
	end
end

--===========================================================================
-- Statistics Collection
--===========================================================================

--[[
	Collects aggregate statistics for this sector.
	Runs in parallel context.
]]
local function collectStatistics(cells: { Types.GridCell }): Types.GridStatistics
	local totalDensity = 0.0
	local maxDensity = 0.0
	local activeCells = 0
	local totalDustMass = 0.0

	for _, cell in ipairs(cells) do
		totalDensity += cell.density
		if cell.density > maxDensity then
			maxDensity = cell.density
		end
		if cell.density > 0.01 then
			activeCells += 1
			totalDustMass += cell.density
		end
	end

	local cellCount = #cells
	return {
		totalCells = cellCount,
		activeCells = activeCells,
		averageDensity = if cellCount > 0 then totalDensity / cellCount else 0,
		maxDensity = maxDensity,
		totalDustMass = totalDustMass,
		sectorsProcessed = 1,
		processingTimeMs = 0,
	}
end

--===========================================================================
-- Buffer Serialization
--===========================================================================

--[[
	Serializes all cell data into the output buffer.
	This runs on the main thread (synchronized) because buffer writes
	must happen in the serial context.
]]
function SimulationActor:serializeOutput(): ()
	for index, cell in ipairs(self.cells) do
		BufferSerializer.writeCell(
			self.outputBuffer,
			index - 1,
			cell.id,
			cell.density,
			cell.wind.directionX,
			cell.wind.directionZ,
			cell.wind.magnitude,
			cell.disturbance,
			cell.materialId
		)
	end
end

--===========================================================================
-- Main Simulation Step
--===========================================================================

--[[
	Runs one full simulation step for this actor's sector.
	
	The parallel execution strategy:
	1. Enter parallel context (task.desynchronize)
	2. Run all heavy math (wind, diffusion, advection, settling, decay, generation)
	3. Exit parallel context (task.synchronize)
	4. Serialize results to buffer (must be on main thread)
	
	This ensures the math runs on a worker thread while buffer writes
	and SharedTable operations happen safely on the main thread.
]]
function SimulationActor:step(deltaTime: number): ()
	local startTime = os.clock()

	-- Phase 1: Enter parallel context for heavy math
	-- task.desynchronize() allows this actor's math to run on a
	-- different thread than the main simulation loop.
	task.desynchronize()

	-- Update wind field based on current weather
	updateWindField(self.cells, self.weatherState, deltaTime, self.turbulenceSeed)

	-- Diffusion: dust spreads to neighbors
	diffuseDust(self.cells, self.neighborCache, self.config.diffusionRate, deltaTime)

	-- Advection: wind transports dust
	advectDust(self.cells, self.neighborCache, self.config.windInfluence, deltaTime)

	-- Gravity settling: dust falls
	settleDust(self.cells, self.neighborCache, self.config.gravitySettling * SETTLING_RATE_BASE, deltaTime)

	-- Disturbance decay
	decayDisturbance(self.cells, deltaTime)

	-- Material-based dust generation
	generateDust(self.cells, deltaTime)

	-- Natural dust decay
	decayDust(self.cells, self.config.decayRate, deltaTime)

	-- Precipitation effects
	applyPrecipitation(self.cells, self.weatherState, deltaTime)

	-- Collect statistics
	self.statistics = collectStatistics(self.cells)

	-- Phase 2: Return to main thread for serialization
	task.synchronize()

	-- Serialize results to buffer (main thread)
	self:serializeOutput()

	-- Update timing stats
	self.statistics.processingTimeMs = (os.clock() - startTime) * 1000
end

--===========================================================================
-- Output Access
--===========================================================================

function SimulationActor:getOutput(): (buffer, number)
	return self.outputBuffer, self.outputCellCount
end

function SimulationActor:getStatistics(): Types.GridStatistics
	return self.statistics
end

--===========================================================================
-- SharedTable Integration
--===========================================================================

--[[
	Writes this actor's statistics into a SharedTable for cross-actor
	state sharing. This allows the server to aggregate stats from all
	sectors without explicit message passing.
]]
function SimulationActor:writeToSharedTable(sharedTable: any): ()
	if sharedTable == nil then
		return
	end
	sharedTable[string.format("sector_%d_stats", self.sectorId)] = {
		activeCells = self.statistics.activeCells,
		averageDensity = self.statistics.averageDensity,
		maxDensity = self.statistics.maxDensity,
		totalDustMass = self.statistics.totalDustMass,
		processingTimeMs = self.statistics.processingTimeMs,
	}
end

--[[
	Reads another sector's statistics from the SharedTable.
	Used for boundary-aware optimizations (e.g., knowing if a neighbor
	sector has high dust that might flow into this one).
]]
function SimulationActor:readFromSharedTable(sharedTable: any, otherSectorId: number): any
	if sharedTable == nil then
		return nil
	end
	return sharedTable[string.format("sector_%d_stats", otherSectorId)]
end

--===========================================================================
-- Cleanup
--===========================================================================

function SimulationActor:destroy(): ()
	self.cells = {}
	self.neighborCache = {}
	self.outputBuffer = buffer.create(0) :: any
	self.windField = {}
	setmetatable(self :: any, nil)
end

export type SimulationActor = ActorT

return SimulationActor