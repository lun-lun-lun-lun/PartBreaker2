--!strict
--!native

local VoxelGrid = require(script.Parent.VoxelGrid)
local Types = require(script.Parent.Types)

local Connectivity = {}

type Component = Types.Component
type BudgetContext = Types.BudgetContext

local NEIGHBOR_OFFSETS = {
	{ 1, 0, 0 },
	{ -1, 0, 0 },
	{ 0, 1, 0 },
	{ 0, -1, 0 },
	{ 0, 0, 1 },
	{ 0, 0, -1 },
}

function Connectivity.extractComponents(grid: VoxelGrid.Grid, context: BudgetContext?): { Component }
	local components = table.create(8) :: { Component }
	if grid.solidCount <= 0 then
		return components
	end

	local stamp = VoxelGrid.beginVisit(grid)
	local queue = table.create(1024) :: { number }

	for startIndex = 0, grid.total - 1 do
		if context then
			context:consume("connectivityVisits", 1)
			context.stats.connectivityVisits += 1
		end

		if not VoxelGrid.isSolidIndex(grid, startIndex) or VoxelGrid.isVisited(grid, startIndex, stamp) then
			continue
		end

		local indices = table.create(256) :: { number }
		local head = 1
		local tail = 1
		queue[1] = startIndex
		VoxelGrid.markVisited(grid, startIndex, stamp)

		while head <= tail do
			local index = queue[head]
			queue[head] = nil :: any
			head += 1
			if context then
				context:consume("connectivityVisits", 1)
				context.stats.connectivityVisits += 1
			end

			local count = #indices + 1
			indices[count] = index

			local x, y, z = VoxelGrid.indexToCoord(grid, index)

			for _, offset in NEIGHBOR_OFFSETS do
				local nx = x + offset[1]
				local ny = y + offset[2]
				local nz = z + offset[3]
				if not VoxelGrid.inBounds(grid, nx, ny, nz) then
					continue
				end

				local neighborIndex = VoxelGrid.index(grid, nx, ny, nz)
				if VoxelGrid.isSolidIndex(grid, neighborIndex) and not VoxelGrid.isVisited(grid, neighborIndex, stamp) then
					VoxelGrid.markVisited(grid, neighborIndex, stamp)
					tail += 1
					queue[tail] = neighborIndex
				end
			end
		end

		local componentCount = #components + 1
		components[componentCount] = {
			id = componentCount,
			indices = indices,
			supported = false,
		}
		if context then
			context.stats.componentsExtracted += 1
		end
	end

	return components
end

return Connectivity
