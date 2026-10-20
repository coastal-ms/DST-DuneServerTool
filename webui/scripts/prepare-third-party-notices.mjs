import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
const root = fileURLToPath(new URL('..', import.meta.url))
const lock = JSON.parse(readFileSync(path.join(root, 'package-lock.json'), 'utf8'))
const entries = []
let output = 'DST THIRD-PARTY COMPONENT NOTICES\n\nThese components retain their own licenses. DST does not grant rights to Funcom game artwork.\nThe inventory and map art source records identify game artwork separately.\n\n'
for (const [folder, data] of Object.entries(lock.packages)) {
  if (!folder || data.dev || data.devOptional) continue
  const directory = path.join(root, folder)
  const packageFile = path.join(directory, 'package.json')
  if (!existsSync(packageFile)) continue
  const definition = JSON.parse(readFileSync(packageFile, 'utf8'))
  const notices = readdirSync(directory).filter(name => /^(unlicense|licen[cs]e|copying|copyright|notice|thirdpartynotices)(\.|$)/i.test(name))
  const record = { name:definition.name, version:definition.version, license:data.license || definition.license, packageSource:data.resolved, repository:definition.repository, notices }
  entries.push(record)
  output += `\n${'='.repeat(72)}\n${record.name} ${record.version}\nLicense: ${record.license}\nSource package: ${record.packageSource}\n`
  for (const name of notices) output += `\n--- ${name} ---\n${readFileSync(path.join(directory, name), 'utf8')}\n`
}
writeFileSync(path.join(root, 'public/THIRD-PARTY-NOTICES.txt'), output)
writeFileSync(path.join(root, 'public/THIRD-PARTY-SOURCES.json'), JSON.stringify(entries, null, 2)+'\n')
console.log(`Prepared notices for ${entries.length} declared production dependencies; ${entries.filter(x=>!x.notices.length).length} have metadata-only license declarations`)
