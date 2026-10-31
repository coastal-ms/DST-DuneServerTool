import { useEffect, useMemo, useState } from 'react'
import type { SharedInventoryGroup } from '../../api/gameplay'
import type {
  SoloInventoryDestination,
  SoloInventoryItemGroup,
  SoloInventoryItemOccurrence,
  SoloRangedWeapon,
} from '../../api/solo'
import { Icon } from '../Icon'
import { useInventoryImages } from '../inventory/useInventoryImages'
import { InventorySlot } from '../inventory/InventorySlot'
import { DataState } from '../platform/DataState'
import { DetailPanel } from '../platform/DetailPanel'
import { CollapsibleCard } from '../CollapsibleCard'
import { StackEditor, DurabilityEditor, WaterEditor } from '../../pages/gameplay/players/sections'
import type { InventoryItem } from '../../api/gameplay'

const emptyMetadata = {
  category: '',
  tier: 0,
  rarity: '',
  icon: '',
  stackMaximum: 0,
  volume: 0,
  vendorPrice: 0,
  isGradeable: false,
}

export function buildSoloInventoryGroups(items: SoloInventoryItemGroup[]): SharedInventoryGroup[] {
  const grouped = new Map<string, SharedInventoryGroup>()
  const locations = new Map<string, Set<string>>()
  items.forEach(item => {
    const key = item.templateId.trim().toLowerCase()
    if (!key) return
    const current = grouped.get(key)
    if (!current) {
      grouped.set(key, {
        groupKey: key,
        templateId: item.templateId,
        displayName: item.displayName || item.templateId,
        totalQuantity: item.totalQuantity,
        occurrenceCount: item.occurrenceCount,
        locationCount: 1,
        quality: {
          min: item.minQuality,
          max: item.maxQuality,
          mixed: item.minQuality !== item.maxQuality,
        },
        metadata: emptyMetadata,
      })
      locations.set(key, new Set([item.destinationKey]))
      return
    }
    current.totalQuantity += item.totalQuantity
    current.occurrenceCount += item.occurrenceCount
    current.quality.min = Math.min(current.quality.min, item.minQuality)
    current.quality.max = Math.max(current.quality.max, item.maxQuality)
    current.quality.mixed = current.quality.min !== current.quality.max
    const itemLocations = locations.get(key)!
    itemLocations.add(item.destinationKey)
    current.locationCount = itemLocations.size
  })
  return [...grouped.values()]
}

export function filterSoloInventoryItemsByLocation(
  items: SoloInventoryItemGroup[],
  destinationKey: string,
) {
  return destinationKey
    ? items.filter(item => item.destinationKey === destinationKey)
    : items
}

export function buildSoloInventoryLocations(
  items: SoloInventoryItemGroup[],
  inventories: SoloInventoryDestination[],
) {
  const unique = new Map(inventories.map(inventory => [inventory.key, inventory.label]))
  items.forEach(item => unique.set(item.destinationKey, item.destinationLabel))
  return [...unique.entries()]
    .map(([key, label]) => ({ key, label }))
    .sort((left, right) => {
      if (left.label === 'Backpack') return -1
      if (right.label === 'Backpack') return 1
      if (left.label === 'Bank Storage') return -1
      if (right.label === 'Bank Storage') return 1
      return left.label.localeCompare(right.label)
    })
}

