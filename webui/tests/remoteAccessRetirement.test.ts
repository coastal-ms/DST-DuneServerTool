import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

describe('remote access retirement guidance', () => {
  it('keeps Expo functional while directing users to the Tailscale Browser Portal', () => {
    const nativeSource = readFileSync(
      resolve(process.cwd(), '..', 'mobile', 'app', 'index.tsx'),
      'utf8',
    )
    const settingsSource = readFileSync(
      resolve(process.cwd(), 'src', 'pages', 'settings', 'MobileAppCard.tsx'),
      'utf8',
    )

    expect(nativeSource).toContain('Native app retirement planned')
    expect(nativeSource).toContain('Browser Portal')
    expect(nativeSource).toContain('Tailscale link or QR code')
    expect(settingsSource).toContain('Native mobile apps are being retired')
    expect(settingsSource).toContain('Tailscale remote access and this')
    expect(settingsSource).toContain('responsive portal remain supported')
  })

  it('states the stable-release cutoff for legacy Cloudflare support', () => {
    const source = readFileSync(
      resolve(process.cwd(), 'src', 'pages', 'settings', 'RemoteAccessCard.tsx'),
      'utf8',
    )

    expect(source).toContain('scheduled for removal when the')
    expect(source).toContain('current v15 test line promotes to stable')
    expect(source).toContain('Migrate before the v15 stable release')
  })
})
