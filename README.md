# zdsk

A terminal chat client for the [DeepSeek API](https://api-docs.deepseek.com/), written in Zig 0.16.0.

## Features

- Multi-turn conversation — full message history is sent with each request
- Fenced code blocks rendered as full-width coloured rectangles using truecolor ANSI
- Terminal width detected at runtime via `ioctl(TIOCGWINSZ)` for accurate padding
- Model selectable at launch via CLI argument
- Zero dependencies — only the Zig standard library

## Requirements

- Zig 0.16.0
- A [DeepSeek API key](https://platform.deepseek.com/api_keys)
- A truecolor terminal (kitty, alacritty, iTerm2, GNOME Terminal 3.36+, etc.)

## Build / Run

```sh
make deploy
# or...
make run
```


The binary is placed at `zig-out/bin/zdsk`.

## Usage

Export your API key, then run:

```sh
export DEEPSEEK_API_KEY="your-key-here"
./zig-out/bin/zdsk
```

To use a different model, pass it as the first argument:

```sh
./zig-out/bin/zdsk deepseek-reasoner
```

Available models:

| Model | Description |
|---|---|
| `deepseek-chat` | DeepSeek-V3.2, standard mode (default) |
| `deepseek-reasoner` | DeepSeek-V3.2, thinking/reasoning mode |

### In-session commands

| Input | Action |
|---|---|
| Any text + Enter | Send message |
| `/exit` or `/quit` | Quit |
| Ctrl-D | Quit |

## Notes

- The `write_buffer_size` on `std.http.Client` is set to 8192 bytes to avoid a known hang with large HTTPS POST payloads (Zig issue [#25015](https://github.com/ziglang/zig/issues/25015)).
- If stdout is not a TTY (e.g. piped), `termWidth` falls back to 80 columns.
