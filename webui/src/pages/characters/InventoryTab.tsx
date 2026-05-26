// Inventory tab — pick a writable inventory, see its items, add from catalog or remove.
import { useMemo, useState } from 'react'
import { Icon } from '../../components/Icon'
import { SectionCard, Toast } from './Shared'
import { CatalogPicker } from './CatalogPicker'
import { addInventoryItem, removeItem } from '../../api/characters'
import type { CharacterDetail, CharacterDefs, ItemCatalog, CatalogItem } from '../../api/types'

type Props = {
  detail: CharacterDetail
  defs: CharacterDefs
  catalog: ItemCatalog | null
  catalogLoading: boolean
  onChanged?: () => void
}

function categoryStackLimit(category: string | undefined, defs: CharacterDefs): number {
  if (!category) return defs.defaultStackLimit
  return defs.stackLimits[category] ?? defs.defaultStackLimit
}

function isEquipmentCategory(category: string | undefined, defs: CharacterDefs): boolean {
  if (!category) return false
  return defs.equipmentCategoryPrefixes.some(p => category.toLowerCase().startsWith(p.toLowerCase()))
}

export function InventoryTab({ detail, defs, catalog, catalogLoading, onChanged }: Props) {
  const writableTypeSet = useMemo(() => new Set(defs.writableInvTypes.map(t => t.type)), [defs])
  const writable = useMemo(
    () => detail.inventory.inventories.filter(i => writableTypeSet.has(i.inventoryType)),
    [detail, writableTypeSet],
  )

  const [selectedInvId, setSelectedInvId] = useState<number | null>(
    writable.length > 0 ? writable[0].id : null,
  )
  const [pickerOpen, setPickerOpen]   = useState(false)
  const [stackSize, setStackSize]     = useState('1')
  const [busyItem, setBusyItem]       = useState<number | null>(null)
  const [ok, setOk]   = useState<string | null>(null)
  const [err, setErr] = useState<string | null>(null)

  const selectedInv = writable.find(i => i.id === selectedInvId) ?? writable[0] ?? null
  const items = selectedInv
    ? detail.inventory.items.filter(it => it.inventoryId === selectedInv.id)
    : []

  const typeLabel = (t: number) => defs.writableInvTypes.find(w => w.type === t)?.label ?? `Type ${t}`
  const lookup = (tmpl: string) => catalog?.items.find(c => c.templateId === tmpl)

  async function onAdd(item: CatalogItem) {
    if (!selectedInv) return
    setErr(null); setOk(null)
    try {
      const cap = categoryStackLimit(item.category, defs)
      const requested = Math.max(1, Math.floor(Number(stackSize) || 1))
      const stack = Math.min(requested, cap)
      const isEq = isEquipmentCategory(item.category, defs)
      await addInventoryItem(selectedInv.id, item.templateId, stack, isEq)
      setOk(`Added ${item.name} × ${stack} to ${typeLabel(selectedInv.inventoryType)}.`)
      setPickerOpen(false)
      onChanged?.()
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    }
  }

  async function onRemove(itemId: number) {
    setErr(null); setOk(null); setBusyItem(itemId)
    try {
      await removeItem(itemId)
      setOk('Item removed.')
      onChanged?.()
    } catch (e) {
      setErr(e instanceof Error ? e.message : String(e))
    } finally {
      setBusyItem(null)
    }
  }

  return (
    <SectionCard title="Inventory" icon="Backpack" actions={
      <button type="button" className="btn-primary" disabled={!selectedInv}
              onClick={() => setPickerOpen(true)}>
        <Icon name="Plus" size={14} /> Add Item
      </button>
    }>
      <Toast kind="error" message={err} onClear={() => setErr(null)} />
      <Toast kind="success" message={ok} onClear={() => setOk(null)} />

      {writable.length === 0 ? (
        <div className="text-sm text-text-muted py-6 text-center">
          <Icon name="PackageOpen" size={20} className="mx-auto mb-2 opacity-40" />
          No editable inventories for this character.
        </div>
      ) : (
        <>
          <div className="flex flex-wrap items-center gap-2 mb-4">
            <label className="text-xs text-text-muted">Container:</label>
            <select
              value={selectedInvId ?? ''}
              onChange={e => setSelectedInvId(Number(e.target.value))}
              className="px-3 py-1.5 rounded-lg bg-surface-2 border border-border text-sm
                         focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
            >
              {writable.map(inv => (
                <option key={inv.id} value={inv.id}>
                  {typeLabel(inv.inventoryType)} · id {inv.id} · {inv.maxItemCount} slots
                </option>
              ))}
            </select>
            <span className="text-xs text-text-dim">{items.length} items</span>
          </div>

          {items.length === 0 ? (
            <div className="text-sm text-text-muted py-6 text-center border border-dashed border-border rounded-lg">
              Container is empty.
            </div>
          ) : (
            <div className="border border-border rounded-lg overflow-hidden">
              <table className="w-full text-sm">
                <thead className="bg-surface-2 text-text-muted text-xs uppercase tracking-wider">
                  <tr>
                    <th className="text-left px-3 py-2 font-medium w-12">Slot</th>
                    <th className="text-left px-3 py-2 font-medium">Item</th>
                    <th className="text-right px-3 py-2 font-medium w-20">Stack</th>
                    <th className="px-3 py-2 w-24"></th>
                  </tr>
                </thead>
                <tbody>
                  {items
                    .slice()
                    .sort((a, b) => a.positionIndex - b.positionIndex)
                    .map(it => {
                      const meta = lookup(it.templateId)
                      return (
                        <tr key={it.id} className="border-t border-border hover:bg-surface-2/40">
                          <td className="px-3 py-1.5 font-mono text-xs text-text-dim">{it.positionIndex}</td>
                          <td className="px-3 py-1.5">
                            <div className="text-text">{meta?.name ?? it.templateId}</div>
                            <div className="text-xs text-text-dim font-mono">
                              {meta?.category ? `${meta.category} · ` : ''}{it.templateId}
                            </div>
                          </td>
                          <td className="px-3 py-1.5 text-right font-mono">{it.stackSize}</td>
                          <td className="px-3 py-1.5 text-right">
                            <button type="button" className="btn-danger px-2 py-1 text-xs"
                                    disabled={busyItem === it.id} onClick={() => onRemove(it.id)}>
                              <Icon name={busyItem === it.id ? 'Loader2' : 'Trash2'} size={13}
                                    className={busyItem === it.id ? 'animate-spin' : ''} />
                            </button>
                          </td>
                        </tr>
                      )
                    })}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}

      <CatalogPicker
        open={pickerOpen}
        title="Add Item to Inventory"
        catalog={catalog}
        loading={catalogLoading}
        onPick={onAdd}
        onClose={() => setPickerOpen(false)}
        extra={
          <div className="flex items-center gap-1.5">
            <label className="text-xs text-text-muted">Stack:</label>
            <input
              type="number"
              min={1}
              value={stackSize}
              onChange={e => setStackSize(e.target.value)}
              className="w-20 px-2 py-1.5 rounded-lg bg-surface-2 border border-border text-sm font-mono
                         focus:outline-none focus:ring-2 focus:ring-ibad focus:border-ibad/50"
            />
          </div>
        }
      />
    </SectionCard>
  )
}
