--!strict
-- BulkRenderEngine.luau
-- Client-side rendering engine for the Dynamic Road Dust & Particulate Simulation.
--
-- This is the "Production" layer rendering engine. It:
--   1. Receives binary frame buffers from the server via RemoteEvent
--   2. Deserializes cell data using BufferSerializer.readCellFields
--   3. Maps cell IDs to world positions using the grid coordinate system
--   4. Manages dust particle parts via ObjectPool (O(1) acquire/release)
--   5. Updates all particle positions in a single workspace:BulkMoveTo call
--   6. Applies material-based coloring and density-based size scaling
--   7. Simulates dust kick-up height based on disturbance level
--   8. Applies wind drift to particle positions
--
-- Key optimization: workspace:BulkMoveTo submits thousands of CFrame updates
-- in a single Lua->C++ bridge call, eliminating per-part overhead. This is
-- critical for rendering thousands of dust particles at 60fps without stutter.
--
-- The engine decouples frame processing (ProcessFrame, called on server tick)
-- from rendering (Flush, called on Heartbeat) to allow smooth visual updates
-- between simulation steps. ProcessFrame handles pool management (acquiring/
-- releasing parts), while Flush re-reads cell data to compute fresh CFrames
-- and submits them via BulkMoveTo at the render frame rate.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared:WaitForChild("Types"))
local BufferSerializer = require(Shared:WaitForChild("BufferSerializer"))
local ObjectPool = require(Shared:WaitForChild("ObjectPool"))
local MaterialsCatalog = require(Shared:WaitForChild("MaterialsCatalog"))

--===========================================================================
-- Constants
--===========================================================================

-- Frame header is 16 bytes at the start of frame buffers.
-- This must be passed to readCellFields to skip the header when reading cell data.
-- The header contains: frameId (u32), cellCount (u32), timestamp (f32), reserved (u32)
local FRAME_HEADER_SIZE = 16

-- Particle visual defaults
local BASE_PART_SIZE = 3.0
local PART_HEIGHT = 0.8
local MAX_EMISSION_HEIGHT = 8.0 -- max height dust kicks up from disturbance
local WIND_DRIFT_SCALE = 0.5 -- how much wind affects particle horizontal position
local DENSITY_SIZE_SCALE = 4.0 -- max size multiplier from high density
local TRANSPARENCY_MIN = 0.2 -- most opaque (at max density)
local TRANSPARENCY_MAX = 0.9 -- most transparent (at threshold density)

-- Object pool configuration
local POOL_INITIAL_SIZE = 200
local POOL_GROWTH_RATE = 100
local POOL_CULL_THRESHOLD = 300
local POOL_CULL_INTERVAL = 120

--===========================================================================
-- Module Setup
--===========================================================================

local BulkRenderEngine = {}
BulkRenderEngine.__index = BulkRenderEngine

--===========================================================================
-- Internal Type Definition
--===========================================================================

type RenderEngineT = {
	_config: Types.ClientRenderConfig,
	_pool: any,
	_partFolder: Folder,
	_template: BasePart,
	_partArray: { BasePart },
	_cframeArray: { CFrame },
	_cellToWorld: { [number]: Vector3 },
	_cellToPart: { [number]: BasePart },
	_partToCell: { [BasePart]: number },
	-- Stored frame data for Flush to re-read at render rate
	_frameBuffer: buffer?,
	_frameCellCount: number,
	_frameId: number,
	_lastFrameId: number,
	_activeCellCount: number,
	_renderTimeMs: number,
	_totalFramesProcessed: number,
	_initialized: boolean,
	ProcessFrame: (self: RenderEngineT, frameBuffer: buffer, cellCount: number, frameId: number) -> (),
	Flush: (self: RenderEngineT) -> (),
	UpdateConfig: (self: RenderEngineT, config: Types.ClientRenderConfig) -> (),
	GetStats: (self: RenderEngineT) -> Types.ClientVisualizationState,
	Destroy: (self: RenderEngineT) -> (),
}

--===========================================================================
-- Helper Functions
--===========================================================================

