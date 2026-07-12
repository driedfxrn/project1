-- WeaponService.server.lua
-- Creates the Laser Ray tool, handles instant block destruction via iterative raycasting,
-- swipe interpolation, power checks, and the Lucky Block mechanic.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local StarterPack = game:GetService("StarterPack")

local Constants = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Constants"))
local Packets = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Packets"))

-- Cache config locals for hot paths
local LaserRange = Constants.LaserRange
local LaserPower = Constants.LaserPower
local LuckyChance = Constants.LuckyChance
local LuckyBlockColor = Constants.LuckyBlockColor
local LuckyBlockMaterial = Constants.LuckyBlockMaterial
local LuckyBlockSize = Constants.LuckyBlockSize
local ExplosionBlastRadius = Constants.ExplosionBlastRadius
local ExplosionBlastPressure = Constants.ExplosionBlastPressure
local LaunchForce = Constants.LaunchForce
local BlockSize = Constants.BlockSize
local SwipeInterpolationSteps = Constants.SwipeInterpolationSteps

-- The ArenaBlocks and LuckyBlocks folders must be created in Studio (or via Rojo).
local BlocksFolder = Workspace:FindFirstChild(Constants.BlocksFolderName)
if not BlocksFolder or not BlocksFolder:IsA("Folder") then
	warn(`[{script.Name}] The "{Constants.BlocksFolderName}" folder is missing in Workspace. Please create it before running.`)
	return nil
end

local LuckyFolder = Workspace:FindFirstChild(Constants.LuckyFolderName)
if not LuckyFolder or not LuckyFolder:IsA("Folder") then
	warn(`[{script.Name}] The "{Constants.LuckyFolderName}" folder is missing in Workspace. Please create it before running.`)
	return nil
end

-- Reused RaycastParams (filtered to the arena blocks folder only)
local RayParams = RaycastParams.new()
RayParams.FilterType = Enum.RaycastFilterType.Include
RayParams.FilterDescendantsInstances = { BlocksFolder }
RayParams.IgnoreWater = true

-- Reused Lucky Block template
local LuckyTemplate = Instance.new("Part")
LuckyTemplate.Anchored = true
LuckyTemplate.CanCollide = true
LuckyTemplate.CastShadow = false
LuckyTemplate.Size = LuckyBlockSize
LuckyTemplate.Color = LuckyBlockColor
LuckyTemplate.Material = LuckyBlockMaterial
LuckyTemplate.TopSurface = Enum.SurfaceType.Smooth
LuckyTemplate.BottomSurface = Enum.SurfaceType.Smooth

-- Spawn a Lucky Block at a position with a ClickDetector
local function SpawnLuckyBlock(Position: Vector3)
	local Block = LuckyTemplate:Clone()
	Block.CFrame = CFrame.new(Position)
	Block.Parent = LuckyFolder

	local ClickDetector = Instance.new("ClickDetector")
	ClickDetector.MaxActivationDistance = 16
	ClickDetector.CursorIcon = "rbxassetid://10620242502"
	ClickDetector.Parent = Block

	local function OnClick(Player: Player)
		local Character = Player.Character
		if not Character then
			return
		end
		local HumanoidRootPart = Character:FindFirstChild("HumanoidRootPart")
		if not HumanoidRootPart then
			return
		end

		-- Create the explosion
		local Explosion = Instance.new("Explosion")
		Explosion.Position = Position
		Explosion.BlastRadius = ExplosionBlastRadius
		Explosion.BlastPressure = ExplosionBlastPressure
		Explosion.DestroyJointRadiusPercent = 0
		Explosion.Parent = Workspace

		-- Launch the player backward (away from the explosion center)
		local LaunchDirection = (HumanoidRootPart.Position - Position).Unit
		if LaunchDirection.Magnitude > 0 then
			local CurrentVelocity = HumanoidRootPart.AssemblyLinearVelocity
			HumanoidRootPart.AssemblyLinearVelocity = CurrentVelocity + (LaunchDirection * LaunchForce)
		end

		-- Remove the lucky block
		Block:Destroy()
	end

	ClickDetector.MouseClick:Connect(OnClick)
