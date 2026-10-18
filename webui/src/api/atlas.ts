import { api, authenticatedApiNavigation } from './client'

export interface AtlasSession {
  available: boolean
  url?: string
  mode?: 'snapshot' | 'live'
  reasonCode?: string
}

/** Starts only the idle local map host; observations remain opt-in. */
export async function openAtlasSession() {
  const session = await api<AtlasSession>('/api/v1/maps/atlas/session', { method: 'POST', body: '{}' })
  if (session.available && session.url === '/api/v1/maps/atlas/view') {
    return { ...session, url: authenticatedApiNavigation(session.url) }
  }
  return session
}
