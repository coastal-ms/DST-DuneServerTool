import { existsSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

describe('retired remote transports', () => {
  it('removes the native project and Cloudflare card while keeping browser access', () => {
    expect(existsSync(resolve(process.cwd(), '..', 'mobile', 'package-lock.json'))).toBe(false)
    expect(existsSync(resolve(process.cwd(), 'src/pages/settings/RemoteAccessCard.tsx'))).toBe(false)
    const settings = readFileSync(resolve(process.cwd(), 'src/pages/Settings.tsx'), 'utf8')
    expect(settings).toContain('<BrowserAccessCard />')
    expect(settings).not.toContain('<RemoteAccessCard />')
    const browser = readFileSync(resolve(process.cwd(), 'src/pages/settings/BrowserAccessCard.tsx'), 'utf8')
    expect(browser).toContain('Tailscale Funnel')
    expect(browser).toContain('<PortalAccountsManager')
    expect(browser).not.toContain('cfAccessClientSecret')
    expect(browser).not.toContain('legacy custom domain')
  })
})