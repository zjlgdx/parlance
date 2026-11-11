import { expect, mock, test } from 'claude-code/testing'
import type { On, ProcessSpawnChunk, ProcessSpawnResult, TurnCompleteInput } from 'claude-code'

// Every `pl` here is a fake: the test's `process.spawn` hook stands for the engine.

const PANE = {
  plugin: 'parlance',
  component: 'Pane',
  requestId: 'parlance',
  props: {
    title: 'Parlance',
    isFocused: false,
    bodyColumns: 60,
    placement: 'dock',
    scroll: { offset: 0, bodyRows: 30 },
    view: {},
  },
} as const

const ANSWER = 'The fix uses a one-sided skip.'
const RESULT = JSON.stringify({
  schema: 1,
  command: 'explain',
  status: 'ok',
  result: {
    translation: '修复用了单侧跳过。',
    plain: '只在一边跳过检查。',
    terms: [
      { word: 'one-sided skip', ipa: null, meaning: '单侧跳过', here: '这里指只跳过左边' },
      { word: 'fix', ipa: '/fɪks/', meaning: '修复', here: '本轮的改动' },
    ],
    vocab: null,
    domain: null,
  },
  error: null,
})

type Run = { chunks: ProcessSpawnChunk[]; code: number | null }
type Spawned = { argv: readonly string[] }

// The engine beneath the plugin: a session `s-1` whose pane is open, and `pl` answering `run`.
function engine(
  on: On,
  run: (argv: readonly string[]) => Run | 'cannot start',
  pane: 'shown' | 'behind another tab' | 'waiting' | 'closed' = 'shown',
  panesAnswered: Promise<void> = Promise.resolve(),
) {
  const spawned: Spawned[] = []
  const opened: string[] = []
  on('command.register', (_, e) => ({ value: { command: e.name } }))
  on('ui.open', (_, e) => {
    opened.push(e.id)
    return { value: { isPlaced: true } }
  })
  on('ui.panes', async () => {
    await panesAnswered
    return {
      value:
        pane === 'closed'
          ? []
          : [
              {
                id: 'parlance',
                title: 'Parlance',
                isShown: pane === 'shown',
                isFocused: false,
                isPlaced: pane === 'shown' || pane === 'behind another tab',
              },
            ],
    }
  })
  on('session.id', () => ({ value: 's-1' }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
  on('process.spawn', async function* (_, e) {
    spawned.push({ argv: e.argv })
    const answer = run(e.argv)
    // A call on `$` is answered `{ value }`; a child that cannot start, `{ deny }`.
    if (answer === 'cannot start') return { deny: 'spawn pl ENOENT' }
    for (const chunk of answer.chunks) yield chunk
    const ended: ProcessSpawnResult = { code: answer.code, signal: null }
    return { value: ended }
  })
  return Object.assign(spawned, { opened })
}

const turn = (fields: Partial<TurnCompleteInput> = {}) =>
  ({
    answer: ANSWER,
    durationMs: 1,
    isAborted: false,
    turnId: 't-1',
    reason: 'answer',
    ...fields,
  }) as TurnCompleteInput

// The person typing `/parlance <args>` at a fullscreen terminal.
const typed = (args: string) =>
  ({
    command: 'parlance',
    args,
    origin: { kind: 'composer' },
    presentation: { isFullscreen: true, columns: 160 },
  }) as const

const stdout = (text: string): ProcessSpawnChunk => ({ stream: 'stdout', text })
const stderr = (text: string): ProcessSpawnChunk => ({ stream: 'stderr', text })

test('a completed reply is explained in the pane, on every surface', async ($, on) => {
  const clock = mock.clock(on)
  const spawned = engine(on, () => ({
    chunks: [stderr('pl: using Claude Code session s-1… (prompts: 1)\n'), stdout(RESULT + '\n')],
    code: 0,
  }))
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.turn.complete(turn())
  await clock.settle()

  expect([...spawned]).toEqual([
    { argv: ['pl', 'explain', '--session', 'claude:s-1', '--json', '--', ANSWER] },
  ])
  expect(spawned.opened).toEqual(['parlance'])
  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    const text = (await ui.find({ type: 'Markdown' }))?.text ?? ''
    expect(text).toContain('修复用了单侧跳过。')
    expect(text).toContain('**Plain:** 只在一边跳过检查。')
    expect(text).toContain('- **one-sided skip**: 单侧跳过\n  这里指只跳过左边')
    expect(text).toContain('- **fix** /fɪks/: 修复')
    expect((await ui.find({ type: 'Text', text: 'Latest reply' }))?.text).toBe('Latest reply')
    await ui.unmount()
  }
})

test('subagent, interrupted, refused, failed and empty turns start nothing', async ($, on) => {
  const clock = mock.clock(on)
  const spawned = engine(on, () => ({ chunks: [stdout(RESULT)], code: 0 }))
  await $.turn.complete(turn({ agentId: 'a-1' }))
  await $.turn.complete(turn({ reason: 'aborted', isAborted: true }))
  await $.turn.complete(turn({ reason: 'refusal', refusal: { category: null, explanation: null } }))
  await $.turn.complete(turn({ reason: 'error' }))
  await $.turn.complete(turn({ answer: '  \n' }))
  await clock.settle()

  expect([...spawned]).toEqual([])
})

for (const pane of ['closed', 'waiting', 'behind another tab'] as const) {
  test(`a pane that is ${pane} pauses the explanations`, async ($, on) => {
    const clock = mock.clock(on)
    const spawned = engine(on, () => ({ chunks: [stdout(RESULT)], code: 0 }), pane)
    await $.turn.complete(turn())
    await clock.settle()

    expect([...spawned]).toEqual([])
  })
}

test('a new turn kills the running request and only its result is drawn', async ($, on) => {
  const clock = mock.clock(on)
  let release = () => {}
  const held = new Promise<void>(resolve => (release = resolve))
  let firstAborted = false
  let firstClosed = false
  let firstFinished = false
  const spawned: string[] = []
  on('ui.panes', () => ({
    value: [{ id: 'parlance', title: 'Parlance', isShown: true, isFocused: false, isPlaced: true }],
  }))
  on('session.id', () => ({ value: 's-1' }))
  on('turn.complete', (_, e) => ({ text: e.answer }))
  on('process.spawn', async function* (_, e, next) {
    const answer = e.argv[e.argv.length - 1] ?? ''
    spawned.push(answer)
    if (answer === 'first') {
      // A real pl writes nothing more until its result: the kill must come while it waits.
      const killed = new Promise<void>(resolve =>
        next.signal.addEventListener('abort', () => resolve(), { once: true }),
      )
      try {
        yield stderr('pl: using Claude Code session s-1…\n')
        await Promise.race([held, killed.then(() => (firstAborted = true))])
        if (firstAborted) return { value: { code: null, signal: 'SIGTERM' } }
        yield stdout(RESULT.replace('修复用了单侧跳过。', 'OLD RESULT'))
        firstFinished = true
        return { value: { code: 0, signal: null } }
      } finally {
        firstClosed = true
      }
    }
    yield stdout(RESULT)
    return { value: { code: 0, signal: null } }
  })

  await $.turn.complete(turn({ answer: 'first', turnId: 't-1' }))
  await clock.settle()
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /explaining/ }))?.text).toBe(
    'Latest reply: explaining…',
  )

  await $.turn.complete(turn({ answer: 'second', turnId: 't-2' }))
  await clock.settle()

  // Nothing is released yet: the first child was killed while it waited.
  expect(firstAborted).toBe(true)
  expect(firstClosed).toBe(true)
  expect(spawned).toEqual(['first', 'second'])
  release()
  await clock.settle()
  expect(firstFinished).toBe(false)
  const text = (await ui.find({ type: 'Markdown' }))?.text ?? ''
  expect(text).toContain('修复用了单侧跳过。')
  expect(text).not.toContain('OLD RESULT')
  await ui.unmount()
})

