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

-- Prefer a part that is already the root of an existing assembly contributing
-- to this new component — keeping the root stable lets us reuse the existing
-- WeldConstraints. Tie-break by which old assembly contributes the most parts;
-- fall back to the largest-volume part if no incumbent root is available.
local function chooseRootSticky(parts: { BasePart }, registry: any): BasePart?
	local partSet: { [BasePart]: boolean } = {}
	for _, part in parts do
		partSet[part] = true
	end

	local oldRootVotes: { [BasePart]: number } = {}
	for _, part in parts do
		local oldAssembly = registry:getAssemblyByPart(part)
		if oldAssembly and oldAssembly.rootPart and partSet[oldAssembly.rootPart] then
			local rootCandidate = oldAssembly.rootPart
			oldRootVotes[rootCandidate] = (oldRootVotes[rootCandidate] or 0) + 1
		end
	end

	local best = nil :: BasePart?
	local bestScore = 0
	for rootCandidate, votes in oldRootVotes do
		if votes > bestScore then
			bestScore = votes
			best = rootCandidate
		end
	end

	if best then
		return best
	end

	return chooseRoot(parts)
end

local function planWeldForPart(registry: any, root: BasePart, part: BasePart): WeldConstraint?
	local oldAssembly = registry:getAssemblyByPart(part)
	if not oldAssembly then
		return nil
	end
	local existingWeld = oldAssembly.weldByPart[part]
	if not existingWeld or existingWeld.Parent == nil then
		return nil
	end
	if existingWeld.Part0 == root and existingWeld.Part1 == part then
		return existingWeld
	end
	return nil
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

type WeldPlan = {
	assemblyIndex: number,
	part: BasePart,
	existingToClaim: WeldConstraint?,
}

type NewAssemblyPlan = {
	component: any,
	parts: { BasePart },
	root: BasePart,
	assemblyId: number,
	supported: boolean,
}

local function assemblyWeldsLookValid(assembly: any, root: BasePart, parts: { BasePart }): boolean
	for _, part in parts do
		if part == root or not assembly.parts[part] then
			continue
		end

		local weld = assembly.weldByPart[part]
		if not weld or weld.Parent == nil or weld.Part0 ~= root or weld.Part1 ~= part then
			return false
		end
	end

	return true
end

