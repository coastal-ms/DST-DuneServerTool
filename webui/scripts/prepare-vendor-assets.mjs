import { cpSync, mkdirSync, readFileSync, rmSync, readdirSync, statSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import path from 'node:path'
const root = fileURLToPath(new URL('..', import.meta.url))
const source = path.join(root, 'node_modules/monaco-editor')
const definition = JSON.parse(readFileSync(path.join(source, 'package.json'), 'utf8'))
const wanted = JSON.parse(readFileSync(path.join(root, 'package.json'), 'utf8')).dependencies['monaco-editor']
if (definition.version !== wanted) throw new Error('Monaco package does not match the pinned version')
const output = path.join(root, 'public/vendor/monaco')
if (!output.startsWith(path.join(root, 'public/vendor') + path.sep) || path.basename(output) !== 'monaco') throw new Error('Unsafe generated vendor output')
rmSync(output, { recursive: true, force: true })
mkdirSync(output, { recursive: true })
cpSync(path.join(source, 'min/vs'), path.join(output, 'vs'), { recursive: true })
// DST exposes a SQL editor only. Keep its core worker and tokenizer; omit
// workers used exclusively by TypeScript, CSS, HTML and JSON language services.
let omittedBytes = 0
for (const name of readdirSync(path.join(output, 'vs/assets'))) {
  if (/^(ts|css|html|json)\.worker-.*\.js$/.test(name)) {
    const file = path.join(output, 'vs/assets', name)
    omittedBytes += statSync(file).size
    rmSync(file)
  }
}
// The existing editor uses the default English messages and has no locale override.
for (const name of readdirSync(path.join(output, 'vs'))) {
  if (/^nls\.messages\.(?!js\.js$).+\.js\.js$/.test(name)) {
    const file = path.join(output, 'vs', name)
    omittedBytes += statSync(file).size
    rmSync(file)
  }
}
console.log(`Omitted ${omittedBytes} bytes of unused editor workers and translations`)
cpSync(path.join(source, 'LICENSE'), path.join(output, 'LICENSE.txt'))
cpSync(path.join(source, 'ThirdPartyNotices.txt'), path.join(output, 'ThirdPartyNotices.txt'))
console.log(`Prepared local Monaco ${definition.version} with its license notices`)

await import('./prepare-third-party-notices.mjs')
