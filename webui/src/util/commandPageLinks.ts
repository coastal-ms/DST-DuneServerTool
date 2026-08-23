export type CommandPageLink = {
  to: string
  label: string
  description: string
  icon: string
  localOnly?: boolean
}

const COMMAND_PAGE_LINKS: readonly CommandPageLink[] = [
  {
    to: '/terminal',
    label: 'Open PowerShell',
    description: 'Open DST\'s embedded PowerShell terminal on this computer.',
    icon: 'SquareTerminal',
    localOnly: true,
  },
]

export function getVisibleCommandPageLinks(local: boolean): readonly CommandPageLink[] {
  return COMMAND_PAGE_LINKS.filter(link => !link.localOnly || local)
}
