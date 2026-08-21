import { describe, expect, it } from 'vitest'
import { buildBrowserPortalLink } from '../src/util/browserPortalLink'

describe('buildBrowserPortalLink', () => {
  it('matches the browser portal URL used by the QR and copy action', () => {
    expect(buildBrowserPortalLink('https://example.ts.net/', 'abc+/='))
      .toBe('https://example.ts.net/?key=abc%2B%2F%3D')
  })

  it('requires both the remote address and stable token', () => {
    expect(buildBrowserPortalLink('', 'token')).toBe('')
    expect(buildBrowserPortalLink('https://example.ts.net', '')).toBe('')
  })
})