end

-- Destroy all blocks along a ray from Origin to Target using iterative raycasting.
-- Raycasts → destroys hit block → advances past it → repeats until range exhausted.
-- This is precise: only blocks directly in the ray path get destroyed.
local function DestroyBlocksAlongRay(Origin: Vector3, Target: Vector3)
	local Direction = Target - Origin
	local TotalDistance = math.min(Direction.Magnitude, LaserRange)
	if TotalDistance < 0.01 then
		return
	end

	local DirectionUnit = Direction.Unit
	local RemainingDistance = TotalDistance
	local CurrentOrigin = Origin

	while RemainingDistance > 0 do
		local Result = Workspace:Raycast(CurrentOrigin, DirectionUnit * RemainingDistance, RayParams)
		if not Result then
			break
		end

		local HitPart = Result.Instance
		if HitPart and HitPart.Parent == BlocksFolder then
			local HitPosition = Result.Position

			-- Power check: only destroy if laser power >= block power
			local BlockPower = HitPart:GetAttribute("BlockPower") or Constants.BlockPower

			if LaserPower >= BlockPower then
				HitPart:Destroy()

				-- 5% chance to spawn a Lucky Block at the destroyed position
				if math.random() < LuckyChance then
					SpawnLuckyBlock(HitPosition)
				end
			end

			-- Advance the ray origin just past the hit point
			local Traveled = (HitPosition - CurrentOrigin).Magnitude
			RemainingDistance -= Traveled
			CurrentOrigin = HitPosition + DirectionUnit * 0.01
		else
			break
		end
	end
end

-- Handle a laser fire from a player (via ByteNet)
local function HandleLaserFire(Data: { Origin: Vector3, Target: Vector3, PreviousTarget: Vector3 }, Player: Player)
	-- Validate the player is alive and near the origin (anti-exploit)
	local Character = Player.Character
	if not Character then
		return
	end
	local HumanoidRootPart = Character:FindFirstChild("HumanoidRootPart")
	if not HumanoidRootPart then
		return
	end
	if (Data.Origin - HumanoidRootPart.Position).Magnitude > 32 then
		return
	end

	-- Destroy blocks along the ray from origin to target
	DestroyBlocksAlongRay(Data.Origin, Data.Target)

	-- Interpolate between previous and current target for swipe satisfaction
	local PrevTarget = Data.PreviousTarget
	local CurrTarget = Data.Target

	if (PrevTarget - Vector3.zero).Magnitude > 0.01 and (CurrTarget - PrevTarget).Magnitude > 0.01 then
		for Step = 1, SwipeInterpolationSteps - 1 do
			local Alpha = Step / SwipeInterpolationSteps
			local InterpTarget = PrevTarget:Lerp(CurrTarget, Alpha)
			DestroyBlocksAlongRay(Data.Origin, InterpTarget)
		end
	end
end

Packets.FireLaser.listen(HandleLaserFire)

-- Build the Laser Ray tool and place it in StarterPack
local function CreateTool()
	local Tool = Instance.new("Tool")
	Tool.Name = Constants.ToolName
	Tool.ToolTip = "Hold to fire a laser ray that destroys blocks"
	Tool.RequiresHandle = true
	Tool.CanBeDropped = false

	local Handle = Instance.new("Part")
	Handle.Name = "Handle"
	Handle.Size = Vector3.new(0.5, 0.5, 1.5)
	Handle.Color = Constants.LaserColor
	Handle.Material = Enum.Material.Neon
	Handle.Anchored = false
	Handle.CanCollide = false
	Handle.Parent = Tool

	Tool.Parent = StarterPack
end

CreateTool()

return nil