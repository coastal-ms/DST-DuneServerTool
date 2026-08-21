export function buildBrowserPortalLink(baseUrl: string, remoteToken: string): string {
  if (!baseUrl || !remoteToken) return ''
  return `${baseUrl.replace(/\/+$/, '')}/?key=${encodeURIComponent(remoteToken)}`
}