test('a failed run shows the last pl diagnostic, cleaned for the pane', async ($, on) => {
  const clock = mock.clock(on)
  engine(on, () => ({
    chunks: [
      stderr('pl: using Claude Code session s-1…\npl: Keychain skipped in non-interactive mode.\n'),
      stderr('pl: an API key is required. \u001b[31mSet\u001b[0m DEEPSEEK_API_KEY\u0007.\n'),
    ],
    code: 3,
  }))
  await $.turn.complete(turn())
  await clock.settle()

  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /^pl: / }))?.text).toBe(
    'pl: an API key is required. Set DEEPSEEK_API_KEY.',
  )
  expect(await ui.find({ type: 'Markdown' })).toBeUndefined()
  await ui.unmount()
})

test('a session pl cannot read yet shows its exit 66 line', async ($, on) => {
  const clock = mock.clock(on)
  engine(on, () => ({
    chunks: [stderr('pl: no Claude Code session found for this directory.\n')],
    code: 66,
  }))
  await $.turn.complete(turn())
  await clock.settle()

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /^pl: / }))?.text).toBe(
    'pl: no Claude Code session found for this directory.',
  )
  await ui.unmount()
})

test('notices are not shown as the reason a run failed', async ($, on) => {
  const clock = mock.clock(on)
  const aborted = JSON.stringify({
    schema: 1,
    command: 'explain',
    status: 'error',
    result: null,
    error: { code: 'aborted', message: 'The request was cancelled.' },
  })
  engine(on, () => ({
    chunks: [
      stderr('pl: using Claude Code session s-1… (started 14:02, prompts: 3)\n'),
      stderr('pl: Keychain skipped in non-interactive mode.\n'),
      stderr('pl: model gemma4:12b has no profile in preset compatible; the first token may be slow.\n'),
      stderr('pl: a PEM block was redacted from the text sent; a stray marker takes the text around it too.\n'),
      stdout(aborted + '\n'),
    ],
    code: 130,
  }))
  await $.turn.complete(turn())
  await clock.settle()

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /^pl: / })).toBeUndefined()
  expect((await ui.find({ type: 'Text', text: /without an explanation/ }))?.text).toBe(
    'pl ended (exit 130) without an explanation.',
  )
  await ui.unmount()
})

