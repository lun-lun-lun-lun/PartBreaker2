--!strict

local RunService = game:GetService("RunService")

export type ForceId = number

export type HitInfo = {
	instance: BasePart,
	position: Vector3,
	normal: Vector3,
	distance: number,
}

export type Config = {
	part: BasePart,
	mass: number?,
	radius: number?,
	velocity: Vector3?,
	forces: { Vector3 }?,
	filter: { Instance }?,
	filterType: Enum.RaycastFilterType?,
	collisionGroup: string?,
	onHit: ((HitInfo) -> ())?,
	onDestroy: (() -> ())?,
	lifetime: number?,
	bounciness: number?,
	minBounceSpeed: number?,
	maxBounces: number?,
}

local Projectile = {}
Projectile.__index = Projectile

export type Projectile = typeof(setmetatable(
	{} :: {
		t0: number,
		r0: Vector3,
		v0: Vector3,
		aNet: Vector3,
		mass: number,
		radius: number,
		forces: { [ForceId]: Vector3 },
		nextForceId: ForceId,
		facingDirection: Vector3,
		part: BasePart,
		overlapParams: OverlapParams,
		raycastParams: RaycastParams,
		onHit: ((HitInfo) -> ())?,
		onDestroy: (() -> ())?,
		spawnTime: number,
		lifetime: number?,
		alive: boolean,
		lastSampledPos: Vector3,
		bounciness: number,
		minBounceSpeed: number,
		bouncesRemaining: number?,
		resting: boolean,
	},
	Projectile
))

local active: { [Projectile]: true } = {}

local MIN_DISPLACEMENT = 1e-5
local MAX_COLLISIONS_PER_STEP = 4
local MAX_OVERLAP_RECOVERY_STEPS = 3
local OVERLAP_RECOVERY_PADDING = 0.01
local NORMAL_FALLBACK_EPSILON = 1e-4
local ORIENTATION_EPSILON = 1e-4
local BOUNCE_CLEARANCE = 0.05
local VELOCITY_EPSILON = 2
local ROLLING_FRICTION_DECELERATION = 60
local ROLLING_STOP_SPEED = 0.5

local function recomputeAcceleration(self: Projectile)
	local sum = Vector3.zero
	for _, f in self.forces do
		sum += f
	end
	self.aNet = sum / self.mass
end

local function reSnapshot(self: Projectile, now: number)
	local dt = now - self.t0
	self.r0 = self.r0 + self.v0 * dt + self.aNet * (0.5 * dt * dt)
	self.v0 = self.v0 + self.aNet * dt
	self.t0 = now
end

function Projectile.samplePosition(self: Projectile): Vector3
	local dt = os.clock() - self.t0
	return self.r0 + self.v0 * dt + self.aNet * (0.5 * dt * dt)
end

function Projectile.sampleVelocity(self: Projectile): Vector3
	local dt = os.clock() - self.t0
	return self.v0 + self.aNet * dt
end

function Projectile.addForce(self: Projectile, force: Vector3): ForceId
	reSnapshot(self, os.clock())
	local id = self.nextForceId
	self.nextForceId = id + 1
	self.forces[id] = force
	recomputeAcceleration(self)
	return id
end

function Projectile.removeForce(self: Projectile, id: ForceId)
	local existing: Vector3? = self.forces[id]
	if existing == nil then
		return
	end
	reSnapshot(self, os.clock())
	self.forces[id] = nil
	recomputeAcceleration(self)
end

function Projectile.setMass(self: Projectile, mass: number)
	reSnapshot(self, os.clock())
	self.mass = mass
	recomputeAcceleration(self)
end

function Projectile.setVelocity(self: Projectile, velocity: Vector3)
	reSnapshot(self, os.clock())
	self.v0 = velocity
	if velocity.Magnitude > ORIENTATION_EPSILON then
		self.facingDirection = velocity.Unit
	end
