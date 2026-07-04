--!strict
-- Types.luau
-- Central type definitions for the Dynamic Road Dust & Particulate Simulation Engine.
-- All modules import from here to maintain a single source of truth for data contracts.

export type Vector3Int = {
	x: number,
	y: number,
	z: number,
}

export type CellId = number

export type DustDensity = number -- 0.0 to 1.0 normalized
export type WindSpeed = number -- studs per second
export type DisturbanceLevel = number -- 0.0 to 1.0

export type WindVector = {
	directionX: number,
	directionY: number,
	directionZ: number,
	magnitude: WindSpeed,
}

export type GridCell = {
	id: CellId,
	coords: Vector3Int,
	worldPosition: Vector3,
	density: DustDensity,
	wind: WindVector,
	disturbance: DisturbanceLevel,
	materialId: number,
	neighborIds: { CellId },
}

export type CellBinaryLayout = {
	idOffset: number,
	densityOffset: number,
	windOffset: number,
	disturbanceOffset: number,
	materialOffset: number,
	totalSize: number,
}

export type MaterialProfile = {
	id: number,
	name: string,
	surfaceRoughness: number,
	dustRetention: number,
	dustGenerationRate: number,
	windResistance: number,
	frictionCoefficient: number,
	color: Color3,
	particleSizeMultiplier: number,
}

export type WeatherState = {
	id: number,
	name: string,
	windBaseSpeed: number,
	windDirection: Vector3,
	humidity: number,
	precipitationRate: number,
	dustSuppression: number,
	visibilityReduction: number,
	ambientColor: Color3,
	outdoorAmbient: Color3,
	fogEnd: number,
	fogStart: number,
}

export type VehicleProfile = {
	id: number,
	name: string,
	weight: number,
	speed: number,
	tireWidth: number,
	disturbanceRadius: number,
	disturbanceForce: number,
	particleEmissionRate: number,
	maxEmissionHeight: number,
	dustKickMultiplier: number,
}

export type DustParticleProfile = {
	id: number,
	name: string,
	baseSize: number,
	dragCoefficient: number,
	gravityMultiplier: number,
	settlingRate: number,
	color: Color3,
	transparency: number,
	lifetime: number,
}

export type SectorAssignment = {
	sectorId: number,
	startCell: CellId,
	endCell: CellId,
	cellCount: number,
}

export type SimulationConfig = {
	gridDimensions: Vector3Int,
	cellSize: number,
	sectorCount: number,
	tickRate: number,
	maxDensity: number,
	diffusionRate: number,
	decayRate: number,
	windInfluence: number,
	gravitySettling: number,
	disturbanceThreshold: number,
	visualizationThreshold: number,
}

export type SimulationFrame = {
	frameId: number,
	timestamp: number,
	buffer: buffer,
	cellCount: number,
	layout: CellBinaryLayout,
}

export type RenderBatch = {
	cfames: { CFrame },
	parts: { BasePart },
	count: number,
}

export type PoolEntry = {
	part: BasePart,
	inUse: boolean,
	lastUsedFrame: number,
	densityValue: number,
}

export type ObjectPoolConfig = {
	template: BasePart,
	initialSize: number,
	maxSize: number,
	growthRate: number,
	cullThreshold: number,
	cullInterval: number,
}

export type BulkRenderConfig = {
	maxPartsPerBatch: number,
	updateRate: number,
	lerpFactor: number,
	useBulkMoveTo: boolean,
	renderMode: Enum.RenderFidelity,
}

export type ActorMessage = {
	sectorId: number,
	frameId: number,
	buffer: buffer,
	cellCount: number,
}

export type NeighborQuery = {
	radius: number,
	maxResults: number,
	filter: (CellId, GridCell) -> boolean,
}

export type GridStatistics = {
	totalCells: number,
	activeCells: number,
	averageDensity: number,
	maxDensity: DustDensity,
	totalDustMass: number,
	sectorsProcessed: number,
	processingTimeMs: number,
}

export type ClientVisualizationState = {
	visibleParticles: number,
	pooledParts: number,
	activeCells: number,
	renderTimeMs: number,
	lastFrameId: number,
}

export type EngineState = {
	Running: "Stopped" | "Starting" | "Running" | "Stopping" | "Paused",
	CurrentFrame: number,
	CurrentWeather: number,
	ActiveVehicles: number,
}

export type OctreeBounds = {
	min: Vector3,
	max: Vector3,
	center: Vector3,
	size: Vector3,
}

export type OctreeNode = {
	bounds: OctreeBounds,
	depth: number,
	cells: { GridCell },
	children: { OctreeNode? } & { [number]: OctreeNode? },
	isLeaf: boolean,
	maxCells: number,
}

export type FluidDynamicsParams = {
	viscosity: number,
	diffusion: number,
	advectionWeight: number,
	pressureWeight: number,
	iterations: number,
}

export type WindField = {
	grid: { WindVector },
	dimensions: Vector3Int,
	globalDirection: Vector3,
	globalSpeed: number,
	turbulence: number,
}

export type DisturbanceEvent = {
	cellId: CellId,
	source: "Vehicle" | "Wind" | "Explosion" | "Footstep" | "Custom",
	intensity: number,
	radius: number,
	timestamp: number,
	duration: number,
}

export type CityBlock = {
	id: number,
	name: string,
	origin: Vector3,
	size: Vector3,
	materialId: number,
	trafficDensity: number,
	buildingHeight: number,
}

export type CityLayout = {
	blocks: { CityBlock },
	roadNetwork: { { Vector3 } },
	totalArea: number,
	gridOrigin: Vector3,
}

export type ClientRenderConfig = {
	gridDimensions: Vector3Int,
	cellSize: number,
	origin: Vector3,
	visualizationThreshold: number,
	maxParticles: number,
}

export type ClientState = {
	Initialized: boolean,
	CurrentWeather: number,
	CurrentFrame: number,
	TotalFramesReceived: number,
	TotalBytesReceived: number,
	LastFrameTime: number,
	AverageFrameTime: number,
	FrameTimeHistory: { number },
}

return nil
