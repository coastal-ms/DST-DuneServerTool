import { describe, expect, it } from 'vitest'
import type { PortResult, PortStatus } from '../src/api/types'
import { portResultPresentation, summarizeTcpPorts } from '../src/util/portStatusPresentation'

function status(results: PortResult[]): PortStatus {
  return { mode: 'builtin', publicIp: '192.0.2.1', results }
}

function tcp(port: number, value: PortResult['status']): PortResult {
  return { port, protocol: 'TCP', label: `TCP ${port}`, status: value }
}

describe('TCP port summary presentation', () => {
  it('renders all-open checks green with an open ratio', () => {
    expect(summarizeTcpPorts(status([tcp(80, 'open'), tcp(443, 'open')]))).toEqual({
      label: '2/2 open',
      tone: 'text-success',
      heading: 'TCP ports open',
      state: 'open',
    })
  })

  it('renders an explicit closed result red', () => {
    expect(summarizeTcpPorts(status([tcp(80, 'open'), tcp(443, 'closed')]))).toEqual({
      label: '1/2 open',
      tone: 'text-danger',
      heading: 'TCP port status',
      state: 'closed',
    })
  })

  it('renders all-unknown checks as warning without a false zero-open ratio', () => {
    expect(summarizeTcpPorts(status([tcp(31982, 'unknown')]))).toEqual({
      label: 'Unknown',
      tone: 'text-warning',
      heading: 'TCP port status',
      state: 'unknown',
    })
  })

  it('distinguishes mixed open and unknown checks without counting unknown as closed', () => {
    expect(summarizeTcpPorts(status([tcp(80, 'open'), tcp(31982, 'unknown')]))).toEqual({
      label: '1 open · 1 unknown',
      tone: 'text-warning',
      heading: 'TCP port status',
      state: 'unknown',
    })
  })
})

describe('individual port presentation', () => {
  it.each([
    ['open', 'Open', 'pill-success'],
    ['closed', 'Closed', 'pill-danger'],
    ['unknown', 'Unknown', 'pill-warning'],
    ['udp-skip', 'Unchecked', 'pill-muted'],
  ] as const)('maps %s to visible text and its class contract', (value, label, pillClass) => {
    expect(portResultPresentation(tcp(31982, value))).toEqual({ label, pillClass })
  })

  describe('operator-driven external verification', () => {
    it('URL-encodes the public address without making a request', async () => {
      const { externalPortVerificationUrl } = await import('../src/util/portStatusPresentation')
      expect(externalPortVerificationUrl('example.test/? value')).toBe(
        'https://dnschecker.org/port-scanner.php?query=example.test%2F%3F+value',
      )
    })
  })
})
