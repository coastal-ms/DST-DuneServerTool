import {
  useCallback,
  useSyncExternalStore,
  type AnchorHTMLAttributes,
  type ReactNode,
} from 'react'
import {
  Link as WouterLink,
  Redirect,
  Route as WouterRoute,
  Router as WouterRouter,
  Switch,
  useLocation as useWouterLocation,
  useSearch as useWouterSearch,
} from 'wouter'

type LinkProps = Omit<AnchorHTMLAttributes<HTMLAnchorElement>, 'href'> & {
  to: string
}

type NavLinkProps = Omit<LinkProps, 'className'> & {
  end?: boolean
  className?: string | ((state: { isActive: boolean }) => string)
}

type RouteProps = {
  path: string
  element: ReactNode
}

export function BrowserRouter({ children }: { children: ReactNode }) {
  return <WouterRouter>{children}</WouterRouter>
}

export function Routes({ children }: { children: ReactNode }) {
  return <Switch>{children}</Switch>
}

export function Route({ path, element }: RouteProps) {
  return path === '*'
    ? <WouterRoute>{element}</WouterRoute>
    : <WouterRoute path={path}>{element}</WouterRoute>
}

export function mergeNavigationLocation(
  to: string,
  currentSearch: string,
  currentHash: string,
) {
  const target = new URL(to, 'https://dst.local')
  const merged = new URLSearchParams(currentSearch)
  const targetKeys = new Set(target.searchParams.keys())
  for (const key of targetKeys) {
    merged.delete(key)
    for (const value of target.searchParams.getAll(key)) merged.append(key, value)
  }
  const search = merged.toString()
  return `${target.pathname}${search ? `?${search}` : ''}${target.hash || currentHash}`
}

export function Navigate({
  to,
  replace = false,
  preserveLocation = false,
}: {
  to: string
  replace?: boolean
  preserveLocation?: boolean
}) {
  const destination = preserveLocation
    ? mergeNavigationLocation(to, window.location.search, window.location.hash)
    : to
  return <Redirect to={destination} replace={replace} />
}

export function Link({ to, ...props }: LinkProps) {
  return <WouterLink href={to} {...props} />
}

export function NavLink({ to, end = false, className, ...props }: NavLinkProps) {
  const [pathname] = useWouterLocation()
  const isActive = end
    ? pathname === to
    : pathname === to || pathname.startsWith(to.endsWith('/') ? to : `${to}/`)
  const resolvedClassName = typeof className === 'function'
    ? className({ isActive })
    : className

  return <WouterLink href={to} className={resolvedClassName} {...props} />
}

export function useNavigate() {
  const [, navigate] = useWouterLocation()
  return useCallback(
    (to: string, options?: { replace?: boolean }) => navigate(to, options),
    [navigate],
  )
}

export function useLocation() {
  const [pathname] = useWouterLocation()
  return { pathname }
}

export function useSearch() {
  return useWouterSearch()
}

function subscribeToHash(onStoreChange: () => void) {
  window.addEventListener('hashchange', onStoreChange)
  window.addEventListener('popstate', onStoreChange)
  return () => {
    window.removeEventListener('hashchange', onStoreChange)
    window.removeEventListener('popstate', onStoreChange)
  }
}

export function useHash() {
  return useSyncExternalStore(
    subscribeToHash,
    () => window.location.hash,
    () => '',
  )
}
