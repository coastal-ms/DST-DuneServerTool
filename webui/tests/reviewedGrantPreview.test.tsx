import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ReviewedGrantReview } from '../src/pages/gameplay/players/sections'

afterEach(cleanup)
const counts = { total: 2, owned: 1, remaining: 1, entries: [
  {id:'ExistingRecipe',owned:true,quality:0,uses:1,limited:true},
  {id:'MissingRecipe',owned:false,quality:2,uses:4,limited:true},
] }
describe('Reviewed grant preview', () => {
  it('shows exact missing entries and uses, allows inspecting owned entries and never grants on navigation', () => {
    const onGrant=vi.fn()
    render(<ReviewedGrantReview counts={counts} loading={false} busy={false} offline label="Grant recipes" onRetry={vi.fn()} onGrant={onGrant} />)
    expect(screen.getByText('MissingRecipe')).toBeInTheDocument()
    expect(screen.getByText(/Quality 2 · 4 uses/)).toBeInTheDocument()
    expect(screen.queryByText('ExistingRecipe')).not.toBeInTheDocument()
    fireEvent.change(screen.getByLabelText('Grant entry filter'),{target:{value:'owned'}})
    expect(screen.getByText('ExistingRecipe')).toBeInTheDocument()
    expect(screen.getByText(/Already owned — preserved/)).toBeInTheDocument()
    expect(onGrant).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button',{name:'Grant recipes'}))
    expect(onGrant).toHaveBeenCalledOnce()
  })
  it.each(['online','loading','unavailable','incomplete','all-owned'])('blocks irreversible submission when %s', mode => {
    const onGrant=vi.fn()
    render(<ReviewedGrantReview counts={mode==='unavailable'?null:mode==='incomplete'?{...counts,entries:[]}:mode==='all-owned'?{...counts,remaining:0}:counts}
      loading={mode==='loading'} busy={false} offline={mode!=='online'} label="Grant recipes" onRetry={vi.fn()} onGrant={onGrant} />)
    expect(screen.getByRole('button',{name:'Grant recipes'})).toBeDisabled()
    expect(onGrant).not.toHaveBeenCalled()
  })
})
