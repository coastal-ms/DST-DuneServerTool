import names from './data/atlas-station-names.json'

/** Community search names supplement the game's generic buried-station label. */
export function getAtlasStationName(layout: number, sector: string, type: string): string | null {
  if (type !== 'testing-station') return null
  const matches = names.stations.filter(station => station.layout === layout && station.sector === sector)
  return matches.length === 1 ? matches[0].name : null
}
