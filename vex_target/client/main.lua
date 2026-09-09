-- ============================================================================
-- VEX TARGET — client/main.lua
--
-- Consolidated client-side entry point. Functionally identical to the
-- previous client/{core,raycast,reticle,bridge,watchdog}.lua split — this is
-- a structural merge into one file, not a rewrite. Section banners below
-- mark where each former file's content lives, in the same dependency order
-- fxmanifest.lua used to load them in (core -> raycast -> reticle -> bridge
-- -> watchdog), since later sections reference functions/tables the earlier
-- sections define.
--
-- The former per-file split still has a reason to exist if this resource
-- grows further (easier isolated diffs, clearer ownership per concern) —
-- this merge is purely to satisfy a single-file client/main.lua deliverable
-- without discarding any of the working, already-server-integrated logic.
-- ============================================================================

VexTarget = VexTarget or {}

-- ============================================================================
-- SECTION: registry, state, public registration exports
-- (formerly client/core.lua)
-- ============================================================================

VexTarget.TargetEntities = {
    Models = {},

    Peds = {
        ByModel = {},
        ByNetId = {}
    },

    Vehicles = {
        ByModel = {},
        ByNetId = {},
        ByClass = {}
    }
}

VexTarget.State = {
    active = false,
    activationHeld = false,
    selectionHeld = false,

    raycastMode = Config.DefaultRaycastMode,

    currentTarget = nil,

    lastResolved = {
        entity = 0,
        options = nil,
        sourceType = nil,
        sourceKey = nil,
        conditionResults = {},
        conditionsPassedAt = 0
    }
}

VexTarget.VehicleClassCache = {}

-- Promoted above the raycast section (rather than kept private inside the
-- watchdog section, where it originally lived as a local) so Raycast()'s
-- defensive poll loop below can bail out the instant the activation key is
-- released mid-probe, instead of only noticing on the NEXT Tier B iteration.
-- Behavior is unchanged — this is the same non-native / native-control
-- branching as before, just callable from both places.
function VexTarget.IsActivationPressed()
    if not Config.Activation.UseNativeControl then
        return VexTarget.State.activationHeld == true
    end

    local hash = Config.Activation.NativeControlHash

    if hash == nil then
        return false
    end

    local group = Config.Activation.ControlGroup

    return IsControlPressed(group, hash)
        or IsDisabledControlPressed(group, hash)
end

local function now()
    return GetGameTimer()
end

local function normalizeHash(model)
    local modelType = type(model)

    if modelType == 'number' then
        return model
    end

    if modelType == 'string' then
        return GetHashKey(model)
    end

    return nil
end

local function normalizeModelArray(models)
    if type(models) == 'string' or type(models) == 'number' then
        return { models }
    end

    if type(models) ~= 'table' then
        return {}
    end

    return models
end

local function cloneMetadata(metadata)
    if type(metadata) ~= 'table' then
        return metadata
    end

    local result = {}

    for key, value in pairs(metadata) do
        if type(value) == 'table' then
            result[key] = cloneMetadata(value)
        else
            result[key] = value
        end
    end

    return result
end

