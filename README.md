# vex_target

A lightweight visual raycast targeting utility for RedM.

`vex_target` provides entity and model targeting using camera-based raycasting, a native reticle, conditional interactions, and asynchronous selection handling.

## Features

* Camera-based entity raycasting
* Native targeting reticle
* Ped, vehicle, object, and model targeting
* Network entity targeting
* Per-option interaction distances
* Conditional target options
* Async selection callbacks
* `vex_textui` integration
* Optimized active/idle watchdog
* Zero raycasting while targeting is inactive

## Dependencies

* `vex_core`
* `vex_callback`
* `vex_textui`

## Installation

Place `vex_target` in your resources directory and add:

```cfg
ensure vex_core
ensure vex_callback
ensure vex_textui
ensure vex_target
```

## Basic Usage

```lua
exports['vex_target']:AddTargetModel({
    `p_bedroll01x`
}, {
    {
        id = 'sleep',
        label = 'Sleep',
        distance = 1.5,

        onSelect = function(entity, data)
            print('Selected bedroll:', entity)
        end
    }
})
```

## Exports

```lua
AddTargetModel(models, options)
AddTargetPed(models, options)
AddTargetVehicle(models, options, classPredicate)
AddTargetEntity(netId, options)

RemoveTargetModel(model)
RemoveTargetPed(model)
RemoveTargetVehicle(model)
RemoveTargetEntity(netId)

IsTargetActive()
GetCurrentTarget()
```

## Performance

`vex_target` only performs raycasts while target mode is active. When inactive, the resource falls back to a lightweight watchdog with no raycasting, target resolution, or reticle rendering.

## VEX Ecosystem

`vex_target` is designed as a foundational targeting dependency for other VEX RedM resources.

## License

See the repository license for usage and distribution terms.
