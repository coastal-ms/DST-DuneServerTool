import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { SoloRecoveryActivity } from '../src/components/solo/SoloRecoveryActivity'

afterEach(cleanup)
it('keeps named and legacy backup history visible without treating a name as current ownership', () => {
  const open = vi.fn()
  render(<SoloRecoveryActivity onOpenBackups={open} backups={[
    { name: 'old.db', relativePath: 'archive/0/old.db', bytes: 10, createdAt: '', modifiedAt: '2026-10-30', characterName: 'EarlierCharacter' },
    { name: 'new.db', relativePath: 'new.db', bytes: 10, createdAt: '', modifiedAt: '2026-10-31', characterName: 'Replacement' },
    { name: 'legacy.db', relativePath: 'legacy.db', bytes: 10, createdAt: '', modifiedAt: '2026-10-29' },
  ]} />)
  expect(screen.getByText('Character: EarlierCharacter')).toBeVisible()
  expect(screen.getByText('Character: Replacement')).toBeVisible()
  expect(screen.getByText('Character name unavailable for this backup')).toBeVisible()
  fireEvent.click(screen.getByRole('button', { name: 'Open Backups' }))
  expect(open).toHaveBeenCalledOnce()
})
