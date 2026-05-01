--!strict
--!native

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ChunkBuilder = require(script.ChunkBuilder)
local Connectivity = require(script.Connectivity)
local DamageSolver = require(script.DamageSolver)
local GreedyMesher = require(script.GreedyMesher)
local JobScheduler = require(script.JobScheduler)
local ShapeTests = require(script.ShapeTests)
local SupportGraph = require(script.SupportGraph)
local VoxelGrid = require(script.VoxelGrid)
local VoxelRegistry = require(script.VoxelRegistry)
local Types = require(script.Types)

local PartBreaker2 = {}

type DestroyJob = Types.DestroyJob
type DestroySphereJob = Types.DestroySphereJob
type DestroyOBBJob = Types.DestroyOBBJob
type VoxelPartConfig = Types.VoxelPartConfig
type MakeDestructibleConfig = Types.MakeDestructibleConfig
type RuntimeConfig = Types.RuntimeConfig
type RuntimeBudgets = Types.RuntimeBudgets
type RuntimeStats = Types.RuntimeStats
type BudgetContext = Types.BudgetContext
type RemovedVoxel = Types.RemovedVoxel
type BuiltAssembly = Types.BuiltAssembly
type Record = VoxelRegistry.Record

type DestructionProfile = {
	id: number,
	kind: string,
	startedAt: number,
	counts: { [string]: number },
	timings: { [string]: number },
}

type AuthoredWeldDescriptor = {
	other: BasePart,
	name: string,
}

type AssemblyWeldCandidate = {
	root: BasePart,
	gap: number,
}

local DEBRIS_REMOTE_NAME = "PartBreaker2DebrisEvent"
local NETWORK_FOLDER_NAME = "PartBreaker2Net"
local DEBUG_STATS_INTERVAL = 0.75
local DEFAULT_DEBRIS_LOD_RADIUS = 200
local WELD_MIGRATION_TOUCH_PADDING = 0.015
local FALL_WAKE_DELTA_VELOCITY = Vector3.new(0, -0.05, 0)

local runtimeFolder = ChunkBuilder.ensureRuntimeFolder()
local registry = VoxelRegistry.new()
local builder = ChunkBuilder.new(runtimeFolder)
local remoteSeed = 0
local destructionProfileSerial = 0
local scheduler = nil :: JobScheduler.Scheduler?
local networkServer = nil :: any?
local networkLoadAttempted = false
local debugStatsConnection = nil :: RBXScriptConnection?

local runtimeConfig: RuntimeConfig = {
	budgets = nil,
	debug = false,
	statsReplicationInterval = DEBUG_STATS_INTERVAL,
	debrisLodRadius = DEFAULT_DEBRIS_LOD_RADIUS,
	logDestructionTimings = false,
}

local stats: RuntimeStats = {
	jobsQueued = 0,
	jobsCompleted = 0,
	queueLength = 0,
	recordsHit = 0,
	recordsProcessed = 0,
	voxelTests = 0,
	voxelsRemoved = 0,
	connectivityVisits = 0,
	componentsExtracted = 0,
	greedyVisits = 0,
	cuboidsEmitted = 0,
	partsCreated = 0,
	partsReused = 0,
	partsRetired = 0,
	lazyGridsCreated = 0,
	supportIslandParts = 0,
	supportQueries = 0,
	supportHashCandidates = 0,
	supportContactTests = 0,
	supportEdgesRebuilt = 0,
	supportComponentsVisited = 0,
	supportWorkspaceQueries = 0,
	weldsDestroyed = 0,
	weldsCreated = 0,
	weldsReused = 0,
	debrisEvents = 0,
	debrisPositions = 0,
	debrisLodSkipped = 0,
	budgetYields = 0,
	gridMs = 0,
	broadphaseMs = 0,
	damageMs = 0,
	debrisMs = 0,
	connectivityMs = 0,
	greedyMs = 0,
	commitMs = 0,
	supportMs = 0,
}

