--!strict
--!native

local VoxelGrid = require(script.Parent.VoxelGrid)
local ShapeTests = require(script.Parent.ShapeTests)
local Types = require(script.Parent.Types)

local DamageSolver = {}

type RemovedVoxel = Types.RemovedVoxel
type BudgetContext = Types.BudgetContext

export type DamageResult = {
	removed: { RemovedVoxel },
}

local function appendRemoved(removed: { RemovedVoxel }, index: number)
	local count = #removed + 1
	removed[count] = {
		index = index,
	}
end

function DamageSolver.applySphere(record: any, position: Vector3, radius: number, strength: number, context: BudgetContext?): DamageResult
	local grid: VoxelGrid.Grid = record.grid
	local removed = table.create(64)
	if strength < record.requiredStrength or grid.solidCount <= 0 then
		return { removed = removed }
	end

	local localCenter = record.part.CFrame:PointToObjectSpace(position)
	local minX, minY, minZ, maxX, maxY, maxZ = ShapeTests.sphereRange(grid, localCenter, radius)
	local radiusSquared = radius * radius

	for z = minZ, maxZ do
		for y = minY, maxY do
			for x = minX, maxX do
				if context then
					context:consume("voxelTests", 1)
					context.stats.voxelTests += 1
				end

				local index = VoxelGrid.index(grid, x, y, z)
				if not VoxelGrid.isSolidIndex(grid, index) then
					continue
				end

				if ShapeTests.sphereIntersectsVoxel(grid, localCenter, radiusSquared, x, y, z) and VoxelGrid.markDestroyed(grid, index) then
					appendRemoved(removed, index)
					if context then
						context.stats.voxelsRemoved += 1
					end
				end
			end
		end
	end

	return { removed = removed }
end

function DamageSolver.applyOBB(record: any, cframe: CFrame, size: Vector3, strength: number, context: BudgetContext?): DamageResult
	local grid: VoxelGrid.Grid = record.grid
	local removed = table.create(64)
	if strength < record.requiredStrength or grid.solidCount <= 0 then
		return { removed = removed }
	end

	local localOBB = record.part.CFrame:ToObjectSpace(cframe)
	local minX, minY, minZ, maxX, maxY, maxZ = ShapeTests.obbRange(grid, localOBB, size)

	for z = minZ, maxZ do
		for y = minY, maxY do
			for x = minX, maxX do
				if context then
					context:consume("voxelTests", 1)
					context.stats.voxelTests += 1
				end

				local index = VoxelGrid.index(grid, x, y, z)
				if not VoxelGrid.isSolidIndex(grid, index) then
					continue
				end

				if ShapeTests.obbIntersectsVoxel(grid, localOBB, size, x, y, z) and VoxelGrid.markDestroyed(grid, index) then
					appendRemoved(removed, index)
					if context then
						context.stats.voxelsRemoved += 1
					end
				end
			end
		end
	end

	return { removed = removed }
end

return DamageSolver
