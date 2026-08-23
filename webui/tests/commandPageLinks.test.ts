import { describe, expect, it } from 'vitest'
import { getVisibleCommandPageLinks } from '../src/util/commandPageLinks'

describe('Commands page links', () => {
  it('offers the embedded PowerShell terminal only to local viewers', () => {
    expect(getVisibleCommandPageLinks(true)).toContainEqual(expect.objectContaining({
      to: '/terminal',
      label: 'Open PowerShell',
      localOnly: true,
    }))
    expect(getVisibleCommandPageLinks(false)).toEqual([])
  })
})
