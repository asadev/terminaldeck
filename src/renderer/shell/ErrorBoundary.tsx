import { Component, type ErrorInfo, type ReactNode } from 'react'

interface Props {
  /** Named in the fallback so the user knows which part failed. */
  label: string
  children: ReactNode
}

interface State {
  error: Error | null
}

/**
 * Stops one broken panel from taking the whole window with it.
 *
 * Without this, a single component that throws during render unmounts the
 * entire React tree — the app goes white with no rail, no tabs and no way
 * back. That happened for real: a crash inside the MCP panel blanked
 * everything, and because the dock restores its last panel on launch, the app
 * came back up broken every time. A failure has to stay inside the thing that
 * failed.
 */
export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    console.error(`[${this.props.label}] crashed:`, error, info.componentStack)
  }

  private reset = (): void => this.setState({ error: null })

  render(): ReactNode {
    const { error } = this.state
    if (!error) return this.props.children

    return (
      <div className="panel-error" role="alert">
        <p className="panel-error-title">{this.props.label} stopped working.</p>
        <p className="panel-error-detail">{error.message}</p>
        <button type="button" className="btn-ghost" onClick={this.reset}>
          Try again
        </button>
      </div>
    )
  }
}