--[[
	Pre-computes world positions for all cell IDs in the grid.
	This avoids repeated coordinate unpacking during frame processing.

	The cell ID encoding is: id = x + (y * dims.x) + (z * dims.x * dims.y)
	The world position is: origin + (coords * cellSize) + (cellSize * 0.5)
]]
local function precomputeCellPositions(config: Types.ClientRenderConfig): { [number]: Vector3 }
	local dims = config.gridDimensions
	local cellSize = config.cellSize
	local origin = config.origin
	local positions: { [number]: Vector3 } = {}

	local xyPlane = dims.x * dims.y

	for z = 0, dims.z - 1 do
		for y = 0, dims.y - 1 do
			for x = 0, dims.x - 1 do
				local id = x + (y * dims.x) + (z * xyPlane)
				positions[id] = Vector3.new(
					origin.X + (x * cellSize) + (cellSize * 0.5),
					origin.Y + (y * cellSize) + (cellSize * 0.5),
					origin.Z + (z * cellSize) + (cellSize * 0.5)
				)
			end
		end
	end

	return positions
end

--[[
	Creates the template part for dust particles.
	All pooled parts are clones of this template. The template is never
	directly visible - it serves only as a prototype for cloning.
]]
local function createTemplatePart(): BasePart
	local part = Instance.new("Part")
	part.Name = "DustParticle"
	part.Size = Vector3.new(BASE_PART_SIZE, PART_HEIGHT, BASE_PART_SIZE)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Material = Enum.Material.SmoothPlastic
	part.Shape = Enum.PartType.Ball
	part.Position = Vector3.new(0, -100000, 0) -- off-screen holding position
	return part
end

--[[
	Computes the target CFrame for a dust particle based on cell data.
	Includes vertical height offset from disturbance (dust kicks up) and
	horizontal wind drift (dust blows with the wind).

	Parameters:
	  worldPos    - base world position of the grid cell
	  density     - dust density (0.0 to 1.0)
	  windX       - wind direction X component
	  windZ       - wind direction Z component
	  windMag     - wind magnitude in studs/s
	  disturbance - disturbance level (0.0 to 1.0)

	Returns: CFrame at the computed position
]]
local function computeParticleCFrame(
	worldPos: Vector3,
	density: number,
	windX: number,
	windZ: number,
	windMag: number,
	disturbance: number
): CFrame
	-- Height offset: dust rises with disturbance level
	-- More disturbance = higher kick-up (e.g., vehicle driving over dust)
	local heightOffset = disturbance * MAX_EMISSION_HEIGHT

	-- Wind drift: particles shift horizontally in wind direction
	-- Stronger wind = more drift
	local driftX = windX * windMag * WIND_DRIFT_SCALE
	local driftZ = windZ * windMag * WIND_DRIFT_SCALE

	-- Final position combines base cell position, wind drift, and height
	local finalPos = Vector3.new(
		worldPos.X + driftX,
		worldPos.Y + heightOffset,
		worldPos.Z + driftZ
	)

	return CFrame.new(finalPos)
end

--===========================================================================
-- Constructor
--===========================================================================

