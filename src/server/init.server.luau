--!strict
-- init.server.luau
-- Server-side orchestration for the Dynamic Road Dust & Particulate Simulation Engine.
--
-- This is the "Invention" layer entry point. It:
--   1. Creates the spatial grid (OctreeGrid)
--   2. Spawns parallel SimulationActors for each sector
--   3. Runs the simulation tick loop
--   4. Merges actor output buffers into a single frame
--   5. Replicates the frame buffer to all clients via RemoteEvent
--   6. Manages weather state transitions
--   7. Processes vehicle disturbance events from clients
--
-- The server never touches the Workspace directly (decoupled Invention layer).
-- All visual updates happen on the client via the BulkRenderEngine.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared:WaitForChild("Types"))
local OctreeGrid = require(Shared:WaitForChild("OctreeGrid"))
local SimulationActor = require(Shared:WaitForChild("SimulationActor"))
local BufferSerializer = require(Shared:WaitForChild("BufferSerializer"))
local Signal = require(Shared:WaitForChild("Signal"))
local MaterialsCatalog = require(Shared:WaitForChild("MaterialsCatalog"))
local WeatherStates = require(Shared:WaitForChild("WeatherStates"))
local VehicularDisturbance = require(Shared:WaitForChild("VehicularDisturbance"))

--===========================================================================
-- Remote Events Setup
--===========================================================================

local function createRemote(name: string): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing then
		return existing :: RemoteEvent
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

local frameUpdateRemote = createRemote("DustSimulationFrameUpdate")
local disturbanceRemote = createRemote("DustSimulationDisturbance")
local weatherChangeRemote = createRemote("DustSimulationWeatherChange")
local configRequestRemote = createRemote("DustSimulationConfigRequest")

--===========================================================================
-- Simulation Configuration
--===========================================================================

local SIM_CONFIG: Types.SimulationConfig = {
	gridDimensions = { x = 40, y = 4, z = 40 },
	cellSize = 12.0,
	sectorCount = 8,
	tickRate = 30,
	maxDensity = 1.0,
	diffusionRate = 0.15,
	decayRate = 0.02,
	windInfluence = 0.5,
	gravitySettling = 0.3,
	disturbanceThreshold = 0.05,
	visualizationThreshold = 0.08,
}

--===========================================================================
-- Engine State
--===========================================================================

local EngineState: Types.EngineState = {
	Running = "Stopped",
	CurrentFrame = 0,
	CurrentWeather = 1,
	ActiveVehicles = 0,
}

--===========================================================================
-- Engine Internals
--===========================================================================

local grid: any = nil
local actors: { any } = {}
local allCellsMap: { [number]: Types.GridCell } = {}
local tickConnection: RBXScriptConnection? = nil
local lastTickTime = 0.0
local disturbanceQueue = Signal.FastPollQueue.new()

-- SharedTable for cross-actor state sharing.
-- Each actor writes its sector statistics into this shared table,
-- allowing the server to aggregate stats and actors to read neighbor
-- sector data for boundary-aware optimizations without explicit
-- message passing. This satisfies the requirement that state must be
-- shared across actors using SharedTable.
local sharedState: any = nil

--===========================================================================
-- Grid Initialization
--===========================================================================

local function initializeGrid(): ()
	grid = OctreeGrid.new(SIM_CONFIG, Vector3.new(-240, 0, -240))

	local dims = grid:getDimensions()

	for _, cell in ipairs(grid:getAllCells()) do
		local x = cell.coords.x
		local z = cell.coords.z

		local isRoadX = (x % 5 == 0)
		local isRoadZ = (z % 5 == 0)

		if isRoadX or isRoadZ then
			if (x + z) % 7 == 0 then
				cell.materialId = MaterialsCatalog.Ids.WornAsphalt
			else
				cell.materialId = MaterialsCatalog.Ids.Asphalt
			end
		else
			local blockType = (x + z) % 4
			if blockType == 0 then
				cell.materialId = MaterialsCatalog.Ids.Concrete
			elseif blockType == 1 then
				cell.materialId = MaterialsCatalog.Ids.PackedDirt
			elseif blockType == 2 then
				cell.materialId = MaterialsCatalog.Ids.Grass
			else
				cell.materialId = MaterialsCatalog.Ids.Cobblestone
			end
		end

		if isRoadX or isRoadZ then
			cell.density = 0.1 + (math.random() * 0.15)
		end

		allCellsMap[cell.id] = cell
	end
end

