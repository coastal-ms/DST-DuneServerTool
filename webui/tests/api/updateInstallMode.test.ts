import { afterEach, describe, expect, it, vi } from 'vitest'
import { installUpdate } from '../../src/api/update'

afterEach(() => {
  vi.restoreAllMocks()
  sessionStorage.clear()
})

describe('installUpdate initiation mode', () => {
  it('sends explicit silent banner mode', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ launched: true }), { status: 200 }),
    )
    await installUpdate({ mode: 'silent', source: 'banner' })
    expect(fetchMock).toHaveBeenCalledWith('/api/update/install', expect.objectContaining({
      method: 'POST',
      body: JSON.stringify({ mode: 'silent', source: 'banner' }),
    }))
  })

  it('sends explicit interactive Settings mode and preserves reinstall', async () => {
    const fetchMock = vi.spyOn(globalThis, 'fetch').mockResolvedValue(
      new Response(JSON.stringify({ launched: true }), { status: 200 }),
    )
    await installUpdate({ mode: 'interactive', source: 'settings', reinstall: true })
    expect(fetchMock).toHaveBeenCalledWith('/api/update/install?reinstall=1', expect.objectContaining({
      body: JSON.stringify({ mode: 'interactive', source: 'settings' }),
    }))
  })
})
