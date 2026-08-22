export type TouchPoint = {
  x: number
  y: number
}

export function isHorizontalSwipe(
  start: TouchPoint,
  end: TouchPoint,
  direction: 'left' | 'right',
  threshold = 48,
) {
  const deltaX = end.x - start.x
  const deltaY = end.y - start.y
  const movesInDirection = direction === 'right' ? deltaX >= threshold : deltaX <= -threshold
  return movesInDirection && Math.abs(deltaX) > Math.abs(deltaY) * 1.25
}
