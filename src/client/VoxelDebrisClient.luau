--!strict
--!native

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local VoxelDebrisClient = {}

type DebrisPayload = {
	seed: number?,
	Seed: number?,
	positions: { Vector3 }?,
	Positions: { Vector3 }?,
	cellSize: Vector3?,
	CellSize: Vector3?,
	color: Color3?,
	Color: Color3?,
	material: any?,
	Material: any?,
	impulse: Vector3?,
	Impulse: Vector3?,
	lifetime: number?,
	Lifetime: number?,
}

type Shard = {
	part: BasePart,
	position: Vector3,
	velocity: Vector3,
	rotation: Vector3,
	angularVelocity: Vector3,
	age: number,
	lifetime: number,
}

local REMOTE_NAME = "PartBreaker2DebrisEvent"
local MAX_ACTIVE_SHARDS = 320
local MAX_SHARDS_PER_EVENT = 10
local GRAVITY = Vector3.new(0, -Workspace.Gravity, 0)
local BOUNCE_DAMPING = 0.35
local GROUND_FRICTION = 0.72
local FAR_AWAY_BASE = Vector3.new(2^20, 2^20, -2^20)

local folder = nil :: Folder?
local freeParts = {} :: { BasePart }
local active = {} :: { Shard }
local movedParts = table.create(MAX_ACTIVE_SHARDS) :: { BasePart }
local movedCFrames = table.create(MAX_ACTIVE_SHARDS) :: { CFrame }
local pendingReturnParts = table.create(64) :: { BasePart }
local pendingReturnCFrames = table.create(64) :: { CFrame }
local graveyardIndex = 0
local started = false
local raycastParams = RaycastParams.new()
local networkClient = nil :: any?
local networkLoadAttempted = false

local function ensureFolder(): Folder
	if folder then
		return folder
	end

	local newFolder = Instance.new("Folder")
	newFolder.Name = "PartBreaker2ClientDebris"
	newFolder.Parent = Workspace
	folder = newFolder
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { newFolder }
	raycastParams.RespectCanCollide = true
	return newFolder
end

local function graveyardCFrame(): CFrame
	graveyardIndex += 1
	return CFrame.new(FAR_AWAY_BASE + Vector3.new(graveyardIndex * 50, 0, 0))
end

local function getPart(): BasePart
	local part = table.remove(freeParts)
	if part then
		return part
	end

	local newPart = Instance.new("Part")
	newPart.Name = "VoxelDebrisShard"
	newPart.TopSurface = Enum.SurfaceType.Smooth
	newPart.BottomSurface = Enum.SurfaceType.Smooth
	newPart.Anchored = true
	newPart.CanCollide = false
	newPart.CanQuery = false
	newPart.CanTouch = false
	return newPart
end

