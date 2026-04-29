--!strict
--!native

local Workspace = game:GetService("Workspace")

local VoxelGrid = require(script.Parent.VoxelGrid)
local Types = require(script.Parent.Types)

local VoxelRegistry = {}
VoxelRegistry.__index = VoxelRegistry

type VoxelPartConfig = Types.VoxelPartConfig

export type Record = {
	model: Model,
	part: BasePart,
	grid: VoxelGrid.Grid?,
	lazyGrid: boolean,
	assemblyId: number,
	supported: boolean,
	rootPart: BasePart?,
	requiredStrength: number,
	debrisLifetime: number,
	debrisImpulseMultiplier: number,
	maxDebrisVoxels: number,
	maxCuboids: number,
	supportMode: string,
	material: Enum.Material,
	color: Color3,
	transparency: number,
	collisionGroup: string,
	chunks: { BasePart },
	sourceHidden: boolean,
}

export type Assembly = {
	id: number,
	supported: boolean,
	rootPart: BasePart?,
	parts: { [BasePart]: true },
	welds: { [WeldConstraint]: true },
	partCount: number,
	weldCount: number,
}

export type Registry = typeof(setmetatable(
	{} :: {
		recordsBySource: { [BasePart]: Record },
		recordsByQueryPart: { [BasePart]: Record },
		assembliesById: { [number]: Assembly },
		assemblyByPart: { [BasePart]: Assembly },
		pendingConfig: { [BasePart]: VoxelPartConfig },
		overlapParams: OverlapParams,
		maxBroadphaseParts: number,
		nextAssemblyId: number,
	},
	VoxelRegistry
))

local DEFAULT_VOXEL_SIZE = 2
local DEFAULT_MAX_CUBOIDS = 256
local DEFAULT_MAX_DEBRIS = 64
local DEFAULT_DEBRIS_LIFETIME = 2.5
local DEFAULT_DEBRIS_IMPULSE_MULTIPLIER = 1

local function numberAttribute(part: Instance, name: string, fallback: number): number
	local value = part:GetAttribute(name)
	return if typeof(value) == "number" then value else fallback
end

local function stringAttribute(part: Instance, name: string, fallback: string): string
	local value = part:GetAttribute(name)
	return if typeof(value) == "string" then value else fallback
end

local function boolAttribute(part: Instance, name: string): boolean?
	local value = part:GetAttribute(name)
	return if typeof(value) == "boolean" then value else nil
end

local function isBlockPart(part: BasePart): boolean
	if part:IsA("Part") then
		return (part :: Part).Shape == Enum.PartType.Block
	end
	return false
end

local function isVoxelPart(part: BasePart): boolean
	local explicit = boolAttribute(part, "VoxelPart")
	if explicit == false then
		return false
	end

	return isBlockPart(part) or part:IsA("WedgePart")
end

local function mergedConfig(part: BasePart, pending: VoxelPartConfig?): VoxelPartConfig
	local voxelSize = if pending and pending.voxelSize then pending.voxelSize else numberAttribute(part, "VoxelSize", DEFAULT_VOXEL_SIZE)
	local requiredStrength = if pending and pending.requiredStrength then pending.requiredStrength else numberAttribute(part, "RequiredStrength", 0)
	local debrisLifetime = if pending and pending.debrisLifetime then pending.debrisLifetime else numberAttribute(part, "DebrisLifetime", DEFAULT_DEBRIS_LIFETIME)
	local debrisImpulseMultiplier = if pending and pending.debrisImpulseMultiplier then pending.debrisImpulseMultiplier else numberAttribute(part, "DebrisImpulseMultiplier", DEFAULT_DEBRIS_IMPULSE_MULTIPLIER)
	local maxDebrisVoxels = if pending and pending.maxDebrisVoxels then pending.maxDebrisVoxels else numberAttribute(part, "MaxDebrisVoxels", DEFAULT_MAX_DEBRIS)
	local maxCuboids = if pending and pending.maxCuboids then pending.maxCuboids else numberAttribute(part, "MaxCuboids", DEFAULT_MAX_CUBOIDS)

	return {
		voxelSize = math.max(0.05, voxelSize),
		requiredStrength = requiredStrength,
		debrisLifetime = debrisLifetime,
		debrisImpulseMultiplier = debrisImpulseMultiplier,
		maxDebrisVoxels = math.max(0, math.floor(maxDebrisVoxels)),
		maxCuboids = math.max(1, math.floor(maxCuboids)),
		lazyGeneratedGrid = if pending and pending.lazyGeneratedGrid ~= nil then pending.lazyGeneratedGrid else true,
	}
