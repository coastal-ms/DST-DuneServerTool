// Global Vitest setup for the webui test suite.
// - Adds jest-dom matchers (toBeInTheDocument, etc.) for React component tests.

import '@testing-library/jest-dom/vitest'
import { beforeEach } from 'vitest'

// Reset session storage between tests so token state never leaks.
beforeEach(() => {
  sessionStorage.clear()
})
