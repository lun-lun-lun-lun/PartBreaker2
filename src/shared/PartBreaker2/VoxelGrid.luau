--!strict
--!native

local VoxelGrid = {}

export type Grid = {
	sizeX: number,
	sizeY: number,
	sizeZ: number,
	total: number,
	voxelSize: number,
	cellSize: Vector3,
	halfSize: Vector3,
	solid: buffer,
	shapeMask: buffer,
	visitedGeneration: buffer,
	meshGeneration: buffer,
	mergedGeneration: buffer,
	visitStamp: number,
	meshStamp: number,
	mergedStamp: number,
	solidCount: number,
	isWedge: boolean,
}

local MAX_U16_STAMP = 65535

local function clampInteger(value: number, minValue: number, maxValue: number): number
	if value < minValue then
		return minValue
	end
	if value > maxValue then
		return maxValue
	end
	return value
end

local function nextStamp(grid: Grid, field: "visitStamp" | "meshStamp" | "mergedStamp", stampBuffer: buffer): number
	local stamp = grid[field] + 1
	if stamp > MAX_U16_STAMP then
		buffer.fill(stampBuffer, 0, 0)
		stamp = 1
	end
	grid[field] = stamp
	return stamp
end

function VoxelGrid.index(grid: Grid, x: number, y: number, z: number): number
	return x + y * grid.sizeX + z * grid.sizeX * grid.sizeY
end

function VoxelGrid.indexToCoord(grid: Grid, index: number): (number, number, number)
	local xy = grid.sizeX * grid.sizeY
	local z = math.floor(index / xy)
	local rest = index - z * xy
	local y = math.floor(rest / grid.sizeX)
	local x = rest - y * grid.sizeX
	return x, y, z
end

function VoxelGrid.inBounds(grid: Grid, x: number, y: number, z: number): boolean
	return x >= 0 and x < grid.sizeX and y >= 0 and y < grid.sizeY and z >= 0 and z < grid.sizeZ
end

function VoxelGrid.isShape(grid: Grid, index: number): boolean
	return buffer.readu8(grid.shapeMask, index) ~= 0
end

function VoxelGrid.isSolidIndex(grid: Grid, index: number): boolean
	return buffer.readu8(grid.solid, index) ~= 0
end

function VoxelGrid.isSolid(grid: Grid, x: number, y: number, z: number): boolean
	if not VoxelGrid.inBounds(grid, x, y, z) then
		return false
	end
	return VoxelGrid.isSolidIndex(grid, VoxelGrid.index(grid, x, y, z))
end

function VoxelGrid.markDestroyed(grid: Grid, index: number): boolean
	if buffer.readu8(grid.solid, index) == 0 then
		return false
	end
	buffer.writeu8(grid.solid, index, 0)
	grid.solidCount -= 1
	return true
end

function VoxelGrid.beginVisit(grid: Grid): number
	return nextStamp(grid, "visitStamp", grid.visitedGeneration)
end

function VoxelGrid.isVisited(grid: Grid, index: number, stamp: number): boolean
	return buffer.readu16(grid.visitedGeneration, index * 2) == stamp
end

function VoxelGrid.markVisited(grid: Grid, index: number, stamp: number)
	buffer.writeu16(grid.visitedGeneration, index * 2, stamp)
end

function VoxelGrid.beginMesh(grid: Grid): (number, number)
	local meshStamp = nextStamp(grid, "meshStamp", grid.meshGeneration)
	local mergedStamp = nextStamp(grid, "mergedStamp", grid.mergedGeneration)
	return meshStamp, mergedStamp
end

function VoxelGrid.isMeshMarked(grid: Grid, index: number, stamp: number): boolean
	return buffer.readu16(grid.meshGeneration, index * 2) == stamp
end

function VoxelGrid.markMesh(grid: Grid, index: number, stamp: number)
	buffer.writeu16(grid.meshGeneration, index * 2, stamp)
end

function VoxelGrid.isMerged(grid: Grid, index: number, stamp: number): boolean
	return buffer.readu16(grid.mergedGeneration, index * 2) == stamp
end

function VoxelGrid.markMerged(grid: Grid, index: number, stamp: number)
	buffer.writeu16(grid.mergedGeneration, index * 2, stamp)
end

function VoxelGrid.voxelMin(grid: Grid, x: number, y: number, z: number): Vector3
	local cell = grid.cellSize
	local half = grid.halfSize
	return Vector3.new(
		-half.X + x * cell.X,
		-half.Y + y * cell.Y,
		-half.Z + z * cell.Z
	)