local function validateOptions(targetOptions)
    if type(targetOptions) ~= 'table' then
        return nil, 'targetOptions must be an ordered array'
    end

    local options = {}
    local ids = {}

    for index, option in ipairs(targetOptions) do
        if type(option) ~= 'table' then
            return nil, ('target option #%d must be a table'):format(index)
        end

        if type(option.id) ~= 'string' or option.id == '' then
            return nil, ('target option #%d requires a non-empty id'):format(index)
        end

        if ids[option.id] then
            return nil, ('duplicate target option id "%s"'):format(option.id)
        end

        ids[option.id] = true

        if type(option.label) ~= 'string' or option.label == '' then
            return nil, ('target option "%s" requires a label'):format(option.id)
        end

        local normalized = {
            id = option.id,
            label = option.label,
            icon = option.icon,
            distance = tonumber(option.distance) or Config.DefaultOptionDistance,
            conditions = option.conditions,
            sustainedSelect = option.sustainedSelect == true,
            onSelect = option.onSelect,
            metadata = cloneMetadata(option.metadata),
            selectControl = option.selectControl
        }

        if normalized.distance <= 0.0 then
            return nil, ('target option "%s" distance must be > 0'):format(option.id)
        end

        if normalized.conditions ~= nil and type(normalized.conditions) ~= 'function' then
            return nil, ('target option "%s" conditions must be a function'):format(option.id)
        end

        if normalized.onSelect ~= nil and type(normalized.onSelect) ~= 'function' then
            return nil, ('target option "%s" onSelect must be a function'):format(option.id)
        end

        options[#options + 1] = normalized
    end

    if #options == 0 then
        return nil, 'targetOptions must contain at least one option'
    end

    return options
end

local function invalidateResolvedCache()
    VexTarget.State.lastResolved.entity = 0
    VexTarget.State.lastResolved.options = nil
    VexTarget.State.lastResolved.sourceType = nil
    VexTarget.State.lastResolved.sourceKey = nil
    VexTarget.State.lastResolved.conditionResults = {}
    VexTarget.State.lastResolved.conditionsPassedAt = 0

    VexTarget.VehicleClassCache = {}
end

local function setModelRegistration(container, models, targetOptions)
    local options, errorMessage = validateOptions(targetOptions)

    if not options then
        return false, errorMessage
    end

    local normalizedModels = normalizeModelArray(models)

    if #normalizedModels == 0 then
        return false, 'modelsArray cannot be empty'
    end

    for _, model in ipairs(normalizedModels) do
        local hash = normalizeHash(model)

        if not hash then
            return false, ('invalid model value: %s'):format(tostring(model))
        end

        container[hash] = {
            options = options
        }
    end

    invalidateResolvedCache()

    return true
end

local function removeModelRegistration(container, model)
    local hash = normalizeHash(model)

    if not hash then
        return false
    end

    if container[hash] == nil then
        return false
    end

    container[hash] = nil

    invalidateResolvedCache()

    return true
end

local function resolveVehicleClass(entity, model)
    local cached = VexTarget.VehicleClassCache[model]

    if cached ~= nil then
        if cached == false then
            return nil
        end

        return cached
    end

    for _, registration in ipairs(VexTarget.TargetEntities.Vehicles.ByClass) do
        local success, matches = pcall(registration.predicate, entity)

        if success and matches == true then
            VexTarget.VehicleClassCache[model] = registration
            return registration
        end

        if not success then
            VexTargetDebug(
                'vehicle class predicate failed for model %s: %s',
                tostring(model),
                tostring(matches)
            )
        end
    end

    VexTarget.VehicleClassCache[model] = false

    return nil
end

-- Same hot-path rationale as RaycastScratch above: ResolveEntity runs once
-- per active frame (the cache-hit branch especially — that's the common
-- case while a player keeps looking at the same entity) and previously
-- allocated a fresh table on every single call, cache hit or not. Reused and
-- mutated in place instead; same synchronous-read-only-this-frame contract.
local ResolvedScratch = {
    options = nil,
    sourceType = nil,
    sourceKey = nil,
    cached = false
}

local function writeResolvedScratch(options, sourceType, sourceKey, cacheHit)
    ResolvedScratch.options = options
    ResolvedScratch.sourceType = sourceType
    ResolvedScratch.sourceKey = sourceKey
    ResolvedScratch.cached = cacheHit

    return ResolvedScratch
end

function VexTarget.ResolveEntity(entity)
    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return nil
    end

    local cached = VexTarget.State.lastResolved

    if cached.entity == entity and cached.options then
        return writeResolvedScratch(cached.options, cached.sourceType, cached.sourceKey, true)
    end

    local entityType = GetEntityType(entity)
    local model = GetEntityModel(entity)

    local registration
    local sourceType
    local sourceKey

    if entityType == 1 then
        local netId = 0

        if NetworkGetEntityIsNetworked(entity) then
            netId = NetworkGetNetworkIdFromEntity(entity)
        end

        if netId ~= 0 then
            registration = VexTarget.TargetEntities.Peds.ByNetId[netId]

            if registration then
                sourceType = 'ped_netid'
                sourceKey = netId
            end
        end

        if not registration then
            registration = VexTarget.TargetEntities.Peds.ByModel[model]

            if registration then
                sourceType = 'ped_model'
                sourceKey = model
            end
        end
    elseif entityType == 2 then
        local netId = 0

        if NetworkGetEntityIsNetworked(entity) then
            netId = NetworkGetNetworkIdFromEntity(entity)
        end

        if netId ~= 0 then
            registration = VexTarget.TargetEntities.Vehicles.ByNetId[netId]

            if registration then
                sourceType = 'vehicle_netid'
                sourceKey = netId
            end
        end

        if not registration then
            registration = VexTarget.TargetEntities.Vehicles.ByModel[model]

            if registration then
                sourceType = 'vehicle_model'
                sourceKey = model
            end
        end

        if not registration then
            registration = resolveVehicleClass(entity, model)

            if registration then
                sourceType = 'vehicle_class'
                sourceKey = registration.id
            end
        end
    end

    if not registration then
        registration = VexTarget.TargetEntities.Models[model]

        if registration then
            sourceType = 'model'
            sourceKey = model
        end
    end

    if not registration then
        invalidateResolvedCache()
        return nil
    end

    cached.entity = entity
    cached.options = registration.options
    cached.sourceType = sourceType
    cached.sourceKey = sourceKey
    cached.conditionResults = {}
    cached.conditionsPassedAt = 0

    return writeResolvedScratch(registration.options, sourceType, sourceKey, false)
end

local function getHitDistance(hitCoords)
    if not hitCoords then
        return math.huge
    end

    local ped = PlayerPedId()

    if not ped or ped == 0 then
        return math.huge
    end

    local playerCoords = GetEntityCoords(ped)

    local dx = hitCoords.x - playerCoords.x
    local dy = hitCoords.y - playerCoords.y
    local dz = hitCoords.z - playerCoords.z

    return math.sqrt((dx * dx) + (dy * dy) + (dz * dz))
end

local function conditionPasses(option, entity, context)
    if not option.conditions then
        return true
    end

    local cache = VexTarget.State.lastResolved
    local currentTime = now()

    local cachedResult = cache.conditionResults[option.id]

    if cachedResult ~= nil
        and (currentTime - cache.conditionsPassedAt) < Config.Watchdog.ConditionRecheckMs
    then
        return cachedResult
    end

    local success, result = pcall(option.conditions, entity, context)

    if not success then
        VexTargetDebug(
            'condition predicate failed for option "%s": %s',
            option.id,
            tostring(result)
        )

        result = false
    end

    cache.conditionResults[option.id] = result == true
    cache.conditionsPassedAt = currentTime

    return result == true
end

-- Reused across every option considered on every active frame (potentially
-- several times per frame — once per registered option within range until
-- one passes its condition). Same allocation-elimination rationale as
-- RaycastScratch/ResolvedScratch above.
--
-- IMPORTANT contract for callers of `conditions`/`onSelect`: the `context`
-- table handed to those caller-supplied functions is this SAME reused
-- table, valid only for the duration of that synchronous call. A predicate
-- or onSelect handler must read what it needs immediately — it must never
-- stash the `context` reference itself (in a closure, a queue, a later
-- async step) expecting it to still hold the same values afterward, since
-- the very next option considered (possibly still within the same frame)
-- overwrites these fields in place. Pull out the specific values you need
-- (numbers/strings/vector3s) rather than keeping the table.
local ContextScratch = {
    entity = 0,
    hitCoords = nil,
    distance = 0,
    optionIndex = 0,
    sourceType = nil,
    sourceKey = nil
}

function VexTarget.GetUsableOption(entity, resolved, hitCoords)
    if not resolved or type(resolved.options) ~= 'table' then
        return nil
    end

    local distance = getHitDistance(hitCoords)

    for index, option in ipairs(resolved.options) do
        if distance <= option.distance then
            ContextScratch.entity = entity
            ContextScratch.hitCoords = hitCoords
            ContextScratch.distance = distance
            ContextScratch.optionIndex = index
            ContextScratch.sourceType = resolved.sourceType
            ContextScratch.sourceKey = resolved.sourceKey

            if conditionPasses(option, entity, ContextScratch) then
                return option, ContextScratch
            end
        end
    end

    return nil
end

-- VexTarget.State.currentTarget stays genuinely nil when there is no active
-- target (GetCurrentTarget()/ClearCurrentTarget() both depend on that), but
-- while a target IS active it now points at this same persistent table on
-- every frame instead of a fresh allocation — mutated in place, not
-- reassigned. External code never reads this field directly; the
-- `GetCurrentTarget` export below still returns its own fresh copy, so no
-- caller outside this file ever sees a mutating table.
local CurrentTargetScratch = {
    entity = 0,
    netId = 0,
    resolvedOptionId = nil,
    hitCoords = nil
}

function VexTarget.SetCurrentTarget(entity, option, context)
    if not entity or entity == 0 or not option then
        VexTarget.State.currentTarget = nil
        return
    end

    local netId = 0

    if NetworkGetEntityIsNetworked(entity) then
        netId = NetworkGetNetworkIdFromEntity(entity)
    end

    CurrentTargetScratch.entity = entity
    CurrentTargetScratch.netId = netId
    CurrentTargetScratch.resolvedOptionId = option.id
    CurrentTargetScratch.hitCoords = context and context.hitCoords or nil

    VexTarget.State.currentTarget = CurrentTargetScratch
end

function VexTarget.ClearCurrentTarget()
    VexTarget.State.currentTarget = nil
end

function VexTarget.ClearResolvedCache()
    invalidateResolvedCache()
end

function VexTarget.SetRaycastMode(mode)
    if type(mode) ~= 'string' or Config.RaycastFlags[mode] == nil then
        return false
    end

    VexTarget.State.raycastMode = mode

    return true
end

-- ---- Public registration exports ------------------------------------------

exports('AddTargetModel', function(modelsArray, targetOptions)
    local success, errorMessage = setModelRegistration(
        VexTarget.TargetEntities.Models,
        modelsArray,
        targetOptions
    )

    if not success then
        VexTargetDebug('AddTargetModel failed: %s', tostring(errorMessage))
    end

    return success, errorMessage
end)

exports('AddTargetPed', function(pedModelArray, targetOptions)
    local success, errorMessage = setModelRegistration(
        VexTarget.TargetEntities.Peds.ByModel,
        pedModelArray,
        targetOptions
    )

    if not success then
        VexTargetDebug('AddTargetPed failed: %s', tostring(errorMessage))
    end

    return success, errorMessage
end)

exports('AddTargetVehicle', function(vehicleModelArray, targetOptions, classPredicate)
    local options, errorMessage = validateOptions(targetOptions)

    if not options then
        return false, errorMessage
    end

    if classPredicate ~= nil then
        if type(classPredicate) ~= 'function' then
            return false, 'classPredicate must be a function'
        end

        VexTarget.TargetEntities.Vehicles.ByClass[#VexTarget.TargetEntities.Vehicles.ByClass + 1] = {
            id = ('vehicle_class_%d_%d'):format(now(), #VexTarget.TargetEntities.Vehicles.ByClass + 1),
            predicate = classPredicate,
            options = options
        }
    end

    local normalizedModels = normalizeModelArray(vehicleModelArray)

    if #normalizedModels > 0 then
        for _, model in ipairs(normalizedModels) do
            local hash = normalizeHash(model)

            if not hash then
                return false, ('invalid vehicle model: %s'):format(tostring(model))
            end

            VexTarget.TargetEntities.Vehicles.ByModel[hash] = {
                options = options
            }
        end
    elseif classPredicate == nil then
        return false, 'vehicle models or classPredicate required'
    end

    invalidateResolvedCache()

    return true
end)

exports('AddTargetEntity', function(netId, targetOptions)
    netId = tonumber(netId)

    if not netId or netId <= 0 then
        return false, 'netId must be a positive network entity ID'
    end

    if not NetworkDoesNetworkIdExist(netId) then
        return false, 'network entity does not currently exist'
    end

    local entity = NetworkGetEntityFromNetworkId(netId)

    if entity == 0 or not DoesEntityExist(entity) then
        return false, 'unable to resolve network entity'
    end

    local options, errorMessage = validateOptions(targetOptions)

    if not options then
        return false, errorMessage
    end

    local entityType = GetEntityType(entity)

    if entityType == 1 then
        VexTarget.TargetEntities.Peds.ByNetId[netId] = {
            options = options
        }
    elseif entityType == 2 then
        VexTarget.TargetEntities.Vehicles.ByNetId[netId] = {
            options = options
        }
    else
        return false, 'AddTargetEntity v1 supports networked peds and vehicles'
    end

    invalidateResolvedCache()

    return true
end)

exports('RemoveTargetModel', function(modelName)
    return removeModelRegistration(
        VexTarget.TargetEntities.Models,
        modelName
    )
end)

exports('RemoveTargetPed', function(pedModel)
    return removeModelRegistration(
        VexTarget.TargetEntities.Peds.ByModel,
        pedModel
    )
end)

exports('RemoveTargetVehicle', function(vehicleModel)
    return removeModelRegistration(
        VexTarget.TargetEntities.Vehicles.ByModel,
        vehicleModel
    )
end)

exports('RemoveTargetEntity', function(netId)
    netId = tonumber(netId)

    if not netId then
        return false
    end

    local removed = false

    if VexTarget.TargetEntities.Peds.ByNetId[netId] then
        VexTarget.TargetEntities.Peds.ByNetId[netId] = nil
        removed = true
    end

    if VexTarget.TargetEntities.Vehicles.ByNetId[netId] then
        VexTarget.TargetEntities.Vehicles.ByNetId[netId] = nil
        removed = true
    end

    if removed then
        invalidateResolvedCache()
    end

    return removed
end)

-- ---- Read-only state exports ------------------------------------------------

exports('IsTargetActive', function()
    return VexTarget.State.active == true
end)

exports('GetCurrentTarget', function()
    local target = VexTarget.State.currentTarget

    if not target then
        return nil
    end

    return {
        entity = target.entity,
        netId = target.netId,
        resolvedOptionId = target.resolvedOptionId
    }
end)

-- ============================================================================
-- SECTION: shape-test raycasting
-- (formerly client/raycast.lua)
-- ============================================================================

local DEG_TO_RAD = math.pi / 180.0

local function rotationToDirection(rotation)
    local pitch = rotation.x * DEG_TO_RAD
    local yaw = rotation.z * DEG_TO_RAD

    local cosPitch = math.cos(pitch)

    return vector3(
        -math.sin(yaw) * cosPitch,
        math.cos(yaw) * cosPitch,
        math.sin(pitch)
    )
end

local function getCameraOrigin()
    if Config.Camera.UseFinalRenderedCamera then
        return GetFinalRenderedCamCoord()
    end

    return GetGameplayCamCoord()
end

local function getCameraRotation()
    if Config.Camera.UseFinalRenderedCamera then
        return GetFinalRenderedCamRot(Config.Camera.RotationOrder)
    end

    return GetGameplayCamRot(Config.Camera.RotationOrder)
end

-- ---- Hot-path result scratch -------------------------------------------------
--
-- VexTarget.Raycast runs once per active (Wait(0)) frame for as long as the
-- key is held. The original implementation returned a fresh table literal
-- from every branch (unconfigured/failed/aborted/resolved) — four table
-- allocations away from being avoidable, all on the hottest loop in the
-- resource. RaycastScratch is a single persistent table mutated in place and
-- returned by reference instead.
--
-- Contract: the caller (runActiveLoop, in the watchdog section below) reads
-- the returned table's fields SYNCHRONOUSLY within the same frame and never
-- stores the reference itself for later use — next frame's call overwrites
-- these same fields in place. This matches how it was already being used
-- (`local ray = VexTarget.Raycast(...)`, read immediately, discarded), so
-- nothing about calling code needed to change.
local RaycastScratch = {
    status = nil,
    hit = false,
    entity = 0,
    hitCoords = nil,
    surfaceNormal = nil,
    origin = nil,
    endCoords = nil
}

local function writeRaycastScratch(status, hit, entity, hitCoords, surfaceNormal, origin, endCoords)
    RaycastScratch.status = status
    RaycastScratch.hit = hit
    RaycastScratch.entity = entity
    RaycastScratch.hitCoords = hitCoords
    RaycastScratch.surfaceNormal = surfaceNormal
    RaycastScratch.origin = origin
    RaycastScratch.endCoords = endCoords

    return RaycastScratch
end

-- Defensive upper bound on how many Wait(0) frames a single probe is allowed
-- to stay "pending" before Raycast() gives up on it. GetShapeTestResult's
-- pending-vs-resolved status codes for the current RedM/CitizenFX build are
-- still unpinned (Open Item #3 in the architecture doc) — this code assumes
-- resultState == 1 means "still pending," matching the CFX convention this
-- was written against, but that assumption itself is unverified. Bounding
-- the poll means that even if the assumption is wrong and the native never
-- reports "resolved" the way this code expects, the loop cannot spin
-- indefinitely — it aborts and lets Tier B carry on instead.
local MAX_PENDING_POLLS = 8

function VexTarget.Raycast(mode)
    mode = mode or VexTarget.State.raycastMode or Config.DefaultRaycastMode

    local flags = Config.RaycastFlags[mode]

    if flags == nil then
        VexTargetDebug(
            'raycast mode "%s" has no verified collision bitmask configured',
            tostring(mode)
        )

        return writeRaycastScratch('unconfigured', false, 0, nil, nil, nil, nil)
    end

    local origin = getCameraOrigin()
    local rotation = getCameraRotation()
    local forward = rotationToDirection(rotation)

    local endCoords = vector3(
        origin.x + (forward.x * Config.MaxTargetDistance),
        origin.y + (forward.y * Config.MaxTargetDistance),
        origin.z + (forward.z * Config.MaxTargetDistance)
    )

    local playerPed = PlayerPedId()

    local handle = StartShapeTestLosProbe(
        origin.x,
        origin.y,
        origin.z,
        endCoords.x,
        endCoords.y,
        endCoords.z,
        flags,
        playerPed,
        Config.RaycastP8
    )

    if not handle or handle == 0 then
        return writeRaycastScratch('failed', false, 0, nil, nil, origin, endCoords)
    end

    local resultState
    local hit
    local hitCoords
    local surfaceNormal
    local entityHit
    local pendingPolls = 0

    repeat
        resultState, hit, hitCoords, surfaceNormal, entityHit =
            GetShapeTestResult(handle)

        if resultState == 1 then
            pendingPolls = pendingPolls + 1

            -- Tear down the moment the activation key is released mid-probe,
            -- or after MAX_PENDING_POLLS frames of no result, rather than
            -- blocking this frame (and therefore Tier B's own exit check)
            -- on a straggling shape test. Either condition returns an
            -- 'aborted' status; runActiveLoop treats any non-hit status as
            -- "no valid target this frame," so no separate branch is needed
            -- there.
            if pendingPolls > MAX_PENDING_POLLS or not VexTarget.IsActivationPressed() then
                return writeRaycastScratch('aborted', false, 0, nil, nil, origin, endCoords)
            end

            Citizen.Wait(0)
        end
    until resultState ~= 1

    return writeRaycastScratch(
        resultState,
        hit == 1 or hit == true,
        entityHit or 0,
        hitCoords,
        surfaceNormal,
        origin,
        endCoords
    )
end

-- ============================================================================
-- SECTION: reticle (pure native draw, no NUI)
-- (formerly client/reticle.lua)
-- ============================================================================

VexTarget.Reticle = {
    visible = false,
    state = 'idle',
    confirmedUntil = 0
}

local function getReticlePreset()
    local currentTime = GetGameTimer()

    if VexTarget.Reticle.confirmedUntil > currentTime then
        return Config.Reticle.Confirmed
    end

    if VexTarget.Reticle.state == 'active' then
        return Config.Reticle.Active
    end

    return Config.Reticle.Idle
end

function VexTarget.ShowReticle()
    VexTarget.Reticle.visible = true
end

function VexTarget.HideReticle()
    VexTarget.Reticle.visible = false
    VexTarget.Reticle.state = 'idle'
    VexTarget.Reticle.confirmedUntil = 0
end

function VexTarget.SetReticleState(state)
    if state ~= 'idle' and state ~= 'active' then
        state = 'idle'
    end

    VexTarget.Reticle.state = state
end

function VexTarget.FlashReticleConfirmed()
    VexTarget.Reticle.confirmedUntil =
        GetGameTimer() + Config.Reticle.Confirmed.FlashMs
end

function VexTarget.DrawReticle()
    if not Config.Reticle.Enabled or not VexTarget.Reticle.visible then
        return
    end

    local preset = getReticlePreset()
    local color = preset.color
    local position = Config.Reticle.Position

    DrawRect(
        position.x,
        position.y,
        preset.width,
        preset.height,
        color.r,
        color.g,
        color.b,
        color.a
    )
end

-- ============================================================================
-- SECTION: vex_callback bridge + mandatory server sanity submission
-- (formerly client/bridge.lua)
-- ============================================================================

local selectionSequence = 0

local function nextSelectionId()
    selectionSequence = selectionSequence + 1

    if selectionSequence > 2147483647 then
        selectionSequence = 1
    end

    return ('vex_target:%d:%d'):format(
        GetGameTimer(),
        selectionSequence
    )
end

local function getNetworkId(entity)
    if not entity
        or entity == 0
        or not DoesEntityExist(entity)
        or not NetworkGetEntityIsNetworked(entity)
    then
        return 0
    end

    return NetworkGetNetworkIdFromEntity(entity)
end

local function invokeCallbackBridge(selectionId, payload)
    local bridge = Config.CallbackBridge

    if bridge.Mode == 'local' then
        return false
    end

    if bridge.Mode == 'event' then
        TriggerEvent(
            bridge.ResolveEvent,
            selectionId,
            payload
        )

        return true
    end

    if bridge.Mode == 'export' then
        local success, result = pcall(function()
            return exports[bridge.Resource][bridge.ResolveExport](
                selectionId,
                payload
            )
        end)

        if not success then
            VexTargetDebug(
                'vex_callback export bridge failed: %s',
                tostring(result)
            )

            return false
        end

        return true
    end

    VexTargetDebug(
        'unknown callback bridge mode "%s"',
        tostring(bridge.Mode)
    )

    return false
end

local function dispatchLocalOnSelect(option, entity, payload)
    if type(option.onSelect) ~= 'function' then
        return
    end

    CreateThread(function()
        local success, errorMessage = pcall(
            option.onSelect,
            entity,
            payload
        )

        if not success then
            VexTargetDebug(
                'onSelect failed for option "%s": %s',
                tostring(option.id),
                tostring(errorMessage)
            )
        end
    end)
end

-- ---- Server sanity submission ----------------------------------------------
--
-- Fires unconditionally, independent of Config.CallbackBridge.Mode.
-- CallbackBridge only governs how the LOCAL Lua onSelect gets invoked; the
-- server-side validation pass in server/main.lua is a separate, mandatory
-- backstop against a modified client forging a selection outright. Anything
-- a calling resource does that has real consequences (money, items, world
-- state) must be driven off the server's ValidatedEvent, never off this
-- local dispatch alone.
--
-- msgpack (the wire format TriggerServerEvent uses) cannot serialise
-- functions/userdata. A careless caller's metadata table could contain one
-- (cloneMetadata above only deep-copies nested tables, it does not strip
-- non-primitive leaves) which would otherwise throw INSIDE the
-- TriggerServerEvent call itself, before the server ever sees anything.
-- networkSafeCopy pre-strips those leaves client-side so a malformed
-- metadata table degrades to a dropped field instead of an uncaught error
-- in the Tier B loop.

local function networkSafeCopy(value, depth)
    depth = depth or 0

    if depth > 6 then
        return nil
    end

    local valueType = type(value)

    if valueType == 'string' or valueType == 'number' or valueType == 'boolean' or value == nil then
        return value
    end

    if valueType == 'vector3' or valueType == 'vector4' or valueType == 'vector2' then
        return value
    end

    if valueType == 'table' then
        local result = {}

        for key, nested in pairs(value) do
            local keyType = type(key)

            if keyType == 'string' or keyType == 'number' then
                result[key] = networkSafeCopy(nested, depth + 1)
            end
        end

        return result
    end

    -- functions, userdata, threads: unsupported over the wire, dropped.
    return nil
end

local function submitSelectionToServer(payload)
    local hitCoords = payload.hitCoords

    local safeHitCoords = hitCoords and {
        x = hitCoords.x,
        y = hitCoords.y,
        z = hitCoords.z
    } or nil

    local wirePayload = {
        selectionId = payload.selectionId,
        netId = payload.netId,
        hitCoords = safeHitCoords,
        optionId = payload.optionId,
        sourceType = payload.sourceType,
        sourceKey = payload.sourceKey,
        metadata = networkSafeCopy(payload.metadata)
    }

    local success, errorMessage = pcall(
        TriggerServerEvent,
        'vex_target:server:submitSelection',
        wirePayload
    )

    if not success then
        VexTargetDebug(
            'failed to submit selection %s to server: %s',
            tostring(payload.selectionId),
            tostring(errorMessage)
        )
    end
end

function VexTarget.DispatchSelection(entity, hitCoords, option, context)
    local selectionId = nextSelectionId()

    local payload = {
        selectionId = selectionId,
        entity = entity,
        netId = getNetworkId(entity),
        hitCoords = hitCoords,
        optionId = option.id,
        metadata = option.metadata,
        sourceType = context and context.sourceType or nil,
        sourceKey = context and context.sourceKey or nil
    }

    local bridged = invokeCallbackBridge(selectionId, payload)

    -- The registration callback itself must never execute inline in the Tier B
    -- loop. Even when vex_callback is configured, this local callback remains
    -- the v1 Lua export completion path unless the deployment elects to route
    -- completion entirely through vex_callback.
    if not bridged or Config.CallbackBridge.AllowLocalFallback then
        dispatchLocalOnSelect(option, entity, payload)
    end

    TriggerEvent(
        'vex_target:selectionResolved',
        payload
    )

    submitSelectionToServer(payload)

    return payload
end

-- ============================================================================
-- SECTION: modifier-key watchdog (Tier A / Tier B) + failsafes
-- (formerly client/watchdog.lua)
-- ============================================================================

local activeLoopRunning = false
local textVisible = false
local lastSelectAt = 0

-- ---- Key mapping state ------------------------------------------------------

RegisterCommand('+' .. Config.Activation.Command, function()
    VexTarget.State.activationHeld = true
end, false)

RegisterCommand('-' .. Config.Activation.Command, function()
    VexTarget.State.activationHeld = false
end, false)

RegisterKeyMapping(
    '+' .. Config.Activation.Command,
    Config.Activation.Description,
    Config.Activation.DefaultMapper,
    Config.Activation.DefaultKey
)

RegisterCommand('+' .. Config.Selection.Command, function()
    VexTarget.State.selectionHeld = true
end, false)

RegisterCommand('-' .. Config.Selection.Command, function()
    VexTarget.State.selectionHeld = false
end, false)

RegisterKeyMapping(
    '+' .. Config.Selection.Command,
    Config.Selection.Description,
    Config.Selection.DefaultMapper,
    Config.Selection.DefaultKey
)

-- ---- Control readers ---------------------------------------------------------
--
-- Activation-key reading now lives in VexTarget.IsActivationPressed (defined
-- in the registry section above) so Raycast()'s defensive poll loop can
-- share it. Kept here only as a call-site alias for readability within this
-- section.

local function isActivationPressed()
    return VexTarget.IsActivationPressed()
end

local function isSelectionPressed(option)
    if option and option.selectControl ~= nil then
        local control = option.selectControl

        return IsControlPressed(0, control)
            or IsDisabledControlPressed(0, control)
    end

    if not Config.Selection.UseNativeControl then
        return VexTarget.State.selectionHeld == true
    end

    local hash = Config.Selection.NativeControlHash

    if hash == nil then
        return false
    end

    local group = Config.Selection.ControlGroup

    return IsControlPressed(group, hash)
        or IsDisabledControlPressed(group, hash)
end

-- ---- TextUI -------------------------------------------------------------------

local function hideText()
    if not textVisible then
        return
    end

    textVisible = false

    if not Config.TextUI.Enabled then
        return
    end

    local success, errorMessage = pcall(function()
        exports[Config.TextUI.Resource]:HideTextInput()
    end)

    if not success then
        VexTargetDebug(
            'HideTextInput failed: %s',
            tostring(errorMessage)
        )
    end
end

local function displayText(option)
    if not Config.TextUI.Enabled then
        return
    end

    local success, errorMessage = pcall(function()
        exports[Config.TextUI.Resource]:DisplayTextInput(
            option.label,
            Config.TextUI.Variant,
            option.icon
        )
    end)

    if success then
        textVisible = true
        return
    end

    VexTargetDebug(
        'DisplayTextInput failed: %s',
        tostring(errorMessage)
    )
end

-- ---- Teardown -------------------------------------------------------------------

local function teardownTargetMode()
    VexTarget.State.active = false

    VexTarget.HideReticle()
    VexTarget.ClearCurrentTarget()
    VexTarget.ClearResolvedCache()

    hideText()
end

-- ---- Selection ------------------------------------------------------------------

local function shouldDispatchSelection(option)
    if not isSelectionPressed(option) then
        return false
    end

    local currentTime = GetGameTimer()

    if (currentTime - lastSelectAt) < Config.Behaviour.SelectionDebounceMs then
        return false
    end

    lastSelectAt = currentTime

    return true
end

-- ---- Tier B: active loop, Wait(0), exists only while the key is held ------------

local function runActiveLoop()
    if activeLoopRunning then
        return
    end

    activeLoopRunning = true
    VexTarget.State.active = true

    VexTarget.ShowReticle()
    VexTarget.SetReticleState('idle')

    while isActivationPressed() do
        -- Draw every active frame.
        VexTarget.DrawReticle()

        local ray = VexTarget.Raycast(
            VexTarget.State.raycastMode
        )

        local validTarget = false

        if ray.hit
            and ray.entity
            and ray.entity ~= 0
            and DoesEntityExist(ray.entity)
        then
            local resolved = VexTarget.ResolveEntity(ray.entity)

            if resolved then
                local option, context = VexTarget.GetUsableOption(
                    ray.entity,
                    resolved,
                    ray.hitCoords
                )

                if option then
                    validTarget = true

                    VexTarget.SetCurrentTarget(
                        ray.entity,
                        option,
                        context
                    )

                    VexTarget.SetReticleState('active')

                    displayText(option)

                    if shouldDispatchSelection(option) then
                        VexTarget.FlashReticleConfirmed()

                        VexTarget.DispatchSelection(
                            ray.entity,
                            ray.hitCoords,
                            option,
                            context
                        )

                        if not option.sustainedSelect
                            and Config.Behaviour.ExitAfterSelection
                        then
                            break
                        end
                    end
                end
            end
        end

        if not validTarget then
            VexTarget.ClearCurrentTarget()
            VexTarget.SetReticleState('idle')
            hideText()
        end

        Citizen.Wait(Config.Watchdog.ActiveWaitMs)
    end

    teardownTargetMode()

    activeLoopRunning = false
end

-- ---- Tier A: idle watchdog, Wait(250), the only thread running at rest ----------
--
-- Idle cost: one activation-state read every Config.Watchdog.IdleWaitMs.
-- No raycast. No draw. No registry resolution. No vex_core predicate.
-- No textui work.

CreateThread(function()
    while true do
        local pressed = isActivationPressed()

        if pressed and not activeLoopRunning then
            runActiveLoop()
        elseif not pressed and VexTarget.State.active and not activeLoopRunning then
            -- Defensive self-healing path.
            teardownTargetMode()
        end

        Citizen.Wait(Config.Watchdog.IdleWaitMs)
    end
end)

-- ---- Failsafe ---------------------------------------------------------------------

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    VexTarget.State.activationHeld = false
    VexTarget.State.selectionHeld = false

    teardownTargetMode()
end)
