--!strict
--!native

local VoxelGrid = require(script.Parent.VoxelGrid)
local Types = require(script.Parent.Types)

local GreedyMesher = {}

type Cuboid = Types.Cuboid
type Component = Types.Component
type BudgetContext = Types.BudgetContext

local DEFAULT_MAX_CUBOIDS = 512

local function componentBounds(grid: VoxelGrid.Grid, component: Component): Cuboid?
	local firstIndex = component.indices[1]
	if firstIndex == nil then
		return nil
	end

	local firstX, firstY, firstZ = VoxelGrid.indexToCoord(grid, firstIndex)
	local minX = firstX
	local minY = firstY
	local minZ = firstZ
	local maxX = firstX
	local maxY = firstY
	local maxZ = firstZ

	for indexPosition = 2, #component.indices do
		local x, y, z = VoxelGrid.indexToCoord(grid, component.indices[indexPosition])
		if x < minX then minX = x end
		if y < minY then minY = y end
		if z < minZ then minZ = z end
		if x > maxX then maxX = x end
		if y > maxY then maxY = y end
		if z > maxZ then maxZ = z end
	end

	local minPoint = VoxelGrid.voxelMin(grid, minX, minY, minZ)
	local size = Vector3.new(
		(maxX - minX + 1) * grid.cellSize.X,
		(maxY - minY + 1) * grid.cellSize.Y,
		(maxZ - minZ + 1) * grid.cellSize.Z
	)

	return {
		center = minPoint + size * 0.5,
		size = size,
	}
end

local function isAvailable(grid: VoxelGrid.Grid, index: number, meshStamp: number, mergedStamp: number): boolean
	return VoxelGrid.isMeshMarked(grid, index, meshStamp) and not VoxelGrid.isMerged(grid, index, mergedStamp)
end

local function canFillX(grid: VoxelGrid.Grid, x0: number, x1: number, y: number, z: number, meshStamp: number, mergedStamp: number): boolean
	for x = x0, x1 do
		local index = VoxelGrid.index(grid, x, y, z)
		if not isAvailable(grid, index, meshStamp, mergedStamp) then
			return false
		end
	end
	return true
end

local function canFillXY(grid: VoxelGrid.Grid, x0: number, x1: number, y0: number, y1: number, z: number, meshStamp: number, mergedStamp: number): boolean
	for y = y0, y1 do
		if not canFillX(grid, x0, x1, y, z, meshStamp, mergedStamp) then
			return false
		end
	end
	return true
end

local function markCuboidMerged(grid: VoxelGrid.Grid, x0: number, y0: number, z0: number, width: number, height: number, depth: number, mergedStamp: number)
	for z = z0, z0 + depth - 1 do
		for y = y0, y0 + height - 1 do
			for x = x0, x0 + width - 1 do
				VoxelGrid.markMerged(grid, VoxelGrid.index(grid, x, y, z), mergedStamp)
			end
		end
	end
end

function GreedyMesher.meshComponent(grid: VoxelGrid.Grid, component: Component, maxCuboids: number?, context: BudgetContext?): { Cuboid }
	local cuboidLimit = maxCuboids or DEFAULT_MAX_CUBOIDS
	local meshStamp, mergedStamp = VoxelGrid.beginMesh(grid)

	for _, index in component.indices do
		if context then
			context:consume("greedyVisits", 1)
			context.stats.greedyVisits += 1
		end
		VoxelGrid.markMesh(grid, index, meshStamp)
	end

	local cuboids = table.create(math.min(#component.indices, cuboidLimit))
	local emitted = 0
	local overflowed = false

	for z = 0, grid.sizeZ - 1 do
		for y = 0, grid.sizeY - 1 do
			for x = 0, grid.sizeX - 1 do
				if context then
					context:consume("greedyVisits", 1)
					context.stats.greedyVisits += 1
				end

				local index = VoxelGrid.index(grid, x, y, z)
				if not isAvailable(grid, index, meshStamp, mergedStamp) then
					continue
				end

				local width = 1
				while x + width < grid.sizeX do
					local nextIndex = VoxelGrid.index(grid, x + width, y, z)
					if not isAvailable(grid, nextIndex, meshStamp, mergedStamp) then
						break
					end
					if context then
						context:consume("greedyVisits", 1)
						context.stats.greedyVisits += 1
					end
					width += 1
				end

				local height = 1
				while y + height < grid.sizeY do
					if not canFillX(grid, x, x + width - 1, y + height, z, meshStamp, mergedStamp) then
						break
					end
					height += 1
				end

				local depth = 1
				while z + depth < grid.sizeZ do
					if not canFillXY(grid, x, x + width - 1, y, y + height - 1, z + depth, meshStamp, mergedStamp) then
						break
					end
					depth += 1
				end

				markCuboidMerged(grid, x, y, z, width, height, depth, mergedStamp)

				emitted += 1
				if emitted <= cuboidLimit then
					local minPoint = VoxelGrid.voxelMin(grid, x, y, z)
					local size = Vector3.new(
						width * grid.cellSize.X,
						height * grid.cellSize.Y,
						depth * grid.cellSize.Z
					)
					cuboids[emitted] = {
						center = minPoint + size * 0.5,
						size = size,
					}
					if context then
						context.stats.cuboidsEmitted += 1
					end
				else
					overflowed = true
				end
			end
		end
	end

	if overflowed then
		local fallback = componentBounds(grid, component)
		if fallback then
			if context then
				context.stats.cuboidsEmitted += 1
			end
			return { fallback }
		end
	end

	return cuboids
end

return GreedyMesher
