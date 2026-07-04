--!strict
-- BufferSerializer.luau
-- Binary serialization engine for grid cell data.
-- Converts complex cell payloads (id, density, wind vector, disturbance, material)
-- into compact binary buffers to eliminate nested-table memory overhead across actors.
--
-- Binary layout per cell (20 bytes total):
--   [0..3]   uint32  cellId
--   [4..7]   float32 density (0.0 - 1.0)
--   [8..11]  float32 windDirectionX
--   [12..15] float32 windDirectionZ
--   [16..17] uint16  windMagnitude (scaled)
--   [18]     uint8   disturbance (0-255 scaled)
--   [19]     uint8   materialId
--
-- This module is shared between server (write) and client (read).

local Types = require(script.Parent.Types)

local BufferSerializer = {}

-- Layout constants - single source of truth for byte offsets
export type CellLayout = {
	CELL_SIZE: number,
	ID_OFFSET: number,
	DENSITY_OFFSET: number,
	WIND_X_OFFSET: number,
	WIND_Z_OFFSET: number,
	WIND_MAG_OFFSET: number,
	DISTURBANCE_OFFSET: number,
	MATERIAL_OFFSET: number,
}

local LAYOUT: CellLayout = {
	CELL_SIZE = 20,
	ID_OFFSET = 0,
	DENSITY_OFFSET = 4,
	WIND_X_OFFSET = 8,
	WIND_Z_OFFSET = 12,
	WIND_MAG_OFFSET = 16,
	DISTURBANCE_OFFSET = 18,
	MATERIAL_OFFSET = 19,
}

BufferSerializer.LAYOUT = LAYOUT
BufferSerializer.CELL_SIZE = LAYOUT.CELL_SIZE

-- Scaling constants for integer-compressed fields
local WIND_MAG_SCALE = 100.0 -- max representable: 655.35 studs/s
local DISTURBANCE_SCALE = 255.0
local DENSITY_SCALE = 100000.0

--===========================================================================
-- Encoding
--===========================================================================

--[[
	Calculates the required buffer size for a given cell count.
]]
function BufferSerializer.calculateBufferSize(cellCount: number): number
	return cellCount * LAYOUT.CELL_SIZE
end

--[[
	Creates a new buffer sized for the specified number of cells.
]]
function BufferSerializer.createBuffer(cellCount: number): buffer
	return buffer.create(cellCount * LAYOUT.CELL_SIZE)
end

--[[
	Writes a single cell's data into a buffer at the specified cell index.
	Uses bit32-safe writes for each field according to the binary layout.
]]
function BufferSerializer.writeCell(
	buf: buffer,
	cellIndex: number,
	cellId: number,
	density: number,
	windX: number,
	windZ: number,
	windMagnitude: number,
	disturbance: number,
	materialId: number
): ()
	local baseOffset = cellIndex * LAYOUT.CELL_SIZE

	-- Cell ID: uint32
	buffer.writeu32(buf, baseOffset + LAYOUT.ID_OFFSET, cellId)

	-- Density: float32 (clamped 0..1)
	local clampedDensity = math.clamp(density, 0.0, 1.0)
	buffer.writef32(buf, baseOffset + LAYOUT.DENSITY_OFFSET, clampedDensity)

	-- Wind direction X: float32
	buffer.writef32(buf, baseOffset + LAYOUT.WIND_X_OFFSET, windX)

	-- Wind direction Z: float32
	buffer.writef32(buf, baseOffset + LAYOUT.WIND_Z_OFFSET, windZ)

	-- Wind magnitude: uint16 (scaled, clamped to max)
	local scaledWindMag = math.clamp(math.floor(windMagnitude * WIND_MAG_SCALE), 0, 65535)
	buffer.writeu16(buf, baseOffset + LAYOUT.WIND_MAG_OFFSET, scaledWindMag)

	-- Disturbance: uint8 (scaled 0..255)
	local scaledDisturbance = math.clamp(math.floor(disturbance * DISTURBANCE_SCALE), 0, 255)
	buffer.writeu8(buf, baseOffset + LAYOUT.DISTURBANCE_OFFSET, scaledDisturbance)

	-- Material ID: uint8
	buffer.writeu8(buf, baseOffset + LAYOUT.MATERIAL_OFFSET, math.clamp(materialId, 0, 255))
end