export function SoloInventoryExplorer({
  items,
  inventories,
  connected,
  disabled,
  busyItemId,
  onDelete,
  onDeleteGroup,
  onEdit,
}: {
  items: SoloInventoryItemGroup[]
  inventories: SoloInventoryDestination[]
  connected: boolean
  disabled: boolean
  busyItemId: number | null
  onEdit?: (item: SoloInventoryItemOccurrence, field: 'stack' | 'water' | 'durability', values: Record<string, number>) => Promise<void>
  onDelete: (
    item: SoloInventoryItemOccurrence,
    location: SoloInventoryItemGroup,
    quantity: number,
  ) => void
  onDeleteGroup?: (templateId: string, displayName: string, destination: string,
    destinationLabel: string, count: number, total: number) => void
}) {
  const [loadImages, setLoadImages] = useInventoryImages()
  const [query, setQuery] = useState('')
  const [sort, setSort] = useState<'name' | 'quantity'>('name')
  const [chosenDestinationKey, setDestinationKey] = useState<string | null>(null)
  const [visibleCount, setVisibleCount] = useState(100)
  const [selected, setSelected] = useState<SharedInventoryGroup | null>(null)
  const [deleteQuantities, setDeleteQuantities] = useState<Record<number, string>>({})
  const [occurrenceLimit, setOccurrenceLimit] = useState(100)
  const locations = useMemo(
    () => buildSoloInventoryLocations(items, inventories),
    [inventories, items],
  )
  const backpackKey = inventories.find(inventory => inventory.kind === 'backpack')?.key
    ?? items.find(item => item.destinationKind === 'backpack')?.destinationKey
    ?? locations[0]?.key
    ?? ''
  const destinationKey = chosenDestinationKey ?? backpackKey

  useEffect(() => {
    if (chosenDestinationKey && !locations.some(location => location.key === chosenDestinationKey)) {
      setDestinationKey(null)
    }
  }, [chosenDestinationKey, locations])
  const groups = useMemo(() => {
    const needle = query.trim().toLowerCase()
    const visibleItems = filterSoloInventoryItemsByLocation(items, destinationKey)
    return buildSoloInventoryGroups(visibleItems)
      .filter(item => !needle
        || item.displayName.toLowerCase().includes(needle)
        || item.templateId.toLowerCase().includes(needle)
        || visibleItems.some(row => row.templateId.toLowerCase() === item.groupKey
          && row.destinationLabel.toLowerCase().includes(needle)))
      .sort((left, right) => sort === 'quantity'
        ? right.totalQuantity - left.totalQuantity || left.displayName.localeCompare(right.displayName)
        : left.displayName.localeCompare(right.displayName))
  }, [destinationKey, items, query, sort])
  const selectedLocations = selected
    ? filterSoloInventoryItemsByLocation(items, destinationKey)
      .filter(item => item.templateId.trim().toLowerCase() === selected.groupKey)
    : []
  const deletableLocations = selectedLocations.filter(location => location.destinationKind !== 'equipment')
  const deleteCount = deletableLocations.reduce((sum, location) => sum + location.occurrenceCount, 0)
  const deleteTotal = deletableLocations.reduce((sum, location) => sum + location.totalQuantity, 0)
  const occurrenceRows = selectedLocations.flatMap(location =>
    (location.occurrences ?? []).map(occurrence => ({ location, occurrence })))
  useEffect(() => setOccurrenceLimit(100), [selected?.groupKey, destinationKey])
  const visibleGroups = groups.slice(0, visibleCount)

  useEffect(() => setVisibleCount(100), [destinationKey, items, query, sort])
  useEffect(() => {
    setSelected(current => current
      ? groups.find(group => group.groupKey === current.groupKey) ?? null
      : null)
  }, [groups])

  return (
    <CollapsibleCard
      id="solo-current-inventory"
      title="Current inventory"
      icon="PackageSearch"
      subtitle="Browse and edit items in the Backpack, equipment, Bank Storage and supported built storage. Close Dune before editing; unequip equipment before deleting it."
      headerRight={
        <span className="pill border-info/40 bg-info/10 text-info">
          {groups.length} item type{groups.length === 1 ? '' : 's'}
        </span>
      }
      className="mb-0"
    >

      {connected && items.length > 0 && (
        <>
          <div className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-[minmax(14rem,1fr)_minmax(12rem,.5fr)_minmax(12rem,.45fr)]">
            <label className="text-sm font-medium text-text">
              Search current inventory
              <input
                className="input mt-1 min-h-11 w-full"
                value={query}
                maxLength={200}
                placeholder="Item, template, or location"
                onChange={event => setQuery(event.target.value)}
              />
            </label>
            <label className="text-sm font-medium text-text">
              Inventory location
              <select
                className="input mt-1 min-h-11 w-full"
                value={destinationKey}
                onChange={event => setDestinationKey(event.target.value)}
              >
                <option value="">All locations</option>
                {locations.map(location => (
                  <option key={location.key} value={location.key}>{location.label}</option>
                ))}
              </select>
            </label>
            <label className="text-sm font-medium text-text">
              Sort by
              <select
                className="input mt-1 min-h-11 w-full"
                value={sort}
                onChange={event => setSort(event.target.value as 'name' | 'quantity')}
              >
                <option value="name">Name A-Z</option>
                <option value="quantity">Total quantity</option>
              </select>
            </label>
          </div>
          <label className="mt-3 flex min-h-11 items-center gap-2 text-sm">
            <input type="checkbox" checked={loadImages} onChange={event => setLoadImages(event.target.checked)} />Load images
          </label>
          {groups.length === 0 ? (
            <div className="mt-4">
              <DataState state="empty" title="No matching Solo inventory items" message="Try another item, template, or location." />
            </div>
          ) : (
            <ul className={loadImages ? "mt-4 grid min-w-0 grid-cols-[repeat(auto-fill,minmax(min(6.5rem,100%),1fr))] gap-2.5" : "mt-4 grid min-w-0 grid-cols-1 gap-1.5"} aria-label="Solo inventory results">
              {visibleGroups.map(group => (
                <li key={group.groupKey} className="min-w-0">
                  <InventorySlot item={group} showImages={loadImages} onSelect={setSelected} />
                </li>
              ))}
            </ul>
          )}
          {visibleCount < groups.length && (
            <div className="mt-4 flex justify-center">
              <button type="button" className="btn-secondary min-h-11" onClick={() => setVisibleCount(count => count + 100)}>
                <Icon name="ChevronDown" size={14} />
                Load 100 more
              </button>
            </div>
          )}
        </>
      )}
      {!connected && <div className="mt-4"><DataState state="unavailable" title="Connect a Solo profile to browse inventory" /></div>}
      {connected && items.length === 0 && <div className="mt-4"><DataState state="empty" title="No items found in supported Solo inventories" /></div>}

      <DetailPanel open={selected !== null} title={selected?.displayName ?? 'Inventory item'} onClose={() => setSelected(null)}>
        {selected && (
          <div className="space-y-4">
            <div>
              <p className="break-all font-mono text-xs text-text-muted">{selected.templateId}</p>
              <p className="mt-2 text-sm text-text">
                {selected.totalQuantity.toLocaleString()} total across {selected.locationCount} location{selected.locationCount === 1 ? '' : 's'}.
              </p>
            </div>
            {onDeleteGroup && deleteCount > 0 && (
              <button type="button" className="btn-secondary min-h-11 text-danger"
                disabled={disabled || busyItemId !== null}
                onClick={() => onDeleteGroup(selected.templateId, selected.displayName,
                  destinationKey || 'all', locations.find(l => l.key === destinationKey)?.label ?? 'all supported locations',
                  deleteCount, deleteTotal)}>
                <Icon name="Trash2" size={15} />
                Delete all {deleteTotal.toLocaleString()} ({deleteCount.toLocaleString()} stack{deleteCount === 1 ? '' : 's'})
              </button>
            )}
            <ul className="divide-y divide-border rounded-lg border border-border bg-surface-2 px-3">
              {occurrenceRows.slice(0, occurrenceLimit).map(({ location, occurrence }) => {
                const rawQuantity = deleteQuantities[occurrence.itemId] ?? String(occurrence.stackSize)
                const quantity = Number(rawQuantity)
                const validQuantity = Number.isSafeInteger(quantity)
                  && quantity >= (occurrence.stackSize === 0 ? 0 : 1)
                  && quantity <= occurrence.stackSize
                return (
                  <li key={occurrence.itemId} className="flex flex-wrap items-center justify-between gap-4 py-3 text-sm">
                    <div className="min-w-0">
                      <button type="button" className="max-w-full truncate text-left font-medium text-accent-bright underline decoration-dotted underline-offset-4 hover:decoration-solid"
                        title={`Open ${location.destinationLabel} inventory`}
                        disabled={busyItemId !== null}
                        onClick={() => { setDestinationKey(location.destinationKey); setQuery(''); setSelected(null) }}>
                        {location.destinationLabel}
                      </button>
                      <p className="text-xs text-text-muted">Item {occurrence.itemId} · quality {occurrence.quality} · stack x{occurrence.stackSize}</p>
                    </div>
                    {location.destinationKind === 'equipment' ? (
                      <span className="text-xs text-text-muted">Unequip to delete</span>
                    ) : <div className="flex shrink-0 items-end gap-2">
                      <label className="text-xs font-medium text-text-muted">
                        Delete quantity
                        <input
                          type="number"
                          className="input mt-1 h-9 w-20 text-right font-semibold text-accent-bright"
                          min={occurrence.stackSize === 0 ? 0 : 1}
                          max={occurrence.stackSize}
                          step={1}
                          value={rawQuantity}
                          disabled={disabled || busyItemId !== null}
                          onChange={event => setDeleteQuantities(current => ({
                            ...current,
                            [occurrence.itemId]: event.target.value,
                          }))}
                        />
                      </label>
                      <button
                        type="button"
                        className="btn-icon min-h-11 min-w-11 text-danger"
                        aria-label={`Delete ${location.displayName} from ${location.destinationLabel}`}
                        title="Delete item"
                        disabled={disabled || busyItemId !== null || !validQuantity}
                        onClick={() => onDelete(occurrence, location, quantity)}
                      >
                        <Icon name={busyItemId === occurrence.itemId ? 'LoaderCircle' : 'Trash2'} size={15} className={busyItemId === occurrence.itemId ? 'animate-spin' : undefined} />
                      </button>
                    </div>}
                    {onEdit && occurrence.revision && <SoloItemEditors key={`${occurrence.itemId}:${occurrence.revision}`}
                      item={occurrence} name={location.displayName} disabled={disabled || busyItemId !== null} onEdit={onEdit} />}
                  </li>
                )
              })}
            </ul>
            {occurrenceLimit < occurrenceRows.length && (
              <button type="button" className="btn-secondary" onClick={() => setOccurrenceLimit(n => n + 100)}>
                Load 100 more stacks
              </button>
            )}
          </div>
        )}
      </DetailPanel>
    </CollapsibleCard>
  )
}

