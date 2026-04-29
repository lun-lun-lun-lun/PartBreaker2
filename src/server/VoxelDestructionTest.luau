--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPack = game:GetService("StarterPack")
local Workspace = game:GetService("Workspace")

local VoxelDestructionTest = {}

local TEST_MODEL_NAME = "PartBreaker2RandomVoxelTest"
local SUPPORT_TEST_MODEL_NAME = "PartBreaker2SupportRefreshTest"
local SUPPORT_TEST_BASE_NAME = "PartBreaker2SupportRefreshBase"
local SPHERE_TOOL_NAME = "Voxel Breaker"
local SLICE_TOOL_NAME = "Voxel Support Slice"
local GREEDY_VIS_TOOL_NAME = "Viz Greedy Meshes"
local ATTACHED_VIS_TOOL_NAME = "Viz Attached Chunks"
local REMOTE_NAME = "PartBreaker2VoxelToolActivated"
local SPHERE_MODE = "Sphere"
local SLICE_MODE = "HorizontalSlice"
local GREEDY_VIS_MODE = "Greedy"
local ATTACHED_VIS_MODE = "Attached"
local DESTROY_RADIUS = 3.5
local SLICE_SIZE = Vector3.new(64, 2.2, 12)
local MAX_DESTROY_DISTANCE = 140
local DESTROY_STRENGTH = 250
local DESTROY_IMPULSE = 70
local TOOL_COOLDOWN = 0.25
local PART_COUNT = 32
local RANDOM_SEED = 424242

local lastUseByPlayer: { [Player]: number } = {}
local toolRemote = nil :: RemoteEvent?
local networkServer = nil :: any?
local networkLoadAttempted = false

local function getNetworkServer(): any?
	if networkServer or networkLoadAttempted then
		return networkServer
	end

	networkLoadAttempted = true
	local shared = ReplicatedStorage:FindFirstChild("Shared")
	local folder = if shared then shared:FindFirstChild("PartBreaker2Net") else nil
	local serverModule = if folder then folder:FindFirstChild("Server") else nil
	if serverModule and serverModule:IsA("ModuleScript") then
		local ok, result = pcall(require, serverModule)
		if ok then
			networkServer = result
		else
			warn(`PartBreaker2: failed to load Blink server module for test tools: {result}`)
		end
	end

	return networkServer
end

local function randomRange(random: Random, minValue: number, maxValue: number): number
	return minValue + (maxValue - minValue) * random:NextNumber()
end

local function randomCFrame(random: Random, position: Vector3): CFrame
	return CFrame.new(position)
		* CFrame.Angles(
			math.rad(random:NextNumber(-35, 35)),
			math.rad(random:NextNumber(0, 360)),
			math.rad(random:NextNumber(-35, 35))
		)
end

local function configureVoxelPart(part: BasePart, random: Random)
	part.Anchored = true
	part.CanCollide = true
	part.CanQuery = true
	part.CanTouch = true
	part.Material = Enum.Material.Concrete
	part.Color = Color3.fromHSV(random:NextNumber(0.02, 0.13), random:NextNumber(0.35, 0.7), random:NextNumber(0.55, 0.9))
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part:SetAttribute("VoxelPart", true)
	part:SetAttribute("VoxelSize", random:NextNumber(1.25, 2.25))
	part:SetAttribute("RequiredStrength", random:NextInteger(0, 90))
	part:SetAttribute("MaxCuboids", 320)
	part:SetAttribute("MaxDebrisVoxels", 96)
	part:SetAttribute("DebrisLifetime", 2.75)
	part:SetAttribute("DebrisImpulseMultiplier", 1)
	part:SetAttribute("VoxelSupport", "Bottom")
end

local function makeRandomVoxelPart(random: Random, parent: Instance, index: number)
	local useWedge = random:NextNumber() < 0.28
	local part = if useWedge then Instance.new("WedgePart") else Instance.new("Part")
	part.Name = if useWedge then `VoxelWedge_{index}` else `VoxelBlock_{index}`
	part.Size = Vector3.new(
		randomRange(random, 5, 13),
		randomRange(random, 4, 12),
		randomRange(random, 5, 13)
	)

	local column = (index - 1) % 8
	local row = math.floor((index - 1) / 8)
	local layer = math.floor((index - 1) / 16)
	local basePosition = Vector3.new(
		(column - 3.5) * 8 + randomRange(random, -1.8, 1.8),
		3.5 + layer * 8 + randomRange(random, -0.8, 2.2),
		-42 - row * 8 + randomRange(random, -1.8, 1.8)
	)

	part.CFrame = randomCFrame(random, basePosition)
	configureVoxelPart(part, random)
	part.Parent = parent
