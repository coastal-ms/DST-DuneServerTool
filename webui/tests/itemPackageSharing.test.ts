import { afterEach, describe, expect, it, vi } from 'vitest'
import { downloadItemPackage, PACKAGE_FILE_LIMIT, parseSharedItemPackage, serializeItemPackage } from '../src/util/itemPackageSharing'

const packageData = { id: 'local-id', name: 'Survival kit', items: [
  { template: 'Schematic_UniquePincushionChest', qty: 1, quality: 5 },
  { template: 'FutureMod_Item', qty: 100_000, quality: 0 },
] }
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); vi.useRealTimers() })
describe('Portable Give Packages', () => {
  it('roundtrips exact item IDs, quantities, grades and Unicode names without local identity', () => {
    const input = { ...packageData, name: 'Desert kit — Mk6', hostname: 'private-host', path: 'private-path' }
    const text = serializeItemPackage(input)
    expect(JSON.parse(text)).toEqual({ format: 'dst-item-package', version: 1, name: input.name, items: packageData.items })
    expect(parseSharedItemPackage(text)).toEqual({ name: input.name, items: packageData.items })
    expect(text).not.toContain('local-id')
    expect(text).not.toContain('private-host')
    expect(text).not.toContain('private-path')
  })
  it('ignores a sender ID and defaults a missing grade without changing the item identity', () => {
    expect(parseSharedItemPackage(JSON.stringify({ format: 'dst-item-package', version: 1, id: 'existing-id', name: 'Shared',
      items: [{ template: 'D_T2_Vehicle(Ground)_SandBike_Set', qty: 3 }] }))).toEqual({ name: 'Shared',
      items: [{ template: 'D_T2_Vehicle(Ground)_SandBike_Set', qty: 3, quality: 0 }] })
  })
  it.each([0,-1,1.5,100_001,'2',null])('rejects invalid quantity %s instead of clamping it', qty => {
    expect(() => parseSharedItemPackage(JSON.stringify({ format:'dst-item-package',version:1,name:'Kit',items:[{template:'Item',qty}] }))).toThrow(/quantity/)
  })
  it.each([-1,6,1.5,'5'])('rejects invalid grade %s', quality => {
    expect(() => serializeItemPackage({ name:'Kit',items:[{template:'Item',qty:1,quality} as never] })).toThrow(/grade/)
  })
  it('rejects damaged, unsupported and oversized files and empty packages', () => {
    for (const text of ['not json','null','[]','{}',JSON.stringify({format:'dst-item-package',version:2}),
      JSON.stringify({format:'dst-item-package',version:1,name:'Kit',items:[]})]) expect(() => parseSharedItemPackage(text)).toThrow()
    expect(() => parseSharedItemPackage(' '.repeat(PACKAGE_FILE_LIMIT+1))).toThrow(/256 KB/)
    expect(() => serializeItemPackage({name:'Kit',items:Array.from({length:101},()=>({template:'Item',qty:1,quality:0}))})).toThrow(/1–100/)
  })
  it('downloads one portable file with a safe filename and releases its object URL', () => {
    vi.useFakeTimers()
    const create=vi.fn(()=> 'blob:package'),revoke=vi.fn()
    vi.stubGlobal('URL',class extends URL { static createObjectURL=create;static revokeObjectURL=revoke })
    const click=vi.spyOn(HTMLAnchorElement.prototype,'click').mockImplementation(function(this: HTMLAnchorElement) {
      expect(this.download).toBe('A-B-kit.dst-package.json')
      expect(this.href).toBe('blob:package')
    })
    downloadItemPackage({...packageData,name:'A/B:kit'})
    expect(click).toHaveBeenCalledOnce()
    expect(create.mock.calls[0][0]).toBeInstanceOf(Blob)
    vi.runAllTimers()
    expect(revoke).toHaveBeenCalledWith('blob:package')
    expect(document.querySelector('a[download]')).toBeNull()
  })
})
