export function buildBrowserPortalLink(baseUrl: string, remoteToken: string, accountLoginEnabled = false): string {
  if (!baseUrl) return ''
  const stableUrl = `${baseUrl.replace(/\/+$/, '')}/`
  if (accountLoginEnabled) return stableUrl
  if (!remoteToken) return ''
  return `${stableUrl}?key=${encodeURIComponent(remoteToken)}`
}
