import { getSharedInventory, getSharedInventoryOccurrences, type SharedInventoryQuery, type SharedInventoryOccurrencesQuery } from '../../api/gameplay'

// One mounted inventory explorer owns these reads. No timer or idle work.
export class InventoryReadSession {
  private reads = new Map<string, Promise<unknown>>()
  clear() { this.reads.clear() }
  private read<T>(kind: string, query: object, fetch: () => Promise<T>): Promise<T> {
    const key = kind + JSON.stringify(query, Object.keys(query).sort())
    const existing = this.reads.get(key)
    if (existing) return existing as Promise<T>
    if (this.reads.size >= 64) this.reads.delete(this.reads.keys().next().value!)
    const pending = fetch().catch(error => {
      if (this.reads.get(key) === pending) this.reads.delete(key)
      throw error
    })
    this.reads.set(key, pending)
    return pending
  }
  groups(query: SharedInventoryQuery) { return this.read('groups', query, () => getSharedInventory(query)) }
  occurrences(query: SharedInventoryOccurrencesQuery) { return this.read('items', query, () => getSharedInventoryOccurrences(query)) }
}
