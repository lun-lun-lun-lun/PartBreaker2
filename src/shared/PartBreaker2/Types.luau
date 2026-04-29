--!strict

export type VoxelPartConfig = {
	voxelSize: number?,
	requiredStrength: number?,
	debrisLifetime: number?,
	debrisImpulseMultiplier: number?,
	maxDebrisVoxels: number?,
	maxCuboids: number?,
	lazyGeneratedGrid: boolean?,
}

export type MakeDestructibleConfig = {
	voxelSize: number?,
	requiredStrength: number?,
	debrisLifetime: number?,
	debrisImpulseMultiplier: number?,
	maxDebrisVoxels: number?,
	maxCuboids: number?,
	supportMode: string?,
	overrideExistingAttributes: boolean?,
	register: boolean?,
	lazyGeneratedGrid: boolean?,
}

export type RuntimeBudgets = {
	maxTasksPerFrame: number?,
	maxRecordsPerFrame: number?,
	maxVoxelTestsPerFrame: number?,
	maxConnectivityVisitsPerFrame: number?,
	maxGreedyVisitsPerFrame: number?,
	maxPartsCommittedPerFrame: number?,
	maxSupportQueriesPerFrame: number?,
	maxWeldOpsPerFrame: number?,
}

export type RuntimeConfig = {
	budgets: RuntimeBudgets?,
	debug: boolean?,
	statsReplicationInterval: number?,
}

export type RuntimeStats = {
	jobsQueued: number,
	jobsCompleted: number,
	queueLength: number,
	recordsHit: number,
	recordsProcessed: number,
	voxelTests: number,
	voxelsRemoved: number,
	connectivityVisits: number,
	componentsExtracted: number,
	greedyVisits: number,
	cuboidsEmitted: number,
	partsCreated: number,
	partsReused: number,
	partsRetired: number,
	lazyGridsCreated: number,
	supportIslandParts: number,
	supportQueries: number,
	weldsDestroyed: number,
	weldsCreated: number,
	debrisEvents: number,
	debrisPositions: number,
	budgetYields: number,
	broadphaseMs: number,
	damageMs: number,
	connectivityMs: number,
	greedyMs: number,
	commitMs: number,
	supportMs: number,
}

export type DestroySphereJob = {
	kind: "sphere",
	position: Vector3,
	radius: number,
	strength: number,
	impulse: Vector3?,
}

export type DestroyOBBJob = {
	kind: "obb",
	cframe: CFrame,
	size: Vector3,
	strength: number,
	impulse: Vector3?,
}

export type DestroyJob = DestroySphereJob | DestroyOBBJob

export type BudgetKey =
	"tasks"
	| "records"
	| "voxelTests"
	| "connectivityVisits"
	| "greedyVisits"
	| "partsCommitted"
	| "supportQueries"
	| "weldOps"

export type BudgetContext = {
	consume: (BudgetContext, BudgetKey, number?) -> (),
	stats: RuntimeStats,
}

export type RemovedVoxel = {
	index: number,
}

export type Cuboid = {
	center: Vector3,
	size: Vector3,
}

export type Component = {
	id: number?,
	record: any?,
	indices: { number },
	supported: boolean,
	cuboids: { Cuboid }?,
	assemblyId: number?,
}

export type BuiltAssembly = {
	assemblyId: number,
	parts: { BasePart },
	rootPart: BasePart?,
	supported: boolean,
}

return {}