--[[
	Creates a new BulkRenderEngine with the given client render configuration.

	The engine initializes:
	  - An ObjectPool for dust particle parts (pre-allocated, O(1) acquire/release)
	  - A pre-computed cell ID -> world position lookup table
	  - A workspace folder to contain all dust particle parts
	  - A template part used for cloning by the object pool

	Parameters:
	  config - ClientRenderConfig containing grid dimensions, cell size,
	           origin, visualization threshold, and max particle count

	Returns: BulkRenderEngine instance
]]
function BulkRenderEngine.new(config: Types.ClientRenderConfig): any
	-- Create a dedicated folder in Workspace for dust particles
	-- This keeps the workspace hierarchy clean and allows easy cleanup
	local partFolder = Instance.new("Folder")
	partFolder.Name = "DustParticles"
	partFolder.Parent = Workspace

	-- Create the template part that will be cloned for each dust particle
	local template = createTemplatePart()

	-- Create the object pool for efficient particle part management
	-- The pool pre-allocates parts and recycles them, avoiding GC pressure
	-- from creating/destroying parts every frame
	local poolConfig: Types.ObjectPoolConfig = {
		template = template,
		initialSize = POOL_INITIAL_SIZE,
		maxSize = config.maxParticles,
		growthRate = POOL_GROWTH_RATE,
		cullThreshold = POOL_CULL_THRESHOLD,
		cullInterval = POOL_CULL_INTERVAL,
	}
	local pool = ObjectPool.new(poolConfig, partFolder)

	-- Pre-compute world positions for all possible cell IDs
	-- This is a one-time O(n) cost that enables O(1) position lookup per frame
	local cellToWorld = precomputeCellPositions(config)

	local self = setmetatable({
		_config = config,
		_pool = pool,
		_partFolder = partFolder,
		_template = template,
		_partArray = {},
		_cframeArray = {},
		_cellToWorld = cellToWorld,
		_cellToPart = {},
		_partToCell = {},
		_frameBuffer = nil :: buffer?,
		_frameCellCount = 0,
		_frameId = 0,
		_lastFrameId = 0,
		_activeCellCount = 0,
		_renderTimeMs = 0,
		_totalFramesProcessed = 0,
		_initialized = true,
	}, BulkRenderEngine) :: any

	return self
end

--===========================================================================
-- Frame Processing
--===========================================================================

--[[
	Processes a simulation frame received from the server.

	Reads cell data from the binary frame buffer using readCellFields with
	FRAME_HEADER_SIZE to skip the 16-byte frame header. Determines which cells
	exceed the visualization threshold and manages the object pool by acquiring
	parts for newly-active cells and releasing parts for cells that are no
	longer visible. Sets material-based color and density-based size/transparency.

	The frame buffer is stored for Flush to re-read at render rate, allowing
	CFrame computation to happen on Heartbeat (60fps) even when simulation
	ticks run at a lower rate (30fps). This decoupling ensures smooth visual
	updates between simulation steps.

	Parameters:
	  frameBuffer - binary buffer containing frame header + cell data
	  cellCount   - number of cells in the frame
	  frameId     - simulation frame ID for tracking
]]
function BulkRenderEngine:ProcessFrame(frameBuffer: buffer, cellCount: number, frameId: number): ()
	local self = self :: RenderEngineT
	local startTime = os.clock()

	self._frameId = frameId
	self._totalFramesProcessed += 1

	-- Store the frame buffer for Flush to re-read at render rate
	self._frameBuffer = frameBuffer
	self._frameCellCount = cellCount

	local threshold = self._config.visualizationThreshold
	local cellToWorld = self._cellToWorld
	local cellToPart = self._cellToPart
	local partToCell = self._partToCell
	local pool = self._pool

	-- Track which cells are active this frame (for release detection)
	local activeThisFrame: { [number]: boolean } = {}

	local activeCount = 0

	-- Iterate over all cells in the frame buffer
	-- readCellFields returns 7 values: cellId, density, windX, windZ,
	-- windMag, disturbance, materialId
	-- We pass FRAME_HEADER_SIZE (16) as the header offset to skip the
	-- 16-byte frame header at the start of the buffer
	for i = 0, cellCount - 1 do
		local cellId, density, windX, windZ, windMag, disturbance, materialId =
			BufferSerializer.readCellFields(frameBuffer, i, FRAME_HEADER_SIZE)

		-- Skip cells below the visualization threshold
		if density < threshold then
			continue
		end

		-- Look up pre-computed world position for this cell ID
		local worldPos = cellToWorld[cellId]
		if worldPos == nil then
			continue
		end

		activeThisFrame[cellId] = true
		activeCount += 1

		-- Acquire or reuse a particle part for this cell
		local part = cellToPart[cellId]
		if part == nil then
			-- New active cell - acquire a part from the pool
			local acquired = pool:Acquire()
			if acquired == nil then
				-- Pool exhausted at max capacity - skip this cell
				continue
			end
			part = acquired :: BasePart
			cellToPart[cellId] = part
			partToCell[part] = cellId

			-- Set initial color based on the cell's material type
			-- Color is only set once when the part is acquired
			local materialColor = MaterialsCatalog.getColor(materialId)
			part.Color = materialColor
		end

		-- Update particle size based on density and material properties
		-- Higher density = larger particle; material multiplier affects base size
		local sizeScale = 1.0 + (density * DENSITY_SIZE_SCALE)
		local materialSize = MaterialsCatalog.getParticleSize(materialId)
		local finalSize = BASE_PART_SIZE * sizeScale * materialSize * 0.3
		part.Size = Vector3.new(finalSize, PART_HEIGHT, finalSize)

		-- Update transparency based on density
		-- More dust = more opaque; less dust = more transparent
		local transparency = TRANSPARENCY_MAX - (density * (TRANSPARENCY_MAX - TRANSPARENCY_MIN))
		part.Transparency = transparency
	end

	-- Release parts for cells that are no longer above the threshold
	-- This recycles parts back to the pool for reuse by other cells
	local cellsToRemove: { number } = {}
	for cellId, _ in pairs(cellToPart) do
		if not activeThisFrame[cellId] then
			table.insert(cellsToRemove, cellId)
		end
	end

	for _, cellId in ipairs(cellsToRemove) do
		local part = cellToPart[cellId]
		if part then
			pool:Release(part)
			cellToPart[cellId] = nil
			partToCell[part] = nil
		end
	end

	-- Update statistics
	self._activeCellCount = activeCount
	self._renderTimeMs = (os.clock() - startTime) * 1000
	self._lastFrameId = frameId
