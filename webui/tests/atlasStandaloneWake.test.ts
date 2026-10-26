import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { JSDOM } from 'jsdom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { waitFor } from '@testing-library/react'

const html = readFileSync(resolve(process.cwd(), '../app/tools/DuneAtlas/index.html'), 'utf8')
const source = html.match(/<script id="standalone-screen-awake">([\s\S]*?)<\/script>/)![1]
const windows: JSDOM[] = []
function fixture(request: ReturnType<typeof vi.fn>, embedded = false) {
  const dom = new JSDOM('<!doctype html><body></body>', { url: 'https://portal.example.test', runScripts: 'outside-only', pretendToBeVisual: true })
  windows.push(dom)
  const w = dom.window
  const idle = { paused: false }
  Object.defineProperty(w.navigator, 'wakeLock', { value: { request } })
  Object.defineProperty(w, 'viewerIdle', { value: idle })
  if (embedded) Object.defineProperty(w, 'parent', { value: {} })
  w.eval(source)
  return { w, idle }
}
function sentinel() {
  const lock = new EventTarget() as EventTarget & { release: ReturnType<typeof vi.fn> }
  lock.release = vi.fn().mockResolvedValue(undefined)
  return lock
}
afterEach(() => { for (const dom of windows.splice(0)) dom.window.close() })

describe('popped-out map screen wake lock', () => {
  it('holds a lock outside the portal and releases when this viewer pauses', async () => {
    const first = sentinel(), second = sentinel(), request = vi.fn().mockResolvedValueOnce(first).mockResolvedValueOnce(second)
    const { w, idle } = fixture(request)
    await waitFor(() => expect(w.document.body.textContent).toContain('Screen keep-awake active'))
    expect(request).toHaveBeenCalledExactlyOnceWith('screen')
    idle.paused = true
    w.document.dispatchEvent(new w.Event('dst-atlas-screen-sync'))
    expect(first.release).toHaveBeenCalledOnce()
    expect(w.document.body.textContent).toContain('Live map paused')
    idle.paused = false
    w.document.dispatchEvent(new w.Event('dst-atlas-screen-sync'))
    await waitFor(() => expect(request).toHaveBeenCalledTimes(2))
    w.dispatchEvent(new w.Event('pagehide'))
    expect(second.release).toHaveBeenCalledOnce()
  })
  it('leaves embedded wake-lock ownership with the portal', () => {
    const request = vi.fn()
    const { w } = fixture(request, true)
    expect(request).not.toHaveBeenCalled()
    expect(w.document.querySelector('button')).toBeNull()
  })
  it('recovers a released lock once and allows an explicit retry after refusal', async () => {
    const first = sentinel(), second = sentinel()
    const request = vi.fn().mockResolvedValueOnce(first).mockRejectedValueOnce(new Error('Battery policy')).mockResolvedValueOnce(second)
    const { w } = fixture(request)
    await waitFor(() => expect(w.document.body.textContent).toContain('Screen keep-awake active'))
    first.dispatchEvent(new Event('release'))
    await waitFor(() => expect(request).toHaveBeenCalledTimes(2))
    expect(w.document.body.textContent).toContain('tap to retry')
    w.document.querySelector('button')!.click()
    await waitFor(() => expect(w.document.body.textContent).toContain('Screen keep-awake active'))
    expect(request).toHaveBeenCalledTimes(3)
    w.dispatchEvent(new w.Event('pagehide'))
    expect(second.release).toHaveBeenCalledOnce()
  })
  it('releases a pending request that completes after the window is left', async () => {
    let resolve!: (lock: unknown) => void
    const request = vi.fn(() => new Promise(r => { resolve = r })), lock = sentinel()
    const { w } = fixture(request)
    w.dispatchEvent(new w.Event('pagehide'))
    resolve(lock)
    await waitFor(() => expect(lock.release).toHaveBeenCalledOnce())
  })
})
