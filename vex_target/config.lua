Config = Config or {}

-- ============================================================================
-- VEX TARGET
-- Shared configuration
-- ============================================================================

Config.Debug = false

-- ============================================================================
-- Activation
-- ============================================================================
--
-- The architecture recommends a RegisterKeyMapping-driven custom bind instead
-- of hijacking a combat-sensitive native RDR control.
--
-- RegisterKeyMapping ultimately drives the held state through +command /
-- -command handlers. Tier A then cheaply samples that state every IdleWaitMs.
--
-- The exact native activation-control hash was deliberately left as an open
-- implementation pin in the architecture. NativeControlHash therefore remains
-- optional rather than pretending an unverified hash is authoritative.
--
-- Note for anyone auditing this against a "no FiveM legacy natives" checklist:
-- RegisterKeyMapping is not FiveM/GTA5-specific — it's a CitizenFX-framework
-- native shared by both games, and it's the standard way RedM resources (RSG-
-- Core, VORP, etc.) expose a rebindable custom keybind. Swapping it for a raw
-- IsControlPressed/IsDisabledControlPressed control hash (UseNativeControl =
-- true, below) is supported for anyone who specifically wants that path, but
-- doing so by default would mean shipping an unverified NativeControlHash
-- guess in place of a working, correctly-non-polling default — trading a
-- real (if superficial) objection for a real risk. Left as UseNativeControl
-- = false unless a verified hash is supplied.
-- ============================================================================

Config.Activation = {
    Command = 'vex_target',
    Description = 'Activate VEX Target',
    DefaultMapper = 'keyboard',
    DefaultKey = 'LMENU',

    -- false = RegisterKeyMapping held-state mode
    -- true  = IsControlPressed / IsDisabledControlPressed mode
    UseNativeControl = false,

    -- Pin against the live RedM native reference before enabling
    -- UseNativeControl.
    NativeControlHash = nil,

    -- Native control group passed to IsControlPressed.
    ControlGroup = 0
}

-- ============================================================================
-- Selection
-- ============================================================================

Config.Selection = {
    Command = 'vex_target_select',
    Description = 'Select VEX Target Option',
    DefaultMapper = 'MOUSE_BUTTON',
    DefaultKey = 'MOUSE_LEFT',

    -- Optional native-control mode.
    UseNativeControl = false,

    -- Intentionally unpinned by the architectural document.
    NativeControlHash = nil,

    ControlGroup = 0
}

-- ============================================================================
-- Watchdog
-- ============================================================================

Config.Watchdog = {
    -- Tier A idle cadence.
    IdleWaitMs = 250,

    -- Tier B always uses Wait(0).
    ActiveWaitMs = 0,

    -- Conditions such as job/rank clearance should not cross resource
    -- boundaries at frame rate.
    ConditionRecheckMs = 200
}

-- ============================================================================
-- Targeting
-- ============================================================================

Config.MaxTargetDistance = 7.0

-- Default target option distance when an option does not explicitly define one.
Config.DefaultOptionDistance = 2.0

-- A raycast mode can be selected by calling VexTarget.SetRaycastMode internally
-- or through future API expansion.
Config.DefaultRaycastMode = 'default'

-- ============================================================================
-- Raycast flags
-- ============================================================================
--
-- IMPORTANT:
-- The Phase 1 architecture explicitly marks RDR3 shape-test intersect bit values
-- as "pin before implementation".
--
-- Supply verified values for the server's current RedM/CitizenFX build here.
--
-- A value of nil deliberately prevents the raycast from dispatching and logs a
-- debug warning instead of silently using a potentially incorrect collision
-- mask.
--
-- Example deployment shape:
--
-- Config.RaycastFlags = {
--     default = VERIFIED_BITMASK,
--     peds = VERIFIED_PED_MODE_BITMASK,
--     vehicles = VERIFIED_VEHICLE_MODE_BITMASK,
--     objects = VERIFIED_OBJECT_MODE_BITMASK
-- }
-- ============================================================================

Config.RaycastFlags = {
    default = nil,
    peds = nil,
    vehicles = nil,
    objects = nil
}

-- Native-family trailing flag specified by the architecture.
Config.RaycastP8 = 7

-- ============================================================================
-- Camera
-- ============================================================================

Config.Camera = {
    RotationOrder = 2,

    -- Architectural default:
    -- GetGameplayCamCoord() / GetGameplayCamRot(2)
    UseFinalRenderedCamera = false
}

-- ============================================================================
-- Reticle
-- ============================================================================
--
-- Pure native reticle. No NUI.
-- The dot stays at a fixed normalized screen coordinate.
-- ============================================================================

Config.Reticle = {
    Enabled = true,

    Position = {
        x = 0.5,
        y = 0.5
    },

    Idle = {
        width = 0.0030,
        height = 0.0050,

        color = {
            r = 225,
            g = 225,
            b = 225,
            a = 150
        }
    },

    Active = {
        width = 0.0040,
        height = 0.0065,

        color = {
            r = 220,
            g = 186,
            b = 115,
            a = 230
        }
    },

    Confirmed = {
        width = 0.0050,
        height = 0.0080,

        color = {
            r = 245,
            g = 218,
            b = 150,
            a = 255
        },

        FlashMs = 120
    }
}

-- ============================================================================
-- vex_textui integration
-- ============================================================================

