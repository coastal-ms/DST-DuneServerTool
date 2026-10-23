import React from 'react'
import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { getAtlasEmbedUrl, getLocalAtlasPreviewUrl, LocalAtlasPreview } from '../src/pages/workspaces/LocalAtlasPreview'

afterEach(cleanup)

describe('local atlas development bridge', () => {
  it('expands the existing frame, restores it and rejects messages from other pages', () => {
    const url='/api/v1/maps/atlas/view?embedded=1'
    render(<LocalAtlasPreview url={url} />)
    const frame=screen.getByTitle('Own-server live atlas') as HTMLIFrameElement
    const send=(origin:string,source:Window|null,type='dst-atlas-toggle-expand')=>fireEvent(window,new MessageEvent('message',{origin,source,data:{type}}))
    send('https://other.example.test',frame.contentWindow)
    expect(screen.queryByRole('button',{name:'Restore map'})).not.toBeInTheDocument()
    send(window.location.origin,window)
    expect(screen.queryByRole('button',{name:'Restore map'})).not.toBeInTheDocument()
    send(window.location.origin,frame.contentWindow)
    expect(screen.getByTitle('Own-server live atlas')).toBe(frame)
    expect(frame.parentElement).toHaveAttribute('data-map-expanded','true')
    expect(frame).toHaveStyle({height:'100dvh'})
    expect(document.body.style.overflow).toBe('hidden')
    fireEvent.click(screen.getByRole('button',{name:'Restore map'}))
    expect(frame.parentElement).toHaveAttribute('data-map-expanded','false')
    expect(document.body.style.overflow).toBe('')
    send(window.location.origin,frame.contentWindow)
    fireEvent.keyDown(window,{key:'Escape'})
    expect(frame.parentElement).toHaveAttribute('data-map-expanded','false')
    send(window.location.origin,frame.contentWindow)
    send(window.location.origin,frame.contentWindow,'dst-atlas-collapse')
    expect(frame.parentElement).toHaveAttribute('data-map-expanded','false')
  })
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
