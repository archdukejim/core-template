---
description: "Stage and commit all changes with a conventional commit message"
allowed-tools: ["Bash(git add:*)", "Bash(git status:*)", "Bash(git diff:*)", "Bash(git commit:*)", "Bash(git log:*)"]
---

Review the current git state and create a commit:

1. Run `git status` and `git diff` (including staged changes with `git diff --cached`) to understand what has changed.
2. Run `git log --oneline -5` to match the existing commit message style.
3. Stage all modified/new tracked files with `git add -u`, unless specific files were mentioned — in that case stage only those.
4. Write a commit message following Conventional Commits: `<type>: <description>`
   - Types: `feat`, `fix`, `refactor`, `chore`, `docs`, `test`, `style`
   - Imperative mood, present tense ("add" not "added")
   - First line under 72 characters
   - Add a body if the change warrants explanation
5. Commit using a heredoc so formatting is preserved.

Do not push. Do not amend previous commits. If there is nothing to commit, say so.
