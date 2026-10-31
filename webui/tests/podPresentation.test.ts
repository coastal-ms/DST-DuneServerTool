import { expect, it } from 'vitest'
import { podPresentation } from '../src/podPresentation'
import type { PodSummary } from '../src/api/pods'
const pod = (values: Partial<PodSummary>): PodSummary => ({ namespace: 'test', name: 'test-sg-survival-1-pod-1', ready: '1/1', phase: 'Running', status: 'Running', restarts: 100, node: 'test', ip: '', startTime: '', ...values })
it.each([
  ['survival-1', 'Hagga Basin'], ['deepdesert-1', 'Deep Desert'], ['sh-harkovillage', 'Harko Village'],
  ['dlc-story-lostharvest-ecolaba', 'Lost Harvest: Ecolab A'], ['story-heighlinerdungeon', 'Heighliner Dungeon'],
])('labels the known %s game map', (slug, label) => expect(podPresentation(pod({ name: `test-sg-${slug}-pod-2` })).label).toBe(label))
it('does not infer current problems from lifetime restarts', () => expect(podPresentation(pod({}))).toMatchObject({ healthy: true, needsAttention: false, state: 'Ready' }))
it('marks a Running pod with unready containers as not ready', () => expect(podPresentation(pod({ ready: '0/1' }))).toMatchObject({ healthy: false, needsAttention: true, state: 'Not ready' }))
it('keeps a failed Hagga map visible for attention', () => expect(podPresentation(pod({ phase: 'Failed', status: 'Error', ready: '0/1' }))).toMatchObject({ group: 'maps', terminal: false, needsAttention: true, state: 'Error' }))
it('separates failed backup attempts from current health', () => expect(podPresentation(pod({ name: 'test-dump-20261030-120000-pod', phase: 'Failed', status: 'Error', ready: '0/1' }))).toMatchObject({ group: 'history', terminal: true, needsAttention: false, state: 'Failed attempt' }))
it('keeps an in-progress backup visible', () => expect(podPresentation(pod({ name: 'test-dump-20261030-120000-pod' }))).toMatchObject({ group: 'services', terminal: false }))
it('shows the full name for unknown services without inventing a role', () => expect(podPresentation(pod({ name: 'test-unknown-service-very-long-unique-suffix' }))).toMatchObject({ label: 'test-unknown-service-very-long-unique-suffix', group: 'services' }))
