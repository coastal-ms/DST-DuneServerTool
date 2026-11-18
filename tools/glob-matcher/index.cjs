'use strict'

const { Minimatch } = require('dst-glob-engine')
const globrex = require('globrex')

function matcherOptions(options) {
  return {
    dot: options.dot,
    nocase: options.nocase,
    nobrace: options.nobrace,
    noext: options.noextglob,
    noglobstar: options.noglobstar,
    nonegate: options.nonegate,
    matchBase: options.matchBase || options.basename,
    nocomment: true,
    magicalBraces: true,
    platform: (options.windows ?? (process.platform === 'win32')) ? 'win32' : 'linux',
  }
}

function compile(pattern, options) {
  const config = matcherOptions(options)
  if (pattern.startsWith('!(') && !config.noext) config.nonegate = true
  return new Minimatch(pattern, config)
}

function match(patterns, options = {}) {
  const rules = [patterns].flat().map(pattern => compile(pattern, options))
  const ignored = options.ignore ? match(options.ignore, { ...options, ignore: undefined }) : () => false
  return path => typeof path === 'string' && path.length > 0 &&
    rules.some(rule => rule.match(path)) && !ignored(path)
}

// Matchers in the build tools call this API array-first and with slash-normalized paths.
match.isMatch = (path, patterns, options) => match(patterns, options)(path)

// Astro and Vite serialize regexes for project-configured asset and deny lists.
// Ordinary file discovery uses Minimatch's non-regex matching engine above.
match.makeRe = (pattern, options = {}) => globrex(pattern, {
  extended: true,
  globstar: true,
  flags: options.nocase ? 'i' : '',
}).regex

function splitPattern(pattern) {
  const parts = []
  const groups = []
  const closing = { '[': ']', '{': '}', '(': ')' }
  let start = 0
  for (let i = 0; i < pattern.length; i++) {
    const character = pattern[i]
    if (character === '\\') {
      i++
      continue
    }
    const group = groups.at(-1)
    if (character === group) groups.pop()
    else if (group !== ']' && Object.hasOwn(closing, character)) groups.push(closing[character])
    else if (i > 0 && character === '/' && groups.length === 0) {
      if (i > start) parts.push(pattern.slice(start, i))
      start = i + 1
    }
  }
  if (start < pattern.length) parts.push(pattern.slice(start))
  return parts
}

// tinyglobby uses parts to choose its crawl root. Vite uses base for import globs.
match.scan = (pattern, options = {}) => {
  let glob = pattern
  let negated = false
  if (!options.nonegate) {
    while (glob.startsWith('!') && !glob.startsWith('!(')) {
      negated = true
      glob = glob.slice(1)
    }
  }
  if (glob.startsWith('./')) glob = glob.slice(2)
  const parts = splitPattern(glob)
  const config = { ...matcherOptions(options), nonegate: true }
  const dynamic = parts.findIndex(part => new Minimatch(part, config).hasMagic())
  const isGlob = dynamic !== -1
  const base = isGlob ? parts.slice(0, dynamic).join('/') || (glob.startsWith('/') ? '/' : '') : glob
  return { base, isGlob, negated, parts: options.parts && (parts.length > 1 || glob.endsWith('/')) ? parts : [] }
}

module.exports = match
