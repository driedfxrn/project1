-- ArenaGenerator.server.lua
-- Generates a massive 50x50x50 grid of destructible blocks using frame-batching
-- so the server never freezes or drops frames during generation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Constants = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Constants"))

-- Pre-compute values used in the hot loop
local GridSize = Constants.GridSize
local BlockSize = Constants.BlockSize
local BlocksPerFrame = Constants.BlocksPerFrame
local HalfGrid = (GridSize * BlockSize) / 2
local BlockColor = Constants.BlockColor
local BlockMaterial = Constants.BlockMaterial
local BlockPower = Constants.BlockPower

-- The ArenaBlocks folder must be created in Studio (or via Rojo project).
-- We do not create it in code — warn if it's missing.
local BlocksFolder = Workspace:FindFirstChild(Constants.BlocksFolderName)
if not BlocksFolder or not BlocksFolder:IsA("Folder") then
	warn(`[{script.Name}] The "{Constants.BlocksFolderName}" folder is missing in Workspace. Please create it before running.`)
	return nil
end

-- Create a single template part. Cloning is far cheaper than constructing
-- a new Instance and setting every property 125,000 times.
local Template = Instance.new("Part")
Template.Anchored = true
Template.CanCollide = true
Template.CastShadow = false
Template.Size = Vector3.new(BlockSize, BlockSize, BlockSize)
Template.Color = BlockColor
Template.Material = BlockMaterial
Template.TopSurface = Enum.SurfaceType.Smooth
Template.BottomSurface = Enum.SurfaceType.Smooth
Template.Locked = true

-- Generates the grid across multiple Heartbeat frames.
local function GenerateArena(Folder: Folder)
	local TotalBlocks = GridSize * GridSize * GridSize
	local Created = 0
	local Connection

	Connection = RunService.Heartbeat:Connect(function()
		local CreatedThisFrame = 0
		-- Build a slice of the grid this frame
		while CreatedThisFrame < BlocksPerFrame and Created < TotalBlocks do
			-- Derive x/y/z from the linear index (avoids nested loop overhead in Lua)
			local Index = Created
			local X = Index % GridSize
			local Y = math.floor(Index / GridSize) % GridSize
			local Z = math.floor(Index / (GridSize * GridSize)) % GridSize

			local Block = Template:Clone()
			Block.CFrame = CFrame.new(
				X * BlockSize - HalfGrid,
				Y * BlockSize,
				Z * BlockSize - HalfGrid
			)
			Block:SetAttribute("BlockPower", BlockPower)
			Block.Parent = Folder

			Created += 1
			CreatedThisFrame += 1
		end

		if Created >= TotalBlocks then
			Connection:Disconnect()
		end
	end)
end

GenerateArena(BlocksFolder)

return nil