import { useEffect, useState, useCallback } from 'react'

type BIPEvent = Event & {
  prompt: () => Promise<void>
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed'; platform: string }>
}

declare global {
  interface Window {
    __dunePwaPrompt?: BIPEvent | null
  }
}

export function useInstallPrompt() {
  const [canInstall, setCanInstall] = useState<boolean>(!!window.__dunePwaPrompt)
  const [installed, setInstalled] = useState<boolean>(
    typeof window !== 'undefined' &&
      (window.matchMedia?.('(display-mode: standalone)').matches ||
        (window.navigator as { standalone?: boolean }).standalone === true)
  )

  useEffect(() => {
    const onPrompt = (e: Event) => {
      e.preventDefault()
      window.__dunePwaPrompt = e as BIPEvent
      setCanInstall(true)
    }
    const onInstalled = () => {
      window.__dunePwaPrompt = null
      setCanInstall(false)
      setInstalled(true)
    }
    window.addEventListener('beforeinstallprompt', onPrompt)
    window.addEventListener('appinstalled', onInstalled)
    return () => {
      window.removeEventListener('beforeinstallprompt', onPrompt)
      window.removeEventListener('appinstalled', onInstalled)
    }
  }, [])

  const install = useCallback(async (): Promise<'accepted' | 'dismissed' | 'unavailable'> => {
    const p = window.__dunePwaPrompt
    if (!p) return 'unavailable'
    try {
      await p.prompt()
      const choice = await p.userChoice
      window.__dunePwaPrompt = null
      setCanInstall(false)
      return choice.outcome
    } catch {
      return 'dismissed'
    }
  }, [])

  return { canInstall, installed, install }
}
