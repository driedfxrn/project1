--!strict
-- init.client.luau
-- Client-side visualizer for the Dynamic Road Dust & Particulate Simulation.
--
-- This is the "Production" layer entry point. It:
--   1. Receives binary frame buffers from the server via RemoteEvent
--   2. Feeds them into the BulkRenderEngine for visualization
--   3. Handles weather state changes (Lighting updates)
--   4. Sends vehicle disturbance events to the server
--   5. Manages the render loop (Heartbeat -> Flush)
--   6. Provides a debug HUD for performance monitoring

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared:WaitForChild("Types"))
local BulkRenderEngine = require(script.Parent:WaitForChild("BulkRenderEngine"))
local BufferSerializer = require(Shared:WaitForChild("BufferSerializer"))
local WeatherStates = require(Shared:WaitForChild("WeatherStates"))
local VehicularDisturbance = require(Shared:WaitForChild("VehicularDisturbance"))

local player = Players.LocalPlayer

--===========================================================================
-- Remote Events
--===========================================================================

local frameUpdateRemote = ReplicatedStorage:WaitForChild("DustSimulationFrameUpdate") :: RemoteEvent
local disturbanceRemote = ReplicatedStorage:WaitForChild("DustSimulationDisturbance") :: RemoteEvent
local weatherChangeRemote = ReplicatedStorage:WaitForChild("DustSimulationWeatherChange") :: RemoteEvent
local configRequestRemote = ReplicatedStorage:WaitForChild("DustSimulationConfigRequest") :: RemoteEvent

--===========================================================================
-- Client State
--===========================================================================

local ClientState: Types.ClientState = {
	Initialized = false,
	CurrentWeather = 1,
	CurrentFrame = 0,
	TotalFramesReceived = 0,
	TotalBytesReceived = 0,
	LastFrameTime = 0,
	AverageFrameTime = 0,
	FrameTimeHistory = {},
}

--===========================================================================
-- Render Engine
--===========================================================================

local renderEngine: any = nil
local renderConnection: RBXScriptConnection? = nil
local debugHudConnection: RBXScriptConnection? = nil

--===========================================================================
-- Debug HUD
--===========================================================================

local debugEnabled = false
local debugScreenGui: ScreenGui? = nil
local debugFrameLabel: TextLabel? = nil
local debugParticleLabel: TextLabel? = nil
local debugFpsLabel: TextLabel? = nil
local debugMemoryLabel: TextLabel? = nil
local debugWeatherLabel: TextLabel? = nil

local function createDebugHud(): ()
	if debugScreenGui then
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "DustSimulationDebug"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local frame = Instance.new("Frame")
	frame.Name = "DebugPanel"
	frame.Size = UDim2.new(0, 280, 0, 140)
	frame.Position = UDim2.new(0, 10, 0, 10)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
	frame.BackgroundTransparency = 0.2
	frame.BorderSizePixel = 1
	frame.BorderColor3 = Color3.fromRGB(60, 60, 70)
	frame.Parent = gui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 24)
	title.Position = UDim2.new(0, 0, 0, 0)
	title.BackgroundColor3 = Color3.fromRGB(30, 30, 35)
	title.TextColor3 = Color3.fromRGB(100, 200, 255)
	title.Font = Enum.Font.Code
	title.TextSize = 14
	title.Text = "  Dust Simulation - Debug HUD"
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.Parent = frame

	local function createStatLabel(name: string, yPos: number): TextLabel
		local label = Instance.new("TextLabel")
		label.Name = name
		label.Size = UDim2.new(1, -10, 0, 18)
		label.Position = UDim2.new(0, 5, 0, yPos)
		label.BackgroundTransparency = 1
		label.TextColor3 = Color3.fromRGB(200, 200, 210)
		label.Font = Enum.Font.Code
		label.TextSize = 12
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Parent = frame
		return label
	end

	debugFrameLabel = createStatLabel("FrameLabel", 28)
	debugParticleLabel = createStatLabel("ParticleLabel", 46)
	debugFpsLabel = createStatLabel("FpsLabel", 64)
	debugMemoryLabel = createStatLabel("MemoryLabel", 82)
	debugWeatherLabel = createStatLabel("WeatherLabel", 100)

	debugScreenGui = gui
end

local function updateDebugHud(): ()
	if not debugEnabled or not debugScreenGui then
		return
	end

	local engine = renderEngine
	if engine == nil then
		return
	end

	local stats = engine:GetStats()

	if debugFrameLabel then
		debugFrameLabel.Text = string.format("  Frame: %d | Cells: %d", stats.lastFrameId, stats.activeCells)
	end
	if debugParticleLabel then
		debugParticleLabel.Text = string.format("  Particles: %d active / %d pooled / %d total",
			stats.visibleParticles, stats.pooledParts, stats.visibleParticles + stats.pooledParts)
	end
	if debugFpsLabel then
		debugFpsLabel.Text = string.format("  Render: %.2f ms", stats.renderTimeMs)
	end
	if debugMemoryLabel then
		local memKB = ClientState.TotalBytesReceived / 1024
		debugMemoryLabel.Text = string.format("  Data RX: %.2f KB total | %.1f KB/frame avg",
			memKB, memKB / math.max(1, ClientState.TotalFramesReceived))
	end
	if debugWeatherLabel then
		local weatherName = WeatherStates.getState(ClientState.CurrentWeather).name
		debugWeatherLabel.Text = string.format("  Weather: %s", weatherName)
	end
