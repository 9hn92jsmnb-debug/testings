local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local PhysicsService = game:GetService("PhysicsService")
local SimplePath = require(game.ReplicatedStorage.Modules["SimplePath (modified)"])

export type AnimationTracks = {
Idle: Animation?,
Aiming: Animation?,
Shooting: Animation?,
Reload: Animation?,
}

export type NPCConfig = {
FireRate: number?,
SpreadDegrees: number?,
BulletSpeed: number?,
AutoAimDistance: number?,
MinBurst: number?,
MaxBurst: number?,
ReloadThreshold: number?,
ReloadDuration: number?,
AccuracyRecovery: number?,
BurstInaccuracyGrowth: number?,
BulletSize: Vector3?,
BulletColor: Color3?,
Trail: boolean?,
TrailLifetime: number?,
TrailWidth: number?,
Damage: number?,
Animations: AnimationTracks?,
}

export type NPCState = {
Model: Model,
Root: BasePart?,
Humanoid: Humanoid?,
Animator: Animator?,
Gun: Instance?,
Target: Model?,
Config: NPCConfig,
FireCooldown: number,
BurstRemaining: number,
ReloadTimer: number,
Mag: number,
AccuracyBloom: number,
CurrentTrack: AnimationTrack?,
Path: any?,
PathGoal: Vector3?,
PathActive: boolean,
LastSeenVelocity: Vector3?,
StateTag: string,
}

local m = {}

local function createAnimation(id: string): Animation
local anim = Instance.new("Animation")
anim.AnimationId = id
return anim
end

local function normalizeAnimation(animation: Animation | string | number | nil): Animation?
if animation == nil then
return nil
end
if typeof(animation) == "Instance" then
local inst = animation :: Instance
if inst:IsA("Animation") then
return inst
end
return nil
end
if typeof(animation) == "string" then
return createAnimation(animation :: string)
end
if typeof(animation) == "number" then
return createAnimation("rbxassetid://" .. tostring(animation :: number))
end
return nil
end

local DEFAULT_ANIMATIONS: AnimationTracks = {
Idle = createAnimation("rbxassetid://98564293923592"),
Aiming = createAnimation("rbxassetid://117550659743277"),
Shooting = createAnimation("rbxassetid://109848498488419"),
Reload = createAnimation("rbxassetid://107885163606729"),
}

local DEFAULTS: NPCConfig = {
FireRate = 8,
SpreadDegrees = 4,
BulletSpeed = 320,
AutoAimDistance = 180,
MinBurst = 2,
MaxBurst = 5,
ReloadThreshold = 12,
ReloadDuration = 1.2,
AccuracyRecovery = 4,
BurstInaccuracyGrowth = 1.3,
BulletSize = Vector3.new(0.2, 0.2, 1.2),
BulletColor = Color3.fromRGB(255, 180, 130),
Trail = true,
TrailLifetime = 0.22,
TrailWidth = 0.13,
Damage = 15,
Animations = DEFAULT_ANIMATIONS,
}

local activeNPCs: { NPCState } = {}
local connection: RBXScriptConnection? = nil

local ignoreParams = OverlapParams.new()
ignoreParams.FilterType = Enum.RaycastFilterType.Blacklist

local function blendConfigs(config: NPCConfig?): NPCConfig
local result: NPCConfig = {}
for key, defaultValue in pairs(DEFAULTS) do
result[key] = if config and config[key] ~= nil then config[key] else defaultValue
end
local animations: AnimationTracks = {
Idle = DEFAULT_ANIMATIONS.Idle,
Aiming = DEFAULT_ANIMATIONS.Aiming,
Shooting = DEFAULT_ANIMATIONS.Shooting,
Reload = DEFAULT_ANIMATIONS.Reload,
}
if config and config.Animations then
animations.Idle = normalizeAnimation(config.Animations.Idle) or animations.Idle
animations.Aiming = normalizeAnimation(config.Animations.Aiming) or animations.Aiming
animations.Shooting = normalizeAnimation(config.Animations.Shooting) or animations.Shooting
animations.Reload = normalizeAnimation(config.Animations.Reload) or animations.Reload
end
result.Animations = animations
return result
end

