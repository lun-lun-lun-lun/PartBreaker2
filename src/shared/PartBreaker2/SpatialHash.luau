--!strict
--!native

local SpatialHash = {}
SpatialHash.__index = SpatialHash

export type Hash = typeof(setmetatable(
	{} :: {
		cellSize: number,
		buckets: { [string]: { [BasePart]: true } },
		partCells: { [BasePart]: { [string]: true } },
	},
	SpatialHash
))

local function cellCoord(value: number, cellSize: number): number
	return math.floor(value / cellSize)
end

local function cellKey(x: number, y: number, z: number): string
	return `{x},{y},{z}`
end

local function worldAabb(cframe: CFrame, size: Vector3, padding: number): (Vector3, Vector3)
	local half = size * 0.5 + Vector3.new(padding, padding, padding)
	local right = cframe.RightVector
	local up = cframe.UpVector
	local look = cframe.LookVector
	local extent = Vector3.new(
		math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(look.X) * half.Z,
		math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(look.Y) * half.Z,
		math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(look.Z) * half.Z
	)

	return cframe.Position - extent, cframe.Position + extent
end

function SpatialHash.new(cellSize: number): Hash
	return setmetatable({
		cellSize = math.max(1, cellSize),
		buckets = {} :: { [string]: { [BasePart]: true } },
		partCells = {} :: { [BasePart]: { [string]: true } },
	}, SpatialHash) :: Hash
end

function SpatialHash.remove(self: Hash, part: BasePart)
	local cells = self.partCells[part]
	if not cells then
		return
	end

	for key in cells do
		local bucket = self.buckets[key]
		if bucket then
			bucket[part] = nil
			if next(bucket) == nil then
				self.buckets[key] = nil
			end
		end
	end

	self.partCells[part] = nil
end

function SpatialHash.insert(self: Hash, part: BasePart)
	self:remove(part)

	local minPoint, maxPoint = worldAabb(part.CFrame, part.Size, 0)
	local minX = cellCoord(minPoint.X, self.cellSize)
	local minY = cellCoord(minPoint.Y, self.cellSize)
	local minZ = cellCoord(minPoint.Z, self.cellSize)
	local maxX = cellCoord(maxPoint.X, self.cellSize)
	local maxY = cellCoord(maxPoint.Y, self.cellSize)
	local maxZ = cellCoord(maxPoint.Z, self.cellSize)
	local cells: { [string]: true } = {}

	for x = minX, maxX do
		for y = minY, maxY do
			for z = minZ, maxZ do
				local key = cellKey(x, y, z)
				local bucket = self.buckets[key]
				if not bucket then
					bucket = {} :: { [BasePart]: true }
					self.buckets[key] = bucket
				end
				bucket[part] = true
				cells[key] = true
			end
		end
	end

	self.partCells[part] = cells
end

function SpatialHash.update(self: Hash, part: BasePart)
	self:insert(part)
end

function SpatialHash.queryAABB(self: Hash, cframe: CFrame, size: Vector3, padding: number, outParts: { BasePart }?): { BasePart }
	local minPoint, maxPoint = worldAabb(cframe, size, padding)
	local minX = cellCoord(minPoint.X, self.cellSize)
	local minY = cellCoord(minPoint.Y, self.cellSize)
	local minZ = cellCoord(minPoint.Z, self.cellSize)
	local maxX = cellCoord(maxPoint.X, self.cellSize)
	local maxY = cellCoord(maxPoint.Y, self.cellSize)
	local maxZ = cellCoord(maxPoint.Z, self.cellSize)
	local parts = outParts or ({} :: { BasePart })
	local seen: { [BasePart]: boolean } = {}

	for x = minX, maxX do
		for y = minY, maxY do
			for z = minZ, maxZ do
				local bucket = self.buckets[cellKey(x, y, z)]
				if not bucket then
					continue
				end

				for part in bucket do
					if not seen[part] then
						seen[part] = true
						parts[#parts + 1] = part
					end
				end
			end
		end
	end

	return parts
end

return SpatialHash
