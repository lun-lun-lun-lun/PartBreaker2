--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VoxelDestructionTestClient = {}

local REMOTE_NAME = "PartBreaker2VoxelToolActivated"

local localPlayer = Players.LocalPlayer
local started = false
local boundTools: { [Tool]: boolean } = {}
local currentMouseByTool: { [Tool]: Mouse } = {}
local remote = nil :: RemoteEvent?
local networkClient = nil :: any?
local networkLoadAttempted = false

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
			warn(`PartBreaker2: failed to load Blink client module for test tool: {result}`)
		end
	end

	return networkClient
end

local function getRemote(): RemoteEvent?
	if remote then
		return remote
	end

	local found = ReplicatedStorage:WaitForChild(REMOTE_NAME, 10)
	if found and found:IsA("RemoteEvent") then
		remote = found
		return found
	end

	warn("PartBreaker2: voxel test tool remote was not found; mouse aiming disabled")
	return nil
end

local function isVoxelBreakerTool(instance: Instance): boolean
	return instance:IsA("Tool")
		and instance:GetAttribute("PartBreaker2TestTool") == true
end

local function bindTool(tool: Tool)
	if boundTools[tool] then
		return
	end
	boundTools[tool] = true

	tool.Equipped:Connect(function(mouse: Mouse)
		currentMouseByTool[tool] = mouse
	end)

	tool.Unequipped:Connect(function()
		currentMouseByTool[tool] = nil
	end)

	tool.Activated:Connect(function()
		local network = getNetworkClient()
		local mouse = currentMouseByTool[tool]
		if not mouse then
			return
		end

		if network and network.ToolActivated then
			(network.ToolActivated :: any).Fire(mouse.Hit.Position)
			return
		end

		local targetRemote = getRemote()
		if targetRemote then
			targetRemote:FireServer(mouse.Hit.Position)
		end
	end)

	tool.Destroying:Connect(function()
		boundTools[tool] = nil
		currentMouseByTool[tool] = nil
	end)
end

local function scanContainer(container: Instance?)
	if not container then
		return
	end

	for _, child in container:GetChildren() do
		if isVoxelBreakerTool(child) then
			bindTool(child :: Tool)
		end
	end
end

local function watchContainer(container: Instance?)
	if not container then
		return
	end

	scanContainer(container)
	container.ChildAdded:Connect(function(child)
		if isVoxelBreakerTool(child) then
			bindTool(child :: Tool)
		end
	end)
end

function VoxelDestructionTestClient.start()
	if started then
		return
	end
	started = true

	task.spawn(function()
		if not getNetworkClient() then
			getRemote()
		end
	end)
	watchContainer(localPlayer:WaitForChild("Backpack", 10))
	watchContainer(localPlayer.Character)

	localPlayer.CharacterAdded:Connect(function(character)
		watchContainer(character)
	end)
end

return VoxelDestructionTestClient