local function getOrCreateDebrisRemote(): RemoteEvent?
	local existing = ReplicatedStorage:FindFirstChild(DEBRIS_REMOTE_NAME)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end

	if not RunService:IsServer() then
		return nil
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = DEBRIS_REMOTE_NAME
	remote.Parent = ReplicatedStorage
	return remote
end

local debrisRemote = getOrCreateDebrisRemote()

local function getNetworkServer(): any?
	if networkServer or networkLoadAttempted then
		return networkServer
	end

	networkLoadAttempted = true
	if not RunService:IsServer() then
		return nil
	end

	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local folder = if shared then shared:FindFirstChild(NETWORK_FOLDER_NAME) else nil
	local serverModule = if folder then folder:FindFirstChild("Server") else nil
	if serverModule and serverModule:IsA("ModuleScript") then
		local ok, result = pcall(require, serverModule)
		if ok then
			networkServer = result
		else
			warn(`PartBreaker2: failed to load Blink server module: {result}`)
		end
	end

	return networkServer
end

local function fireDebugStats()
	if not runtimeConfig.debug then
		return
	end

	local server = getNetworkServer()
	if not server or not server.DebugStats then
		return
	end

	local snapshot = (PartBreaker2 :: any).getStats() :: RuntimeStats
	;(server.DebugStats :: any).FireAll({
		QueueLength = math.min(65535, snapshot.queueLength),
		JobsQueued = math.min(4294967295, snapshot.jobsQueued),
		JobsCompleted = math.min(4294967295, snapshot.jobsCompleted),
		RecordsProcessed = math.min(4294967295, snapshot.recordsProcessed),
		VoxelTests = math.min(4294967295, snapshot.voxelTests),
		VoxelsRemoved = math.min(4294967295, snapshot.voxelsRemoved),
		ComponentsExtracted = math.min(4294967295, snapshot.componentsExtracted),
		CuboidsEmitted = math.min(4294967295, snapshot.cuboidsEmitted),
		PartsCreated = math.min(4294967295, snapshot.partsCreated),
		PartsReused = math.min(4294967295, snapshot.partsReused),
		SupportQueries = math.min(4294967295, snapshot.supportQueries),
		WeldsCreated = math.min(4294967295, snapshot.weldsCreated),
		WeldsDestroyed = math.min(4294967295, snapshot.weldsDestroyed),
		BudgetYields = math.min(4294967295, snapshot.budgetYields),
	})
end

local function ensureDebugStatsLoop()
	if debugStatsConnection or not RunService:IsServer() then
		return
	end

	local accumulator = 0
	debugStatsConnection = RunService.Heartbeat:Connect(function(deltaTime)
		if not runtimeConfig.debug then
			return
		end

		accumulator += deltaTime
		local interval = runtimeConfig.statsReplicationInterval or DEBUG_STATS_INTERVAL
		if accumulator >= interval then
			accumulator = 0
			fireDebugStats()
		end
	end)
end

local function isSupportedVoxelSourcePart(instance: Instance): boolean
	if instance:IsA("WedgePart") then
		return true
	end

	if instance:IsA("Part") then
		return instance.Shape == Enum.PartType.Block
	end

	return false
end

local function setAttributeDefault(instance: Instance, name: string, value: any, fallback: any, overrideExisting: boolean)
	if value ~= nil then
		instance:SetAttribute(name, value)
	elseif overrideExisting or instance:GetAttribute(name) == nil then
		instance:SetAttribute(name, fallback)
	end
end

local function configToVoxelPartConfig(config: MakeDestructibleConfig?): VoxelPartConfig
	if config == nil then
		return {}
	end

	return {
		voxelSize = config.voxelSize,
		requiredStrength = config.requiredStrength,
		debrisLifetime = config.debrisLifetime,
		debrisImpulseMultiplier = config.debrisImpulseMultiplier,
		maxDebrisVoxels = config.maxDebrisVoxels,
		maxCuboids = config.maxCuboids,
		lazyGeneratedGrid = config.lazyGeneratedGrid,
	}
end

local function getRecordGrid(record: Record, context: BudgetContext?): VoxelGrid.Grid
	return registry:ensureGrid(record, context)