--[[
	Encodes an array of cell data tables into a single compact buffer.
	Returns the buffer and the number of cells written.
]]
function BufferSerializer.encodeCells(cells: { Types.GridCell }): (buffer, number)
	local cellCount = #cells
	local buf = BufferSerializer.createBuffer(cellCount)

	for index, cell in ipairs(cells) do
		BufferSerializer.writeCell(
			buf,
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

	return buf, cellCount
end

--[[
	Writes a header block at the start of a frame buffer containing
	metadata about the simulation frame. Header is 16 bytes:
	  [0..3]   uint32 frameId
	  [4..7]   uint32 cellCount
	  [8..11]  float32 timestamp
	  [12..15] uint32 reserved
]]
function BufferSerializer.writeFrameHeader(
	buf: buffer,
	frameId: number,
	cellCount: number,
	timestamp: number
): ()
	buffer.writeu32(buf, 0, frameId)
	buffer.writeu32(buf, 4, cellCount)
	buffer.writef32(buf, 8, timestamp)
	buffer.writeu32(buf, 12, 0) -- reserved for future flags
end

--[[
	Reads the frame header from a buffer.
]]
function BufferSerializer.readFrameHeader(buf: buffer): (number, number, number)
	local frameId = buffer.readu32(buf, 0)
	local cellCount = buffer.readu32(buf, 4)
	local timestamp = buffer.readf32(buf, 8)
	return frameId, cellCount, timestamp
end

--===========================================================================
-- Decoding
--===========================================================================

--[[
	Reads a single cell from a buffer at the specified cell index and returns
	a decoded table with all fields restored to their original numeric types.
]]
function BufferSerializer.readCell(buf: buffer, cellIndex: number): Types.GridCell
	local baseOffset = cellIndex * LAYOUT.CELL_SIZE

	local cellId = buffer.readu32(buf, baseOffset + LAYOUT.ID_OFFSET)
	local density = buffer.readf32(buf, baseOffset + LAYOUT.DENSITY_OFFSET)
	local windX = buffer.readf32(buf, baseOffset + LAYOUT.WIND_X_OFFSET)
	local windZ = buffer.readf32(buf, baseOffset + LAYOUT.WIND_Z_OFFSET)
	local windMagScaled = buffer.readu16(buf, baseOffset + LAYOUT.WIND_MAG_OFFSET)
	local disturbanceScaled = buffer.readu8(buf, baseOffset + LAYOUT.DISTURBANCE_OFFSET)
	local materialId = buffer.readu8(buf, baseOffset + LAYOUT.MATERIAL_OFFSET)

	return {
		id = cellId,
		coords = { x = 0, y = 0, z = 0 },
		worldPosition = Vector3.zero,
		density = density,
		wind = {
			directionX = windX,
			directionY = 0,
			directionZ = windZ,
			magnitude = windMagScaled / WIND_MAG_SCALE,
		},
		disturbance = disturbanceScaled / DISTURBANCE_SCALE,
		materialId = materialId,
		neighborIds = {},
	}
end

--[[
	Decodes an entire buffer into an array of cell tables.
	Optionally accepts a header offset to skip frame metadata.
]]
function BufferSerializer.decodeCells(buf: buffer, cellCount: number, headerSize: number?): { Types.GridCell }
	local offset = headerSize or 0
	local cells = table.create(cellCount)

	for i = 0, cellCount - 1 do
		local baseOffset = offset + (i * LAYOUT.CELL_SIZE)

		local cellId = buffer.readu32(buf, baseOffset + LAYOUT.ID_OFFSET)
		local density = buffer.readf32(buf, baseOffset + LAYOUT.DENSITY_OFFSET)
		local windX = buffer.readf32(buf, baseOffset + LAYOUT.WIND_X_OFFSET)
		local windZ = buffer.readf32(buf, baseOffset + LAYOUT.WIND_Z_OFFSET)
		local windMagScaled = buffer.readu16(buf, baseOffset + LAYOUT.WIND_MAG_OFFSET)
		local disturbanceScaled = buffer.readu8(buf, baseOffset + LAYOUT.DISTURBANCE_OFFSET)
		local materialId = buffer.readu8(buf, baseOffset + LAYOUT.MATERIAL_OFFSET)

		cells[i + 1] = {
			id = cellId,
			coords = { x = 0, y = 0, z = 0 },
			worldPosition = Vector3.zero,
			density = density,
			wind = {
				directionX = windX,
				directionY = 0,
				directionZ = windZ,
				magnitude = windMagScaled / WIND_MAG_SCALE,
			},
			disturbance = disturbanceScaled / DISTURBANCE_SCALE,
			materialId = materialId,
			neighborIds = {},
		}
	end

	return cells
end

--[[
	Decodes only the density field for a single cell - used by the client
	visualizer for fast threshold checks without full deserialization.
]]
function BufferSerializer.readCellDensity(buf: buffer, cellIndex: number): number
	local baseOffset = cellIndex * LAYOUT.CELL_SIZE
	return buffer.readf32(buf, baseOffset + LAYOUT.DENSITY_OFFSET)
end

--[[
	Decodes only the wind vector for a single cell - used by the client
	for particle drift direction without full deserialization.
]]
function BufferSerializer.readCellWind(buf: buffer, cellIndex: number): (number, number, number)
	local baseOffset = cellIndex * LAYOUT.CELL_SIZE
	local windX = buffer.readf32(buf, baseOffset + LAYOUT.WIND_X_OFFSET)
	local windZ = buffer.readf32(buf, baseOffset + LAYOUT.WIND_Z_OFFSET)
	local windMagScaled = buffer.readu16(buf, baseOffset + LAYOUT.WIND_MAG_OFFSET)
	return windX, windZ, windMagScaled / WIND_MAG_SCALE
end

--[[
	Decodes only the disturbance level for a single cell.
]]
function BufferSerializer.readCellDisturbance(buf: buffer, cellIndex: number): number
	local baseOffset = cellIndex * LAYOUT.CELL_SIZE
	local scaled = buffer.readu8(buf, baseOffset + LAYOUT.DISTURBANCE_OFFSET)
	return scaled / DISTURBANCE_SCALE
end

--[[
	Decodes only the material ID for a single cell.
]]
function BufferSerializer.readCellMaterial(buf: buffer, cellIndex: number): number
	local baseOffset = cellIndex * LAYOUT.CELL_SIZE
	return buffer.readu8(buf, baseOffset + LAYOUT.MATERIAL_OFFSET)
end

--[[
	Reads the cell ID at a given index.
]]
function BufferSerializer.readCellId(buf: buffer, cellIndex: number): number
	local baseOffset = cellIndex * LAYOUT.CELL_SIZE
	return buffer.readu32(buf, baseOffset + LAYOUT.ID_OFFSET)
end

--===========================================================================
-- Batch Operations
--===========================================================================

--[[
	Iterates over all cells in a buffer and invokes a callback for each.
	This is the most memory-efficient way to process frame data on the client
	since it never materializes the full cell array.
]]
function BufferSerializer.forEachCell(
	buf: buffer,
	cellCount: number,
	callback: (cellIndex: number, cellId: number, density: number, windX: number, windZ: number, windMag: number, disturbance: number, materialId: number) -> ()
): ()
	for i = 0, cellCount - 1 do
		local baseOffset = i * LAYOUT.CELL_SIZE
		local cellId = buffer.readu32(buf, baseOffset + LAYOUT.ID_OFFSET)
		local density = buffer.readf32(buf, baseOffset + LAYOUT.DENSITY_OFFSET)
		local windX = buffer.readf32(buf, baseOffset + LAYOUT.WIND_X_OFFSET)
		local windZ = buffer.readf32(buf, baseOffset + LAYOUT.WIND_Z_OFFSET)
		local windMag = buffer.readu16(buf, baseOffset + LAYOUT.WIND_MAG_OFFSET) / WIND_MAG_SCALE
		local disturbance = buffer.readu8(buf, baseOffset + LAYOUT.DISTURBANCE_OFFSET) / DISTURBANCE_SCALE
		local materialId = buffer.readu8(buf, baseOffset + LAYOUT.MATERIAL_OFFSET)

		callback(i, cellId, density, windX, windZ, windMag, disturbance, materialId)
	end
end

--[[
	Filters cells in a buffer by a predicate, returning indices of matching cells.
	Used by the client to find cells above the visualization threshold.
]]
function BufferSerializer.filterCellIndices(
	buf: buffer,
	cellCount: number,
	predicate: (density: number, disturbance: number) -> boolean
): { number }
	local results = {}
	for i = 0, cellCount - 1 do
		local baseOffset = i * LAYOUT.CELL_SIZE
		local density = buffer.readf32(buf, baseOffset + LAYOUT.DENSITY_OFFSET)
		local disturbance = buffer.readu8(buf, baseOffset + LAYOUT.DISTURBANCE_OFFSET) / DISTURBANCE_SCALE
		if predicate(density, disturbance) then
			table.insert(results, i)
		end
	end
	return results
end

--[[
	Creates a compact summary of a buffer's contents for debugging/telemetry.
	Returns aggregate statistics without materializing the full cell array.
]]
function BufferSerializer.summarizeBuffer(buf: buffer, cellCount: number): Types.GridStatistics
	local totalDensity = 0.0
	local maxDensity = 0.0
	local activeCells = 0
	local totalDustMass = 0.0

	for i = 0, cellCount - 1 do
		local baseOffset = i * LAYOUT.CELL_SIZE
		local density = buffer.readf32(buf, baseOffset + LAYOUT.DENSITY_OFFSET)
		totalDensity += density
		if density > maxDensity then
			maxDensity = density
		end
		if density > 0.01 then
			activeCells += 1
			totalDustMass += density
		end
	end

	return {
		totalCells = cellCount,
		activeCells = activeCells,
		averageDensity = if cellCount > 0 then totalDensity / cellCount else 0,
		maxDensity = maxDensity,
		totalDustMass = totalDustMass,
		sectorsProcessed = 0,
		processingTimeMs = 0,
	}
end

--[[
	Merges multiple sector buffers into a single contiguous buffer.
	Used by the server to assemble the final frame before replication.
]]
function BufferSerializer.mergeSectorBuffers(sectorBuffers: { { buffer: buffer, cellCount: number } }): (buffer, number)
	local totalCells = 0
	for _, entry in ipairs(sectorBuffers) do
		totalCells += entry.cellCount
	end

	local merged = BufferSerializer.createBuffer(totalCells)
	local writeOffset = 0

	for _, entry in ipairs(sectorBuffers) do
		local src = entry.buffer
		local srcLen = entry.cellCount * LAYOUT.CELL_SIZE
		buffer.copy(merged, writeOffset, src, 0, srcLen)
		writeOffset += srcLen
	end

	return merged, totalCells
end

--[[
	Copies a range of cells from a source buffer to a destination buffer.
	Useful for extracting a sector's worth of data from a merged frame.
]]
function BufferSerializer.copyCellRange(
	dst: buffer,
	dstIndex: number,
	src: buffer,
	srcIndex: number,
	count: number
): ()
	local dstOffset = dstIndex * LAYOUT.CELL_SIZE
	local srcOffset = srcIndex * LAYOUT.CELL_SIZE
	local byteCount = count * LAYOUT.CELL_SIZE
	buffer.copy(dst, dstOffset, src, srcOffset, byteCount)
end

--[[
	Reads a single cell's fields and returns them as separate values.
	This is the efficient multi-return variant used by the BulkRenderEngine
	to avoid allocating a table per cell during rendering.
	The headerOffset parameter skips frame header bytes (default 0 for raw sector buffers).
	Returns: cellId, density, windX, windZ, windMag, disturbance, materialId
]]
function BufferSerializer.readCellFields(
	buf: buffer,
	cellIndex: number,
	headerOffset: number?
): (number, number, number, number, number, number, number)
	local baseOffset = (headerOffset or 0) + (cellIndex * LAYOUT.CELL_SIZE)
	local cellId = buffer.readu32(buf, baseOffset + LAYOUT.ID_OFFSET)
	local density = buffer.readf32(buf, baseOffset + LAYOUT.DENSITY_OFFSET)
	local windX = buffer.readf32(buf, baseOffset + LAYOUT.WIND_X_OFFSET)
	local windZ = buffer.readf32(buf, baseOffset + LAYOUT.WIND_Z_OFFSET)
	local windMag = buffer.readu16(buf, baseOffset + LAYOUT.WIND_MAG_OFFSET) / WIND_MAG_SCALE
	local disturbance = buffer.readu8(buf, baseOffset + LAYOUT.DISTURBANCE_OFFSET) / DISTURBANCE_SCALE
	local materialId = buffer.readu8(buf, baseOffset + LAYOUT.MATERIAL_OFFSET)
	return cellId, density, windX, windZ, windMag, disturbance, materialId
end

--[[
	Returns the raw byte size of the buffer for memory telemetry.
]]
function BufferSerializer.getBufferSize(buf: buffer): number
	return buffer.len(buf)
end

--[[
	Returns a human-readable string of buffer memory usage.
]]
function BufferSerializer.formatMemoryUsage(buf: buffer): string
	local bytes = buffer.len(buf)
	if bytes < 1024 then
		return string.format("%d B", bytes)
	elseif bytes < 1024 * 1024 then
		return string.format("%.2f KB", bytes / 1024)
	else
		return string.format("%.2f MB", bytes / (1024 * 1024))
	end
end

return BufferSerializer