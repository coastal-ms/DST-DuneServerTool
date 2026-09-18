import { describe, expect, it } from 'vitest'
import { mapLabel } from '../src/util/mapLabel'

describe('Retail map labels', () => {
  it.each([
    ['CB_Story_DestroyedZanovar', 'Zanovar'],
    ['CB_Story_OrbitalMonitor', 'Arrakeen Spaceport'],
    ['CB_Arrakis_Story_Paranoid_PrayerRoom', 'Place of Contemplation'],
    ['CB_Arrakis_Story_Glutton_DiningRoom', "The Glutton's Dining Room"],
    ['CB_Arrakis_Generic_Sietch_Room', 'Sietch Talab'],
  ])('labels %s as %s', (map, label) => {
    expect(mapLabel(map)).toBe(label)
  })
})
