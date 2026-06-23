// SectionErrorBoundary — fine-grained guard for one card/section within a page.
//
// PageErrorBoundary protects a whole route subtree: if any child throws during
// render, the ENTIRE page is replaced by the fallback. That's too coarse for a
// page like Settings, which stacks several independent cards — a render error
// in one card (e.g. a settings value whose shape differs between builds, which
// trips React error #31 "objects are not valid as a React child") would blank
// the whole Settings route, including unrelated, still-working cards.
//
// Wrapping each card in this boundary contains the failure: only the broken
// card shows a compact inline error (with a Retry), the rest of the page keeps
// working, and the exception is still logged via console.error so it lands in
// webview2-debug.log for the diagnostics ZIP.
import { Component, type ErrorInfo, type ReactNode } from 'react'

type Props = {
  // Friendly label for the section/card, shown in the fallback so the user
  // knows which part failed.
  name: string
  children: ReactNode
}

type State = {
  error: Error | null
}

export class SectionErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): Partial<State> {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    console.error(`[SectionErrorBoundary:${this.props.name}]`, error, info.componentStack)
  }

  private handleRetry = (): void => {
    this.setState({ error: null })
  }

  render(): ReactNode {
    const { error } = this.state
    if (!error) return this.props.children

    return (
      <div className="card mb-4 p-4 border-danger/40 bg-danger/5">
        <div className="text-sm font-semibold text-danger mb-1 flex items-center gap-2">
          {this.props.name} couldn’t be displayed
        </div>
        <p className="text-xs text-text-muted mb-2">
          This section hit an unexpected error and was skipped so the rest of the page keeps working.
          If it persists, attach the logs ZIP from <strong>Help → Create GitHub Issue + Save Logs</strong>.
        </p>
        <pre className="text-[11px] font-mono whitespace-pre-wrap break-words text-text-muted bg-surface-2 border border-border rounded-lg p-2 max-h-32 overflow-auto mb-2">
          {error.message || String(error)}
        </pre>
        <button type="button" className="btn-secondary text-xs" onClick={this.handleRetry}>
          Retry
        </button>
      </div>
    )
  }
}
