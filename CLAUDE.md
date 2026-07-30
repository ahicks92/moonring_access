# MoonringAccess — project rules

## Message building: MessageBuilder everywhere (important)

Spoken messages are assembled with the MessageBuilder (`src/ma_mb.lua`), never
by string concatenation with hand-managed separators or punctuation.

- `speech.say()` accepts a builder directly — hand it the builder, unbuilt.
  It builds, supplies the terminal full stop, and skips empty builders.
  Never append a trailing `"."` yourself.
- Build ONE builder as high up as possible (the announcer/watcher/label that
  owns the utterance) and pass it DOWN into part-building functions, which
  append to it (`describe(m, x, y)`, `god_row(m, y)`, `note_body(m, ...)`).
- Separators are the builder's job: `fragment` = space, `list_item` = comma,
  `sentence`/`exclaim` = terminal punctuation. Boundaries are punctuation-aware
  (a part ending in `:` `.` `!` `?` is never double-punctuated; a trailing
  comma is replaced at a sentence boundary).
- Sortable/reorderable entries (nearest-first announcer lists) are built as
  per-entry sub-builders, sorted, then embedded into the top-level builder —
  `fragment`/`list_item`/`sentence` accept a builder and inline its text.
- Overlay labels already receive a shared builder as `ctx.message`; append to
  it, never build strings first. The dispatcher/keygraph own the boundaries
  between announce, row label, and control label.

What MAY still use `..`:

- ONE atomic phrase formatting a single value: `"Health " .. hp .. " of " .. max`,
  `text.offset(dx, dy)`, `text.plural(n, "item")`, `"x " .. count`. The moment
  a second phrase joins it, use the builder.
- Structural/differential KEYS, log lines (`speech.log`), dev-server output,
  and review-buffer line CONTENT (`buffers.add` stores plain lines).
- `details` producers return a LIST of line strings (the Details buffer steps
  them one at a time); a line with conditional parts is built with a throwaway
  builder and `build()`.

If you find speech assembled with `table.concat(parts, ", ")` or
`say(a .. ", " .. b .. ".")`, that is a bug under this rule — refactor it.
