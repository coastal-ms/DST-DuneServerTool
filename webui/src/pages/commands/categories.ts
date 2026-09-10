import type { Command } from '../../api/types'

export const COMMAND_CATEGORIES = [
  { id: 'battlegroup', label: 'Battlegroup', icon: 'Activity', description: 'Start, stop, update, and maintain the game servers.',
    commands: ['start', 'restart', 'stop', 'update', 'fix-on-demand-maps'] },
  { id: 'vm', label: 'VM & Power', icon: 'HardDrive', description: 'VM setup, power, and memory. All-server actions also affect the battlegroup.',
    commands: ['initial-setup', 'start-vm', 'stop-vm', 'startup', 'shutdown', 'reboot', 'enable-experimental-swap'] },
  { id: 'configuration', label: 'Configuration', icon: 'Settings', description: 'Apply INIs and open battlegroup or Director configuration.',
    commands: ['apply-inis', 'edit', 'edit-advanced', 'open-director'] },
  { id: 'network', label: 'Network & Access', icon: 'Network', description: 'Connection addresses, VM credentials, and SSH keys.',
    commands: ['change-vm-ip', 'change-battlegroup-ip', 'rotate-ssh-key', 'change-password'] },
  { id: 'database', label: 'Database', icon: 'Database', description: 'Back up or import the battlegroup database.',
    commands: ['backup', 'import'] },
  { id: 'logs', label: 'Logs & Files', icon: 'Files', description: 'Export pod logs and browse battlegroup files.',
    commands: ['logs-export', 'operator-logs-export', 'open-file-browser'] },
  { id: 'tools', label: 'Terminals & Tools', icon: 'SquareTerminal', description: 'Open local or VM terminals, a pod shell, and setup guidance.',
    commands: ['shell-vm', 'shell-pod', 'ssh', 'setup-guide'] },
] as const

export type CommandCategory = typeof COMMAND_CATEGORIES[number]['id']

export function getCommandCategory(command: Command): CommandCategory {
  return COMMAND_CATEGORIES.find(category => category.commands.some(name => name === command.name))?.id
    ?? (command.section === 'VM' ? 'vm' : command.section === 'Battlegroup' ? 'battlegroup' : 'tools')
}
