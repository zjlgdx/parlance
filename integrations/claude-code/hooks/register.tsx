import { atom, read, update } from 'claude-code'
import type {
  EngineInterface,
  HookStream,
  ProcessSpawnChunk,
  ProcessSpawnResult,
  Register,
} from 'claude-code'

import type { ParlanceView } from '../types'

const PANE = 'parlance'
const TITLE = 'Parlance'
const INSTALL =
  'Install the Parlance CLI with: brew install zjlgdx/tap/parlance. Its pl must come first on the PATH Claude Code was started with.'
const UPGRADE =
  'This pl is too old to read Claude Code sessions. Upgrade it with: brew upgrade parlance'

const IDLE =
  'Each reply is explained here when Claude finishes a turn. /parlance <phrase> looks up a phrase from this session.'

const view = atom({ plugin: 'parlance', key: 'view' } as const, { kind: 'idle' }, {
  shape: 'view-1',
})

// One request at a time. A hot reload drops these and kills the child with the old module.
let generation = 0
let running: HookStream<ProcessSpawnChunk, ProcessSpawnResult> | undefined

type Explained = {
  translation?: unknown
  plain?: unknown
  terms?: unknown
}

// The Markdown and Text elements refuse control characters other than tab and newline.
function clean(text: string): string {
  return text
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/g, '')
    .replace(/\u001b\][^\u0007\u001b]*(\u0007|\u001b\\)?/g, '')
    .replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f]/g, '')
}

function field(value: unknown): string {
  return typeof value === 'string' ? clean(value).trim() : ''
}

function toMarkdown(result: Explained): string {
  const parts: string[] = []
  const translation = field(result.translation)
  const plain = field(result.plain)
  if (translation) parts.push(translation)
  if (plain) parts.push(`**Plain:** ${plain}`)
  const terms = Array.isArray(result.terms) ? result.terms : []
  const cards = terms.flatMap(term => {
    if (typeof term !== 'object' || term === null) return []
    const card = term as Record<string, unknown>
    const word = field(card.word)
    if (!word) return []
    const ipa = field(card.ipa)
    const meaning = field(card.meaning)
    const here = field(card.here)
    return [
      `- **${word}**${ipa ? ` ${ipa}` : ''}${meaning ? `: ${meaning}` : ''}${here ? `\n  ${here}` : ''}`,
    ]
  })
  if (cards.length > 0) parts.push(['**Terms**', ...cards].join('\n'))
  return parts.join('\n\n')
}

// Lines pl writes on stderr that report progress or a notice, never why it failed.
const NOTICES = [
  /^pl: using .* session /,
  /^pl: Keychain skipped in non-interactive mode\./,
  /^pl: Keychain (access denied|is locked); continuing key lookup\./,
  /^pl: model .* has no profile in preset /,
  /^pl: .* contains \d+ unknown field\(s\); ignored\./,
  /^pl: a PEM block was redacted from the text sent/,
]

function lastDiagnostic(stderr: string): string | undefined {
  const lines = stderr.split('\n').map(line => clean(line).trim())
  return lines
    .filter(line => line.startsWith('pl: ') && !NOTICES.some(notice => notice.test(line)))
    .pop()
}

function parse(stdout: string): Record<string, unknown> | undefined {
  try {
    const value: unknown = JSON.parse(stdout)
    return typeof value === 'object' && value !== null ? (value as Record<string, unknown>) : undefined
  } catch {
    return undefined
  }
}

// What the pane shows for a pl run that ended on its own. Text elements draw these messages as written.
function outcome(
  subject: string,
  code: number | null,
  stdout: string,
  stderr: string,
): ParlanceView {
  // An older pl rejects the option in ArgumentParser's words, before it writes any `pl:` line.
  if (code === 64 && stderr.includes("Unknown option '--session'")) {
    return { kind: 'failed', message: UPGRADE }
  }
  const json = parse(stdout)
  if (code === 0 && json?.status === 'ok' && typeof json.result === 'object' && json.result) {
    const markdown = toMarkdown(json.result as Explained)
    if (markdown) return { kind: 'done', subject, markdown }
  }
  const said = lastDiagnostic(stderr)
  if (said) return { kind: 'failed', message: said }
  const ended = code === null ? 'on a signal' : `exit ${code}`
  // Parlance's pl answered (an interrupt writes an `aborted` object and no diagnostic line).
  if (json?.command === 'explain') {
    return { kind: 'failed', message: `pl ended (${ended}) without an explanation.` }
  }
  // macOS ships an unrelated /usr/bin/pl; it answers with neither JSON nor a `pl:` line.
  return { kind: 'failed', message: `pl ended (${ended}) without a Parlance result. ${INSTALL}` }
}

