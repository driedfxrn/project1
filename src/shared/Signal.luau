--!strict
-- Signal.luau
-- Custom immediate-mode signal implementation.
--
-- Roblox's deferred signal mode introduces queueing bottlenecks that are
-- unacceptable in Parallel Luau workflows where we need deterministic,
-- immediate dispatch. This signal fires handlers synchronously the moment
-- :Fire() is called, with zero allocation on the hot path after warmup.
--
-- Features:
--   - Immediate execution (no deferred queue)
--   - :Connect() returns a custom Connection object with :Disconnect()
--   - :Once() for one-shot handlers
--   - :DisconnectAll() for teardown
--   - Memory-efficient: handler array is reused, no per-fire allocation
--   - Safe against handler disconnection during iteration

local Signal = {}
Signal.__index = Signal

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

type Handler = (...any) -> ()

-- Forward-declared internal signal shape
type SignalInternal = {
	_handlers: { Handler },
	_pendingAdd: { Handler },
	_pendingRemove: { Handler },
	_isFiring: boolean,
	_yieldDepth: number,
	_removeHandler: (self: SignalInternal, handler: Handler) -> (),
	_removeHandlerImmediate: (self: SignalInternal, handler: Handler) -> (),
}

local Connection = {}
Connection.__index = Connection

function Connection.new(signal: SignalInternal, handler: Handler): Connection
	return setmetatable({
		_signal = signal,
		_handler = handler,
		Connected = true,
	}, Connection) :: any
end

function Connection:Disconnect(): ()
	if not self.Connected then
		return
	end
	self.Connected = false
	local signal = (self :: any)._signal :: SignalInternal
	signal:_removeHandler((self :: any)._handler)
end

function Signal.new(): Signal
	return setmetatable({
		_handlers = {},
		_pendingAdd = {},
		_pendingRemove = {},
		_isFiring = false,
		_yieldDepth = 0,
	}, Signal) :: any
end

--[[
	Connects a handler that will be called immediately when :Fire() is invoked.
	Returns a Connection object that can be disconnected.
]]
function Signal:Connect(handler: Handler): Connection
	assert(typeof(handler) == "function", "Signal:Connect expects a function")

	local conn = Connection.new(self :: any, handler)

	if self._isFiring then
		-- Defer the add until current fire cycle completes to avoid mutation during iteration
		table.insert(self._pendingAdd, handler)
	else
		table.insert(self._handlers, handler)
	end

	return conn
end

--[[
	Connects a handler that will only fire once, then auto-disconnects.
]]
function Signal:Once(handler: Handler): Connection
	assert(typeof(handler) == "function", "Signal:Once expects a function")

	local conn: Connection
	conn = self:Connect(function(...)
		if conn.Connected then
			conn:Disconnect()
		end
		handler(...)
	end)

	return conn
end

--[[
	Fires the signal immediately, calling all connected handlers synchronously.
	Any handlers connected or disconnected during the fire cycle are deferred
	to prevent mutation-during-iteration issues.
]]
function Signal:Fire(...: any): ()
	self._isFiring = true

	local handlers = self._handlers
	for i = 1, #handlers do
		local handler = handlers[i]
		if handler ~= nil then
			handler(...)
		end
	end

	self._isFiring = false

	-- Process pending additions
	if #self._pendingAdd > 0 then
		for i = 1, #self._pendingAdd do
			table.insert(self._handlers, self._pendingAdd[i])
		end
		table.clear(self._pendingAdd)
	end

	-- Process pending removals
	if #self._pendingRemove > 0 then
		for i = 1, #self._pendingRemove do
			self:_removeHandlerImmediate(self._pendingRemove[i])
		end
		table.clear(self._pendingRemove)
	end
end

--[[
	Alias for Fire for API compatibility with Roblox-style signals.
]]
function Signal:FireAll(...: any): ()
	self:Fire(...)
end

--[[
	Internal: removes a handler from the active list.
	If currently firing, defers the removal.
]]
function Signal:_removeHandler(handler: Handler): ()
	if self._isFiring then
		table.insert(self._pendingRemove, handler)
	else
		self:_removeHandlerImmediate(handler)
	end
end

--[[
	Internal: performs the actual removal of a handler from the list.
	Uses a reverse scan to find and remove the handler efficiently.
]]
function Signal:_removeHandlerImmediate(handler: Handler): ()
	local handlers = self._handlers
	for i = #handlers, 1, -1 do
		if handlers[i] == handler then
			table.remove(handlers, i)
			return
		end
	end
end

--[[
	Disconnects all handlers. Useful for teardown.
]]
function Signal:DisconnectAll(): ()
	table.clear(self._handlers)
	table.clear(self._pendingAdd)
	table.clear(self._pendingRemove)
end

--[[
	Returns the number of currently connected handlers.
]]
function Signal:GetHandlerCount(): number
	return #self._handlers
end

--[[
	Returns true if any handlers are connected.
]]
function Signal:HasHandlers(): boolean
	return #self._handlers > 0
end

--[[
	Destroys the signal and releases all references.
]]
function Signal:Destroy(): ()
	self:DisconnectAll()
	setmetatable(self :: any, nil)
end

