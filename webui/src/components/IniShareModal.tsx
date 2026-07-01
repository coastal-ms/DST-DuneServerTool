// IniShareModal — a copyable "give this to your players" popup for a client-side
// Game.ini block. Rendered through a portal to document.body so it always sits
// above the page (parent cards / the sticky footer create stacking contexts that
// would otherwise trap a nested fixed overlay underneath them).
import { useState } from 'react'
import { createPortal } from 'react-dom'
import { Icon } from './Icon'

const CLIENT_GAME_INI_PATH = '%LOCALAPPDATA%\\DuneSandbox\\Saved\\Config\\WindowsClient\\Game.ini'

type Props = {
  title?: string
  /** The exact INI text to display + copy. When empty, the modal renders nothing. */
  block: string
  /** Short line under the title explaining why the player needs this. */
  subtitle?: React.ReactNode
  onClose: () => void
}

export function IniShareModal({ title = 'Give this to your players', block, subtitle, onClose }: Props) {
  const [copied, setCopied] = useState(false)
  if (!block) return null

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(block)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch { /* clipboard may be unavailable; the text is still shown */ }
  }

  return createPortal(
    <div
      className="fixed inset-0 z-[11000] flex items-center justify-center bg-slate-950/80 p-4 backdrop-blur-sm"
      onClick={onClose}
    >
      <div
        className="w-full max-w-2xl rounded-xl border border-border bg-surface shadow-2xl"
        onClick={e => e.stopPropagation()}
      >
        <div className="flex items-start gap-3 border-b border-border px-6 py-4">
          <div className="mt-0.5 flex h-9 w-9 shrink-0 items-center justify-center rounded-full bg-accent/15">
            <Icon name="Share2" size={18} className="text-accent" />
          </div>
          <div className="min-w-0">
            <h2 className="text-base font-semibold text-text">{title}</h2>
            {subtitle && <p className="text-xs text-text-muted">{subtitle}</p>}
          </div>
          <button type="button" className="ml-auto btn-icon" onClick={onClose} title="Close">
            <Icon name="X" size={16} />
          </button>
        </div>

        <div className="px-6 py-4 space-y-3">
          <div className="text-xs text-text-muted">
            File location on each player&apos;s PC:{' '}
            <span className="font-mono break-all text-text">{CLIENT_GAME_INI_PATH}</span>
          </div>
          <pre className="max-h-[45vh] overflow-auto rounded-lg border border-border bg-surface-2 p-3 text-xs font-mono text-text whitespace-pre">
{block}
          </pre>
          <div className="flex items-center gap-2">
            <button type="button" className="btn-primary" onClick={() => void copy()}>
              <Icon name={copied ? 'Check' : 'Copy'} size={14} /> {copied ? 'Copied' : 'Copy to clipboard'}
            </button>
            <button type="button" className="btn-secondary" onClick={onClose}>Close</button>
          </div>
          <div className="text-xs text-text-dim leading-relaxed">
            Tip: if a player already has one of these <span className="font-mono">[/Script/...]</span> section
            headers, they should merge these lines into it rather than adding a second copy of the header. This
            block matches what DST wrote to your own client <span className="font-mono">Game.ini</span>.
          </div>
        </div>
      </div>
    </div>,
    document.body,
  )
}
