import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ReviewedGrantReview } from '../src/pages/gameplay/players/sections'

afterEach(cleanup)
const counts = { total: 2, owned: 1, remaining: 1, entries: [
  {id:'ExistingRecipe',owned:true,quality:0,uses:1,limited:true},
  {id:'MissingRecipe',owned:false,quality:2,uses:4,limited:true},
] }
describe('Reviewed grant preview', () => {
  it('allows only exhausted owned recipes to be reissued without marking usable recipes as missing', () => {
    const onGrant=vi.fn()
    render(<ReviewedGrantReview counts={{total:3,owned:3,remaining:0,reissuable:1,entries:[
      {id:'ExhaustedRecipe',owned:true,quality:0,uses:0,limited:true,grantable:true},
      {id:'UsableRecipe',owned:true,quality:0,uses:1,limited:true,grantable:false},
      {id:'UnlimitedRecipe',owned:true,quality:0,uses:0,limited:false,grantable:false},
    ]}} loading={false} busy={false} offline label="Grant recipes" onRetry={vi.fn()} onGrant={onGrant} />)
    expect(screen.getByText('ExhaustedRecipe')).toBeInTheDocument()
    expect(screen.queryByText('UsableRecipe')).not.toBeInTheDocument()
    expect(screen.queryByText('UnlimitedRecipe')).not.toBeInTheDocument()
    expect(screen.getByText(/1 to reissue/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button',{name:'Grant recipes'}))
    expect(onGrant).toHaveBeenCalledOnce()
  })
  it('keeps the maximum augmentation grant available when recipes still have uses', () => {
    render(<ReviewedGrantReview counts={{total:1,owned:1,remaining:0,reissuable:1,entries:[
      {id:'AugmentationRecipe',owned:true,quality:5,uses:4,limited:true,grantable:true},
    ]}} loading={false} busy={false} offline reissueAll label="Grant augmentations" onRetry={vi.fn()} onGrant={vi.fn()} />)
    expect(screen.getByText(/Each press grants another use/)).toBeInTheDocument()
    expect(screen.getByRole('button',{name:'Grant augmentations'})).toBeEnabled()
    expect(screen.queryByRole('spinbutton')).not.toBeInTheDocument()
  })
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

it.each([
  [{value: [{id:'Swatch',owned:false}], Count:1}],
  [{id:null,owned:false}],
  [null],
  {},
])('shows a retry without crashing on malformed status entries', entries => {
  const onGrant=vi.fn()
  render(<ReviewedGrantReview counts={{total:1,owned:0,remaining:1,entries} as unknown as Parameters<typeof ReviewedGrantReview>[0]['counts']}
    loading={false} busy={false} offline label="Grant swatches" onRetry={vi.fn()} onGrant={onGrant} />)
  expect(screen.getByRole('button',{name:'Retry preview'})).toBeInTheDocument()
  expect(screen.getByRole('button',{name:'Grant swatches'})).toBeDisabled()
  expect(onGrant).not.toHaveBeenCalled()
})