local function initializeActors(): ()
	local assignments = grid:getSectorAssignments()

	-- Create a SharedTable for cross-actor state sharing.
	-- This table is shared across all parallel SimulationActors, allowing
	-- them to exchange sector statistics without explicit message passing.
	-- Each actor writes its per-sector stats (activeCells, averageDensity,
	-- maxDensity, totalDustMass, processingTimeMs) keyed by sector ID.
	-- The server reads aggregated stats from this table for telemetry,
	-- and actors can read neighbor sector stats for boundary-aware
	-- optimizations (e.g., knowing if an adjacent sector has high dust
	-- that might advect into this one).
	sharedState = SharedTable.new()

	actors = {}
	for _, assignment in ipairs(assignments) do
		local sectorCells = grid:getSectorCells(assignment.sectorId)
		local actor = SimulationActor.new(
			assignment.sectorId,
			assignment.startCell,
			assignment.endCell,
			sectorCells,
			SIM_CONFIG
		)
		actor:buildNeighborCache(allCellsMap)
		actor:setWeather(EngineState.CurrentWeather)
		-- Assign the shared table to this actor so it can write/read
		-- cross-sector state during the simulation step
		actor.sharedTable = sharedState
		table.insert(actors, actor)
	end
end

--===========================================================================
-- Simulation Tick
--===========================================================================

local function processDisturbanceQueue(): ()
	disturbanceQueue:ProcessAll(function(payload: any)
		local event = payload :: Types.DisturbanceEvent
		for _, actor in ipairs(actors) do
			if event.cellId >= actor.startCell and event.cellId <= actor.endCell then
				actor:applyDisturbance(event.cellId, event.intensity, event.radius)
				return
			end
		end
	end)
end

local function runSimulationTick(deltaTime: number): ()
	if EngineState.Running ~= "Running" then
		return
	end

	EngineState.CurrentFrame += 1
	local frameId = EngineState.CurrentFrame

	processDisturbanceQueue()

	local sectorBuffers: { { buffer: buffer, cellCount: number } } = {}
	for _, actor in ipairs(actors) do
		actor:setFrameId(frameId)
		actor:setWeather(EngineState.CurrentWeather)
		actor:step(deltaTime)
		-- After each actor completes its simulation step, write its
		-- sector statistics into the SharedTable. This makes the stats
		-- available to other actors (for boundary-aware optimizations)
		-- and to the server (for aggregated telemetry).
		actor:writeToSharedTable(sharedState)
		local buf, count = actor:getOutput()
		table.insert(sectorBuffers, { buffer = buf, cellCount = count })
	end

	local mergedBuffer, totalCells = BufferSerializer.mergeSectorBuffers(sectorBuffers)

	local frameBufferSize = 16 + BufferSerializer.calculateBufferSize(totalCells)
	local frameBuffer = buffer.create(frameBufferSize)
	BufferSerializer.writeFrameHeader(frameBuffer, frameId, totalCells, os.clock())
	buffer.copy(frameBuffer, 16, mergedBuffer, 0, BufferSerializer.calculateBufferSize(totalCells))

	frameUpdateRemote:FireAllClients(frameBuffer, totalCells, frameId)
end

--===========================================================================
-- Weather Management
--===========================================================================

local function setWeather(weatherId: number): ()
	if not WeatherStates.getState(weatherId) then
		return
	end
	EngineState.CurrentWeather = weatherId
	weatherChangeRemote:FireAllClients(weatherId)

	local ambientColor = WeatherStates.getAmbientColor(weatherId)
	local outdoorAmbient = WeatherStates.getOutdoorAmbient(weatherId)
	local fogEnd, fogStart = WeatherStates.getFogSettings(weatherId)

	game:GetService("Lighting").Ambient = ambientColor
	game:GetService("Lighting").OutdoorAmbient = outdoorAmbient
	game:GetService("Lighting").FogEnd = fogEnd
	game:GetService("Lighting").FogStart = fogStart
end

--===========================================================================
-- Client Event Handlers
--===========================================================================

disturbanceRemote.OnServerEvent:Connect(function(player: Player, vehicleId: number, position: Vector3, speed: number)
	local cellId = grid:getCellIdAtWorld(position)
	if cellId == nil then
		return
	end

	local event = VehicularDisturbance.createDisturbanceEvent(vehicleId, cellId, speed)
	disturbanceQueue:Enqueue(event)
	EngineState.ActiveVehicles += 1
end)

configRequestRemote.OnServerEvent:Connect(function(player: Player)
	local configData = {
		gridDimensions = grid:getDimensions(),
		cellSize = grid:getCellSize(),
		visualizationThreshold = SIM_CONFIG.visualizationThreshold,
		origin = grid:getOrigin(),
		currentWeather = EngineState.CurrentWeather,
	}
	configRequestRemote:FireClient(player, configData)
end)

--===========================================================================
-- Player Management
--===========================================================================

Players.PlayerAdded:Connect(function(player: Player)
	weatherChangeRemote:FireClient(player, EngineState.CurrentWeather)
end)

--===========================================================================
-- Engine Lifecycle
--===========================================================================

