--!strict
--!native

local Workspace = game:GetService("Workspace")

local Types = require(script.Parent.Types)

local ChunkBuilder = {}
ChunkBuilder.__index = ChunkBuilder

type Component = Types.Component
type Cuboid = Types.Cuboid
type BuiltAssembly = Types.BuiltAssembly
type BudgetContext = Types.BudgetContext

export type Builder = typeof(setmetatable(
	{} :: {
		runtimeFolder: Folder,
		chunkFolder: Folder,
		poolFolder: Folder,
		freeParts: { BasePart },
		pendingMoveParts: { BasePart },
		pendingMoveCFrames: { CFrame },
		graveyardIndex: number,
	},
	ChunkBuilder
))

local FAR_AWAY_BASE = Vector3.new(2^20, 2^20, 2^20)

local function getOrCreateFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function removeWeldsTouching(part: BasePart)
	for _, child in part:GetChildren() do
		if child:IsA("WeldConstraint") then
			child:Destroy()
		end
	end
end

function ChunkBuilder.new(runtimeFolder: Folder): Builder
	return setmetatable({
		runtimeFolder = runtimeFolder,
		chunkFolder = getOrCreateFolder(runtimeFolder, "Chunks"),
		poolFolder = getOrCreateFolder(runtimeFolder, "ChunkPool"),
		freeParts = {},
		pendingMoveParts = {},
		pendingMoveCFrames = {},
		graveyardIndex = 0,
	}, ChunkBuilder) :: Builder
end

