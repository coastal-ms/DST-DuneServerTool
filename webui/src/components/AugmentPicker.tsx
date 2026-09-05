import { useEffect, useMemo, useState } from 'react'
import { getAugmentCatalog, type AugmentCatalog } from '../api/gameplay'

let catalogPromise: Promise<AugmentCatalog> | null = null

function loadCatalog() {
  catalogPromise ??= getAugmentCatalog()
  return catalogPromise
}

export function resolveAugmentItemTags(
  catalog: AugmentCatalog,
  templateId: string,
  displayName: string,
): string[] {
  if (templateId.toLowerCase().endsWith('_schematic')) return []
  return catalog.itemAliases[templateId] ?? catalog.methodItems[displayName] ?? []
}

export function augmentSlotLimit(tags: string[]): number {
  if (tags.some(tag => tag.startsWith('Items.Clothes'))) return 2
  if (tags.some(tag => tag.startsWith('Items.Holsters'))) return 3
  return 0
}

export function AugmentPicker({
  templateId,
  displayName,
  selected,
  quality,
  disabled,
  onSelectedChange,
  onQualityChange,
}: {
  templateId: string
  displayName: string
  selected: string[]
  quality: number
  disabled: boolean
  onSelectedChange: (value: string[]) => void
  onQualityChange: (value: number) => void
}) {
  const [catalog, setCatalog] = useState<AugmentCatalog | null>(null)
  const [loadFailed, setLoadFailed] = useState(false)

  useEffect(() => {
    void loadCatalog().then(setCatalog).catch(() => setLoadFailed(true))
  }, [])

  const tags = useMemo(
    () => catalog ? resolveAugmentItemTags(catalog, templateId, displayName) : [],
    [catalog, templateId, displayName],
  )
  const limit = augmentSlotLimit(tags)
  const eligible = useMemo(() => {
    if (!catalog || limit === 0) return []
    return Object.entries(catalog.augments)
      .filter(([, augment]) => {
        if (!augment.gradeEffects[String(quality)]) return false
        return tags.some(itemTag => augment.tags.some(augmentTag =>
          itemTag === augmentTag || itemTag.startsWith(`${augmentTag}.`)))
      })
      .sort(([, left], [, right]) => left.name.localeCompare(right.name))
  }, [catalog, limit, quality, tags])

  if (!templateId) return null
  if (loadFailed) {
    return <p className="text-xs text-danger">Augment compatibility data could not be loaded.</p>
  }
  if (!catalog) {
    return <p className="text-xs text-text-dim">Loading compatible augments...</p>
  }
  if (limit === 0) {
    return <p className="text-xs text-text-dim">No verified augment slots are available for this item.</p>
  }

  const toggle = (augmentId: string) => {
    if (selected.includes(augmentId)) {
      onSelectedChange(selected.filter(value => value !== augmentId))
    } else if (selected.length < limit) {
      onSelectedChange([...selected, augmentId])
    }
  }

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between gap-3">
        <span className="text-[11px] uppercase tracking-wider text-text-dim">
          Augments ({selected.length}/{limit})
        </span>
        <label className="flex items-center gap-2 text-xs text-text-muted">
          Grade
          <select
            value={quality}
            disabled={disabled}
            onChange={event => {
              onSelectedChange([])
              onQualityChange(Number(event.target.value))
            }}
            className="rounded-lg bg-surface-2 border border-border px-2 py-1 text-text"
          >
            {[1, 2, 3, 4, 5].map(value => <option key={value} value={value}>{value}</option>)}
          </select>
        </label>
      </div>
      <div className="max-h-44 overflow-y-auto rounded-lg border border-border bg-surface-2/50 p-2 space-y-1">
        {eligible.map(([id, augment]) => (
          <label key={id} className="flex items-start gap-2 rounded px-2 py-1.5 hover:bg-surface-2 cursor-pointer">
            <input
              type="checkbox"
              checked={selected.includes(id)}
              disabled={disabled || (!selected.includes(id) && selected.length >= limit)}
              onChange={() => toggle(id)}
              className="mt-0.5 accent-ibad"
            />
            <span className="min-w-0">
              <span className="block text-sm text-text">{augment.name}</span>
              <span className="block text-[11px] text-text-dim">
                {augment.gradeEffects[String(quality)].join(' · ')}
              </span>
            </span>
          </label>
        ))}
        {eligible.length === 0 && (
          <p className="px-2 py-1 text-xs text-text-dim">No compatible augments support this grade.</p>
        )}
      </div>
      <p className="text-[11px] text-text-dim">
        Optional. Selected augments are granted at maximum rolls. Pre-augmented grants require the player or Solo game to be offline.
      </p>
    </div>
  )
}