function show($: EngineInterface, mine: number, next: ParlanceView): Promise<unknown> {
  return update($, view, current => (mine === generation ? next : current))
}

async function explain($: EngineInterface, mine: number, text: string, subject: string) {
  await show($, mine, { kind: 'running', subject })
  const id = await $.session.id()
  if (mine !== generation) return

  const child = $.process.spawn({
    argv: ['pl', 'explain', '--session', `claude:${id}`, '--json', '--', text],
  })
  running = child
  let stdout = ''
  let stderr = ''
  let ended: ProcessSpawnResult
  try {
    for await (const piece of child) {
      if (piece.stream === 'stdout') stdout += piece.text
      else stderr += piece.text
    }
    ended = await child.result
  } catch (error) {
    // The first pull rejects when `pl` cannot start: not on PATH, or not executable.
    const why = error instanceof Error ? clean(error.message).trim() : ''
    await show($, mine, {
      kind: 'failed',
      message: `Could not start pl${why ? ` (${why})` : ''}. ${INSTALL}`,
    })
    return
  } finally {
    if (running === child) running = undefined
  }
  await show($, mine, outcome(subject, ended.code, stdout, stderr))
}

// Requests are numbered when their event arrives, before any await, so one that resumes late
// never replaces a request that arrived after it.
let arrivals = 0
let latestStarted = 0

// Starts a request in place of the one running. The loop outlives the hook that started it.
function start($: EngineInterface, text: string, subject: string, arrival: number): void {
  if (arrival < latestStarted) return
  latestStarted = arrival
  const mine = ++generation
  const previous = running
  running = undefined
  // return() on the stream kills the child; the value it is handed is not read.
  previous?.return({ code: null, signal: null }).catch(() => undefined)
  explain($, mine, text, subject)
    .catch(error =>
      show($, mine, {
        kind: 'failed',
        message: `Parlance could not run: ${error instanceof Error ? clean(error.message) : 'unknown error'}`,
      }),
    )
    .catch(() => undefined)
}

function quote(phrase: string): string {
  const short = phrase.length > 80 ? `${phrase.slice(0, 79)}…` : phrase
  return `“${clean(short)}”`
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'parlance',
      description: 'Look up a phrase from this session in the Parlance pane',
      argumentHint: '[phrase]',
      immediate: true,
    })
    // Unasked, the engine places the pane only on a wide enough terminal.
    if (e.isInteractive) void $.ui.open({ id: PANE, title: TITLE })

    return next(e)
  })

  // Only main-loop answers, and only while the pane is on screen: closing it pauses the mod.
  on('turn.complete', async ($, e, next) => {
    const arrival = ++arrivals
    const done = await next(e)
    if (e.agentId === undefined && e.reason === 'answer' && e.answer.trim()) {
      const panes = await $.ui.panes()
      // A placed pane can sit as a tab behind another one; only the shown pane is on screen.
      const onScreen = panes.some(pane => pane.id === PANE && pane.isPlaced && pane.isShown)
      if (onScreen) start($, e.answer, 'Latest reply', arrival)
    }

    return done
  })

  // The answer is `{}`: a command's text would reach Claude, so the result goes to the pane alone.
  on('command.run', { command: 'parlance' }, async ($, e) => {
    const arrival = ++arrivals
    await $.ui.open({ id: PANE, title: TITLE })
    const phrase = e.args.trim()
    if (phrase) start($, phrase, quote(phrase), arrival)

    return {}
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Markdown } = $.ui.resolve(e)
    const now = await read($, view)

    return (
      <Box flexDirection="column">
        {now.kind === 'idle' && <Text dimColor>{IDLE}</Text>}
        {now.kind === 'running' && <Text dimColor>{now.subject}: explaining…</Text>}
        {now.kind === 'done' && <Text dimColor>{now.subject}</Text>}
        {now.kind === 'done' && <Markdown text={now.markdown} />}
        {now.kind === 'failed' && <Text color="error">{now.message}</Text>}
      </Box>
    )
  })
}
