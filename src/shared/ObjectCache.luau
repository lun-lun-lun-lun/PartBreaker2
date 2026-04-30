--!strict
--!native
local FAR_AWAY_CFRAME = CFrame.new(2^24, 2^24, 2^24)
local EXPAND_BY_AMOUNT = 50

local MovingParts = table.create(10_000) :: { BasePart }
local MovingCFrames = table.create(10_000) :: { CFrame }

local ScheduledUpdate = false
local function UpdateMovement()
	while true do
		workspace:BulkMoveTo(MovingParts, MovingCFrames, Enum.BulkMoveMode.FireCFrameChanged)

		table.clear(MovingParts)
		table.clear(MovingCFrames)

		ScheduledUpdate = false
		coroutine.yield()
	end
end
local UpdateMovementThread = coroutine.create(UpdateMovement)

local Cache = {}
Cache.__index = Cache

type CacheData = {
	CacheHolder: Folder,
	_ExpandAmount: number,
	_Template: BasePart | Model,
	_FreeObjects: { BasePart },
	_Objects: { [BasePart]: boolean },
	_IsTemplateModel: boolean,
	_PreallocatedAmount: number,
}

export type CacheInstance = CacheData & {
	_GetNew: (CacheInstance, number, boolean) -> BasePart,
	GetPart: (CacheInstance, CFrame?) -> BasePart,
	ReturnPart: (CacheInstance, BasePart) -> (),
	Update: (CacheInstance) -> (),
	ExpandCache: (CacheInstance, number) -> (),
	SetExpandAmount: (CacheInstance, number) -> (),
	IsInUse: (CacheInstance, BasePart) -> boolean,
	Destroy: (CacheInstance) -> (),
}

local function getObjectRoot(object: BasePart | Model, isModel: boolean): BasePart
	if isModel then
		local root = (object :: Model).PrimaryPart
		assert(root ~= nil, "ObjectCache: cloned model is missing PrimaryPart")
		return root
	end

	return object :: BasePart
end

function Cache._GetNew(self: CacheInstance, Amount: number, Warn: boolean): BasePart
	if Warn then
		warn(`ObjectCache: Cache retrieval exceeded preallocated amount! expanding by {Amount}...`)
	end

	local FreeObjectsContainer = self._FreeObjects
	local InitialLength = #self._FreeObjects
	local CacheHolder = self.CacheHolder

	local IsTemplateModel = self._IsTemplateModel
	local Template: Model | BasePart = self._Template

	local TargetParts = table.create(Amount) :: { BasePart }
	local TargetCFrames = table.create(Amount) :: { CFrame }
	local AddedObjects = table.create(Amount) :: { Instance }
	for Index = InitialLength + 1, InitialLength + Amount do
		local Object = (Template:Clone() :: any) :: BasePart | Model
		local ObjectRoot = getObjectRoot(Object, IsTemplateModel)

		FreeObjectsContainer[Index] = ObjectRoot

		local OffsetIndex = Index - InitialLength
		TargetParts[OffsetIndex] = ObjectRoot
		TargetCFrames[OffsetIndex] = FAR_AWAY_CFRAME
		AddedObjects[OffsetIndex] = Object
	end

	workspace:BulkMoveTo(TargetParts, TargetCFrames, Enum.BulkMoveMode.FireCFrameChanged)

	for _, Object in AddedObjects do
		Object.Parent = CacheHolder
	end

	local part = table.remove(FreeObjectsContainer)
	assert(part ~= nil, "ObjectCache: failed to allocate a new object")
	return part
end

function Cache.GetPart(self: CacheInstance, PartCFrame: CFrame?): BasePart
	local Part = table.remove(self._FreeObjects) or Cache._GetNew(self, self._ExpandAmount, true)

	self._Objects[Part] = nil
	if PartCFrame then
		table.insert(MovingParts, Part)
		table.insert(MovingCFrames, PartCFrame)

		if not ScheduledUpdate then
			ScheduledUpdate = true
			task.defer(UpdateMovementThread)
		end
	end

	return Part
