// Vehicle spawn catalog — the deliverable CHOAM vehicle blueprints and their
// tier template variants. `className` is the Unreal actor-class path sent to the
// game's SpawnVehicleAt RMQ command; `templates` are the optional tier loadouts
// (sent as TemplateName). Spawning at a player requires the player to be online.
export interface VehicleTemplate {
  id: string
  label: string
  className: string
  templates: string[]
  // Top-tier (Mk6) module item template ids that, given to a player, let them
  // assemble this vehicle at a Vehicle Assembly. Empty when the game has no
  // discrete part items for the vehicle (Tank / Treadwheel / Container), in
  // which case only the live RMQ spawn is available. Used by the "Give Vehicle
  // Kit" action, which delivers these parts via the normal give-item path so it
  // works online OR offline — no RMQ spawn required.
  kit: string[]
}

// The consumables bundled into every Give Vehicle Kit alongside the parts: one
// Large Vehicle Fuel Cell to fuel the assembled vehicle and a Welding Torch Mk5
// to weld/repair it. Both are plain inventory items, delivered the same way.
export const VEHICLE_KIT_FUEL_TEMPLATE = 'FuelCanister_Large'   // Large Vehicle Fuel Cell
export const VEHICLE_KIT_TORCH_TEMPLATE = 'RepairTool5'         // Welding Torch Mk5

export const VEHICLE_CATALOG: VehicleTemplate[] = [
  {
    id: 'Sandbike',
    label: 'Sandbike',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_Sandbike_CHOAM.BP_Sandbike_CHOAM_C',
    templates: ['T1_ExtraSeat', 'T2_Inventory', 'T3_Boost', 'T4_Scanner', 'T5', 'T6'],
    kit: ['SandbikeChassis_6', 'SandbikeEngine_6', 'SandbikeGenerator_6', 'SandbikeHull_6', 'SandbikeLocomotion_6', 'SandbikeBoost_6'],
  },
  {
    id: 'Buggy',
    label: 'Buggy',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_Buggy_CHOAM.BP_Buggy_CHOAM_C',
    templates: ['T3_Inventory', 'T4_Boost', 'T5_Mining', 'T6_Combat'],
    kit: ['BuggyChassis_6', 'BuggyEngine_6', 'BuggyGenerator_6', 'BuggyHullFront_6', 'BuggyHullBack_6', 'BuggyHullBackExtra_6', 'BuggyLocomotion_6', 'BuggyBoost_6', 'BuggyInventory_6'],
  },
  {
    id: 'Tank',
    label: 'Tank',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_Tank_CHOAM.BP_Tank_CHOAM_C',
    templates: ['T6_CombatFire', 'T6_CombatDart'],
    kit: [],
  },
  {
    id: 'Sandcrawler',
    label: 'Sandcrawler',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_SandCrawler_CHOAM.BP_SandCrawler_CHOAM_C',
    templates: ['T6_Harvesting'],
    kit: ['SandcrawlerChassis_6', 'SandcrawlerEngine_6', 'SandcrawlerGenerator_6', 'SandcrawlerHull_6', 'SandcrawlerLocomotion_6', 'SandcrawlerSpiceContainer_6', 'SandcrawlerSpiceHeader_6'],
  },
  {
    id: 'TreadWheel',
    label: 'Treadwheel',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_TreadWheel.BP_TreadWheel_C',
    templates: ['T4_Passenger', 'T5_Inventory', 'T6_Boost'],
    kit: [],
  },
  {
    id: 'ContainerVehicle',
    label: 'Container Vehicle',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_ContainerVehicle.BP_ContainerVehicle_C',
    templates: ['Container'],
    kit: [],
  },
  {
    id: 'OrnithopterLight',
    label: 'Ornithopter (Light)',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/FlyingVehicles/BP_LightOrnithopter_Choam.BP_LightOrnithopter_Choam_C',
    templates: ['T4_Inventory', 'T5_Boost', 'T6_Combat'],
    kit: ['OrnithopterLightChassis_6', 'OrnithopterLightEngine_6', 'OrnithopterLightGenerator_6', 'OrnithopterLightHullFront_6', 'OrnithopterLightHullBack_6', 'OrnithopterLightLocomotion_6', 'OrnithopterLightBoost_6'],
  },
  {
    id: 'OrnithopterMedium',
    label: 'Ornithopter (Medium)',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/FlyingVehicles/BP_MediumOrnithopter_CHOAM.BP_MediumOrnithopter_CHOAM_C',
    templates: ['T5_Inventory', 'T6_Combat'],
    kit: ['OrnithopterMediumChassis_6', 'OrnithopterMediumEngine_6', 'OrnithopterMediumGenerator_6', 'OrnithopterMediumHull_6', 'OrnithopterMediumHullFront_6', 'OrnithopterMediumHullBack_6', 'OrnithopterMediumLocomotion_6', 'OrnithopterMediumBoost_6'],
  },
  {
    id: 'OrnithopterTransport',
    label: 'Ornithopter (Transport)',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/FlyingVehicles/BP_TransportOrnithopter_CHOAM.BP_TransportOrnithopter_CHOAM_C',
    templates: ['T6_Boost'],
    kit: ['OrnithopterTransportChassis_6', 'OrnithopterTransportEngine_6', 'OrnithopterTransportGenerator_6', 'OrnithopterTransportHull_6', 'OrnithopterTransportHullFront_6', 'OrnithopterTransportHullBack_6', 'OrnithopterTransportLocomotion_6', 'OrnithopterTransportBoost_6'],
  },
]
