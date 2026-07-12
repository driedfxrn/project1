-- LaserRayController.client.lua
-- Client-side: detects when the Laser Ray tool is activated, computes the aim
-- ray from the camera via UserInputService, and sends it to the server via ByteNet.
-- Supports hold-to-fire with a smooth Beam instance, block highlighting, and
-- swipe interpolation via PreviousTarget tracking.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Constants = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Constants"))
local Packets = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Packets"))

local Player = Players.LocalPlayer
local Camera = Workspace.CurrentCamera

local ArenaBlocksFolder = Workspace:FindFirstChild(Constants.BlocksFolderName)

-- State
local CurrentTool = nil
local IsFiring = false
local PreviousTarget = Vector3.zero

-- Beam visual components (reused)
local BeamPart = Instance.new("Part")
BeamPart.Anchored = true
BeamPart.CanCollide = false
BeamPart.CastShadow = false
BeamPart.Transparency = 1
BeamPart.Parent = Workspace

local StartAttachment = Instance.new("Attachment")
StartAttachment.Parent = BeamPart

local EndAttachment = Instance.new("Attachment")
EndAttachment.Parent = BeamPart

local Beam = Instance.new("Beam")
Beam.Attachment0 = StartAttachment
Beam.Attachment1 = EndAttachment
Beam.FaceCamera = true
Beam.Width0 = Constants.LaserThickness
Beam.Width1 = Constants.LaserThickness
Beam.Color = ColorSequence.new(Constants.LaserColor)
Beam.Transparency = NumberSequence.new(0)
Beam.LightEmission = 1
Beam.LightInfluence = 0
Beam.Enabled = false
Beam.Parent = BeamPart

-- Reused Highlight instance for hovered block
local Highlight = Instance.new("Highlight")
Highlight.FillColor = Constants.HighlightColor
Highlight.OutlineColor = Constants.HighlightColor
Highlight.FillTransparency = Constants.HighlightFillTransparency
Highlight.OutlineTransparency = 0
Highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
Highlight.Enabled = false
Highlight.Parent = nil

local CurrentHighlightedBlock = nil

