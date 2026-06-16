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
  // Named/unique top-tier modules for this vehicle (e.g. the "Mohandis" engine,
  // "Night Rider" boost) plus any special extras — delivered alongside the base
  // kit so the player also gets the best specialized variants. Empty when the
  // vehicle has no unique modules in the catalog.
  unique: string[]
  // Optional per-template delivery quantity (template id -> count) for the Give
  // Vehicle Kit action. Any template not listed defaults to 1. Lets a single part
  // be handed out in multiples (e.g. a Buggy assembles from 4 treads).
  qty?: Record<string, number>
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
    unique: ['SandbikeEngine_Unique_Speed_6', 'SandbikeBoost_Unique_LessHeat_6'],
    qty: { SandbikeLocomotion_6: 3 },
  },
  {
    id: 'Buggy',
    label: 'Buggy',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_Buggy_CHOAM.BP_Buggy_CHOAM_C',
    templates: ['T3_Inventory', 'T4_Boost', 'T5_Mining', 'T6_Combat'],
    kit: ['BuggyChassis_6', 'BuggyEngine_6', 'BuggyGenerator_6', 'BuggyHullFront_6', 'BuggyHullBack_6', 'BuggyHullBackExtra_6', 'BuggyLocomotion_6', 'BuggyBoost_6', 'BuggyInventory_6'],
    unique: ['BuggyEngine_Unique_Accelerate_06', 'BuggyBoost_Unique_LessHeat_6', 'BuggyInventory_Unique_Capacity_06', 'BuggyMining_Unique_YieldIncrease_06'],
    qty: { BuggyLocomotion_6: 4 },
  },
  {
    id: 'Tank',
    label: 'Tank',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_Tank_CHOAM.BP_Tank_CHOAM_C',
    templates: ['T6_CombatFire', 'T6_CombatDart'],
    kit: [],
    unique: [],
  },
  {
    id: 'Sandcrawler',
    label: 'Sandcrawler',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_SandCrawler_CHOAM.BP_SandCrawler_CHOAM_C',
    templates: ['T6_Harvesting'],
    kit: ['SandcrawlerChassis_6', 'SandcrawlerEngine_6', 'SandcrawlerGenerator_6', 'SandcrawlerHull_6', 'SandcrawlerSpiceContainer_6', 'SandcrawlerSpiceHeader_6'],
    unique: ['SandcrawlerEngine_Unique_Speed_06', 'SandcrawlerLocomotion_Unique_WormThreat_06', 'SandcrawlerSpiceContainer_Unique_Capacity_6'],
    qty: { SandcrawlerLocomotion_Unique_WormThreat_06: 2 },
  },
  {
    id: 'TreadWheel',
    label: 'Treadwheel',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_TreadWheel.BP_TreadWheel_C',
    templates: ['T4_Passenger', 'T5_Inventory', 'T6_Boost'],
    kit: [],
    unique: [],
  },
  {
    id: 'ContainerVehicle',
    label: 'Container Vehicle',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_ContainerVehicle.BP_ContainerVehicle_C',
    templates: ['Container'],
    kit: [],
    unique: [],
  },
  {
    id: 'OrnithopterLight',
    label: 'Ornithopter (Light)',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/FlyingVehicles/BP_LightOrnithopter_Choam.BP_LightOrnithopter_Choam_C',
    templates: ['T4_Inventory', 'T5_Boost', 'T6_Combat'],
    kit: ['OrnithopterLightChassis_6', 'OrnithopterLightEngine_6', 'OrnithopterLightGenerator_6', 'OrnithopterLightHullFront_6', 'OrnithopterLightHullBack_6', 'OrnithopterLightBoost_6'],
    unique: ['OrnithopterLightLocomotion_Unique_Speed_6', 'OrnithopterLightBoost_Unique_LessHeat_6', 'OrnithopterLightInventory_4'],
    qty: { OrnithopterLightLocomotion_Unique_Speed_6: 4 },
  },
  {
    id: 'OrnithopterMedium',
    label: 'Ornithopter (Medium)',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/FlyingVehicles/BP_MediumOrnithopter_CHOAM.BP_MediumOrnithopter_CHOAM_C',
    templates: ['T5_Inventory', 'T6_Combat'],
    kit: ['OrnithopterMediumChassis_6', 'OrnithopterMediumEngine_6', 'OrnithopterMediumGenerator_6', 'OrnithopterMediumHull_6', 'OrnithopterMediumHullFront_6', 'OrnithopterMediumHullBack_6', 'OrnithopterMediumBoost_6'],
    unique: ['OrnithopterMediumLocomotion_Unique_Strafe_6', 'OrnithopterMediumBoost_Unique_LessHeat_6', 'OrnithopterMediumInventory_5'],
    qty: { OrnithopterMediumLocomotion_Unique_Strafe_6: 6 },
  },
  {
    id: 'OrnithopterTransport',
    label: 'Ornithopter (Transport)',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/FlyingVehicles/BP_TransportOrnithopter_CHOAM.BP_TransportOrnithopter_CHOAM_C',
    templates: ['T6_Boost'],
    kit: ['OrnithopterTransportChassis_6', 'OrnithopterTransportEngine_6', 'OrnithopterTransportGenerator_6', 'OrnithopterTransportHull_6', 'OrnithopterTransportHullFront_6', 'OrnithopterTransportHullBack_6', 'OrnithopterTransportBoost_6'],
    unique: ['OrnithopterTransportLocomotion_Unique_Speed_6', 'OrnithopterTransportBoost_Unique_LessHeat_06'],
    qty: { OrnithopterTransportLocomotion_Unique_Speed_6: 8, OrnithopterTransportHullBack_6: 2, OrnithopterTransportHullFront_6: 2 },
  },
]