end

function VoxelGrid.voxelMax(grid: Grid, x: number, y: number, z: number): Vector3
	return VoxelGrid.voxelMin(grid, x, y, z) + grid.cellSize
end

function VoxelGrid.voxelCenter(grid: Grid, x: number, y: number, z: number): Vector3
	return VoxelGrid.voxelMin(grid, x, y, z) + grid.cellSize * 0.5
end

function VoxelGrid.indexCenter(grid: Grid, index: number): Vector3
	local x, y, z = VoxelGrid.indexToCoord(grid, index)
	return VoxelGrid.voxelCenter(grid, x, y, z)
end

function VoxelGrid.localAabbToVoxelRange(grid: Grid, minPoint: Vector3, maxPoint: Vector3): (number, number, number, number, number, number)
	local half = grid.halfSize
	local cell = grid.cellSize

	local minX = clampInteger(math.floor((minPoint.X + half.X) / cell.X), 0, grid.sizeX - 1)
	local minY = clampInteger(math.floor((minPoint.Y + half.Y) / cell.Y), 0, grid.sizeY - 1)
	local minZ = clampInteger(math.floor((minPoint.Z + half.Z) / cell.Z), 0, grid.sizeZ - 1)
	local maxX = clampInteger(math.floor((maxPoint.X + half.X) / cell.X), 0, grid.sizeX - 1)
	local maxY = clampInteger(math.floor((maxPoint.Y + half.Y) / cell.Y), 0, grid.sizeY - 1)
	local maxZ = clampInteger(math.floor((maxPoint.Z + half.Z) / cell.Z), 0, grid.sizeZ - 1)

	return minX, minY, minZ, maxX, maxY, maxZ
end

-- Conservative wedge test: a voxel cell is solid if any part of it lies under
-- the wedge's slope. The slope rises with +Z, so the highest allowed Y inside
-- the cell is at the cell's back edge (localMax.Z); the lowest Y in the cell
-- (localMin.Y) must be at or below that to intersect.
local function isInsideWedgeByCorners(localMin: Vector3, localMax: Vector3, halfSize: Vector3): boolean
	local normalizedZ = (localMax.Z + halfSize.Z) / (halfSize.Z * 2)
	if normalizedZ < 0 then normalizedZ = 0 end
	if normalizedZ > 1 then normalizedZ = 1 end
	local maxY = -halfSize.Y + normalizedZ * (halfSize.Y * 2)
	return localMin.Y <= maxY
end

function VoxelGrid.create(part: BasePart, voxelSize: number, isWedge: boolean): Grid
	local size = part.Size
	local sizeX = math.max(1, math.ceil(size.X / voxelSize))
	local sizeY = math.max(1, math.ceil(size.Y / voxelSize))
	local sizeZ = math.max(1, math.ceil(size.Z / voxelSize))
	local total = sizeX * sizeY * sizeZ
	local cellSize = Vector3.new(size.X / sizeX, size.Y / sizeY, size.Z / sizeZ)
	local halfSize = size * 0.5

	local solid = buffer.create(total)
	local shapeMask = buffer.create(total)
	local visitedGeneration = buffer.create(total * 2)
	local meshGeneration = buffer.create(total * 2)
	local mergedGeneration = buffer.create(total * 2)
	local solidCount = 0

	local grid: Grid = {
		sizeX = sizeX,
		sizeY = sizeY,
		sizeZ = sizeZ,
		total = total,
		voxelSize = voxelSize,
		cellSize = cellSize,
		halfSize = halfSize,
		solid = solid,
		shapeMask = shapeMask,
		visitedGeneration = visitedGeneration,
		meshGeneration = meshGeneration,
		mergedGeneration = mergedGeneration,
		visitStamp = 0,
		meshStamp = 0,
		mergedStamp = 0,
		solidCount = 0,
		isWedge = isWedge,
	}

	for z = 0, sizeZ - 1 do
		for y = 0, sizeY - 1 do
			for x = 0, sizeX - 1 do
				local index = VoxelGrid.index(grid, x, y, z)
				local inside
				if isWedge then
					local cellMin = VoxelGrid.voxelMin(grid, x, y, z)
					local cellMax = cellMin + cellSize
					inside = isInsideWedgeByCorners(cellMin, cellMax, halfSize)
				else
					inside = true
				end
				if inside then
					buffer.writeu8(shapeMask, index, 1)
					buffer.writeu8(solid, index, 1)
					solidCount += 1
				end
			end
		end
	end

	grid.solidCount = solidCount
	return grid
end

return VoxelGrid