end

function VoxelRegistry.new(): Registry
	local overlapParams = OverlapParams.new()
	overlapParams.MaxParts = 0
	overlapParams.RespectCanCollide = false

	return setmetatable({
		recordsBySource = {},
		recordsByQueryPart = {},
		assembliesById = {},
		assemblyByPart = {},
		pendingConfig = {},
		overlapParams = overlapParams,
		maxBroadphaseParts = 0,
		nextAssemblyId = 1,
	}, VoxelRegistry) :: Registry
end

function VoxelRegistry.allocateAssemblyId(self: Registry): number
	local id = self.nextAssemblyId
	self.nextAssemblyId += 1
	return id
end

function VoxelRegistry.registerAssembly(self: Registry, assemblyId: number, parts: { BasePart }, rootPart: BasePart?, supported: boolean): Assembly
	local assembly = self.assembliesById[assemblyId]
	if not assembly then
		assembly = {
			id = assemblyId,
			supported = supported,
			rootPart = rootPart,
			parts = {},
			welds = {},
			partCount = 0,
			weldCount = 0,
		}
		self.assembliesById[assemblyId] = assembly
	else
		assembly.supported = supported
		assembly.rootPart = rootPart or assembly.rootPart
	end

	for _, part in parts do
		if not assembly.parts[part] then
			assembly.parts[part] = true
			assembly.partCount += 1
		end
		self.assemblyByPart[part] = assembly

		local record = self.recordsBySource[part]
		if record then
			record.assemblyId = assemblyId
			record.supported = supported
			record.rootPart = rootPart
		end
	end

	return assembly
end

function VoxelRegistry.registerWeld(self: Registry, assemblyId: number, weld: WeldConstraint)
	local assembly = self.assembliesById[assemblyId]
	if not assembly or assembly.welds[weld] then
		return
	end

	assembly.welds[weld] = true
	assembly.weldCount += 1
	weld.Destroying:Once(function()
		local currentAssembly = self.assembliesById[assemblyId]
		if currentAssembly and currentAssembly.welds[weld] then
			currentAssembly.welds[weld] = nil
			currentAssembly.weldCount -= 1
		end
	end)
end

function VoxelRegistry.destroyWeldsTouchingParts(self: Registry, parts: { BasePart }, context: any?)
	local partSet: { [BasePart]: boolean } = {}
	local assemblySet: { [number]: Assembly } = {}

	for _, part in parts do
		partSet[part] = true
		local assembly = self.assemblyByPart[part]
		if assembly then
			assemblySet[assembly.id] = assembly
		end
	end

	for _, assembly in assemblySet do
		for weld in assembly.welds do
			if (weld.Part0 and partSet[weld.Part0]) or (weld.Part1 and partSet[weld.Part1]) then
				if context then
					context:consume("weldOps", 1)
					context.stats.weldsDestroyed += 1
				end
				weld:Destroy()
			end
		end
	end

	for _, part in parts do
		for _, child in part:GetChildren() do
			if child:IsA("WeldConstraint") then
				if context then
					context:consume("weldOps", 1)
					context.stats.weldsDestroyed += 1
				end
				child:Destroy()
			end
		end
	end
end

