import { afterEach, describe, expect, it, vi } from 'vitest'
import { cleanup, render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import React from 'react'
import { ShellPreferencesCard } from '../../src/pages/settings/ShellPreferencesCard'

type MessageHandler = (event: MessageEvent) => void

function installShellHost(onRequest: (message: Record<string, unknown>) => Record<string, unknown>) {
  const handlers = new Set<MessageHandler>()
  const webview = {
    addEventListener: (_type: string, handler: MessageHandler) => handlers.add(handler),
    removeEventListener: (_type: string, handler: MessageHandler) => handlers.delete(handler),
    postMessage: vi.fn((message: Record<string, unknown>) => {
      const response = onRequest(message)
      queueMicrotask(() => {
        handlers.forEach(handler => handler(new MessageEvent('message', { data: response })))
      })
    }),
  }
  Object.defineProperty(window, 'chrome', {
    configurable: true,
    value: { webview },
  })
  return webview
}

afterEach(() => {
  cleanup()
  localStorage.clear()
  Reflect.deleteProperty(window, 'chrome')
})

describe('ShellPreferencesCard', () => {
  it('loads, saves, and requests a shell-only restart', async () => {
    const requests: string[] = []
    installShellHost(message => {
      const type = String(message.type)
      requests.push(type)
      if (type === 'preferences.get') {
        return {
          channel: 'dune-shell',
          type: 'preferences.result',
          requestId: message.requestId,
          ok: true,
          preferences: { softwareRendering: false },
          active: { softwareRendering: false },
          restartRequired: false,
        }
      }
      if (type === 'preferences.set') {
        return {
          channel: 'dune-shell',
          type: 'preferences.result',
          requestId: message.requestId,
          ok: true,
          preferences: { softwareRendering: true },
          active: { softwareRendering: false },
          restartRequired: true,
        }
      }
      return {
        channel: 'dune-shell',
        type: 'shell.restart.result',
        requestId: message.requestId,
        ok: true,
      }
    })

    const user = userEvent.setup()
    render(<ShellPreferencesCard />)

    const checkbox = await screen.findByRole('checkbox', { name: /use software rendering/i })
    expect(checkbox).not.toBeChecked()
    await user.click(checkbox)
    await user.click(screen.getByRole('button', { name: /save and restart shell/i }))

    await waitFor(() => {
      expect(requests).toEqual(['preferences.get', 'preferences.set', 'shell.restart'])
    })
  })

  it('surfaces a persistence error without requesting restart', async () => {
    const requests: string[] = []
    installShellHost(message => {
      const type = String(message.type)
      requests.push(type)
      if (type === 'preferences.get') {
        return {
          channel: 'dune-shell',
          type: 'preferences.result',
          requestId: message.requestId,
          ok: true,
          preferences: { softwareRendering: false },
          active: { softwareRendering: false },
          restartRequired: false,
        }
      }
      return {
        channel: 'dune-shell',
        type: 'preferences.result',
        requestId: message.requestId,
        ok: false,
        error: 'Access denied while writing shell-settings.json.',
      }
    })

    const user = userEvent.setup()
    render(<ShellPreferencesCard />)
    await user.click(await screen.findByRole('checkbox', { name: /use software rendering/i }))
    await user.click(screen.getByRole('button', { name: /save and restart shell/i }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Access denied')
    expect(requests).toEqual(['preferences.get', 'preferences.set'])
  })
})
