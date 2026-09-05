import { Fragment, useEffect, useMemo, useState } from 'react'
import {
  getAugmentCatalog,
  type AugmentCatalog,
  type AugmentSelection,
} from '../api/gameplay'

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

export function maxAugmentGrade(gradeEffects: Record<string, string[]>): number {
  return Math.max(
    ...Object.keys(gradeEffects).map(Number).filter(Number.isInteger),
  )
}

export function AugmentPicker({
  templateId,
  displayName,
  selected,
  disabled,
  onSelectedChange,
}: {
  templateId: string
  displayName: string
  selected: AugmentSelection[]
  disabled: boolean
  onSelectedChange: (value: AugmentSelection[]) => void
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
        return tags.some(itemTag => augment.tags.some(augmentTag =>
          itemTag === augmentTag || itemTag.startsWith(`${augmentTag}.`)))
      })
      .sort(([, left], [, right]) =>
        maxAugmentGrade(right.gradeEffects) - maxAugmentGrade(left.gradeEffects)
        || left.name.localeCompare(right.name))
  }, [catalog, limit, tags])

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
    const current = selected.find(value => value.id === augmentId)
    if (current) {
      onSelectedChange(selected.filter(value => value.id !== augmentId))
    } else if (selected.length < limit) {
      const grades = Object.keys(catalog.augments[augmentId].gradeEffects)
        .map(Number)
        .filter(Number.isInteger)
      onSelectedChange([...selected, { id: augmentId, quality: Math.max(...grades) }])
    }
  }

  return (
    <div className="space-y-2">
      <div className="flex items-center justify-between gap-3">
        <span className="text-[11px] uppercase tracking-wider text-text-dim">
          Augments ({selected.length}/{limit})
        </span>
      </div>
      <div className="max-h-72 overflow-y-auto rounded-lg border border-border bg-surface-2/50 p-2 space-y-1">
        {eligible.map(([id, augment], index) => {
          const selection = selected.find(value => value.id === id)
          const grades = Object.keys(augment.gradeEffects)
            .map(Number)
            .filter(Number.isInteger)
            .sort((left, right) => left - right)
          const displayGrade = selection?.quality ?? Math.max(...grades)
          const maximumGrade = maxAugmentGrade(augment.gradeEffects)
          const previousMaximum = index > 0
            ? maxAugmentGrade(eligible[index - 1][1].gradeEffects)
            : null
          return (
            <Fragment key={id}>
              {maximumGrade !== previousMaximum && (
                <div className="mt-2 first:mt-0 border-b border-border pb-1 text-[10px] font-semibold uppercase tracking-wider text-text-dim">
                  Maximum Grade {maximumGrade}
                </div>
              )}
              <div className="flex items-start gap-2 rounded px-2 py-1.5 hover:bg-surface-2">
                <input
                  type="checkbox"
                  checked={!!selection}
                  disabled={disabled || (!selection && selected.length >= limit)}
                  onChange={() => toggle(id)}
                  className="mt-0.5 accent-ibad"
                />
                <button
                  type="button"
                  disabled={disabled}
                  onClick={() => toggle(id)}
                  className="min-w-0 flex-1 text-left"
                >
                  <span className="block text-sm text-text">{augment.name}</span>
                  <span className="block text-[11px] text-text-dim">
                    {augment.gradeEffects[String(displayGrade)].join(' · ')}
                  </span>
                </button>
                {selection && (
                  <label className="flex items-center gap-1 text-[11px] text-text-muted">
                    Grade
                    <select
                      value={selection.quality}
                      disabled={disabled}
                      onChange={event => onSelectedChange(selected.map(value =>
                        value.id === id ? { ...value, quality: Number(event.target.value) } : value))}
                      className="rounded bg-surface-2 border border-border px-1.5 py-1 text-text"
                    >
                      {grades.map(value => <option key={value} value={value}>{value}</option>)}
                    </select>
                  </label>
                )}
              </div>
            </Fragment>
          )
        })}
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