function VoxelRegistry.getAssemblyParts(self: Registry, assemblyId: number): { BasePart }
	local assembly = self.assembliesById[assemblyId]
	if not assembly then
		return {}
	end

	local parts = table.create(assembly.partCount)
	for part in assembly.parts do
		parts[#parts + 1] = part
	end

	return parts
end

function VoxelRegistry.isActiveVoxelPart(self: Registry, part: BasePart): boolean
	return part.Parent ~= nil
		and part:GetAttribute("VoxelPart") == true
		and self.recordsBySource[part] ~= nil
end

function VoxelRegistry.clearAssembliesForParts(self: Registry, parts: { BasePart })
	local affectedAssemblies: { [number]: Assembly } = {}

	for _, part in parts do
		local assembly = self.assemblyByPart[part]
		if not assembly then
			continue
		end

		affectedAssemblies[assembly.id] = assembly
		self.assemblyByPart[part] = nil

		if assembly.parts[part] then
			assembly.parts[part] = nil
			assembly.partCount -= 1
		end

		if assembly.rootPart == part then
			assembly.rootPart = nil
		end
	end

	for assemblyId, assembly in affectedAssemblies do
		if assembly.partCount <= 0 then
			self.assembliesById[assemblyId] = nil
		end
	end
end

function VoxelRegistry.unregisterAssemblyPart(self: Registry, part: BasePart)
	local assembly = self.assemblyByPart[part]
	if not assembly then
		return
	end

	self.assemblyByPart[part] = nil
	if assembly.parts[part] then
		assembly.parts[part] = nil
		assembly.partCount -= 1
	end

	if assembly.rootPart == part then
		assembly.rootPart = nil
	end

	if assembly.partCount <= 0 then
		self.assembliesById[assembly.id] = nil
	end
end

function VoxelRegistry.getAssemblyByPart(self: Registry, part: BasePart): Assembly?
	return self.assemblyByPart[part]
end

function VoxelRegistry.setAssemblySupported(self: Registry, assemblyId: number, supported: boolean)
	local assembly = self.assembliesById[assemblyId]
	if not assembly then
		return
	end

	assembly.supported = supported
	for part in assembly.parts do
		part:SetAttribute("PartBreaker2Supported", supported)
		part.Anchored = supported
		local record = self.recordsBySource[part]
		if record then
			record.supported = supported
		end
	end
end

function VoxelRegistry.configureVoxelPart(self: Registry, part: BasePart, config: VoxelPartConfig)
	self.pendingConfig[part] = config

	local existing = self.recordsBySource[part]
	if existing then
		existing.requiredStrength = config.requiredStrength or existing.requiredStrength
		existing.debrisLifetime = config.debrisLifetime or existing.debrisLifetime
		existing.debrisImpulseMultiplier = config.debrisImpulseMultiplier or existing.debrisImpulseMultiplier
		existing.maxDebrisVoxels = config.maxDebrisVoxels or existing.maxDebrisVoxels
		existing.maxCuboids = config.maxCuboids or existing.maxCuboids
	end
end

function VoxelRegistry.ensureGrid(self: Registry, record: Record, context: any?): VoxelGrid.Grid
	if record.grid then
		return record.grid
	end

	local config = mergedConfig(record.part, self.pendingConfig[record.part])
	record.grid = VoxelGrid.create(record.part, config.voxelSize :: number, record.part:IsA("WedgePart"))
	record.lazyGrid = false
	record.part:SetAttribute("PartBreaker2LazyGrid", false)
	if context then
		context.stats.lazyGridsCreated += 1
	end

	return record.grid :: VoxelGrid.Grid
end

function VoxelRegistry.registerQueryPart(self: Registry, part: BasePart, record: Record)
	self.recordsByQueryPart[part] = record
end

function VoxelRegistry.unregisterQueryPart(self: Registry, part: BasePart)
	self.recordsByQueryPart[part] = nil
end

function VoxelRegistry.registerPart(self: Registry, model: Model, part: BasePart): Record?
	if self.recordsBySource[part] then
		return self.recordsBySource[part]
	end

	if not isVoxelPart(part) then
		return nil
	end

	local config = mergedConfig(part, self.pendingConfig[part])
	local explicitLazyGrid = boolAttribute(part, "PartBreaker2LazyGrid")
	local generatedChunk = part:GetAttribute("_PartBreaker2GeneratedChunk") == true
	local lazyGrid = if explicitLazyGrid ~= nil then explicitLazyGrid else generatedChunk and config.lazyGeneratedGrid ~= false
	local grid = if lazyGrid then nil else VoxelGrid.create(part, config.voxelSize :: number, part:IsA("WedgePart"))
	local supportDefault = if part.Anchored then "Bottom" else "None"
	local assembly = self.assemblyByPart[part]
	if not assembly then
		local attributeAssemblyId = part:GetAttribute("PartBreaker2AssemblyId")
		local assemblyId = if typeof(attributeAssemblyId) == "number" then attributeAssemblyId else self:allocateAssemblyId()
		local attributeSupported = part:GetAttribute("PartBreaker2Supported")
		local supported = if typeof(attributeSupported) == "boolean" then attributeSupported else part.Anchored
		assembly = self:registerAssembly(assemblyId, { part }, part, supported)
	end

	local record: Record = {
		model = model,
		part = part,
		grid = grid,
		lazyGrid = lazyGrid,
		assemblyId = assembly.id,
		supported = assembly.supported,
		rootPart = assembly.rootPart,
		requiredStrength = config.requiredStrength :: number,
		debrisLifetime = config.debrisLifetime :: number,
		debrisImpulseMultiplier = config.debrisImpulseMultiplier :: number,
		maxDebrisVoxels = config.maxDebrisVoxels :: number,
		maxCuboids = config.maxCuboids :: number,
		supportMode = stringAttribute(part, "VoxelSupport", supportDefault),
		material = part.Material,
		color = part.Color,
		transparency = part.Transparency,
		collisionGroup = part.CollisionGroup,
		chunks = {},
		sourceHidden = false,
	}

	self.recordsBySource[part] = record
	self.recordsByQueryPart[part] = record
	part:SetAttribute("_PartBreaker2Registered", true)
	part:SetAttribute("PartBreaker2AssemblyId", record.assemblyId)
	part:SetAttribute("PartBreaker2Supported", record.supported)
	part:SetAttribute("PartBreaker2LazyGrid", lazyGrid)

	return record
end

function VoxelRegistry.registerModel(self: Registry, model: Model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			self:registerPart(model, descendant)
		end
	end
end

function VoxelRegistry.unregisterModel(self: Registry, model: Model)
	local toRemove = table.create(8)
	for part, record in self.recordsBySource do
		if record.model == model then
			toRemove[#toRemove + 1] = record
		end
	end

	for _, record in toRemove do
		self:unregisterRecord(record)
	end
end

function VoxelRegistry.unregisterRecord(self: Registry, record: Record)
	self.recordsBySource[record.part] = nil
	self.recordsByQueryPart[record.part] = nil
	self:unregisterAssemblyPart(record.part)
	record.part:SetAttribute("_PartBreaker2Registered", nil)
	for _, chunk in record.chunks do
		self.recordsByQueryPart[chunk] = nil
	end
end

function VoxelRegistry.getRecordFromQueryPart(self: Registry, part: BasePart): Record?
	return self.recordsByQueryPart[part]
end

function VoxelRegistry.collectRecordsFromParts(self: Registry, parts: { BasePart }): { Record }
	local found = table.create(#parts)
	local seen: { [Record]: boolean } = {}

	for _, part in parts do
		local record = self.recordsByQueryPart[part]
		if record and not seen[record] then
			seen[record] = true
			found[#found + 1] = record
		end
	end

	return found
end

function VoxelRegistry.querySphere(self: Registry, position: Vector3, radius: number): { Record }
	local parts = Workspace:GetPartBoundsInRadius(position, radius, self.overlapParams)
	return self:collectRecordsFromParts(parts)
end

function VoxelRegistry.queryOBB(self: Registry, cframe: CFrame, size: Vector3): { Record }
	local parts = Workspace:GetPartBoundsInBox(cframe, size, self.overlapParams)
	return self:collectRecordsFromParts(parts)
end

return VoxelRegistry
