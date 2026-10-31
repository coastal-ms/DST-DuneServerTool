import { isValidTemplateId, type GiveItemEntry, type ItemPackage } from '../api/gameplay'

export const PACKAGE_FILE_LIMIT = 256 * 1024
const FORMAT = 'dst-item-package'
type SharedPackage = Pick<ItemPackage, 'name' | 'items'>

function validatePackage(value: unknown): SharedPackage {
  if (!value || typeof value !== 'object') throw new Error('Choose a valid DST package file.')
  const raw = value as Record<string, unknown>
  if (typeof raw.name !== 'string' || !raw.name.trim() || raw.name.trim().length > 80) {
    throw new Error('Package name must contain 1–80 characters.')
  }
  if (!Array.isArray(raw.items) || raw.items.length < 1 || raw.items.length > 100) {
    throw new Error('A package must contain 1–100 items.')
  }
  const items: GiveItemEntry[] = raw.items.map((entry, index) => {
    if (!entry || typeof entry !== 'object') throw new Error(`Item ${index + 1} is invalid.`)
    const item = entry as Record<string, unknown>
    if (typeof item.template !== 'string' || item.template.trim().length > 256 || !isValidTemplateId(item.template)) {
      throw new Error(`Item ${index + 1} needs a valid item template ID.`)
    }
    if (typeof item.qty !== 'number' || !Number.isInteger(item.qty) || item.qty < 1 || item.qty > 100_000) {
      throw new Error(`Item ${index + 1} quantity must be a whole number from 1 to 100,000.`)
    }
    const quality = item.quality === undefined ? 0 : item.quality
    if (typeof quality !== 'number' || !Number.isInteger(quality) || quality < 0 || quality > 5) {
      throw new Error(`Item ${index + 1} grade must be a whole number from 0 to 5.`)
    }
    return { template: item.template.trim(), qty: item.qty, quality }
  })
  return { name: raw.name.trim(), items }
}

export function serializeItemPackage(pkg: SharedPackage): string {
  return JSON.stringify({ format: FORMAT, version: 1, ...validatePackage(pkg) }, null, 2) + '\n'
}

export function parseSharedItemPackage(text: string): SharedPackage {
  if (new TextEncoder().encode(text).byteLength > PACKAGE_FILE_LIMIT) throw new Error('Package files must be 256 KB or smaller.')
  let raw: Record<string, unknown>
  try { raw = JSON.parse(text.replace(/^\uFEFF/, '')) } catch { throw new Error('This file does not contain valid package JSON.') }
  if (!raw || typeof raw !== 'object' || raw.format !== FORMAT) throw new Error('Choose a DST package export file.')
  if (raw.version !== 1) throw new Error('This package file version is not supported. Update DST or ask for a compatible export.')
  return validatePackage(raw)
}

export function downloadItemPackage(pkg: SharedPackage): void {
  const content = serializeItemPackage(pkg)
  const filename = pkg.name.replace(/[<>:"/\\|?*\u0000-\u001f]/g, '-').replace(/[. ]+$/g, '').slice(0, 80) || 'DST-package'
  const url = URL.createObjectURL(new Blob([content], { type: 'application/json' }))
  const link = document.createElement('a')
  link.href = url
  link.download = `${filename}.dst-package.json`
  document.body.append(link)
  link.click()
  link.remove()
  window.setTimeout(() => URL.revokeObjectURL(url), 0)
}
