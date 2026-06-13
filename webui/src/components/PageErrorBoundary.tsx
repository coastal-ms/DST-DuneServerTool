// PageErrorBoundary — last-resort guard for a route subtree. When a child
// render throws, instead of letting the exception propagate to the root and
// white-out the entire app (no error boundary => empty document), we trap it
// here and render an inline error card with the message, the React component
// stack, and a Retry button.
//
// Why this exists: v11.5.x and v12.0.0 had a long-standing "Game Config goes
// blank" report we couldn't diagnose because the whole WebView would clear
// and there was no way to see the underlying exception. Wrapping the page
// gives us a visible error UI on the user's screen AND lets us log the
// failure via console.error so it lands in webview2-debug.log.
import { Component, type ErrorInfo, type ReactNode } from 'react'

type Props = {
  // Friendly label for the page wrapped by this boundary. Surfaced in the
  // header of the fallback card so users know which page crashed.
  pageName: string
  children: ReactNode
}

type State = {
  error: Error | null
  componentStack: string | null
}

export class PageErrorBoundary extends Component<Props, State> {
  state: State = { error: null, componentStack: null }

  static getDerivedStateFromError(error: Error): Partial<State> {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    // Emit to the console so the WebView2 console-event listener (added in
    // v12.0.1) captures it into webview2-debug.log. This is what makes the
    // diagnostics ZIP useful for postmortem analysis.
    // eslint-disable-next-line no-console
    console.error(`[PageErrorBoundary:${this.props.pageName}]`, error, info.componentStack)
    this.setState({ componentStack: info.componentStack ?? null })
  }

  private handleRetry = (): void => {
    this.setState({ error: null, componentStack: null })
  }

  render(): ReactNode {
    const { error, componentStack } = this.state
    if (!error) return this.props.children

    return (
      <div className="p-6">
        <div className="card p-5 border-danger/40 bg-danger/5">
          <div className="text-sm font-semibold uppercase tracking-wider text-danger mb-2">
            {this.props.pageName} crashed
          </div>
          <p className="text-sm text-text mb-3">
            The page hit an unhandled error and was prevented from rendering. The full stack has been
            written to <span className="font-mono">%APPDATA%\DuneServer\webview2-debug.log</span>; please
            attach the ZIP from <strong>Help → Create GitHub Issue + Save Logs</strong>.
          </p>

          <div className="mb-3">
            <div className="text-xs font-medium text-text-muted mb-1">Error</div>
            <pre className="text-xs font-mono whitespace-pre-wrap break-words text-text bg-surface-2 border border-border rounded-lg p-3 max-h-40 overflow-auto">
              {error.message || String(error)}
            </pre>
          </div>

          {error.stack && (
            <details className="mb-3">
              <summary className="text-xs text-text-muted cursor-pointer select-none">
                JS stack trace
              </summary>
              <pre className="mt-1 text-[11px] font-mono whitespace-pre-wrap break-words text-text-muted bg-surface-2 border border-border rounded-lg p-3 max-h-60 overflow-auto">
                {error.stack}
              </pre>
            </details>
          )}

          {componentStack && (
            <details className="mb-3">
              <summary className="text-xs text-text-muted cursor-pointer select-none">
                React component stack
              </summary>
              <pre className="mt-1 text-[11px] font-mono whitespace-pre-wrap break-words text-text-muted bg-surface-2 border border-border rounded-lg p-3 max-h-60 overflow-auto">
                {componentStack}
              </pre>
            </details>
          )}

          <div className="flex items-center gap-2">
            <button type="button" className="btn-primary" onClick={this.handleRetry}>
              Retry render
            </button>
            <button type="button" className="btn-secondary" onClick={() => window.location.reload()}>
              Reload page
            </button>
          </div>
        </div>
      </div>
    )
  }
}