end

function Projectile.setRadius(self: Projectile, radius: number)
	self.radius = radius
end

function Projectile.destroy(self: Projectile)
	if not self.alive then
		return
	end
	self.alive = false
	active[self] = nil
	local cb = self.onDestroy
	if cb then
		task.spawn(cb)
	end
end

local ProjectileSim = {}

local function setPose(self: Projectile, position: Vector3, velocity: Vector3)
	if velocity.Magnitude > ORIENTATION_EPSILON then
		self.facingDirection = velocity.Unit
	end

	local forward = self.facingDirection
	local up = if math.abs(forward:Dot(Vector3.yAxis)) > 0.99 then Vector3.zAxis else Vector3.yAxis
	self.part.CFrame = CFrame.lookAt(position, position + forward, up)
	self.lastSampledPos = position
end

local function setState(self: Projectile, position: Vector3, velocity: Vector3, now: number)
	self.r0 = position
	self.v0 = velocity
	self.t0 = now
	setPose(self, position, velocity)
end

local function enterRest(self: Projectile, contactCenter: Vector3, now: number)
	self.r0 = contactCenter
	self.v0 = Vector3.zero
	self.aNet = Vector3.zero
	self.t0 = now
	self.resting = true
	setPose(self, contactCenter, Vector3.zero)
end

function ProjectileSim.new(config: Config): Projectile
	local part = config.part
	local size = part.Size
	local radius = config.radius or math.min(size.X, size.Y, size.Z) * 0.5
	local initialVelocity = config.velocity or Vector3.zero
	local initialFacingDirection = if initialVelocity.Magnitude > ORIENTATION_EPSILON then initialVelocity.Unit else part.CFrame.LookVector

	local rp = RaycastParams.new()
	rp.FilterType = config.filterType or Enum.RaycastFilterType.Exclude
	local filter: { Instance } = { part }
	if config.filter then
		for _, inst in config.filter do
			table.insert(filter, inst)
		end
	end
	rp.FilterDescendantsInstances = filter
	if config.collisionGroup then
		rp.CollisionGroup = config.collisionGroup
	end

	local op = OverlapParams.new()
	op.FilterType = rp.FilterType
	op.FilterDescendantsInstances = filter
	op.MaxParts = 8
	if config.collisionGroup then
		op.CollisionGroup = config.collisionGroup
	end

	local now = os.clock()
	local self = setmetatable({
		t0 = now,
		r0 = part.Position,
		v0 = initialVelocity,
		aNet = Vector3.zero,
		mass = config.mass or 1,
		radius = radius,
		forces = {} :: { [ForceId]: Vector3 },
		nextForceId = 1 :: ForceId,
		facingDirection = initialFacingDirection,
		part = part,
		overlapParams = op,
		raycastParams = rp,
		onHit = config.onHit,
		onDestroy = config.onDestroy,
		spawnTime = now,
		lifetime = config.lifetime,
		alive = true,
		lastSampledPos = part.Position,
		bounciness = config.bounciness or 0,
		minBounceSpeed = config.minBounceSpeed or 2,
		bouncesRemaining = config.maxBounces,
		resting = false,
	}, Projectile) :: Projectile

	if config.forces then
		for _, f in config.forces do
			self.forces[self.nextForceId] = f
			self.nextForceId = self.nextForceId + 1
		end
		recomputeAcceleration(self)
	end

	part.Anchored = true
	part.CanCollide = false

	if initialVelocity.Magnitude > ORIENTATION_EPSILON then
		local up = if math.abs(initialFacingDirection:Dot(Vector3.yAxis)) > 0.99 then Vector3.zAxis else Vector3.yAxis
		part.CFrame = CFrame.lookAt(part.Position, part.Position + initialFacingDirection, up)
	end

	active[self] = true
	return self
end

function ProjectileSim.gravityForce(mass: number): Vector3
	return Vector3.new(0, -workspace.Gravity * mass, 0)
