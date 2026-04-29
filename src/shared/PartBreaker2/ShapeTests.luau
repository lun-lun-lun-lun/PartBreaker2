--!strict
--!native

local VoxelGrid = require(script.Parent.VoxelGrid)

local ShapeTests = {}

local EPSILON = 1e-6

local function abs(value: number): number
	return if value < 0 then -value else value
end

local function clamp(value: number, minValue: number, maxValue: number): number
	if value < minValue then
		return minValue
	end
	if value > maxValue then
		return maxValue
	end
	return value
end

function ShapeTests.sphereRange(grid: VoxelGrid.Grid, localCenter: Vector3, radius: number): (number, number, number, number, number, number)
	local radiusVector = Vector3.new(radius, radius, radius)
	return VoxelGrid.localAabbToVoxelRange(grid, localCenter - radiusVector, localCenter + radiusVector)
end

function ShapeTests.sphereIntersectsVoxel(grid: VoxelGrid.Grid, localCenter: Vector3, radiusSquared: number, x: number, y: number, z: number): boolean
	local minPoint = VoxelGrid.voxelMin(grid, x, y, z)
	local maxPoint = minPoint + grid.cellSize

	local closestX = clamp(localCenter.X, minPoint.X, maxPoint.X)
	local closestY = clamp(localCenter.Y, minPoint.Y, maxPoint.Y)
	local closestZ = clamp(localCenter.Z, minPoint.Z, maxPoint.Z)

	local dx = localCenter.X - closestX
	local dy = localCenter.Y - closestY
	local dz = localCenter.Z - closestZ

	return dx * dx + dy * dy + dz * dz <= radiusSquared
end

function ShapeTests.obbRange(grid: VoxelGrid.Grid, localOBB: CFrame, size: Vector3): (number, number, number, number, number, number)
	local half = size * 0.5
	local minX = math.huge
	local minY = math.huge
	local minZ = math.huge
	local maxX = -math.huge
	local maxY = -math.huge
	local maxZ = -math.huge

	for sx = -1, 1, 2 do
		for sy = -1, 1, 2 do
			for sz = -1, 1, 2 do
				local corner = localOBB * Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)
				if corner.X < minX then minX = corner.X end
				if corner.Y < minY then minY = corner.Y end
				if corner.Z < minZ then minZ = corner.Z end
				if corner.X > maxX then maxX = corner.X end
				if corner.Y > maxY then maxY = corner.Y end
				if corner.Z > maxZ then maxZ = corner.Z end
			end
		end
	end

	return VoxelGrid.localAabbToVoxelRange(
		grid,
		Vector3.new(minX, minY, minZ),
		Vector3.new(maxX, maxY, maxZ)
	)
end

local function pointInsideOBB(localOBB: CFrame, half: Vector3, point: Vector3): boolean
	local p = localOBB:PointToObjectSpace(point)
	return abs(p.X) <= half.X and abs(p.Y) <= half.Y and abs(p.Z) <= half.Z
end

local function projectAabbRadius(axis: Vector3, half: Vector3): number
	return half.X * abs(axis.X) + half.Y * abs(axis.Y) + half.Z * abs(axis.Z)
end

local function projectObbRadius(axis: Vector3, bx: Vector3, by: Vector3, bz: Vector3, half: Vector3): number
	return half.X * abs(axis:Dot(bx)) + half.Y * abs(axis:Dot(by)) + half.Z * abs(axis:Dot(bz))
end

local function axisSeparates(axis: Vector3, centerDelta: Vector3, aHalf: Vector3, bHalf: Vector3, bx: Vector3, by: Vector3, bz: Vector3): boolean
	if axis:Dot(axis) <= EPSILON then
		return false
	end

	local distance = abs(centerDelta:Dot(axis))
	local radius = projectAabbRadius(axis, aHalf) + projectObbRadius(axis, bx, by, bz, bHalf)
	return distance > radius + EPSILON
end

function ShapeTests.obbIntersectsVoxel(grid: VoxelGrid.Grid, localOBB: CFrame, size: Vector3, x: number, y: number, z: number): boolean
	local voxelCenter = VoxelGrid.voxelCenter(grid, x, y, z)
	local obbHalf = size * 0.5

	if pointInsideOBB(localOBB, obbHalf, voxelCenter) then
		return true
	end

	local aHalf = grid.cellSize * 0.5
	local bCenter = localOBB.Position
	local centerDelta = bCenter - voxelCenter
	local bx = localOBB.RightVector
	local by = localOBB.UpVector
	local bz = localOBB.LookVector

	if axisSeparates(Vector3.xAxis, centerDelta, aHalf, obbHalf, bx, by, bz) then return false end
	if axisSeparates(Vector3.yAxis, centerDelta, aHalf, obbHalf, bx, by, bz) then return false end
	if axisSeparates(Vector3.zAxis, centerDelta, aHalf, obbHalf, bx, by, bz) then return false end
	if axisSeparates(bx, centerDelta, aHalf, obbHalf, bx, by, bz) then return false end
	if axisSeparates(by, centerDelta, aHalf, obbHalf, bx, by, bz) then return false end
	if axisSeparates(bz, centerDelta, aHalf, obbHalf, bx, by, bz) then return false end

	if axisSeparates(Vector3.xAxis:Cross(bx), centerDelta, aHalf, obbHalf, bx, by, bz) then return false end
	if axisSeparates(Vector3.xAxis:Cross(by), centerDelta, aHalf, obbHalf, bx, by, bz) then return false end
	if axisSeparates(Vector3.xAxis:Cross(bz), centerDelta, aHalf, obbHalf, bx, by, bz) then return false end
	if axisSeparates(Vector3.yAxis:Cross(bx), centerDelta, aHalf, obbHalf, bx, by, bz) then return false end
	if axisSeparates(Vector3.yAxis:Cross(by), centerDelta, aHalf, obbHalf, bx, by, bz) then return false end
	if axisSeparates(Vector3.yAxis:Cross(bz), centerDelta, aHalf, obbHalf, bx, by, bz) then return false end
	if axisSeparates(Vector3.zAxis:Cross(bx), centerDelta, aHalf, obbHalf, bx, by, bz) then return false end
	if axisSeparates(Vector3.zAxis:Cross(by), centerDelta, aHalf, obbHalf, bx, by, bz) then return false end
	if axisSeparates(Vector3.zAxis:Cross(bz), centerDelta, aHalf, obbHalf, bx, by, bz) then return false end

	return true
end

return ShapeTests
