import { useEffect, useMemo, useState } from 'react'
import type { SharedInventoryGroup } from '../../api/gameplay'
import type { SoloInventoryItemGroup, SoloRangedWeapon } from '../../api/solo'
import type { SoloInventoryDestination } from '../../api/solo'
import { Icon } from '../Icon'
import { InventorySlot } from '../inventory/InventorySlot'
import { DataState } from '../platform/DataState'
import { DetailPanel } from '../platform/DetailPanel'

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

function qualityLabel(item: SoloInventoryItemGroup) {
  return item.minQuality === item.maxQuality
    ? String(item.maxQuality)
    : `${item.minQuality}-${item.maxQuality}`
}

export function SoloInventoryExplorer({
  items,
  connected,
}: {
  items: SoloInventoryItemGroup[]
  connected: boolean
}) {
  const [query, setQuery] = useState('')
  const [sort, setSort] = useState<'name' | 'quantity'>('name')
  const [destinationKey, setDestinationKey] = useState('')
  const [visibleCount, setVisibleCount] = useState(100)
  const [selected, setSelected] = useState<SharedInventoryGroup | null>(null)
  const locations = useMemo(() => {
    const unique = new Map<string, string>()
    items.forEach(item => unique.set(item.destinationKey, item.destinationLabel))
    return [...unique.entries()]
      .map(([key, label]) => ({ key, label }))
      .sort((left, right) => {
        if (left.label === 'Backpack') return -1
        if (right.label === 'Backpack') return 1
        return left.label.localeCompare(right.label)
      })
  }, [items])
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
    ? items.filter(item => item.templateId.trim().toLowerCase() === selected.groupKey)
    : []
  const visibleGroups = groups.slice(0, visibleCount)

  useEffect(() => setVisibleCount(100), [destinationKey, items, query, sort])

  return (
    <section className="card p-5" aria-labelledby="solo-current-inventory-title">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 id="solo-current-inventory-title" className="flex items-center gap-2 font-semibold">
            <Icon name="PackageSearch" size={16} />
            Current inventory
          </h2>
          <p className="mt-1 text-sm text-text-muted">
            Browse grouped items already stored in the selected Solo save. This view is read-only.
          </p>
        </div>
        <span className="pill border-info/40 bg-info/10 text-info">
          {groups.length} item type{groups.length === 1 ? '' : 's'}
        </span>
      </div>

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
          {groups.length === 0 ? (
            <div className="mt-4">
              <DataState state="empty" title="No matching Solo inventory items" message="Try another item, template, or location." />
            </div>
          ) : (
            <ul className="mt-4 grid min-w-0 grid-cols-[repeat(auto-fill,minmax(min(6.5rem,100%),1fr))] gap-2.5" aria-label="Solo inventory results">
              {visibleGroups.map(group => (
                <li key={group.groupKey} className="min-w-0">
                  <InventorySlot item={group} onSelect={setSelected} />
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
                {selected.totalQuantity} total across {selected.locationCount} location{selected.locationCount === 1 ? '' : 's'}.
              </p>
            </div>
            <ul className="divide-y divide-border rounded-lg border border-border bg-surface-2 px-3">
              {selectedLocations.map(item => (
                <li key={`${item.destinationKey}:${item.templateId}`} className="flex items-center justify-between gap-4 py-3 text-sm">
                  <div className="min-w-0">
                    <p className="truncate font-medium text-text">{item.destinationLabel}</p>
                    <p className="text-xs text-text-muted">{item.occurrenceCount} stack{item.occurrenceCount === 1 ? '' : 's'} · quality {qualityLabel(item)}</p>
                  </div>
                  <span className="shrink-0 font-semibold text-accent-bright">x{item.totalQuantity}</span>
                </li>
              ))}
            </ul>
          </div>
        )}
      </DetailPanel>
    </section>
  )
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

export function SoloBackpackSlotsEditor({
  backpack,
  disabled,
  busy,
  onSave,
}: {
  backpack?: SoloInventoryDestination
  disabled: boolean
  busy: boolean
  onSave: (slots: number) => void
}) {
  const [slots, setSlots] = useState(backpack?.maxItemCount ?? 60)

  useEffect(() => {
    setSlots(backpack?.maxItemCount ?? 60)
  }, [backpack?.id, backpack?.maxItemCount])

  return (
    <section className="card p-5" aria-labelledby="solo-backpack-slots-title">
      <h2 id="solo-backpack-slots-title" className="flex items-center gap-2 font-semibold">
        <Icon name="Backpack" size={16} />
        Backpack slot capacity
      </h2>
      <p className="mt-1 text-sm text-text-muted">
        Change the backpack item-slot limit independently from inventory volume. The game must be fully closed; DST retains and verifies the save.
      </p>
      {!backpack ? (
        <div className="mt-4">
          <DataState state="empty" title="No Solo backpack inventory found" />
        </div>
      ) : (
        <div className="mt-4 flex flex-col gap-3 sm:flex-row sm:items-end">
          <label className="w-full text-sm font-medium text-text sm:max-w-xs">
            Maximum backpack slots
            <input
              type="number"
              min={1}
              max={100_000}
              step={1}
              className="input mt-1 min-h-11 w-full"
              value={slots}
              disabled={disabled || busy}
              onChange={event => setSlots(Number(event.target.value))}
            />
          </label>
          <button
            type="button"
            className="btn-primary min-h-11"
            disabled={disabled || busy || !Number.isSafeInteger(slots) || slots < 1 || slots > 100_000}
            onClick={() => onSave(slots)}
          >
            <Icon name={busy ? 'LoaderCircle' : 'Save'} size={14} className={busy ? 'animate-spin' : undefined} />
            {busy ? 'Saving...' : 'Set backpack slots'}
          </button>
        </div>
      )}
    </section>
  )
}
