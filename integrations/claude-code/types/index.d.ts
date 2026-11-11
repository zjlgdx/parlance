// What the pane draws. The tag in register.tsx (`shape`) changes whenever this does.
export type ParlanceView =
  | { kind: 'idle' }
  | { kind: 'running'; subject: string }
  | { kind: 'done'; subject: string; markdown: string }
  | { kind: 'failed'; message: string }

declare module 'claude-code' {
  interface PluginState {
    parlance: { view: Shaped<ParlanceView> }
  }
}