end

function VoxelDestructionTest.createRandomVoxelModel(partBreaker: any): Model
	local existing = Workspace:FindFirstChild(TEST_MODEL_NAME)
	if existing then
		existing:Destroy()
	end

	local random = Random.new(RANDOM_SEED)
	local model = Instance.new("Model")
	model.Name = TEST_MODEL_NAME
	model:SetAttribute("VoxelModel", true)

	for index = 1, PART_COUNT do
		makeRandomVoxelPart(random, model, index)
	end

	model.Parent = Workspace
	CollectionService:AddTag(model, "VoxelModel")
	partBreaker.registerModel(model)

	print(`[PartBreaker2 test] spawned {PART_COUNT} randomized VoxelParts in {model:GetFullName()}`)
	return model
end

function VoxelDestructionTest.createSupportRefreshTestModel(partBreaker: any): Model
	local existingModel = Workspace:FindFirstChild(SUPPORT_TEST_MODEL_NAME)
	if existingModel then
		existingModel:Destroy()
	end

	local existingBase = Workspace:FindFirstChild(SUPPORT_TEST_BASE_NAME)
	if existingBase then
		existingBase:Destroy()
	end

	local base = Instance.new("Part")
	base.Name = SUPPORT_TEST_BASE_NAME
	base.Size = Vector3.new(72, 1, 18)
	base.CFrame = CFrame.new(0, -0.5, 28)
	base.Anchored = true
	base.CanCollide = true
	base.CanQuery = true
	base.CanTouch = true
	base.Material = Enum.Material.Concrete
	base.Color = Color3.fromRGB(105, 112, 120)
	base.TopSurface = Enum.SurfaceType.Smooth
	base.BottomSurface = Enum.SurfaceType.Smooth
	base:SetAttribute("PartBreaker2SupportAnchor", true)
	base.Parent = Workspace

	local model = Instance.new("Model")
	model.Name = SUPPORT_TEST_MODEL_NAME
	model:SetAttribute("VoxelModel", true)

	local wall = Instance.new("Part")
	wall.Name = "SupportRefreshWall"
	wall.Size = Vector3.new(56, 32, 4)
	wall.CFrame = CFrame.new(0, 16, 28)
	wall.Anchored = true
	wall.CanCollide = true
	wall.CanQuery = true
	wall.CanTouch = true
	wall.Material = Enum.Material.Concrete
	wall.Color = Color3.fromRGB(155, 164, 176)
	wall.TopSurface = Enum.SurfaceType.Smooth
	wall.BottomSurface = Enum.SurfaceType.Smooth
	wall:SetAttribute("VoxelPart", true)
	wall:SetAttribute("VoxelSize", 2)
	wall:SetAttribute("RequiredStrength", 0)
	wall:SetAttribute("MaxCuboids", 512)
	wall:SetAttribute("MaxDebrisVoxels", 128)
	wall:SetAttribute("DebrisLifetime", 2.5)
	wall:SetAttribute("DebrisImpulseMultiplier", 1)
	wall:SetAttribute("VoxelSupport", "Graph")
	wall.Parent = model

	model.Parent = Workspace
	CollectionService:AddTag(model, "VoxelModel")
	partBreaker.registerModel(model)

	print("[PartBreaker2 support test] spawned wall. Use Voxel Support Slice across the wall: bottom should stay supported, top should fall.")
	return model
end

local function createDestroyerPreview(center: Vector3)
	local preview = Instance.new("Part")
	preview.Name = "SphereDestroyerPreview"
	preview.Shape = Enum.PartType.Ball
	preview.Size = Vector3.new(DESTROY_RADIUS * 2, DESTROY_RADIUS * 2, DESTROY_RADIUS * 2)
	preview.Color = Color3.fromRGB(255, 70, 70)
	preview.Material = Enum.Material.Neon
	preview.Transparency = 0.55
	preview.Anchored = true
	preview.CanCollide = false
	preview.CanQuery = false
	preview.CanTouch = false
	preview.CFrame = CFrame.new(center)
	preview.Parent = Workspace

	task.delay(0.12, function()
		if preview.Parent ~= nil then
			preview:Destroy()
		end
	end)
