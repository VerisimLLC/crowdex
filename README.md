# Crowdex

Crowdex is a community-developed module for [DMHub](https://dmhub.app) that
implements MCDM's **Crows** tabletop RPG (currently in playtest). It is written
in Lua and runs inside the DMHub virtual tabletop.

Crowdex is **layered on top of the Draw Steel Codex** -- the Lua mod that
implements MCDM's Draw Steel system in DMHub. Crowdex reuses and overrides Draw
Steel types and systems, so to run Crowdex you also need the Draw Steel Codex
present.

This repository is open to outside contributors. The guide below explains how to
get set up to develop Crowdex using GitHub.

---

## How DMHub development works (read this first)

DMHub normally downloads a module's Lua files from the cloud. For development, it
can instead load Lua files from a folder on your machine -- your **git folder**.

> The Codex will always look to your git folder for Lua files, **always
> preferring the git folder over the cloud**. It only fetches a file from the
> cloud if that file does not exist in your git folder.

This is what lets you edit code locally, see your changes live, and use git for
version control. It also comes with one responsibility:

> If you set up a git folder and then stop pulling updates, your local copy will
> fall out of date and your Codex will become stale. Pull regularly (see
> [Staying up to date](#staying-up-to-date)).

---

## Prerequisites

1. **DMHub** installed, with the Draw Steel Codex available (this is the host
   app Crowdex runs inside).
2. A **GitHub account** -- sign up at <https://github.com>.
3. **git** -- <https://git-scm.com/downloads>.
4. **gh** (the GitHub CLI) -- <https://cli.github.com>. This is a separate
   program from git and makes cloning and forking easier.

After installing `gh`, authenticate once:

```
gh auth login
```

Follow the prompts (choose GitHub.com, HTTPS, and authenticate in the browser).

---

## One-time setup

Crowdex lives in a `Crowdex/` subfolder **inside** a Draw Steel Codex checkout.
Your DMHub git folder points at the Draw Steel Codex root, and Crowdex sits
inside it.

### 1. Get the Draw Steel Codex

Clone it somewhere convenient, for example `C:\dev`:

```
gh repo clone VerisimLLC/draw-steel-codex
```

This creates a `draw-steel-codex` folder.

### 2. Fork Crowdex and clone your fork into it

Because you will contribute changes back via pull requests, work from your own
**fork** of Crowdex rather than the main repo.

Fork it (creates `your-username/crowdex`) and clone your fork into the
`Crowdex` subfolder of the codex you just cloned:

```
gh repo fork VerisimLLC/crowdex --clone=false
gh repo clone your-username/crowdex draw-steel-codex/Crowdex
```

Then add the main repo as an `upstream` remote so you can pull in others'
changes later:

```
cd draw-steel-codex/Crowdex
git remote add upstream https://github.com/VerisimLLC/crowdex.git
```

Your layout now looks like:

```
draw-steel-codex/          <- your DMHub git folder (cloned in step 1)
    Crowdex/               <- your fork of Crowdex (cloned in step 2)
        CrowdexRules.lua
        CrowdexBuilder.lua
        ...
    Draw Steel Core Rules/
    ...
```

### 3. Point DMHub at your git folder

1. Open DMHub / the Codex.
2. Go to the **code modding** section and press the **Dev Settings** button.
3. Add a `gitfolder` key to the JSON document pointing at your Draw Steel Codex
   folder. On Windows, escape each backslash as `\\`:

   ```json
   "gitfolder": "C:\\dev\\draw-steel-codex"
   ```

4. Save. The Codex will now load Lua from your git folder, preferring it over
   the cloud (so your Crowdex edits take effect), and falling back to the cloud
   for everything you do not have locally.

You are now set up. Edits you make to files under `Crowdex/` show up in the
Codex.

---

## Day-to-day workflow

Keep a terminal open in the `Crowdex` folder.

**Edit** files directly in `draw-steel-codex/Crowdex/` with your editor of
choice. Reload the Lua in DMHub to see changes.

**Check what you changed:**

```
git status
git diff
```

**Commit your work** (commit often -- small, focused commits are easier to
review):

```
git commit -a -m "Describe what you changed"
```

**Push to your fork:**

```
git push
```

---

## Contributing changes back

1. Make sure your fork is up to date (see below).
2. Create a branch for your work:
   ```
   git checkout -b my-feature
   ```
3. Commit and push the branch:
   ```
   git push -u origin my-feature
   ```
4. Open a pull request against `VerisimLLC/crowdex`:
   ```
   gh pr create
   ```

Please keep all Crowdex-specific changes inside this repository. Do not modify
the base Draw Steel Codex to make Crowdex work -- if you need a new hook in the
base codex, raise it as an issue first.

### Lua style note

DMHub's Lua runtime only handles **ASCII** characters in source files. Use plain
ASCII in all `.lua` files -- no smart quotes, em dashes, or ellipses. Use `-`,
`"`, and `...` instead.

---

## Staying up to date

The base Draw Steel Codex and Crowdex both change over time. Pull regularly so
your local copy does not go stale.

Update the base codex:

```
cd draw-steel-codex
git pull
```

Update Crowdex from the main repo into your fork:

```
cd draw-steel-codex/Crowdex
git fetch upstream
git merge upstream/main
```

---

## Questions

Open an issue on <https://github.com/VerisimLLC/crowdex> if you get stuck or
something here is out of date.
