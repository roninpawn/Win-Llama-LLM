# WinLlama LLM <img align="left" src="https://github.com/roninpawn/Win-Llama-LLM/blob/main/Screenshots/WinLlama.png">

**A native Windows control panel for running local GGUF models with
llama.cpp --- without living in a terminal.**

WinLlama LLM turns a folder full of models, llama-server builds,
command-line arguments, MCP roots, and console windows into a small
Windows application you can actually *operate*.

Pick a model. Press **Start**. Open chat. <br> When you want the machinery, it is still there.

## Why WinLlama?

`llama-server` is excellent software. It is also a command-line server.

Once you have more than one model, more than one server build,
model-specific context settings, KV-cache choices, optional MCP
filesystem access, and a growing pile of launch arguments, "just run
llama-server" stops being quite so simple.

WinLlama LLM sits on top of that machinery without trying to replace it.

It gives you:
<img width=315px align="right" src="https://github.com/roninpawn/Win-Llama-LLM/blob/main/Screenshots/Configure.png" alt="WinLlama LLM Configure Session window">
-   **One-click model launch and shutdown**
-   **Multiple GGUF model profiles**
-   **Multiple llama-server registrations** -- for when a model needs a certain build or fork
-   **Per-model context and KV-cache configuration**
-   **Live server status and process controls**
-   **A built-in console viewer** with live llama and MCP logs
-   **Session-based rotating logs**
-   **Optional local MCP filesystem access**
-   **Global and per-model MCP directory roots**
-   **First-run setup** builds a working `config.ini` instead of
    handing you an empty text file and wishing you luck
-   **A hand-editable INI configuration** when you *do* want to get your
    hands dirty
-   **No installation ceremony for the release build** --- download the
    EXE and run it

And it does all of this in a compact, native Windows interface.

## The idea

WinLlama does not want to become your "AI _platform_."
<img align="right" src="https://github.com/roninpawn/Win-Llama-LLM/blob/main/Screenshots/Start.png" alt="WinLlama LLM Start window" width=400px>

It does not download models, invent a proprietary model format, hide
llama.cpp behind an account, or build another ecosystem between you and
the software you already chose.

It is a **controller**.

You provide the GGUF.\
You provide `llama-server.exe`.\
WinLlama remembers how you want them run.

A model profile can point at any registered llama server, so a
collection can mix ordinary llama.cpp builds with specialized or
experimental builds without turning your launch routine into a
collection of batch files.

From the Start window you can launch the saved configuration
immediately, or open **Configure Session** and temporarily change the
server, context, KV cache, or model MCP roots without overwriting the
model's defaults.

Once running, the Activity window gives you the controls that matter:
edit, start, restart, stop, open chat, inspect consoles, or shut the
whole owned stack down.

## Built-in console viewer

No forest of command prompts required.

WinLlama captures `stdout` and `stderr` from the processes it launches
and presents them in its own console viewer.

The viewer includes separate **Llama** and **MCP** views, optional
wrapping, configurable refresh timing, mouse-wheel history navigation,
and intelligent tail-following: stay at the bottom and it follows new
output; scroll upward and it leaves your view alone.

![WinLlama LLM built-in console viewer](https://github.com/roninpawn/Win-Llama-LLM/blob/main/Screenshots/Consoles.jpg)

Logging is buffered in memory and periodically flushed rather than
performing a disk write for every line. Logs rotate by session, with
configurable retention.

MCP health polling is also compressed. Hundreds of consecutive status
requests do not need to become hundreds of useless log lines.

## MCP filesystem access

MCP support is deliberately narrow.
<img align=right width=400px alt="WinLlama LLM MCP Config window" src="https://github.com/roninpawn/Win-Llama-LLM/blob/main/Screenshots/MCP.png">

WinLlama does **not** attempt to be a universal or remote MCP client.
Its job is to bootstrap and supervise a local `mcp-proxy` filesystem
endpoint that your llama-server client can use to give agentic models
direct access to certain, specific directories.

You can define:

-   **Global roots** available to every model
-   **Model roots** belonging only to a particular model

Because Qwen and Phi might share a desk at work. But when they go home
they sleep in their own beds.

MCP is entirely optional. If you don't want models running around your
discs, they certainly do not have to.

## Getting started

### Release build

1.  Download the latest **WinLlama LLM** release.
2.  Run `WinLlama LLM.exe`.
3.  Browse to your `llama-server.exe`.
4.  Add a name and location for your GGUF model.
5.  Configure MCP if you want it, or skip it.
6.  Press **Start**.

WinLlama opens the llama-server web UI automatically, or via the 
**Open Chat** button, once your model is online.

### Running from source

WinLlama LLM is written in **AutoHotkey v2**.

Clone or download the repository, make sure AutoHotkey v2 is installed,
and run:

``` text
WinLlama LLM.ahk
```

The release executable is compiled with Ahk2Exe.

## Requirements

**Required**

-   Windows
-   A compatible `llama-server.exe`
-   At least one GGUF model

**Optional MCP support**

-   Python
-   `mcp-proxy`
-   `mcp-server-filesystem`

WinLlama attempts to discover `mcp-proxy.exe` automatically in common
Windows/Python installation locations. If discovery fails, the MCP
configuration screen lets you browse to it directly.

## Configuration philosophy

The GUI is the normal way to configure WinLlama, but `config.ini` is not
an opaque database.

Models and llama servers are stored as named sections.
Application-maintained state is kept separately from the settings a
person is likely to want to edit by hand.

That is intentional: **the GUI and the INI are two interfaces to the
same configuration, not competing systems.**

If a model file or registered server executable later moves or
disappears, WinLlama does not silently rewrite your configuration. It
reports the problem when that configuration is used and gives you the
tools to fix it.

## Process safety

WinLlama distinguishes between processes **it owns** and compatible
servers that were already running.

That distinction matters.

An externally started server can be detected and represented without
WinLlama pretending it launched it. Operations that would cross that
ownership boundary require explicit action rather than quietly
terminating somebody else's process.

Likewise, closing the controller normally shuts down the services it
owns. **Shutdown** is intended to mean shutdown.

## What WinLlama is not

WinLlama LLM is not:

-   a model downloader
-   a model marketplace
-   a replacement for llama.cpp
-   a universal MCP implementation
-   a cloud service
-   an account system
-   an Electron wrapper around a web page

It is a Windows llama-server manager.

That is the job.

## Status

WinLlama LLM is a new project. The current release has been built and
exercised against real local llama-server and mcp-proxy workflows, but
hardware, models, llama.cpp builds, and forks vary enormously.

If you find a reproducible bug, please open an issue with the relevant
configuration and log output.

## License

MIT. See the repository's license file for the exact terms under which
WinLlama LLM is distributed.

------------------------------------------------------------------------

**Local models are already complicated enough. Starting one shouldn't
be.**
