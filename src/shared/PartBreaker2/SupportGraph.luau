--!strict
--!native

local Workspace = game:GetService("Workspace")

local SupportGraph = {}

local CONTACT_PADDING = 0.015

local supportIslandSerial = 0

export type RefreshResult = {
	unsupportedNewRoots: { BasePart },
}

local function abs(value: number): number
	return if value < 0 then -value else value
end

local function partVolume(part: BasePart): number
	local size = part.Size
	return size.X * size.Y * size.Z
end

local function obbTouches(cframeA: CFrame, sizeA: Vector3, cframeB: CFrame, sizeB: Vector3, padding: number): boolean
	local aHalf = sizeA * 0.5 + Vector3.new(padding, padding, padding)
	local bHalf = sizeB * 0.5 + Vector3.new(padding, padding, padding)
	local aAxes = {
		cframeA.RightVector,
		cframeA.UpVector,
		cframeA.LookVector,
	}
	local bAxes = {
		cframeB.RightVector,
		cframeB.UpVector,
		cframeB.LookVector,
	}
	local centerDelta = cframeB.Position - cframeA.Position
	local epsilon = 1e-6

	for _, axis in aAxes do
		local distance = abs(centerDelta:Dot(axis))
		local radiusA = if axis == aAxes[1] then aHalf.X elseif axis == aAxes[2] then aHalf.Y else aHalf.Z
		local radiusB = bHalf.X * abs(axis:Dot(bAxes[1]))
			+ bHalf.Y * abs(axis:Dot(bAxes[2]))
			+ bHalf.Z * abs(axis:Dot(bAxes[3]))
		if distance > radiusA + radiusB + epsilon then
			return false
		end
	end

	for _, axis in bAxes do
		local distance = abs(centerDelta:Dot(axis))
		local radiusA = aHalf.X * abs(axis:Dot(aAxes[1]))
			+ aHalf.Y * abs(axis:Dot(aAxes[2]))
			+ aHalf.Z * abs(axis:Dot(aAxes[3]))
		local radiusB = if axis == bAxes[1] then bHalf.X elseif axis == bAxes[2] then bHalf.Y else bHalf.Z
		if distance > radiusA + radiusB + epsilon then
			return false
		end
	end

	for _, axisA in aAxes do
		for _, axisB in bAxes do
			local axis = axisA:Cross(axisB)
			if axis:Dot(axis) <= epsilon then
				continue
			end

			local distance = abs(centerDelta:Dot(axis))
			local radiusA = aHalf.X * abs(axis:Dot(aAxes[1]))
				+ aHalf.Y * abs(axis:Dot(aAxes[2]))
				+ aHalf.Z * abs(axis:Dot(aAxes[3]))
			local radiusB = bHalf.X * abs(axis:Dot(bAxes[1]))
				+ bHalf.Y * abs(axis:Dot(bAxes[2]))
				+ bHalf.Z * abs(axis:Dot(bAxes[3]))
			if distance > radiusA + radiusB + epsilon then
				return false
			end
		end
	end

	return true
end

local function expandedSize(part: BasePart): Vector3
	return part.Size + Vector3.new(CONTACT_PADDING * 2, CONTACT_PADDING * 2, CONTACT_PADDING * 2)
end

local function isActiveVoxelPart(registry: any, part: BasePart): boolean
	return registry:isActiveVoxelPart(part)
end

local function isExplicitSupportAnchor(part: BasePart): boolean
	return part:GetAttribute("PartBreaker2SupportAnchor") == true
end

local function isExternalSupport(registry: any, part: BasePart): boolean
	if part.Parent == nil then
		return false
	end

	if isExplicitSupportAnchor(part) then
		return true
	end

	if isActiveVoxelPart(registry, part) or part:GetAttribute("VoxelPart") == true then
		return false
	end

	return part.Anchored
end

