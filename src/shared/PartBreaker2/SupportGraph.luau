--!strict
--!native

local ShapeTests = require(script.Parent.ShapeTests)

local SupportGraph = {}

local CONTACT_PADDING = 0.015

local supportIslandSerial = 0

export type RefreshResult = {
	unsupportedRoots: { BasePart },
}

type GraphComponent = {
	parts: { BasePart },
	supportPartSet: { [BasePart]: boolean },
	supported: boolean,
	containsNewPart: boolean,
	newParts: { BasePart },
	unchangedAssembly: any?,
	augmentAssembly: any?,
}

local function partVolume(part: BasePart): number
	local size = part.Size
	return size.X * size.Y * size.Z
end

local function isActiveVoxelPart(registry: any, part: BasePart): boolean
	return registry:isActiveVoxelPart(part)
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
		local rootCandidate: BasePart? = if oldAssembly then oldAssembly.rootPart else nil
		if rootCandidate and partSet[rootCandidate] then
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
	local dirtyParts = {} :: { BasePart }
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
		local weldPeers = registry:getWeldPeerSet(seedPart)
		if weldPeers then
			for peer in weldPeers do
				appendActivePart(registry, dirtyParts, dirtySet, peer)
			end
		end
	end

	if queryCFrame and querySize then
		for _, nearbyPart in registry:getNearbySupportParts(queryCFrame, querySize, CONTACT_PADDING, context) do
			appendActivePart(registry, dirtyParts, dirtySet, nearbyPart)
		end
	end

	return dirtyParts, newPartSet
end

local function collectGraphComponents(registry: any, seedParts: { BasePart }, newPartSet: { [BasePart]: boolean }, context: any?): { GraphComponent }
	local components = {} :: { GraphComponent }
	local visited: { [BasePart]: boolean } = {}

	for _, startPart in seedParts do
		if visited[startPart] or not isActiveVoxelPart(registry, startPart) then
			continue
		end

		local queue = { startPart } :: { BasePart }
		local head = 1
		local groupParts = {} :: { BasePart }
		local supportPartSet: { [BasePart]: boolean } = {}
		local supported = false
		local containsNewPart = false
		local newParts = {} :: { BasePart }
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

			local weldPeers = registry:getWeldPeerSet(part)
			if weldPeers then
				for peer in weldPeers do
					if not visited[peer] and isActiveVoxelPart(registry, peer) then
						visited[peer] = true
						queue[#queue + 1] = peer
					end
				end
			end
		end

		local oldAssembly = if oldAssemblyKinds == 1 then onlyOldAssembly else nil
		local oldAssemblyPartCount = if oldAssembly then oldAssemblyCounts[oldAssembly] or 0 else 0
		local unchangedAssembly = nil :: any?
		local augmentAssembly = nil :: any?

		local oldAssemblyRoot: BasePart? = if oldAssembly then oldAssembly.rootPart else nil
		if oldAssembly and oldAssemblyRoot and oldAssembly.supported == supported then
			if #newParts == 0 and oldAssembly.partCount == #groupParts then
				if assemblyWeldsLookValid(oldAssembly, oldAssemblyRoot, groupParts) then
					unchangedAssembly = oldAssembly
				end
			elseif #newParts > 0 and oldAssembly.partCount == oldAssemblyPartCount then
				if assemblyWeldsLookValid(oldAssembly, oldAssemblyRoot, groupParts) then
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
		unsupportedRoots = {},
	}
	local unsupportedRootSet: { [BasePart]: boolean } = {}

	local function addUnsupportedRoot(root: BasePart?)
		if not root or unsupportedRootSet[root] then
			return
		end
		unsupportedRootSet[root] = true
		result.unsupportedRoots[#result.unsupportedRoots + 1] = root
	end

	local dirtyParts, newPartSet = collectDirtyParts(registry, seedParts, queryCFrame, querySize, newParts, context)
	if #dirtyParts <= 0 then
		return result
	end

	-- Restrict the contact-rebuild set to parts physically near the damage
	-- region: only those could have had a neighbor added (a new chunk) or
	-- removed (the source). Transitively-affected parts further out keep
	-- their cached contacts and are reused via ensureSupportContacts during
	-- the graph traversal below.
	local rebuildParts = dirtyParts
	if queryCFrame and querySize then
		rebuildParts = table.create(#dirtyParts) :: { BasePart }
		for _, part in dirtyParts do
			if newPartSet[part] or ShapeTests.partsTouch(part.CFrame, part.Size, queryCFrame, querySize, 0) then
				rebuildParts[#rebuildParts + 1] = part
			end
		end
	end

	registry:rebuildSupportContacts(rebuildParts, context)
	local components = collectGraphComponents(registry, dirtyParts, newPartSet, context)
	if context then
		context.stats.supportIslandParts += #dirtyParts
	end

	-- Phase 1: lay out the new assemblies with sticky roots, plan welds.
	local newAssemblies: { NewAssemblyPlan } = {}
	local augmentAssemblies = {} :: { GraphComponent }
	local weldPlans: { WeldPlan } = {}
	local claimedSet: { [WeldConstraint]: boolean } = {}
	local changedParts = {} :: { BasePart }
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
		local snapshot = {} :: { WeldConstraint }
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

	-- Sweep stray library-authored WeldConstraints parented under changed parts.
	-- User-authored welds (no `_PartBreaker2Weld` attribute) are intentional and
	-- must survive damage so support can walk through them.
	for _, part in changedParts do
		for _, child in part:GetChildren() do
			if
				child:IsA("WeldConstraint")
				and not claimedSet[child]
				and child.Parent ~= nil
				and child:GetAttribute("_PartBreaker2Weld") == true
			then
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
				weld:SetAttribute("_PartBreaker2Weld", true)
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
			weld:SetAttribute("_PartBreaker2Weld", true)
			weld.Parent = plan.root
			registry:registerWeld(assemblyId, weld)
		end
	end

	-- Phase 5: per-part attributes & anchoring; collect unsupported roots.
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

		local augmentRoot: BasePart? = assembly.rootPart
		if not component.supported then
			addUnsupportedRoot(augmentRoot)
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

		if not supported then
			addUnsupportedRoot(plan.root)
		end
	end

	return result
end

return SupportGraph
