import * as Icons from 'lucide-react'
import type { LucideIcon } from 'lucide-react'

type Props = {
  name: string
  className?: string
  size?: number
  strokeWidth?: number
}

export function Icon({ name, className, size = 18, strokeWidth = 2 }: Props) {
  const C = (Icons as unknown as Record<string, LucideIcon>)[name]
  if (!C) return <Icons.HelpCircle size={size} className={className} />
  return <C size={size} strokeWidth={strokeWidth} className={className} />
}