local function stopTrack(state: NPCState)
if state.CurrentTrack then
state.CurrentTrack:Stop(0.1)
state.CurrentTrack = nil
end
end

local function playTrack(state: NPCState, animation: Animation?, shouldLoop: boolean?)
if not state.Animator or not animation then
return
end

local desiredLoop = shouldLoop ~= nil and shouldLoop or false
if state.CurrentTrack and state.CurrentTrack.Animation == animation then
state.CurrentTrack.Looped = desiredLoop
if not state.CurrentTrack.IsPlaying then
state.CurrentTrack:Play(0.12, 1, 1)
end
return
end

stopTrack(state)
local track = state.Animator:LoadAnimation(animation)
track.Priority = Enum.AnimationPriority.Action
track.Looped = desiredLoop
track:Play(0.12, 1, 1)
state.CurrentTrack = track
end

local function clamp01(v: number): number
if v < 0 then
return 0
elseif v > 1 then
return 1
end
return v
end

local function makeSpreadDirection(base: Vector3, spreadDegrees: number, bloom: number): Vector3
local cf = CFrame.lookAt(Vector3.zero, base)
local spreadRad = math.rad(spreadDegrees * bloom)
local yaw = (math.random() * 2 - 1) * spreadRad
local pitch = (math.random() * 2 - 1) * spreadRad * 0.6
local offset = CFrame.Angles(pitch, yaw, 0)
return (cf * offset).LookVector
end

local function spawnTrail(part: BasePart, direction: Vector3, config: NPCConfig)
if not config.Trail then
return
end

local attachment0 = Instance.new("Attachment")
attachment0.Position = Vector3.zero
attachment0.Parent = part

local attachment1 = Instance.new("Attachment")
attachment1.Position = direction.Unit * 1
attachment1.Parent = part

local trail = Instance.new("Trail")
trail.Attachment0 = attachment0
trail.Attachment1 = attachment1
trail.Color = ColorSequence.new(config.BulletColor)
trail.Lifetime = config.TrailLifetime or 0.2
trail.MinLength = 0.1
trail.Transparency = NumberSequence.new(0.15, 1)
trail.LightEmission = 0.8
trail.FaceCamera = true
trail.WidthScale = NumberSequence.new(config.TrailWidth or 0.1)
trail.Parent = part

Debris:AddItem(attachment0, config.TrailLifetime or 0.2)
Debris:AddItem(attachment1, config.TrailLifetime or 0.2)
Debris:AddItem(trail, config.TrailLifetime or 0.2)
end

local function isNPCModel(model: Model?): boolean
if not model then
return false
end
for _, state in ipairs(activeNPCs) do
if state.Model == model then
return true
end
end
return false
end

local function computeAimOrigin(state: NPCState): BasePart?
if state.Gun then
if state.Gun:IsA("Model") then
local primary = state.Gun.PrimaryPart or state.Gun:FindFirstChildWhichIsA("BasePart")
if primary then
return primary
end
elseif state.Gun:IsA("Tool") then
local handle = state.Gun:FindFirstChildWhichIsA("BasePart")
if handle then
return handle
end
end
end
return state.Root
end

local function spawnBullet(from: BasePart, direction: Vector3, speed: number, config: NPCConfig, shooter: NPCState)
local bullet = Instance.new("Part")
bullet.Size = config.BulletSize or Vector3.new(0.2, 0.2, 1.2)
bullet.Material = Enum.Material.Neon
bullet.Color = config.BulletColor or Color3.fromRGB(255, 180, 130)
bullet.CanCollide = false
bullet.CanTouch = true
bullet.CollisionGroup = "Bullets"
bullet.CFrame = CFrame.lookAt(from.Position, from.Position + direction)
bullet.Velocity = direction.Unit * speed
bullet.Parent = workspace

local dealtDamage = false
bullet.Touched:Connect(function(hit)
if dealtDamage then
return
end
local character = hit:FindFirstAncestorOfClass("Model")
if not character or character == shooter.Model or isNPCModel(character) then
return
end
local humanoid = character:FindFirstChildOfClass("Humanoid")
if humanoid and humanoid.Health > 0 then
dealtDamage = true
humanoid:TakeDamage(config.Damage or DEFAULTS.Damage)
bullet:Destroy()
end
end)