end

--===========================================================================
-- Render Flush
--===========================================================================

--[[
	Flushes the prepared particle updates to the renderer.

	Re-reads cell data from the stored frame buffer using readCellFields with
	FRAME_HEADER_SIZE to compute fresh CFrames for all active particles. This
	allows CFrame computation to happen at the render frame rate (Heartbeat,
	typically 60fps) even when simulation frames arrive at a lower rate.

	Uses workspace:BulkMoveTo to submit all CFrame changes in a single
	C++ bridge call. This is dramatically faster than setting .CFrame
	on each part individually, which would cross the Lua->C++ bridge
	once per part (thousands of times per frame).

	Enum.BulkMoveMode.FireCFrameChanged ensures that property change
	signals are triggered, maintaining compatibility with any systems
	that listen for CFrame changes.

	This method is called on Heartbeat (every render frame, typically 60fps).
	If no frame buffer is stored or no parts are active, it returns immediately.
]]
function BulkRenderEngine:Flush(): ()
	local self = self :: RenderEngineT

	-- Need a stored frame buffer to read cell data from
	local frameBuffer = self._frameBuffer
	if frameBuffer == nil then
		return
	end

	local cellCount = self._frameCellCount
	if cellCount == 0 then
		return
	end

	local threshold = self._config.visualizationThreshold
	local cellToWorld = self._cellToWorld
	local cellToPart = self._cellToPart

	-- Clear the batch arrays for rebuilding
	table.clear(self._partArray)
	table.clear(self._cframeArray)

	-- Re-read cell data from the stored frame buffer to compute fresh CFrames
	-- We pass FRAME_HEADER_SIZE (16) as the header offset to skip the
	-- 16-byte frame header at the start of the buffer
	for i = 0, cellCount - 1 do
		local cellId, density, windX, windZ, windMag, disturbance, materialId =
			BufferSerializer.readCellFields(frameBuffer, i, FRAME_HEADER_SIZE)

		-- Skip cells below the visualization threshold
		if density < threshold then
			continue
		end

		-- Look up pre-computed world position for this cell ID
		local worldPos = cellToWorld[cellId]
		if worldPos == nil then
			continue
		end

		-- Get the part assigned to this cell (allocated in ProcessFrame)
		local part = cellToPart[cellId]
		if part == nil then
			continue
		end

		-- Compute the target CFrame with disturbance height and wind drift
		local targetCFrame = computeParticleCFrame(
			worldPos, density, windX, windZ, windMag, disturbance
		)

		-- Add to batch arrays for BulkMoveTo
		table.insert(self._partArray, part)
		table.insert(self._cframeArray, targetCFrame)
	end

	local partCount = #self._partArray
	if partCount == 0 then
		return
	end

	-- Single C++ bridge call for all particle position updates
	-- This is the critical performance optimization: instead of N individual
	-- .CFrame assignments (N bridge crossings), we do 1 BulkMoveTo call
	Workspace:BulkMoveTo(
		self._partArray,
		self._cframeArray,
		Enum.BulkMoveMode.FireCFrameChanged
	)