function ChunkBuilder.flushBulkMoves(self: Builder)
	if #self.pendingMoveParts <= 0 then
		return
	end

	Workspace:BulkMoveTo(self.pendingMoveParts, self.pendingMoveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	table.clear(self.pendingMoveParts)
	table.clear(self.pendingMoveCFrames)
end

local function queueMove(self: Builder, part: BasePart, cframe: CFrame)
	self.pendingMoveParts[#self.pendingMoveParts + 1] = part
	self.pendingMoveCFrames[#self.pendingMoveCFrames + 1] = cframe
end

function ChunkBuilder.getPart(self: Builder): BasePart
	local part = table.remove(self.freeParts)
	if part then
		return part
	end

	local newPart = Instance.new("Part")
	newPart.Name = "VoxelChunk"
	newPart.TopSurface = Enum.SurfaceType.Smooth
	newPart.BottomSurface = Enum.SurfaceType.Smooth
	newPart:SetAttribute("_PartBreaker2GeneratedChunk", true)
	return newPart
end

function ChunkBuilder.retirePart(self: Builder, part: BasePart, context: BudgetContext?)
	removeWeldsTouching(part)
	if context then
		context.stats.partsRetired += 1
	end

	self.graveyardIndex += 1
	local offset = self.graveyardIndex * 64
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part:SetAttribute("VoxelPart", false)
	part:SetAttribute("PartBreaker2AssemblyId", nil)
	part:SetAttribute("PartBreaker2ComponentId", nil)
	part:SetAttribute("PartBreaker2GreedyGroupId", nil)
	part:SetAttribute("PartBreaker2Supported", nil)
	part:SetAttribute("PartBreaker2SupportReason", nil)
	part:SetAttribute("PartBreaker2ContactIslandId", nil)
	part:SetAttribute("PartBreaker2LazyGrid", nil)
	part.Parent = self.poolFolder
	queueMove(self, part, CFrame.new(FAR_AWAY_BASE + Vector3.new(offset, 0, 0)))
	table.insert(self.freeParts, part)
end

function ChunkBuilder.hideSourcePart(part: BasePart, context: BudgetContext?)
	removeWeldsTouching(part)
	if context then
		context.stats.partsRetired += 1
	end
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part:SetAttribute("VoxelPart", false)
	part:SetAttribute("PartBreaker2AssemblyId", nil)
	part:SetAttribute("PartBreaker2ComponentId", nil)
	part:SetAttribute("PartBreaker2GreedyGroupId", nil)
	part:SetAttribute("PartBreaker2Supported", nil)
	part:SetAttribute("PartBreaker2SupportReason", nil)
	part:SetAttribute("PartBreaker2ContactIslandId", nil)
	part:SetAttribute("PartBreaker2LazyGrid", nil)
end

local function configureChunkFromRecord(part: BasePart, sourceRecord: any, cuboid: Cuboid, component: Component, lazyGeneratedGrid: boolean)
	local supported = component.supported
	local assemblyId = component.assemblyId or 0
	local componentId = component.id or 0
	local grid = sourceRecord.grid

	part.Name = "VoxelChunk"
	part.Size = cuboid.size
	part.CFrame = sourceRecord.part.CFrame * CFrame.new(cuboid.center)
	part.Color = sourceRecord.color
	part.Material = sourceRecord.material
	part.Transparency = sourceRecord.transparency
	part.CollisionGroup = sourceRecord.collisionGroup
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = true
	part.CanTouch = true
	part.Massless = false
	part.CustomPhysicalProperties = sourceRecord.part.CustomPhysicalProperties
	part:SetAttribute("VoxelPart", true)
	part:SetAttribute("VoxelSize", grid.voxelSize)
	part:SetAttribute("RequiredStrength", sourceRecord.requiredStrength)
	part:SetAttribute("DebrisLifetime", sourceRecord.debrisLifetime)
	part:SetAttribute("DebrisImpulseMultiplier", sourceRecord.debrisImpulseMultiplier)
	part:SetAttribute("MaxDebrisVoxels", sourceRecord.maxDebrisVoxels)
	part:SetAttribute("MaxCuboids", sourceRecord.maxCuboids)
	part:SetAttribute("PartBreaker2LazyGrid", lazyGeneratedGrid)
	part:SetAttribute("VoxelSupport", "Graph")
	part:SetAttribute("PartBreaker2AssemblyId", assemblyId)
	part:SetAttribute("PartBreaker2ComponentId", componentId)
	part:SetAttribute("PartBreaker2GreedyGroupId", assemblyId)
	part:SetAttribute("PartBreaker2Supported", supported)
	part:SetAttribute("PartBreaker2SupportReason", "Pending")
	part:SetAttribute("PartBreaker2ContactIslandId", nil)
end

local function partVolume(part: BasePart): number
	local size = part.Size
	return size.X * size.Y * size.Z
end

local function chooseRoot(parts: { BasePart }): BasePart?
	local root = nil :: BasePart?
	local largestVolume = -math.huge
	for _, part in parts do
		local volume = partVolume(part)
		if volume > largestVolume then
			largestVolume = volume
			root = part
		end
	end

	if not root then
		return nil
	end

	return root
end

function ChunkBuilder.buildChunks(self: Builder, sourceRecord: any, components: { Component }, context: BudgetContext?, lazyGeneratedGrid: boolean): { BuiltAssembly }
	local builtAssemblies = table.create(#components) :: { BuiltAssembly }

	for componentIndex, component in components do
		local cuboids = component.cuboids
		if cuboids == nil then
			continue
		end

		local componentParts = table.create(#cuboids) :: { BasePart }
		for _, cuboid in cuboids do
			if context then
				context:consume("partsCommitted", 1)
			end

			local reused = #self.freeParts > 0
			local part = self:getPart()
			if context then
				if reused then
					context.stats.partsReused += 1
				else
					context.stats.partsCreated += 1
				end
			end
			configureChunkFromRecord(part, sourceRecord, cuboid, component, lazyGeneratedGrid)
			part.Parent = self.chunkFolder
			componentParts[#componentParts + 1] = part
		end

		local root = chooseRoot(componentParts)

		for _, part in componentParts do
			part:SetAttribute("VoxelComponent", componentIndex)
		end

		builtAssemblies[#builtAssemblies + 1] = {
			assemblyId = component.assemblyId or 0,
			parts = componentParts,
			rootPart = root,
			supported = component.supported,
		}
	end

	return builtAssemblies
end

function ChunkBuilder.ensureRuntimeFolder(): Folder
	local existing = Workspace:FindFirstChild("PartBreaker2Runtime")
	if existing and existing:IsA("Folder") then
		return existing
	end

	local folder = Instance.new("Folder")
	folder.Name = "PartBreaker2Runtime"
	folder.Parent = Workspace
	return folder
end

return ChunkBuilder
