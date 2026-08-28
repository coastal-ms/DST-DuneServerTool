import type { ReactNode } from 'react'
import { Link } from '../../router'
import type { WorkspaceDefinition } from '../../platform/workspaces'
import { Icon } from '../Icon'
import { PageHeader } from '../PageHeader'

export type WorkspaceTab = {
  id: string
  label: string
  to: string
  icon?: string
}

export function WorkspaceLayout({
  workspace,
  tabs = [],
  activeTab,
  actions,
  children,
}: {
  workspace: WorkspaceDefinition
  tabs?: readonly WorkspaceTab[]
  activeTab?: string
  actions?: ReactNode
  children: ReactNode
}) {
  return (
    <div className="min-w-0" data-workspace={workspace.id}>
      <PageHeader
        title={workspace.label}
        icon={workspace.icon}
        description={workspace.purpose}
        actions={actions}
      />
      {tabs.length > 0 && (
        <nav
          aria-label={`${workspace.label} workspace views`}
          className="-mx-3 mb-5 overflow-x-auto overscroll-x-contain border-b border-border px-3 touch-pan-x [scrollbar-width:none] sm:mx-0 sm:px-0 [&::-webkit-scrollbar]:hidden"
        >
          <div className="flex min-w-max items-center gap-1">
            {tabs.map(tab => {
              const active = activeTab === tab.id
              return (
                <Link
                  key={tab.id}
                  to={tab.to}
                  aria-current={active ? 'page' : undefined}
                  className={`min-h-11 shrink-0 border-b-2 px-3 py-2.5 text-sm font-medium transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ibad ${
                    active
                      ? 'border-accent text-accent-bright'
                      : 'border-transparent text-text-muted hover:text-text'
                  }`}
                >
                  <span className="inline-flex items-center gap-2">
                    {tab.icon && <Icon name={tab.icon} size={15} />}
                    {tab.label}
                  </span>
                </Link>
              )
            })}
          </div>
        </nav>
      )}
      <div className="min-w-0">{children}</div>
    </div>
  )
}

export function WorkspaceSection({
  id,
  title,
  description,
  children,
}: {
  id: string
  title: string
  description?: string
  children: ReactNode
}) {
  return (
    <section
      className="mb-7 min-w-0"
      data-section-nav-id={id}
      data-section-nav-label={title}
      tabIndex={-1}
    >
      <div className="mb-3">
        <h2 className="text-base font-semibold text-text">{title}</h2>
        {description && <p className="mt-1 max-w-[72ch] text-sm text-text-muted">{description}</p>}
      </div>
      {children}
    </section>
  )
}
