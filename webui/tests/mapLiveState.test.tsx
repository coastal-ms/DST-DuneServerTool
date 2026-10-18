import React from 'react'
import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, expect, it, vi } from 'vitest'
import { MapLiveState } from '../src/pages/workspaces/MapLiveState'
const { getDeepDesertMapSnapshot } = vi.hoisted(() => ({ getDeepDesertMapSnapshot: vi.fn() }))
vi.mock('../src/api/maps', () => ({ getDeepDesertMapSnapshot }))
vi.mock('../src/api/atlas', () => ({ openAtlasSession: () => new Promise(() => {}) }))
afterEach(cleanup)
it('never mounts or requests the retired cached sample view while Atlas opens', () => {
  render(<MapLiveState />)
  expect(screen.getByText('Opening live map…')).toBeInTheDocument()
  expect(getDeepDesertMapSnapshot).not.toHaveBeenCalled()
  expect(screen.queryByText('Active spice observations')).not.toBeInTheDocument()
})
