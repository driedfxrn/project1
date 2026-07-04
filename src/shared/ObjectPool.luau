--!strict
-- ObjectPool.luau
-- Custom object pooling system for managing dust particle meshes.
--
-- Instead of creating and destroying BaseParts every frame (which causes
-- severe GC pressure and frame stutter), this pool pre-allocates a set of
-- parts and recycles them. When a grid cell's dust density reaches the
-- visualization threshold, the client grabs a part from the pool. When a
-- particle settles or fades, the part is returned to the pool.
--
-- Features:
--   - Pre-allocation with configurable initial size
--   - Dynamic growth up to a max cap
--   - Automatic culling of idle entries past a threshold
--   - O(1) acquire/release via free-list stack
--   - Full strict typing
--   - Decoupled from simulation logic (pure Production layer)

local Types = require(script.Parent.Types)

local ObjectPool = {}
ObjectPool.__index = ObjectPool

type PoolEntryT = {
	part: BasePart,
	inUse: boolean,
	lastUsedFrame: number,
	densityValue: number,
}

type ObjectPoolT = {
	_config: Types.ObjectPoolConfig,
	_entries: { PoolEntryT },
	_freeList: { number },
	_activeCount: number,
	_totalCreated: number,
	_totalAcquired: number,
	_totalReleased: number,
	_currentFrame: number,
	_lastCullFrame: number,
	_template: BasePart,
	_parent: Instance,
	_createEntry: (self: ObjectPoolT) -> PoolEntryT,
	Acquire: (self: ObjectPoolT) -> BasePart?,
	Release: (self: ObjectPoolT, part: BasePart) -> (),
	ReleaseAll: (self: ObjectPoolT) -> (),
	GetActiveCount: (self: ObjectPoolT) -> number,
	GetPooledCount: (self: ObjectPoolT) -> number,
	GetTotalCount: (self: ObjectPoolT) -> number,
	GetTotalAcquired: (self: ObjectPoolT) -> number,
	GetTotalReleased: (self: ObjectPoolT) -> number,
	SetFrame: (self: ObjectPoolT, frame: number) -> (),
	CullIdle: (self: ObjectPoolT, frameThreshold: number) -> number,
	PreAllocate: (self: ObjectPoolT, count: number) -> (),
	Resize: (self: ObjectPoolT, newMax: number) -> (),
	GetStats: (self: ObjectPoolT) -> Types.ClientVisualizationState,
	Destroy: (self: ObjectPoolT) -> (),
}

--[[
	Creates a new ObjectPool with the given configuration.
	The template part is cloned to populate the pool. All pooled parts
	are parented to the specified parent instance (typically a Folder
	in the Workspace dedicated to dust particles).
]]
function ObjectPool.new(config: Types.ObjectPoolConfig, parent: Instance?): any
	local pool = setmetatable({
		_config = config,
		_entries = {},
		_freeList = {},
		_activeCount = 0,
		_totalCreated = 0,
		_totalAcquired = 0,
		_totalReleased = 0,
		_currentFrame = 0,
		_lastCullFrame = 0,
		_template = config.template,
		_parent = parent or workspace,
	}, ObjectPool) :: any

	pool:PreAllocate(config.initialSize)
	return pool
end

--[[
	Creates a single pool entry by cloning the template.
	The part is anchored, hidden, and parented to the pool's parent folder.
]]
function ObjectPool:_createEntry(): PoolEntryT
	local self = self :: ObjectPoolT
	local part = self._template:Clone()
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Position = Vector3.new(0, -100000, 0) -- off-screen holding position
	part.Parent = self._parent

	self._totalCreated += 1

	return {
		part = part,
		inUse = false,
		lastUsedFrame = self._currentFrame,
		densityValue = 0,
	}
end

