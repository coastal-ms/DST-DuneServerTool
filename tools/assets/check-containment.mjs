import fs from 'node:fs'
import path from 'node:path'
import { createHash } from 'node:crypto'
import { fileURLToPath } from 'node:url'
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
function verifyRecord(folder, recordName) {
  const record = JSON.parse(fs.readFileSync(path.join(folder, recordName), 'utf8'))
  for (const item of record.files) {
    if (path.basename(item.file) !== item.file) throw new Error('Unsafe packaged art path')
    const file = path.join(folder, 'icons', item.file)
    if (createHash('sha256').update(fs.readFileSync(file)).digest('hex') !== item.sha256) throw new Error(`Packaged art differs: ${file}`)
  }
}
for (const relative of ['app/tools/DuneAtlas', 'app/resources/solo-mods/dst-solo-live-map/Companion']) {
  const folder = path.join(root, relative)
  verifyRecord(folder, 'ART-SOURCES.json')
  verifyRecord(folder, 'TERRAIN-SOURCES.json')
  const source = fs.readFileSync(path.join(folder, 'atlas_assets.py'), 'utf8')
  if (/urllib|urlopen|https?:\/\//i.test(source)) throw new Error('Map art resolver must remain local')
}
const icons = JSON.parse(fs.readFileSync(path.join(root, 'webui/src/data/item-icons.json'), 'utf8'))
const sources = JSON.parse(fs.readFileSync(path.join(root, 'webui/public/item-icons/sources.json'), 'utf8'))
for (const image of sources.files) {
  if (createHash('sha256').update(fs.readFileSync(path.join(root, 'webui/public/item-icons', image.file))).digest('hex') !== image.sha256) throw new Error('Inventory art differs')
}
for (const image of Object.values(icons)) if (!/^[a-f0-9]{20}\.webp$/.test(image) || !fs.existsSync(path.join(root, 'webui/public/item-icons', image))) throw new Error('Inventory icon is not packaged')
const resolver = fs.readFileSync(path.join(root, 'webui/src/components/inventory/InventoryItemIcon.tsx'), 'utf8')
if (/\bfetch\s*\(|cdn-hosted|holidy/i.test(resolver)) throw new Error('Inventory art must not fetch external metadata')
const dist = path.join(root, 'webui/dist')
for (const file of ['vendor/monaco/vs/loader.js', 'vendor/monaco/vs/editor/editor.main.js', 'vendor/monaco/LICENSE.txt', 'vendor/monaco/ThirdPartyNotices.txt', 'THIRD-PARTY-NOTICES.txt']) if (!fs.existsSync(path.join(dist, file))) throw new Error(`Missing packaged editor dependency: ${file}`)
console.log(`Local art and editor packaging verified: ${sources.files.length} inventory images and 13 terrain layouts in both adapters`)