--===========================================================================
-- FastPollQueue - a custom fast-polling queue for high-frequency events
--===========================================================================

--[[
	FastPollQueue provides an alternative to signal-based event handling for
	scenarios where we want to batch process events at a controlled cadence
	rather than firing immediately. This is used by the simulation engine to
	coalesce disturbance events into per-tick batches.

	Unlike deferred signals, this queue does not use Roblox's scheduler and
	instead is manually pumped by the simulation tick, giving us full control
	over execution timing and ordering.
]]

local FastPollQueue = {}
FastPollQueue.__index = FastPollQueue

export type QueueEntry = {
	id: number,
	payload: any,
	timestamp: number,
}

type FastPollQueueT = {
	_entries: { [number]: QueueEntry },
	_head: number,
	_tail: number,
	_count: number,
	_nextId: number,
	_maxSize: number,
	Enqueue: (self: FastPollQueueT, payload: any) -> number,
	Dequeue: (self: FastPollQueueT) -> any,
	Peek: (self: FastPollQueueT) -> any,
	ProcessAll: (self: FastPollQueueT, callback: (payload: any) -> ()) -> (),
	ProcessBatch: (self: FastPollQueueT, maxCount: number, callback: (payload: any) -> ()) -> number,
	Count: (self: FastPollQueueT) -> number,
	IsEmpty: (self: FastPollQueueT) -> boolean,
	Clear: (self: FastPollQueueT) -> (),
	SetMaxSize: (self: FastPollQueueT, maxSize: number) -> (),
	Destroy: (self: FastPollQueueT) -> (),
}

function FastPollQueue.new(): FastPollQueue
	return setmetatable({
		_entries = {},
		_head = 1,
		_tail = 0,
		_count = 0,
		_nextId = 1,
		_maxSize = 10000,
	}, FastPollQueue) :: any
end

--[[
	Enqueues a payload. Returns the assigned entry ID.
	If the queue is at max capacity, the oldest entry is dropped.
]]
function FastPollQueue:Enqueue(payload: any): number
	local self = self :: FastPollQueueT
	if self._count >= self._maxSize then
		self:Dequeue()
	end

	self._tail += 1
	self._count += 1
	local id = self._nextId
	self._nextId += 1

	self._entries[self._tail] = {
		id = id,
		payload = payload,
		timestamp = os.clock(),
	}

	return id
end

--[[
	Dequeues and returns the oldest entry's payload, or nil if empty.
]]
function FastPollQueue:Dequeue(): any
	local self = self :: FastPollQueueT
	if self._count == 0 then
		return nil
	end

	local entry = self._entries[self._head]
	if entry == nil then
		return nil
	end

	self._entries[self._head] = nil
	self._head += 1
	self._count -= 1

	return entry.payload
end

--[[
	Returns the oldest entry without removing it.
]]
function FastPollQueue:Peek(): any
	local self = self :: FastPollQueueT
	if self._count == 0 then
		return nil
	end
	local entry = self._entries[self._head]
	if entry == nil then
		return nil
	end
	return entry.payload
end

--[[
	Processes all entries in the queue, invoking the callback for each.
	Entries are consumed in order. This is the "pump" operation.
]]
function FastPollQueue:ProcessAll(callback: (payload: any) -> ()): ()
	local self = self :: FastPollQueueT
	while self._count > 0 do
		local payload = self:Dequeue()
		if payload ~= nil then
			callback(payload)
		end
	end
end

--[[
	Processes up to maxCount entries from the queue.
	Useful for time-slicing event processing across multiple frames.
]]
function FastPollQueue:ProcessBatch(maxCount: number, callback: (payload: any) -> ()): number
	local self = self :: FastPollQueueT
	local processed = 0
	while self._count > 0 and processed < maxCount do
		local payload = self:Dequeue()
		if payload ~= nil then
			callback(payload)
			processed += 1
		end
	end
	return processed
end

--[[
	Returns the current number of entries in the queue.
]]
function FastPollQueue:Count(): number
	local self = self :: FastPollQueueT
	return self._count
end

--[[
	Returns true if the queue is empty.
]]
function FastPollQueue:IsEmpty(): boolean
	local self = self :: FastPollQueueT
	return self._count == 0
end

--[[
	Removes all entries from the queue.
]]
function FastPollQueue:Clear(): ()
	local self = self :: FastPollQueueT
	table.clear(self._entries)
	self._head = 1
	self._tail = 0
	self._count = 0
end

--[[
	Sets the maximum queue capacity. If reducing below current count,
	excess entries are dropped from the front.
]]
function FastPollQueue:SetMaxSize(maxSize: number): ()
	local self = self :: FastPollQueueT
	self._maxSize = maxSize
	while self._count > maxSize do
		self:Dequeue()
	end
end

--[[
	Destroys the queue and releases all references.
]]
function FastPollQueue:Destroy(): ()
	self:Clear()
	setmetatable(self :: any, nil)
end

-- Export types for external consumption
export type Signal = typeof(Signal.new())
export type FastPollQueue = typeof(FastPollQueue.new())

-- Attach FastPollQueue as a nested type for namespacing
Signal.FastPollQueue = FastPollQueue

return Signal