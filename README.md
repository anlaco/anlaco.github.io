# anlaco.github.io

The ANLACO website. Static HTML and CSS — no build step, no framework, no
JavaScript — served by GitHub Pages.

It presents the test-bench stack: [Anvil](https://github.com/anlaco/anvil)
(sequencer), [Crucible](https://github.com/anlaco/Crucible) (the bench's
digital twin) and [wasi-grpc](https://github.com/anlaco/wasi-grpc) (gRPC on
native WASI sockets).

## Files

| File | What it is |
|---|---|
| `index.html` | The whole site. One page, semantic sections. |
| `style.css` | Design tokens, light and dark, plus every component. |
| `favicon.svg` | The mark: a step signal inside a rounded frame. |

## Working on it

Open `index.html` in a browser, or serve the directory:

```sh
python3 -m http.server 8000
```

There is nothing to compile and nothing to install.

## Brand notes

- **Palette.** Paper and ink, with an amber accent — the colour of a bench
  instrument's display, and deliberately not the blue-green that every
  test-and-measurement vendor already owns. Both themes are defined as tokens
  at the top of `style.css`; change them there and the whole site follows.
- **Mark.** A step waveform crossing a rounded frame: a measured signal, and a
  state machine, which is what a test device mostly is.
- **Typography.** System stacks only, so pages render instantly and no request
  ever leaves the visitor's machine.
- **Voice.** Concrete and unembellished. Claims on this site are checked
  against the repositories; project status is stated as it actually is, not as
  we would like it to be.

## Keeping it honest

The status chips (`chip-live`, `chip-wip`) and the "Where we actually are"
section make specific claims about each project's maturity. When a milestone
lands, update them here too — a website that overstates the state of the code
costs more trust than it buys.
