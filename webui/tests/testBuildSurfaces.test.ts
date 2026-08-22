import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, it } from 'vitest'

describe('test build identity surfaces', () => {
  for (const file of ['layout/StatusBar.tsx', 'layout/Sidebar.tsx', 'pages/Settings.tsx']) {
    it(`${file} uses the shared exact identity`, () => {
      const source = readFileSync(resolve(__dirname, `../src/${file}`), 'utf8')
      expect(source).toContain('getTestBuildIdentity')
      expect(source).toContain(file === 'layout/Sidebar.tsx' ? 'testBuild.compactLabel' : 'testBuild.label')
      expect(source).toContain('testBuild.title')
    })
  }
})