local function addUniquePart(parts: { BasePart }, partSet: { [BasePart]: boolean }, part: BasePart)
	if partSet[part] then
		return
	end

	partSet[part] = true
	parts[#parts + 1] = part
end

local function addEdge(edges: { { number } }, a: number, b: number)
	if a == b then
		return
	end

	edges[a][#edges[a] + 1] = b
	edges[b][#edges[b] + 1] = a
end

local function collectIslandParts(
	registry: any,
	seedParts: { BasePart },
	queryCFrame: CFrame?,
	querySize: Vector3?,
	context: any?
): { BasePart }
	local overlapParams = OverlapParams.new()
	overlapParams.MaxParts = 0
	overlapParams.RespectCanCollide = false

	local islandParts = {}
	local islandSet: { [BasePart]: boolean } = {}
	local queue = {}
	local queued: { [BasePart]: boolean } = {}
	local head = 1

	local function enqueue(part: BasePart)
		if queued[part] or not isActiveVoxelPart(registry, part) then
			return
		end

		queued[part] = true
		queue[#queue + 1] = part
		addUniquePart(islandParts, islandSet, part)
	end

	for _, seedPart in seedParts do
		enqueue(seedPart)
	end

	if queryCFrame and querySize then
		if context then
			context:consume("supportQueries", 1)
			context.stats.supportQueries += 1
		end
		for _, nearbyPart in Workspace:GetPartBoundsInBox(queryCFrame, querySize, overlapParams) do
			if nearbyPart:IsA("BasePart") then
				enqueue(nearbyPart)
			end
		end
	end

	while head <= #queue do
		local part = queue[head]
		head += 1

		local assembly = registry:getAssemblyByPart(part)
		if assembly then
			for assemblyPart in assembly.parts do
				enqueue(assemblyPart)
			end
		end

		if context then
			context:consume("supportQueries", 1)
			context.stats.supportQueries += 1
		end
		for _, nearbyPart in Workspace:GetPartBoundsInBox(part.CFrame, expandedSize(part), overlapParams) do
			if not nearbyPart:IsA("BasePart") or nearbyPart == part or not isActiveVoxelPart(registry, nearbyPart) then
				continue
			end

			if obbTouches(part.CFrame, part.Size, nearbyPart.CFrame, nearbyPart.Size, CONTACT_PADDING) then
				enqueue(nearbyPart)
			end
		end
	end

	return islandParts
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

	return root
end

local function weldToRoot(registry: any, assemblyId: number, root: BasePart, parts: { BasePart }, context: any?)
	for _, part in parts do
		if part == root then
			continue
		end

		if context then
			context:consume("weldOps", 1)
			context.stats.weldsCreated += 1
		end
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = part
		weld.Parent = root
		registry:registerWeld(assemblyId, weld)
	end
end

local function buildContactGraph(registry: any, islandParts: { BasePart }, context: any?): ({ { number } }, { [number]: boolean })
	local overlapParams = OverlapParams.new()
	overlapParams.MaxParts = 0
	overlapParams.RespectCanCollide = false

	local indexByPart: { [BasePart]: number } = {}
	local edges = table.create(#islandParts)
	local directSupport: { [number]: boolean } = {}

	for index, part in islandParts do
		indexByPart[part] = index
		edges[index] = {}
	end

	for index, part in islandParts do
		if isExplicitSupportAnchor(part) then
			directSupport[index] = true
		end

		if context then
			context:consume("supportQueries", 1)
			context.stats.supportQueries += 1
		end
		for _, nearbyPart in Workspace:GetPartBoundsInBox(part.CFrame, expandedSize(part), overlapParams) do
			if not nearbyPart:IsA("BasePart") or nearbyPart == part then
				continue
			end

			if isActiveVoxelPart(registry, nearbyPart) then
				local neighborIndex = indexByPart[nearbyPart]
				if neighborIndex and neighborIndex > index and obbTouches(part.CFrame, part.Size, nearbyPart.CFrame, nearbyPart.Size, CONTACT_PADDING) then
					addEdge(edges, index, neighborIndex)
				end
			elseif isExternalSupport(registry, nearbyPart) and obbTouches(part.CFrame, part.Size, nearbyPart.CFrame, nearbyPart.Size, CONTACT_PADDING) then
				directSupport[index] = true
			end
		end
	end

	return edges, directSupport
end

local function collectContactComponents(
	islandParts: { BasePart },
	edges: { { number } },
	directSupport: { [number]: boolean },
	newPartSet: { [BasePart]: boolean }
)
	local components = {}
	local visited: { [number]: boolean } = {}

	for startIndex = 1, #islandParts do
		if visited[startIndex] then
			continue
		end

		local queue = { startIndex }
		local head = 1
		local groupParts = {}
		local supportPartSet: { [BasePart]: boolean } = {}
		local supported = false
		local containsNewPart = false
		visited[startIndex] = true

		while head <= #queue do
			local index = queue[head]
			head += 1

			local part = islandParts[index]
			groupParts[#groupParts + 1] = part

			if directSupport[index] then
				supported = true
				supportPartSet[part] = true
			end

			if newPartSet[part] then
				containsNewPart = true
			end

			for _, neighborIndex in edges[index] do
				if not visited[neighborIndex] then
					visited[neighborIndex] = true
					queue[#queue + 1] = neighborIndex
				end
			end
		end

		components[#components + 1] = {
			parts = groupParts,
			supportPartSet = supportPartSet,
			supported = supported,
			containsNewPart = containsNewPart,
		}
	end

	return components
end

function SupportGraph.refreshAroundDamage(
	registry: any,
	seedParts: { BasePart },
	queryCFrame: CFrame?,
	querySize: Vector3?,
	newParts: { BasePart }?,
	context: any?
): RefreshResult
	local result: RefreshResult = {
		unsupportedNewRoots = {},
	}

	local islandParts = collectIslandParts(registry, seedParts, queryCFrame, querySize, context)
	if #islandParts <= 0 then
		return result
	end
	if context then
		context.stats.supportIslandParts += #islandParts
	end

	local newPartSet: { [BasePart]: boolean } = {}
	if newParts then
		for _, part in newParts do
			newPartSet[part] = true
		end
	end

	local edges, directSupport = buildContactGraph(registry, islandParts, context)
	local components = collectContactComponents(islandParts, edges, directSupport, newPartSet)

	registry:destroyWeldsTouchingParts(islandParts, context)
	registry:clearAssembliesForParts(islandParts)

	for _, component in components do
		local parts = component.parts
		local root = chooseRoot(parts)
		if not root then
			continue
		end

		supportIslandSerial += 1
		local islandId = supportIslandSerial
		local assemblyId = registry:allocateAssemblyId()
		local supported = component.supported == true

		registry:registerAssembly(assemblyId, parts, root, supported)
		weldToRoot(registry, assemblyId, root, parts, context)

		for _, part in parts do
			local supportReason = "Unsupported"
			if supported then
				supportReason = if component.supportPartSet[part] then "ExternalAnchor" else "ConnectedToSupport"
			end

			part.Anchored = supported
			part:SetAttribute("PartBreaker2AssemblyId", assemblyId)
			part:SetAttribute("PartBreaker2Supported", supported)
			part:SetAttribute("PartBreaker2SupportReason", supportReason)
			part:SetAttribute("PartBreaker2ContactIslandId", islandId)
		end

		if not supported and component.containsNewPart then
			result.unsupportedNewRoots[#result.unsupportedNewRoots + 1] = root
		end
	end

	return result
end

return SupportGraph
