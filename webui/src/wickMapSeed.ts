export type WickMapSeedSource = 'deep-desert' | 'farm'

type CoriolisMapSeed = { map: string; seed: number }

export function selectWickMapSeed(
  maps: CoriolisMapSeed[],
  farmSeed: number,
  deepDesertRunning: boolean | null,
): { seed: number | null; source: WickMapSeedSource } {
  if (deepDesertRunning === false) {
    return { seed: farmSeed, source: 'farm' }
  }

  const friendly = maps.find(m => m.map === 'DeepDesert')
  const fallback = maps.find(m => m.map.startsWith('DeepDesert'))
  return { seed: friendly?.seed ?? fallback?.seed ?? null, source: 'deep-desert' }
}
