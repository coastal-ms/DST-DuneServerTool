import { Link, NavLink, useLocation, useSearch } from '../router'
import { useEffect, useMemo, useState, useRef } from 'react'
import { createPortal } from 'react-dom'
import {
  DndContext,
  KeyboardSensor,
  PointerSensor,
  closestCenter,
  useSensor,
  useSensors,
  type DragEndEvent,
} from '@dnd-kit/core'
import {
  SortableContext,
  sortableKeyboardCoordinates,
  useSortable,
  verticalListSortingStrategy,
} from '@dnd-kit/sortable'
import { CSS } from '@dnd-kit/utilities'
import { Icon } from '../components/Icon'
import {
  getVisibleNavItems,
  isNavItemActive,
  NAV_ITEMS,
  type NavItem,
} from '../nav'
import { useUpdateCheck } from '../hooks/useUpdateCheck'
import {
  isSidebarPageHideable,
  useSidebarNavigationOrder,
  type SidebarDividerEntry,
} from '../hooks/useSidebarNavigationOrder'
import { api } from '../api/client'
import { fmtToolVersion } from '../format'
import { isLocalViewer, isWindowsViewer } from '../util/viewer'
import { getTestBuildIdentity } from '../util/testBuildIdentity'
import { usePortalAccess } from '../auth/portalAccess'
import { PORTAL_HANDOFF_REQUEST_EVENT } from '../util/portalHandoff'

// WebView2 host bridge — present only when the portal is rendered inside the
// native DuneShell.exe app window (not in a regular browser tab).
type WebView2Host = { postMessage: (data: unknown) => void }
function getWebView2(): WebView2Host | null {
  const w = window as unknown as { chrome?: { webview?: WebView2Host } }
  return w.chrome?.webview ?? null
}

type Props = {
  collapsed: boolean
  onExpand?: () => void
}