spawnTrail(bullet, direction, config)
Debris:AddItem(bullet, 4)
end

local function predictTargetPosition(targetRoot: BasePart, lastVel: Vector3?, bulletSpeed: number, origin: Vector3): Vector3
local targetPos = targetRoot.Position
if not lastVel then
return targetPos
end

local toTarget = targetPos - origin
local distance = toTarget.Magnitude
local time = distance / bulletSpeed
return targetPos + lastVel * time
end

local function hasLineOfSight(origin: BasePart, target: BasePart, model: Model): boolean
local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Blacklist
params.FilterDescendantsInstances = { model }
local result = workspace:Raycast(origin.Position, (target.Position - origin.Position), params)
return not result or result.Instance:IsDescendantOf(target.Parent)
end

local function tagCharacter(model: Model)
for _, part in ipairs(model:GetDescendants()) do
if part:IsA("BasePart") then
PhysicsService:SetPartCollisionGroup(part, "NPC")
end
end
end

local function refreshAttachments(state: NPCState)
local gunValue = state.Model:FindFirstChild("Gun")
local gunInstance = gunValue and gunValue:IsA("ObjectValue") and gunValue.Value or nil
state.Gun = gunInstance
end

local function reloadIfNeeded(state: NPCState)
if state.ReloadTimer > 0 then
return true
end

if state.Mag <= 0 or (state.Mag < state.Config.ReloadThreshold and math.random() < 0.35) then
local reloadAnim = state.Config.Animations and state.Config.Animations.Reload
local duration = state.Config.ReloadDuration
if state.Animator and reloadAnim then
stopTrack(state)
local track = state.Animator:LoadAnimation(reloadAnim)
track.Priority = Enum.AnimationPriority.Action
track.Looped = false
track:Play(0.1, 1, 1)
state.CurrentTrack = track
if track.Length and track.Length > 0 then
duration = math.max(duration, track.Length)
end
else
playTrack(state, reloadAnim, false)
end

state.ReloadTimer = duration
state.Mag = state.Config.ReloadThreshold * 2
return true
end
return false
end

local function updateShooting(state: NPCState, dt: number)
local muzzle = computeAimOrigin(state)
if not muzzle then
return
end

state.FireCooldown = math.max(0, state.FireCooldown - dt)
state.ReloadTimer = math.max(0, state.ReloadTimer - dt)
state.AccuracyBloom = math.max(1, state.AccuracyBloom - dt * state.Config.AccuracyRecovery)

if not state.Target or not state.Target.Parent then
return
end

local targetRoot = state.Target:FindFirstChild("HumanoidRootPart")
if not targetRoot then
return
end

state.LastSeenVelocity = targetRoot.AssemblyLinearVelocity
if state.ReloadTimer > 0 then
playTrack(state, state.Config.Animations and state.Config.Animations.Reload, false)
return
end

if reloadIfNeeded(state) then
return
end

if state.FireCooldown > 0 then
return
end

if state.BurstRemaining <= 0 then
state.BurstRemaining = math.random(state.Config.MinBurst, state.Config.MaxBurst)
end

local origin = computeAimOrigin(state)
if not origin then
return
end

if not hasLineOfSight(origin, targetRoot, state.Model) then
return
end

local predicted = predictTargetPosition(targetRoot, state.LastSeenVelocity, state.Config.BulletSpeed, origin.Position)
local desired = (predicted - origin.Position).Unit
local spreadDir = makeSpreadDirection(desired, state.Config.SpreadDegrees, state.AccuracyBloom)
spawnBullet(muzzle, spreadDir, state.Config.BulletSpeed, state.Config, state)
playTrack(state, state.Config.Animations and state.Config.Animations.Shooting, true)

state.FireCooldown = 1 / state.Config.FireRate
state.BurstRemaining -= 1
state.Mag -= 1
state.AccuracyBloom += state.Config.BurstInaccuracyGrowth
end

local function pickTarget(state: NPCState)
if state.Target and state.Target.Parent then
return
end

local root = state.Root
if not root then
return
end

local closest: Model? = nil
local closestDist = math.huge

