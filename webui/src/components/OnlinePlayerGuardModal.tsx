import { useEffect, useRef, useState } from 'react'
import {
  registerOnlinePlayerConfirmationHandler,
  type PlayersOnlineConflict,
} from '../api/client'
import { ConfirmationModal } from './ConfirmationModal'

type PendingConfirmation = {
  conflict: Partial<PlayersOnlineConflict>
  resolve: (confirmed: boolean) => void
}

const FAILURE_LABELS: Record<
  NonNullable<PlayersOnlineConflict['verificationFailure']>,
  string
> = {
  context_unavailable: 'Server address unavailable',
  no_response: 'No response received',
  timeout: 'Verification timed out',
  server_error: 'Server query failed',
  invalid_response: 'Invalid response received',
}

export function OnlinePlayerGuardModal() {
  const [pending, setPending] = useState<PendingConfirmation | null>(null)
  const pendingRef = useRef<PendingConfirmation | null>(null)

  useEffect(() => {
    const unregister = registerOnlinePlayerConfirmationHandler((conflict) => {
      if (pendingRef.current) return Promise.resolve(false)
      return new Promise<boolean>((resolve) => {
        const request = { conflict, resolve }
        pendingRef.current = request
        setPending(request)
      })
    })
    return () => {
      unregister()
      pendingRef.current?.resolve(false)
      pendingRef.current = null
    }
  }, [])

  if (!pending) return null

  const settle = (confirmed: boolean) => {
    pending.resolve(confirmed)
    pendingRef.current = null
    setPending(null)
  }
  const { conflict } = pending
  const unknown = conflict.conflict === 'player_status_unknown'
  const names = conflict.playerNames ?? []
  const count = conflict.playersOnline ?? names.length
  const title = unknown
    ? 'Player verification failed'
    : `${count} connected player${count === 1 ? '' : 's'} detected`
  const description = conflict.message ?? (
    unknown
      ? 'DST could not verify whether players are online before this action.'
      : 'This action may disconnect connected players.'
  )
  const failureLabel = conflict.verificationFailure
    ? FAILURE_LABELS[conflict.verificationFailure]
    : 'Player status unknown'

  return (
    <ConfirmationModal
      title={title}
      description={description}
      confirmLabel={unknown ? 'Continue without verification' : 'Continue anyway'}
      onCancel={() => settle(false)}
      onConfirm={() => settle(true)}
    >
      <div className="space-y-3 text-sm">
        {unknown ? (
          <>
            <div className="flex items-center justify-between gap-3 rounded-lg border border-border bg-surface-2 px-3 py-2">
              <span className="text-text-muted">Verification status</span>
              <strong className="text-right font-medium text-warning">{failureLabel}</strong>
            </div>
            <div className="rounded-lg border border-danger/40 bg-danger/10 px-3 py-3 text-danger">
              <strong className="block font-semibold">Connected players may still be online.</strong>
              <span className="mt-1 block leading-relaxed">
                Continuing can disconnect them. Cancel is the safe choice until player status can be verified.
              </span>
            </div>
          </>
        ) : (
          <div className="rounded-lg border border-danger/40 bg-danger/10 px-3 py-3 text-danger">
            <strong className="block font-semibold">
              Continuing will disconnect {count === 1 ? 'this player' : 'these players'}.
            </strong>
            {names.length > 0 && (
              <span className="mt-1 block break-words leading-relaxed text-text">
                {names.slice(0, 8).join(', ')}
                {names.length > 8 ? `, +${names.length - 8} more` : ''}
              </span>
            )}
          </div>
        )}
      </div>
    </ConfirmationModal>
  )
}
