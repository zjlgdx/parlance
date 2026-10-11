# CLA records

Sign using the exact statement in [CLA.md](../CLA.md#how-to-sign), replacing
only its five bracketed fields. Save it as `cla/signatures/<github-user-id>.md`
with the statement's final newline. The numeric id inside must match the file
name, and the version must match the head tree's `Version:` in `CLA.md`.
A renamed login does not change the numeric identity. `.gitkeep` only preserves
the initially empty directory; it is not a signature.

Both allowlists are UTF-8 text. Blank lines and `#` comments (including inline
comments) are ignored; fields are separated by whitespace:

- `maintainers`: one positive decimal GitHub user id per line. Put the login
  in a comment for readability, for example `1209636 # zjlgdx`.
- `bots`: `account <numeric-id> <login>` for an exempt bot account, or
  `email <address>` for an AI tool's coauthor email. The login is informational;
  account checks use only the id. Email comparison is case-insensitive.

`land` reads both lists from the pinned `origin/main`, so an addition becomes
effective only after that PR merges. Bot exemptions never confer maintainer
rights, and bot PRs still require signatures for human authors and coauthors.
Other contributors' signatures must be valid in both main and head; submitters
can add or update their own signature in their PR. Maintainers can correct or
remove someone else's record at that person's request. A new signature comes
only from the signer's own PR; this is a maintainer rule the check does not
enforce, but the check does refuse a signature added in the same PR as that
person's contribution.

Maintainers must start `bash scripts/land <pr>` from a checkout tracking main.
It fetches and pins main, loads the merge tool and its helpers from raw base
objects into a temporary directory, and checks signatures and paths even during
`--dry-run`. Do not merge directly in the web UI or start land from a PR checkout:
those bypass the trusted entry point. Failure output identifies the account,
commit, coauthor or path to report on the PR. Commit attribution checks detect
omissions; commit metadata alone does not prove consent or authorship.