end

local function snapScalar(value: number): number
	if math.abs(value) < VELOCITY_EPSILON then
		return 0
	end

	return value
end

local function integratePosition(position: Vector3, velocity: Vector3, acceleration: Vector3, dt: number): Vector3
	return position + velocity * dt + acceleration * (0.5 * dt * dt)
end

local function integrateVelocity(velocity: Vector3, acceleration: Vector3, dt: number): Vector3
	return velocity + acceleration * dt
end

local function projectOntoSurface(vector: Vector3, normal: Vector3): Vector3
	return vector - normal * vector:Dot(normal)
end

local function recoverFromOverlap(self: Projectile, position: Vector3, preferredNormal: Vector3?): (Vector3, Vector3?)
	local recoveredPosition = position
	local recoveryNormal = preferredNormal

	for _ = 1, MAX_OVERLAP_RECOVERY_STEPS do
		local overlaps = workspace:GetPartBoundsInRadius(recoveredPosition, self.radius + OVERLAP_RECOVERY_PADDING, self.overlapParams)
		local deepestPenetration = 0
		local deepestNormal = nil :: Vector3?

		for _, overlap in overlaps do
			if overlap:IsA("BasePart") then
				local closestPoint = overlap:GetClosestPointOnSurface(recoveredPosition)
				local offset = recoveredPosition - closestPoint
				local distance = offset.Magnitude
				local normal = if distance > NORMAL_FALLBACK_EPSILON then offset / distance else recoveryNormal

				if normal == nil then
					local fromCenter = recoveredPosition - overlap.Position
					normal = if fromCenter.Magnitude > NORMAL_FALLBACK_EPSILON then fromCenter.Unit else Vector3.yAxis
				end

				local penetration = self.radius + OVERLAP_RECOVERY_PADDING - distance
				if penetration > deepestPenetration then
					deepestPenetration = penetration
					deepestNormal = normal
				end
			end
		end

		if deepestNormal == nil or deepestPenetration <= 0 then
			return recoveredPosition, recoveryNormal
		end

		recoveredPosition += deepestNormal * deepestPenetration
		recoveryNormal = deepestNormal
	end

	return recoveredPosition, recoveryNormal
end

