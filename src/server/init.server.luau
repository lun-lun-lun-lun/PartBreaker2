--!strict

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local PartBreaker2 = require(ReplicatedStorage.Shared.PartBreaker2)
local ProjectileSim = require(ReplicatedStorage.Shared.ProjectileSim)
local VoxelDestructionTest = require(script:WaitForChild("VoxelDestructionTest"))
local house = Workspace:FindFirstChild("ClassicHouse")
local wall = Workspace:FindFirstChild("BigWall")

local SPAWN_DELAY_SECONDS = 3
local CLEANUP_DELAY_SECONDS = 15
local PROJECTILE_NAME = "ProjectileSimTestSphere"
local PROJECTILE_DESTRUCTION_RADIUS = 5
local PROJECTILE_DESTRUCTION_STRENGTH = 100
local PROJECTILE_DEBRIS_IMPULSE = 55

PartBreaker2.configureRuntime({
	debug = false,
	budgets = {
		maxTasksPerFrame = 400,
		maxRecordsPerFrame = 300,
		maxVoxelTestsPerFrame = 600000,
		maxConnectivityVisitsPerFrame = 800000,
		maxGreedyVisitsPerFrame = 1000000,
		maxPartsCommittedPerFrame = 9600,
		maxSupportQueriesPerFrame = 8000,
		maxWeldOpsPerFrame = 16000,
	},
})

local function registerVoxelModel(instance: Instance)
	if instance:IsA("Model") then
		PartBreaker2.registerModel(instance)
	end
end


if house and house:IsA("Model") then
	local count = PartBreaker2.makeModelDestructible(house, {
		voxelSize = 3,
		requiredStrength = 0,
		supportMode = "Bottom",
		maxCuboids = 256,
		maxDebrisVoxels = 20,
		debrisLifetime = 2.5,
		overrideExistingAttributes = false,
		lazyGeneratedGrid = true,
	})

	print(`Made {count} parts destructible in ClassicHouse`)
end

if wall and wall:IsA("Model") then
	local count = PartBreaker2.makeModelDestructible(wall, {
		voxelSize = 2,
		requiredStrength = 0,
		supportMode = "Bottom",
		maxCuboids = 256,
		maxDebrisVoxels = 64,
		debrisLifetime = 2.5,
		overrideExistingAttributes = false,
		lazyGeneratedGrid = true,
	})

	print(`Made {count} parts destructible in BigWall`)
end

PartBreaker2.registerTaggedModels()
PartBreaker2.registerAttributedModels(Workspace)

CollectionService:GetInstanceAddedSignal("VoxelModel"):Connect(registerVoxelModel)
Workspace.DescendantAdded:Connect(function(instance)
	if instance:IsA("Model") and instance:GetAttribute("VoxelModel") == true then
		PartBreaker2.registerModel(instance)
	end
end)

VoxelDestructionTest.start(PartBreaker2)

local function spawnProjectileTest()
	local existing = Workspace:FindFirstChild(PROJECTILE_NAME)
	if existing then
		existing:Destroy()
	end

	local sphere = Instance.new("Part")
	sphere.Name = PROJECTILE_NAME
	sphere.Shape = Enum.PartType.Ball
	sphere.Size = Vector3.new(2, 2, 2)
	sphere.Color = Color3.fromRGB(255, 170, 64)
	sphere.Material = Enum.Material.Neon
	sphere.TopSurface = Enum.SurfaceType.Smooth
	sphere.BottomSurface = Enum.SurfaceType.Smooth
	sphere.Position = Vector3.new(-24, 8, 0)
	sphere.Parent = Workspace

	local hitCount = 0
	local mass = 1

	local projectile = ProjectileSim.new({
		part = sphere,
		mass = mass,
		velocity = Vector3.new(22, 48, 10),
		forces = {
			ProjectileSim.gravityForce(mass),
		},
		bounciness = 0.55,
		minBounceSpeed = 4,
		maxBounces = 40,
		onHit = function(hitInfo)
			hitCount += 1
			PartBreaker2.destroySphere(
				hitInfo.position,
				PROJECTILE_DESTRUCTION_RADIUS,
				PROJECTILE_DESTRUCTION_STRENGTH,
				-hitInfo.normal * PROJECTILE_DEBRIS_IMPULSE
			)
			print(string.format(
				"[ProjectileSim test] hit %d on %s at %.2f, %.2f, %.2f",
				hitCount,
				hitInfo.instance:GetFullName(),
				hitInfo.position.X,
				hitInfo.position.Y,
				hitInfo.position.Z
			))
		end,
		onDestroy = function()
			print(string.format("[ProjectileSim test] cleaned up after %d hits", hitCount))
		end,
	})

	task.delay(CLEANUP_DELAY_SECONDS, function()
		projectile:destroy()
		if sphere.Parent ~= nil then
			sphere:Destroy()
		end
	end)

	print("[ProjectileSim test] launched test sphere")
end

print(string.format("[ProjectileSim test] spawning sphere in %d seconds", SPAWN_DELAY_SECONDS))
task.delay(SPAWN_DELAY_SECONDS, spawnProjectileTest)
