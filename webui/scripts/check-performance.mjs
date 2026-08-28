import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const baseline = JSON.parse(fs.readFileSync(path.join(root, 'performance-baseline.json'), 'utf8'))
const html = fs.readFileSync(path.join(root, 'dist', 'index.html'), 'utf8')
const scriptSources = [...html.matchAll(/<script\b[^>]*\bsrc="([^"]+\.js)"/g)].map(match => match[1])

if (scriptSources.length === 0) {
  throw new Error('Performance check could not find an initial JavaScript entry in dist/index.html.')
}

const visited = new Set()

function collectStaticModule(relativePath) {
  const normalized = relativePath.replace(/^\/+/, '').replaceAll('\\', '/')
  if (visited.has(normalized)) return 0
  visited.add(normalized)
  const absolute = path.join(root, 'dist', normalized)
  const source = fs.readFileSync(absolute, 'utf8')
  let bytes = fs.statSync(absolute).size
  const directory = path.posix.dirname(normalized)
  const staticImports = [
    ...source.matchAll(/\b(?:import|export)\b(?!\s*\()[^;]*?\bfrom\s*["']([^"']+\.js)["']/g),
    ...source.matchAll(/\bimport\s*["']([^"']+\.js)["']/g),
  ]
  for (const match of staticImports) {
    if (!match[1].startsWith('.')) continue
    bytes += collectStaticModule(path.posix.normalize(path.posix.join(directory, match[1])))
  }
  return bytes
}

const initialBytes = scriptSources.reduce(
  (total, source) => total + collectStaticModule(source),
  0,
)

if (initialBytes > baseline.maximumInitialJavaScriptBytes) {
  throw new Error(
    `Initial JavaScript is ${initialBytes} bytes; budget is ${baseline.maximumInitialJavaScriptBytes} bytes `
      + `(${baseline.maximumGrowthPercent}% over the ${baseline.baselineInitialJavaScriptBytes}-byte baseline).`,
  )
}

const change = ((initialBytes - baseline.baselineInitialJavaScriptBytes) / baseline.baselineInitialJavaScriptBytes) * 100
console.log(
  `Initial JavaScript: ${initialBytes} bytes across ${visited.size} static module chunk(s) `
    + `(${change.toFixed(1)}% vs baseline; budget ${baseline.maximumInitialJavaScriptBytes}).`,
)
