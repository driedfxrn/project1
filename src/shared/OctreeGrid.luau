--!strict
-- OctreeGrid.luau
-- Custom spatial partitioning system for the dust simulation.
--
-- The city map is divided into thousands of 3D cells arranged in a uniform
-- grid. This module provides:
--   - Grid construction with configurable dimensions and cell size
--   - O(1) coordinate-to-cellId hashing
--   - Neighbor querying (6-face and 26-adjacency)
--   - Radius-based cell queries via the octree acceleration structure
--   - Sector assignment for parallel actor distribution
--   - World-space <-> grid-space coordinate conversion
--
-- The octree is built on top of the uniform grid to accelerate spatial
-- queries that span large areas (e.g., "all cells within 50 studs of
-- this vehicle"). Leaf nodes contain direct cell references.

local Types = require(script.Parent.Types)

local OctreeGrid = {}
OctreeGrid.__index = OctreeGrid

--===========================================================================
-- Internal Types
--===========================================================================

type GridInternal = {
	_dimensions: Types.Vector3Int,
	_cellSize: number,
	_origin: Vector3,
	_cells: { [number]: Types.GridCell },
	_cellByCoords: { [number]: { [number]: { [number]: Types.GridCell } } },
	_octreeRoot: OctreeNodeT?,
	_totalCells: number,
	_sectorAssignments: { Types.SectorAssignment },
	_computeNeighbors: (self: GridInternal) -> (),
	_buildOctree: (self: GridInternal) -> (),
	_buildOctreeNode: (self: GridInternal, cells: { Types.GridCell }, bounds: Types.OctreeBounds, depth: number, maxCells: number) -> OctreeNodeT,
	_computeOctantBounds: (self: GridInternal, parentBounds: Types.OctreeBounds, octant: number) -> Types.OctreeBounds,
	_assignSectors: (self: GridInternal, sectorCount: number) -> (),
	get26Neighbors: (self: GridInternal, cellId: number) -> { Types.GridCell },
	getSectorAssignments: (self: GridInternal) -> { Types.SectorAssignment },
	getSectorCells: (self: GridInternal, sectorId: number) -> { Types.GridCell },
	getCellById: (self: GridInternal, cellId: number) -> Types.GridCell?,
	getCellByCoords: (self: GridInternal, x: number, y: number, z: number) -> Types.GridCell?,
	getCellAtWorld: (self: GridInternal, worldPos: Vector3) -> Types.GridCell?,
	getCellIdAtWorld: (self: GridInternal, worldPos: Vector3) -> number?,
	getAllCells: (self: GridInternal) -> { Types.GridCell },
	getTotalCells: (self: GridInternal) -> number,
	getDimensions: (self: GridInternal) -> Types.Vector3Int,
	getCellSize: (self: GridInternal) -> number,
	getOrigin: (self: GridInternal) -> Vector3,
	getBounds: (self: GridInternal) -> Types.OctreeBounds,
	queryRadius: (self: GridInternal, worldPos: Vector3, radius: number) -> { Types.GridCell },
	queryRegion: (self: GridInternal, minPos: Vector3, maxPos: Vector3) -> { Types.GridCell },
	queryRay: (self: GridInternal, startPos: Vector3, endPos: Vector3) -> { Types.GridCell },
	getNearestCell: (self: GridInternal, worldPos: Vector3) -> Types.GridCell?,
	setCellDensity: (self: GridInternal, cellId: number, density: number) -> (),
	addCellDensity: (self: GridInternal, cellId: number, delta: number) -> (),
	setCellWind: (self: GridInternal, cellId: number, dirX: number, dirY: number, dirZ: number, magnitude: number) -> (),
	setCellDisturbance: (self: GridInternal, cellId: number, disturbance: number) -> (),
	setCellMaterial: (self: GridInternal, cellId: number, materialId: number) -> (),
	applyDisturbance: (self: GridInternal, worldPos: Vector3, radius: number, intensity: number) -> (),
	getStatistics: (self: GridInternal) -> Types.GridStatistics,
	getActiveCells: (self: GridInternal, threshold: number) -> { Types.GridCell },
	reset: (self: GridInternal) -> (),
	destroy: (self: GridInternal) -> (),
}

type OctreeNodeT = {
	bounds: Types.OctreeBounds,
	depth: number,
	cells: { Types.GridCell },
	children: { OctreeNodeT? },
	isLeaf: boolean,
	maxCells: number,
}

--===========================================================================
-- Utility Functions
--===========================================================================

--[[
	Hashes 3D grid coordinates into a unique 1D cell ID.
	Uses a cantor-pairing-style hash that guarantees uniqueness for
	grids up to 2^16 cells per axis (65536).
]]
local function coordsToId(x: number, y: number, z: number, dims: Types.Vector3Int): number
	-- Pack into a single integer: id = x + y*dims.x + z*dims.x*dims.y
	return x + (y * dims.x) + (z * dims.x * dims.y)
end

--[[
	Unpacks a 1D cell ID back into 3D grid coordinates.
]]
local function idToCoords(id: number, dims: Types.Vector3Int): Types.Vector3Int
	local xyPlane = dims.x * dims.y
	local z = math.floor(id / xyPlane)
	local remainder = id - (z * xyPlane)
	local y = math.floor(remainder / dims.x)
	local x = remainder - (y * dims.x)
	return { x = x, y = y, z = z }
end

--[[
	Converts grid coordinates to world-space position (center of cell).
]]
local function coordsToWorld(x: number, y: number, z: number, cellSize: number, origin: Vector3): Vector3
	return Vector3.new(
		origin.X + (x * cellSize) + (cellSize * 0.5),
		origin.Y + (y * cellSize) + (cellSize * 0.5),
		origin.Z + (z * cellSize) + (cellSize * 0.5)
	)
end

--[[
	Converts a world-space position to grid coordinates.
	Returns nil if the position is outside the grid bounds.
]]
local function worldToCoords(worldPos: Vector3, cellSize: number, origin: Vector3, dims: Types.Vector3Int): Types.Vector3Int?
	local localX = (worldPos.X - origin.X) / cellSize
	local localY = (worldPos.Y - origin.Y) / cellSize
	local localZ = (worldPos.Z - origin.Z) / cellSize

	local gx = math.floor(localX)
	local gy = math.floor(localY)
	local gz = math.floor(localZ)

	if gx < 0 or gx >= dims.x or gy < 0 or gy >= dims.y or gz < 0 or gz >= dims.z then
		return nil
	end

	return { x = gx, y = gy, z = gz }
end

--[[
	Computes the bounds of the entire grid in world space.
]]
local function computeGridBounds(dims: Types.Vector3Int, cellSize: number, origin: Vector3): Types.OctreeBounds
	local size = Vector3.new(dims.x * cellSize, dims.y * cellSize, dims.z * cellSize)
	local min = origin
	local max = origin + size
	local center = origin + (size * 0.5)
	return {
		min = min,
		max = max,
		center = center,
		size = size,
	}
end

--===========================================================================
-- Grid Construction
--===========================================================================

--[[
	Creates a new grid with the specified dimensions and cell size.
	All cells are initialized with zero density and default wind vectors.
]]
function OctreeGrid.new(config: Types.SimulationConfig, origin: Vector3?): OctreeGrid
	local dims = config.gridDimensions
	local cellSize = config.cellSize
	local gridOrigin = origin or Vector3.zero

	local self = setmetatable({
		_dimensions = dims,
		_cellSize = cellSize,
		_origin = gridOrigin,
		_cells = {},
		_cellByCoords = {},
		_octreeRoot = nil,
		_totalCells = 0,
		_sectorAssignments = {},
	}, OctreeGrid) :: any

	-- Initialize all cells
	for z = 0, dims.z - 1 do
		for y = 0, dims.y - 1 do
			for x = 0, dims.x - 1 do
				local id = coordsToId(x, y, z, dims)
				local worldPos = coordsToWorld(x, y, z, cellSize, gridOrigin)

				local cell: Types.GridCell = {
					id = id,
					coords = { x = x, y = y, z = z },
					worldPosition = worldPos,
					density = 0,
					wind = {
						directionX = 0,
						directionY = 0,
						directionZ = 0,
						magnitude = 0,
					},
					disturbance = 0,
					materialId = 0,
					neighborIds = {},
				}

				self._cells[id] = cell

				-- Index by coords for fast lookup
				if self._cellByCoords[x] == nil then
					self._cellByCoords[x] = {}
				end
				if self._cellByCoords[x][y] == nil then
					self._cellByCoords[x][y] = {}
				end
				self._cellByCoords[x][y][z] = cell

				self._totalCells += 1
			end
		end
	end

	-- Precompute neighbors for each cell
	self:_computeNeighbors()

	-- Build octree acceleration structure
	self:_buildOctree()

	-- Assign sectors for parallel processing
	self:_assignSectors(config.sectorCount)

	return self
end

--[[
	Computes and caches the 6-face neighbor IDs for each cell.
	This is used by the fluid dynamics solver for diffusion calculations.
]]
function OctreeGrid:_computeNeighbors(): ()
	local self = self :: GridInternal
	local dims = self._dimensions

	for id, cell in pairs(self._cells) do
		local x, y, z = cell.coords.x, cell.coords.y, cell.coords.z
		local neighbors = {}

		-- 6-face adjacency
		local offsets = {
			{ 1, 0, 0 },
			{ -1, 0, 0 },
			{ 0, 1, 0 },
			{ 0, -1, 0 },
			{ 0, 0, 1 },
			{ 0, 0, -1 },
		}

		for _, offset in ipairs(offsets) do
			local nx, ny, nz = x + offset[1], y + offset[2], z + offset[3]
			if nx >= 0 and nx < dims.x and ny >= 0 and ny < dims.y and nz >= 0 and nz < dims.z then
				local neighborId = coordsToId(nx, ny, nz, dims)
				table.insert(neighbors, neighborId)
			end
		end

		cell.neighborIds = neighbors
	end
end

--[[
	Computes the 26-adjacency neighbors (all surrounding cells including
	diagonals) for a given cell. This is used for more detailed diffusion
	and wind turbulence calculations.
]]
function OctreeGrid:get26Neighbors(cellId: number): { Types.GridCell }
	local self = self :: GridInternal
	local cell = self._cells[cellId]
	if cell == nil then
		return {}
	end

	local dims = self._dimensions
	local x, y, z = cell.coords.x, cell.coords.y, cell.coords.z
	local neighbors = {}

	for dz = -1, 1 do
		for dy = -1, 1 do
			for dx = -1, 1 do
				if dx == 0 and dy == 0 and dz == 0 then
					continue
				end
				local nx, ny, nz = x + dx, y + dy, z + dz
				if nx >= 0 and nx < dims.x and ny >= 0 and ny < dims.y and nz >= 0 and nz < dims.z then
					local neighbor = self:getCellByCoords(nx, ny, nz)
					if neighbor then
						table.insert(neighbors, neighbor)
					end
				end
			end
		end
	end

	return neighbors
end

--===========================================================================
-- Octree Construction
--===========================================================================

--[[
	Builds the octree acceleration structure on top of the uniform grid.
	The octree subdivides space recursively until each leaf node contains
	at most maxCells cells. This accelerates radius-based queries.
]]
function OctreeGrid:_buildOctree(): ()
	local self = self :: GridInternal
	local dims = self._dimensions
	local bounds = computeGridBounds(dims, self._cellSize, self._origin)

	-- Collect all cells into a flat array
	local allCells = {}
	for _, cell in pairs(self._cells) do
		table.insert(allCells, cell)
	end

	self._octreeRoot = self:_buildOctreeNode(allCells, bounds, 0, 8)
end

--[[
	Recursively builds an octree node. If the cell count exceeds maxCells
	and we haven't reached a single-cell region, we subdivide into 8 children.
]]
function OctreeGrid:_buildOctreeNode(
	cells: { Types.GridCell },
	bounds: Types.OctreeBounds,
	depth: number,
	maxCells: number
): OctreeNodeT
	local self = self :: GridInternal
	local node: OctreeNodeT = {
		bounds = bounds,
		depth = depth,
		cells = cells,
		children = {},
		isLeaf = true,
		maxCells = maxCells,
	}

	-- Don't subdivide if we're small enough or too deep
	if #cells <= maxCells or depth >= 8 then
		return node
	end

	-- Subdivide into 8 octants
	node.isLeaf = false
	node.cells = {} -- clear; only leaf nodes hold cells

	local center = bounds.center
	local octantCells: { { Types.GridCell } } = {}
	for i = 1, 8 do
		octantCells[i] = {}
	end

	for _, cell in ipairs(cells) do
		local pos = cell.worldPosition
		local octant = 0
		if pos.X >= center.X then octant += 1 end
		if pos.Y >= center.Y then octant += 2 end
		if pos.Z >= center.Z then octant += 4 end
		table.insert(octantCells[octant + 1], cell)
	end

	for i = 1, 8 do
		if #octantCells[i] > 0 then
			local childBounds = self:_computeOctantBounds(bounds, i - 1)
			node.children[i] = self:_buildOctreeNode(octantCells[i], childBounds, depth + 1, maxCells)
		end
	end

	return node
end

--[[
	Computes the bounds of a specific octant within a parent node's bounds.
	Octant index is 0-7, bit-encoded: bit0=X+, bit1=Y+, bit2=Z+.
]]
function OctreeGrid:_computeOctantBounds(parentBounds: Types.OctreeBounds, octant: number): Types.OctreeBounds
	local self = self :: GridInternal
	local min = parentBounds.min
	local center = parentBounds.center
	local half = parentBounds.size * 0.5

	local childMin = Vector3.new(
		if (octant % 2) >= 1 then center.X else min.X,
		if (octant % 4) >= 2 then center.Y else min.Y,
		if octant >= 4 then center.Z else min.Z
	)

	return {
		min = childMin,
		max = childMin + half,
		center = childMin + (half * 0.5),
		size = half,
	}
end

--===========================================================================
-- Sector Assignment
--===========================================================================

--[[
	Divides the grid into contiguous sectors for parallel actor processing.
	Sectors are assigned along the X axis for cache locality, then wrapped
	to Y and Z if needed. Each sector gets a contiguous range of cell IDs.
]]
function OctreeGrid:_assignSectors(sectorCount: number): ()
	local self = self :: GridInternal
	local totalCells = self._totalCells
	if sectorCount <= 0 then
		sectorCount = 1
	end

	local cellsPerSector = math.ceil(totalCells / sectorCount)
	local assignments = {}

	for i = 0, sectorCount - 1 do
		local startCell = i * cellsPerSector
		local endCell = math.min(startCell + cellsPerSector - 1, totalCells - 1)
		if startCell < totalCells then
			table.insert(assignments, {
				sectorId = i,
				startCell = startCell,
				endCell = endCell,
				cellCount = endCell - startCell + 1,
			})
		end
	end

	self._sectorAssignments = assignments
end

--[[
	Returns the sector assignments for parallel processing.
]]
function OctreeGrid:getSectorAssignments(): { Types.SectorAssignment }
	local self = self :: GridInternal
	return self._sectorAssignments
end

--[[
	Returns the cells belonging to a specific sector.
]]
function OctreeGrid:getSectorCells(sectorId: number): { Types.GridCell }
	local self = self :: GridInternal
	local assignment = self._sectorAssignments[sectorId + 1]
	if assignment == nil then
		return {}
	end

	local cells = {}
	for id = assignment.startCell, assignment.endCell do
		local cell = self._cells[id]
		if cell then
			table.insert(cells, cell)
		end
	end
	return cells
end

--===========================================================================
-- Cell Access
--===========================================================================

--[[
	Returns the cell with the given ID, or nil if it doesn't exist.
]]
function OctreeGrid:getCellById(cellId: number): Types.GridCell?
	local self = self :: GridInternal
	return self._cells[cellId]
end

--[[
	Returns the cell at the given grid coordinates, or nil if out of bounds.
]]
function OctreeGrid:getCellByCoords(x: number, y: number, z: number): Types.GridCell?
	local self = self :: GridInternal
	local xTable = self._cellByCoords[x]
	if xTable == nil then
		return nil
	end
	local yTable = xTable[y]
	if yTable == nil then
		return nil
	end
	return yTable[z]
end

--[[
	Returns the cell at the given world position, or nil if outside the grid.
]]
function OctreeGrid:getCellAtWorld(worldPos: Vector3): Types.GridCell?
	local self = self :: GridInternal
	local coords = worldToCoords(worldPos, self._cellSize, self._origin, self._dimensions)
	if coords == nil then
		return nil
	end
	return self:getCellByCoords(coords.x, coords.y, coords.z)
end

--[[
	Returns the cell ID at the given world position, or nil if outside the grid.
]]
function OctreeGrid:getCellIdAtWorld(worldPos: Vector3): number?
	local self = self :: GridInternal
	local coords = worldToCoords(worldPos, self._cellSize, self._origin, self._dimensions)
	if coords == nil then
		return nil
	end
	return coordsToId(coords.x, coords.y, coords.z, self._dimensions)
end

--[[
	Returns all cells in the grid as a flat array.
]]
function OctreeGrid:getAllCells(): { Types.GridCell }
	local self = self :: GridInternal
	local cells = {}
	for _, cell in pairs(self._cells) do
		table.insert(cells, cell)
	end
	return cells
end

--[[
	Returns the total number of cells in the grid.
]]
function OctreeGrid:getTotalCells(): number
	local self = self :: GridInternal
	return self._totalCells
end

--[[
	Returns the grid dimensions.
]]
function OctreeGrid:getDimensions(): Types.Vector3Int
	local self = self :: GridInternal
	return self._dimensions
end

--[[
	Returns the cell size.
]]
function OctreeGrid:getCellSize(): number
	local self = self :: GridInternal
	return self._cellSize
end

--[[
	Returns the grid origin in world space.
]]
function OctreeGrid:getOrigin(): Vector3
	local self = self :: GridInternal
	return self._origin
end

--[[
	Returns the total world-space bounds of the grid.
]]
function OctreeGrid:getBounds(): Types.OctreeBounds
	local self = self :: GridInternal
	return computeGridBounds(self._dimensions, self._cellSize, self._origin)
end

--===========================================================================
-- Spatial Queries
--===========================================================================

--[[
	Returns all cells within the specified radius of a world position.
	Uses the octree to prune distant cells efficiently.
]]
function OctreeGrid:queryRadius(worldPos: Vector3, radius: number): { Types.GridCell }
	local self = self :: GridInternal
	local results = {}
	local radiusSq = radius * radius

	local function recurseNode(node: OctreeNodeT?)
		if node == nil then
			return
		end
		-- Check if node bounds intersect the query sphere
		local closest = Vector3.new(
			math.clamp(worldPos.X, node.bounds.min.X, node.bounds.max.X),
			math.clamp(worldPos.Y, node.bounds.min.Y, node.bounds.max.Y),
			math.clamp(worldPos.Z, node.bounds.min.Z, node.bounds.max.Z)
		)
		local distSq = (worldPos - closest).Magnitude
		if distSq > radiusSq then
			return -- node is too far
		end

		if node.isLeaf then
			for _, cell in ipairs(node.cells) do
				local cellDistSq = (cell.worldPosition - worldPos).Magnitude
				if cellDistSq <= radiusSq then
					table.insert(results, cell)
				end
			end
		else
			for _, child in ipairs(node.children) do
				recurseNode(child)
			end
		end
	end

	recurseNode(self._octreeRoot)
	return results
end

--[[
	Returns all cells within a rectangular region defined by min and max
	world coordinates.
]]
function OctreeGrid:queryRegion(minPos: Vector3, maxPos: Vector3): { Types.GridCell }
	local self = self :: GridInternal
	local results = {}

	local function recurseNode(node: OctreeNodeT?)
		if node == nil then
			return
		end
		-- Check if node bounds intersect the query box
		if node.bounds.max.X < minPos.X or node.bounds.min.X > maxPos.X then
			return
		end
		if node.bounds.max.Y < minPos.Y or node.bounds.min.Y > maxPos.Y then
			return
		end
		if node.bounds.max.Z < minPos.Z or node.bounds.min.Z > maxPos.Z then
			return
		end

		if node.isLeaf then
			for _, cell in ipairs(node.cells) do
				local pos = cell.worldPosition
				if pos.X >= minPos.X and pos.X <= maxPos.X
					and pos.Y >= minPos.Y and pos.Y <= maxPos.Y
					and pos.Z >= minPos.Z and pos.Z <= maxPos.Z
				then
					table.insert(results, cell)
				end
			end
		else
			for _, child in ipairs(node.children) do
				recurseNode(child)
			end
		end
	end

	recurseNode(self._octreeRoot)
	return results
end

--[[
	Returns all cells along a ray (line segment) from start to end position.
	Useful for vehicle path disturbance queries.
]]
function OctreeGrid:queryRay(startPos: Vector3, endPos: Vector3): { Types.GridCell }
	local self = self :: GridInternal
	local results = {}
	local direction = endPos - startPos
	local length = direction.Magnitude
	local normalized = direction / length

	-- DDA-based voxel traversal
	local cellSize = self._cellSize
	local currentCoords = worldToCoords(startPos, cellSize, self._origin, self._dimensions)
	if currentCoords == nil then
		return results
	end

	local stepX = if normalized.X > 0 then 1 elseif normalized.X < 0 then -1 else 0
	local stepY = if normalized.Y > 0 then 1 elseif normalized.Y < 0 then -1 else 0
	local stepZ = if normalized.Z > 0 then 1 elseif normalized.Z < 0 then -1 else 0

	local tDeltaX = if stepX ~= 0 then math.abs(cellSize / normalized.X) else math.huge
	local tDeltaY = if stepY ~= 0 then math.abs(cellSize / normalized.Y) else math.huge
	local tDeltaZ = if stepZ ~= 0 then math.abs(cellSize / normalized.Z) else math.huge

	local x, y, z = currentCoords.x, currentCoords.y, currentCoords.z
	local tMaxX = tDeltaX * 0.5
	local tMaxY = tDeltaY * 0.5
	local tMaxZ = tDeltaZ * 0.5

	local traveled = 0
	local maxIterations = self._totalCells -- safety limit

	for _ = 1, maxIterations do
		if traveled > length then
			break
		end

		local cell = self:getCellByCoords(x, y, z)
		if cell then
			table.insert(results, cell)
		end

		-- Advance to next cell
		if tMaxX < tMaxY and tMaxX < tMaxZ then
			x += stepX
			traveled = tMaxX
			tMaxX += tDeltaX
		elseif tMaxY < tMaxZ then
			y += stepY
			traveled = tMaxY
			tMaxY += tDeltaY
		else
			z += stepZ
			traveled = tMaxZ
			tMaxZ += tDeltaZ
		end

		-- Bounds check
		if x < 0 or x >= self._dimensions.x
			or y < 0 or y >= self._dimensions.y
			or z < 0 or z >= self._dimensions.z
		then
			break
		end
	end

	return results
end

--[[
	Returns the nearest cell to a world position. If the position is inside
	the grid, this is the cell at that position. Otherwise, it finds the
	closest boundary cell.
]]
function OctreeGrid:getNearestCell(worldPos: Vector3): Types.GridCell?
	local self = self :: GridInternal
	local direct = self:getCellAtWorld(worldPos)
	if direct then
		return direct
	end

	-- Clamp to grid bounds and find the closest cell
	local bounds = self:getBounds()
	local clamped = Vector3.new(
		math.clamp(worldPos.X, bounds.min.X, bounds.max.X - 0.01),
		math.clamp(worldPos.Y, bounds.min.Y, bounds.max.Y - 0.01),
		math.clamp(worldPos.Z, bounds.min.Z, bounds.max.Z - 0.01)
	)
	return self:getCellAtWorld(clamped)
end

--===========================================================================
-- Cell Modification
--===========================================================================

--[[
	Sets the dust density of a cell by ID.
]]
function OctreeGrid:setCellDensity(cellId: number, density: number): ()
	local self = self :: GridInternal
	local cell = self._cells[cellId]
	if cell then
		cell.density = math.clamp(density, 0, 1)
	end
end

--[[
	Adds to the dust density of a cell by ID. Clamped to [0, 1].
]]
function OctreeGrid:addCellDensity(cellId: number, delta: number): ()
	local self = self :: GridInternal
	local cell = self._cells[cellId]
	if cell then
		cell.density = math.clamp(cell.density + delta, 0, 1)
	end
end

--[[
	Sets the wind vector of a cell by ID.
]]
function OctreeGrid:setCellWind(cellId: number, dirX: number, dirY: number, dirZ: number, magnitude: number): ()
	local self = self :: GridInternal
	local cell = self._cells[cellId]
	if cell then
		cell.wind.directionX = dirX
		cell.wind.directionY = dirY
		cell.wind.directionZ = dirZ
		cell.wind.magnitude = magnitude
	end
end

--[[
	Sets the disturbance level of a cell by ID.
]]
function OctreeGrid:setCellDisturbance(cellId: number, disturbance: number): ()
	local self = self :: GridInternal
	local cell = self._cells[cellId]
	if cell then
		cell.disturbance = math.clamp(disturbance, 0, 1)
	end
end

--[[
	Sets the material ID of a cell by ID.
]]
function OctreeGrid:setCellMaterial(cellId: number, materialId: number): ()
	local self = self :: GridInternal
	local cell = self._cells[cellId]
	if cell then
		cell.materialId = materialId
	end
end

--[[
	Applies a disturbance event to all cells within the given radius.
	The disturbance falls off linearly from the center.
]]
function OctreeGrid:applyDisturbance(worldPos: Vector3, radius: number, intensity: number): ()
	local self = self :: GridInternal
	local cells = self:queryRadius(worldPos, radius)
	for _, cell in ipairs(cells) do
		local dist = (cell.worldPosition - worldPos).Magnitude
		local falloff = 1 - (dist / radius)
		cell.disturbance = math.clamp(cell.disturbance + (intensity * falloff), 0, 1)
	end
end

--===========================================================================
-- Statistics
--===========================================================================

--[[
	Computes aggregate statistics over the entire grid.
]]
function OctreeGrid:getStatistics(): Types.GridStatistics
	local self = self :: GridInternal
	local totalDensity = 0
	local maxDensity = 0
	local activeCells = 0
	local totalDustMass = 0

	for _, cell in pairs(self._cells) do
		totalDensity += cell.density
		if cell.density > maxDensity then
			maxDensity = cell.density
		end
		if cell.density > 0.01 then
			activeCells += 1
			totalDustMass += cell.density
		end
	end

	return {
		totalCells = self._totalCells,
		activeCells = activeCells,
		averageDensity = if self._totalCells > 0 then totalDensity / self._totalCells else 0,
		maxDensity = maxDensity,
		totalDustMass = totalDustMass,
		sectorsProcessed = #self._sectorAssignments,
		processingTimeMs = 0,
	}
end

--[[
	Returns a list of cells that exceed the given density threshold.
	Used by the server to determine which cells to visualize.
]]
function OctreeGrid:getActiveCells(threshold: number): { Types.GridCell }
	local self = self :: GridInternal
	local results = {}
	for _, cell in pairs(self._cells) do
		if cell.density >= threshold then
			table.insert(results, cell)
		end
	end
	return results
end

--[[
	Resets all cell densities, disturbances, and wind vectors to zero.
]]
function OctreeGrid:reset(): ()
	local self = self :: GridInternal
	for _, cell in pairs(self._cells) do
		cell.density = 0
		cell.disturbance = 0
		cell.wind.directionX = 0
		cell.wind.directionY = 0
		cell.wind.directionZ = 0
		cell.wind.magnitude = 0
	end
end

--[[
	Destroys the grid and releases all references.
]]
function OctreeGrid:destroy(): ()
	local self = self :: GridInternal
	self._cells = {}
	self._cellByCoords = {}
	self._octreeRoot = nil
	self._sectorAssignments = {}
	setmetatable(self :: any, nil)
end

--===========================================================================
-- Coordinate Conversion Utilities (exposed)
--===========================================================================

OctreeGrid.coordsToId = coordsToId
OctreeGrid.idToCoords = idToCoords
OctreeGrid.coordsToWorld = coordsToWorld
OctreeGrid.worldToCoords = worldToCoords

export type OctreeGrid = GridInternal

return OctreeGrid