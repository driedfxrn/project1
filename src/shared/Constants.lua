-- Constants.lua
-- Shared configuration for the Arena, Laser Ray weapon, and Lucky Block mechanic.

local Constants = {
	-- Arena grid configuration
	GridSize = 50,            -- 50x50x50 grid
	BlockSize = 4,            -- each block is 4x4x4 studs
	BlocksPerFrame = 500,     -- blocks generated per Heartbeat frame (batching to avoid lag)

	-- Block appearance
	BlockColor = Color3.fromRGB(120, 120, 120),
	BlockMaterial = Enum.Material.Plastic,

	-- Lucky block configuration
	LuckyChance = 0.05,       -- 5% chance to spawn a lucky block
	LuckyBlockColor = Color3.fromRGB(255, 215, 0),
	LuckyBlockMaterial = Enum.Material.Neon,
	LuckyBlockSize = Vector3.new(4.2, 4.2, 4.2),
	ExplosionBlastRadius = 12,
	ExplosionBlastPressure = 500000,
	LaunchForce = 80,         -- impulse magnitude for backward launch

	-- Laser Ray weapon
	LaserRange = 20,          -- studs
	LaserPower = 100,         -- power of the laser (must be >= BlockPower to destroy)
	LaserColor = Color3.fromRGB(0, 255, 100),
	LaserThickness = 0.3,
	LaserFadeTime = 0.15,     -- seconds before visual beam fades
	HighlightColor = Color3.fromRGB(0, 255, 100),
	HighlightFillTransparency = 0.7,

	-- Block power system
	BlockPower = 10,          -- default power needed to destroy a regular block
	SwipeInterpolationSteps = 5, -- interpolation steps between frames for swiping

	-- Folders / names
	BlocksFolderName = "ArenaBlocks",
	LuckyFolderName = "LuckyBlocks",
	ToolName = "Laser Ray",
}

return Constants