local function returnPart(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Parent = ensureFolder()
	pendingReturnParts[#pendingReturnParts + 1] = part
	pendingReturnCFrames[#pendingReturnCFrames + 1] = graveyardCFrame()
	table.insert(freeParts, part)
end

local function flushReturnedParts()
	if #pendingReturnParts <= 0 then
		return
	end

	Workspace:BulkMoveTo(pendingReturnParts, pendingReturnCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	table.clear(pendingReturnParts)
	table.clear(pendingReturnCFrames)
end

local function materialFromValue(value: any): Enum.Material
	local numericValue = if typeof(value) == "number" then value else nil
	local name = if typeof(value) == "string" then value else nil
	for _, material in Enum.Material:GetEnumItems() do
		if material.Value == numericValue or material.Name == name then
			return material :: Enum.Material
		end
	end
	return Enum.Material.Plastic
end

local function spawnShard(payload: DebrisPayload, position: Vector3, random: Random)
	if #active >= MAX_ACTIVE_SHARDS then
		local oldest = table.remove(active, 1)
		if oldest then
			returnPart(oldest.part)
		end
	end

	local part = getPart()
	local cellSize = payload.cellSize or payload.CellSize or Vector3.one
	part.Size = Vector3.new(
		math.max(0.1, cellSize.X * random:NextNumber(0.65, 0.95)),
		math.max(0.1, cellSize.Y * random:NextNumber(0.65, 0.95)),
		math.max(0.1, cellSize.Z * random:NextNumber(0.65, 0.95))
	)
	part.Color = payload.color or payload.Color or Color3.fromRGB(163, 162, 165)
	part.Material = materialFromValue(payload.material or payload.Material)
	part.Transparency = 0
	part.CFrame = CFrame.new(position)
	part.Parent = ensureFolder()

	local spray = Vector3.new(
		random:NextNumber(-1, 1),
		random:NextNumber(0.25, 1.25),
		random:NextNumber(-1, 1)
	)
	if spray.Magnitude > 0 then
		spray = spray.Unit
	end

	local velocity = (payload.impulse or payload.Impulse or Vector3.zero) + spray * random:NextNumber(18, 54)
	active[#active + 1] = {
		part = part,
		position = position,
		velocity = velocity,
		rotation = Vector3.new(random:NextNumber(0, math.pi), random:NextNumber(0, math.pi), random:NextNumber(0, math.pi)),
		angularVelocity = Vector3.new(random:NextNumber(-8, 8), random:NextNumber(-8, 8), random:NextNumber(-8, 8)),
		age = 0,
		lifetime = payload.lifetime or payload.Lifetime or 2.5,
	}
end

local function handlePayload(payload: DebrisPayload)
	ensureFolder()
	local random = Random.new(payload.seed or payload.Seed or 0)
	local positions = payload.positions or payload.Positions or {}
	local limit = math.min(#positions, MAX_SHARDS_PER_EVENT)
	if limit <= 0 then
		return
	end

	local stride = math.max(1, math.ceil(#positions / limit))
	local emitted = 0
	for index = 1, #positions, stride do
		emitted += 1
		spawnShard(payload, positions[index], random)
		if emitted >= limit then
			break
		end
	end
end

local function getNetworkClient(): any?
	if networkClient or networkLoadAttempted then
		return networkClient
	end

	networkLoadAttempted = true
	local shared = ReplicatedStorage:WaitForChild("Shared", 10)
	local folder = if shared then shared:FindFirstChild("PartBreaker2Net") else nil
	local clientModule = if folder then folder:FindFirstChild("Client") else nil
	if clientModule and clientModule:IsA("ModuleScript") then
		local ok, result = pcall(require, clientModule)
		if ok then
			networkClient = result
		else
			warn(`PartBreaker2: failed to load Blink client module: {result}`)
		end
	end

	return networkClient
end

local function step(dt: number)
	local movedCount = 0
	local index = 1
	while index <= #active do
		local shard = active[index]
		shard.age += dt
		if shard.age >= shard.lifetime then
			returnPart(shard.part)
			active[index] = active[#active]
			active[#active] = nil :: any
			continue
		end

		local oldPosition = shard.position
		local velocity = shard.velocity + GRAVITY * dt
		local newPosition = oldPosition + velocity * dt
		local result = Workspace:Raycast(oldPosition, newPosition - oldPosition, raycastParams)

		if result then
			local normal = result.Normal
			newPosition = result.Position + normal * 0.04
			local normalVelocity = normal * velocity:Dot(normal)
			local tangentVelocity = velocity - normalVelocity
			velocity = tangentVelocity * GROUND_FRICTION - normalVelocity * BOUNCE_DAMPING
		end

		shard.velocity = velocity
		shard.position = newPosition
		shard.rotation += shard.angularVelocity * dt
		movedCount += 1
		movedParts[movedCount] = shard.part
		movedCFrames[movedCount] = CFrame.new(newPosition) * CFrame.Angles(shard.rotation.X, shard.rotation.Y, shard.rotation.Z)

		index += 1
	end

	if movedCount > 0 then
		Workspace:BulkMoveTo(movedParts, movedCFrames, Enum.BulkMoveMode.FireCFrameChanged)
		for clearIndex = 1, movedCount do
			movedParts[clearIndex] = nil :: any
			movedCFrames[clearIndex] = nil :: any
		end
	end

	flushReturnedParts()
end

function VoxelDebrisClient.start()
	if started then
		return
	end
	started = true
	ensureFolder()

	local network = getNetworkClient()
	if network and network.Debris then
		(network.Debris :: any).On(function(payload)
			handlePayload(payload)
		end)
	end

	local remote = ReplicatedStorage:WaitForChild(REMOTE_NAME, 10)
	if remote and remote:IsA("RemoteEvent") then
		remote.OnClientEvent:Connect(function(payload: DebrisPayload)
			handlePayload(payload)
		end)
	elseif not network then
		warn("PartBreaker2: debris remote was not found; client debris disabled")
	end

	RunService.RenderStepped:Connect(step)
end

return VoxelDebrisClient
