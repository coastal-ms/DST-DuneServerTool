// Cosmetics tab — list unlocked, add from catalog, remove inline.
import { useState } from 'react'
import { Icon } from '../../components/Icon'
import { SectionCard, Toast } from './Shared'
import { CatalogPicker } from './CatalogPicker'
import { addCosmetic, removeCosmetic } from '../../api/characters'
import type { CharacterDetail, ItemCatalog, CatalogItem } from '../../api/types'

type Props = {
  charId: number
  detail: CharacterDetail
  catalog: ItemCatalog | null
  catalogLoading: boolean
  onChanged?: () => void
}

export function CosmeticsTab({ charId, detail, catalog, catalogLoading, onChanged }: Props) {
  const [pickerOpen, setPickerOpen] = useState(false)
  const [busyId, setBusyId] = useState<string | null>(null)
  const [ok, setOk] = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)

  const lookup = (id: string) => catalog?.items.find(i => i.templateId === id)

  async function onAdd(item: CatalogItem) {
    setErr(null); setOk(null)
    try {
      await addCosmetic(charId, item.templateId)
      setOk(`Added ${item.name}.`)
      setPickerOpen(false)
      onChanged?.()
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    }
  }

  async function onRemove(id: string) {
    setErr(null); setOk(null); setBusyId(id)
    try {
      await removeCosmetic(charId, id)
      setOk('Removed.')
      onChanged?.()
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setBusyId(null)
    }
  }

  return (
    <SectionCard title="Cosmetics" icon="Shirt" actions={
      <button type="button" className="btn-primary" onClick={() => setPickerOpen(true)}>
        <Icon name="Plus" size={14} /> Add Cosmetic
      </button>
    }>
      <Toast kind="error" message={err} onClear={() => setErr(null)} />
      <Toast kind="success" message={ok} onClear={() => setOk(null)} />

      {detail.cosmetics.length === 0 ? (
        <div className="text-sm text-text-muted py-6 text-center">
          <Icon name="ShoppingBag" size={20} className="mx-auto mb-2 opacity-40" />
          No cosmetics unlocked for this character yet.
        </div>
      ) : (
        <ul className="divide-y divide-border">
          {detail.cosmetics.map(id => {
            const item = lookup(id)
            return (
              <li key={id} className="py-2 flex items-center justify-between gap-3">
                <div className="min-w-0">
                  <div className="text-sm text-text truncate">{item?.name ?? id}</div>
                  <div className="text-xs text-text-dim font-mono truncate">
                    {item?.category ? `${item.category} · ` : ''}{id}
                  </div>
                </div>
                <button type="button" className="btn-danger px-2 py-1 text-xs"
                        disabled={busyId === id} onClick={() => onRemove(id)}>
                  <Icon name={busyId === id ? 'Loader2' : 'Trash2'} size={13}
                        className={busyId === id ? 'animate-spin' : ''} /> Remove
                </button>
              </li>
            )
          })}
        </ul>
      )}

      <CatalogPicker
        open={pickerOpen}
        title="Add Cosmetic"
        catalog={catalog}
        loading={catalogLoading}
        onPick={onAdd}
        onClose={() => setPickerOpen(false)}
      />
    </SectionCard>
  )
}
