import type { PortResult, PortStatus } from '../api/types'

export type PortTone = 'text-success' | 'text-danger' | 'text-warning' | 'text-text-muted'

export function summarizeTcpPorts(ports: PortStatus | null | undefined): {
  label: string
  tone: PortTone
  heading: string
  state: 'open' | 'closed' | 'unknown' | 'disabled'
} {
  if (ports?.mode === 'disabled') {
    return { label: 'Disabled', tone: 'text-text-muted', heading: 'Port checks', state: 'disabled' }
  }

  const tcp = Array.isArray(ports?.results)
    ? ports.results.filter(result => result.protocol === 'TCP')
    : []
  const open = tcp.filter(result => result.status === 'open').length
  const closed = tcp.filter(result => result.status === 'closed').length
  const unknown = tcp.length - open - closed

  if (closed > 0) {
    return {
      label: `${open}/${open + closed} open`,
      tone: 'text-danger',
      heading: 'TCP port status',
      state: 'closed',
    }
  }
  if (unknown > 0) {
    return {
      label: open > 0 ? `${open} open · ${unknown} unknown` : 'Unknown',
      tone: 'text-warning',
      heading: 'TCP port status',
      state: 'unknown',
    }
  }
  if (open > 0) {
    return { label: `${open}/${open} open`, tone: 'text-success', heading: 'TCP ports open', state: 'open' }
  }
  return { label: 'Unknown', tone: 'text-warning', heading: 'TCP port status', state: 'unknown' }
}

export function externalPortVerificationUrl(publicIp: string): string {
  const query = new URLSearchParams({ query: publicIp })
  return `https://dnschecker.org/port-scanner.php?${query.toString()}`
}

export function portResultPresentation(result: PortResult | undefined): {
  label: string
  pillClass: string
} {
  switch (result?.status) {
    case 'open':
      return { label: 'Open', pillClass: 'pill-success' }
    case 'closed':
      return { label: 'Closed', pillClass: 'pill-danger' }
    case 'unknown':
      return { label: 'Unknown', pillClass: 'pill-warning' }
    default:
      return { label: 'Unchecked', pillClass: 'pill-muted' }
  }
}