export function Sidebar({ collapsed, onExpand }: Props) {
  const { pathname } = useLocation()
  const search = useSearch()
  const { canAccessOwnerSurfaces } = usePortalAccess()
  const { data: upd } = useUpdateCheck()
  const version = upd?.currentVersion ?? ''
  const testBuild = getTestBuildIdentity(upd)
  const [showPortalConfirm, setShowPortalConfirm] = useState(false)
  const [portalDetaching, setPortalDetaching] = useState(false)
  const [portalError, setPortalError] = useState<string | null>(null)
  const [customizing, setCustomizing] = useState(false)
  const [editingDividerId, setEditingDividerId] = useState<string | null>(null)
  // Issue #280 recovery flow: after handing the portal to the default browser
  // we keep the app window open until the browser checks in with the server.
  // 'confirm' = pre-flight dialog · 'waiting' = browser opened, polling for
  // check-in · 'failed' = browser never reached the server (offer Copy URL +
  // close anyway).
  const [portalPhase, setPortalPhase] = useState<'confirm' | 'waiting' | 'failed'>('confirm')
  const [portalUrl, setPortalUrl] = useState<string | null>(null)
  const [portalCopied, setPortalCopied] = useState(false)
  const portalCancelRef = useRef(false)

  const onOpenWebPortal = async () => {
    if (portalDetaching) return
    setPortalDetaching(true)
    setPortalError(null)
    portalCancelRef.current = false
    try {
      // Tell the server to flag itself as "intentionally detached" — the
      // app-window watcher in ConsoleHost.ps1 reads this flag and skips the
      // usual "shell exited -> stop listener" teardown. Server keeps running.
      const r = await api<{ ok: boolean; url: string }>(
        '/api/portal/open-in-browser', { method: 'POST' },
      )
      if (!r?.url) throw new Error('Server did not return a portal URL.')
      setPortalUrl(r.url)
      const wv = getWebView2()
      if (wv) {
        // Open the browser but KEEP this window open. We wait for the freshly
        // opened browser tab to check in with the server (proving it could
        // actually reach 127.0.0.1) before closing ourselves. If it never
        // checks in, the user keeps a working app window + Copy URL fallback
        // instead of being stranded on a "page unavailable" error (issue #280).
        wv.postMessage({ action: 'open', url: r.url })
        setPortalPhase('waiting')
        void waitForBrowserCheckin()
      } else {
        // Browser fallback: just open the URL in a new tab. We can't close
        // our own window from a regular browser tab.
        window.open(r.url, '_blank', 'noopener')
        setShowPortalConfirm(false)
      }
    } catch (e) {
      setPortalError(e instanceof Error ? e.message : String(e))
    } finally {
      setPortalDetaching(false)
    }
  }

  // Poll the server until the browser we just opened checks in, then close the
  // app window. Times out into the 'failed' state so the user can copy the URL
  // or close anyway.
  const waitForBrowserCheckin = async () => {
    const deadline = Date.now() + 30000
    while (Date.now() < deadline) {
      await new Promise(res => setTimeout(res, 1200))
      if (portalCancelRef.current) return
      let checkedIn = false
      try {
        const s = await api<{ checkedIn: boolean }>('/api/portal/checkin-status')
        checkedIn = !!s?.checkedIn
      } catch { /* transient — keep polling */ }
      if (portalCancelRef.current) return
      if (checkedIn) {
        const wv = getWebView2()
        if (wv) wv.postMessage({ action: 'close' })
        return
      }
    }
    if (!portalCancelRef.current) setPortalPhase('failed')
  }

  // User gave up on the browser hand-off — re-attach so a normal window close
  // tears the server down again, and reset the dialog.
  const onCancelPortalHandoff = async () => {
    portalCancelRef.current = true
    try { await api('/api/portal/reattach', { method: 'POST' }) } catch { /* best effort */ }
    setShowPortalConfirm(false)
    setPortalPhase('confirm')
    setPortalUrl(null)
    setPortalError(null)
  }

  // Browser confirmed unreachable but the user wants to close anyway (server
  // stays running because it's already detached; they can paste the URL into a
  // working browser later).
  const onCloseAnyway = () => {
    const wv = getWebView2()
    if (wv) wv.postMessage({ action: 'close' })
  }

  const onCopyPortalUrl = async () => {
    if (!portalUrl) return
    try {
      await navigator.clipboard.writeText(portalUrl)
      setPortalCopied(true)
      setTimeout(() => setPortalCopied(false), 2000)
    } catch { /* clipboard blocked — the URL is shown in the box to copy manually */ }
  }

  useEffect(() => {
    const openPortalHandoff = () => {
      setPortalError(null)
      setPortalPhase('confirm')
      setShowPortalConfirm(true)
    }
    window.addEventListener(PORTAL_HANDOFF_REQUEST_EVENT, openPortalHandoff)
    return () => window.removeEventListener(PORTAL_HANDOFF_REQUEST_EVENT, openPortalHandoff)
  }, [])

  const localViewer = isLocalViewer()
  const windowsViewer = isWindowsViewer()
  const visibleItems = useMemo(() => getVisibleNavItems({
    local: localViewer,
    windows: windowsViewer,
    canAccessOwnerSurfaces,
    includeSidebarHidden: false,
  }), [canAccessOwnerSurfaces, localViewer, windowsViewer])
  const {
    layoutItems,
    reorder,
    addDivider,
    renameDivider,
    removeDivider,
    hiddenPageIds,
    setPageHidden,
    setPagesHidden,
    reset: resetNavigationOrder,
    isCustomized,
  } = useSidebarNavigationOrder(NAV_ITEMS, visibleItems)
  const visibleLayoutItems = layoutItems.filter(entry => (
    entry.type === 'divider' || !hiddenPageIds.has(entry.id)
  ))
  const displayItems = customizing
    ? layoutItems
    : visibleLayoutItems.filter((entry, index) => {
        if (entry.type === 'page') return true
        for (let nextIndex = index + 1; nextIndex < visibleLayoutItems.length; nextIndex += 1) {
          if (visibleLayoutItems[nextIndex].type === 'divider') return false
          if (visibleLayoutItems[nextIndex].type === 'page') return true
        }
        return false
      })
  const dividerPageIds = useMemo(() => {
    const result = new Map<string, string[]>()
    let currentDividerId: string | null = null
    for (const entry of layoutItems) {
      if (entry.type === 'divider') {
        currentDividerId = entry.id
        result.set(entry.id, [])
      } else if (currentDividerId && isSidebarPageHideable(entry.item)) {
        result.get(currentDividerId)?.push(entry.id)
      }
    }
    return result
  }, [layoutItems])
  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 6 } }),
    useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates }),
  )

  const handleDragEnd = ({ active, over }: DragEndEvent) => {
    if (!over || active.id === over.id) return
    reorder(String(active.id), String(over.id))
  }

  // Shared row renderer for a single nav item, in either layout mode.
  const renderItem = (item: (typeof visibleItems)[number]) => {
    const isActive = isNavItemActive(item, pathname, search)
    return (
      <Link
        to={item.sidebarTo ?? item.to}
        aria-current={isActive ? 'page' : undefined}
        title={collapsed ? item.label : undefined}
        className={
          collapsed
            ? `w-full flex items-center justify-center h-9 rounded-lg transition-all border ${
                isActive
                  ? 'bg-accent/15 text-accent-bright border-accent/30 shadow-inner'
                  : 'text-text-muted hover:text-text hover:bg-surface-2/60 border-transparent'
              }`
            : `flex min-h-9 items-center gap-2.5 px-3 py-1.5 rounded-lg text-sm transition-all border ${
                isActive
                  ? 'bg-accent/15 text-accent-bright border-accent/30 shadow-inner'
                  : 'text-text-muted hover:text-text hover:bg-surface-2/60 border-transparent'
              }`
        }
      >
        <Icon name={item.icon} size={collapsed ? 18 : 16} />
        {!collapsed && (
          <span className="min-w-0 flex flex-col items-start">
            <span className="whitespace-nowrap">{item.label}</span>
            {item.badge && (
              <span className="mt-0.5 text-[9px] leading-none font-semibold uppercase tracking-wider px-1.5 py-0.5 rounded bg-sky-400/15 text-sky-400 border border-sky-400/40">
                {item.badge}
              </span>
            )}
          </span>
        )}
      </Link>
    )
  }

  return (
    <aside
      className={`${collapsed ? 'w-14' : 'w-60'} hidden md:flex shrink-0 border-r border-border bg-surface/60 backdrop-blur-md flex-col transition-[width] duration-150 motion-reduce:transition-none`}
    >
      <div
        className={`${
          collapsed ? 'px-2 justify-center' : 'px-5'
        } py-4 border-b border-border flex items-center gap-2.5`}
      >
        <img
          src="/logo.png"
          alt="Dune Server Tool logo"
          className="w-9 h-9 rounded-full shrink-0 object-contain"
        />
        {!collapsed && (
          <div className="flex-1 min-w-0">
            <div className="inline-block text-center leading-tight">
              <div className="text-2xl font-bold tracking-wide">DST</div>
              <div className="text-sm font-semibold tracking-wide">Dune Server Tool</div>
            </div>
            <div className="text-[10px] text-text-dim uppercase tracking-widest">Management Portal</div>
            <div className="mt-1 flex items-center gap-1 text-[11px] font-bold tracking-wide">
              <Icon name="ThumbsUp" size={11} className="text-emerald-400" />
              <span className="bg-gradient-to-r from-emerald-400 via-sky-400 to-yellow-300 bg-clip-text text-transparent">
                Thank you Hawk_I5
              </span>
            </div>
          </div>
        )}
      </div>

      <nav
        className={`flex-1 overflow-y-auto ${
          collapsed ? 'px-1.5 py-2' : 'px-2 py-1.5'
        } ${collapsed ? '' : 'space-y-2'}`}
      >
        {customizing && !collapsed && (
          <div className="sticky top-0 z-10 mb-2 rounded-lg border border-accent/30 bg-surface px-3 py-2 shadow-[0_4px_14px_-8px_rgba(0,0,0,0.8)]">
            <div className="text-xs font-semibold text-text">Customize navigation</div>
            <p className="mt-0.5 text-[11px] leading-snug text-text-dim">
              Drag pages and sections into any order, or hide what you do not need. Changes stay in this browser.
            </p>
            <div className="mt-2 grid grid-cols-3 gap-1.5">
              <button
                type="button"
                className="btn-secondary min-h-9 justify-center px-2 py-1 text-[10px]"
                onClick={() => setEditingDividerId(addDivider())}
              >
                <Icon name="Plus" size={12} /> Section
              </button>
              <button
                type="button"
                className="btn-secondary min-h-9 justify-center px-2 py-1 text-[10px]"
                onClick={() => {
                  setEditingDividerId(null)
                  resetNavigationOrder()
                }}
                disabled={!isCustomized}
              >
                <Icon name="RotateCcw" size={12} /> Reset
              </button>
              <button
                type="button"
                className="btn-primary min-h-9 justify-center px-2 py-1 text-[10px]"
                onClick={() => setCustomizing(false)}
              >
                <Icon name="Check" size={12} /> Done
              </button>
            </div>
          </div>
        )}
        {customizing && !collapsed ? (
          <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={handleDragEnd}>
            <SortableContext items={displayItems.map(entry => entry.id)} strategy={verticalListSortingStrategy}>
              <ul className="space-y-0.5">
                {displayItems.map(entry => (
                  entry.type === 'page'
                    ? (
                        <SortableSidebarPage
                          key={entry.id}
                          item={entry.item}
                          active={isNavItemActive(entry.item, pathname, search)}
                          hidden={hiddenPageIds.has(entry.id)}
                          onVisibilityChange={hidden => setPageHidden(entry.id, hidden)}
                        />
                      )
                    : (
                        <SortableSidebarDivider
                          key={entry.id}
                          divider={entry}
                          autoFocus={entry.id === editingDividerId}
                          onRename={renameDivider}
                          onRemove={removeDivider}
                          hideablePageIds={dividerPageIds.get(entry.id) ?? []}
                          hiddenPageIds={hiddenPageIds}
                          onVisibilityChange={(pageIds, hidden) => setPagesHidden(pageIds, hidden)}
                        />
                      )
                ))}
              </ul>
            </SortableContext>
          </DndContext>
        ) : (
          <ul className={collapsed ? 'space-y-1' : 'space-y-0.5'}>
            {displayItems.map((entry, index) => (
              entry.type === 'page'
                ? <li key={entry.id}>{renderItem(entry.item)}</li>
                : (
                    <li
                      key={entry.id}
                      className={collapsed
                        ? `${index === 0 ? 'hidden' : 'my-2'} border-t border-accent/55`
                        : 'mb-1 mt-2 flex items-center gap-2 px-3 text-[10px] font-semibold uppercase tracking-widest text-accent-bright before:h-px before:flex-1 before:bg-accent/55 after:h-px after:flex-1 after:bg-accent/55'}
                    >
                      {!collapsed && entry.label}
                    </li>
                  )
            ))}
          </ul>
        )}
      </nav>

      <div
        className={`${
          collapsed ? 'px-1.5 py-2' : 'px-4 py-3'
        } border-t border-border text-[10px] text-text-dim space-y-2`}
      >
        {!customizing && (
          <button
            type="button"
            onClick={() => {
              if (collapsed) onExpand?.()
              setCustomizing(true)
            }}
            aria-label="Customize navigation"
            title={collapsed ? 'Expand and customize navigation' : 'Customize pages and section labels'}
            disabled={collapsed && !onExpand}
            className={
              collapsed
                ? 'w-full flex items-center justify-center h-8 rounded-md border border-border text-text-dim hover:text-text hover:bg-surface-2/60 transition-colors disabled:opacity-50'
                : 'w-full flex items-center justify-center gap-1.5 px-2 py-1.5 rounded-md border border-border text-text-muted hover:text-text hover:bg-surface-2/60 transition-colors uppercase tracking-widest'
            }
          >
            <Icon name="ListRestart" size={collapsed ? 14 : 11} />
            {!collapsed && <span>Customize navigation</span>}
          </button>
        )}
        <a
          href="https://buymeacoffee.com/coastal_dst"
          target="_blank"
          rel="noopener noreferrer"
          title="Support DST on Buy Me a Coffee"
          className={
            collapsed
              ? 'w-full flex items-center justify-center h-8 rounded-md border border-accent/30 text-accent-bright/90 hover:text-accent-bright hover:bg-accent/10 hover:border-accent/50 transition-colors'
              : 'w-full flex items-center justify-center gap-1.5 px-2 py-1.5 rounded-md border border-accent/30 text-accent-bright/90 hover:text-accent-bright hover:bg-accent/10 hover:border-accent/50 transition-colors uppercase tracking-widest'
          }
        >
          <Icon name="Coffee" size={collapsed ? 14 : 11} />
          {!collapsed && <span>Buy Me a Coffee</span>}
          {!collapsed && <Icon name="ExternalLink" size={9} className="text-text-dim" />}
        </a>
        {collapsed && testBuild && (
          <NavLink
            to="/settings"
            title={`${testBuild.title}. Click to open Settings.`}
            className="w-full flex items-center justify-center h-8 rounded-md border border-warning/50 text-warning hover:bg-warning/15 hover:border-warning/70 transition-colors"
          >
            <Icon name="FlaskConical" size={14} />
          </NavLink>
        )}
        {!collapsed && (
          <div className="flex items-center justify-between">
            <span className="flex items-center gap-1.5">
              {version ? fmtToolVersion(version) : '—'}
              {testBuild && (
                <NavLink
                  to="/settings"
                  title={`${testBuild.title}. Click to open Settings, switch to Stable, and install the released build.`}
                  className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[9px] font-semibold uppercase tracking-wider border border-warning/40 bg-warning/10 text-warning hover:bg-warning/20 transition-colors"
                >
                  <Icon name="FlaskConical" size={9} /> {testBuild.compactLabel}
                </NavLink>
              )}
            </span>
            <span className="font-mono">coastal-ms</span>
          </div>
        )}
      </div>

      {showPortalConfirm && createPortal(
        <div
          className="fixed inset-0 bg-black/60 backdrop-blur-sm z-50 flex items-center justify-center p-4"
          onClick={() => { if (!portalDetaching && portalPhase === 'confirm') setShowPortalConfirm(false) }}
        >
          <div
            className="card p-5 max-w-md w-full text-text"
            onClick={e => e.stopPropagation()}
          >
            <div className="flex items-center gap-2 mb-3">
              <Icon name="ExternalLink" size={16} className="text-accent" />
              <h3 className="text-sm font-semibold uppercase tracking-widest text-accent">Open in web browser</h3>
            </div>

            {portalPhase === 'confirm' && (
              <>
                <p className="text-sm text-text-muted mb-2">
                  The portal will open in your <strong>default web browser</strong>. The app window <strong>stays open</strong> until the browser connects, then closes automatically.
                </p>
                <p className="text-sm text-text-muted mb-2">
                  Your server keeps running in the background — the browser tab will work normally.
                </p>
                <p className="text-sm text-text-muted">
                  Reopen Dune Server Tool any time to bring the app window back (the running server will be restarted).
                </p>
                {portalError && (
                  <div className="mt-3 text-xs text-red-400 bg-red-950/40 border border-red-900/60 rounded px-3 py-2">
                    {portalError}
                  </div>
                )}
                <div className="mt-4 flex flex-col gap-2">
                  <button
                    className="btn-primary w-full justify-center"
                    onClick={() => { void onOpenWebPortal() }}
                    disabled={portalDetaching}
                  >
                    <Icon name={portalDetaching ? 'Loader2' : 'ExternalLink'} size={12} className={portalDetaching ? 'animate-spin' : ''} />
                    {portalDetaching ? 'Opening…' : 'Open in browser'}
                  </button>
                  <button
                    className="btn-secondary w-full justify-center"
                    onClick={() => setShowPortalConfirm(false)}
                    disabled={portalDetaching}
                  >
                    <Icon name="X" size={12} /> Cancel
                  </button>
                </div>
              </>
            )}

            {portalPhase === 'waiting' && (
              <>
                <p className="text-sm text-text-muted mb-3 flex items-center gap-2">
                  <Icon name="Loader2" size={14} className="animate-spin text-accent" />
                  Waiting for your browser to open the portal…
                </p>
                <p className="text-xs text-text-dim mb-3">
                  This window will close automatically once your browser connects. If your browser shows a “page unavailable” error, it may be blocked from reaching the server (antivirus, VPN or proxy) — use the URL below.
                </p>
                {portalUrl && <PortalUrlBox url={portalUrl} copied={portalCopied} onCopy={onCopyPortalUrl} />}
                <div className="mt-4 flex flex-col gap-2">
                  <button
                    className="btn-secondary w-full justify-center"
                    onClick={() => { void onCancelPortalHandoff() }}
                  >
                    <Icon name="X" size={12} /> Cancel — keep app window open
                  </button>
                </div>
              </>
            )}

            {portalPhase === 'failed' && (
              <>
                <p className="text-sm text-text-muted mb-2 flex items-center gap-2">
                  <Icon name="AlertTriangle" size={14} className="text-warning" />
                  Your browser didn’t reach the server.
                </p>
                <p className="text-xs text-text-dim mb-3">
                  The app window is still working, so nothing is lost. Your browser is likely blocked from <span className="font-mono">127.0.0.1</span> by antivirus, a VPN, or a proxy. Copy the URL below and open it in another browser, or add a loopback bypass and try again.
                </p>
                {portalUrl && <PortalUrlBox url={portalUrl} copied={portalCopied} onCopy={onCopyPortalUrl} />}
                <div className="mt-4 flex flex-col gap-2">
                  <button
                    className="btn-secondary w-full justify-center"
                    onClick={() => { void onCancelPortalHandoff() }}
                  >
                    <Icon name="ArrowLeft" size={12} /> Keep using the app window
                  </button>
                  <button
                    className="btn-ghost w-full justify-center text-text-dim"
                    onClick={onCloseAnyway}
                    title="Close the app window anyway — the server stays running so you can open the URL later"
                  >
                    <Icon name="X" size={12} /> Close app window anyway
                  </button>
                </div>
              </>
            )}
          </div>
        </div>,
        document.body,
      )}
    </aside>
  )
}

