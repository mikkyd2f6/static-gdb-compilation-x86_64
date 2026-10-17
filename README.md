# static-gdb

Statically-linked [GDB](https://www.gnu.org/software/gdb/) builds for **x86_64 Linux** —
single portable binaries that run on any x86_64 Linux system with no shared-library
dependencies. Useful on minimal servers, containers, rescue environments, or machines
where you can't install packages.

Built with `--enable-targets=all`, so the debugger understands foreign-architecture
ELF files too (ARM, RISC-V, ...) — handy for inspecting cross-compiled binaries and
for remote debugging (`target remote ...`).

## Variants

| Binary | ~Size | Description |
|---|---|---|
| `gdb-<ver>-static-nopython` | 33 MB | Lean debugger, TUI included, no Python scripting |
| `gdb-<ver>-static-python` | 40 MB | Additionally embeds static CPython 3.12 for GDB Python scripting |

## Quick start

Requirements: Ubuntu/Debian-ish x86_64 host with `gcc`, `make`, `curl`, and:

```bash
sudo apt-get install -y libgmp-dev libmpfr-dev libexpat1-dev zlib1g-dev \
                        libncurses-dev texinfo
```

Then:

```bash
./build.sh
```

Both variants end up in `dist/`, with full install trees under `install/<variant>/`.
A full build takes roughly 15–25 minutes on a 20-core machine.

### Options

All settings are environment variables (shown with defaults):

```bash
GDB_VERSION=16.3        # GDB release to build
PYTHON_VERSION=3.12.7   # CPython used for the python variant
TARGETS=all             # or x86_64-linux-gnu for a native-only, smaller build
VARIANTS="nopython python"  # build only one:  VARIANTS=nopython ./build.sh
JOBS=$(nproc)           # parallel build jobs
```

The script is re-runnable: downloaded sources, the static Python build, and install
trees are skipped when already present.

## Caveats of static GDB (glibc)

- **Thread debugging is limited.** A glibc-static executable cannot `dlopen` the
  system `libthread_db`, so you'll see
  `Unable to find libthread_db matching inferior's thread library` and no
  thread-aware debugging. Use a dynamically-linked GDB when you need that.
- **Python variant:** extension modules that rely on `dlopen` cannot load
  (`import ctypes`, `import ssl`, ... fail). Pure-Python GDB scripts work.
  **pwndbg/gef will not work** with the static build — they need a dynamic GDB.
- **Python data-directory:** the `gdb` Python module lives in
  `install/python/share/gdb/python` (path baked in at configure time). If you move
  the binary elsewhere, keep that directory next to it or pass
  `--data-directory=/path/to/share/gdb`.

## How it works / notable gotchas

The build works around three non-obvious issues; details matter if you bump versions:

1. **GDB 16.x hard-requires GMP and MPFR** at configure time (`libgmp-dev`,
   `libmpfr-dev`).
2. **The final GDB link goes through libtool**, which *silently consumes* a plain
   `-static` flag and produces a dynamic binary. The fix is to relink the final
   binary with `make -C gdb LDFLAGS="-all-static"`.
3. **Distro `libpython3.x.a` is not reliably linkable statically** — Ubuntu's
   archive references `python_hashlib_Hacl_*` symbols it does not ship, and embeds
   `pyexpat`/`zlib` without adding `-lexpat -lz`. The script therefore builds
   CPython from source with `--disable-shared` and points GDB at it via
   `--with-python=`.

Build layout (all gitignored):

```
src/          downloaded + extracted GDB and CPython sources
deps/python/  static CPython install (used by the python variant)
build-*/      out-of-tree build directories
install/*/    full install trees per variant
dist/         stripped final binaries
```

## CI

`.gitlab-ci.yml` builds both variants on every push and exposes `dist/` as job
artifacts. It needs a GitLab runner with Docker (`ubuntu:24.04` image installs its
own dependencies in `before_script`).

## Publishing this repo

After creating the project on GitLab:

```bash
git remote add origin git@gitlab.com:<user>/static-gdb.git
git push -u origin main
```

Prefer attaching the `dist/` binaries to a GitLab **Release** rather than committing
them — 30–40 MB binaries bloat clones permanently.

## License

GDB is GPLv3; statically-linked GDB binaries are derivative works, so if you
distribute the binaries you must offer the corresponding source (pointing at this
repo plus the exact `GDB_VERSION`/`PYTHON_VERSION` is a reasonable way to do that).
No license is claimed over these build files — add one of your choosing before
publishing if you want one.