--[[
	Pre-allocates a specified number of entries into the pool.
	This is called during initialization and can be called again to warm up.
]]
function ObjectPool:PreAllocate(count: number): ()
	local self = self :: ObjectPoolT
	for _ = 1, count do
		if #self._entries >= self._config.maxSize then
			break
		end
		local entry = self:_createEntry()
		table.insert(self._entries, entry)
		table.insert(self._freeList, #self._entries)
	end
end

--[[
	Acquires a part from the pool. If the free list is empty and the pool
	has not reached max size, new entries are grown. Returns nil if the
	pool is exhausted and at max capacity.
]]
function ObjectPool:Acquire(): BasePart?
	local self = self :: ObjectPoolT
	-- Try to get from free list first (O(1) pop from end)
	local freeIndex = table.remove(self._freeList)
	if freeIndex == nil then
		-- Attempt to grow
		local currentSize = #self._entries
		if currentSize < self._config.maxSize then
			local growBy = math.min(self._config.growthRate, self._config.maxSize - currentSize)
			for _ = 1, growBy do
				local entry = self:_createEntry()
				table.insert(self._entries, entry)
				table.insert(self._freeList, #self._entries)
			end
			freeIndex = table.remove(self._freeList)
		end
	end

	if freeIndex == nil then
		return nil
	end

	local entry = self._entries[freeIndex]
	entry.inUse = true
	entry.lastUsedFrame = self._currentFrame
	entry.densityValue = 0
	entry.part.Transparency = 0

	self._activeCount += 1
	self._totalAcquired += 1

	return entry.part
end

--[[
	Returns a part to the pool, making it available for reuse.
	The part is hidden and moved to the holding position.
]]
function ObjectPool:Release(part: BasePart): ()
	local self = self :: ObjectPoolT
	-- Find the entry by part reference
	for i, entry in ipairs(self._entries) do
		if entry.part == part then
			if not entry.inUse then
				return -- already released
			end
			entry.inUse = false
			entry.lastUsedFrame = self._currentFrame
			entry.densityValue = 0
			entry.part.Transparency = 1
			entry.part.Position = Vector3.new(0, -100000, 0)
			table.insert(self._freeList, i)
			self._activeCount -= 1
			self._totalReleased += 1
			return
		end
	end
end

--[[
	Releases all currently active parts back to the pool.
	Used when the simulation is paused or the visualizer resets.
]]
function ObjectPool:ReleaseAll(): ()
	local self = self :: ObjectPoolT
	for i, entry in ipairs(self._entries) do
		if entry.inUse then
			entry.inUse = false
			entry.part.Transparency = 1
			entry.part.Position = Vector3.new(0, -100000, 0)
			table.insert(self._freeList, i)
		end
	end
	self._activeCount = 0
end

--[[
	Returns the number of currently active (in-use) parts.
]]
function ObjectPool:GetActiveCount(): number
	local self = self :: ObjectPoolT
	return self._activeCount
end

--[[
	Returns the number of available (free) parts in the pool.
]]
function ObjectPool:GetPooledCount(): number
	local self = self :: ObjectPoolT
	return #self._freeList
end

--[[
	Returns the total number of parts created by the pool (active + free).
]]
function ObjectPool:GetTotalCount(): number
	local self = self :: ObjectPoolT
	return #self._entries
end

--[[
	Returns the total number of acquire operations since pool creation.
]]
function ObjectPool:GetTotalAcquired(): number
	local self = self :: ObjectPoolT
	return self._totalAcquired
end

--[[
	Returns the total number of release operations since pool creation.
]]
function ObjectPool:GetTotalReleased(): number
	local self = self :: ObjectPoolT
	return self._totalReleased
end

--[[
	Advances the pool's internal frame counter. This is used to track
	how long a part has been idle for culling purposes.
]]
function ObjectPool:SetFrame(frame: number): ()
	local self = self :: ObjectPoolT
	self._currentFrame = frame
end

--[[
	Culls idle entries that have not been used for at least frameThreshold
	frames. This destroys the underlying parts and removes them from the
	pool to reclaim memory. Returns the number of entries culled.
]]
function ObjectPool:CullIdle(frameThreshold: number): number
	local self = self :: ObjectPoolT
	local culled = 0
	local newEntries = {}
	local newFreeList = {}

	-- Rebuild entries and freeList, skipping culled idle entries
	for i, entry in ipairs(self._entries) do
		local isIdle = not entry.inUse and (self._currentFrame - entry.lastUsedFrame) > frameThreshold
		if isIdle and #newEntries > self._config.initialSize then
			-- Destroy the part to reclaim memory
			entry.part:Destroy()
			culled += 1
		else
			table.insert(newEntries, entry)
			if not entry.inUse then
				table.insert(newFreeList, #newEntries)
			end
		end
	end

	self._entries = newEntries
	self._freeList = newFreeList
	self._lastCullFrame = self._currentFrame

	return culled
end

--[[
	Resizes the pool's maximum capacity. If shrinking, excess idle entries
	are destroyed. Active entries are never destroyed.
]]
function ObjectPool:Resize(newMax: number): ()
	local self = self :: ObjectPoolT
	self._config.maxSize = newMax

	-- If we're over the new max, cull idle entries down
	while #self._entries > newMax do
		local freeIndex = table.remove(self._freeList)
		if freeIndex == nil then
			break -- no more free entries to remove
		end
		local entry = self._entries[freeIndex]
		if entry and not entry.inUse then
			entry.part:Destroy()
			self._entries[freeIndex] = nil
		end
	end

	-- Compact the entries table (remove nil gaps)
	local compacted = {}
	local newFreeList = {}
	for i, entry in ipairs(self._entries) do
		if entry ~= nil then
			table.insert(compacted, entry)
			if not entry.inUse then
				table.insert(newFreeList, #compacted)
			end
		end
	end
	self._entries = compacted
	self._freeList = newFreeList
end

--[[
	Returns statistics about the pool for debugging and telemetry.
]]
function ObjectPool:GetStats(): Types.ClientVisualizationState
	local self = self :: ObjectPoolT
	return {
		visibleParticles = self._activeCount,
		pooledParts = #self._freeList,
		activeCells = 0,
		renderTimeMs = 0,
		lastFrameId = self._currentFrame,
	}
end

--[[
	Destroys the pool and all managed parts. Releases all references.
]]
function ObjectPool:Destroy(): ()
	local self = self :: ObjectPoolT
	for _, entry in ipairs(self._entries) do
		if entry.part and entry.part.Parent then
			entry.part:Destroy()
		end
	end
	table.clear(self._entries)
	table.clear(self._freeList)
	self._activeCount = 0
	setmetatable(self :: any, nil)
end

export type ObjectPool = ObjectPoolT

return ObjectPool