end

local function createOBBPreview(cframe: CFrame, size: Vector3)
	local preview = Instance.new("Part")
	preview.Name = "OBBDestroyerPreview"
	preview.Size = size
	preview.Color = Color3.fromRGB(255, 190, 65)
	preview.Material = Enum.Material.Neon
	preview.Transparency = 0.55
	preview.Anchored = true
	preview.CanCollide = false
	preview.CanQuery = false
	preview.CanTouch = false
	preview.CFrame = cframe
	preview.Parent = Workspace

	task.delay(0.16, function()
		if preview.Parent ~= nil then
			preview:Destroy()
		end
	end)
end

local function makeTool(toolName: string, mode: string, tooltip: string): Tool
	local tool = Instance.new("Tool")
	tool.Name = toolName
	tool.ToolTip = tooltip
	tool.RequiresHandle = false
	tool.CanBeDropped = false
	tool:SetAttribute("PartBreaker2TestTool", true)
	tool:SetAttribute("PartBreaker2DestroyerMode", mode)
	return tool
end

local function makeVisualizerTool(toolName: string, mode: string, tooltip: string): Tool
	local tool = Instance.new("Tool")
	tool.Name = toolName
	tool.ToolTip = tooltip
	tool.RequiresHandle = false
	tool.CanBeDropped = false
	tool:SetAttribute("PartBreaker2VisualizerTool", true)
	tool:SetAttribute("PartBreaker2VisualizerMode", mode)
	return tool
end

local function ensureStarterTool(toolName: string, mode: string, tooltip: string)
	local existing = StarterPack:FindFirstChild(toolName)
	if existing and existing:IsA("Tool") then
		existing.ToolTip = tooltip
		existing:SetAttribute("PartBreaker2TestTool", true)
		existing:SetAttribute("PartBreaker2DestroyerMode", mode)
		return
	end

	local tool = makeTool(toolName, mode, tooltip)
	tool.Parent = StarterPack
end

local function ensureStarterVisualizerTool(toolName: string, mode: string, tooltip: string)
	local existing = StarterPack:FindFirstChild(toolName)
	if existing and existing:IsA("Tool") then
		existing.ToolTip = tooltip
		existing:SetAttribute("PartBreaker2VisualizerTool", true)
		existing:SetAttribute("PartBreaker2VisualizerMode", mode)
		return
	end

	local tool = makeVisualizerTool(toolName, mode, tooltip)
	tool.Parent = StarterPack
end

local function giveTool(player: Player, toolName: string, mode: string, tooltip: string)
	local backpack = player:WaitForChild("Backpack", 10)
	if not backpack then
		return
	end

	local characterTool = if player.Character then player.Character:FindFirstChild(toolName) else nil
	local existing = backpack:FindFirstChild(toolName) or characterTool
	if existing and existing:IsA("Tool") then
		existing.ToolTip = tooltip
		existing:SetAttribute("PartBreaker2TestTool", true)
		existing:SetAttribute("PartBreaker2DestroyerMode", mode)
		return
	end

	local tool = makeTool(toolName, mode, tooltip)
	tool.Parent = backpack
end

local function giveVisualizerTool(player: Player, toolName: string, mode: string, tooltip: string)
	local backpack = player:WaitForChild("Backpack", 10)
	if not backpack then
		return
	end

	local characterTool = if player.Character then player.Character:FindFirstChild(toolName) else nil
	local existing = backpack:FindFirstChild(toolName) or characterTool
	if existing and existing:IsA("Tool") then
		existing.ToolTip = tooltip
		existing:SetAttribute("PartBreaker2VisualizerTool", true)
		existing:SetAttribute("PartBreaker2VisualizerMode", mode)
		return
	end

	local tool = makeVisualizerTool(toolName, mode, tooltip)
	tool.Parent = backpack
end

