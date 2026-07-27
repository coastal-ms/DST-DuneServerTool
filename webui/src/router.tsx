import {
  useCallback,
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

export function Navigate({ to, replace = false }: { to: string; replace?: boolean }) {
  return <Redirect to={to} replace={replace} />
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