-- Reused RaycastParams for the camera aim ray (blacklist the player's character)
local AimRayParams = RaycastParams.new()
AimRayParams.FilterType = Enum.RaycastFilterType.Whitelist
AimRayParams.IgnoreWater = true
-- Compute the world-space aim target from the mouse position on screen
-- Returns the hit position and the hit instance (what the player actually sees)
local function GetAimTarget(): (Vector3, BasePart?)
	local MouseLocation = UserInputService:GetMouseLocation()
	local ScreenRay = Camera:ViewportPointToRay(MouseLocation.X, MouseLocation.Y)

	local Character = Player.Character
	if Character then
		AimRayParams.FilterDescendantsInstances = {ArenaBlocksFolder }
	end 

	local Result = Workspace:Raycast(ScreenRay.Origin, ScreenRay.Direction * 1000, AimRayParams)
	if Result then
		return Result.Position, Result.Instance
	end

	-- If nothing was hit, project far along the ray
	return ScreenRay.Origin + ScreenRay.Direction * 1000, nil
end

-- Update the beam visual between Origin and EndPoint
local function UpdateBeam(Origin: Vector3, EndPoint: Vector3)
	BeamPart.Position = Origin
	StartAttachment.Position = Vector3.zero
	EndAttachment.Position = EndPoint - Origin
	Beam.Enabled = true
end

-- Hide the beam
local function HideBeam()
	Beam.Enabled = false
end

-- Update the highlight on the hovered block
local function UpdateHighlight(Block: BasePart?)
	-- Remove highlight from the previous block if it changed
	if CurrentHighlightedBlock and CurrentHighlightedBlock ~= Block then
		local Existing = CurrentHighlightedBlock:FindFirstChild("Highlight")
		if Existing == Highlight then
			Highlight.Parent = nil
		end
		CurrentHighlightedBlock = nil
	end

	-- Add highlight to the new block
	if Block and Block ~= CurrentHighlightedBlock then
		if not Block:FindFirstChild("Highlight") then
			Highlight.Parent = Block
			Highlight.Enabled = true
			CurrentHighlightedBlock = Block
		end
	elseif Block == CurrentHighlightedBlock then
		if Highlight.Parent ~= Block then
			Highlight.Parent = Block
			Highlight.Enabled = true
		end
	end
end

-- Remove the highlight entirely
local function ClearHighlight()
	if CurrentHighlightedBlock then
		local Existing = CurrentHighlightedBlock:FindFirstChild("Highlight")
		if Existing == Highlight then
			Highlight.Parent = nil
		end
		CurrentHighlightedBlock = nil
	end
	Highlight.Enabled = false
end

-- Clamp a target point to the laser range from the origin
local function ClampTargetToRange(Origin: Vector3, Target: Vector3): Vector3
	local Direction = Target - Origin
	local Distance = Direction.Magnitude
	if Distance <= Constants.LaserRange then
		return Target
	end
	return Origin + Direction.Unit * Constants.LaserRange
end

-- Hook up the tool when it's equipped
local function SetupTool(Tool: Tool)
	CurrentTool = Tool

	Tool.Activated:Connect(function()
		IsFiring = true
		PreviousTarget = Vector3.zero
	end)

	Tool.Deactivated:Connect(function()
		IsFiring = false
		HideBeam()
		ClearHighlight()
	end)

	Tool.Unequipped:Connect(function()
		IsFiring = false
		HideBeam()
		ClearHighlight()
		CurrentTool = nil
	end)
end

-- Continuous fire loop while the mouse is held
-- Fires every frame for instant destruction; beam + highlight update every frame
RunService.RenderStepped:Connect(function()
	if not IsFiring or not CurrentTool then
		return
	end

	local Character = Player.Character
	if not Character then
		return
	end
	local HumanoidRootPart = Character:FindFirstChild("HumanoidRootPart")
	if not HumanoidRootPart then
		return
	end

	local Handle = CurrentTool:FindFirstChild("Handle")
	local Origin = if Handle then Handle.Position else HumanoidRootPart.Position

	-- Get the camera hit — this is what the player actually sees and aims at
	local AimTarget, HitBlock = GetAimTarget()

	-- Clamp the target to the laser range from the tool origin
	local ClampedTarget = ClampTargetToRange(Origin, AimTarget)

	-- Update beam from tool origin to the clamped target
	UpdateBeam(Origin, ClampedTarget)

	-- Highlight the block the camera ray actually hit (what the player sees)
	UpdateHighlight(HitBlock)

	-- Fire shot every frame via ByteNet
	Packets.FireLaser.send({
		Origin = Origin,
		Target = ClampedTarget,
		PreviousTarget = PreviousTarget,
	})

	-- Store current target for next frame's interpolation
	PreviousTarget = ClampedTarget
end)

-- Watch for the tool being added to the player's backpack/character
local function WatchForTool()
	local Backpack = Player:WaitForChild("Backpack")
	local Character = Player.Character or Player.CharacterAdded:Wait()

	local function CheckContainer(Container: Instance)
		for _, Item in ipairs(Container:GetChildren()) do
			if Item:IsA("Tool") and Item.Name == Constants.ToolName then
				SetupTool(Item)
			end
		end
	end

	Backpack.ChildAdded:Connect(function(Child)
		if Child:IsA("Tool") and Child.Name == Constants.ToolName then
			SetupTool(Child)
		end
	end)
	Character.ChildAdded:Connect(function(Child)
		if Child:IsA("Tool") and Child.Name == Constants.ToolName then
			SetupTool(Child)
		end
	end)

	CheckContainer(Backpack)
	CheckContainer(Character)
end

WatchForTool()

return nil