for _, descendant in ipairs(workspace:GetDescendants()) do
if descendant:IsA("Humanoid") and descendant.Health > 0 then
local char = descendant.Parent
if char and char ~= state.Model and char:IsA("Model") and not isNPCModel(char) then
local hrp = char:FindFirstChild("HumanoidRootPart")
if hrp then
local dist = (hrp.Position - root.Position).Magnitude
if dist < state.Config.AutoAimDistance and dist < closestDist then
closestDist = dist
closest = char
end
end
end
end
end

state.Target = closest
end

local function setPathGoal(state: NPCState, goal: Vector3)
if state.PathGoal and (state.PathGoal - goal).Magnitude < 0.5 then
return
end

state.PathGoal = goal
state.PathActive = true
if state.Path then
state.Path:Run(goal)
end
end

local function stopPath(state: NPCState)
if state.PathActive and state.Path then
state.Path:Stop()
end
state.PathActive = false
state.PathGoal = nil
end

local function updateMovement(state: NPCState)
if not state.Root then
stopPath(state)
return
end

if not state.Target or not state.Target.Parent then
stopPath(state)
state.StateTag = "Idle"
playTrack(state, state.Config.Animations and state.Config.Animations.Idle, true)
return
end

local targetRoot = state.Target:FindFirstChild("HumanoidRootPart")
if not targetRoot then
stopPath(state)
state.StateTag = "Idle"
return
end

setPathGoal(state, targetRoot.Position)
state.StateTag = "Chasing"
playTrack(state, state.Config.Animations and state.Config.Animations.Aiming, true)
end

local function ensureConnection()
if connection then
return
end

connection = RunService.Heartbeat:Connect(function(dt)
for index = #activeNPCs, 1, -1 do
local state = activeNPCs[index]
if not state.Model.Parent or not state.Humanoid or state.Humanoid.Health <= 0 then
stopPath(state)
if state.CurrentTrack then
state.CurrentTrack:Stop()
end
table.remove(activeNPCs, index)
else
pickTarget(state)
updateMovement(state)
updateShooting(state, dt)
end
end

if #activeNPCs == 0 and connection then
connection:Disconnect()
connection = nil
end
end)
end

function m.AddNPC(model: Model, config: NPCConfig?)
assert(model, "Model is required")
local humanoid = model:FindFirstChildWhichIsA("Humanoid")
local animator = humanoid and humanoid:FindFirstChildWhichIsA("Animator")
local root = model:FindFirstChild("HumanoidRootPart")

local state: NPCState = {
Model = model,
Root = root,
Humanoid = humanoid,
Animator = animator,
Gun = nil,
Target = nil,
Config = blendConfigs(config),
FireCooldown = 0,
BurstRemaining = 0,
ReloadTimer = 0,
Mag = 30,
AccuracyBloom = 1,
CurrentTrack = nil,
Path = nil,
PathGoal = nil,
PathActive = false,
LastSeenVelocity = nil,
StateTag = "Idle",
}

tagCharacter(model)
refreshAttachments(state)

local path = SimplePath.new(model)
path.Visualize = false
state.Path = path

table.insert(activeNPCs, state)
ensureConnection()
return state
end

function m.SetTarget(model: Model, target: Model?)
for _, state in ipairs(activeNPCs) do
if state.Model == model then
if target and isNPCModel(target) then
return
end
state.Target = target
if target and target:FindFirstChild("HumanoidRootPart") then
setPathGoal(state, target.HumanoidRootPart.Position)
end
return
end
end
end

function m.RemoveNPC(model: Model)
for index = #activeNPCs, 1, -1 do
local state = activeNPCs[index]
if state.Model == model then
stopPath(state)
if state.CurrentTrack then
state.CurrentTrack:Stop()
end
table.remove(activeNPCs, index)
break
end
end

if #activeNPCs == 0 and connection then
connection:Disconnect()
connection = nil
end
end

function m.RefreshGun(model: Model)
for _, state in ipairs(activeNPCs) do
if state.Model == model then
refreshAttachments(state)
return
end
end
end

function m.ListNPCs(): { NPCState }
return activeNPCs
end

function m.Reset()
for index = #activeNPCs, 1, -1 do
m.RemoveNPC(activeNPCs[index].Model)
end
end

return m
