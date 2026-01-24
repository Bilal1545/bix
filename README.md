# Six

> **Stop managing packages. Start managing systems.**  
> If you’re using Nix just to keep your sanity, six exists to give it back to you.

six is a **cross–distribution, declarative package synchronizer** that does one thing extremely well:

**You describe what should exist. six makes it exist. Everywhere.**

No daemon.  
No rebuilds.  
No language you have to “learn”.  
No ideological commitment.

Just a file. And reality aligning itself to that file.

---

## Why six exists (and why you’re still reading)

Nix is powerful.  
Nix is also a lifestyle choice.

Most people don’t want:
- a new language
- a new store
- a new filesystem philosophy
- a new way of thinking about time

They just want this sentence to be true:

> “If I move this config to another machine, my system should look the same.”

That’s it. That’s the whole dream.

six delivers **that exact promise**, without replacing your distro, your package manager, or your soul.

---

## What six does

- Works on **Arch, Debian/Ubuntu, Fedora, Alpine** (and friends)
- Automatically detects:
  - pacman / yay (AUR)
  - apt
  - dnf
  - apk
- Uses **your native package manager**
- Supports:
  - repo packages
  - GitHub releases
  - direct URLs
- Single command sync
- Optional updates
- Zero background processes
- Zero lock-in

six is not a replacement.  
six is a conductor.

---

## What six is NOT

- Not a package manager
- Not a build system
- Not a container
- Not a VM
- Not a framework
- Not a religion

If you need any of those, Nix is still there. Calm down.

---

## The config (this is the entire learning curve)

```kdl
pm {
    aur = true
}

package "htop" {}

package "ripgrep" {}

package "starship" {
    source = "github"
    repo   = "starship/starship"
    asset  = "starship-x86_64-unknown-linux-gnu.tar.gz"
}
```

You already understand it.
That’s not an accident.

---

## Usage

```bash
six add htop
six sync
```

Update when *you* decide:

```bash
six sync -u
```

Move the config to another machine:

```bash
six sync
```

Same system.
Different computer.
No rituals required.

---

## Why not just use Nix?

Because sometimes you want:

* declarative state
* without rebuilding the universe

six respects:

* your distro
* your tooling
* your existing mental model

It integrates instead of replacing.

---

## Philosophy (short version)

* Declarative where it matters
* Imperative where it’s practical
* Portable over pure
* Boring over clever

six chooses **leverage over ideology**.

---

## Installation

```bash
curl -fsSL https://github.com/Bilal1545/six/six.sh -o six
chmod +x six
sudo mv six /usr/local/bin/
```

That’s the install.
Yes, really.

---

## License

Apache 2.0
Take it. Fork it. Ship it.
Just don’t pretend you wrote it.

---

## Final note

If you’re happy with Nix, keep using it.

If you’ve ever thought:

> “I love the idea, but why does this feel like I joined a monastery?”

Then six was written for you.

Welcome back to your system.