test('a result with nothing to show is a failure, not an install hint', async ($, on) => {
  const clock = mock.clock(on)
  const empty = JSON.stringify({
    schema: 1,
    command: 'explain',
    status: 'ok',
    result: { translation: '', plain: '', terms: [], vocab: null, domain: null },
    error: null,
  })
  engine(on, () => ({
    chunks: [stderr('pl: using Claude Code session s-1…\n'), stdout(empty + '\n')],
    code: 0,
  }))
  await $.turn.complete(turn())
  await clock.settle()

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /without an explanation/ }))?.text).toBe(
    'pl ended (exit 0) without an explanation.',
  )
  await ui.unmount()
})

test('pl missing from PATH asks to install it', async ($, on) => {
  const clock = mock.clock(on)
  engine(on, () => 'cannot start')
  await $.turn.complete(turn())
  await clock.settle()

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const text = (await ui.find({ type: 'Text', text: /Could not start/ }))?.text ?? ''
  expect(text).toContain('spawn pl ENOENT')
  expect(text).toContain('brew install zjlgdx/tap/parlance')
  await ui.unmount()
})

test('a pl without --session asks to upgrade it', async ($, on) => {
  const clock = mock.clock(on)
  engine(on, () => ({
    chunks: [
      stderr("Error: Unknown option '--session'\nUsage: pl explain [<options>] [<text> ...]\n"),
    ],
    code: 64,
  }))
  await $.turn.complete(turn())
  await clock.settle()

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /too old/ }))?.text).toContain('brew upgrade parlance')
  await ui.unmount()
})

test("macOS's own /usr/bin/pl asks to install Parlance's", async ($, on) => {
  const clock = mock.clock(on)
  engine(on, () => ({
    chunks: [stdout('pl {-input <file>} {-output <file>}\n\tReads ASCII PL from stdin\n')],
    code: 255,
  }))
  await $.turn.complete(turn())
  await clock.settle()

  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  const text = (await ui.find({ type: 'Text', text: /without a Parlance result/ }))?.text ?? ''
  expect(text).toContain('exit 255')
  expect(text).toContain('brew install zjlgdx/tap/parlance')
  await ui.unmount()
})

test('/parlance answers {} and looks the phrase up in the pane', async ($, on) => {
  const clock = mock.clock(on)
  const spawned = engine(on, () => ({ chunks: [stdout(RESULT)], code: 0 }))
  const ran = await $.command.run(typed('  one-sided skip '))
  await clock.settle()

  expect(ran.text).toBeUndefined()
  expect(ran.context).toBeUndefined()
  expect(spawned.opened).toEqual(['parlance'])
  expect([...spawned]).toEqual([
    { argv: ['pl', 'explain', '--session', 'claude:s-1', '--json', '--', 'one-sided skip'] },
  ])
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /one-sided/ }))?.text).toBe('“one-sided skip”')
  await ui.unmount()
})

test('a reply that was still checking the pane does not replace a newer lookup', async ($, on) => {
  const clock = mock.clock(on)
  let answerPanes = () => {}
  const panesAnswered = new Promise<void>(resolve => (answerPanes = resolve))
  const spawned = engine(on, () => ({ chunks: [stdout(RESULT)], code: 0 }), 'shown', panesAnswered)
  const reply = $.turn.complete(turn())
  await clock.settle()
  await $.command.run(typed('one-sided skip'))
  await clock.settle()
  answerPanes()
  await reply
  await clock.settle()

  expect(spawned.map(run => run.argv[run.argv.length - 1])).toEqual(['one-sided skip'])
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect((await ui.find({ type: 'Text', text: /one-sided/ }))?.text).toBe('“one-sided skip”')
  await ui.unmount()
})

test('/parlance with no phrase only opens the pane', async ($, on) => {
  const clock = mock.clock(on)
  const spawned = engine(on, () => ({ chunks: [stdout(RESULT)], code: 0 }))
  const ran = await $.command.run(typed(''))
  await clock.settle()

  expect(ran.text).toBeUndefined()
  expect(spawned.opened).toEqual(['parlance'])
  expect([...spawned]).toEqual([])
})