end

local function getInheritedConfig(record: Record, context: BudgetContext?): VoxelPartConfig
	local grid = getRecordGrid(record, context)
	return {
		voxelSize = grid.voxelSize,
		requiredStrength = record.requiredStrength,
		debrisLifetime = record.debrisLifetime,
		debrisImpulseMultiplier = record.debrisImpulseMultiplier,
		maxDebrisVoxels = record.maxDebrisVoxels,
		maxCuboids = record.maxCuboids,
		lazyGeneratedGrid = true,
	}
end

local function addProfileCount(context: BudgetContext?, key: string, amount: number)
	if not context or amount == 0 then
		return
	end

	local profile = context.profile
	if not profile then
		return
	end

	local counts = profile.counts
	counts[key] = (counts[key] or 0) + amount
end

local function addMs(field: string, startedAt: number, context: BudgetContext?)
	local elapsedMs = (os.clock() - startedAt) * 1000
	(stats :: any)[field] += elapsedMs

	if context and context.profile then
		local timings = context.profile.timings
		timings[field] = (timings[field] or 0) + elapsedMs
	end
end

local function ms(profile: DestructionProfile, field: string): number
	return profile.timings[field] or 0
end

local function count(profile: DestructionProfile, field: string): number
	return profile.counts[field] or 0
end

local function beginDestructionProfile(job: DestroyJob): DestructionProfile
	destructionProfileSerial += 1
	return {
		id = destructionProfileSerial,
		kind = job.kind,
		startedAt = os.clock(),
		counts = {},
		timings = {},
	}
end

local function finishDestructionProfile(profile: DestructionProfile)
	local totalMs = (os.clock() - profile.startedAt) * 1000
	local phaseMs = ms(profile, "broadphaseMs")
		+ ms(profile, "gridMs")
		+ ms(profile, "damageMs")
		+ ms(profile, "debrisMs")
		+ ms(profile, "connectivityMs")
		+ ms(profile, "greedyMs")
		+ ms(profile, "commitMs")
		+ ms(profile, "supportMs")
	local schedulerWaitMs = math.max(0, totalMs - phaseMs)

	print(string.format(
		"[PartBreaker2 timing #%d %s] total=%.2fms phases=%.2fms schedulerWait=%.2fms yields=%d records=%d/%d damaged=%d voxels=%d debris=%d components=%d cuboids=%d",
		profile.id,
		profile.kind,
		totalMs,
		phaseMs,
		schedulerWaitMs,
		count(profile, "budgetYields"),
		count(profile, "recordsProcessed"),
		count(profile, "recordsHit"),
		count(profile, "recordsDamaged"),
		count(profile, "voxelsRemoved"),
		count(profile, "debrisPositions"),
		count(profile, "componentsExtracted"),
		count(profile, "cuboidsEmitted")
	))

	print(string.format(
		"  phases: broadphase=%.2f grid=%.2f damage=%.2f debris=%.2f connectivity=%.2f greedy=%.2f commit=%.2f support=%.2f",
		ms(profile, "broadphaseMs"),
		ms(profile, "gridMs"),
		ms(profile, "damageMs"),
		ms(profile, "debrisMs"),
		ms(profile, "connectivityMs"),
		ms(profile, "greedyMs"),
		ms(profile, "commitMs"),
		ms(profile, "supportMs")
	))

	print(string.format(
		"  work: lazyGrids=%d partsCreated=%d partsReused=%d partsRetired=%d supportParts=%d supportQueries=%d weldsCreated=%d weldsReused=%d weldsDestroyed=%d unsupportedRoots=%d",
		count(profile, "lazyGridsCreated"),
		count(profile, "partsCreated"),
		count(profile, "partsReused"),
		count(profile, "partsRetired"),
		count(profile, "supportIslandParts"),
		count(profile, "supportQueries"),
		count(profile, "weldsCreated"),
		count(profile, "weldsReused"),
		count(profile, "weldsDestroyed"),
		count(profile, "unsupportedRoots")
	))

	print(string.format(
		"  support graph: workspaceQueries=%d hashCandidates=%d contactTests=%d edgesRebuilt=%d componentsVisited=%d",
		count(profile, "supportWorkspaceQueries"),
		count(profile, "supportHashCandidates"),
		count(profile, "supportContactTests"),
		count(profile, "supportEdgesRebuilt"),
		count(profile, "supportComponentsVisited")
	))
