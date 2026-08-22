import { describe, expect, it } from 'vitest'
import type { UpdateCheck } from '../src/api/update'
import { getTestBuildIdentity } from '../src/util/testBuildIdentity'

const base: UpdateCheck = {
  available: false,
  currentVersion: '14.0.0',
  checkedAt: '2026-08-21T00:00:00Z',
}

describe('test build identity', () => {
  it('shows the exact matching installed tag', () => {
    expect(getTestBuildIdentity({
      ...base,
      runningIsPrerelease: true,
      installedTag: 'v14.0.0-test6',
      buildCommit: 'abcdef123456',
    })).toMatchObject({
      label: 'TEST · v14.0.0-test6',
      compactLabel: 'TEST 6',
    })
  })

  it('uses the stamped commit for a manual test candidate', () => {
    expect(getTestBuildIdentity({
      ...base,
      runningIsPrerelease: true,
      installedTag: '',
      buildCommit: 'abcdef1234567890',
    })).toMatchObject({
      label: 'TEST · v14.0.0 · abcdef123456',
      compactLabel: 'TEST BUILD',
    })
  })

  it('does not show a test identity for a stable build', () => {
    expect(getTestBuildIdentity({ ...base, runningIsPrerelease: false })).toBeNull()
  })
})
