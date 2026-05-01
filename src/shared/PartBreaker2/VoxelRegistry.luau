--!strict
--!native

local Workspace = game:GetService("Workspace")

local ShapeTests = require(script.Parent.ShapeTests)
local SpatialHash = require(script.Parent.SpatialHash)
local VoxelGrid = require(script.Parent.VoxelGrid)
local Types = require(script.Parent.Types)

local VoxelRegistry = {}
VoxelRegistry.__index = VoxelRegistry

type VoxelPartConfig = Types.VoxelPartConfig
type SupportHash = SpatialHash.Hash

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
	weldByPart: { [BasePart]: WeldConstraint },
	partCount: number,
	weldCount: number,
}

export type Registry = typeof(setmetatable(
	{} :: {
		recordsBySource: { [BasePart]: Record },
		recordsByQueryPart: { [BasePart]: Record },
		assembliesById: { [number]: Assembly },
		assemblyByPart: { [BasePart]: Assembly },
		supportHash: SupportHash,
		contactNeighborsByPart: { [BasePart]: { [BasePart]: true } },
		directSupportByPart: { [BasePart]: boolean },
		supportContactsValid: { [BasePart]: boolean },
		externalSupportValid: { [BasePart]: boolean },
		weldsByPart: { [BasePart]: { [WeldConstraint]: true } },
		weldDestroyingByWeld: { [WeldConstraint]: RBXScriptConnection },
		weldChildAddedByPart: { [BasePart]: RBXScriptConnection },
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
local SUPPORT_HASH_CELL_SIZE = 16
local CONTACT_PADDING = 0.015

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

local function isExplicitSupportAnchor(part: BasePart): boolean
	return part:GetAttribute("PartBreaker2SupportAnchor") == true
end

local function isExternalSupport(registry: Registry, part: BasePart): boolean
	if part.Parent == nil then
		return false
	end

	if isExplicitSupportAnchor(part) then
		return true
	end

	if registry.recordsBySource[part] ~= nil or part:GetAttribute("VoxelPart") == true then
		return false
	end

	return part.Anchored
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
		recordsBySource = {} :: { [BasePart]: Record },
		recordsByQueryPart = {} :: { [BasePart]: Record },
		assembliesById = {} :: { [number]: Assembly },
		assemblyByPart = {} :: { [BasePart]: Assembly },
		supportHash = SpatialHash.new(SUPPORT_HASH_CELL_SIZE),
		contactNeighborsByPart = {} :: { [BasePart]: { [BasePart]: true } },
		directSupportByPart = {} :: { [BasePart]: boolean },
		supportContactsValid = {} :: { [BasePart]: boolean },
		externalSupportValid = {} :: { [BasePart]: boolean },
		weldsByPart = {} :: { [BasePart]: { [WeldConstraint]: true } },
		weldDestroyingByWeld = {} :: { [WeldConstraint]: RBXScriptConnection },
		weldChildAddedByPart = {} :: { [BasePart]: RBXScriptConnection },
		pendingConfig = {} :: { [BasePart]: VoxelPartConfig },
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

local function getContactSet(self: Registry, part: BasePart): { [BasePart]: true }
	local set = self.contactNeighborsByPart[part]
	if not set then
		set = {} :: { [BasePart]: true }
		self.contactNeighborsByPart[part] = set
	end
	return set
end

local function addContactEdge(self: Registry, a: BasePart, b: BasePart, context: any?)
	if a == b then
		return
	end

	local aSet = getContactSet(self, a)
	if aSet[b] then
		return
	end

	aSet[b] = true
	getContactSet(self, b)[a] = true
	if context then
		context.stats.supportEdgesRebuilt += 1
	end
end

local unindexWeld

local function indexWeld(self: Registry, weld: WeldConstraint)
	local part0 = weld.Part0
	local part1 = weld.Part1
	if not part0 or not part1 or part0 == part1 then
		return
	end

	local set0 = self.weldsByPart[part0]
	if not set0 then
		set0 = {} :: { [WeldConstraint]: true }
		self.weldsByPart[part0] = set0
	end
	set0[weld] = true

	local set1 = self.weldsByPart[part1]
	if not set1 then
		set1 = {} :: { [WeldConstraint]: true }
		self.weldsByPart[part1] = set1
	end
	set1[weld] = true

	self.externalSupportValid[part0] = nil
	self.externalSupportValid[part1] = nil

	if not self.weldDestroyingByWeld[weld] then
		self.weldDestroyingByWeld[weld] = weld.Destroying:Connect(function()
			unindexWeld(self, weld)
		end)
	end
end

function unindexWeld(self: Registry, weld: WeldConstraint)
	local conn = self.weldDestroyingByWeld[weld]
	if conn then
		conn:Disconnect()
		self.weldDestroyingByWeld[weld] = nil
	end

	local part0 = weld.Part0
	if part0 then
		local set0 = self.weldsByPart[part0]
		if set0 then
			set0[weld] = nil
			self.externalSupportValid[part0] = nil
		end
	end

	local part1 = weld.Part1
	if part1 then
		local set1 = self.weldsByPart[part1]
		if set1 then
			set1[weld] = nil
			self.externalSupportValid[part1] = nil
		end
	end
end

function VoxelRegistry.trackWeld(self: Registry, weld: WeldConstraint)
	indexWeld(self, weld)
end

function VoxelRegistry.collectWeldsTouchingPart(self: Registry, part: BasePart): { WeldConstraint }
	local found = {} :: { WeldConstraint }
	local seen: { [WeldConstraint]: boolean } = {}

	local indexed = self.weldsByPart[part]
	if indexed then
		for weld in indexed do
			if weld.Parent ~= nil and (weld.Part0 == part or weld.Part1 == part) then
				seen[weld] = true
				found[#found + 1] = weld
			end
		end
	end

	for _, descendant in Workspace:GetDescendants() do
		if not descendant:IsA("WeldConstraint") then
			continue
		end

		local weld = descendant :: WeldConstraint
		if seen[weld] then
			continue
		end

		if weld.Part0 == part or weld.Part1 == part then
			self:trackWeld(weld)
			seen[weld] = true
			found[#found + 1] = weld
		end
	end

	return found
end

local function scanPartForWelds(self: Registry, part: BasePart)
	for _, child in part:GetChildren() do
		if child:IsA("WeldConstraint") then
			self:trackWeld(child)
		end
	end
end

local function attachWeldChildWatcher(self: Registry, part: BasePart)
	if self.weldChildAddedByPart[part] then
		return
	end
	self.weldChildAddedByPart[part] = part.ChildAdded:Connect(function(child)
		if child:IsA("WeldConstraint") then
			self:trackWeld(child)
		end
	end)
end

local function detachWeldChildWatcher(self: Registry, part: BasePart)
	local conn = self.weldChildAddedByPart[part]
	if conn then
		conn:Disconnect()
		self.weldChildAddedByPart[part] = nil
	end
end

function VoxelRegistry.removeSupportPart(self: Registry, part: BasePart)
	self.supportHash:remove(part)

	local neighbors = self.contactNeighborsByPart[part]
	if neighbors then
		for neighbor in neighbors do
			local neighborSet = self.contactNeighborsByPart[neighbor]
			if neighborSet then
				neighborSet[part] = nil
			end
		end
	end

	self.contactNeighborsByPart[part] = nil
	self.directSupportByPart[part] = nil
	self.supportContactsValid[part] = nil
	self.externalSupportValid[part] = nil

	detachWeldChildWatcher(self, part)
	local welds = self.weldsByPart[part]
	if welds then
		local snapshot = {} :: { WeldConstraint }
		for weld in welds do
			snapshot[#snapshot + 1] = weld
		end
		for _, weld in snapshot do
			unindexWeld(self, weld)
		end
	end
	self.weldsByPart[part] = nil
end

function VoxelRegistry.getContactNeighborSet(self: Registry, part: BasePart): { [BasePart]: true }?
	return self.contactNeighborsByPart[part]
end

function VoxelRegistry.getContactNeighbors(self: Registry, part: BasePart): { BasePart }
	local set = self.contactNeighborsByPart[part]
	if not set then
		return {}
	end

	local neighbors = {} :: { BasePart }
	for neighbor in set do
		if self:isActiveVoxelPart(neighbor) then
			neighbors[#neighbors + 1] = neighbor
		end
	end
	return neighbors
end

function VoxelRegistry.hasDirectSupport(self: Registry, part: BasePart): boolean
	return self.directSupportByPart[part] == true
end

function VoxelRegistry.getWeldPeerSet(self: Registry, part: BasePart): { [BasePart]: true }?
	local welds = self.weldsByPart[part]
	if not welds then
		return nil
	end

	local result = {} :: { [BasePart]: true }
	for weld in welds do
		local other: BasePart? = nil
		if weld.Part0 == part then
			other = weld.Part1
		elseif weld.Part1 == part then
			other = weld.Part0
		end
		if other and self:isActiveVoxelPart(other) then
			result[other] = true
		end
	end
	return result
end

function VoxelRegistry.getNearbySupportParts(self: Registry, cframe: CFrame, size: Vector3, padding: number?, context: any?): { BasePart }
	local nearby = self.supportHash:queryAABB(cframe, size, padding or CONTACT_PADDING, nil)
	if context then
		context.stats.supportHashCandidates += #nearby
	end
	return nearby
end

function VoxelRegistry.rebuildSupportContacts(self: Registry, parts: { BasePart }, context: any?)
	local dirtyParts = {} :: { BasePart }
	local dirtySet: { [BasePart]: boolean } = {}

	for _, part in parts do
		if dirtySet[part] then
			continue
		end
		dirtySet[part] = true

		if self:isActiveVoxelPart(part) then
			self.supportHash:update(part)
			dirtyParts[#dirtyParts + 1] = part
		else
			self:removeSupportPart(part)
		end
	end

	for _, part in dirtyParts do
		local oldNeighbors = self.contactNeighborsByPart[part]
		if oldNeighbors then
			for neighbor in oldNeighbors do
				local neighborSet = self.contactNeighborsByPart[neighbor]
				if neighborSet then
					neighborSet[part] = nil
				end
			end
		end

		self.contactNeighborsByPart[part] = {} :: { [BasePart]: true }
		self.supportContactsValid[part] = true
		-- Only invalidate the external-support flag if its cache is stale.
		-- A part's external supports (anchored world geometry) don't change
		-- when its voxel-voxel neighbors change, so we keep the cached value.
		if not self.externalSupportValid[part] then
			self.directSupportByPart[part] = false
		end
	end

	for _, part in dirtyParts do
		local partCFrame = part.CFrame
		local partSize = part.Size
		local partAligned = ShapeTests.isAxisAligned(partCFrame)

		for _, candidate in self:getNearbySupportParts(partCFrame, partSize, CONTACT_PADDING, context) do
			if candidate == part or not self:isActiveVoxelPart(candidate) then
				continue
			end

			if context then
				context.stats.supportContactTests += 1
			end
			local candidateCFrame = candidate.CFrame
			local candidateSize = candidate.Size
			local touch
			if partAligned and ShapeTests.isAxisAligned(candidateCFrame) then
				touch = ShapeTests.partsTouchAabb(partCFrame, partSize, candidateCFrame, candidateSize, CONTACT_PADDING)
			else
				touch = ShapeTests.partsTouchSat(partCFrame, partSize, candidateCFrame, candidateSize, CONTACT_PADDING)
			end
			if touch then
				addContactEdge(self, part, candidate, context)
			end
		end

		-- Support source-of-truth: a weld whose other endpoint is an anchored
		-- non-voxel (e.g. baseplate). Walking the per-part weld index is O(weld
		-- count) and avoids the workspace query that used to live here.
		if not self.externalSupportValid[part] then
			self.directSupportByPart[part] = false
			local welds = self.weldsByPart[part]
			if welds then
				for weld in welds do
					local other: BasePart? = nil
					if weld.Part0 == part then
						other = weld.Part1
					elseif weld.Part1 == part then
						other = weld.Part0
					end
					if other and isExternalSupport(self, other) then
						if context then
							context.stats.supportContactTests += 1
						end
						self.directSupportByPart[part] = true
						break
					end
				end
			end
			self.externalSupportValid[part] = true
		end
	end
end

-- Invalidate the external-support cache for a part. Call this when the part
-- itself moves or when nearby anchored world geometry is added/removed/moved.
function VoxelRegistry.invalidateExternalSupport(self: Registry, part: BasePart)
	self.externalSupportValid[part] = nil
end

function VoxelRegistry.ensureSupportContacts(self: Registry, part: BasePart, context: any?)
	if self.supportContactsValid[part] and self.externalSupportValid[part] and self:isActiveVoxelPart(part) then
		return
	end

	self:rebuildSupportContacts({ part }, context)
end

function VoxelRegistry.registerAssembly(self: Registry, assemblyId: number, parts: { BasePart }, rootPart: BasePart?, supported: boolean): Assembly
	local assembly = self.assembliesById[assemblyId]
	if not assembly then
		assembly = {
			id = assemblyId,
			supported = supported,
			rootPart = rootPart,
			parts = {} :: { [BasePart]: true },
			welds = {} :: { [WeldConstraint]: true },
			weldByPart = {} :: { [BasePart]: WeldConstraint },
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
	if not assembly then
		return
	end

	self:trackWeld(weld)
	if assembly.welds[weld] then
		return
	end

	assembly.welds[weld] = true
	assembly.weldCount += 1

	local part1 = weld.Part1
	if part1 then
		assembly.weldByPart[part1] = weld
	end

	weld.Destroying:Once(function()
		local currentAssembly = self.assembliesById[assemblyId]
		if currentAssembly and currentAssembly.welds[weld] then
			currentAssembly.welds[weld] = nil
			currentAssembly.weldCount -= 1
			if part1 and currentAssembly.weldByPart[part1] == weld then
				currentAssembly.weldByPart[part1] = nil
			end
		end
	end)
end

-- Detach a weld from its old assembly's bookkeeping (without destroying the
-- WeldConstraint instance) so it can be re-registered to a new assembly.
function VoxelRegistry.detachWeldFromAssembly(self: Registry, assembly: Assembly, weld: WeldConstraint)
	if not assembly.welds[weld] then
		return
	end
	assembly.welds[weld] = nil
	assembly.weldCount -= 1
	local part1 = weld.Part1
	if part1 and assembly.weldByPart[part1] == weld then
		assembly.weldByPart[part1] = nil
	end
end

function VoxelRegistry.getWeldForPart(self: Registry, part: BasePart): WeldConstraint?
	local assembly = self.assemblyByPart[part]
	if not assembly then
		return nil
	end
	return assembly.weldByPart[part]
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

		-- Authored welds can be parented under the anchor or another folder.
		-- Scan Workspace too so no hidden source keeps zombie weld endpoints.
		for _, weld in self:collectWeldsTouchingPart(part) do
			if weld.Parent ~= nil then
				if context then
					context:consume("weldOps", 1)
					context.stats.weldsDestroyed += 1
				end
				weld:Destroy()
			end
		end
	end
end

function VoxelRegistry.getAssemblyParts(self: Registry, assemblyId: number): { BasePart }
	local assembly = self.assembliesById[assemblyId]
	if not assembly then
		return {}
	end

	local parts = table.create(assembly.partCount) :: { BasePart }
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

		if assembly.weldByPart[part] then
			assembly.weldByPart[part] = nil
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

	if assembly.weldByPart[part] then
		assembly.weldByPart[part] = nil
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
	local grid = VoxelGrid.create(record.part, config.voxelSize :: number, record.part:IsA("WedgePart"))
	record.grid = grid
	record.lazyGrid = false
	record.part:SetAttribute("PartBreaker2LazyGrid", false)
	if context then
		context.stats.lazyGridsCreated += 1
	end

	return grid
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
		chunks = {} :: { BasePart },
		sourceHidden = false,
	}

	self.recordsBySource[part] = record
	self.recordsByQueryPart[part] = record
	self.supportHash:insert(part)
	self.supportContactsValid[part] = false
	scanPartForWelds(self, part)
	attachWeldChildWatcher(self, part)
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
	local toRemove = table.create(8) :: { Record }
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
	self:removeSupportPart(record.part)
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
	local found = table.create(#parts) :: { Record }
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