function SoloItemEditors({ item, name, disabled, onEdit }: {
  item: SoloInventoryItemOccurrence; name: string; disabled: boolean
  onEdit: (item: SoloInventoryItemOccurrence, field: 'stack' | 'water' | 'durability', values: Record<string, number>) => Promise<void>
}) {
  const [open, setOpen] = useState(false)
  const view: InventoryItem = { id: item.itemId, template_id: item.templateId, name, stack_size: item.stackSize, quality: item.quality,
    durability: item.durabilityStats ? String(item.durabilityStats.CurrentDurability ?? 0) : 'N/A',
    max_durability: String(item.durabilityStats?.MaxDurability ?? 0),
    decayed_max_durability: String(item.durabilityStats?.DecayedMaxDurability ?? item.durabilityStats?.MaxDurability ?? 0),
    water_amount: String(item.waterStats?.CurrentAmount ?? 0), water_type: 'mL', water_capacity: item.waterStats?.MaxAmount }
  const run = async (fn: () => Promise<{message: string}>) => { try { await fn(); return true } catch { return false } }
  const save = (field: 'stack' | 'water' | 'durability', values: Record<string, number>) => async () => {
    await onEdit(item, field, values); return { message: 'Saved.' }
  }
  return <div className="w-full">
    <button type="button" className="btn-secondary" disabled={disabled} onClick={() => setOpen(value => !value)} aria-expanded={open}>
      <Icon name="Pencil" size={14} /> Edit {name}
    </button>
    {open && <div className="player-item-editors mt-2">
      <StackEditor item={view} busy={disabled} isOnline={false} run={run} onClose={() => {}} onSave={quantity => save('stack', {quantity})()} />
      {item.durabilityStats && <DurabilityEditor item={view} busy={disabled} isOnline={false} solo run={run} onClose={() => {}}
        onSave={(maximum,current,decayed) => save('durability', {maximum,current,decayed})()} />}
      {item.waterStats && <WaterEditor item={view} busy={disabled} solo run={run} onClose={() => {}} onSave={amount => save('water', {amount})()} />}
    </div>}
  </div>
}

