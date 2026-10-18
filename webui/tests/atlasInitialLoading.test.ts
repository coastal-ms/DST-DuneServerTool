import fs from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
const html = fs.readFileSync(path.resolve(import.meta.dirname, '../../app/tools/DuneAtlas/index.html'), 'utf8')
const source = html.slice(html.indexOf('const loadedLayerCounts='), html.indexOf('function spiceLayer('))
describe('initial layer count loading', () => {
 it('spins only until the first result per region, including a zero result', () => {
  document.body.innerHTML = '<span id="count">-</span>'
  const region = { value: 'DeepDesert' }, state = { live: true, refreshing: false }
  const render = new Function('document', 'region', 'state', source + ';return renderLayerCount')(document, region, state)
  const count = document.getElementById('count')!
  render('count', false, 0)
  expect(count.classList.contains('initial-loading')).toBe(true)
  expect(count.getAttribute('aria-label')).toBe('Loading')
  render('count', true, 0)
  expect(count.textContent).toBe('0')
  expect(count.hasAttribute('aria-busy')).toBe(false)
  render('count', false, 0)
  expect(count.classList.contains('initial-loading')).toBe(false)
  region.value = 'HaggaBasin'
  render('count', false, 0)
  expect(count.classList.contains('initial-loading')).toBe(true)
  state.live = false
  render('count', false, 0)
  expect(count.classList.contains('initial-loading')).toBe(false)
  state.refreshing = true
  render('count', false, 0)
  expect(count.classList.contains('initial-loading')).toBe(true)
  render('count', true, 12)
  expect(count.textContent).toBe('12')
  expect(count.classList.contains('initial-loading')).toBe(false)
 })
})
