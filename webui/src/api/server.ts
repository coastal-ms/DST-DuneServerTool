// Server identity API — rename the battlegroup title shown in the in-game
// server browser / status pages (CRD spec.title). Restart-class on the server.
import { api } from './client'

export interface RenameServerResult {
  ok: boolean
  oldName?: string
  newName?: string
  message?: string
}

export function renameServer(name: string) {
  return api<RenameServerResult>('/api/server/name', {
    method: 'POST',
    body: JSON.stringify({ name }),
  })
}
