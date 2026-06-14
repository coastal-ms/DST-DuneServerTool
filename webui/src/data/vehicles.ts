// Vehicle spawn catalog — the deliverable CHOAM vehicle blueprints and their
// tier template variants. `className` is the Unreal actor-class path sent to the
// game's SpawnVehicleAt RMQ command; `templates` are the optional tier loadouts
// (sent as TemplateName). Spawning at a player requires the player to be online.
export interface VehicleTemplate {
  id: string
  label: string
  className: string
  templates: string[]
}

export const VEHICLE_CATALOG: VehicleTemplate[] = [
  {
    id: 'Sandbike',
    label: 'Sandbike',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_Sandbike_CHOAM.BP_Sandbike_CHOAM_C',
    templates: ['T1_ExtraSeat', 'T2_Inventory', 'T3_Boost', 'T4_Scanner', 'T5', 'T6'],
  },
  {
    id: 'Buggy',
    label: 'Buggy',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_Buggy_CHOAM.BP_Buggy_CHOAM_C',
    templates: ['T3_Inventory', 'T4_Boost', 'T5_Mining', 'T6_Combat'],
  },
  {
    id: 'Tank',
    label: 'Tank',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_Tank_CHOAM.BP_Tank_CHOAM_C',
    templates: ['T6_CombatFire', 'T6_CombatDart'],
  },
  {
    id: 'Sandcrawler',
    label: 'Sandcrawler',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_SandCrawler_CHOAM.BP_SandCrawler_CHOAM_C',
    templates: ['T6_Harvesting'],
  },
  {
    id: 'TreadWheel',
    label: 'Treadwheel',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_TreadWheel.BP_TreadWheel_C',
    templates: ['T4_Passenger', 'T5_Inventory', 'T6_Boost'],
  },
  {
    id: 'ContainerVehicle',
    label: 'Container Vehicle',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/GroundVehicles/BP_ContainerVehicle.BP_ContainerVehicle_C',
    templates: ['Container'],
  },
  {
    id: 'OrnithopterLight',
    label: 'Ornithopter (Light)',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/FlyingVehicles/BP_LightOrnithopter_Choam.BP_LightOrnithopter_Choam_C',
    templates: ['T4_Inventory', 'T5_Boost', 'T6_Combat'],
  },
  {
    id: 'OrnithopterMedium',
    label: 'Ornithopter (Medium)',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/FlyingVehicles/BP_MediumOrnithopter_CHOAM.BP_MediumOrnithopter_CHOAM_C',
    templates: ['T5_Inventory', 'T6_Combat'],
  },
  {
    id: 'OrnithopterTransport',
    label: 'Ornithopter (Transport)',
    className: '/Game/Dune/Systems/Vehicles/Blueprints/FlyingVehicles/BP_TransportOrnithopter_CHOAM.BP_TransportOrnithopter_CHOAM_C',
    templates: ['T6_Boost'],
  },
]
