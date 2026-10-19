import { execFileSync } from 'node:child_process'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'

const packageJson = JSON.parse(readFileSync('package.json', 'utf8'))
const commit = process.env.GIT_SHA?.trim() || execFileSync('git', ['rev-parse', '--short=12', 'HEAD'], { encoding: 'utf8' }).trim()

if (!commit) throw new Error('Could not determine the Git commit for dist/version.json')

mkdirSync('dist', { recursive: true })
writeFileSync('dist/version.json', `${JSON.stringify({ version: packageJson.version, commit })}\n`)