end

--===========================================================================
-- Configuration Update
--===========================================================================

--[[
	Updates the render configuration. Called when the server sends
	updated configuration data via the configRequestRemote.

	If grid dimensions change, the cell position cache is rebuilt.
	If max particle count changes, the object pool is resized.

	Parameters:
	  config - updated ClientRenderConfig from the server
]]
function BulkRenderEngine:UpdateConfig(config: Types.ClientRenderConfig): ()
	local self = self :: RenderEngineT

	-- Check if grid dimensions changed before updating config
	local oldDims = self._config.gridDimensions
	local dimsChanged = config.gridDimensions.x ~= oldDims.x
		or config.gridDimensions.y ~= oldDims.y
		or config.gridDimensions.z ~= oldDims.z

	-- Check if max particle count changed
	local maxParticlesChanged = config.maxParticles ~= self._config.maxParticles

	-- Update the configuration
	self._config = config

	-- Rebuild cell position cache if grid dimensions changed
	if dimsChanged then
		self._cellToWorld = precomputeCellPositions(config)
	end

	-- Resize the object pool if max particles changed
	if maxParticlesChanged then
		self._pool:Resize(config.maxParticles)
	end
end

--===========================================================================
-- Statistics
--===========================================================================

--[[
	Returns current rendering statistics for the debug HUD.

	Returns a ClientVisualizationState containing:
	  - visibleParticles: count of currently active (in-use) parts
	  - pooledParts: count of available (free) parts in the pool
	  - activeCells: number of cells above the visualization threshold
	  - renderTimeMs: time spent processing the last frame in milliseconds
	  - lastFrameId: the most recently processed frame ID
]]
function BulkRenderEngine:GetStats(): Types.ClientVisualizationState
	local self = self :: RenderEngineT
	return {
		visibleParticles = self._pool:GetActiveCount(),
		pooledParts = self._pool:GetPooledCount(),
		activeCells = self._activeCellCount,
		renderTimeMs = self._renderTimeMs,
		lastFrameId = self._lastFrameId,
	}
end

--===========================================================================
-- Cleanup
--===========================================================================

--[[
	Destroys the render engine and releases all resources.

	- Releases all active parts back to the pool
	- Destroys the object pool and all managed parts
	- Clears all mapping tables and position caches
	- Removes the dust particle folder from the workspace
	- Destroys the template part

	Call this when the client is cleaning up (e.g., player leaving).
]]
function BulkRenderEngine:Destroy(): ()
	local self = self :: RenderEngineT

	-- Release all active parts back to the pool
	self._pool:ReleaseAll()

	-- Destroy the pool and all its managed parts
	self._pool:Destroy()

	-- Clear all mapping tables
	table.clear(self._cellToPart)
	table.clear(self._partToCell)
	table.clear(self._partArray)
	table.clear(self._cframeArray)
	table.clear(self._cellToWorld)

	-- Clear stored frame data
	self._frameBuffer = nil
	self._frameCellCount = 0

	-- Remove the dust particle folder from the workspace
	if self._partFolder then
		self._partFolder:Destroy()
	end

	-- Destroy the template part
	if self._template then
		self._template:Destroy()
	end

	self._initialized = false
	setmetatable(self :: any, nil)
end

export type BulkRenderEngine = RenderEngineT

return BulkRenderEngine