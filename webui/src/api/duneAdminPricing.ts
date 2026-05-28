// Sane-pricing patch installer for Coastal's dune-admin customization.
// Bundles a patch + build script into the user's dune-admin source repo and
// runs build-patched.ps1 -Restart to produce a patched dune-admin.exe in
// place of the upstream one.
import { api } from './client'

export interface PricingPrecondition {
  key: string
  label: string
  ok: boolean
  detail: string
  fix: string
  installCommand: string | null
}

export interface PricingPatchMarker {
  appliedAt: string
  appliedByVersion: string
  patchFile: string
  upstreamBackup: string
}

export interface PricingPatchStatus {
  exePath: string
  sourceDir: string
  preconditions: PricingPrecondition[]
  patchApplied: boolean
  marker: PricingPatchMarker | null
  canApply: boolean
  canRestore: boolean
  checkedAt: string
  error?: string
}

export interface PricingPatchApplyResult {
  ok: boolean
  exitCode: number
  log: string
  logFile: string
  patchApplied: boolean
}

export interface PricingPatchRestoreResult {
  ok: boolean
  restoredFrom: string
  patchApplied: boolean
  message: string
}

export function getPricingPatchStatus(): Promise<PricingPatchStatus> {
  return api<PricingPatchStatus>('/api/dune-admin/pricing-patch/status')
}

export function applyPricingPatch(): Promise<PricingPatchApplyResult> {
  return api<PricingPatchApplyResult>('/api/dune-admin/pricing-patch/apply', {
    method: 'POST',
  })
}

export function restorePricingPatch(): Promise<PricingPatchRestoreResult> {
  return api<PricingPatchRestoreResult>('/api/dune-admin/pricing-patch/restore', {
    method: 'POST',
  })
}