end
function Cache.ReturnPart(self: CacheInstance, Part: BasePart)
	if self._Objects[Part] then
		return
	end

	self._Objects[Part] = true

	table.insert(self._FreeObjects, Part)
	table.insert(MovingParts, Part)
	table.insert(MovingCFrames, FAR_AWAY_CFRAME)

	if not ScheduledUpdate then
		ScheduledUpdate = true
		task.defer(UpdateMovementThread)
	end
end

function Cache.Update(_self: CacheInstance)
	task.spawn(UpdateMovementThread)
end

function Cache.ExpandCache(self: CacheInstance, Amount: number)
	assert(typeof(Amount) ~= "number" or Amount >= 0, `Invalid argument #1 to 'ObjectCache:ExpandCache' (positive number expected, got {typeof(Amount)})`)
	Cache._GetNew(self, Amount, false)
end
function Cache.SetExpandAmount(self: CacheInstance, Amount: number)
	assert(typeof(Amount) ~= "number" or Amount > 0, `Invalid argument #1 to 'ObjectCache:SetExpandAmount' (positive number expected, got {typeof(Amount)})`)
	self._ExpandAmount = Amount
end

function Cache.IsInUse(self: CacheInstance, Object: BasePart): boolean
	return self._Objects[Object] == nil
end

function Cache.Destroy(self: CacheInstance)
	self.CacheHolder:Destroy()
end

local function GetCacheContainer(): Folder
	local CacheHolder = Instance.new("Folder")
	CacheHolder.Name = "ObjectCache"

	return CacheHolder
end

local Constructor = {}
function Constructor.new(Template: BasePart | Model, CacheSize: number?, CachesContainer: Instance?): CacheInstance
	local TemplateType = typeof(Template)
	assert(TemplateType == "Instance", `Invalid argument #1 to 'ObjectCache.new' (BasePart expected, got {TemplateType})`)

	assert(Template:IsA("BasePart") or Template:IsA("Model"), `Invalid argument #1 to 'ObjectCache.new' (BasePart or Model expected, got {Template.ClassName})`)
	assert(Template.Archivable, `ObjectCache: Cannot use template object provided, as it has Archivable set to false.`)
	if Template:IsA("Model") then
		assert(Template.PrimaryPart ~= nil, `Invalid Template provided to 'ObjectCache.new': Model has no PrimaryPart set!`)
	end

	local CacheSizeType = typeof(CacheSize)
	assert(CacheSize == nil or CacheSizeType == "number", `Invalid argument #2 to 'ObjectCache.new' (number expected, got {CacheSizeType})`)
	assert(CacheSize == nil or CacheSize >= 0, `Invalid argument #2 to 'ObjectCache.new' (positive number expected, got {CacheSize})`)

	local ContainerType = typeof(CachesContainer)
	assert(CachesContainer == nil or ContainerType == "Instance", `Invalid argument #3 to 'ObjectCache.new' (Instance expected, got {ContainerType})`)

	local PreallocAmount = CacheSize or 10
	local CacheParent = GetCacheContainer()

	local Objects: {[BasePart]: boolean} = {}
	local TargetParts = table.create(PreallocAmount) :: { BasePart }

	local IsTemplateModel = Template:IsA("Model")
	for Index = 1, PreallocAmount do
		local Object = (Template:Clone() :: any) :: BasePart | Model
		local ObjectRoot = getObjectRoot(Object, IsTemplateModel)

		TargetParts[Index] = ObjectRoot

		ObjectRoot.CFrame = FAR_AWAY_CFRAME
		local ObjectInstance = Object :: Instance
		ObjectInstance.Parent = CacheParent
	end

	CacheParent.Parent = CachesContainer or workspace

	local self = ({
		CacheHolder = CacheParent,
		_ExpandAmount = EXPAND_BY_AMOUNT,
		_Template = Template,
		_FreeObjects = TargetParts,
		_Objects = Objects,
		_IsTemplateModel = IsTemplateModel,
		_PreallocatedAmount = PreallocAmount,
	} :: any) :: CacheData
	return (setmetatable(self, Cache) :: any) :: CacheInstance
end

return Constructor