local function step(self: Projectile, now: number, _frameDt: number)
	if not self.alive or self.resting then
		return
	end

	if self.lifetime and (now - self.spawnTime) >= self.lifetime then
		self:destroy()
		return
	end

	if self.part.Parent == nil then
		self:destroy()
		return
	end

	local remainingDt = now - self.t0
	if remainingDt <= 0 then
		return
	end

	local position = self.r0
	local velocity = self.v0
	local bouncesRemaining = self.bouncesRemaining
	local recoveryNormal = nil :: Vector3?
	local collisionsProcessed = 0

	while remainingDt > 0 do
		position, recoveryNormal = recoverFromOverlap(self, position, recoveryNormal)

		local nextPos = integratePosition(position, velocity, self.aNet, remainingDt)
		local displacement = nextPos - position
		local displacementMagnitude = displacement.Magnitude

		if displacementMagnitude <= MIN_DISPLACEMENT then
			position = nextPos
			velocity = integrateVelocity(velocity, self.aNet, remainingDt)
			remainingDt = 0
			break
		end

		local result = workspace:Spherecast(position, self.radius, displacement, self.raycastParams)
		if not result then
			position = nextPos
			velocity = integrateVelocity(velocity, self.aNet, remainingDt)
			remainingDt = 0
			break
		end

		collisionsProcessed += 1
		if collisionsProcessed > MAX_COLLISIONS_PER_STEP then
			break
		end

		local travelFraction = math.clamp(result.Distance / displacementMagnitude, 0, 1)
		local travelDt = remainingDt * travelFraction
		local normal = result.Normal
		local hitPosition = result.Position
		local centerAtImpact = position + displacement * travelFraction
		local settledCenter = centerAtImpact + normal * BOUNCE_CLEARANCE
		local vAtImpact = integrateVelocity(velocity, self.aNet, travelDt)
		recoveryNormal = normal

		local cb = self.onHit
		if cb then
			task.spawn(cb, {
				instance = result.Instance,
				position = hitPosition,
				normal = normal,
				distance = result.Distance,
			})
		end

		local intoSurface = vAtImpact:Dot(normal)
		local canBounce = self.bounciness > 0
			and intoSurface < 0
			and (bouncesRemaining == nil or bouncesRemaining > 0)

		if canBounce then
			local normalVelocity = normal * intoSurface
			local tangentialVelocity = vAtImpact - normalVelocity
			local tangentialSpeed = tangentialVelocity.Magnitude
			local bouncedNormalSpeed = snapScalar(-intoSurface * self.bounciness)
			local remainingAfterImpact = remainingDt - travelDt
			local tangentialAcceleration = projectOntoSurface(self.aNet, normal)

			if bouncedNormalSpeed < self.minBounceSpeed then
				local rollingAcceleration = tangentialAcceleration
				if tangentialSpeed > 0 then
					rollingAcceleration -= tangentialVelocity.Unit * ROLLING_FRICTION_DECELERATION
				end

				local rollingVelocity = tangentialVelocity + rollingAcceleration * remainingAfterImpact
				rollingVelocity = projectOntoSurface(rollingVelocity, normal)
				if tangentialSpeed > 0 and rollingVelocity:Dot(tangentialVelocity) < 0 then
					rollingVelocity = Vector3.zero
				end

				local rollingPosition = integratePosition(settledCenter, tangentialVelocity, rollingAcceleration, remainingAfterImpact)
				if rollingVelocity.Magnitude <= ROLLING_STOP_SPEED then
					if bouncesRemaining ~= nil then
						self.bouncesRemaining = bouncesRemaining
					end
					enterRest(self, rollingPosition, now)
					return
				end

				position = rollingPosition
				velocity = rollingVelocity
				remainingDt = 0
				break
			end

			local snappedTangentialVelocity = if tangentialSpeed < VELOCITY_EPSILON then Vector3.zero else tangentialVelocity
			local newV = snappedTangentialVelocity + normal * bouncedNormalSpeed
			local aIntoSurface = math.max(0, -self.aNet:Dot(normal))
			local nextFall = 0.5 * aIntoSurface * remainingAfterImpact * remainingAfterImpact - bouncedNormalSpeed * remainingAfterImpact
			local nudgeAmount = math.max(BOUNCE_CLEARANCE, nextFall * 3 + BOUNCE_CLEARANCE)

			position = centerAtImpact + normal * nudgeAmount
			velocity = newV
			remainingDt = remainingAfterImpact

			if bouncesRemaining ~= nil then
				bouncesRemaining -= 1
			end

			if remainingDt <= 1e-6 then
				remainingDt = 0
			end

			continue
		end

		if self.bounciness > 0 then
			if bouncesRemaining ~= nil then
				self.bouncesRemaining = bouncesRemaining
			end
			enterRest(self, settledCenter, now)
			return
		end

		if bouncesRemaining ~= nil then
			self.bouncesRemaining = bouncesRemaining
		end
		self.r0 = centerAtImpact
		self.v0 = vAtImpact
		self.t0 = now
		self.part.CFrame = CFrame.new(centerAtImpact)
		self.lastSampledPos = centerAtImpact
		self:destroy()
		return
	end

	if bouncesRemaining ~= nil then
		self.bouncesRemaining = bouncesRemaining
	end
	setState(self, position, velocity, now)
end

RunService.Heartbeat:Connect(function(frameDt)
	local now = os.clock()
	for projectile in active do
		step(projectile, now, frameDt)
	end
end)

return ProjectileSim
