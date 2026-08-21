export type ShellPreferences = {
  softwareRendering: boolean
}

export type ShellPreferencesState = {
  preferences: ShellPreferences
  active: ShellPreferences
  restartRequired: boolean
}

type WebView2Host = {
  addEventListener: (type: 'message', handler: (event: MessageEvent) => void) => void
  removeEventListener: (type: 'message', handler: (event: MessageEvent) => void) => void
  postMessage: (data: unknown) => void
}

type ShellResponse = {
  channel: 'dune-shell'
  type: string
  requestId: string
  ok: boolean
  error?: string | null
  preferences?: ShellPreferences
  active?: ShellPreferences
  restartRequired?: boolean
}

function getWebView2(): WebView2Host | null {
  const host = window as unknown as { chrome?: { webview?: WebView2Host } }
  return host.chrome?.webview ?? null
}

export function isShellHost(): boolean {
  return getWebView2() !== null
}

async function requestShell<T extends ShellResponse>(
  type: string,
  payload: Record<string, unknown> = {},
): Promise<T> {
  const webview = getWebView2()
  if (!webview) throw new Error('Desktop shell bridge is not available.')

  const requestId = `shell-${Date.now()}-${Math.random().toString(16).slice(2)}`
  return new Promise<T>((resolve, reject) => {
    const timeout = window.setTimeout(() => finish(new Error('Desktop shell did not respond.')), 10_000)
    const finish = (error: Error | null, response?: T) => {
      window.clearTimeout(timeout)
      webview.removeEventListener('message', handler)
      if (error) reject(error)
      else resolve(response!)
    }
    const handler = (event: MessageEvent) => {
      let data: unknown = event.data
      if (typeof data === 'string') {
        try { data = JSON.parse(data) } catch { return }
      }
      const response = data as Partial<ShellResponse>
      if (response.channel !== 'dune-shell' || response.requestId !== requestId) return
      if (!response.ok) {
        finish(new Error(response.error || 'Desktop shell request failed.'))
        return
      }
      finish(null, response as T)
    }

    webview.addEventListener('message', handler)
    webview.postMessage({ channel: 'dune-shell', type, requestId, ...payload })
  })
}

export async function getShellPreferences(): Promise<ShellPreferencesState> {
  const response = await requestShell<ShellResponse>('preferences.get')
  if (!response.preferences || !response.active) {
    throw new Error('Desktop shell returned an incomplete preferences response.')
  }
  return {
    preferences: response.preferences,
    active: response.active,
    restartRequired: response.restartRequired === true,
  }
}

export async function setShellPreferences(
  changes: Partial<ShellPreferences>,
): Promise<ShellPreferencesState> {
  const response = await requestShell<ShellResponse>('preferences.set', { changes })
  if (!response.preferences || !response.active) {
    throw new Error('Desktop shell returned an incomplete preferences response.')
  }
  return {
    preferences: response.preferences,
    active: response.active,
    restartRequired: response.restartRequired === true,
  }
}

export async function restartShell(): Promise<void> {
  await requestShell<ShellResponse>('shell.restart')
}