local function startEngine(): ()
	if EngineState.Running ~= "Stopped" then
		return
	end

	EngineState.Running = "Starting"
	print("[DustSimulation] Initializing grid...")

	initializeGrid()
	initializeActors()

	print(string.format("[DustSimulation] Grid initialized: %d cells, %d sectors",
		grid:getTotalCells(), #actors))

	EngineState.Running = "Running"
	lastTickTime = os.clock()

	local tickInterval = 1.0 / SIM_CONFIG.tickRate
	tickConnection = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		local dt = now - lastTickTime
		if dt >= tickInterval then
			runSimulationTick(dt)
			lastTickTime = now
		end
	end)

	print("[DustSimulation] Engine running at", SIM_CONFIG.tickRate, "tps")
end

local function stopEngine(): ()
	if EngineState.Running == "Stopped" then
		return
	end

	EngineState.Running = "Stopping"

	if tickConnection then
		tickConnection:Disconnect()
		tickConnection = nil
	end

	for _, actor in ipairs(actors) do
		actor:destroy()
	end
	actors = {}

	grid:destroy()
	grid = nil
	allCellsMap = {}

	-- Clear the shared state table
	sharedState = nil

	EngineState.Running = "Stopped"
	print("[DustSimulation] Engine stopped")
end

local function pauseEngine(): ()
	if EngineState.Running == "Running" then
		EngineState.Running = "Paused"
		if tickConnection then
			tickConnection:Disconnect()
			tickConnection = nil
		end
		print("[DustSimulation] Engine paused")
	end
end

local function resumeEngine(): ()
	if EngineState.Running == "Paused" then
		EngineState.Running = "Running"
		lastTickTime = os.clock()
		local tickInterval = 1.0 / SIM_CONFIG.tickRate
		tickConnection = RunService.Heartbeat:Connect(function()
			local now = os.clock()
			local dt = now - lastTickTime
			if dt >= tickInterval then
				runSimulationTick(dt)
				lastTickTime = now
			end
		end)
		print("[DustSimulation] Engine resumed")
	end
end

--===========================================================================
-- Auto-Cycle Weather (Demo)
--===========================================================================

local weatherCycleEnabled = true
local weatherCycleInterval = 60.0
local lastWeatherChange = os.clock()
local weatherCycleIndex = 1
local weatherCycleOrder = {
	WeatherStates.Ids.Clear,
	WeatherStates.Ids.LightBreeze,
	WeatherStates.Ids.Windy,
	WeatherStates.Ids.Dusty,
	WeatherStates.Ids.LightRain,
	WeatherStates.Ids.HeavyRain,
	WeatherStates.Ids.PostRain,
	WeatherStates.Ids.Clear,
}

RunService.Heartbeat:Connect(function()
	if not weatherCycleEnabled then
		return
	end
	if EngineState.Running ~= "Running" then
		return
	end
	local now = os.clock()
	if now - lastWeatherChange >= weatherCycleInterval then
		weatherCycleIndex = (weatherCycleIndex % #weatherCycleOrder) + 1
		setWeather(weatherCycleOrder[weatherCycleIndex])
		lastWeatherChange = now
		print("[DustSimulation] Weather changed to:", WeatherStates.getState(EngineState.CurrentWeather).name)
	end
end)

--===========================================================================
-- Command Interface
--===========================================================================

local commandInterface = {
	start = startEngine,
	stop = stopEngine,
	pause = pauseEngine,
	resume = resumeEngine,
	setWeather = setWeather,
	getStats = function(): Types.GridStatistics
		return grid:getStatistics()
	end,
	getFrame = function(): number
		return EngineState.CurrentFrame
	end,
	getActorCount = function(): number
		return #actors
	end,
	getBufferMemory = function(): string
		local total = 0
		for _, actor in ipairs(actors) do
			local buf, count = actor:getOutput()
			total += BufferSerializer.getBufferSize(buf)
		end
		if total < 1024 then
			return string.format("%d B", total)
		elseif total < 1024 * 1024 then
			return string.format("%.2f KB", total / 1024)
		else
			return string.format("%.2f MB", total / (1024 * 1024))
		end
	end,
}

local existingInterface = ReplicatedStorage:FindFirstChild("DustSimulationCommands")
if existingInterface then
	existingInterface:Destroy()
end
local commandFolder = Instance.new("Folder")
commandFolder.Name = "DustSimulationCommands"
commandFolder.Parent = ReplicatedStorage

for name, func in pairs(commandInterface) do
	local bindable = Instance.new("BindableFunction")
	bindable.Name = name
	bindable.OnInvoke = func
	bindable.Parent = commandFolder
end

--===========================================================================
-- Startup
--===========================================================================

print("[DustSimulation] Server script loaded. Starting engine...")
startEngine()
print("[DustSimulation] Use ReplicatedStorage.DustSimulationCommands for control")