local function appendActivePart(registry: any, parts: { BasePart }, partSet: { [BasePart]: boolean }, part: BasePart)
	if partSet[part] or not isActiveVoxelPart(registry, part) then
		return
	end

	partSet[part] = true
	parts[#parts + 1] = part
end

local function collectDirtyParts(
	registry: any,
	seedParts: { BasePart },
	queryCFrame: CFrame?,
	querySize: Vector3?,
	newParts: { BasePart }?,
	context: any?
): ({ BasePart }, { [BasePart]: boolean })
	local dirtyParts = {}
	local dirtySet: { [BasePart]: boolean } = {}
	local newPartSet: { [BasePart]: boolean } = {}

	if newParts then
		for _, part in newParts do
			newPartSet[part] = true
			appendActivePart(registry, dirtyParts, dirtySet, part)
		end
	end

	for _, seedPart in seedParts do
		appendActivePart(registry, dirtyParts, dirtySet, seedPart)
		for _, neighbor in registry:getContactNeighbors(seedPart) do
			appendActivePart(registry, dirtyParts, dirtySet, neighbor)
		end
	end

	if queryCFrame and querySize then
		for _, nearbyPart in registry:getNearbySupportParts(queryCFrame, querySize, CONTACT_PADDING, context) do
			appendActivePart(registry, dirtyParts, dirtySet, nearbyPart)
		end
	end

	return dirtyParts, newPartSet
end

local function collectGraphComponents(registry: any, seedParts: { BasePart }, newPartSet: { [BasePart]: boolean }, context: any?)
	local components = {}
	local visited: { [BasePart]: boolean } = {}

	for _, startPart in seedParts do
		if visited[startPart] or not isActiveVoxelPart(registry, startPart) then
			continue
		end

		local queue = { startPart }
		local head = 1
		local groupParts = {}
		local supportPartSet: { [BasePart]: boolean } = {}
		local supported = false
		local containsNewPart = false
		local newParts = {}
		local oldAssemblyCounts: { [any]: number } = {}
		local oldAssemblyKinds = 0
		local onlyOldAssembly = nil :: any?
		visited[startPart] = true

		while head <= #queue do
			local part = queue[head]
			head += 1
			groupParts[#groupParts + 1] = part

			if context then
				context.stats.supportComponentsVisited += 1
			end

			registry:ensureSupportContacts(part, context)

			if registry:hasDirectSupport(part) then
				supported = true
				supportPartSet[part] = true
			end

			if newPartSet[part] then
				containsNewPart = true
				newParts[#newParts + 1] = part
			else
				local assembly = registry:getAssemblyByPart(part)
				if assembly then
					if oldAssemblyCounts[assembly] == nil then
						oldAssemblyKinds += 1
						onlyOldAssembly = assembly
						oldAssemblyCounts[assembly] = 0
					end
					oldAssemblyCounts[assembly] += 1
				end
			end

			local neighbors = registry:getContactNeighborSet(part)
			if neighbors then
				for neighbor in neighbors do
					if not visited[neighbor] and isActiveVoxelPart(registry, neighbor) then
						visited[neighbor] = true
						queue[#queue + 1] = neighbor
					end
				end
			end
		end

		local oldAssembly = if oldAssemblyKinds == 1 then onlyOldAssembly else nil
		local oldAssemblyPartCount = if oldAssembly then oldAssemblyCounts[oldAssembly] or 0 else 0
		local unchangedAssembly = nil :: any?
		local augmentAssembly = nil :: any?

		if oldAssembly and oldAssembly.rootPart and oldAssembly.supported == supported then
			if #newParts == 0 and oldAssembly.partCount == #groupParts then
				if assemblyWeldsLookValid(oldAssembly, oldAssembly.rootPart, groupParts) then
					unchangedAssembly = oldAssembly
				end
			elseif #newParts > 0 and oldAssembly.partCount == oldAssemblyPartCount then
				if assemblyWeldsLookValid(oldAssembly, oldAssembly.rootPart, groupParts) then
					augmentAssembly = oldAssembly
				end
			end
		end

		components[#components + 1] = {
			parts = groupParts,
			supportPartSet = supportPartSet,
			supported = supported,
			containsNewPart = containsNewPart,
			newParts = newParts,
			unchangedAssembly = unchangedAssembly,
			augmentAssembly = augmentAssembly,
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

	local dirtyParts, newPartSet = collectDirtyParts(registry, seedParts, queryCFrame, querySize, newParts, context)
	if #dirtyParts <= 0 then
		return result
	end

	registry:rebuildSupportContacts(dirtyParts, context)
	local components = collectGraphComponents(registry, dirtyParts, newPartSet, context)
	if context then
		context.stats.supportIslandParts += #dirtyParts
	end

	-- Phase 1: lay out the new assemblies with sticky roots, plan welds.
	local newAssemblies: { NewAssemblyPlan } = {}
	local augmentAssemblies = {}
	local weldPlans: { WeldPlan } = {}
	local claimedSet: { [WeldConstraint]: boolean } = {}
	local changedParts = {}
	local changedPartSet: { [BasePart]: boolean } = {}

	local function markChanged(part: BasePart)
		if changedPartSet[part] then
			return
		end
		changedPartSet[part] = true
		changedParts[#changedParts + 1] = part
	end

	for _, component in components do
		if component.unchangedAssembly then
			continue
		end

		if component.augmentAssembly then
			augmentAssemblies[#augmentAssemblies + 1] = component
			for _, part in component.newParts do
				markChanged(part)
			end
			continue
		end

		local parts = component.parts
		if #parts <= 0 then
			continue
		end

		local root = chooseRootSticky(parts, registry)
		if not root then
			continue
		end

		local assemblyId = registry:allocateAssemblyId()
		local plan: NewAssemblyPlan = {
			component = component,
			parts = parts,
			root = root,
			assemblyId = assemblyId,
			supported = component.supported == true,
		}
		newAssemblies[#newAssemblies + 1] = plan
		local assemblyIndex = #newAssemblies

		for _, part in parts do
			markChanged(part)
			if part == root then
				continue
			end

			local existingToClaim = planWeldForPart(registry, root, part)
			if existingToClaim then
				claimedSet[existingToClaim] = true
			end

			weldPlans[#weldPlans + 1] = {
				assemblyIndex = assemblyIndex,
				part = part,
				existingToClaim = existingToClaim,
			}
		end
	end

	if #changedParts <= 0 then
		return result
	end

	-- Snapshot every old assembly touched by changed parts, so we can later
	-- destroy unclaimed welds without touching unchanged graph components.
	local affectedAssemblies: { [number]: any } = {}
	for _, part in changedParts do
		local oldAssembly = registry:getAssemblyByPart(part)
		if oldAssembly then
			affectedAssemblies[oldAssembly.id] = oldAssembly
		end
	end

	-- Phase 2: destroy welds that weren't claimed (touching changed parts).
	for _, oldAssembly in affectedAssemblies do
		local snapshot = {}
		for weld in oldAssembly.welds do
			snapshot[#snapshot + 1] = weld
		end
		for _, weld in snapshot do
			if claimedSet[weld] then
				continue
			end
			local touchesChanged = (weld.Part0 and changedPartSet[weld.Part0])
				or (weld.Part1 and changedPartSet[weld.Part1])
			if touchesChanged then
				if context then
					context:consume("weldOps", 1)
					context.stats.weldsDestroyed += 1
				end
				weld:Destroy()
			end
		end
	end

	-- Sweep any stray (untracked) WeldConstraints parented under changed parts.
	for _, part in changedParts do
		for _, child in part:GetChildren() do
			if child:IsA("WeldConstraint") and not claimedSet[child] and child.Parent ~= nil then
				if context then
					context:consume("weldOps", 1)
					context.stats.weldsDestroyed += 1
				end
				child:Destroy()
			end
		end
	end

	-- Phase 3: detach claimed welds from old bookkeeping so we can re-register.
	for weld in claimedSet do
		for _, oldAssembly in affectedAssemblies do
			if oldAssembly.welds[weld] then
				registry:detachWeldFromAssembly(oldAssembly, weld)
			end
		end
	end

	-- Phase 4: clear assembly memberships for island parts; register the new
	-- assemblies and re-attach claimed welds + create the new ones.
	registry:clearAssembliesForParts(changedParts)

	for _, component in augmentAssemblies do
		local assembly = component.augmentAssembly
		local root = assembly.rootPart
		if not root then
			continue
		end

		registry:registerAssembly(assembly.id, component.newParts, root, component.supported)
		for _, part in component.newParts do
			if part ~= root then
				if context then
					context:consume("weldOps", 1)
					context.stats.weldsCreated += 1
				end
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = root
				weld.Part1 = part
				weld.Parent = root
				registry:registerWeld(assembly.id, weld)
			end
		end
	end

	for _, plan in newAssemblies do
		registry:registerAssembly(plan.assemblyId, plan.parts, plan.root, plan.supported)
	end

	for _, weldPlan in weldPlans do
		local plan = newAssemblies[weldPlan.assemblyIndex]
		local assemblyId = plan.assemblyId
		if weldPlan.existingToClaim then
			registry:registerWeld(assemblyId, weldPlan.existingToClaim)
			if context then
				context.stats.weldsReused += 1
			end
		else
			if context then
				context:consume("weldOps", 1)
				context.stats.weldsCreated += 1
			end
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = plan.root
			weld.Part1 = weldPlan.part
			weld.Parent = plan.root
			registry:registerWeld(assemblyId, weld)
		end
	end

	-- Phase 5: per-part attributes & anchoring; collect unsupported new roots.
	for _, component in augmentAssemblies do
		local assembly = component.augmentAssembly
		supportIslandSerial += 1
		local islandId = supportIslandSerial
		for _, part in component.newParts do
			local supportReason = "Unsupported"
			if component.supported then
				supportReason = if component.supportPartSet[part] then "ExternalAnchor" else "ConnectedToSupport"
			end

			part.Anchored = component.supported
			part:SetAttribute("PartBreaker2AssemblyId", assembly.id)
			part:SetAttribute("PartBreaker2Supported", component.supported)
			part:SetAttribute("PartBreaker2SupportReason", supportReason)
			part:SetAttribute("PartBreaker2ContactIslandId", islandId)
		end

		if not component.supported and component.containsNewPart and assembly.rootPart then
			result.unsupportedNewRoots[#result.unsupportedNewRoots + 1] = assembly.rootPart
		end
	end

	for _, plan in newAssemblies do
		supportIslandSerial += 1
		local islandId = supportIslandSerial
		local supported = plan.supported
		for _, part in plan.parts do
			local supportReason = "Unsupported"
			if supported then
				supportReason = if plan.component.supportPartSet[part] then "ExternalAnchor" else "ConnectedToSupport"
			end

			part.Anchored = supported
			part:SetAttribute("PartBreaker2AssemblyId", plan.assemblyId)
			part:SetAttribute("PartBreaker2Supported", supported)
			part:SetAttribute("PartBreaker2SupportReason", supportReason)
			part:SetAttribute("PartBreaker2ContactIslandId", islandId)
		end

		if not supported and plan.component.containsNewPart then
			result.unsupportedNewRoots[#result.unsupportedNewRoots + 1] = plan.root
		end
	end

	return result
end

return SupportGraph
