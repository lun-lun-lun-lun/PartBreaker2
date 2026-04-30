--!strict
--!native

local VoxelGrid = require(script.Parent.VoxelGrid)

local ShapeTests = {}

local EPSILON = 1e-6
local AXIS_ALIGNMENT_EPSILON = 1e-4

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

-- Returns the voxel index range whose centers are guaranteed to lie strictly
-- inside the sphere (so the voxel cell is fully contained). Returns an empty
-- range (lo > hi on each axis) if the sphere has no such interior.
function ShapeTests.sphereInteriorRange(grid: VoxelGrid.Grid, localCenter: Vector3, radius: number): (number, number, number, number, number, number)
	local cellSize = grid.cellSize
	local halfSize = grid.halfSize
	local halfDiag = cellSize.Magnitude * 0.5
	local innerR = radius - halfDiag
	if innerR <= 0 then
		return 1, 0, 1, 0, 1, 0
	end

	local extent = innerR / math.sqrt(3)

	local minX = math.ceil((localCenter.X - extent + halfSize.X - cellSize.X * 0.5) / cellSize.X)
	local maxX = math.floor((localCenter.X + extent + halfSize.X - cellSize.X * 0.5) / cellSize.X)
	local minY = math.ceil((localCenter.Y - extent + halfSize.Y - cellSize.Y * 0.5) / cellSize.Y)
	local maxY = math.floor((localCenter.Y + extent + halfSize.Y - cellSize.Y * 0.5) / cellSize.Y)
	local minZ = math.ceil((localCenter.Z - extent + halfSize.Z - cellSize.Z * 0.5) / cellSize.Z)
	local maxZ = math.floor((localCenter.Z + extent + halfSize.Z - cellSize.Z * 0.5) / cellSize.Z)

	if minX < 0 then minX = 0 end
	if minY < 0 then minY = 0 end
	if minZ < 0 then minZ = 0 end
	if maxX > grid.sizeX - 1 then maxX = grid.sizeX - 1 end
	if maxY > grid.sizeY - 1 then maxY = grid.sizeY - 1 end
	if maxZ > grid.sizeZ - 1 then maxZ = grid.sizeZ - 1 end

	if minX > maxX or minY > maxY or minZ > maxZ then
		return 1, 0, 1, 0, 1, 0
	end

	return minX, minY, minZ, maxX, maxY, maxZ
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

-- Cheap fast-path containment check: returns true iff the entire voxel cell
-- lies inside the OBB. Costs 3 dot products + 3 axis projections (vs. 15-axis
-- SAT for obbIntersectsVoxel). Use as a guard before the full intersect test.
function ShapeTests.obbContainsVoxel(grid: VoxelGrid.Grid, localOBB: CFrame, size: Vector3, x: number, y: number, z: number): boolean
	local voxelCenter = VoxelGrid.voxelCenter(grid, x, y, z)
	local obbHalf = size * 0.5
	local cellHalf = grid.cellSize * 0.5
	local delta = voxelCenter - localOBB.Position
	local bx = localOBB.RightVector
	local by = localOBB.UpVector
	local bz = localOBB.LookVector

	local projX = abs(delta:Dot(bx)) + cellHalf.X * abs(bx.X) + cellHalf.Y * abs(bx.Y) + cellHalf.Z * abs(bx.Z)
	if projX > obbHalf.X then return false end
	local projY = abs(delta:Dot(by)) + cellHalf.X * abs(by.X) + cellHalf.Y * abs(by.Y) + cellHalf.Z * abs(by.Z)
	if projY > obbHalf.Y then return false end
	local projZ = abs(delta:Dot(bz)) + cellHalf.X * abs(bz.X) + cellHalf.Y * abs(bz.Y) + cellHalf.Z * abs(bz.Z)
	if projZ > obbHalf.Z then return false end

	return true
end

-- A CFrame is "axis-aligned" iff each rotation axis vector has all of its
-- magnitude in a single world-axis component (so it's one of the 24 orientations
-- formed by 90° turns). For a unit vector this happens iff the sum of |components|
-- equals 1. Orthonormality of CFrame guarantees the third axis follows from two.
function ShapeTests.isAxisAligned(cframe: CFrame): boolean
	local r = cframe.RightVector
	local rSum = abs(r.X) + abs(r.Y) + abs(r.Z)
	if rSum < 1 - AXIS_ALIGNMENT_EPSILON or rSum > 1 + AXIS_ALIGNMENT_EPSILON then
		return false
	end
	local u = cframe.UpVector
	local uSum = abs(u.X) + abs(u.Y) + abs(u.Z)
	return uSum >= 1 - AXIS_ALIGNMENT_EPSILON and uSum <= 1 + AXIS_ALIGNMENT_EPSILON
end

