import React from 'react'
import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { getAtlasEmbedUrl, getLocalAtlasPreviewUrl, LocalAtlasPreview } from '../src/pages/workspaces/LocalAtlasPreview'

afterEach(cleanup)

describe('local atlas development bridge', () => {
  it.each(['/api/v1/maps/atlas/view/other', '/api/v1/maps/atlas/view?path=http://example.com', '//example.com/api/v1/maps/atlas/view'])('rejects an unsuitable proxy view: %s', value => {
    expect(getAtlasEmbedUrl(value)).toBeNull()
  })
  it('never enables the private collector in a release build', () => {
    expect(getLocalAtlasPreviewUrl(false, 'http://127.0.0.1:18747/?key=private')).toBeNull()
  })
  it.each([
    'https://example.com/?key=private', 'http://127.0.0.1.evil.test/?key=private',
    'http://localhost@evil.test/?key=private', 'http://localhost/other?key=private',
    'http://localhost/', 'file:///preview', 'invalid',
  ])('rejects an unsuitable endpoint: %s', value => {
    expect(getLocalAtlasPreviewUrl(true, value)).toBeNull()
  })
  it('loads the main selection view and permits a full-screen map', () => {
    const url = getLocalAtlasPreviewUrl(true, 'http://127.0.0.1:18747/?key=private&view=map')!
    expect(new URL(url).searchParams.has('view')).toBe(false)
    expect(new URL(url).searchParams.get('embedded')).toBe('1')
    render(<LocalAtlasPreview url={url} />)
    expect(screen.getByTitle('Own-server live atlas')).toHaveAttribute('allow', 'fullscreen')
    expect(screen.getByTitle('Own-server live atlas')).toHaveAttribute('referrerpolicy', 'no-referrer')
  })
})
