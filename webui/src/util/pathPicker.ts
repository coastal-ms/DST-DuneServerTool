import { api } from '../api/client'

type WebView2Host = {
  addEventListener: (type: string, handler: (event: MessageEvent) => void) => void
  removeEventListener: (type: string, handler: (event: MessageEvent) => void) => void
  postMessage: (data: unknown) => void
}

function getWebView2(): WebView2Host | null {
  const host = window as unknown as { chrome?: { webview?: WebView2Host } }
  return host.chrome?.webview ?? null
}

export async function pickLocalFolder(options: {
  initialPath?: string
  description: string
}): Promise<string | null> {
  const webview = getWebView2()
  if (webview) {
    const id = `folder-${Date.now()}-${Math.random().toString(16).slice(2)}`
    return new Promise(resolve => {
      let settled = false
      const finish = (path: string | null) => {
        if (settled) return
        settled = true
        webview.removeEventListener('message', handler)
        resolve(path)
      }
      const handler = (event: MessageEvent) => {
        const data = typeof event.data === 'string' ? JSON.parse(event.data) : event.data
        if (data?.action === 'file-picked' && data?.id === id) {
          finish(data.path ?? null)
        }
      }
      webview.addEventListener('message', handler)
      webview.postMessage({
        action: 'pick-folder',
        id,
        initialPath: options.initialPath,
        description: options.description,
      })
      window.setTimeout(() => finish(null), 300_000)
    })
  }

  const result = await api<{ ok: boolean; cancelled: boolean; path: string }>(
    '/api/browse-path',
    {
      method: 'POST',
      body: JSON.stringify({
        mode: 'folder',
        current: options.initialPath ?? '',
        title: options.description,
      }),
    },
  )
  return result.cancelled ? null : result.path
}