-- AABB overlap test for two parts that are both axis-aligned in world space.
-- For axis-aligned CFrames, the world-axis half-extents are the part's half-size
-- components permuted by the rotation (each abs(axis component) is 0 or 1).
function ShapeTests.partsTouchAabb(cframeA: CFrame, sizeA: Vector3, cframeB: CFrame, sizeB: Vector3, padding: number): boolean
	local rA = cframeA.RightVector
	local uA = cframeA.UpVector
	local lA = cframeA.LookVector
	local hAx = sizeA.X * 0.5 + padding
	local hAy = sizeA.Y * 0.5 + padding
	local hAz = sizeA.Z * 0.5 + padding
	local aExtX = abs(rA.X) * hAx + abs(uA.X) * hAy + abs(lA.X) * hAz
	local aExtY = abs(rA.Y) * hAx + abs(uA.Y) * hAy + abs(lA.Y) * hAz
	local aExtZ = abs(rA.Z) * hAx + abs(uA.Z) * hAy + abs(lA.Z) * hAz

	local rB = cframeB.RightVector
	local uB = cframeB.UpVector
	local lB = cframeB.LookVector
	local hBx = sizeB.X * 0.5 + padding
	local hBy = sizeB.Y * 0.5 + padding
	local hBz = sizeB.Z * 0.5 + padding
	local bExtX = abs(rB.X) * hBx + abs(uB.X) * hBy + abs(lB.X) * hBz
	local bExtY = abs(rB.Y) * hBx + abs(uB.Y) * hBy + abs(lB.Y) * hBz
	local bExtZ = abs(rB.Z) * hBx + abs(uB.Z) * hBy + abs(lB.Z) * hBz

	local delta = cframeB.Position - cframeA.Position
	if abs(delta.X) > aExtX + bExtX + EPSILON then return false end
	if abs(delta.Y) > aExtY + bExtY + EPSILON then return false end
	if abs(delta.Z) > aExtZ + bExtZ + EPSILON then return false end
	return true
end

-- Full 15-axis OBB-OBB separating-axis test.
function ShapeTests.partsTouchSat(cframeA: CFrame, sizeA: Vector3, cframeB: CFrame, sizeB: Vector3, padding: number): boolean
	local aHalf = sizeA * 0.5 + Vector3.new(padding, padding, padding)
	local bHalf = sizeB * 0.5 + Vector3.new(padding, padding, padding)
	local ax = cframeA.RightVector
	local ay = cframeA.UpVector
	local az = cframeA.LookVector
	local bx = cframeB.RightVector
	local by = cframeB.UpVector
	local bz = cframeB.LookVector
	local centerDelta = cframeB.Position - cframeA.Position

	local distance = abs(centerDelta:Dot(ax))
	local radius = aHalf.X + bHalf.X * abs(ax:Dot(bx)) + bHalf.Y * abs(ax:Dot(by)) + bHalf.Z * abs(ax:Dot(bz))
	if distance > radius + EPSILON then return false end
	distance = abs(centerDelta:Dot(ay))
	radius = aHalf.Y + bHalf.X * abs(ay:Dot(bx)) + bHalf.Y * abs(ay:Dot(by)) + bHalf.Z * abs(ay:Dot(bz))
	if distance > radius + EPSILON then return false end
	distance = abs(centerDelta:Dot(az))
	radius = aHalf.Z + bHalf.X * abs(az:Dot(bx)) + bHalf.Y * abs(az:Dot(by)) + bHalf.Z * abs(az:Dot(bz))
	if distance > radius + EPSILON then return false end

	distance = abs(centerDelta:Dot(bx))
	radius = bHalf.X + aHalf.X * abs(bx:Dot(ax)) + aHalf.Y * abs(bx:Dot(ay)) + aHalf.Z * abs(bx:Dot(az))
	if distance > radius + EPSILON then return false end
	distance = abs(centerDelta:Dot(by))
	radius = bHalf.Y + aHalf.X * abs(by:Dot(ax)) + aHalf.Y * abs(by:Dot(ay)) + aHalf.Z * abs(by:Dot(az))
	if distance > radius + EPSILON then return false end
	distance = abs(centerDelta:Dot(bz))
	radius = bHalf.Z + aHalf.X * abs(bz:Dot(ax)) + aHalf.Y * abs(bz:Dot(ay)) + aHalf.Z * abs(bz:Dot(az))
	if distance > radius + EPSILON then return false end

	for axisIndex = 1, 9 do
		local aAxis: Vector3
		local bAxis: Vector3
		if axisIndex <= 3 then
			aAxis = ax
			bAxis = if axisIndex == 1 then bx elseif axisIndex == 2 then by else bz
		elseif axisIndex <= 6 then
			aAxis = ay
			bAxis = if axisIndex == 4 then bx elseif axisIndex == 5 then by else bz
		else
			aAxis = az
			bAxis = if axisIndex == 7 then bx elseif axisIndex == 8 then by else bz
		end

		local axis = aAxis:Cross(bAxis)
		if axis:Dot(axis) <= EPSILON then
			continue
		end

		local d = abs(centerDelta:Dot(axis))
		local rA = aHalf.X * abs(axis:Dot(ax)) + aHalf.Y * abs(axis:Dot(ay)) + aHalf.Z * abs(axis:Dot(az))
		local rB = bHalf.X * abs(axis:Dot(bx)) + bHalf.Y * abs(axis:Dot(by)) + bHalf.Z * abs(axis:Dot(bz))
		if d > rA + rB + EPSILON then return false end
	end

	return true
end

-- Dispatcher: AABB fast-path when both parts are axis-aligned, else full SAT.
function ShapeTests.partsTouch(cframeA: CFrame, sizeA: Vector3, cframeB: CFrame, sizeB: Vector3, padding: number): boolean
	if ShapeTests.isAxisAligned(cframeA) and ShapeTests.isAxisAligned(cframeB) then
		return ShapeTests.partsTouchAabb(cframeA, sizeA, cframeB, sizeB, padding)
	end
	return ShapeTests.partsTouchSat(cframeA, sizeA, cframeB, sizeB, padding)
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
