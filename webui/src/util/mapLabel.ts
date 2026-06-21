// Friendly display names for the technical map/section identifiers reported by
// the battlegroup (e.g. "SH_Arrakeen" -> "Arrakeen"). Mirrors the backend
// _Get-DuneSpinUpLabel in app/server/lib/MapSpinUp.ps1 so the Dashboard "Game
// Servers" table reads the same way as the Map Spin-Up page. Anything not in
// the table falls back to a generic prettifier (strip known prefixes,
// underscores -> spaces).

const MAP_LABELS: Record<string, string> = {
  // Always-on maps that never appear in director.ini but do show up in the
  // battlegroup status game-servers table.
  Survival_1: 'Hagga Basin',
  Overmap: 'Overmap',
  // On-demand / instanced maps (kept in sync with the backend label table).
  SH_Arrakeen: 'Arrakeen',
  SH_HarkoVillage: 'Harko Village',
  DeepDesert_1: 'Deep Desert',
  DLC_Story_LostHarvest_EcolabA: 'Lost Harvest: Ecolab A',
  DLC_Story_LostHarvest_EcolabB: 'Lost Harvest: Ecolab B',
  DLC_Story_LostHarvest_ForgottenLab: 'Lost Harvest: Forgotten Lab',
  CB_Dungeon_Hephaestus: 'Dungeon: Hephaestus',
  CB_Dungeon_OldCarthag: 'Dungeon: Old Carthag',
  CB_Dungeon_ThePit: 'Dungeon: The Pit',
  CB_Story_BanditFortress01: 'Bandit Fortress',
  Story_ArtOfKanly: 'The Art of Kanly',
  Story_ProcesVerbal: 'Procès-Verbal',
  Story_Faction_Outpost_Atre: 'Faction Outpost: Atreides',
  Story_Faction_Outpost_Hark: 'Faction Outpost: Harkonnen',
  Story_HeighlinerDungeon: 'Heighliner Dungeon',
}

const PREFIXES = [
  'CB_Ecolab_',
  'CB_Overland_',
  'CB_Story_',
  'CB_Dungeon_',
  'DLC_Story_',
  'Story_',
  'CB_',
  'SH_',
]

export function mapLabel(map: string | null | undefined): string {
  const raw = (map ?? '').trim()
  if (!raw) return '—'
  if (MAP_LABELS[raw]) return MAP_LABELS[raw]
  let s = raw
  for (const p of PREFIXES) {
    if (s.startsWith(p)) {
      s = s.slice(p.length)
      break
    }
  }
  return s.replace(/_/g, ' ').trim() || raw
}
