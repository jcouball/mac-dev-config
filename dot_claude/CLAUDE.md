# Communication preferences

- Plain, direct language in all output — prose, chat replies, commit
  messages. No flattery, no praise without reason, no AI writing tells.
  For substantial prose editing, the unslop skill is the authority.
- Never add co-author trailers to commit messages.
- Never add "Generated with Claude Code" attribution (or any AI
  attribution) to GitHub issues, comments, or any other content.
- When reporting completed work, state what changed in a sentence or
  two — no recaps or restated plans.
- Match response length to the question; simple questions get direct
  answers without headers or sections.
- Challenge incorrect assumptions directly and explain why.
- When presenting three or more findings, options, risks, decisions,
  questions, or actions, assign each a short code (F1, O1, R1, D1,
  Q1, A1). Keep codes stable through the conversation. Skip codes
  for short, simple answers.
- Banned phrases: "load-bearing", "the real tension",
  "worth stating plainly", "here's the honest truth".

# Test machines

## sophon (Windows)

- Windows 11 Pro, x64, on my home network. Reach it with `ssh sophon`
  (configured in `~/.ssh/config`, key auth, no prompt). Only reachable
  when I'm on the home network. Use it for testing on Windows.
- For a PR in a project that supports Windows, run the project's test
  suite on sophon when the change could behave differently there
  (process, signal, path, encoding, or file-system code; dependency or
  Ruby version changes). Skip it for docs-only changes. Record the
  result in the PR description. If sophon is unreachable, say so and
  ask me to run it; never report a Windows run that did not happen.
- The remote shell is PowerShell 7, not cmd or bash. Write remote
  commands in PowerShell syntax and wrap them in single quotes locally
  so zsh does not expand `$` variables: `ssh sophon '$PSVersionTable'`.
  `&` backgrounds a job; chain with `;` or `&&`.
- `bash` on the PATH is the WSL launcher (Ubuntu, WSL 2), not Git Bash.
  Don't use it for Windows testing.
- Tools are managed by mise: Ruby (MRI, x64-mingw-ucrt, with `ridk`),
  Node, Python, Go, Java, Rust. Git for Windows and `gh` are installed.
- Machine setup is managed by chezmoi from github.com/jcouball/sophon-config.
  The chezmoi source on sophon is `C:\Users\james\.local\share\chezmoi`;
  reach it with `chezmoi git -- <args>`. `C:\Users\james\sophon-config` is an
  old clone with uncommitted changes, not the source: don't read the
  machine's configuration from it or edit it.

### Rubies and gems on sophon

- `mise` is on the PATH in an ssh session: sophon-config keeps its `bin`
  folder on the user PATH. `mise ls ruby` lists the installed Rubies. If
  `mise` is ever not found, a winget upgrade has dropped the entry; call it
  by full path,
  `$env:LOCALAPPDATA\Microsoft\WinGet\Packages\jdx.mise_Microsoft.Winget.Source_8wekyb3d8bbwe\mise\bin\mise.exe`,
  and tell me.
- Call a Ruby by full path, to pick the version:
  `$env:LOCALAPPDATA\mise\installs\ruby\<version>\bin\ruby.exe`. When a
  run starts child `ruby` processes (rspec does), put that `bin`
  directory first on `$env:PATH` so the children use the same version.
- To test on a Ruby that isn't installed, run
  `mise install ruby@<version>` (for example `ruby@3.2`). It installs
  side by side in under a minute, changes no default, and needs no
  approval. Leave it installed for reuse, and tell me what was added.
- Never run `mise use -g` or `ridk install`: both change state other
  work on the machine depends on. Ask before installing a Ruby newer
  than the global one, because that repoints mise's `latest` alias.
- Install gems for a test run with `$env:BUNDLE_PATH` set to a scratch
  directory, not into the Ruby itself. If `bundle install` exits 1 only
  because its `mise reshim` hook failed, the gems are installed.
- A `Gemfile.lock` written by Bundler 4 does not load on Ruby 3.1. In
  the scratch copy, delete the lockfile and let Bundler 2 resolve, or
  run the tool without Bundler if its gems are already installed.

### Working on sophon over ssh

- Repos are cloned directly under `C:\Users\james` (for example
  `process_executer`, `ruby-git`, `jruby`). Check for an existing
  checkout there before cloning, and check its branch and status before
  changing anything: it may hold work in progress.
- Do test work in a scratch directory of its own under
  `C:\Users\james`, never in those checkouts. To test a branch that
  isn't pushed, send it as a git bundle
  (`git bundle create pr.bundle main..<branch>`, naming the branch, not
  `HEAD`), clone the existing checkout into the scratch directory, and
  `git fetch` the bundle there.
- Windows sshd kills everything a session started when the session
  closes, including `Start-Process` children. For a job longer than a
  few minutes, start it detached with
  `Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = ...; CurrentDirectory = ... }`,
  using the full path from `(Get-Command pwsh).Source` (a bare `pwsh`
  fails with ReturnValue 9). Have the job write a log file that ends
  with a `DONE` line, and poll the log with short separate ssh calls.
- A dropped connection does not kill a job that is already running, and
  ssh exits 255. Never pipe a long ssh command through `cut` or `tail`:
  the pipeline's exit status hides the 255. After a 255, reconnect and
  read the job's output before rerunning anything.
- Stop only processes you started, matched by PID and exact command
  line. Never stop processes by name (`Get-Process ruby | Stop-Process`,
  `taskkill /IM`): something else on the machine may own them.