function SortableSidebarPage({
  item,
  active,
  hidden,
  onVisibilityChange,
}: {
  item: NavItem
  active: boolean
  hidden: boolean
  onVisibilityChange: (hidden: boolean) => void
}) {
  const {
    attributes,
    listeners,
    setNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({ id: item.to })

  return (
    <li
      ref={setNodeRef}
      style={{
        transform: CSS.Transform.toString(transform),
        transition,
        opacity: isDragging ? 0.45 : undefined,
      }}
      className={`flex min-h-11 items-center gap-1 rounded-lg border px-1.5 py-1 text-sm ${
        hidden
          ? 'border-dashed border-border/80 bg-surface/35 text-text-dim'
          : active
          ? 'bg-accent/15 text-accent-bright border-accent/30 shadow-inner'
          : 'bg-surface-2/30 text-text-muted border-border/70'
      }`}
    >
      <button
        type="button"
        className="flex min-h-7 min-w-7 shrink-0 touch-none cursor-grab items-center justify-center rounded text-text-dim hover:bg-surface-2 hover:text-text focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent active:cursor-grabbing"
        aria-label={`Reorder ${item.label}`}
        title={`Drag to reorder ${item.label}`}
        {...attributes}
        {...listeners}
      >
        <Icon name="GripVertical" size={14} />
      </button>
      <Icon name={item.icon} size={15} />
      <span className="min-w-0 flex-1 truncate">{item.label}</span>
      {hidden && (
        <span className="shrink-0 rounded border border-border bg-surface-2 px-1.5 py-0.5 text-[8px] font-semibold uppercase tracking-wider text-text-dim">
          Hidden
        </span>
      )}
      {item.badge && (
        <span className="shrink-0 rounded border border-sky-400/40 bg-sky-400/15 px-1 py-0.5 text-[8px] font-semibold uppercase tracking-wider text-sky-400">
          {item.badge}
        </span>
      )}
      {isSidebarPageHideable(item) ? (
        <button
          type="button"
          className="flex min-h-11 min-w-11 shrink-0 items-center justify-center rounded text-text-dim hover:bg-surface-2 hover:text-text focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ibad"
          aria-label={`${hidden ? 'Show' : 'Hide'} ${item.label} in sidebar`}
          aria-pressed={hidden}
          title={`${hidden ? 'Show' : 'Hide'} ${item.label} in the left sidebar`}
          onClick={() => onVisibilityChange(!hidden)}
        >
          <Icon name={hidden ? 'Eye' : 'EyeOff'} size={15} />
        </button>
      ) : (
        <span
          className="flex min-h-11 min-w-11 shrink-0 items-center justify-center text-text-dim"
          aria-label={`${item.label} is always shown`}
          title="This page is always shown in the left sidebar"
        >
          <Icon name="LockKeyhole" size={14} />
        </span>
      )}
    </li>
  )
}

function SortableSidebarDivider({
  divider,
  autoFocus,
  onRename,
  onRemove,
  hideablePageIds,
  hiddenPageIds,
  onVisibilityChange,
}: {
  divider: SidebarDividerEntry
  autoFocus: boolean
  onRename: (id: string, label: string) => void
  onRemove: (id: string) => void
  hideablePageIds: readonly string[]
  hiddenPageIds: ReadonlySet<string>
  onVisibilityChange: (pageIds: readonly string[], hidden: boolean) => void
}) {
  const [label, setLabel] = useState(divider.label)
  const inputRef = useRef<HTMLInputElement | null>(null)
  const cancelRenameRef = useRef(false)
  const {
    attributes,
    listeners,
    setNodeRef,
    transform,
    transition,
    isDragging,
  } = useSortable({ id: divider.id })

  useEffect(() => {
    setLabel(divider.label)
  }, [divider.label])

  useEffect(() => {
    if (autoFocus) {
      inputRef.current?.focus()
      inputRef.current?.select()
    }
  }, [autoFocus])

  const commitLabel = () => {
    if (cancelRenameRef.current) {
      cancelRenameRef.current = false
      setLabel(divider.label)
      return
    }
    onRename(divider.id, label)
    if (!label.trim()) setLabel(divider.label)
  }
  const allHideablePagesHidden = hideablePageIds.length > 0
    && hideablePageIds.every(pageId => hiddenPageIds.has(pageId))

  return (
    <li
      ref={setNodeRef}
      style={{
        transform: CSS.Transform.toString(transform),
        transition,
        opacity: isDragging ? 0.45 : undefined,
      }}
      className="mt-2 flex flex-col gap-1 rounded-lg border border-dashed border-accent/65 bg-accent/[0.14] px-1.5 py-1.5 shadow-sm shadow-black/30"
    >
      <div className="flex w-full items-center gap-1">
        <button
          type="button"
          className="flex min-h-9 min-w-9 shrink-0 touch-none cursor-grab items-center justify-center rounded text-accent/75 hover:bg-accent/10 hover:text-accent-bright focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-accent active:cursor-grabbing"
          aria-label={`Reorder section ${divider.label}`}
          title={`Drag to reorder section ${divider.label}`}
          {...attributes}
          {...listeners}
        >
          <Icon name="GripVertical" size={14} />
        </button>
        <input
          ref={inputRef}
          value={label}
          maxLength={48}
          aria-label={`Rename section ${divider.label}`}
          onChange={event => setLabel(event.target.value)}
          onBlur={commitLabel}
          onKeyDown={event => {
            if (event.key === 'Enter') event.currentTarget.blur()
            if (event.key === 'Escape') {
              cancelRenameRef.current = true
              setLabel(divider.label)
              event.currentTarget.blur()
            }
          }}
          className="min-h-9 min-w-0 flex-1 rounded border border-transparent bg-transparent px-1.5 text-[10px] font-semibold uppercase tracking-widest text-accent-bright focus:border-accent/70 focus:bg-surface focus:outline-none focus:ring-2 focus:ring-ibad"
        />
        <button
          type="button"
          className="flex min-h-11 min-w-11 shrink-0 items-center justify-center rounded text-text-dim hover:bg-danger/15 hover:text-danger focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ibad"
          aria-label={`Remove section ${divider.label}`}
          title="Remove this section label; pages remain"
          onClick={() => onRemove(divider.id)}
        >
          <Icon name="Trash2" size={13} />
        </button>
      </div>
      <button
        type="button"
        className="flex min-h-11 w-full items-center justify-center gap-1.5 rounded border border-accent/25 bg-surface/25 px-2 text-[10px] font-semibold uppercase tracking-wider text-accent/80 hover:border-accent/45 hover:bg-accent/10 hover:text-accent-bright focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ibad disabled:cursor-not-allowed disabled:opacity-35"
        aria-label={`${allHideablePagesHidden ? 'Show' : 'Hide'} pages in section ${divider.label}`}
        aria-pressed={allHideablePagesHidden}
        title={`${allHideablePagesHidden ? 'Show' : 'Hide'} optional pages in this section`}
        disabled={hideablePageIds.length === 0}
        onClick={() => onVisibilityChange(hideablePageIds, !allHideablePagesHidden)}
      >
        <Icon name={allHideablePagesHidden ? 'Eye' : 'EyeOff'} size={14} />
        {allHideablePagesHidden ? 'Show section pages' : 'Hide section pages'}
      </button>
    </li>
  )
}

function PortalUrlBox({ url, copied, onCopy }: { url: string; copied: boolean; onCopy: () => void }) {
  return (
    <div className="flex items-center gap-2">
      <code className="flex-1 min-w-0 truncate text-xs bg-black/40 border border-border rounded px-2 py-1.5 font-mono" title={url}>
        {url}
      </code>
      <button
        type="button"
        onClick={onCopy}
        className="btn-secondary shrink-0"
        title="Copy portal URL"
      >
        <Icon name={copied ? 'Check' : 'Copy'} size={13} />
        {copied ? 'Copied' : 'Copy'}
      </button>
    </div>
  )
}
