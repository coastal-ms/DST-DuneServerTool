import { cleanup, render, screen } from '@testing-library/react'
import { afterEach, expect, it } from 'vitest'
import { SoloRegisTanks } from '../src/components/solo/SoloRegisTanks'
afterEach(cleanup)
it('provides grant instructions without enable or launch choices', () => {
 render(<SoloRegisTanks connectionToken="test" />)
 expect(screen.getByText('Grant Regis Tanks')).toBeInTheDocument()
 expect(screen.getByText(/F8/)).toBeInTheDocument()
 expect(screen.getByText(/F9/)).toBeInTheDocument()
 expect(screen.queryByRole('button')).not.toBeInTheDocument()
})
