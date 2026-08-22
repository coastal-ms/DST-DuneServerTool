import type { UpdateCheck } from '../api/update'

export type TestBuildIdentity = {
  label: string
  compactLabel: string
  title: string
}

export function getTestBuildIdentity(update?: UpdateCheck | null): TestBuildIdentity | null {
  if (update?.runningIsPrerelease !== true) return null

  const version = update.currentVersion?.trim()
  const tag = update.installedTag?.trim()
  const commit = update.buildCommit?.trim()
  if (tag) {
    const testNumber = tag.match(/-test(\d+)$/i)?.[1]
    return {
      label: `TEST · ${tag.startsWith('v') ? tag : `v${tag}`}`,
      compactLabel: testNumber ? `TEST ${testNumber}` : 'TEST BUILD',
      title: `Running pre-release test build ${tag}`,
    }
  }

  const versionLabel = version ? (version.startsWith('v') ? version : `v${version}`) : 'unknown version'
  const commitLabel = commit ? ` · ${commit.slice(0, 12)}` : ''
  return {
    label: `TEST · ${versionLabel}${commitLabel}`,
    compactLabel: 'TEST BUILD',
    title: `Running manual pre-release test build ${versionLabel}${commit ? ` from commit ${commit}` : ''}`,
  }
}