end

local function anyPlayerWithin(position: Vector3, radius: number): boolean
	if radius <= 0 then
		return true
	end

	local radiusSquared = radius * radius
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character then
			continue
		end
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			local delta = hrp.Position - position
			if delta:Dot(delta) <= radiusSquared then
				return true
			end
		end
	end

	return false
end

local function sampleDebrisPositions(record: Record, removed: { RemovedVoxel }, context: BudgetContext?): { Vector3 }
	local grid = getRecordGrid(record, context)
	local limit = math.min(record.maxDebrisVoxels, #removed)
	local positions = table.create(limit) :: { Vector3 }
	if limit <= 0 then
		return positions
	end

	local stride = math.max(1, math.ceil(#removed / limit))
	local emitted = 0

	for index = 1, #removed, stride do
		local removedVoxel = removed[index]
		local localCenter = VoxelGrid.indexCenter(grid, removedVoxel.index)
		emitted += 1
		positions[emitted] = record.part.CFrame * localCenter
		if emitted >= limit then
			break
		end
	end

	return positions
end

local function appendUniquePart(parts: { BasePart }, seen: { [BasePart]: boolean }, part: BasePart)
	if seen[part] then
		return
	end

	seen[part] = true
	parts[#parts + 1] = part
end

local function appendAssemblyParts(parts: { BasePart }, seen: { [BasePart]: boolean }, assemblyParts: { BasePart })
	for _, part in assemblyParts do
		appendUniquePart(parts, seen, part)
	end
end

local function isExternalSupportPart(part: BasePart): boolean
	if part.Parent == nil then
		return false
	end

	if part:GetAttribute("PartBreaker2SupportAnchor") == true then
		return true
	end

	if registry.recordsBySource[part] ~= nil or part:GetAttribute("VoxelPart") == true then
		return false
	end

	return part.Anchored
end

local function worldAabb(cframe: CFrame, size: Vector3): (Vector3, Vector3)
	local half = size * 0.5
	local right = cframe.RightVector
	local up = cframe.UpVector
	local look = cframe.LookVector
	local extent = Vector3.new(
		math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(look.X) * half.Z,
		math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(look.Y) * half.Z,
		math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(look.Z) * half.Z
	)

	return cframe.Position - extent, cframe.Position + extent
end

local function axisGap(minA: number, maxA: number, minB: number, maxB: number): number
	if maxA < minB then
		return minB - maxA
	end
	if maxB < minA then
		return minA - maxB
	end
	return 0
end

local function partSurfaceGap(part: BasePart, other: BasePart): number
	if ShapeTests.partsTouch(part.CFrame, part.Size, other.CFrame, other.Size, WELD_MIGRATION_TOUCH_PADDING) then
		return 0
	end

	local minA, maxA = worldAabb(part.CFrame, part.Size)
	local minB, maxB = worldAabb(other.CFrame, other.Size)
	local dx = axisGap(minA.X, maxA.X, minB.X, maxB.X)
	local dy = axisGap(minA.Y, maxA.Y, minB.Y, maxB.Y)
	local dz = axisGap(minA.Z, maxA.Z, minB.Z, maxB.Z)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Authored welds touching a dying source part are destroyed during retirement.
-- Capture enough information to recreate them on the surviving replacement
-- assemblies, regardless of where the original WeldConstraint was parented.
local function collectAuthoredWelds(sourcePart: BasePart): { AuthoredWeldDescriptor }
	local descriptors = {} :: { AuthoredWeldDescriptor }
	local seen: { [WeldConstraint]: boolean } = {}

	for _, weld in registry:collectWeldsTouchingPart(sourcePart) do
		if seen[weld] or weld:GetAttribute("_PartBreaker2Weld") == true then
			continue
		end
		seen[weld] = true

		local part0 = weld.Part0
		local part1 = weld.Part1
		if not part0 or not part1 then
			continue
		end

		local other: BasePart? = nil
		if part0 == sourcePart then
			other = part1
		elseif part1 == sourcePart then
			other = part0
		end

		if other and other ~= sourcePart and other.Parent ~= nil then
			descriptors[#descriptors + 1] = {
				other = other,
				name = weld.Name,
			}
		end
	end

	return descriptors
end

local function closestCandidate(candidates: { AssemblyWeldCandidate }): AssemblyWeldCandidate?
	local closest = nil :: AssemblyWeldCandidate?
	local closestGap = math.huge
	for _, candidate in candidates do
		if candidate.gap < closestGap then
			closestGap = candidate.gap
			closest = candidate
		end
	end
	return closest
end

local function getWeldTargets(other: BasePart, builtAssemblies: { BuiltAssembly }): { BasePart }
	local allCandidates = {} :: { AssemblyWeldCandidate }
	local touchingCandidates = {} :: { AssemblyWeldCandidate }

	for _, assembly in builtAssemblies do
		local root = assembly.rootPart
		if not root or root.Parent == nil then
			continue
		end

		local bestGap = math.huge
		for _, part in assembly.parts do
			if part.Parent == nil then
				continue
			end

			local gap = partSurfaceGap(part, other)
			if gap < bestGap then
				bestGap = gap
			end
		end

		if bestGap == math.huge then
			continue
		end

		local candidate: AssemblyWeldCandidate = {
			root = root,
			gap = bestGap,
		}
		allCandidates[#allCandidates + 1] = candidate
		if bestGap <= WELD_MIGRATION_TOUCH_PADDING then
			touchingCandidates[#touchingCandidates + 1] = candidate
		end
	end

	local targets = {} :: { BasePart }
	if #touchingCandidates > 0 then
		if isExternalSupportPart(other) then
			for _, candidate in touchingCandidates do
				targets[#targets + 1] = candidate.root
			end
		else
			local closestTouching = closestCandidate(touchingCandidates)
			if closestTouching then
				targets[#targets + 1] = closestTouching.root
			end
		end
		return targets
	end

	local nearest = closestCandidate(allCandidates)
	if nearest then
		targets[#targets + 1] = nearest.root
	end
	return targets
end

local function migrateAuthoredWelds(descriptors: { AuthoredWeldDescriptor }, builtAssemblies: { BuiltAssembly }, context: BudgetContext?)
	if #descriptors <= 0 or #builtAssemblies <= 0 then
		return
	end

	local createdByOther: { [BasePart]: { [BasePart]: boolean } } = {}
	for _, descriptor in descriptors do
		local other = descriptor.other
		if other.Parent == nil then
			continue
		end

		local rootSet = createdByOther[other]
		if not rootSet then
			rootSet = {} :: { [BasePart]: boolean }
			createdByOther[other] = rootSet
		end

		for _, root in getWeldTargets(other, builtAssemblies) do
			if rootSet[root] or root.Parent == nil or other.Parent == nil then
				continue
			end
			rootSet[root] = true

			if context then
				context:consume("weldOps", 1)
				context.stats.weldsCreated += 1
			end

			local migrated = Instance.new("WeldConstraint")
			migrated.Name = descriptor.name
			migrated.Part0 = root
			migrated.Part1 = other
			migrated.Parent = root
			registry:trackWeld(migrated)
		end
	end
end

local function applyImpulseToRoots(roots: { BasePart }, impulse: Vector3?)
	local wakeImpulse = if impulse and impulse.Magnitude > 0 then impulse else FALL_WAKE_DELTA_VELOCITY
	for _, root in roots do
		task.defer(function()
			if root.Parent ~= nil and not root.Anchored then
				root:ApplyImpulse(wakeImpulse * math.max(1, root.AssemblyMass))
			end
		end)
	end
end

local function fireDebris(record: Record, removed: { RemovedVoxel }, impulse: Vector3?, context: BudgetContext?)
	if #removed <= 0 then
		return
	end

	local lodRadius = runtimeConfig.debrisLodRadius or 0
	if RunService:IsServer() and lodRadius > 0 and not anyPlayerWithin(record.part.Position, lodRadius) then
		if context then
			context.stats.debrisLodSkipped += 1
		else
			stats.debrisLodSkipped += 1
		end
		return
	end

	local positions = sampleDebrisPositions(record, removed, context)
	if #positions <= 0 then
		return
	end

	remoteSeed = (remoteSeed + 1) % 2147483647
	if context then
		context.stats.debrisEvents += 1
		context.stats.debrisPositions += #positions
	else
		stats.debrisEvents += 1
		stats.debrisPositions += #positions
	end

	local grid = getRecordGrid(record, context)
	local scaledImpulse = (impulse or Vector3.zero) * record.debrisImpulseMultiplier
	local server = getNetworkServer()
	if server and server.Debris then
		(server.Debris :: any).FireAll({
			Seed = remoteSeed,
			Positions = positions,
			CellSize = grid.cellSize,
			Color = record.color,
			Material = record.material.Value,
			Impulse = scaledImpulse,
			Lifetime = record.debrisLifetime,
		})
	elseif debrisRemote then
		debrisRemote:FireAllClients({
			seed = remoteSeed,
			positions = positions,
			cellSize = grid.cellSize,
			color = record.color,
			material = record.material.Name,
			impulse = scaledImpulse,
			lifetime = record.debrisLifetime,
		})
	end
end

local function retireRecord(record: Record, context: BudgetContext?)
	-- Only tear down welds that actually touch the dying source part. Welds
	-- between surviving sibling chunks are preserved so SupportGraph's diff
	-- can claim them for the rebuilt assemblies.
	registry:destroyWeldsTouchingParts({ record.part }, context)
	registry:unregisterRecord(record)

	if record.part:GetAttribute("_PartBreaker2GeneratedChunk") == true then
		builder:retirePart(record.part, context)
	else
		ChunkBuilder.hideSourcePart(record.part, context)
	end

	for _, chunk in record.chunks do
		registry:unregisterQueryPart(chunk)
	end
end

local function rebuildRecord(record: Record, impulse: Vector3?, context: BudgetContext)
	local grid = getRecordGrid(record, context)
	local oldCFrame = record.part.CFrame
	local oldSize = record.part.Size
	local startedAt = os.clock()
	registry:ensureSupportContacts(record.part, context)
	local oldContactNeighbors = registry:getContactNeighbors(record.part)
	addMs("supportMs", startedAt, context)

	local dirtySeedParts = table.create(#oldContactNeighbors + 8) :: { BasePart }
	local dirtySeedSet: { [BasePart]: boolean } = {}
	appendAssemblyParts(dirtySeedParts, dirtySeedSet, oldContactNeighbors)

	startedAt = os.clock()
	local components = Connectivity.extractComponents(grid, context)
	addMs("connectivityMs", startedAt, context)

	startedAt = os.clock()
	for componentIndex, component in components do
		component.id = componentIndex
		component.record = record
		component.assemblyId = registry:allocateAssemblyId()
		component.supported = false
		component.cuboids = GreedyMesher.meshComponent(grid, component, record.maxCuboids, context)
	end
	addMs("greedyMs", startedAt, context)

	local inheritedConfig = getInheritedConfig(record, context)
	local model = record.model
	local newParts = table.create(16) :: { BasePart }
	local newPartSet: { [BasePart]: boolean } = {}

	local authoredWelds = collectAuthoredWelds(record.part)

	startedAt = os.clock()
	local builtAssemblies = builder:buildChunks(record, components, context, inheritedConfig.lazyGeneratedGrid ~= false)
	retireRecord(record, context)

	for _, builtAssembly in builtAssemblies do
		registry:registerAssembly(
			builtAssembly.assemblyId,
			builtAssembly.parts,
			builtAssembly.rootPart,
			builtAssembly.supported
		)

		for _, chunk in builtAssembly.parts do
			appendUniquePart(newParts, newPartSet, chunk)
			appendUniquePart(dirtySeedParts, dirtySeedSet, chunk)
			registry:configureVoxelPart(chunk, inheritedConfig)
			registry:registerPart(model, chunk)
		end
	end
	migrateAuthoredWelds(authoredWelds, builtAssemblies, context)
	builder:flushBulkMoves()
	addMs("commitMs", startedAt, context)

	startedAt = os.clock()
	local queryPadding = math.max(2, grid.voxelSize * 2)
	local refreshResult = SupportGraph.refreshAroundDamage(
		registry,
		dirtySeedParts,
		oldCFrame,
		oldSize + Vector3.new(queryPadding, queryPadding, queryPadding),
		newParts,
		context
	)
	builder:flushBulkMoves()
	addMs("supportMs", startedAt, context)
	addProfileCount(context, "unsupportedRoots", #refreshResult.unsupportedRoots)
	applyImpulseToRoots(refreshResult.unsupportedRoots, impulse)
end

local function processRecordDamage(record: Record, removed: { RemovedVoxel }, impulse: Vector3?, context: BudgetContext)
	if #removed <= 0 then
		return
	end

	addProfileCount(context, "recordsDamaged", 1)
	local startedAt = os.clock()
	fireDebris(record, removed, impulse, context)
	addMs("debrisMs", startedAt, context)
	rebuildRecord(record, impulse, context)
end

local function processSphere(context: BudgetContext, job: DestroySphereJob)
	local startedAt = os.clock()
	local records = registry:querySphere(job.position, job.radius)
	addMs("broadphaseMs", startedAt, context)
	context.stats.recordsHit += #records

	for _, record in records do
		context:consume("records", 1)
		context.stats.recordsProcessed += 1
		startedAt = os.clock()
		getRecordGrid(record, context)
		addMs("gridMs", startedAt, context)

		startedAt = os.clock()
		local result = DamageSolver.applySphere(record, job.position, job.radius, job.strength, context)
		addMs("damageMs", startedAt, context)
		processRecordDamage(record, result.removed, job.impulse, context)
	end
end

local function processOBB(context: BudgetContext, job: DestroyOBBJob)
	local startedAt = os.clock()
	local records = registry:queryOBB(job.cframe, job.size)
	addMs("broadphaseMs", startedAt, context)
	context.stats.recordsHit += #records

	for _, record in records do
		context:consume("records", 1)
		context.stats.recordsProcessed += 1
		startedAt = os.clock()
		getRecordGrid(record, context)
		addMs("gridMs", startedAt, context)

		startedAt = os.clock()
		local result = DamageSolver.applyOBB(record, job.cframe, job.size, job.strength, context)
		addMs("damageMs", startedAt, context)
		processRecordDamage(record, result.removed, job.impulse, context)
	end
end

local function enqueueDestroyJob(job: DestroyJob)
	if not scheduler then
		return
	end

	local name = if job.kind == "sphere" then "destroySphere" else "destroyOBB"
	scheduler:enqueue(name, function(context: BudgetContext)
		local profile = if runtimeConfig.logDestructionTimings == true then beginDestructionProfile(job) else nil
		context:setProfile(profile)

		if job.kind == "sphere" then
			processSphere(context, job :: DestroySphereJob)
		else
			processOBB(context, job :: DestroyOBBJob)
		end

		if profile then
			finishDestructionProfile(profile)
			context:setProfile(nil)
		end
	end)
end

if RunService:IsServer() then
	scheduler = JobScheduler.new(stats, runtimeConfig.budgets)
	ensureDebugStatsLoop()
	getNetworkServer()
end

function PartBreaker2.configureRuntime(config: RuntimeConfig)
	if config.budgets ~= nil then
		runtimeConfig.budgets = config.budgets
		if scheduler then
			scheduler:configure(config.budgets :: RuntimeBudgets)
		end
	end

	if config.debug ~= nil then
		runtimeConfig.debug = config.debug
	end

	if config.statsReplicationInterval ~= nil then
		runtimeConfig.statsReplicationInterval = config.statsReplicationInterval
	end

	if config.debrisLodRadius ~= nil then
		runtimeConfig.debrisLodRadius = config.debrisLodRadius
	end

	if config.logDestructionTimings ~= nil then
		runtimeConfig.logDestructionTimings = config.logDestructionTimings
	end
end

function PartBreaker2.getStats(): RuntimeStats
	if scheduler then
		stats.queueLength = scheduler:pendingCount()
	end

	local copy = {} :: any
	for key, value in stats :: any do
		copy[key] = value
	end
	return copy :: RuntimeStats
end

function PartBreaker2.flushPendingJobs(maxFrames: number?)
	if scheduler then
		scheduler:flush(maxFrames)
	end
end

function PartBreaker2.registerModel(model: Model)
	registry:registerModel(model)
end

function PartBreaker2.unregisterModel(model: Model)
	registry:unregisterModel(model)
end

function PartBreaker2.configureVoxelPart(part: BasePart, config: VoxelPartConfig)
	registry:configureVoxelPart(part, config)
end

function PartBreaker2.makeModelDestructible(model: Model, config: MakeDestructibleConfig?): number
	local overrideExisting = if config then config.overrideExistingAttributes == true else false
	local configuredCount = 0
	local voxelConfig = configToVoxelPartConfig(config)

	model:SetAttribute("VoxelModel", true)
	if RunService:IsServer() then
		CollectionService:AddTag(model, "VoxelModel")
	end

	for _, descendant in model:GetDescendants() do
		if not isSupportedVoxelSourcePart(descendant) then
			continue
		end

		local part = descendant :: BasePart
		part:SetAttribute("VoxelPart", true)
		setAttributeDefault(part, "VoxelSize", if config then config.voxelSize else nil, 2, overrideExisting)
		setAttributeDefault(part, "RequiredStrength", if config then config.requiredStrength else nil, 0, overrideExisting)
		setAttributeDefault(part, "MaxCuboids", if config then config.maxCuboids else nil, 256, overrideExisting)
		setAttributeDefault(part, "MaxDebrisVoxels", if config then config.maxDebrisVoxels else nil, 64, overrideExisting)
		setAttributeDefault(part, "DebrisLifetime", if config then config.debrisLifetime else nil, 2.5, overrideExisting)
		setAttributeDefault(part, "DebrisImpulseMultiplier", if config then config.debrisImpulseMultiplier else nil, 1, overrideExisting)
		setAttributeDefault(part, "VoxelSupport", if config then config.supportMode else nil, if part.Anchored then "Bottom" else "None", overrideExisting)
		setAttributeDefault(part, "PartBreaker2LazyGrid", false, false, overrideExisting)

		registry:configureVoxelPart(part, voxelConfig)
		configuredCount += 1
	end

	if config == nil or config.register ~= false then
		PartBreaker2.registerModel(model)
	end

	return configuredCount
end

function PartBreaker2.destroySphere(position: Vector3, radius: number, strength: number, impulse: Vector3?)
	enqueueDestroyJob({
		kind = "sphere",
		position = position,
		radius = radius,
		strength = strength,
		impulse = impulse,
	})
end

function PartBreaker2.destroyOBB(cframe: CFrame, size: Vector3, strength: number, impulse: Vector3?)
	enqueueDestroyJob({
		kind = "obb",
		cframe = cframe,
		size = size,
		strength = strength,
		impulse = impulse,
	})
end

function PartBreaker2.registerTaggedModels()
	for _, instance in CollectionService:GetTagged("VoxelModel") do
		if instance:IsA("Model") then
			PartBreaker2.registerModel(instance)
		end
	end
end

function PartBreaker2.registerAttributedModels(root: Instance?)
	local searchRoot = root or Workspace
	for _, instance in searchRoot:GetDescendants() do
		if instance:IsA("Model") and instance:GetAttribute("VoxelModel") == true then
			PartBreaker2.registerModel(instance)
		end
	end
end

function PartBreaker2.getRuntimeFolder(): Folder
	return runtimeFolder
end

return PartBreaker2