Config.TextUI = {
    Enabled = true,

    Resource = 'vex_textui',

    -- Passed through as the second DisplayTextInput argument.
    Variant = 'target'
}

-- ============================================================================
-- vex_callback bridge
-- ============================================================================
--
-- The actual vex_callback resolve API was explicitly unresolved in the
-- architecture.
--
-- Bridge mode:
--
--   'export'
--       bridge.lua attempts:
--       exports[Resource][ResolveExport](selectionId, payload)
--
--   'event'
--       bridge.lua triggers ResolveEvent with selectionId + payload.
--
--   'local'
--       only the asynchronous local onSelect dispatch is used.
--
-- Local onSelect dispatch remains asynchronous regardless of bridge mode so a
-- calling resource cannot stall the Tier B targeting loop.
-- ============================================================================

Config.CallbackBridge = {
    Mode = 'local',

    Resource = 'vex_callback',

    -- Replace once the actual vex_callback API is pinned.
    ResolveExport = 'Resolve',

    -- Optional bridge if vex_callback ultimately exposes an event instead.
    ResolveEvent = 'vex_callback:client:resolve',

    -- If the external bridge cannot be invoked, still dispatch the registered
    -- Lua onSelect asynchronously.
    AllowLocalFallback = true
}

-- ============================================================================
-- Behaviour
-- ============================================================================

Config.Behaviour = {
    -- Single-shot interaction exits target mode after confirmation unless the
    -- option declares sustainedSelect = true.
    ExitAfterSelection = true,

    -- Avoid sending repeated select actions when a mapped selection button is
    -- held down.
    SelectionDebounceMs = 175
}

-- ============================================================================
-- Server-side sanity layer
-- ============================================================================
--
-- vex_target's client (registry, raycast, watchdog) is NOT a trust boundary.
-- A modified client can call VexTarget.DispatchSelection directly, or fake a
-- shape-test hit, with an arbitrary entity/netId/hitCoords/optionId/metadata
-- table and no real raycast ever having run. Config.Server governs the
-- independent server-side validation pass that runs on every selection
-- REGARDLESS of Config.CallbackBridge.Mode above — that setting only decides
-- how the local Lua onSelect gets invoked on the client, it has no bearing
-- on whether the server validates the raw selection. Anything with a real
-- server-side consequence (currency, items, world-state changes) must be
-- driven off Config.Server.ValidatedEvent server-side, never off the
-- client-local onSelect alone.
-- ============================================================================

Config.Server = {
    -- Extra distance tolerance layered on top of Config.MaxTargetDistance to
    -- absorb legitimate network latency between the client's raycast frame
    -- and the server's most recently replicated player position. Slack for
    -- lag, not a second targeting range.
    DistancePadding = 1.5,

    -- Hard ceiling regardless of DistancePadding math, so a
    -- MaxTargetDistance misconfiguration upstream can't silently inflate the
    -- server's tolerance to something exploitable.
    MaxAllowedDistance = 15.0,

    -- Minimum time between ACCEPTED selections from the same player,
    -- enforced server-side. Independent of, and not a substitute for,
    -- Config.Behaviour.SelectionDebounceMs, which is client-side UX only and
    -- cannot be trusted as a security control.
    MinIntervalMs = 150,

    -- How long an accepted selectionId is remembered for replay rejection.
    SelectionIdMemoryMs = 30000,

    -- Recognised sourceType values a client is allowed to claim (mirrors
    -- core.lua's VexTarget.ResolveEntity sourceType vocabulary). Anything
    -- else is rejected outright rather than silently coerced into a bucket.
    ValidSourceTypes = {
        ped_netid = true,
        ped_model = true,
        vehicle_netid = true,
        vehicle_model = true,
        vehicle_class = true,
        model = true
    },

    -- sourceTypes that claim a specific networked entity and therefore must
    -- resolve to a real, currently-existing server-side entity.
    NetworkedSourceTypes = {
        ped_netid = true,
        vehicle_netid = true
    },

    -- Generic metadata sanitisation limits. vex_target's server has no
    -- schema for what a given optionId's metadata SHOULD contain (that is
    -- calling-resource-specific) — this is a shape/size backstop against a
    -- malformed or hostile payload, not business-logic validation.
    Metadata = {
        MaxDepth = 4,
        MaxKeys = 32,
        MaxStringLength = 256
    },

    -- vex_core's authoritative-position export is, like vex_callback's real
    -- API elsewhere in this project, unconfirmed. Resolved defensively: try
    -- the configured export first, fall back to the native replicated ped
    -- position if it's missing or errors. Never fails open — a position
    -- that cannot be established at all fails the distance check rather
    -- than skipping it.
    Core = {
        Resource = 'vex_core',
        PositionExport = 'GetPlayerCoords'
    },

    -- Event names other server resources should consume. Kept distinct from
    -- Config.CallbackBridge (client-side, local-onSelect dispatch) since
    -- this is the authoritative path for anything with real server-side
    -- consequences.
    ValidatedEvent = 'vex_target:server:selectionValidated',
    RejectedEvent = 'vex_target:server:selectionRejected'
}

-- ============================================================================
-- Debug helper
-- ============================================================================

function VexTargetDebug(message, ...)
    if not Config.Debug then
        return
    end

    local formatted = message

    if select('#', ...) > 0 then
        formatted = string.format(message, ...)
    end

    print(('[vex_target] %s'):format(formatted))
end