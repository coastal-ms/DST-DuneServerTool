import { describe, expect, it } from 'vitest'
import { isHorizontalSwipe } from '../src/util/mobileNavigationGesture'

describe('isHorizontalSwipe', () => {
  it('accepts deliberate navigation swipes in either direction', () => {
    expect(isHorizontalSwipe({ x: 8, y: 100 }, { x: 80, y: 106 }, 'right')).toBe(true)
    expect(isHorizontalSwipe({ x: 180, y: 100 }, { x: 100, y: 106 }, 'left')).toBe(true)
  })

  it('ignores short, vertical, and opposite-direction movement', () => {
    expect(isHorizontalSwipe({ x: 8, y: 100 }, { x: 40, y: 102 }, 'right')).toBe(false)
    expect(isHorizontalSwipe({ x: 8, y: 100 }, { x: 80, y: 180 }, 'right')).toBe(false)
    expect(isHorizontalSwipe({ x: 80, y: 100 }, { x: 8, y: 102 }, 'right')).toBe(false)
  })
})