end

local function toggleDebugHud(): ()
	debugEnabled = not debugEnabled
	if debugEnabled then
		createDebugHud()
		if debugScreenGui then
			debugScreenGui.Enabled = true
		end
		if debugHudConnection == nil then
			debugHudConnection = RunService.Heartbeat:Connect(function()
				updateDebugHud()
			end)
		end
		print("[DustSimulation] Debug HUD enabled")
	else
		if debugScreenGui then
			debugScreenGui.Enabled = false
		end
		if debugHudConnection then
			debugHudConnection:Disconnect()
			debugHudConnection = nil
		end
		print("[DustSimulation] Debug HUD disabled")
	end
end

--===========================================================================
-- Weather Application
--===========================================================================

local function applyWeatherEffects(weatherId: number): ()
	ClientState.CurrentWeather = weatherId

	local ambientColor = WeatherStates.getAmbientColor(weatherId)
	local outdoorAmbient = WeatherStates.getOutdoorAmbient(weatherId)
	local fogEnd, fogStart = WeatherStates.getFogSettings(weatherId)

	Lighting.Ambient = ambientColor
	Lighting.OutdoorAmbient = outdoorAmbient
	Lighting.FogEnd = fogEnd
	Lighting.FogStart = fogStart

	local weatherState = WeatherStates.getState(weatherId)
	if weatherState.visibilityReduction > 0.3 then
		Lighting.FogColor = weatherState.ambientColor
	else
		Lighting.FogColor = Color3.fromRGB(200, 200, 210)
	end

	print("[DustSimulation] Client weather updated to:", weatherState.name)
end

--===========================================================================
-- Frame Reception
--===========================================================================

frameUpdateRemote.OnClientEvent:Connect(function(frameBuffer: buffer, cellCount: number, frameId: number)
	local engine = renderEngine
	if engine == nil then
		return
	end

	local startTime = os.clock()

	ClientState.TotalFramesReceived += 1
	ClientState.TotalBytesReceived += buffer.len(frameBuffer)
	ClientState.CurrentFrame = frameId

	engine:ProcessFrame(frameBuffer, cellCount, frameId)

	local frameTime = os.clock() - startTime
	table.insert(ClientState.FrameTimeHistory, frameTime)
	if #ClientState.FrameTimeHistory > 60 then
		table.remove(ClientState.FrameTimeHistory, 1)
	end

	local totalTime = 0
	for _, time in ipairs(ClientState.FrameTimeHistory) do
		totalTime += time
	end
	ClientState.AverageFrameTime = totalTime / #ClientState.FrameTimeHistory
end)

weatherChangeRemote.OnClientEvent:Connect(function(weatherId: number)
	applyWeatherEffects(weatherId)
end)

configRequestRemote.OnClientEvent:Connect(function(configData: any)
	local data = configData :: Types.ClientRenderConfig
	if renderEngine then
		renderEngine:UpdateConfig(data)
	end
end)

--===========================================================================
-- Vehicle Disturbance Reporting
--===========================================================================

local function reportDisturbance(vehicleId: number, position: Vector3, speed: number): ()
	disturbanceRemote:FireServer(vehicleId, position, speed)
end

--===========================================================================
-- Render Loop
--===========================================================================

local function startRenderLoop(): ()
	if renderConnection then
		return
	end

	renderConnection = RunService.Heartbeat:Connect(function()
		local engine = renderEngine
		if engine then
			engine:Flush()
		end
	end)
end

local function stopRenderLoop(): ()
	if renderConnection then
		renderConnection:Disconnect()
		renderConnection = nil
	end
end

--===========================================================================
-- Initialization
--===========================================================================

local function initialize(): ()
	if ClientState.Initialized then
		return
	end

	local config: Types.ClientRenderConfig = {
		gridDimensions = { x = 40, y = 4, z = 40 },
		cellSize = 12.0,
		origin = Vector3.new(-240, 0, -240),
		visualizationThreshold = 0.08,
		maxParticles = 3000,
	}

	renderEngine = BulkRenderEngine.new(config)

	configRequestRemote:FireServer()

	startRenderLoop()

	ClientState.Initialized = true
	print("[DustSimulation] Client visualizer initialized")
end

--===========================================================================
-- Keyboard Input (Debug Toggle)
--===========================================================================

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end

	if input.KeyCode == Enum.KeyCode.F3 then
		toggleDebugHud()
	end
end)

--===========================================================================
-- Cleanup
--===========================================================================

local function cleanup(): ()
	stopRenderLoop()
	if debugHudConnection then
		debugHudConnection:Disconnect()
		debugHudConnection = nil
	end
	if renderEngine then
		renderEngine:Destroy()
		renderEngine = nil
	end
	if debugScreenGui then
		debugScreenGui:Destroy()
		debugScreenGui = nil
	end
	ClientState.Initialized = false
end

Players.PlayerRemoving:Connect(function(leavingPlayer: Player)
	if leavingPlayer == player then
		cleanup()
	end
end)

--===========================================================================
-- Startup
--===========================================================================

print("[DustSimulation] Client script loaded. Initializing visualizer...")
initialize()
print("[DustSimulation] Press F3 to toggle debug HUD")
