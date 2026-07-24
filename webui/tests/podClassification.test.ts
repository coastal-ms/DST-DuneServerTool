// podClassification identifies Funcom's terminal battlegroup backup/restore
// pods so the Pods page can label them instead of showing an unqualified red
// Error row that reads as a live server problem (see field report: Pods page
// showed two red Error rows for `-dump-...-pod` names that were actually two
// specific failed scheduled backups, not a server/DB fault).

import { describe, expect, it } from 'vitest'
import { backupOpKindLabel, getBackupOpPodInfo, isFailedPodStatus } from '../src/podClassification'

describe('getBackupOpPodInfo', () => {
  it('identifies a canonical dump (backup) pod name and parses its UTC timestamp', () => {
    const info = getBackupOpPodInfo('sh-368927b88f3e203b-hinnar-dump-20260718-040000-pod')
    expect(info).not.toBeNull()
    expect(info!.kind).toBe('dump')
    expect(info!.timestamp.toISOString()).toBe('2026-07-18T04:00:00.000Z')
  })

  it('identifies a canonical import (restore) pod name', () => {
    const info = getBackupOpPodInfo('sh-368927b88f3e203b-hinnar-import-20260720-040000-pod')
    expect(info).not.toBeNull()
    expect(info!.kind).toBe('import')
    expect(info!.timestamp.toISOString()).toBe('2026-07-20T04:00:00.000Z')
  })

  it('returns null for ordinary long-running pods', () => {
    expect(getBackupOpPodInfo('battlegroup-db-postgresql-0')).toBeNull()
    expect(getBackupOpPodInfo('battlegroup-util-6f9c8d7b6-abcde')).toBeNull()
    expect(getBackupOpPodInfo('file-browser-5d4f9c8b7-xyz12')).toBeNull()
  })

  it('returns null for empty/undefined-ish input', () => {
    expect(getBackupOpPodInfo('')).toBeNull()
  })

  it('does not match a name merely containing "dump" without the full timestamp suffix', () => {
    expect(getBackupOpPodInfo('some-dump-truck-pod')).toBeNull()
    expect(getBackupOpPodInfo('sh-abc-dump-20260718-pod')).toBeNull()
  })
})

describe('backupOpKindLabel', () => {
  it('labels dump as Backup and import as Restore', () => {
    expect(backupOpKindLabel('dump')).toBe('Backup')
    expect(backupOpKindLabel('import')).toBe('Restore')
  })
})

describe('isFailedPodStatus', () => {
  it('flags terminal-failure statuses', () => {
    expect(isFailedPodStatus('Error')).toBe(true)
    expect(isFailedPodStatus('Failed')).toBe(true)
    expect(isFailedPodStatus('CrashLoopBackOff')).toBe(true)
    expect(isFailedPodStatus('OOMKilled')).toBe(true)
  })

  it('does not flag healthy/in-progress statuses', () => {
    expect(isFailedPodStatus('Running')).toBe(false)
    expect(isFailedPodStatus('Succeeded')).toBe(false)
    expect(isFailedPodStatus('Completed')).toBe(false)
    expect(isFailedPodStatus('Pending')).toBe(false)
    expect(isFailedPodStatus('')).toBe(false)
  })
})