local function giveTestTools(player: Player)
	giveTool(player, SPHERE_TOOL_NAME, SPHERE_MODE, "Click to spawn a PartBreaker2 sphere destroyer at your mouse")
	giveTool(player, SLICE_TOOL_NAME, SLICE_MODE, "Click the support-test wall to cut it with a horizontal OBB slice")
	giveVisualizerTool(player, GREEDY_VIS_TOOL_NAME, GREEDY_VIS_MODE, "Click to toggle greedy mesh coloring")
	giveVisualizerTool(player, ATTACHED_VIS_TOOL_NAME, ATTACHED_VIS_MODE, "Click to toggle attached chunk coloring")
end

local function ensureToolRemote(): RemoteEvent
	if toolRemote then
		return toolRemote
	end

	local existing = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
	if existing and existing:IsA("RemoteEvent") then
		toolRemote = existing
		return existing
	end

	local remote = Instance.new("RemoteEvent")
	remote.Name = REMOTE_NAME
	remote.Parent = ReplicatedStorage
	toolRemote = remote
	return remote
end

local function getEquippedTestTool(player: Player): Tool?
	local character = player.Character
	if not character then
		return nil
	end

	for _, child in character:GetChildren() do
		if child:IsA("Tool") and child:GetAttribute("PartBreaker2TestTool") == true then
			return child
		end
	end

	return nil
end

local function useToolAtMouse(partBreaker: any, player: Player, targetPosition: any)
	local equippedTool = getEquippedTestTool(player)
	if typeof(targetPosition) ~= "Vector3" or not equippedTool then
		return
	end

	local now = os.clock()
	local lastUse = lastUseByPlayer[player] or 0
	if now - lastUse < TOOL_COOLDOWN then
		return
	end
	lastUseByPlayer[player] = now

	local character = player.Character
	if not character then
		return
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	local offset = targetPosition - root.Position
	local distance = offset.Magnitude
	local direction = if distance > 0.001 then offset / distance else root.CFrame.LookVector
	local clampedDistance = math.min(distance, MAX_DESTROY_DISTANCE)
	local center = root.Position + direction * clampedDistance
	local mode = equippedTool:GetAttribute("PartBreaker2DestroyerMode")

	if mode == SLICE_MODE then
		local cframe = CFrame.new(center)
		createOBBPreview(cframe, SLICE_SIZE)
		partBreaker.destroyOBB(cframe, SLICE_SIZE, DESTROY_STRENGTH, direction * DESTROY_IMPULSE)
	else
		createDestroyerPreview(center)
		partBreaker.destroySphere(center, DESTROY_RADIUS, DESTROY_STRENGTH, direction * DESTROY_IMPULSE)
	end
end

function VoxelDestructionTest.start(partBreaker: any)
	VoxelDestructionTest.createRandomVoxelModel(partBreaker)
	VoxelDestructionTest.createSupportRefreshTestModel(partBreaker)
	ensureStarterTool(SPHERE_TOOL_NAME, SPHERE_MODE, "Click to spawn a PartBreaker2 sphere destroyer at your mouse")
	ensureStarterTool(SLICE_TOOL_NAME, SLICE_MODE, "Click the support-test wall to cut it with a horizontal OBB slice")
	ensureStarterVisualizerTool(GREEDY_VIS_TOOL_NAME, GREEDY_VIS_MODE, "Click to toggle greedy mesh coloring")
	ensureStarterVisualizerTool(ATTACHED_VIS_TOOL_NAME, ATTACHED_VIS_MODE, "Click to toggle attached chunk coloring")
	local remote = ensureToolRemote()
	remote.OnServerEvent:Connect(function(player: Player, targetPosition: any)
		useToolAtMouse(partBreaker, player, targetPosition)
	end)
	local network = getNetworkServer()
	if network and network.ToolActivated then
		network.ToolActivated.On(function(player: Player, targetPosition: Vector3)
			useToolAtMouse(partBreaker, player, targetPosition)
		end)
	end

	local function setupPlayer(player: Player)
		player.CharacterAdded:Connect(function()
			task.defer(giveTestTools, player)
		end)
		task.defer(giveTestTools, player)
	end

	for _, player in Players:GetPlayers() do
		setupPlayer(player)
	end

	Players.PlayerAdded:Connect(function(player)
		setupPlayer(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastUseByPlayer[player] = nil
	end)
end

return VoxelDestructionTest
