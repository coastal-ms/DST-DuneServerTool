import { beforeEach, expect, it, vi } from 'vitest'
const groups = vi.hoisted(() => vi.fn())
const occurrences = vi.hoisted(() => vi.fn())
vi.mock('../src/api/gameplay', () => ({getSharedInventory: groups, getSharedInventoryOccurrences: occurrences}))
import { InventoryReadSession } from '../src/components/inventory/InventoryReadSession'
beforeEach(() => vi.resetAllMocks())
it('shares pending and visited page reads while keeping cursor and scope separate', async () => {
  let finish!: (value: unknown) => void
  groups.mockImplementationOnce(() => new Promise(resolve => { finish = resolve })).mockResolvedValue({page: 2})
  const session = new InventoryReadSession()
  const first = session.groups({playerId: 1, limit: 28})
  const shared = session.groups({limit: 28, playerId: 1})
  expect(groups).toHaveBeenCalledTimes(1)
  finish({page: 1})
  expect(await shared).toEqual(await first)
  await session.groups({playerId: 1, limit: 28})
  expect(groups).toHaveBeenCalledTimes(1)
  await session.groups({playerId: 1, cursor: 'next', limit: 28})
  await session.groups({playerId: 2, limit: 28})
  expect(groups).toHaveBeenCalledTimes(3)
})
it('reuses hovered item details and invalidates all reads after refresh or edit', async () => {
  occurrences.mockResolvedValue({data: {items: []}})
  const session = new InventoryReadSession()
  const query = {templateId: 'knife', playerId: 1, limit: 28}
  await session.occurrences(query)
  await session.occurrences(query)
  expect(occurrences).toHaveBeenCalledTimes(1)
  session.clear()
  await session.occurrences(query)
  expect(occurrences).toHaveBeenCalledTimes(2)
})
it('retries failed reads and does not let an old rejected request discard a newer read', async () => {
  let fail!: (reason: Error) => void
  groups.mockImplementationOnce(() => new Promise((_resolve,reject) => {fail = reject})).mockResolvedValue({fresh: true})
  const session = new InventoryReadSession()
  const old = session.groups({playerId: 1}).catch(() => null)
  session.clear()
  await session.groups({playerId: 1})
  fail(new Error('old request'))
  await old
  await session.groups({playerId: 1})
  expect(groups).toHaveBeenCalledTimes(2)
})