export function SoloWeaponAmmoEditor({
  weapons,
  disabled,
  busy,
  onSave,
}: {
  weapons: SoloRangedWeapon[]
  disabled: boolean
  busy: boolean
  onSave: (weapon: SoloRangedWeapon, ammo: number) => void
}) {
  const [itemId, setItemId] = useState(weapons[0]?.itemId ?? 0)
  const weapon = weapons.find(item => item.itemId === itemId) ?? weapons[0]
  const [ammo, setAmmo] = useState(weapon?.currentAmmo ?? 0)

  useEffect(() => {
    if (!weapon) {
      setItemId(0)
      setAmmo(0)
      return
    }

    if (itemId !== weapon.itemId) setItemId(weapon.itemId)
    setAmmo(weapon.currentAmmo)
  }, [itemId, weapon])

  return (
    <section className="card p-5" aria-labelledby="solo-weapon-ammo-title">
      <h2 id="solo-weapon-ammo-title" className="flex items-center gap-2 font-semibold">
        <Icon name="Crosshair" size={16} />
        Ranged weapon ammo
      </h2>
      <p className="mt-1 text-sm text-text-muted">
        Set the loaded ammo stored on one ranged weapon. The game must be fully closed; DST retains and verifies the save.
      </p>
      <div className="mt-3 flex max-w-[75ch] items-start gap-2 rounded-lg border border-info/35 bg-info/10 px-3 py-2 text-xs text-text">
        <Icon name="Info" size={14} className="mt-0.5 shrink-0 text-info" />
        <span>
          Values up to 16,777,215 count down normally. Use 2,000,000,000 for infinite ammo.
          Values between those points may not decrease reliably because the game stores ammo with 32-bit float precision.
        </span>
      </div>
      {weapons.length === 0 ? (
        <div className="mt-4">
          <DataState state="empty" title="No ranged weapons with editable ammo found" />
        </div>
      ) : (
        <div className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-[minmax(14rem,1fr)_minmax(9rem,.35fr)_auto] sm:items-end">
          <label className="text-sm font-medium text-text">
            Weapon
            <select
              className="input mt-1 min-h-11 w-full"
              value={weapon?.itemId ?? 0}
              disabled={disabled || busy}
              onChange={event => {
                const next = weapons.find(item => item.itemId === Number(event.target.value))
                if (!next) return
                setItemId(next.itemId)
                setAmmo(next.currentAmmo)
              }}
            >
              {weapons.map(item => (
                <option key={item.itemId} value={item.itemId}>
                  {item.displayName} - {item.destinationLabel} - {item.currentAmmo} loaded
                </option>
              ))}
            </select>
          </label>
          <label className="text-sm font-medium text-text">
            Loaded ammo
            <input
              type="number"
              min={0}
              max={2_000_000_000}
              step={1}
              className="input mt-1 min-h-11 w-full"
              value={ammo}
              disabled={disabled || busy}
              onChange={event => setAmmo(Number(event.target.value))}
            />
          </label>
          <button
            type="button"
            className="btn-primary min-h-11"
            disabled={disabled || busy || !weapon || !Number.isSafeInteger(ammo) || ammo < 0 || ammo > 2_000_000_000}
            onClick={() => weapon && onSave(weapon, ammo)}
          >
            <Icon name={busy ? 'LoaderCircle' : 'Save'} size={14} className={busy ? 'animate-spin' : undefined} />
            {busy ? 'Saving...' : 'Set ammo'}
          </button>
        </div>
      )}
    </section>
  )
}
